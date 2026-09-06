// FPPX 配置文件模块单元测试
// 构建：cmake -DFFMPEGPP_BUILD_TESTS=ON .. && cmake --build . && ctest
// 覆盖：gzip 往返 / v2 导出导入往返 / 未知 ID 强制导入 / CRC 损坏 / 截断 /
//       尾随垃圾 / 张冠李戴 / 图语义校验 / 快速模式 / 旧版格式迁移

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

#include "fppx2.h"
#include "fppx2_format.h"
#include "fppx_gzip.h"
#include "node_registry.h"

using json = nlohmann::json;
using namespace ffmpegpp;

namespace fs = std::filesystem;

static int g_failed = 0;
static int g_passed = 0;

#define CHECK(cond, msg)                                                     \
    do {                                                                     \
        if (cond) {                                                          \
            ++g_passed;                                                      \
        } else {                                                             \
            ++g_failed;                                                      \
            std::printf("  [FAIL] %s\n    (line %d)\n", msg, __LINE__);      \
        }                                                                    \
    } while (0)

static fs::path tmpFile(const std::string& name) {
    fs::path dir = fs::temp_directory_path() / "ffmpegpp_fppx_test";
    fs::create_directories(dir);
    return dir / name;
}

static json readAll(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    return json::parse(f);
}

static std::vector<uint8_t> readBin(const fs::path& p) {
    std::ifstream f(p, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)),
                                std::istreambuf_iterator<char>());
}

// 最小合法图：start → avProcess → output
static json sampleGraph() {
    return {
        {"nodes",
         json::array({
             {{"id", "uuid-a"}, {"type", "start"}, {"params", {{"file_media_type", "video"}}},
              {"x", 0.0}, {"y", 0.0}},
             {{"id", "uuid-b"}, {"type", "avProcess"},
              {"params", {{"video_codec", "h264"}, {"preset", "medium"}}},
              {"x", 100.0}, {"y", 50.0}},
             {{"id", "uuid-c"}, {"type", "output"}, {"params", json::object()},
              {"x", 200.0}, {"y", 0.0}},
         })},
        {"connections",
         json::array({
             {{"id", "k1"}, {"from", "uuid-a"}, {"to", "uuid-b"}, {"kind", "data"}},
             {{"id", "k2"}, {"from", "uuid-b"}, {"to", "uuid-c"}, {"kind", "data"}},
         })},
        {"logicBlocks", json::array()},
    };
}

static Fppx2Result exportGraph(const json& graph, const std::string& path,
                               const std::string& desc = "测试配置") {
    return fppx2Export({{"path", path}, {"mode", 1}, {"description", desc}, {"graph", graph}});
}

