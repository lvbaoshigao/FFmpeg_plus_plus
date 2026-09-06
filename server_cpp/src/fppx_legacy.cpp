#include "fppx_legacy.h"

#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#endif

#include "fppx2_format.h"
#include "fppx_gzip.h"
#include "fppx_validate.h"
#include "node_registry.h"

namespace ffmpegpp {

using json = nlohmann::json;
namespace fd = fppx_detail;

namespace {

// 与 fppx2.cpp 相同的 UTF-8 路径转换（两个编译单元各自持有，避免引内部头）
std::filesystem::path legacyUtf8ToPath(const std::string& p) {
#ifdef _WIN32
    if (p.empty()) return {};
    int wlen = MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, nullptr, 0);
    if (wlen <= 0) return std::filesystem::path(p);
    std::wstring w(static_cast<size_t>(wlen), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, p.c_str(), -1, w.data(), wlen);
    while (!w.empty() && w.back() == L'\0') w.pop_back();
    return std::filesystem::path(w);
#else
    return std::filesystem::path(p);
#endif
}

bool readFileBytes(const std::string& path, std::vector<uint8_t>& out, std::string& err) {
    std::ifstream f(legacyUtf8ToPath(path), std::ios::binary);
    if (!f) {
        err = "无法打开文件: " + path;
        return false;
    }
    f.seekg(0, std::ios::end);
    std::streamoff n = f.tellg();
    if (n < 0 || n > (256LL << 20)) {
        err = "文件大小异常（上限 256MB）";
        return false;
    }
    f.seekg(0, std::ios::beg);
    out.resize(static_cast<size_t>(n));
    if (n > 0) f.read(reinterpret_cast<char*>(out.data()), n);
    if (!f) {
        err = "读取文件失败: " + path;
        return false;
    }
    return true;
}

bool writeFileBytes(const std::string& path, const std::vector<uint8_t>& data, std::string& err) {
    std::ofstream f(legacyUtf8ToPath(path), std::ios::binary | std::ios::trunc);
    if (!f) {
        err = "无法写入文件（路径不可用或被占用）: " + path;
        return false;
    }
    if (!data.empty()) f.write(reinterpret_cast<const char*>(data.data()), data.size());
    f.flush();
    if (!f) {
        err = "写入文件失败（磁盘满或无权限）: " + path;
        return false;
    }
    return true;
}

} // namespace

Fppx2Result fppxLegacyExport(const json& params) {
    Fppx2Result r;
    r.mode = LEGACY_MODE_NODE_EDITOR;

    std::string path = params.value("path", std::string(""));
    if (path.empty()) {
        r.errors.push_back("缺少保存路径 path");
        return r;
    }
    std::string description = params.value("description", std::string(""));
    if (!params.contains("graph") || !params["graph"].is_object() ||
        !params["graph"].contains("nodes") || !params["graph"]["nodes"].is_array()) {
        r.errors.push_back("缺少节点图数据 graph.nodes");
        return r;
    }
    const json& graph = params["graph"];

    // 导出前校验（与新版共用同一套图语义检查；张冠李戴对旧格式只警告，
    // 旧格式没有注册表概念，历史文件里可能存在未登记键）
    std::vector<fd::VNode> vnodes;
    std::vector<std::string> warnings;
    fd::buildVNodesFromJson(graph["nodes"], vnodes, r.errors, warnings);
    if (!r.errors.empty()) {
        r.warnings = warnings;
        return r;
    }
    std::map<std::string, int> uuidToFile;
    for (size_t i = 0; i < vnodes.size(); ++i) uuidToFile[vnodes[i].uuid] = static_cast<int>(i);
    std::vector<fd::VEdge> edges;
    if (graph.contains("connections") && graph["connections"].is_array()) {
        for (const auto& c : graph["connections"]) {
            std::string from = c.value("from", std::string(""));
            std::string to = c.value("to", std::string(""));
            auto fi = uuidToFile.find(from), ti = uuidToFile.find(to);
            if (fi == uuidToFile.end() || ti == uuidToFile.end()) {
                r.errors.push_back("连线引用了不存在的节点: " + fd::shortId(from) + " → " +
                                   fd::shortId(to));
                continue;
            }
            edges.push_back({fi->second, ti->second,
                             c.value("kind", std::string("data")) == "control"});
        }
    }
    fd::validateGraphSemantics(vnodes, edges, r.errors, r.warnings);
    if (!r.errors.empty()) return r;

    // 数据区：gzip(JSON) —— 与 Dart gzip.encode(utf8(jsonEncode(graph))) 等价
    std::string jsonStr = graph.dump();
    std::vector<uint8_t> compressed = gzipCompress(
        reinterpret_cast<const uint8_t*>(jsonStr.data()), jsonStr.size());
    if (compressed.empty()) {
        r.errors.push_back("gzip 压缩失败");
        return r;
    }

    // 文件布局（与 Dart _buildFile 逐字节一致）
    std::vector<uint8_t> file;
    const uint8_t magic[4] = {0x46, 0x50, 0x50, 0x58}; // "FPPX"
    file.insert(file.end(), magic, magic + 4);
    file.push_back(LEGACY_CONFIG_MAJOR);
    file.push_back(LEGACY_CONFIG_MINOR);
    file.push_back(LEGACY_MIN_SOFTWARE_MAJOR);
    file.push_back(LEGACY_COMPAT_MAJOR_COUNT);
    file.push_back(LEGACY_MODE_NODE_EDITOR);
    // 描述长度（2B 大端）+ 描述
    std::string descBytes = description; // UTF-8
    if (descBytes.size() > 0xFFFF) descBytes.resize(0xFFFF);
    file.push_back(static_cast<uint8_t>((descBytes.size() >> 8) & 0xFF));
    file.push_back(static_cast<uint8_t>(descBytes.size() & 0xFF));
    file.insert(file.end(), descBytes.begin(), descBytes.end());
    // 数据长度（4B 大端）+ gzip 数据
    uint32_t dataLen = static_cast<uint32_t>(compressed.size());
    for (int i = 3; i >= 0; --i)
        file.push_back(static_cast<uint8_t>((dataLen >> (8 * i)) & 0xFF));
    file.insert(file.end(), compressed.begin(), compressed.end());

    std::string err;
    if (!writeFileBytes(path, file, err)) {
        r.errors.push_back(err);
        return r;
    }
    r.success = true;
    return r;
}

