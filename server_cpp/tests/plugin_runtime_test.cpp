#include "ffmpegpp_exports.h"
#include "nlohmann/json.hpp"
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
using json = nlohmann::json;
using Bytes = std::vector<uint8_t>;
using Clock = std::chrono::steady_clock;
namespace fs = std::filesystem;
static void require(bool ok, const std::string& message) {
    if (!ok) throw std::runtime_error(message);
}
static void number(Bytes& b, uint32_t n) {
    do { auto x = uint8_t(n & 127); n >>= 7; b.push_back(x | (n ? 128 : 0)); } while (n);
}
static void text(Bytes& b, const std::string& s) { number(b, uint32_t(s.size())); b.insert(b.end(), s.begin(), s.end()); }
static void section(Bytes& b, uint8_t id, const Bytes& data) {
    b.push_back(id); number(b, uint32_t(data.size())); b.insert(b.end(), data.begin(), data.end());
}
static void i32(Bytes& b, int32_t n) {
    b.push_back(0x41);
    bool more = true;
    while (more) {
        uint8_t x = uint8_t(n & 127); n >>= 7;
        more = !((n == 0 && !(x & 64)) || (n == -1 && (x & 64)));
        b.push_back(x | (more ? 128 : 0));
    }
}
struct Fixture {
    std::string mode = "echo", importModule = "ffmpegpp", extraExport;
    uint32_t initial = 1, maximum = 256, tableMax = 0;
    bool start = false, unbounded = false;
};
static Bytes module(const Fixture& f = {}) {
    Bytes b{0,0x61,0x73,0x6d,1,0,0,0};
    section(b, 1, {2, 0x60,2,0x7f,0x7f,1,0x7f, 0x60,0,0});
    Bytes imports; number(imports, 2);
    for (const auto& name : {"request_read", "response_write"}) { text(imports, f.importModule); text(imports, name); imports.push_back(0); number(imports, 0); }
    section(b, 2, imports);
    section(b, 3, {2,1,1});
    if (f.tableMax) { Bytes table{1,0x70,1}; number(table, 0); number(table, f.tableMax); section(b,4,table); }
    Bytes memory{1, uint8_t(f.unbounded ? 0 : 1)}; number(memory, f.initial); if (!f.unbounded) number(memory, f.maximum); section(b,5,memory);
    Bytes exports; number(exports, f.extraExport.empty() ? 3 : 4);
    text(exports,"memory"); exports.push_back(2); number(exports,0);
    text(exports,"Basic_info"); exports.push_back(0); number(exports,2);
    text(exports,"Node_execute"); exports.push_back(0); number(exports,3);
    if (!f.extraExport.empty()) { text(exports,f.extraExport); exports.push_back(0); number(exports,2); }
    section(b,7,exports);
    if (f.start) section(b,8,{2});
    std::string response = R"({"Name":"fixture","Version":"1.0.0","IsPreview":false,"Summary":"test"})";
    if (f.mode == "bad-json") response = "{";
    if (f.mode == "array") response = "[]";
    if (f.mode == "bad-utf8") response = std::string("{\"") + char(0xff) + "\":0}";
    Bytes metadata{0};
    i32(metadata, 32); i32(metadata, int32_t(response.size())); metadata.insert(metadata.end(),{0x10,1,0x1a,0x0b});
    Bytes execute{0};
    if (f.mode == "loop") execute.insert(execute.end(),{0x03,0x40,0x0c,0,0x0b});
    else if (f.mode == "trap") execute.push_back(0);
    else if (f.mode == "bad-pointer" || f.mode == "too-large") {
        i32(execute, f.mode == "bad-pointer" ? -1 : 32); i32(execute, f.mode == "too-large" ? 262145 : 10);
        execute.insert(execute.end(),{0x10,1,0x1a});
    } else if (f.mode == "double-write") {
        for (int i = 0; i < 2; ++i) { i32(execute,32); i32(execute,int32_t(response.size())); execute.insert(execute.end(),{0x10,1,0x1a}); }
    } else if (f.mode == "grow") {
        i32(execute,255); execute.insert(execute.end(),{0x40,0,0x1a}); // grow to 256 pages
        i32(execute,1); execute.insert(execute.end(),{0x40,0}); // growth past max returns -1
        i32(execute,-1); execute.insert(execute.end(),{0x47,0x04,0x40,0,0x0b}); // trap unless -1
        i32(execute,32); i32(execute,int32_t(response.size())); execute.insert(execute.end(),{0x10,1,0x1a});
    } else {
        i32(execute,1024); i32(execute,1024); i32(execute,4096);
        execute.insert(execute.end(),{0x10,0,0x10,1,0x1a});
    }
    execute.push_back(0x0b);
    Bytes code; number(code,2); number(code,uint32_t(metadata.size())); code.insert(code.end(),metadata.begin(),metadata.end());
    number(code,uint32_t(execute.size())); code.insert(code.end(),execute.begin(),execute.end()); section(b,10,code);
    Bytes data{1,0}; i32(data,32); data.push_back(0x0b); text(data,response); section(b,11,data);
    return b;
}
static unsigned sequence = 0;
static json waitReply(const std::string& id) {
    const auto end = Clock::now() + std::chrono::seconds(10);
    while (Clock::now() < end) {
        if (char* p = ffmpegpp_poll()) {
            const std::string s(p); ffmpegpp_free(p); const auto j = json::parse(s);
            if (j.value("id", "") == id) return j;
        } else std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    throw std::runtime_error("backend reply timed out: " + id);
}
static json request(const std::string& action, const json& params = json::object()) {
    const auto id = "plugin-test-" + std::to_string(++sequence);
    const auto s = json{{"id",id},{"action",action},{"params",params}}.dump();
    require(ffmpegpp_request(s.c_str()) == 0, "request rejected: " + action);
    return waitReply(id);
}
struct TempFiles {
    fs::path root = fs::temp_directory_path() / ("ffmpegpp-plugin-test-" + std::to_string(Clock::now().time_since_epoch().count()));
    TempFiles() { fs::create_directories(root); }
    ~TempFiles() { std::error_code ec; fs::remove_all(root,ec); }
    std::string write(const Bytes& bytes) {
        const auto p = root / (std::to_string(++sequence) + ".wasm");
        std::ofstream f(p,std::ios::binary); f.write(reinterpret_cast<const char*>(bytes.data()),std::streamsize(bytes.size())); f.close();
        return p.u8string();
    }
};
static json params(const std::string& path, const std::string& entry = "Node_execute", const json& req = json{{"value",42}}) {
    return {{"module_path",path},{"entry",entry},{"request",req}};
}
int main(int argc, char** argv) {
    try {
        TempFiles temp;
        require(ffmpegpp_init() == 0,"backend init failed");
        struct Shutdown { ~Shutdown() { ffmpegpp_shutdown(); } } shutdown;
        auto caps = request("plugin_capabilities");
        require(caps.value("success",false) && caps["data"]["available"] == true,"runtime capability missing");
        const auto good = temp.write(module());
        const auto noRoot=request("plugin_invoke",params(good));
        require(!noRoot.value("success",true) && noRoot.value("error","").find("root")!=std::string::npos,"unconfigured root did not fail closed");
        require(request("plugin_set_root",{{"root",temp.root.u8string()}}).value("success",false),"root setup failed");
        auto echo = request("plugin_invoke", params(good));
        require(echo.value("success",false) && echo["data"] == json{{"value",42}},"JSON host round-trip failed: " + echo.dump());
        const json yielded={{"host_request",{{"id","host-1"},{"method","http.get"},{"url","https://example.invalid"}}},{"continuation",{{"stage",1}}}};
        require(request("plugin_invoke",params(good,"Node_execute",yielded))["data"]==yielded,"host_request JSON did not survive round-trip");
        const json resumed={{"continuation",{{"stage",1}}},{"host_response",{{"id","host-1"},{"ok",true},{"result",{{"value",17}}}}}};
        require(request("plugin_invoke",params(good,"Node_execute",resumed))["data"]==resumed,"fresh invocation retained a previous request");
        unsigned rejected = 0;
        auto reject = [&](const json& p, const std::string& part) {
            const auto r = request("plugin_invoke",p);
            require(!r.value("success",true),"unsafe module accepted: " + part);
            require(r.value("error","").find(part) != std::string::npos,"wrong rejection for " + part + ": " + r.dump());
            ++rejected;
        };
        TempFiles outside;
        reject(params(outside.write(module())),"outside");
        reject(params(fs::path(good).filename().u8string()),"absolute");
        reject(params((temp.root / ".." / temp.root.filename() / fs::path(good).filename()).u8string()),"traversal");
        std::error_code symlinkError;
        fs::create_symlink(fs::path(good),temp.root / "alias.wasm",symlinkError);
        if (!symlinkError) reject(params((temp.root / "alias.wasm").u8string()),"symlink");
        reject(params(good,"malloc"),"entry");
        reject(params(temp.write(Bytes(8 * 1024 * 1024 + 1,0))),"8 MiB");
        reject(params(temp.write(Bytes{0,0x61,0x73})),"Core WASM");
        auto truncated=module(); truncated.pop_back(); reject(params(temp.write(truncated)),"truncated");
        auto p = params(good); p["limits"]={{"memory_mb",65}}; reject(p,"limit");
        p=params(good); p["request"]={{"huge",std::string(262145,'x')}}; reject(p,"256 KiB");
        Fixture f; f.start=true; reject(params(temp.write(module(f))),"start");
        f={}; f.extraExport="__post_instantiate"; reject(params(temp.write(module(f))),"initialization");
        f.extraExport="__wasm_call_ctors"; reject(params(temp.write(module(f))),"initialization");
        f.extraExport="_initialize"; reject(params(temp.write(module(f))),"initialization");
        f={}; f.initial=1025; f.maximum=1025; reject(params(temp.write(module(f))),"limit");
        f={}; f.maximum=1025; reject(params(temp.write(module(f))),"limit");
        f={}; f.unbounded=true; reject(params(temp.write(module(f))),"bounded");
        f={}; f.tableMax=4097; reject(params(temp.write(module(f))),"limit");
        f={}; f.importModule="wasi_snapshot_preview1"; reject(params(temp.write(module(f))),"import");
        f={}; f.mode="bad-pointer"; reject(params(temp.write(module(f))),"memory");
        f.mode="too-large"; reject(params(temp.write(module(f))),"quota");
        f.mode="double-write"; reject(params(temp.write(module(f))),"quota");
        f.mode="trap"; reject(params(temp.write(module(f))),"trap");
        f.mode="bad-json"; reject(params(temp.write(module(f)),"Basic_info"),"parse");
        f.mode="bad-utf8"; reject(params(temp.write(module(f)),"Basic_info"),"parse");
        f.mode="array"; reject(params(temp.write(module(f)),"Basic_info"),"object");
        f.mode="loop"; const auto loop=temp.write(module(f));
        p=params(loop); p["limits"]={{"fuel",1000}}; reject(p,"instruction limit");
        p=params(loop); p["limits"]={{"fuel",10000000},{"time_ms",1}}; reject(p,"time limit");
        const auto id="cancel-test";
        auto cancelParams=params(loop); cancelParams["limits"]={{"fuel",10000000},{"time_ms",5000}};
        const auto invoke=json{{"id",id},{"action","plugin_invoke"},{"params",cancelParams}}.dump();
        require(ffmpegpp_request(invoke.c_str())==0,"async cancel invoke failed");
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        const auto cancel=json{{"id","cancel-control"},{"action","cancel"},{"params",{{"task_ids",{id}}}}}.dump();
        require(ffmpegpp_request(cancel.c_str())==0,"cancel request failed");
        const auto cancelled=waitReply(id);
        require(!cancelled.value("success",true) && cancelled.value("error","").find("cancel")!=std::string::npos,"running plugin cancellation failed: " + cancelled.dump());
        f={}; f.mode="grow";
        auto growth=request("plugin_invoke",params(temp.write(module(f))));
        require(growth.value("success",false),"memory growth cap failed: " + growth.dump());
        require(request("plugin_invoke",params(good)).value("success",false),"healthy plugin failed after traps");
        require(request("ping")["data"]["pong"]==true,"main backend failed after plugin errors");
        unsigned sdkCount=0;
        if(argc==3) {
            require(request("plugin_set_root",{{"root",fs::canonical(argv[1]).parent_path().u8string()}}).value("success",false),"SDK root setup failed");
            std::ifstream fixture(argv[2]); json cases; fixture >> cases;
            for(const auto& c : cases.at("cases")) {
                const auto result=request("plugin_invoke",params(fs::canonical(argv[1]).u8string(),c.at("entry"),c.at("request")));
                require(result.value("success",false) && result["data"]==c.at("response"),"SDK fixture failed: " + c.at("name").get<std::string>() + ": " + result.dump());
                ++sdkCount;
            }
        }
        ffmpegpp_shutdown();
        require(ffmpegpp_init()==0,"backend re-init failed");
        require(!request("plugin_invoke",params(good)).value("success",true),"root survived backend lifecycle reset");
        std::cout << "PASS: JSON ABI; " << rejected << " malicious/budget rejections; cancellation; memory.grow; trap recovery; " << sdkCount << " compiled SDK cases\n";
        return 0;
    } catch(const std::exception& e) { std::cerr << "FAIL: " << e.what() << '\n'; return 1; }
}
