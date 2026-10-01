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
#include "fppx_crypto.h"
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


    // ═══════════════════════════════════════════════
    // 索引模块（0x00）与加密（0x02/0x05）——本轮新增
    // ═══════════════════════════════════════════════

    auto u32At = [](const std::vector<uint8_t>& b, size_t o) {
        return (static_cast<uint32_t>(b[o]) << 24) | (static_cast<uint32_t>(b[o + 1]) << 16) |
               (static_cast<uint32_t>(b[o + 2]) << 8) | static_cast<uint32_t>(b[o + 3]);
    };
    auto writeBin = [](const fs::path& p, const std::vector<uint8_t>& b) {
        std::ofstream f(p, std::ios::binary);
        f.write(reinterpret_cast<const char*>(b.data()), static_cast<std::streamsize>(b.size()));
    };
    // 在索引里按模块 ID 找 [模块起始, 载荷长度]
    auto findMod = [&](const std::vector<uint8_t>& b, uint8_t id, size_t& off, uint32_t& load) {
        off = 0;
        load = 0;
        if (b.size() < 19 || b[6] != FPPX2_MODULE_INDEX) return false;
        const uint32_t k = u32At(b, 15);
        for (uint32_t i = 0; i < k; ++i) {
            const size_t e = 19 + 9 * static_cast<size_t>(i);
            if (e + 8 >= b.size()) return false;
            if (b[e] == id) {
                off = u32At(b, e + 1);
                load = u32At(b, e + 5) - FPPX2_MODULE_HEADER_LEN;
                return true;
            }
        }
        return false;
    };

    // ── 11. 索引模块布局 ──
    {
        fs::path p = tmpFile("index_layout.fppx");
        Fppx2Result ex = exportGraph(sampleGraph(), p.string(), "索引测试");
        CHECK(ex.success, "带索引导出成功");
        std::vector<uint8_t> b = readBin(p);
        CHECK(b.size() > 19 && b[6] == FPPX2_MODULE_INDEX, "文件头之后第一个模块是索引 0x00");
        CHECK(b[11] == 0x01 && b[12] == 0x09 && b[13] == 0x00 && b[14] == 0x00,
              "索引头 = 版本1/步长9/保留0");
        const uint32_t k = u32At(b, 15);
        CHECK(k == 6, "未加密文件索引条目数 K = 6");
        CHECK(b[19] == FPPX2_MODULE_INDEX, "条目 0 的 ID 为 0x00（索引自身）");
        CHECK(u32At(b, 20) == 6, "条目 0 的偏移 = 6");
        CHECK(u32At(b, 24) == 13u + 9u * k, "条目 0 的大小 = 13 + 9K");
        // 末条必须是结尾模块，且恰好收在文件末尾
        const size_t last = 19 + 9 * static_cast<size_t>(k - 1);
        CHECK(b[last] == FPPX2_MODULE_END, "末条是 0xFF 结尾模块");
        CHECK(u32At(b, last + 1) + u32At(b, last + 5) == b.size(), "索引覆盖到文件末尾");
        // 偏移严格递增
        bool increasing = true;
        for (uint32_t i = 1; i < k; ++i) {
            const size_t a = 19 + 9 * static_cast<size_t>(i - 1);
            const size_t c = 19 + 9 * static_cast<size_t>(i);
            if (u32At(b, c + 1) < u32At(b, a + 1) + u32At(b, a + 5)) increasing = false;
        }
        CHECK(increasing, "索引条目偏移严格递增且不重叠");
        CHECK(u32At(b, 19 + 9 + 1) == 6u + 13u + 9u * k, "介绍模块紧跟索引之后");
    }

    // ── 12. 无索引的老 v2 文件必须仍可读（回退线性扫描）──
    {
        fs::path src = tmpFile("noindex_src.fppx");
        Fppx2Result ex = exportGraph(sampleGraph(), src.string(), "老文件");
        CHECK(ex.success, "生成源文件成功");
        std::vector<uint8_t> b = readBin(src);
        const uint32_t k = u32At(b, 15);
        (void)k;

        auto buildNoIndex = [&](std::vector<uint8_t> payload) {
            std::vector<uint8_t> out(b.begin(), b.begin() + 6);
            auto mod = [&](uint8_t id, const std::vector<uint8_t>& pl) {
                out.push_back(id);
                out.push_back(static_cast<uint8_t>((pl.size() >> 24) & 0xFF));
                out.push_back(static_cast<uint8_t>((pl.size() >> 16) & 0xFF));
                out.push_back(static_cast<uint8_t>((pl.size() >> 8) & 0xFF));
                out.push_back(static_cast<uint8_t>(pl.size() & 0xFF));
                out.insert(out.end(), pl.begin(), pl.end());
            };
            mod(FPPX2_MODULE_DESC, {'o', 'l', 'd'});
            mod(FPPX2_MODULE_ENCRYPTED, {FPPX2_ENCRYPT_NONE});
            mod(FPPX2_MODULE_PAYLOAD, payload);
            const uint32_t crc = fppxCrc32(out.data(), out.size());
            mod(FPPX2_MODULE_CRC32, {static_cast<uint8_t>(crc >> 24),
                                     static_cast<uint8_t>(crc >> 16),
                                     static_cast<uint8_t>(crc >> 8),
                                     static_cast<uint8_t>(crc & 0xFF)});
            mod(FPPX2_MODULE_END, {});
            return out;
        };

        // 从源文件里抠出 0x03 载荷
        size_t payOff = 0;
        uint32_t payLen = 0;
        CHECK(findMod(b, FPPX2_MODULE_PAYLOAD, payOff, payLen), "能在索引中定位 0x03");
        std::vector<uint8_t> payload(b.begin() + payOff + 5, b.begin() + payOff + 5 + payLen);
        CHECK(payload.size() > 8 && payload[0] == 0x01 && payload[1] == 0x09,
              "0x03 载荷以内层索引开头");

        // (a) 无顶层索引，但载荷内仍有内层索引
        fs::path p1 = tmpFile("noindex_a.fppx");
        writeBin(p1, buildNoIndex(payload));
        Fppx2Result r1 = fppx2Import(p1.string(), false);
        CHECK(r1.success && r1.graph["nodes"].size() == 3, "无顶层索引的老文件仍可读");

        // (b) 连内层索引也去掉（更老的载荷：直接 [4B N] 起头）
        const uint32_t kInner = u32At(payload, 4);
        const size_t innerSize = 8 + 9 * static_cast<size_t>(kInner);
        std::vector<uint8_t> legacyPayload(payload.begin() + innerSize, payload.end());
        CHECK(legacyPayload.size() > 4 && !(legacyPayload[0] == 0x01 && legacyPayload[1] == 0x09),
              "剥离内层索引后载荷以 [4B N] 起头");
        fs::path p2 = tmpFile("noindex_b.fppx");
        writeBin(p2, buildNoIndex(legacyPayload));
        Fppx2Result r2 = fppx2Import(p2.string(), false);
        CHECK(r2.success && r2.graph["nodes"].size() == 3, "无内层索引的老载荷仍可读");


        // (c) 索引被写入后，字节 6 一定是 0x00 之外的值判定无歧义
        CHECK(b[6] == FPPX2_MODULE_INDEX && buildNoIndex(payload)[6] == FPPX2_MODULE_DESC,
              "有无索引可由 bytes[6] 无歧义判定");
    }

    // ── 13. 加密往返（AES-256-CBC 默认 + AES-128-CBC）──
    const std::string pwd = "correct horse battery staple";
    for (int algo : {static_cast<int>(FPPX2_ALGO_AES256_CBC),
                     static_cast<int>(FPPX2_ALGO_AES128_CBC)}) {
        const char* tag = (algo == static_cast<int>(FPPX2_ALGO_AES256_CBC)) ? "AES-256" : "AES-128";
        fs::path p = tmpFile(std::string("enc_") + tag + ".fppx");
        json params = {{"path", p.string()},
                       {"mode", 1},
                       {"description", "加密配置"},
                       {"graph", sampleGraph()},
                       {"encrypted", true},
                       {"password", pwd},
                       {"encrypt_algo", algo}};
        Fppx2Result ex = fppx2Export(params);
        CHECK(ex.success, (std::string(tag) + " 加密导出成功: " +
                           (ex.errors.empty() ? "" : ex.errors.front()))
                              .c_str());

        Fppx2Result np = fppx2Import(p.string(), false);
        CHECK(!np.success && np.needPassword && np.errors.empty(),
              (std::string(tag) + " 无口令返回 need_password 而非错误").c_str());

        std::vector<uint8_t> b = readBin(p);
        Fppx2Result wp = fppx2Import(p.string(), false, "wrong password");
        CHECK(!wp.success && !wp.errors.empty(), (std::string(tag) + " 错口令被拒绝").c_str());

        Fppx2Result ok = fppx2Import(p.string(), false, pwd);
        CHECK(ok.success && ok.encrypted, (std::string(tag) + " 正确口令解密成功").c_str());
        CHECK(ok.success && ok.graph["nodes"].size() == 3 &&
                  ok.graph["connections"].size() == 2,
              (std::string(tag) + " 解密后节点与连线数一致").c_str());

        // 加密后条目数 7（多一个 0x05），且 0x02 首字节标记算法
        CHECK(u32At(b, 15) == 7, (std::string(tag) + " 加密文件索引条目数 = 7").c_str());
        size_t encOff = 0, macOff = 0, payOff2 = 0, crcOff = 0;
        uint32_t encLen = 0, macLen = 0, payLen2 = 0, crcLen = 0;
        CHECK(findMod(b, FPPX2_MODULE_ENCRYPTED, encOff, encLen), "能定位 0x02");
        CHECK(findMod(b, FPPX2_MODULE_MAC, macOff, macLen), "能定位 0x05");
        CHECK(findMod(b, FPPX2_MODULE_PAYLOAD, payOff2, payLen2), "能定位 0x03");
        CHECK(findMod(b, FPPX2_MODULE_CRC32, crcOff, crcLen), "能定位 0x04");
        CHECK(b[encOff + 5] == static_cast<uint8_t>(algo), "0x02 首字节 = 算法族字节");
        CHECK(encLen == 13 + 16 + 16, "0x02 载荷 = 13 定长头 + salt16 + iv16");
        CHECK(b[encOff + 6] == FPPX2_KDF_PBKDF2_SHA256, "0x02 的 kdf 字节正确");
        CHECK(u32At(b, encOff + 7) == FPPX2_PBKDF2_ITERS_DESKTOP, "0x02 记录了迭代次数");
        CHECK(b[encOff + 11] == FPPX2_MAC_HMAC_SHA256, "0x02 的 macAlgo 字节正确");
        CHECK(macLen == 32, "0x05 载荷 = 32B HMAC-SHA256");
        CHECK(macOff == payOff2 + 5 + payLen2, "0x05 紧随 0x03 之后");
        CHECK(crcOff == macOff + 5 + macLen, "0x04 紧随 0x05 之后");
        CHECK(b[encOff + 5 + 13] != 0 || b[encOff + 5 + 14] != 0, "salt 非全零");
        // 密文长度 = PKCS#7 填充后的 16 字节整数倍，且与明文字节数不同
        CHECK(payLen2 % 16 == 0, "密文长度为 16 的整数倍");
        CHECK(b[payOff2 + 5] != 0x01 || b[payOff2 + 6] != 0x09, "密文开头不是明文内层索引");
        // 介绍模块保持明文（加密设计的有意边界）
        size_t descOff = 0;
        uint32_t descLen = 0;
        CHECK(findMod(b, FPPX2_MODULE_DESC, descOff, descLen), "能定位 0x01");
        std::string desc(reinterpret_cast<const char*>(b.data() + descOff + 5), descLen);
        CHECK(desc == "加密配置", "介绍文本保持明文（设计边界）");
    }

    // ── 14. 空口令一律拒绝 ──
    {
        fs::path p = tmpFile("empty_pwd.fppx");
        Fppx2Result ex = fppx2Export({{"path", p.string()},
                                      {"mode", 1},
                                      {"graph", sampleGraph()},
                                      {"encrypted", true},
                                      {"password", ""}});
        CHECK(!ex.success, "空口令加密导出被拒绝");
        CHECK(!fs::exists(p), "被拒绝时不应留下文件");
    }

    // ── 15. 篡改检测（密文 / 索引 / 截断）──
    {
        fs::path p = tmpFile("tamper_src.fppx");
        Fppx2Result ex = fppx2Export({{"path", p.string()},
                                      {"mode", 1},
                                      {"description", "篡改测试"},
                                      {"graph", sampleGraph()},
                                      {"encrypted", true},
                                      {"password", pwd}});
        CHECK(ex.success, "生成篡改测试源文件");
        std::vector<uint8_t> b = readBin(p);
        size_t payOff = 0, idxOff = 0;
        uint32_t payLen = 0, idxLen = 0;
        findMod(b, FPPX2_MODULE_PAYLOAD, payOff, payLen);
        findMod(b, FPPX2_MODULE_ENCRYPTED, idxOff, idxLen);

        // (a) 翻转密文最后一字节 -> MAC 失配
        {
            std::vector<uint8_t> t = b;
            t[payOff + 5 + payLen - 1] ^= 0x01;
            fs::path tp = tmpFile("tamper_cipher.fppx");
            writeBin(tp, t);
            Fppx2Result r = fppx2Import(tp.string(), false, pwd);
            CHECK(!r.success, "密文被篡改时拒绝导入");
        }
        // (b) 改写索引里 0x03 条目的偏移 -> MAC 覆盖索引，同样失配
        {
            std::vector<uint8_t> t = b;
            const uint32_t k = u32At(t, 15);
            for (uint32_t i = 0; i < k; ++i) {
                const size_t e = 19 + 9 * static_cast<size_t>(i);
                if (t[e] == FPPX2_MODULE_PAYLOAD) t[e + 1] ^= 0x01;
            }
            fs::path tp = tmpFile("tamper_index.fppx");
            writeBin(tp, t);
            Fppx2Result r = fppx2Import(tp.string(), false, pwd);
            CHECK(!r.success, "索引被篡改时拒绝导入（MAC 覆盖索引）");
        }
        // (c) 截断
        {
            std::vector<uint8_t> t(b.begin(), b.begin() + b.size() / 2);
            fs::path tp = tmpFile("tamper_cut.fppx");
            writeBin(tp, t);
            Fppx2Result r = fppx2Import(tp.string(), false, pwd);
            CHECK(!r.success, "截断的加密文件被拒绝");
        }
        // (d) 只改 0x02 的迭代次数 -> 密钥不同 -> 拒绝
        {
            std::vector<uint8_t> t = b;
            t[idxOff + 7] ^= 0x01;
            fs::path tp = tmpFile("tamper_iters.fppx");
            writeBin(tp, t);
            Fppx2Result r = fppx2Import(tp.string(), false, pwd);
            CHECK(!r.success, "篡改迭代次数导致口令校验失败");
        }
    }

    // ── 16. 快速模式（0x02）带内层索引往返 ──
    {
        fs::path p = tmpFile("quick_idx.fppx");
        json items = json::array({{{"key", "input"}, {"params", {{"path", "a.mp4"}}},
                                  {"enabled", true}}});
        Fppx2Result ex = fppx2Export(
            {{"path", p.string()}, {"mode", 2}, {"description", "快速"}, {"quick_items", items}});
        CHECK(ex.success, "快速模式导出成功");
        std::vector<uint8_t> b = readBin(p);
        size_t payOff = 0;
        uint32_t payLen = 0;
        findMod(b, FPPX2_MODULE_PAYLOAD, payOff, payLen);
        CHECK(b[payOff + 5] == 0x01 && b[payOff + 6] == 0x09, "快速模式载荷以内层索引开头");
        Fppx2Result im = fppx2Import(p.string(), false);
        CHECK(im.success && im.quickItems.size() == 1, "快速模式带索引往返一致");

        // 快速模式也能加密
        fs::path pe = tmpFile("quick_enc.fppx");
        Fppx2Result ex2 = fppx2Export({{"path", pe.string()},
                                       {"mode", 2},
                                       {"quick_items", items},
                                       {"encrypted", true},
                                       {"password", pwd}});
        CHECK(ex2.success, "快速模式加密导出成功");
        Fppx2Result np = fppx2Import(pe.string(), false);
        CHECK(!np.success && np.needPassword, "快速模式加密文件需口令");
        Fppx2Result ok = fppx2Import(pe.string(), false, pwd);
        CHECK(ok.success && ok.quickItems.size() == 1, "快速模式加密往返一致");
    }

    // ── 17. 旧版格式不受影响（冻结）──
    {
        fs::path p = tmpFile("legacy_frozen.fppx");
        Fppx2Result ex = fppxLegacyExport({{"path", p.string()},
                                           {"graph", sampleGraph()},
                                           {"description", "旧版"}});
        CHECK(ex.success, "旧版导出仍成功");
        std::vector<uint8_t> b = readBin(p);
        CHECK(b.size() > 6 && b[4] == 1 && b[5] == 2, "旧版第 4/5 字节仍是 configMajor/Minor");
        Fppx2Result im = fppxAutoImport(p.string(), false);
        CHECK(im.success && !im.isNewFormat, "旧版经自动路由仍可导入");
    }

    // ── 18. 索引规则 5 的 32 位回绕：非法条目必须先在结构层被拒（回退线性扫描）──
    {
        auto put = [](std::vector<uint8_t>& v, uint32_t x) {
            v.push_back(static_cast<uint8_t>(x >> 24));
            v.push_back(static_cast<uint8_t>(x >> 16));
            v.push_back(static_cast<uint8_t>(x >> 8));
            v.push_back(static_cast<uint8_t>(x));
        };
        auto mod = [](std::vector<uint8_t>& out, uint8_t id, const std::vector<uint8_t>& pl) {
            out.push_back(id);
            out.push_back(static_cast<uint8_t>(pl.size() >> 24));
            out.push_back(static_cast<uint8_t>(pl.size() >> 16));
            out.push_back(static_cast<uint8_t>(pl.size() >> 8));
            out.push_back(static_cast<uint8_t>(pl.size()));
            out.insert(out.end(), pl.begin(), pl.end());
        };
        std::vector<uint8_t> f = {0x46, 0x50, 0x50, 0x58, 0xFF, 0x02};  // 快速模式
        std::vector<uint8_t> idxPl = {0x01, 0x09, 0x00, 0x00};
        put(idxPl, 3);
        idxPl.push_back(FPPX2_MODULE_INDEX);
        put(idxPl, 6);
        put(idxPl, 13 + 9 * 3);  // entry0 合法（索引自身）
        idxPl.push_back(0x01);
        put(idxPl, 46);
        put(idxPl, 0xFFFFFFF0u);  // entry1：46+size 在 32 位下回绕为 30
        const size_t e2 = idxPl.size();
        idxPl.push_back(FPPX2_MODULE_END);
        put(idxPl, 0);
        put(idxPl, 0);  // entry2 占位（回填真实 END 位置）
        mod(f, FPPX2_MODULE_INDEX, idxPl);
        const size_t afterIndex = f.size();  // = 46
        mod(f, FPPX2_MODULE_DESC, {'d'});
        mod(f, FPPX2_MODULE_ENCRYPTED, {FPPX2_ENCRYPT_NONE});
        std::vector<uint8_t> quickPay = {0x01, 0x09, 0x00, 0x00};
        put(quickPay, 2);
        quickPay.insert(quickPay.end(), 18, 0x00);  // 内层索引条目（读侧不使用）
        put(quickPay, 0);                           // [4B 参数项数 = 0]
        mod(f, FPPX2_MODULE_PAYLOAD, quickPay);
        mod(f, FPPX2_MODULE_CRC32, {0, 0, 0, 0});  // 占位，随后回填
        mod(f, FPPX2_MODULE_END, {});
        const size_t fileSize18 = f.size();
        const size_t crcStart18 = fileSize18 - FPPX2_MODULE_HEADER_LEN - 9;
        CHECK(afterIndex == 46, "回绕用例：索引模块恰为 40 字节");
        // entry2 落在 CRC 覆盖区内 -> 必须在算 CRC 之前回填，否则 CRC 必然失配
        const size_t e = 11 + e2;
        const size_t endOff18 = fileSize18 - FPPX2_MODULE_HEADER_LEN;
        f[e] = FPPX2_MODULE_END;
        f[e + 1] = static_cast<uint8_t>(endOff18 >> 24);
        f[e + 2] = static_cast<uint8_t>(endOff18 >> 16);
        f[e + 3] = static_cast<uint8_t>(endOff18 >> 8);
        f[e + 4] = static_cast<uint8_t>(endOff18);
        f[e + 5] = 0;
        f[e + 6] = 0;
        f[e + 7] = 0;
        f[e + 8] = FPPX2_MODULE_HEADER_LEN;
        const uint32_t crc18 = fppxCrc32(f.data(), crcStart18);
        f[crcStart18 + 5] = static_cast<uint8_t>(crc18 >> 24);
        f[crcStart18 + 6] = static_cast<uint8_t>(crc18 >> 16);
        f[crcStart18 + 7] = static_cast<uint8_t>(crc18 >> 8);
        f[crcStart18 + 8] = static_cast<uint8_t>(crc18);
        fs::path p = tmpFile("idx_overflow.fppx");
        writeBin(p, f);
        Fppx2Result r = fppx2Import(p.string(), false);
        bool fellBack = false;
        for (const auto& w : r.warnings)
            if (w.find("回退线性扫描") != std::string::npos) fellBack = true;
        CHECK(fellBack, "规则5回绕的索引被判结构非法并回退（不再落入越界报错分支）");
        CHECK(r.success && r.mode == 2, "回退后按真实模块序列成功解析");
    }

    // ── 19. 索引条目数上限：K 超限按结构非法回退（防大额 reserve 分配）──
    {
        auto put = [](std::vector<uint8_t>& v, uint32_t x) {
            v.push_back(static_cast<uint8_t>(x >> 24));
            v.push_back(static_cast<uint8_t>(x >> 16));
            v.push_back(static_cast<uint8_t>(x >> 8));
            v.push_back(static_cast<uint8_t>(x));
        };
        auto mod = [](std::vector<uint8_t>& out, uint8_t id, const std::vector<uint8_t>& pl) {
            out.push_back(id);
            out.push_back(static_cast<uint8_t>(pl.size() >> 24));
            out.push_back(static_cast<uint8_t>(pl.size() >> 16));
            out.push_back(static_cast<uint8_t>(pl.size() >> 8));
            out.push_back(static_cast<uint8_t>(pl.size()));
            out.insert(out.end(), pl.begin(), pl.end());
        };
        std::vector<uint8_t> quickPay = {0x01, 0x09, 0x00, 0x00};
        put(quickPay, 2);
        quickPay.insert(quickPay.end(), 18, 0x00);
        put(quickPay, 0);
        struct Mod {
            uint8_t id;
            std::vector<uint8_t> pl;
        };
        std::vector<Mod> mods;
        mods.push_back({FPPX2_MODULE_DESC, {'d'}});
        mods.push_back({FPPX2_MODULE_ENCRYPTED, {FPPX2_ENCRYPT_NONE}});
        for (int i = 0; i < 59; ++i) mods.push_back({0x07, {}});  // 未知模块填充
        mods.push_back({FPPX2_MODULE_PAYLOAD, quickPay});
        mods.push_back({FPPX2_MODULE_CRC32, {0, 0, 0, 0}});
        mods.push_back({FPPX2_MODULE_END, {}});
        const uint32_t K = static_cast<uint32_t>(1 + mods.size());  // 65 > 上限 64
        const size_t idxSize = 5 + 8 + 9 * static_cast<size_t>(K);
        std::vector<uint8_t> idxPl = {0x01, 0x09, 0x00, 0x00};
        put(idxPl, K);
        idxPl.push_back(FPPX2_MODULE_INDEX);
        put(idxPl, 6);
        put(idxPl, static_cast<uint32_t>(idxSize));
        size_t pos = 6 + idxSize;
        for (const Mod& m : mods) {
            idxPl.push_back(m.id);
            put(idxPl, static_cast<uint32_t>(pos));
            put(idxPl, static_cast<uint32_t>(5 + m.pl.size()));
            pos += 5 + m.pl.size();
        }
        CHECK(K == 65, "K 上限用例：条目数 65 > 上限 64");
        std::vector<uint8_t> f = {0x46, 0x50, 0x50, 0x58, 0xFF, 0x02};
        mod(f, FPPX2_MODULE_INDEX, idxPl);
        size_t crcStart = 0;
        for (const Mod& m : mods) {
            if (m.id == FPPX2_MODULE_CRC32) crcStart = f.size();
            mod(f, m.id, m.pl);
        }
        const uint32_t crc19 = fppxCrc32(f.data(), crcStart);
        f[crcStart + 5] = static_cast<uint8_t>(crc19 >> 24);
        f[crcStart + 6] = static_cast<uint8_t>(crc19 >> 16);
        f[crcStart + 7] = static_cast<uint8_t>(crc19 >> 8);
        f[crcStart + 8] = static_cast<uint8_t>(crc19);
        fs::path p = tmpFile("idx_toomany.fppx");
        writeBin(p, f);
        Fppx2Result r = fppx2Import(p.string(), false);
        bool fellBack = false;
        for (const auto& w : r.warnings)
            if (w.find("回退线性扫描") != std::string::npos) fellBack = true;
        CHECK(fellBack, "K 超过上限的索引被判结构非法并回退");
        CHECK(r.success && r.mode == 2, "K 超限回退后仍能按线性扫描解析成功");
    }

    // ── 20. 加密原语公开向量自校（规范 §12）──
    {
        auto toHex = [](const uint8_t* p, size_t n) {
            static const char* h = "0123456789abcdef";
            std::string s;
            for (size_t i = 0; i < n; ++i) {
                s.push_back(h[p[i] >> 4]);
                s.push_back(h[p[i] & 0x0F]);
            }
            return s;
        };
        auto fromHex = [](const std::string& s) {
            std::vector<uint8_t> v;
            auto nib = [](char c) { return c <= '9' ? c - '0' : (c | 0x20) - 'a' + 10; };
            for (size_t i = 0; i + 1 < s.size(); i += 2)
                v.push_back(static_cast<uint8_t>(nib(s[i]) * 16 + nib(s[i + 1])));
            return v;
        };
        {
            uint8_t d[32];
            const char* m = "abc";
            fppx_crypto::sha256(reinterpret_cast<const uint8_t*>(m), 3, d);
            CHECK(toHex(d, 32) ==
                      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
                  "SHA-256(abc) 符合 FIPS 180-4");
        }
        {
            uint8_t d[32];
            const char* k = "Jefe";
            const char* msg = "what do ya want for nothing?";
            fppx_crypto::hmacSha256(reinterpret_cast<const uint8_t*>(k), 4,
                                    reinterpret_cast<const uint8_t*>(msg), 28, d);
            CHECK(toHex(d, 32) ==
                      "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
                  "HMAC-SHA256 符合 RFC 4231 TC2");
        }
        {
            std::vector<uint8_t> salt = fromHex("73616c74");
            std::vector<uint8_t> dk =
                fppx_crypto::pbkdf2HmacSha256("password", salt.data(), salt.size(), 4096, 32);
            CHECK(toHex(dk.data(), dk.size()) ==
                      "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a",
                  "PBKDF2-HMAC-SHA256 符合 RFC 6070 SHA-256 向量");
        }
        {
            std::vector<uint8_t> key = fromHex("000102030405060708090a0b0c0d0e0f");
            std::vector<uint8_t> iv(16, 0);
            std::vector<uint8_t> pt = fromHex("00112233445566778899aabbccddeeff");
            std::vector<uint8_t> ct;
            fppx_crypto::aesCbcEncrypt(fppx_crypto::AesKeyBits::Aes128, key.data(), iv.data(),
                                       pt.data(), pt.size(), ct);
            CHECK(ct.size() >= 16 && toHex(ct.data(), 16) == "69c4e0d86a7b0430d8cdb78070b4c55a",
                  "AES-128 分组符合 FIPS-197 C.1");
        }
        {
            std::vector<uint8_t> key =
                fromHex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4");
            std::vector<uint8_t> iv = fromHex("000102030405060708090a0b0c0d0e0f");
            std::vector<uint8_t> pt =
                fromHex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51"
                        "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710");
            std::vector<uint8_t> ct;
            fppx_crypto::aesCbcEncrypt(fppx_crypto::AesKeyBits::Aes256, key.data(), iv.data(),
                                       pt.data(), pt.size(), ct);
            CHECK(toHex(ct.data(), 64) ==
                      "f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d"
                      "39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b",
                  "AES-256-CBC 4 组符合 NIST SP800-38A F.2.5");
        }
    }

    // ── 21. 读端迭代次数上限（必须"先拒绝"而不是先跑十几秒派生）──
    {
        fs::path p = tmpFile("iters_cap_src.fppx");
        Fppx2Result ex = fppx2Export({{"path", p.string()},
                                      {"mode", 1},
                                      {"description", "迭代上限"},
                                      {"graph", sampleGraph()},
                                      {"encrypted", true},
                                      {"password", pwd}});
        CHECK(ex.success, "生成迭代上限测试源文件");
        std::vector<uint8_t> b = readBin(p);
        size_t payOff = 0, idxOff = 0;
        uint32_t payLen = 0, idxLen = 0;
        findMod(b, FPPX2_MODULE_PAYLOAD, payOff, payLen);
        findMod(b, FPPX2_MODULE_ENCRYPTED, idxOff, idxLen);
        // 0x02 载荷布局 [1B algo][1B kdf][4B iters]...，iters 落在 模块偏移+5+2 起 4 字节
        {
            std::vector<uint8_t> t = b;
            const uint32_t over = FPPX2_PBKDF2_ITERS_MAX + 1; // 0x000F4241
            t[idxOff + 7] = static_cast<uint8_t>(over >> 24);
            t[idxOff + 8] = static_cast<uint8_t>(over >> 16);
            t[idxOff + 9] = static_cast<uint8_t>(over >> 8);
            t[idxOff + 10] = static_cast<uint8_t>(over);
            fs::path tp = tmpFile("iters_cap_over.fppx");
            writeBin(tp, t);
            Fppx2Result r = fppx2Import(tp.string(), false, pwd);
            CHECK(!r.success, "迭代次数超上限时拒绝导入");
            CHECK(!r.errors.empty() && r.errors.front().find("迭代次数") != std::string::npos,
                  "拒绝原因是迭代次数越界（而非先跑完整密钥派生再失败）");
        }
        {
            Fppx2Result r = fppx2Import(p.string(), false, pwd);
            CHECK(r.success, "上限内的默认迭代次数（20 万）照常往返");
        }
    }

    // ── 22. encrypt_algo 先按 int 校验、不收窄截断 ──
    {
        fs::path p = tmpFile("algo_range.fppx");
        // 0x102 收窄到 uint8 后是 0x02（合法值），必须原样拒绝
        Fppx2Result bad = fppx2Export({{"path", p.string()},
                                       {"mode", 1},
                                       {"graph", sampleGraph()},
                                       {"encrypted", true},
                                       {"password", pwd},
                                       {"encrypt_algo", 0x102}});
        CHECK(!bad.success, "encrypt_algo=0x102 被拒绝（不再截断成合法的 0x02）");
        CHECK(!fs::exists(p), "算法非法时不落盘");
        {
            fs::path q1 = tmpFile("algo128.fppx");
            Fppx2Result r1 = fppx2Export({{"path", q1.string()},
                                          {"mode", 1},
                                          {"graph", sampleGraph()},
                                          {"encrypted", true},
                                          {"password", pwd},
                                          {"encrypt_algo", 0x01}});
            CHECK(r1.success, "encrypt_algo=0x01（AES-128-CBC）仍可用");
            fs::path q2 = tmpFile("algo256.fppx");
            Fppx2Result r2 = fppx2Export({{"path", q2.string()},
                                          {"mode", 1},
                                          {"graph", sampleGraph()},
                                          {"encrypted", true},
                                          {"password", pwd},
                                          {"encrypt_algo", 0x02}});
            CHECK(r2.success, "encrypt_algo=0x02（AES-256-CBC）仍可用");
        }
    }

    // ── 23. JSON 输出对非法 UTF-8 免疫 ──
    // description 取自文件 0x01 模块的原始字节，可能不是合法 UTF-8：严格模式 dump()
    // 会抛 type_error.316，表现为"文件明明解析成功却导入失败"。JsonWriter 已切 replace。
    {
        json j = json::object();
        j["description"] = std::string("\xff\xfe bad utf8");
        bool strictThrew = false;
        try {
            (void)j.dump();
        } catch (const std::exception&) {
            strictThrew = true;
        }
        CHECK(strictThrew, "基线：严格模式 dump() 对非法 UTF-8 确实抛异常（兜底确有必要）");
        bool replaceOk = false;
        try {
            replaceOk = !j.dump(-1, ' ', false, json::error_handler_t::replace).empty();
        } catch (const std::exception&) {
            replaceOk = false;
        }
        CHECK(replaceOk, "replace 模式 dump() 不抛异常（JsonWriter 已采用该模式）");
    }

    // ── 24. 描述字段的 UTF-8 校验与 GBK 兜底 ──
    // 写端拒绝非法 UTF-8；读端尽力按 GBK 转码（Windows），否则丢弃 + warning，
    // 不再透传乱码字节给 GUI。
    {
        auto ok = [](const std::string& s) {
            return fppx2IsValidUtf8(reinterpret_cast<const uint8_t*>(s.data()), s.size());
        };
        CHECK(ok(""), "UTF-8 校验：空串合法");
        CHECK(ok("hello 中文 🎬"), "UTF-8 校验：常规中英 + emoji 合法");
        CHECK(ok("\xE4\xB8\xAD"), "UTF-8 校验：三字节序列（中）合法");
        CHECK(!ok("\xFF"), "UTF-8 校验：孤立前缀字节非法");
        CHECK(!ok("\xE4\xB8"), "UTF-8 校验：截断序列非法");
        CHECK(!ok("\xC0\x80"), "UTF-8 校验：超长编码（C0 80）非法");
        CHECK(!ok("\xED\xA0\x80"), "UTF-8 校验：代理区（U+D800）非法");
        CHECK(!ok("\xF4\x90\x80\x80"), "UTF-8 校验：越界（U+110000）非法");
        CHECK(!ok(std::string("ab\xFF\xFE", 4)), "UTF-8 校验：混入非法字节非法");

        // 写端：description 含非法字节 → fppx2Export 拒绝
        {
            Fppx2Result r = fppx2Export(json{
                {"path", tmpFile("enc_desc_bad.fppx").string()},
                {"mode", 1},
                {"description", std::string("bad \xFF desc")},
                {"graph", json::object()}});
            CHECK(!r.success && !r.errors.empty(),
                  "导出：description 含非法 UTF-8 被拒绝写盘");
        }
        // 读端兜底由导入路径调用 fppx2IsValidUtf8（GBK 转码在 Windows 分支），
        // 校验函数向量已覆盖判定本身；端到端 GBK 用例依赖本地代码页，不在此断言。
    }

    std::printf("== %d passed, %d failed ==\n", g_passed, g_failed);
    return g_failed == 0 ? 0 : 1;
}
