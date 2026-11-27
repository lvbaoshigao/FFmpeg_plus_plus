#include "plugin_runtime.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <cerrno>
#ifdef _WIN32
#include <windows.h>
#else
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#endif
#include <mutex>
#include <set>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#ifndef FFMPEGPP_ENABLE_PLUGINS
#define FFMPEGPP_ENABLE_PLUGINS 0
#endif
#if FFMPEGPP_ENABLE_PLUGINS
#include "wasm_export.h"
#endif

namespace ffmpegpp {
namespace {
using json = nlohmann::json;
using Clock = std::chrono::steady_clock;
constexpr size_t kModuleBytes = 8 * 1024 * 1024;
constexpr size_t kJsonBytes = 256 * 1024;
constexpr uint32_t kTableElements = 4096;
const std::set<std::string> kEntries = {"Basic_info", "Node_info", "Node_editor_add", "Node_execute"};
[[noreturn]] void fail(const std::string& message) {
    throw std::runtime_error("Plugin: " + message);
}
namespace fs = std::filesystem;
struct PluginRoot {
    fs::path path, requestedPath;
#ifdef _WIN32
    HANDLE directory = INVALID_HANDLE_VALUE;
    ~PluginRoot() { if (directory != INVALID_HANDLE_VALUE) CloseHandle(directory); }
#else
    int directory = -1;
    ~PluginRoot() { if (directory >= 0) close(directory); }
#endif
};
std::mutex rootMutex;
std::shared_ptr<PluginRoot> configuredRoot;
bool insideRoot(const fs::path& root, const fs::path& path) {
    auto p = path.begin();
    for (auto r = root.begin(); r != root.end(); ++r, ++p) {
        if (p == path.end()) return false;
#ifdef _WIN32
        const auto a = r->native(), b = p->native();
        if (CompareStringOrdinal(a.c_str(), int(a.size()), b.c_str(), int(b.size()), TRUE) != CSTR_EQUAL) return false;
#else
        if (*r != *p) return false;
#endif
    }
    return p != path.end();
}
#ifdef _WIN32
fs::path openedPath(HANDLE handle) {
    std::wstring buffer(32768, L'\0');
    const auto n = GetFinalPathNameByHandleW(handle, buffer.data(), DWORD(buffer.size()), FILE_NAME_NORMALIZED);
    if (!n || n >= buffer.size()) fail("cannot verify opened module path");
    buffer.resize(n);
    if (buffer.compare(0,8,L"\\\\?\\UNC\\") == 0) buffer = L"\\\\" + buffer.substr(8);
    else if (buffer.compare(0,4,L"\\\\?\\") == 0) buffer.erase(0,4);
    return fs::path(buffer).lexically_normal();
}
#endif
[[maybe_unused]] std::vector<uint8_t> readModule(const std::string& path) {
    std::shared_ptr<PluginRoot> root;
    { std::lock_guard<std::mutex> lock(rootMutex); root = configuredRoot; }
    if (!root) fail("plugin root is not configured");
    const auto requested = fs::u8path(path);
    if (!requested.is_absolute()) fail("module path must be absolute");
    for (const auto& part : requested) if (part == "..") fail("module path traversal is prohibited");
    const auto lexical = requested.lexically_normal();
    const auto base = insideRoot(root->requestedPath, lexical) ? root->requestedPath : root->path;
    if (!insideRoot(base, lexical)) fail("module path is outside the configured plugin root");
    const auto relative = lexical.lexically_relative(base);
    // Trusted aliases in the root's own path are canonicalized at setup. No
    // symlinks/reparse points are followed beneath that application directory.
    auto component = base;
    for (const auto& part : relative) {
        component /= part;
#ifdef _WIN32
        const auto attributes = GetFileAttributesW(component.c_str());
        if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_REPARSE_POINT))
            fail("symlink/reparse module paths are prohibited");
#else
        std::error_code statusError;
        if (fs::is_symlink(fs::symlink_status(component, statusError)) || statusError)
            fail("symlink module paths are prohibited");
#endif
    }
    std::error_code ec;
    const auto resolved = fs::canonical(requested, ec);
    if (ec || !insideRoot(root->path, resolved)) fail("module path is outside the configured plugin root");
#ifdef _WIN32
    struct FileHandle {
        HANDLE value = INVALID_HANDLE_VALUE;
        ~FileHandle() { if (value != INVALID_HANDLE_VALUE) CloseHandle(value); }
    } file;
    file.value = CreateFileW(resolved.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                             OPEN_EXISTING, FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
    if (file.value == INVALID_HANDLE_VALUE) fail("cannot open module under plugin root");
    BY_HANDLE_FILE_INFORMATION info{};
    if (!GetFileInformationByHandle(file.value, &info) ||
        (info.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) ||
        !insideRoot(openedPath(root->directory), openedPath(file.value)))
        fail("opened module is outside the plugin root or not a regular file");
    const uint64_t size = (uint64_t(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    if (!size || size > kModuleBytes) fail("module exceeds 8 MiB or is empty");
    std::vector<uint8_t> bytes(static_cast<size_t>(size));
    DWORD readBytes = 0;
    if (!ReadFile(file.value, bytes.data(), DWORD(size), &readBytes, nullptr) || readBytes != size)
        fail("cannot read WASM module");
#else
    // Walk from a retained directory descriptor; symlink swaps cannot redirect
    // resolution outside the configured directory between checking and opening.
    struct Descriptor {
        int value = -1;
        ~Descriptor() { if (value >= 0) close(value); }
    } directory, file;
    directory.value = fcntl(root->directory, F_DUPFD_CLOEXEC, 0);
    if (directory.value < 0) fail("cannot open plugin root descriptor");
    std::vector<std::string> parts;
    for (const auto& part : relative) {
        if (part == ".." || part == "." || part.empty()) fail("invalid relative module path");
        parts.push_back(part.native());
    }
    if (parts.empty()) fail("module path must name a file");
    for (size_t i = 0; i + 1 < parts.size(); ++i) {
        const int next = openat(directory.value, parts[i].c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0) fail("invalid/symlink module directory");
        close(directory.value); directory.value = next;
    }
    file.value = openat(directory.value, parts.back().c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    struct stat info{};
    if (file.value < 0 || fstat(file.value, &info) != 0 || !S_ISREG(info.st_mode))
        fail("module path must be a regular file under plugin root");
    if (info.st_size <= 0 || uint64_t(info.st_size) > kModuleBytes) fail("module exceeds 8 MiB or is empty");
    std::vector<uint8_t> bytes(static_cast<size_t>(info.st_size));
    size_t offset = 0;
    while (offset < bytes.size()) {
        const auto n = read(file.value, bytes.data() + offset, bytes.size() - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) fail("cannot read WASM module");
        offset += static_cast<size_t>(n);
    }
    uint8_t extra;
    if (read(file.value, &extra, 1) != 0) fail("WASM module changed during read");
#endif
    return bytes;
}
struct Limits { int memoryMb = 16, timeMs = 1000, fuel = 1000000; };
int limit(const json& value, const char* key, int fallback, int maximum) {
    if (!value.contains(key)) return fallback;
    const auto& v = value.at(key);
    if (!v.is_number_integer() || v.is_boolean()) fail(std::string("invalid limit ") + key);
    const auto n = v.get<int64_t>();
    if (n <= 0 || n > maximum) fail(std::string("limit out of range: ") + key);
    return static_cast<int>(n);
}
void checkJson(const json& value, int depth = 0, size_t* count = nullptr) {
    size_t local = 0;
    if (!count) count = &local;
    if (depth > 64 || ++*count > 32768) fail("JSON structure limit exceeded");
    if (value.is_structured()) {
        for (const auto& child : value) checkJson(child, depth + 1, count);
    }
}
#if FFMPEGPP_ENABLE_PLUGINS
// Serialize WAMR global initialization/destruction; slot wait consumes deadline.
std::timed_mutex runtimeMutex;
struct Reader {
    const uint8_t* p;
    const uint8_t* end;
    size_t left() const { return static_cast<size_t>(end - p); }
    uint8_t byte() { if (p == end) fail("truncated WASM"); return *p++; }
    uint32_t u32() {
        uint32_t n = 0;
        for (unsigned i = 0; i < 5; ++i) {
            const uint8_t b = byte();
            if (i == 4 && (b & 0xf0)) fail("invalid WASM integer");
            n |= uint32_t(b & 0x7f) << (i * 7);
            if (!(b & 0x80)) return n;
        }
        fail("invalid WASM integer");
    }
    uint32_t count(uint32_t max) { const auto n = u32(); if (n > max) fail("WASM structure limit exceeded"); return n; }
    Reader sub(size_t n) {
        if (n > left()) fail("truncated WASM section");
        Reader r{p, p + n}; p += n; return r;
    }
    void skip(size_t n) { (void)sub(n); }
    std::string name() {
        const auto n = count(1024); const auto r = sub(n);
        return std::string(reinterpret_cast<const char*>(r.p), n);
    }
    void done() const { if (p != end) fail("trailing WASM section data"); }
};
void numericType(uint8_t type) {
    if (type < 0x7c || type > 0x7f) fail("unsupported WASM value type");
}
void constExpr(Reader& r) {
    switch (r.byte()) {
    case 0x41: case 0x42: {
        unsigned n = 0;
        while (r.byte() & 0x80) if (++n >= 10) fail("invalid constant expression");
        break;
    }
    case 0x43: r.skip(4); break;
    case 0x44: r.skip(8); break;
    case 0x23: (void)r.u32(); break;
    default: fail("unsupported constant expression");
    }
    if (r.byte() != 0x0b) fail("unsupported constant expression");
}
uint32_t boundedMemory(Reader& r, uint32_t maximum) {
    // Require maximum; disallow shared/memory64/custom page sizes.
    if (r.u32() != 1) fail("WASM memory/table needs bounded wasm32 limits");
    const auto initial = r.u32(), declaredMax = r.u32();
    if (initial > declaredMax || declaredMax > maximum) fail("WASM memory/table limit exceeded");
    return declaredMax;
}
struct FunctionType { std::vector<uint8_t> params, results; };
uint32_t validateModule(const std::vector<uint8_t>& bytes, uint32_t memoryPages) {
    static const uint8_t header[] = {0, 0x61, 0x73, 0x6d, 1, 0, 0, 0};
    if (bytes.size() < 8 || std::memcmp(bytes.data(), header, 8)) fail("expected Core WASM version 1");
    Reader file{bytes.data() + 8, bytes.data() + bytes.size()};
    std::vector<FunctionType> types;
    std::vector<uint32_t> functionTypes;
    std::map<std::string, uint32_t> exportedFunctions;
    std::set<uint8_t> sections;
    std::set<std::string> imports, exportNames;
    uint32_t definedFunctions = 0, memoryCount = 0, moduleMemoryMax = 0;
    while (file.left()) {
        const auto section = file.byte();
        const auto size = file.u32();
        Reader r = file.sub(size);
        if (!section) continue;
        if (section > 12 || !sections.insert(section).second) fail("unsupported/duplicate WASM section");
        switch (section) {
        case 1: {
            const auto n = r.count(1024);
            for (uint32_t i = 0; i < n; ++i) {
                if (r.byte() != 0x60) fail("unsupported WASM function type");
                FunctionType t;
                auto count = r.count(32);
                while (count--) { auto v = r.byte(); numericType(v); t.params.push_back(v); }
                count = r.count(16);
                while (count--) { auto v = r.byte(); numericType(v); t.results.push_back(v); }
                types.push_back(std::move(t));
            }
            break;
        }
        case 2: {
            const auto n = r.count(2);
            for (uint32_t i = 0; i < n; ++i) {
                const auto module = r.name(), name = r.name();
                if (module != "ffmpegpp" || (name != "request_read" && name != "response_write") ||
                    !imports.insert(name).second || r.byte() != 0) fail("unknown WASM import");
                const auto index = r.u32();
                if (index >= types.size() || types[index].params != std::vector<uint8_t>({0x7f, 0x7f}) ||
                    types[index].results != std::vector<uint8_t>({0x7f})) fail("invalid WASM import signature");
                functionTypes.push_back(index);
            }
            break;
        }
        case 3: {
            definedFunctions = r.count(4096);
            for (uint32_t i = 0; i < definedFunctions; ++i) {
                const auto index = r.u32();
                if (index >= types.size()) fail("invalid WASM function type index");
                functionTypes.push_back(index);
            }
            break;
        }
        case 4: {
            auto n = r.count(1);
            while (n--) { if (r.byte() != 0x70) fail("unsupported table type"); boundedMemory(r, kTableElements); }
            break;
        }
        case 5: {
            memoryCount = r.count(1);
            for (uint32_t i = 0; i < memoryCount; ++i) moduleMemoryMax = boundedMemory(r, memoryPages);
            break;
        }
        case 6: {
            auto n = r.count(1024);
            while (n--) { numericType(r.byte()); if (r.byte() > 1) fail("invalid global"); constExpr(r); }
            break;
        }
        case 7: {
            auto n = r.count(16);
            while (n--) {
                const auto name = r.name();
                if (!exportNames.insert(name).second) fail("duplicate WASM export");
                if (name == "_initialize" || name == "__post_instantiate" || name == "__wasm_call_ctors")
                    fail("automatic WASM initialization is prohibited");
                const auto kind = r.byte(); const auto index = r.u32();
                if (kind == 0) {
                    if (!kEntries.count(name)) fail("unknown WASM function export");
                    exportedFunctions.emplace(name, index);
                } else if (kind != 2 || name != "memory" || index != 0) fail("unsupported WASM export");
            }
            break;
        }
        case 8: fail("WASM start section is prohibited");
        case 9: {
            auto n = r.count(1024);
            uint32_t total = 0;
            while (n--) {
                const auto flags = r.u32();
                if (flags > 3) fail("unsupported element segment");
                if (flags == 2 && r.u32() != 0) fail("invalid table index");
                if (flags == 0 || flags == 2) constExpr(r);
                if (flags && r.byte() != 0) fail("unsupported element kind");
                const auto elements = r.count(kTableElements);
                total += elements; if (total > kTableElements) fail("element segment limit exceeded");
                for (uint32_t i = 0; i < elements; ++i) (void)r.u32();
            }
            break;
        }
        case 10: {
            auto n = r.count(4096);
            if (n != definedFunctions) fail("WASM function/code count mismatch");
            while (n--) {
                const auto bodySize = r.count(1024 * 1024);
                Reader body = r.sub(bodySize);
                auto groups = body.count(1024); uint32_t locals = 0;
                while (groups--) {
                    locals += body.count(4096); numericType(body.byte());
                    if (locals > 4096) fail("WASM local limit exceeded");
                }
                // WAMR performs complete instruction/type/control-flow validation.
            }
            break;
        }
        case 11: {
            auto n = r.count(4096);
            while (n--) {
                const auto flags = r.u32();
                if (flags > 2) fail("unsupported data segment");
                if (flags == 2 && r.u32() != 0) fail("invalid memory index");
                if (flags != 1) constExpr(r);
                const auto length = r.u32(); r.skip(length);
            }
            break;
        }
        case 12: (void)r.count(4096); break;
        default: fail("unsupported WASM section");
        }
        r.done();
    }
    if (memoryCount != 1 || !exportedFunctions.count("Basic_info") || !imports.count("response_write"))
        fail("missing required WASM memory/Basic_info/response_write");
    for (const auto& entry : exportedFunctions) {
        if (entry.second >= functionTypes.size()) fail("invalid exported function index");
        const auto& type = types.at(functionTypes.at(entry.second));
        if (!type.params.empty() || !type.results.empty()) fail("plugin exports must have signature ()->()");
    }
    return moduleMemoryMax;
}
struct CallContext {
    std::string request, response;
    const char* error = nullptr;
    unsigned reads = 0, writes = 0;
};
thread_local CallContext* callContext = nullptr;
int32_t requestRead(wasm_exec_env_t env, uint32_t pointer, uint32_t capacity) noexcept {
    auto* c = callContext;
    if (!c) return -1;
    if (++c->reads > 16 || capacity > kJsonBytes) {
        c->error = "request_read capacity/call quota exceeded"; return -1;
    }
    // An undersized SDK buffer is a recoverable ABI result, not a trap.
    if (capacity < c->request.size()) return -2;
    auto inst = wasm_runtime_get_module_inst(env);
    if (!wasm_runtime_validate_app_addr(inst, pointer, capacity)) { c->error = "request_read invalid memory range"; return -1; }
    auto* target = wasm_runtime_addr_app_to_native(inst, pointer);
    if (!target) { c->error = "request_read invalid pointer"; return -1; }
    std::memcpy(target, c->request.data(), c->request.size());
    return static_cast<int32_t>(c->request.size());
}
int32_t responseWrite(wasm_exec_env_t env, uint32_t pointer, uint32_t length) noexcept {
    auto* c = callContext;
    if (!c) return -1;
    if (++c->writes != 1 || !length || length > kJsonBytes) { c->error = "response_write size/call quota exceeded"; return -1; }
    auto inst = wasm_runtime_get_module_inst(env);
    if (!wasm_runtime_validate_app_addr(inst, pointer, length)) { c->error = "response_write invalid memory range"; return -1; }
    auto* source = wasm_runtime_addr_app_to_native(inst, pointer);
    if (!source) { c->error = "response_write invalid pointer"; return -1; }
    try { c->response.assign(static_cast<const char*>(source), length); }
    catch (...) { c->error = "response allocation failed"; return -1; }
    return static_cast<int32_t>(length);
}
struct RuntimeScope {
    bool initialized = false, threadInitialized = false;
    wasm_module_t module = nullptr;
    wasm_module_inst_t instance = nullptr;
    wasm_exec_env_t env = nullptr;
    ~RuntimeScope() {
        callContext = nullptr;
        if (env) wasm_runtime_destroy_exec_env(env);
        if (instance) wasm_runtime_deinstantiate(instance);
        if (module) wasm_runtime_unload(module);
        if (threadInitialized) wasm_runtime_destroy_thread_env();
        if (initialized) wasm_runtime_destroy();
    }
};
struct Watchdog {
    std::mutex mutex; std::condition_variable cv;
    bool done = false; std::atomic<bool> timedOut{false}, cancelled{false};
    std::thread thread;
    Watchdog(wasm_module_inst_t inst, Clock::time_point deadline, const std::function<bool()>& cancel) {
        thread = std::thread([this, inst, deadline, cancel] {
            std::unique_lock<std::mutex> lock(mutex);
            while (!done) {
                bool stop = false;
                try { stop = cancel && cancel(); } catch (...) { stop = true; }
                if (stop || Clock::now() >= deadline) {
                    cancelled.store(stop); timedOut.store(!stop);
                    wasm_runtime_terminate(inst); return;
                }
                cv.wait_until(lock, std::min(deadline, Clock::now() + std::chrono::milliseconds(10)), [this] { return done; });
            }
        });
    }
    void finish() {
        { std::lock_guard<std::mutex> lock(mutex); done = true; }
        cv.notify_all(); if (thread.joinable()) thread.join();
    }
    ~Watchdog() { finish(); }
};
#endif
} // namespace

void clearPluginRoot() {
    std::lock_guard<std::mutex> lock(rootMutex);
    configuredRoot.reset();
}
nlohmann::json configurePluginRoot(const nlohmann::json& params) {
    if (!params.is_object() || !params.contains("root") || !params["root"].is_string()) fail("root is required");
    const auto value = params["root"].get<std::string>();
    if (value.empty() || value.size() > 32768 || value.find(char(0)) != std::string::npos) fail("invalid plugin root");
    const auto requested = fs::u8path(value);
    if (!requested.is_absolute()) fail("plugin root must be absolute");
    std::error_code ec;
    const auto path = fs::canonical(requested,ec);
    if (ec || !fs::is_directory(path,ec) || ec || path == path.root_path()) fail("plugin root must be an existing private directory");
    auto root = std::make_shared<PluginRoot>(); root->path = path;
    root->requestedPath = requested.lexically_normal();
#ifdef _WIN32
    root->directory = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                                   nullptr, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, nullptr);
    if (root->directory == INVALID_HANDLE_VALUE) fail("cannot retain plugin root handle");
    root->path = openedPath(root->directory);
#else
    root->directory = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root->directory < 0) fail("cannot retain plugin root descriptor");
#endif
    { std::lock_guard<std::mutex> lock(rootMutex); configuredRoot = std::move(root); }
    return {{"configured",true}};
}
nlohmann::json pluginCapabilities() {
    return {{"available", FFMPEGPP_ENABLE_PLUGINS != 0}, {"api_version", 1},
        {"runtime", "WAMR"}, {"runtime_version", "2.4.6"}, {"mode", "interpreter"},
        {"isolation", "wasm-traps-in-process"}, {"wasi", false}, {"guest_threads", false},
        {"max_module_bytes", kModuleBytes}, {"max_request_bytes", kJsonBytes}, {"max_response_bytes", kJsonBytes},
        {"limits", {{"memory_mb", 64}, {"time_ms", 5000}, {"fuel", 10000000}, {"table_elements", kTableElements}}}};
}

nlohmann::json invokePlugin(const nlohmann::json& params, const std::function<bool()>& isCancelled) {
    if (!params.is_object()) fail("params must be an object");
    if (!params.contains("entry") || !params["entry"].is_string() || !kEntries.count(params["entry"].get<std::string>()))
        fail("entry is not an allowed plugin export");
    if (!params.contains("module_path") || !params["module_path"].is_string()) fail("module_path is required");
    const auto path = params["module_path"].get<std::string>();
    if (path.empty() || path.size() > 32768 || path.find(char(0)) != std::string::npos) fail("invalid module_path");
    const auto rawLimits = params.value("limits", json::object());
    if (!rawLimits.is_object()) fail("limits must be an object");
    Limits limits;
    limits.memoryMb = limit(rawLimits, "memory_mb", 16, 64);
    limits.timeMs = limit(rawLimits, "time_ms", 1000, 5000);
    limits.fuel = limit(rawLimits, "fuel", 1000000, 10000000);
    const auto request = params.value("request", json::object());
    if (!request.is_object()) fail("request must be a JSON object");
    checkJson(request);
    const auto requestText = request.dump();
    if (requestText.size() > kJsonBytes) fail("request exceeds 256 KiB");
#if !FFMPEGPP_ENABLE_PLUGINS
    (void)isCancelled; (void)limits;
    fail("WAMR is unavailable in this backend build");
#else
    const auto deadline = Clock::now() + std::chrono::milliseconds(limits.timeMs);
    std::unique_lock<std::timed_mutex> runtimeLock(runtimeMutex, std::defer_lock);
    if (!runtimeLock.try_lock_until(deadline)) fail("runtime busy/time limit exceeded");
    if (isCancelled && isCancelled()) fail("invocation cancelled");
    auto bytes = readModule(path);
    const auto moduleMemoryMax = validateModule(bytes, uint32_t(limits.memoryMb) * 16);
    if (Clock::now() >= deadline) fail("setup time limit exceeded");
    RuntimeScope scope;
    if (!(scope.initialized = wasm_runtime_init())) fail("cannot initialize WAMR");
    // Routine traps are returned through JSON, not printed into the host UI.
    wasm_runtime_set_log_level(WASM_LOG_LEVEL_ERROR);
    if (!wasm_runtime_thread_env_inited()) {
        if (!(scope.threadInitialized = wasm_runtime_init_thread_env())) fail("cannot initialize WAMR worker environment");
    }
    static NativeSymbol symbols[] = {
        {"request_read", reinterpret_cast<void*>(requestRead), "(ii)i", nullptr},
        {"response_write", reinterpret_cast<void*>(responseWrite), "(ii)i", nullptr},
    };
    if (!wasm_runtime_register_natives("ffmpegpp", symbols, 2)) fail("cannot register host ABI");
    char error[256] = {};
    scope.module = wasm_runtime_load(bytes.data(), static_cast<uint32_t>(bytes.size()), error, sizeof(error));
    if (!scope.module) fail(std::string("module validation failed: ") + error);
    InstantiationArgs args{};
    args.default_stack_size = 64 * 1024;
    args.host_managed_heap_size = 0;
    args.max_memory_pages = moduleMemoryMax;
    scope.instance = wasm_runtime_instantiate_ex(scope.module, &args, error, sizeof(error));
    if (!scope.instance) fail(std::string("instantiation failed: ") + error);
    scope.env = wasm_runtime_create_exec_env(scope.instance, args.default_stack_size);
    if (!scope.env) fail("cannot allocate execution environment");
    const auto entryName = params["entry"].get<std::string>();
    auto entry = wasm_runtime_lookup_function(scope.instance, entryName.c_str());
    if (!entry) fail("requested export is missing");
    if (Clock::now() >= deadline) fail("setup time limit exceeded");
    CallContext context; context.request = requestText;
    callContext = &context;
    wasm_runtime_set_instruction_count_limit(scope.env, limits.fuel);
    Watchdog watchdog(scope.instance, deadline, isCancelled);
    const bool ok = wasm_runtime_call_wasm_a(scope.env, entry, 0, nullptr, 0, nullptr);
    watchdog.finish();
    callContext = nullptr;
    if (watchdog.cancelled.load()) fail("invocation cancelled");
    if (watchdog.timedOut.load() || Clock::now() >= deadline) fail("execution time limit exceeded");
    if (!ok) {
        const char* exception = wasm_runtime_get_exception(scope.instance);
        fail(std::string("WASM trap: ") + (exception ? exception : "unknown trap"));
    }
    if (context.error) fail(context.error);
    if (context.writes != 1 || context.response.empty()) fail("plugin produced no response");
    auto response = json::parse(context.response, [](int depth, json::parse_event_t, json&) {
        if (depth > 64) fail("response JSON depth exceeded");
        return true;
    });
    if (!response.is_object()) fail("response must be a JSON object");
    checkJson(response);
    return response;
#endif
}
} // namespace ffmpegpp