Fppx2Result fppxLegacyImport(const std::string& path) {
    Fppx2Result r;

    std::vector<uint8_t> bytes;
    std::string err;
    if (!readFileBytes(path, bytes, err)) {
        r.errors.push_back(err);
        return r;
    }
    if (bytes.size() < 11) {
        r.errors.push_back("文件太小，不是有效的 FPPX 配置");
        return r;
    }
    const uint8_t magic[4] = {0x46, 0x50, 0x50, 0x58};
    if (std::memcmp(bytes.data(), magic, 4) != 0) {
        r.errors.push_back("不是 FPPX 配置文件（魔数不匹配）");
        return r;
    }
    if (bytes[4] == FPPX2_MARKER) {
        r.errors.push_back("这是新版 FPPX 配置（请使用新版导入）");
        return r;
    }

    uint8_t configMajor = bytes[4];
    uint8_t configMinor = bytes[5];
    uint8_t minSw = bytes[6];
    uint8_t compatCount = bytes[7];
    uint8_t mode = bytes[8];
    r.mode = mode;
    r.encrypted = false;

    uint16_t descLen = static_cast<uint16_t>((bytes[9] << 8) | bytes[10]);
    if (bytes.size() < 11 + static_cast<size_t>(descLen) + 4) {
        r.errors.push_back("文件被截断（描述区或数据长度不完整）");
        return r;
    }
    r.description.assign(reinterpret_cast<const char*>(bytes.data()) + 11, descLen);
    size_t dataLenOffset = 11 + descLen;
    uint32_t dataLen = 0;
    for (int i = 0; i < 4; ++i)
        dataLen = (dataLen << 8) | bytes[dataLenOffset + i];
    if (bytes.size() < dataLenOffset + 4 + static_cast<size_t>(dataLen)) {
        r.errors.push_back("文件被截断（数据区声明 " + std::to_string(dataLen) + " 字节）");
        return r;
    }

    // 软件版本兼容（与 Dart import 相同的判定与文案）
    bool versionOk = LEGACY_CURRENT_SOFTWARE_MAJOR >= minSw &&
                     LEGACY_CURRENT_SOFTWARE_MAJOR <= minSw + compatCount;
    if (!versionOk) {
        r.errors.push_back("软件版本不兼容: 配置要求 v" + std::to_string(minSw) + ".x~v" +
                           std::to_string(minSw + compatCount) + ".x，当前 v" +
                           std::to_string(LEGACY_CURRENT_SOFTWARE_MAJOR) + ".0");
    }
    bool isHigherConfig = configMajor > LEGACY_CONFIG_MAJOR ||
                          (configMajor == LEGACY_CONFIG_MAJOR && configMinor > LEGACY_CONFIG_MINOR);
    if (isHigherConfig) {
        r.warnings.push_back("此配置由更高版本创建 (v" + std::to_string(configMajor) + "." +
                             std::to_string(configMinor) + ")，当前支持 v" +
                             std::to_string(LEGACY_CONFIG_MAJOR) + "." +
                             std::to_string(LEGACY_CONFIG_MINOR) + "，部分功能可能不兼容");
    }

    // 解压 + JSON 解析
    std::vector<uint8_t> plain;
    std::string gzErr;
    if (!gzipDecompress(bytes.data() + dataLenOffset + 4, dataLen, plain, gzErr)) {
        r.errors.push_back("配置解压失败: " + gzErr);
        return r;
    }
    json parsed;
    try {
        parsed = json::parse(plain.begin(), plain.end());
    } catch (const std::exception&) {
        r.errors.push_back("配置 JSON 解析失败");
        return r;
    }

    if (mode == LEGACY_MODE_NODE_EDITOR) {
        // 未知节点类型检查（与 Dart 相同的判定与文案）
        std::set<std::string> knownTypes;
        // 注册表覆盖全部 PipelineStepType 名 + 门（门在旧格式 JSON 里 type 也是 start）
        for (const auto& n : parsed.value("nodes", json::array())) {
            std::string typeName = n.value("type", std::string(""));
            std::string gate = n.value("gate", n.value("gateType", std::string("")));
            bool okType = false;
            if (findTypeByName(typeName)) okType = true;
            if (!gate.empty() && findGateByName(gate)) okType = true;
            if (typeName.empty()) okType = true; // 缺 type 交给 GUI fromJson 兜底
            if (!okType)
                r.errors.push_back("不支持的节点类型: \"" + typeName + "\"（可能来自更高版本的软件）");
        }
        if (!r.errors.empty()) return r;
        // 图语义校验（导入侧只警告不阻断？与旧版行为不同——旧版不校验。
        // 为兼容旧行为：这里只跑张冠李戴级别检查，语义错误由 GUI GraphExecutor 报）
        r.graph = parsed;
        r.success = true;
        return r;
    }

    // 旧版非节点编辑器载荷（Dart 行为：存入 legacyConfig 由 GUI 拒绝）
    r.legacy = parsed;
    r.success = true;
    return r;
}

} // namespace ffmpegpp