int main() {
    setvbuf(stdout, nullptr, _IONBF, 0); // 崩溃时也能看到已打印的进度
    std::printf("== fppx test ==\n");

    // ── 1. gzip 往返 ──
    {
        std::string src = "FPPX gzip round-trip 中文内容 0123456789";
        std::vector<uint8_t> gz = gzipCompress(reinterpret_cast<const uint8_t*>(src.data()),
                                               src.size());
        CHECK(!gz.empty(), "gzip 压缩成功");
        CHECK(gz[0] == 0x1F && gz[1] == 0x8B, "gzip 魔数正确");
        std::vector<uint8_t> out;
        std::string err;
        CHECK(gzipDecompress(gz.data(), gz.size(), out, err), "gzip 解压成功");
        CHECK(std::string(out.begin(), out.end()) == src, "gzip 往返内容一致");
    }

    // ── 2. v2 导出 → 导入往返 ──
    {
        fs::path p = tmpFile("round.fppx");
        Fppx2Result ex = exportGraph(sampleGraph(), p.string());
        CHECK(ex.success, (std::string("v2 导出成功: ") +
                           (ex.errors.empty() ? "" : ex.errors.front()))
                              .c_str());
        CHECK(fs::exists(p) && fs::file_size(p) > 6, "导出文件非空");

        // 文件头：FPPX + FF + 01
        std::vector<uint8_t> bytes = readBin(p);
        CHECK(bytes.size() >= 6 && std::memcmp(bytes.data(), FPPX_MAGIC, 4) == 0, "魔数 FPPX");
        CHECK(bytes[4] == 0xFF, "第 5 字节为重构版标记 0xFF");
        CHECK(bytes[5] == 0x01, "模式为节点编辑器 0x01");

        Fppx2Result im = fppx2Import(p.string(), false);
        CHECK(im.success, (std::string("v2 导入成功: ") +
                           (im.errors.empty() ? "" : im.errors.front()))
                              .c_str());
        CHECK(im.mode == 1, "导入模式 0x01");
        CHECK(im.description == "测试配置", "介绍文本往返一致");
        CHECK(im.unknownTypeIds.empty(), "无未知节点");
        if (im.success && im.graph.is_object()) {
            json g = im.graph;
            CHECK(g["nodes"].size() == 3, "节点数往返一致");
            CHECK(g["connections"].size() == 2, "连线数往返一致");
            // UUID 与类型映射稳定
            bool ok = false;
            for (const auto& n : g["nodes"]) {
                if (n["id"] == "uuid-b" && n["type"] == "avProcess") ok = true;
            }
            CHECK(ok, "节点 id/type 往返稳定");
            // 连线方向
            ok = false;
            for (const auto& c : g["connections"]) {
                if (c["from"] == "uuid-a" && c["to"] == "uuid-b" && c["kind"] == "data") ok = true;
            }
            CHECK(ok, "数据连线方向正确");
        }
    }

    // ── 3. 未知节点 ID：确认门 + 强制导入 + 往返保留 ──
    {
        json g = sampleGraph();
        g["nodes"].push_back({{"id", "uuid-x"}, {"type", "unknown"}, {"type_id", 19243},
                              {"params", json::object()}, {"x", 300.0}, {"y", 0.0}});
        // unknown 不参与数据流，加一条控制连线避免"缺数据输入"误报
        g["connections"].push_back(
            {{"id", "k3"}, {"from", "uuid-b"}, {"to", "uuid-x"}, {"kind", "control"}});

        fs::path p = tmpFile("unknown.fppx");
        Fppx2Result ex = exportGraph(g, p.string());
        CHECK(ex.success, "含未知节点仍可导出（原样保留）");

        Fppx2Result im0 = fppx2Import(p.string(), false);
        CHECK(im0.success, "未强制导入返回 success（用于弹确认框）");
        CHECK(im0.graph.is_null(), "未强制导入时不出图");
        CHECK(im0.unknownTypeIds.size() == 1 && im0.unknownTypeIds[0] == "19243",
              "未知 ID 以十进制串返回 19243");

        Fppx2Result im1 = fppx2Import(p.string(), true);
        CHECK(im1.success && im1.graph.is_object(), "强制导入成功出图");
        CHECK(im1.forced, "forced 标记为 true");
        bool found = false;
        for (const auto& n : im1.graph["nodes"]) {
            if (n["type"] == "unknown" && n["type_id"] == 19243) found = true;
        }
        CHECK(found, "强制导入后未知节点保留 type_id 19243");

        // 强制导入的图再导出 → 再导入，ID 仍保留
        fs::path p2 = tmpFile("unknown_rt.fppx");
        Fppx2Result ex2 = exportGraph(im1.graph, p2.string());
        CHECK(ex2.success, "含未知节点的图再次导出成功");
        Fppx2Result im2 = fppx2Import(p2.string(), true);
        found = false;
        for (const auto& n : im2.graph["nodes"]) {
            if (n["type"] == "unknown" && n["type_id"] == 19243) found = true;
        }
        CHECK(found, "二次往返后未知 ID 仍为 19243");
    }

    // ── 4. CRC 损坏 / 截断 / 尾随垃圾 ──
    {
        fs::path p = tmpFile("crc.fppx");
        CHECK(exportGraph(sampleGraph(), p.string()).success, "CRC 用例导出成功");
        std::vector<uint8_t> bytes = readBin(p);
        // 翻转载荷中间一个字节（保正头部合法）
        bytes[bytes.size() / 2] ^= 0xFF;
        fs::path bad = tmpFile("crc_bad.fppx");
        { std::ofstream f(bad, std::ios::binary); f.write((const char*)bytes.data(), bytes.size()); }
        Fppx2Result im = fppx2Import(bad.string(), false);
        CHECK(!im.success, "CRC 损坏被拒绝");
        bool crcMsg = false;
        for (const auto& e : im.errors)
            if (e.find("CRC32") != std::string::npos) crcMsg = true;
        CHECK(crcMsg, "错误信息提及 CRC32");

        // 截断
        std::vector<uint8_t> cut(bytes.begin(), bytes.begin() + bytes.size() / 2);
        fs::path cutp = tmpFile("cut.fppx");
        { std::ofstream f(cutp, std::ios::binary); f.write((const char*)cut.data(), cut.size()); }
        Fppx2Result imCut = fppx2Import(cutp.string(), false);
        CHECK(!imCut.success, "截断文件被拒绝");

        // 尾随垃圾
        std::vector<uint8_t> tail = readBin(p);
        tail.push_back(0x00);
        tail.push_back(0x01);
        fs::path tailp = tmpFile("tail.fppx");
        { std::ofstream f(tailp, std::ios::binary); f.write((const char*)tail.data(), tail.size()); }
        Fppx2Result imTail = fppx2Import(tailp.string(), false);
        CHECK(!imTail.success, "结尾标记后的多余数据被拒绝");
    }

    // ── 5. 张冠李戴（导出关卡）──
    {
        json g = sampleGraph();
        // angle 属于 imageRotate，放在 avProcess 上 = 张冠李戴
        g["nodes"][1]["params"]["angle"] = "90";
        fs::path p = tmpFile("mismatch.fppx");
        Fppx2Result ex = exportGraph(g, p.string());
        CHECK(!ex.success, "张冠李戴导出被拒绝");
        CHECK(!fs::exists(p), "校验失败不落盘");
        bool mm = false;
        for (const auto& e : ex.errors)
            if (e.find("张冠李戴") != std::string::npos) mm = true;
        CHECK(mm, "错误信息提及张冠李戴");
    }

    // ── 6. 图语义校验 ──
    {
        // 缺输出节点
        json g = sampleGraph();
        g["nodes"].erase(g["nodes"].end() - 1);
        g["connections"].erase(g["connections"].end() - 1);
        Fppx2Result ex = exportGraph(g, tmpFile("noout.fppx").string());
        CHECK(!ex.success, "缺少输出节点被拒绝");

        // 环：avProcess 自连
        json g2 = sampleGraph();
        g2["connections"].push_back(
            {{"id", "loop"}, {"from", "uuid-b"}, {"to", "uuid-b"}, {"kind", "data"}});
        Fppx2Result ex2 = exportGraph(g2, tmpFile("cycle.fppx").string());
        CHECK(!ex2.success, "自环被拒绝");

        // 媒体类型不兼容：start(video) → audioConvert(audio)
        json g3 = sampleGraph();
        g3["nodes"][1] = {{"id", "uuid-b"}, {"type", "audioConvert"},
                          {"params", {{"audio_codec", "aac"}}}, {"x", 1.0}, {"y", 1.0}};
        Fppx2Result ex3 = exportGraph(g3, tmpFile("media.fppx").string());
        CHECK(!ex3.success, "媒体类型不兼容被拒绝");
    }

    // ── 7. 快速模式 0x02 ──
    {
        fs::path p = tmpFile("quick.fppx");
        json items = json::array({
            {{"key", "compress"}, {"params", {{"codec", "hevc"}, {"preset", "medium"}}},
             {"enabled", true}},
            {{"key", "bitrate"}, {"params", {{"bitrate", "4M"}}}, {"enabled", false}},
        });
        Fppx2Result ex = fppx2Export({{"path", p.string()}, {"mode", 2},
                                      {"description", "H265 重编码"}, {"quick_items", items}});
        CHECK(ex.success, (std::string("快速模式导出: ") +
                           (ex.errors.empty() ? "" : ex.errors.front()))
                              .c_str());
        std::vector<uint8_t> bytes = readBin(p);
        CHECK(bytes[4] == 0xFF && bytes[5] == 0x02, "快速模式标记 0xFF 0x02");

        Fppx2Result im = fppx2Import(p.string(), false);
        CHECK(im.success && im.mode == 2, "快速模式导入成功");
        CHECK(im.quickItems.size() == 2, "参数项数量一致");
        if (im.quickItems.size() == 2) {
            CHECK(im.quickItems[0]["key"] == "compress" &&
                      im.quickItems[0]["params"]["codec"] == "hevc",
                  "H265 参数往返一致");
            CHECK(im.quickItems[1]["enabled"] == false, "enabled 状态往返一致");
        }
    }

    // ── 8. 旧版格式：导出 → Python 兼容的 gzip 布局 → 导入往返 ──
    {
        fs::path p = tmpFile("legacy.fppx");
        Fppx2Result ex = fppxLegacyExport({{"path", p.string()},
                                           {"graph", sampleGraph()},
                                           {"description", "旧版配置"}});
        CHECK(ex.success, (std::string("旧版导出: ") +
                           (ex.errors.empty() ? "" : ex.errors.front()))
                              .c_str());
        std::vector<uint8_t> bytes = readBin(p);
        CHECK(bytes[0] == 0x46 && bytes[1] == 0x50 && bytes[2] == 0x50 && bytes[3] == 0x58,
              "旧版魔数 FPPX");
        CHECK(bytes[4] == 0x01, "旧版第 5 字节为 configMajor 0x01（与新版的 0xFF 天然区分）");
        CHECK(bytes[8] == 0x01, "旧版模式为节点编辑器");

        Fppx2Result im = fppxLegacyImport(p.string());
        CHECK(im.success, (std::string("旧版导入: ") +
                           (im.errors.empty() ? "" : im.errors.front()))
                              .c_str());
        CHECK(im.graph.is_object() && im.graph["nodes"].size() == 3, "旧版图往返一致");

        // 旧版文件走 v2 导入应被拒（引导用旧版入口）
        Fppx2Result imV2 = fppx2Import(p.string(), false);
        CHECK(!imV2.success, "旧版文件不会被 v2 导入器误收");
    }

    // ── 8.5 自动路由导入：按文件头第 5 字节分发（GUI 端零格式判断）──
    {
        // 新版文件
        fs::path p2 = tmpFile("auto_v2.fppx");
        CHECK(exportGraph(sampleGraph(), p2.string()).success, "自动路由用例：v2 导出成功");
        Fppx2Result imV2 = fppxAutoImport(p2.string(), false);
        CHECK(imV2.success && imV2.isNewFormat && imV2.graph.is_object(),
              "自动路由识别新版并出图");

        // 旧版文件
        fs::path pl = tmpFile("auto_legacy.fppx");
        CHECK(fppxLegacyExport({{"path", pl.string()}, {"graph", sampleGraph()},
                                {"description", ""}})
                  .success, "自动路由用例：旧版导出成功");
        Fppx2Result imL = fppxAutoImport(pl.string(), false);
        CHECK(imL.success && !imL.isNewFormat && imL.graph.is_object(),
              "自动路由识别旧版并出图");

        // 非 FPPX 文件
        fs::path pj = tmpFile("auto_bad.fppx");
        { std::ofstream f(pj, std::ios::binary); f << "{}"; }
        Fppx2Result imBad = fppxAutoImport(pj.string(), false);
        CHECK(!imBad.success, "自动路由拒绝非 FPPX 文件");
    }

    // ── 9.5 Python/Dart 生成的旧版文件 → C++ 导入（gzip 互操作性）──
    {
        fs::path fixture = tmpFile("dart_fixture.fppx");
        if (fs::exists(fixture)) { // fixture 由外部脚本生成（tests/gen_fixtures.py）
            Fppx2Result im = fppxLegacyImport(fixture.string());
            CHECK(im.success, (std::string("Dart 风格旧版导入: ") +
                               (im.errors.empty() ? "" : im.errors.front()))
                                  .c_str());
            if (im.success && im.graph.is_object()) {
                CHECK(im.graph["nodes"].size() == 3, "fixture 节点数一致");
                bool ok = false;
                for (const auto& n : im.graph["nodes"])
                    if (n["type"] == "speed" && n["params"]["speed"] == 2.0) ok = true;
                CHECK(ok, "fixture 节点参数一致");
            }
        }
    }

    // ── 9. 注册表 ──
    {
        CHECK(findTypeById(makeTypeId(0x1)) != nullptr &&
                  std::string(findTypeById(makeTypeId(0x1))->name) == "avProcess",
              "avProcess 的 16B ID 为 0x1");
        CHECK(findTypeByName("videoCrop") != nullptr &&
                  findTypeByName("videoCrop")->id[15] == 0x18,
              "videoCrop 的 ID 为 0x18");
        CHECK(findGateByName("timeTrigger") != nullptr &&
                  findGateByName("timeTrigger")->id[15] == 0x0A,
              "timeTrigger 的 ID 为 0x10A 尾字节 0x0A");
        CHECK(classifyParamKey("angle", findTypeByName("imageRotate"), nullptr) == PKC_OK,
              "angle 属于 imageRotate");
        CHECK(classifyParamKey("angle", findTypeByName("avProcess"), nullptr) == PKC_MISMATCH,
              "angle 放在 avProcess 上判为张冠李戴");
        CHECK(classifyParamKey("totally_new_key", findTypeByName("avProcess"), nullptr) ==
                  PKC_UNLISTED,
              "未登记键判为新键");
        CHECK(findTypeById(makeTypeId(19243)) == nullptr, "未知 ID 查无此项");
    }

    // ── 10. 逻辑块往返 ──
    {
        json g = sampleGraph();
        g["logicBlocks"].push_back({{"id", "lb1"}, {"type", "loop"}, {"name", "批次"},
                                    {"params", {{"count", 3}}},
                                    {"childNodeIds", json::array({"uuid-b"})},
                                    {"x", 50.0}, {"y", 50.0}, {"width", 300.0},
                                    {"height", 200.0}});
        fs::path p = tmpFile("blocks.fppx");
        Fppx2Result ex = exportGraph(g, p.string());
        CHECK(ex.success, (std::string("含逻辑块导出: ") +
                           (ex.errors.empty() ? "" : ex.errors.front()))
                              .c_str());
        Fppx2Result im = fppx2Import(p.string(), false);
        CHECK(im.success && im.graph["logicBlocks"].size() == 1, "逻辑块往返数量一致");
        if (im.success && im.graph["logicBlocks"].size() == 1) {
            const auto& lb = im.graph["logicBlocks"][0];
            CHECK(lb["name"] == "批次" && lb["params"]["count"] == 3 &&
                      lb["childNodeIds"].size() == 1,
                  "逻辑块字段往返一致");
        }
    }

    std::printf("== %d passed, %d failed ==\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
