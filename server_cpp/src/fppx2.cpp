#include "fppx2.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <map>
#include <set>

#include <filesystem>

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

// ═══════════════════════════════════════════════
// 基础工具
// ═══════════════════════════════════════════════

namespace {

// GUI 传来的是 UTF-8 路径；Windows 文件 API 需要宽字符才能正确处理中文路径
std::filesystem::path utf8ToPath(const std::string& p) {
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
    std::ifstream f(utf8ToPath(path), std::ios::binary);
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
    std::ofstream f(utf8ToPath(path), std::ios::binary | std::ios::trunc);
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

// ── 大端写入器 ──
class ByteWriter {
public:
    std::vector<uint8_t> buf;

    size_t pos() const { return buf.size(); }
    void u8(uint8_t v) { buf.push_back(v); }
    void u32(uint32_t v) {
        for (int i = 3; i >= 0; --i) buf.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xFF));
    }
    void patchU32(size_t at, uint32_t v) {
        for (int i = 0; i < 4; ++i)
            buf[at + i] = static_cast<uint8_t>((v >> (8 * (3 - i))) & 0xFF);
    }
    void raw(const uint8_t* p, size_t n) { buf.insert(buf.end(), p, p + n); }
    void rawStr(const std::string& s) { raw(reinterpret_cast<const uint8_t*>(s.data()), s.size()); }
};

// ── 大端读取器（带边界检查，越界后 ok() 为 false）──
class ByteReader {
public:
    ByteReader(const uint8_t* d, size_t n, size_t start = 0) : d_(d), n_(n), p_(start) {}
    bool ok() const { return ok_; }
    bool atEnd() const { return p_ >= n_; }
    size_t remaining() const { return p_ <= n_ ? n_ - p_ : 0; }
    size_t pos() const { return p_; }

    uint8_t u8() {
        if (p_ >= n_) {
            ok_ = false;
            return 0;
        }
        return d_[p_++];
    }
    uint32_t u32() {
        if (p_ + 4 > n_) {
            ok_ = false;
            return 0;
        }
        uint32_t v = 0;
        for (int i = 0; i < 4; ++i) v = (v << 8) | d_[p_ + i];
        p_ += 4;
        return v;
    }
    void bytes16(uint8_t out[16]) {
        if (p_ + 16 > n_) {
            ok_ = false;
            return;
        }
        std::memcpy(out, d_ + p_, 16);
        p_ += 16;
    }
    const uint8_t* peek(size_t len) {
        if (p_ + len > n_) {
            ok_ = false;
            return nullptr;
        }
        const uint8_t* r = d_ + p_;
        p_ += len;
        return r;
    }
    void skip(size_t k) {
        if (p_ + k > n_) {
            ok_ = false;
            p_ = n_;
        } else
            p_ += k;
    }

private:
    const uint8_t* d_;
    size_t n_;
    size_t p_;
    bool ok_ = true;
};

// ── 模块写入助手（统计回填）──
void writeModuleBytes(ByteWriter& w, uint8_t id, const std::vector<uint8_t>& payload) {
    w.u8(id);
    w.u32(static_cast<uint32_t>(payload.size()));
    w.raw(payload.data(), payload.size());
}

// 连线块：[4B 块大小][4B 对端数 K][K × 4B 对端文件 ID]
// 块大小 = 尺寸字段之后的字节数 = 4 + 4K（与导入端 skip(bs-4-4K) 口径一致）
void writeConnBlock(ByteWriter& w, const std::vector<int>& peers) {
    size_t sizePos = w.pos();
    w.u32(0);
    w.u32(static_cast<uint32_t>(peers.size()));
    for (int p : peers) w.u32(static_cast<uint32_t>(p));
    w.patchU32(sizePos, static_cast<uint32_t>(w.pos() - sizePos - 4));
}

// ═══════════════════════════════════════════════
// 0x01 模式：节点图 ↔ 模块 0x03
// ═══════════════════════════════════════════════

// GUI 节点 JSON → 16B 类型 ID；返回 nullptr 表示未知类型
const NodeTypeSpec* specForGuiNode(const json& n, uint64_t& unknownId, std::string& err) {
    std::string type = n.value("type", std::string(""));
    std::string gate = n.value("gate", std::string(""));
    unknownId = 0;
    if (type == "unknown") {
        unknownId = n.value("type_id", static_cast<uint64_t>(0));
        if (unknownId == 0) err = "未知节点缺少 type_id";
        return nullptr;
    }
    if (!gate.empty()) {
        const NodeTypeSpec* g = findGateByName(gate);
        if (!g) err = "未知的逻辑门类型: " + gate;
        return g;
    }
    const NodeTypeSpec* t = findTypeByName(type);
    if (!t) err = "未知的节点类型: " + type;
    return t;
}

void serializeNodeGraph(ByteWriter& w, const json& graph, const std::vector<fd::VNode>& vnodes,
                        const std::map<std::string, int>& uuidToFile,
                        const std::vector<fd::VEdge>& edges, Fppx2Result& r) {
    const json& nodesJson = graph["nodes"];

    // 连线 → 每节点四块（①左逻辑入 ②右数据出 ③左数据入 ④右逻辑出）
    std::vector<std::array<std::vector<int>, FPPX2_CONN_BLOCK_COUNT>> blocks(vnodes.size());
    for (const auto& e : edges) {
        if (e.control) {
            blocks[e.from][FPPX2_BLOCK_CTRL_OUT].push_back(e.to);
            blocks[e.to][FPPX2_BLOCK_CTRL_IN].push_back(e.from);
        } else {
            blocks[e.from][FPPX2_BLOCK_DATA_OUT].push_back(e.to);
            blocks[e.to][FPPX2_BLOCK_DATA_IN].push_back(e.from);
        }
    }

    w.u32(static_cast<uint32_t>(vnodes.size()));
    for (size_t i = 0; i < vnodes.size(); ++i) {
        const fd::VNode& v = vnodes[i];
        uint64_t unknownId = 0;
        std::string err;
        const NodeTypeSpec* spec =
            vnodes[i].isUnknown ? nullptr : specForGuiNode(nodesJson[i], unknownId, err);
        NodeTypeId tid = v.isUnknown ? makeTypeId(v.typeIdInt) : (spec ? spec->id : NodeTypeId{});
        w.raw(tid.data(), 16);

        size_t sizePos = w.pos();
        w.u32(0);                      // 记录剩余大小 S（统计后回填）
        size_t recStart = sizePos + 4; // S 的统计起点（节点文件 ID 起）
        w.u32(static_cast<uint32_t>(v.fileId));

        for (int b = 0; b < FPPX2_CONN_BLOCK_COUNT; ++b) writeConnBlock(w, blocks[i][b]);

        // 属性区：{id, params, x, y}（gate 由 16B 类型 ID 隐含，不再重复存储）
        json attr;
        attr["id"] = v.uuid;
        attr["params"] = nodesJson[i].value("params", json::object());
        attr["x"] = nodesJson[i].value("x", 0.0);
        attr["y"] = nodesJson[i].value("y", 0.0);
        std::string attrStr = attr.dump();
        w.u32(static_cast<uint32_t>(attrStr.size()));
        w.rawStr(attrStr);

        w.patchU32(sizePos, static_cast<uint32_t>(w.pos() - recStart));
    }

    // 逻辑块分组：文件内存 child_ids（文件 ID），GUI JSON 用 childNodeIds（UUID）
    json lbs = graph.contains("logicBlocks") ? graph["logicBlocks"] : json::array();
    json normBlocks = fd::validateLogicBlocks(lbs, uuidToFile, vnodes, r.errors);
    w.u32(static_cast<uint32_t>(normBlocks.size()));
    for (const auto& lb : normBlocks) {
        json fileBlock = lb;
        json childIds = json::array();
        for (const auto& cuuid : lb.value("childNodeIds", json::array())) {
            auto it = uuidToFile.find(cuuid.get<std::string>());
            if (it != uuidToFile.end()) childIds.push_back(it->second);
        }
        fileBlock["child_ids"] = childIds;
        fileBlock.erase("childNodeIds");
        std::string s = fileBlock.dump();
        w.u32(static_cast<uint32_t>(s.size()));
        w.rawStr(s);
    }
}

bool parseNodeGraph(const std::vector<uint8_t>& payload, bool force, Fppx2Result& r) {
    ByteReader rd(payload.data(), payload.size());
    uint32_t n = rd.u32();
    if (!rd.ok()) {
        r.errors.push_back("节点数量字段不完整，逻辑块内容已损坏");
        return false;
    }
    if (n > rd.remaining() / 44 + 1) {
        r.errors.push_back("节点数量异常（声明 " + std::to_string(n) +
                           " 个，超出载荷容量）");
        return false;
    }

    std::vector<fd::VNode> vnodes(n);
    std::vector<json> nodeJsons(n);
    std::vector<std::array<std::vector<int>, FPPX2_CONN_BLOCK_COUNT>> blocks(n);
    std::set<uint32_t> fids;
    std::set<std::string> unknownSeen;

    for (uint32_t i = 0; i < n; ++i) {
        NodeTypeId tid{};
        rd.bytes16(tid.data());
        uint32_t recSize = rd.u32();
        size_t recStart = rd.pos();
        if (!rd.ok()) {
            r.errors.push_back("节点记录被截断（第 " + std::to_string(i) + " 个）");
            return false;
        }
        uint32_t fid = rd.u32();
        if (fids.count(fid)) {
            r.errors.push_back("节点文件 ID 重复: " + std::to_string(fid));
            return false;
        }
        fids.insert(fid);

        // 连线四块
        for (int b = 0; b < FPPX2_CONN_BLOCK_COUNT; ++b) {
            uint32_t bs = rd.u32();
            uint32_t k = rd.u32();
            if (!rd.ok() || bs < 4 + 4 * k) {
                r.errors.push_back("连线块大小异常（节点 " + std::to_string(fid) + "）");
                return false;
            }
            if (bs > 4 + 4 * k)
                r.warnings.push_back("连线块含未知扩展数据（" +
                                     std::to_string(bs - 4 - 4 * k) + " 字节），已跳过");
            for (uint32_t p = 0; p < k; ++p) {
                uint32_t peer = rd.u32();
                if (peer >= n) {
                    r.errors.push_back("连线引用了不存在的节点文件 ID: " +
                                       std::to_string(peer));
                    return false;
                }
                blocks[i][b].push_back(static_cast<int>(peer));
            }
            rd.skip(bs - 4 - 4 * k);
        }

        // 属性区
        uint32_t asz = rd.u32();
        const uint8_t* attrRaw = rd.peek(asz);
        if (!rd.ok() || !attrRaw) {
            r.errors.push_back("节点属性区被截断（节点 " + std::to_string(fid) + "）");
            return false;
        }
        json attr;
        try {
            attr = json::parse(attrRaw, attrRaw + asz);
        } catch (const std::exception&) {
            r.errors.push_back("节点属性 JSON 解析失败（节点 " + std::to_string(fid) + "）");
            return false;
        }

        size_t consumed = rd.pos() - recStart;
        if (consumed != recSize) {
            r.errors.push_back("节点记录大小不一致（声明 " + std::to_string(recSize) + "，实际 " +
                               std::to_string(consumed) + "，节点 " + std::to_string(fid) + "）");
            return false;
        }

        // 类型解析
        fd::VNode v;
        v.uuid = attr.value("id", std::string(""));
        if (v.uuid.empty()) v.uuid = fd::genUuid();
        v.fileId = static_cast<int>(fid);
        const NodeTypeSpec* t = findTypeById(tid);
        const NodeTypeSpec* g = findGateById(tid);
        if (t && !t->isGate) {
            v.spec = t;
            v.isStart = (t->name == std::string("start"));
            v.isOutput = (t->name == std::string("output"));
            if (v.isStart) v.mediaOut = fd::startMediaOut(attr.value("params", json::object()));
            v.label = t->zhLabel;
        } else if (g) {
            v.spec = g;
            v.label = g->zhLabel;
        } else {
            v.isUnknown = true;
            v.typeIdInt = 0;
            for (int by = 0; by < 16; ++by) v.typeIdInt = (v.typeIdInt << 8) | tid[by];
            v.label = "未知节点(" + typeIdToDec(tid) + ")";
            if (unknownSeen.insert(typeIdToDec(tid)).second)
                r.unknownTypeIds.push_back(typeIdToDec(tid));
        }
        vnodes[i] = v;

        json& nj = nodeJsons[i];
        nj["id"] = v.uuid;
        nj["params"] = attr.value("params", json::object());
        nj["x"] = attr.value("x", 0.0);
        nj["y"] = attr.value("y", 0.0);
        if (v.spec && v.spec->isGate) {
            nj["type"] = "start"; // 门节点在 GUI 中 type 固定占位为 start
            nj["gate"] = v.spec->gateName;
        } else if (v.isUnknown) {
            nj["type"] = "unknown";
            nj["type_id"] = v.typeIdInt;
        } else if (v.spec) {
            nj["type"] = v.spec->name;
        }
    }

    // 文件 ID 必须恰好覆盖 0..n-1（"从 0 开始"）
    for (uint32_t i = 0; i < n; ++i) {
        if (!fids.count(i)) {
            r.errors.push_back("节点文件 ID 不连续：缺少 " + std::to_string(i));
            return false;
        }
    }

    // 强制导入确认门：存在未知节点且未确认强制导入时，返回 unknownTypeIds 而不出图
    if (!r.unknownTypeIds.empty() && !force) {
        r.success = true; // graph 保持 null，GUI 据此弹确认框
        return true;
    }

    // 连线镜像交叉验证（A 的②含 B ⇔ B 的③含 A；①④同理）
    auto contains = [](const std::vector<int>& v, int x) {
        return std::find(v.begin(), v.end(), x) != v.end();
    };
    for (uint32_t i = 0; i < n; ++i) {
        for (int j : blocks[i][FPPX2_BLOCK_DATA_OUT]) {
            if (!contains(blocks[j][FPPX2_BLOCK_DATA_IN], static_cast<int>(i))) {
                r.errors.push_back("节点「" + vnodes[i].label + "」与「" + vnodes[j].label +
                                   "」的数据连线记录互不一致");
            }
        }
        for (int j : blocks[i][FPPX2_BLOCK_CTRL_OUT]) {
            if (!contains(blocks[j][FPPX2_BLOCK_CTRL_IN], static_cast<int>(i))) {
                r.errors.push_back("节点「" + vnodes[i].label + "」与「" + vnodes[j].label +
                                   "」的控制连线记录互不一致");
            }
        }
        for (int j : blocks[i][FPPX2_BLOCK_DATA_IN]) {
            if (!contains(blocks[j][FPPX2_BLOCK_DATA_OUT], static_cast<int>(i))) {
                r.errors.push_back("节点「" + vnodes[i].label + "」与「" + vnodes[j].label +
                                   "」的数据连线记录互不一致");
            }
        }
        for (int j : blocks[i][FPPX2_BLOCK_CTRL_IN]) {
            if (!contains(blocks[j][FPPX2_BLOCK_CTRL_OUT], static_cast<int>(i))) {
                r.errors.push_back("节点「" + vnodes[i].label + "」与「" + vnodes[j].label +
                                   "」的控制连线记录互不一致");
            }
        }
    }
    if (!r.errors.empty()) return false;

    // 重建连线（去重）
    std::vector<fd::VEdge> edges;
    std::set<std::pair<int, int>> seenData, seenCtrl;
    for (uint32_t i = 0; i < n; ++i) {
        for (int j : blocks[i][FPPX2_BLOCK_DATA_OUT]) {
            if (seenData.insert({static_cast<int>(i), j}).second)
                edges.push_back({static_cast<int>(i), j, false});
        }
        for (int j : blocks[i][FPPX2_BLOCK_CTRL_OUT]) {
            if (seenCtrl.insert({static_cast<int>(i), j}).second)
                edges.push_back({static_cast<int>(i), j, true});
        }
    }

    // 导入侧张冠李戴只警告（写入侧才是强制关卡）
    for (uint32_t i = 0; i < n; ++i) {
        const fd::VNode& v = vnodes[i];
        if (v.isUnknown) continue;
        json params = nodeJsons[i].value("params", json::object());
        const char* gateName = (v.spec && v.spec->isGate) ? v.spec->gateName : nullptr;
        for (auto it = params.begin(); it != params.end(); ++it) {
            ParamKeyClass c = classifyParamKey(it.key(), v.spec, gateName);
            if (c == PKC_MISMATCH)
                r.warnings.push_back("节点「" + v.label + "」携带了不属于它的参数「" +
                                     it.key() + "」（张冠李戴），已保留原值");
            else if (c == PKC_UNLISTED)
                r.warnings.push_back("参数「" + it.key() + "」未在注册表登记，按新版本参数处理");
        }
    }

    // 图语义校验
    fd::validateGraphSemantics(vnodes, edges, r.errors, r.warnings);

    // 逻辑块分组
    uint32_t m = rd.u32();
    if (!rd.ok()) {
        r.errors.push_back("逻辑块数量字段不完整");
        return false;
    }
    std::map<std::string, int> uuidToFile;
    for (uint32_t i = 0; i < n; ++i) uuidToFile[nodeJsons[i]["id"].get<std::string>()] = i;
    json lbs = json::array();
    for (uint32_t b = 0; b < m; ++b) {
        uint32_t bs = rd.u32();
        const uint8_t* raw = rd.peek(bs);
        if (!rd.ok() || !raw) {
            r.errors.push_back("逻辑块分组被截断");
            return false;
        }
        json lb;
        try {
            lb = json::parse(raw, raw + bs);
        } catch (const std::exception&) {
            r.errors.push_back("逻辑块 JSON 解析失败");
            return false;
        }
        // 文件里是 child_ids（文件 ID），转回 GUI 的 childNodeIds（UUID）
        json guiLb = lb;
        json childUuids = json::array();
        if (lb.contains("child_ids") && lb["child_ids"].is_array()) {
            for (const auto& cfi : lb["child_ids"]) {
                uint32_t cfileId = cfi.get<uint32_t>();
                if (cfileId >= n) {
                    r.errors.push_back("逻辑块引用了不存在的节点文件 ID: " +
                                       std::to_string(cfileId));
                    continue;
                }
                childUuids.push_back(nodeJsons[cfileId]["id"].get<std::string>());
            }
        }
        guiLb["childNodeIds"] = childUuids;
        lbs.push_back(guiLb);
    }
    json normBlocks = fd::validateLogicBlocks(lbs, uuidToFile, vnodes, r.errors);

    // 连线 → GUI JSON（形状与 PipelineConnection.fromJson 对齐）
    json conns = json::array();
    int ci = 0;
    for (const auto& e : edges) {
        conns.push_back({{"id", "conn_" + std::to_string(ci++)},
                         {"from", vnodes[e.from].uuid},
                         {"to", vnodes[e.to].uuid},
                         {"kind", e.control ? "control" : "data"}});
    }

    r.graph = json::object();
    r.graph["nodes"] = nodeJsons;
    r.graph["connections"] = conns;
    r.graph["logicBlocks"] = normBlocks;
    return true;
}

bool parseQuickItems(const std::vector<uint8_t>& payload, Fppx2Result& r) {
    ByteReader rd(payload.data(), payload.size());
    uint32_t k = rd.u32();
    if (!rd.ok()) {
        r.errors.push_back("参数项数量字段不完整");
        return false;
    }
    r.quickItems = json::array();
    for (uint32_t i = 0; i < k; ++i) {
        uint32_t sz = rd.u32();
        const uint8_t* raw = rd.peek(sz);
        if (!rd.ok() || !raw) {
            r.errors.push_back("第 " + std::to_string(i + 1) + " 个参数项被截断");
            return false;
        }
        json item;
        try {
            item = json::parse(raw, raw + sz);
        } catch (const std::exception&) {
            r.errors.push_back("第 " + std::to_string(i + 1) + " 个参数项 JSON 解析失败");
            return false;
        }
        std::string key = item.value("key", std::string(""));
        if (key.empty()) {
            r.errors.push_back("参数项缺少 key（第 " + std::to_string(i + 1) + " 项）");
            continue;
        }
        if (!isKnownQuickKey(key))
            r.warnings.push_back("快速参数「" + key + "」未登记，按新版本参数处理");
        json norm = {{"key", key},
                     {"params", item.value("params", json::object())},
                     {"enabled", item.value("enabled", true)}};
        r.quickItems.push_back(norm);
    }
    return true;
}

} // namespace

// ═══════════════════════════════════════════════
// 对外接口
// ═══════════════════════════════════════════════

json Fppx2Result::toJson() const {
    json j;
    j["success"] = success;
    j["mode"] = mode;
    j["description"] = description;
    j["encrypted"] = encrypted;
    j["is_new_format"] = isNewFormat;
    j["graph"] = graph;
    j["quick_items"] = quickItems;
    j["legacy"] = legacy;
    j["errors"] = errors;
    j["warnings"] = warnings;
    j["unknown_type_ids"] = unknownTypeIds;
    j["forced"] = forced;
    return j;
}

Fppx2Result fppx2Export(const json& params) {
    Fppx2Result r;
    std::string path = params.value("path", std::string(""));
    if (path.empty()) {
        r.errors.push_back("缺少保存路径 path");
        return r;
    }
    int mode = params.value("mode", static_cast<int>(FPPX2_MODE_NODE_EDITOR));
    if (mode != FPPX2_MODE_NODE_EDITOR && mode != FPPX2_MODE_QUICK) {
        char mb[8];
        std::snprintf(mb, sizeof(mb), "%02x", mode);
        r.errors.push_back(std::string("不支持的配置模式: 0x") + mb);
        return r;
    }
    r.mode = mode;
    r.description = params.value("description", std::string(""));

    // 加密占位：本版只允许未加密
    if (params.value("encrypted", false)) {
        r.errors.push_back("加密功能尚未实现（本版仅保留格式占位，请保持关闭）");
        return r;
    }

    // ── 导出前校验（写入前关卡），通过后才落盘 ──
    ByteWriter w;
    w.raw(FPPX_MAGIC, 4);
    w.u8(FPPX2_MARKER);
    w.u8(static_cast<uint8_t>(mode));

    // 模块 0x01 介绍
    w.u8(FPPX2_MODULE_DESC);
    w.u32(static_cast<uint32_t>(r.description.size()));
    w.rawStr(r.description);
    // 模块 0x02 是否加密（恒 0x00）
    w.u8(FPPX2_MODULE_ENCRYPTED);
    w.u32(1);
    w.u8(FPPX2_ENCRYPT_NONE);

    if (mode == FPPX2_MODE_NODE_EDITOR) {
        if (!params.contains("graph") || !params["graph"].is_object() ||
            !params["graph"].contains("nodes") || !params["graph"]["nodes"].is_array()) {
            r.errors.push_back("缺少节点图数据 graph.nodes");
            return r;
        }
        const json& graph = params["graph"];
        std::vector<fd::VNode> vnodes;
        fd::buildVNodesFromJson(graph["nodes"], vnodes, r.errors, r.warnings);
        if (!r.errors.empty()) return r; // 节点缺 id/type 等硬错误，直接拒绝

        std::map<std::string, int> uuidToFile;
        for (size_t i = 0; i < vnodes.size(); ++i)
            uuidToFile[vnodes[i].uuid] = static_cast<int>(i);

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

        // 张冠李戴检查（写入前强制关卡）
        for (size_t i = 0; i < vnodes.size(); ++i) {
            const fd::VNode& v = vnodes[i];
            if (v.isUnknown) {
                r.warnings.push_back("包含未知节点类型 ID " + std::to_string(v.typeIdInt) +
                                     "，将原样保留（仅本机可编辑）");
                continue;
            }
            json nodeParams = graph["nodes"][i].value("params", json::object());
            const char* gateName = (v.spec && v.spec->isGate) ? v.spec->gateName : nullptr;
            for (auto it = nodeParams.begin(); it != nodeParams.end(); ++it) {
                ParamKeyClass c = classifyParamKey(it.key(), v.spec, gateName);
                if (c == PKC_MISMATCH)
                    r.errors.push_back("节点「" + v.label + "」的参数「" + it.key() +
                                       "」不属于该节点类型（张冠李戴）");
                else if (c == PKC_UNLISTED)
                    r.warnings.push_back("参数「" + it.key() + "」未在注册表登记，按新版本参数写入");
            }
        }

        fd::validateGraphSemantics(vnodes, edges, r.errors, r.warnings);

        if (!r.errors.empty()) return r; // 校验失败，拒绝写文件

        // 模块 0x03 逻辑块内容
        {
            ByteWriter payload;
            serializeNodeGraph(payload, graph, vnodes, uuidToFile, edges, r);
            if (!r.errors.empty()) return r;
            writeModuleBytes(w, FPPX2_MODULE_PAYLOAD, payload.buf);
        }
    } else {
        // 0x02 快速模式：只存命令参数项
        if (!params.contains("quick_items") || !params["quick_items"].is_array()) {
            r.errors.push_back("缺少快速参数数据 quick_items");
            return r;
        }
        ByteWriter payload;
        const json& items = params["quick_items"];
        payload.u32(static_cast<uint32_t>(items.size()));
        for (const auto& item : items) {
            std::string key = item.value("key", std::string(""));
            if (key.empty()) {
                r.errors.push_back("快速参数项缺少 key");
                continue;
            }
            if (!isKnownQuickKey(key))
                r.warnings.push_back("快速参数「" + key + "」未登记，按新版本参数写入");
            json norm = {{"key", key},
                         {"params", item.value("params", json::object())},
                         {"enabled", item.value("enabled", true)}};
            std::string s = norm.dump();
            payload.u32(static_cast<uint32_t>(s.size()));
            payload.rawStr(s);
        }
        if (!r.errors.empty()) return r;
        writeModuleBytes(w, FPPX2_MODULE_PAYLOAD, payload.buf);
    }

    // 模块 0x04 CRC32（对文件开头至本模块之前的所有字节——先算再写模块头，
    // 与导入端 [0, 模块 ID 字节偏移) 的计算口径一致）
    {
        uint32_t crcVal = fppxCrc32(w.buf.data(), w.buf.size());
        w.u8(FPPX2_MODULE_CRC32);
        w.u32(4);
        w.u32(crcVal);
    }
    // 模块 0xFF 结尾
    w.u8(FPPX2_MODULE_END);
    w.u32(0);

    std::string err;
    if (!writeFileBytes(path, w.buf, err)) {
        r.errors.push_back(err);
        return r;
    }

    // 写入后自校验（重读解析必须成功，否则删除残缺文件）
    Fppx2Result verify = fppx2Import(path, false);
    if (!verify.success || verify.mode != mode) {
        std::string first = verify.errors.empty() ? "未知原因" : verify.errors.front();
        r.errors.push_back("写入后自校验失败，已删除不完整文件: " + first);
        std::filesystem::remove(utf8ToPath(path), std::error_code{});
        return r;
    }

    r.success = true;
    r.encrypted = false;
    return r;
}

Fppx2Result fppx2Import(const std::string& path, bool force) {
    Fppx2Result r;
    r.forced = force;

    std::vector<uint8_t> bytes;
    std::string err;
    if (!readFileBytes(path, bytes, err)) {
        r.errors.push_back(err);
        return r;
    }
    if (bytes.size() < 6) {
        r.errors.push_back("文件太小，不是有效的 FPPX 配置");
        return r;
    }
    if (std::memcmp(bytes.data(), FPPX_MAGIC, 4) != 0) {
        r.errors.push_back("不是 FPPX 配置文件（魔数不匹配）");
        return r;
    }
    if (bytes[4] != FPPX2_MARKER) {
        r.errors.push_back("这是旧版 FPPX 配置（请使用旧版导入）");
        return r;
    }
    uint8_t mode = bytes[5];
    if (mode != FPPX2_MODE_NODE_EDITOR && mode != FPPX2_MODE_QUICK) {
        char mb[8];
        std::snprintf(mb, sizeof(mb), "%02x", mode);
        r.errors.push_back(std::string("未知的配置模式: 0x") + mb);
        return r;
    }
    r.mode = mode;

    // ── 模块序列解析 ──
    bool sawDesc = false, sawEnc = false, sawPayload = false, sawCrc = false, sawEnd = false;
    uint8_t encVal = FPPX2_ENCRYPT_NONE;
    size_t crcStart = 0;
    uint32_t crcStored = 0;
    std::vector<uint8_t> payload;
    ByteReader rd(bytes.data(), bytes.size(), 6);

    while (!rd.atEnd() && !sawEnd) {
        size_t moduleStart = rd.pos();
        uint8_t id = rd.u8();
        uint32_t sz = rd.u32();
        if (!rd.ok()) {
            r.errors.push_back("模块头不完整，文件被截断");
            return r;
        }
        if (rd.remaining() < sz) {
            char mb[8];
            std::snprintf(mb, sizeof(mb), "%02x", id);
            r.errors.push_back(std::string("模块 0x") + mb + " 的载荷声明 " + std::to_string(sz) +
                               " 字节，超出文件末尾（文件被截断）");
            return r;
        }
        switch (id) {
            case FPPX2_MODULE_DESC: {
                if (sawDesc) {
                    r.warnings.push_back("介绍模块重复，已忽略后者");
                    rd.skip(sz);
                    break;
                }
                const uint8_t* d = rd.peek(sz);
                if (d) r.description.assign(reinterpret_cast<const char*>(d), sz);
                sawDesc = true;
                break;
            }
            case FPPX2_MODULE_ENCRYPTED: {
                if (sawEnc) {
                    r.warnings.push_back("加密标记模块重复，已忽略后者");
                    rd.skip(sz);
                    break;
                }
                if (sz != 1) {
                    r.errors.push_back("加密标记模块大小异常（应为 1 字节）");
                    return r;
                }
                encVal = rd.u8();
                sawEnc = true;
                break;
            }
            case FPPX2_MODULE_PAYLOAD: {
                if (sawPayload) {
                    r.warnings.push_back("逻辑块内容模块重复，已忽略后者");
                    rd.skip(sz);
                    break;
                }
                const uint8_t* d = rd.peek(sz);
                if (d) payload.assign(d, d + sz);
                sawPayload = true;
                break;
            }
            case FPPX2_MODULE_CRC32: {
                if (sawCrc) {
                    rd.skip(sz);
                    break;
                }
                if (sz != 4) {
                    r.errors.push_back("CRC32 模块大小异常（应为 4 字节）");
                    return r;
                }
                crcStart = moduleStart;
                crcStored = rd.u32();
                sawCrc = true;
                break;
            }
            case FPPX2_MODULE_END: {
                if (sz != 0) {
                    r.errors.push_back("结尾标记的载荷应为空");
                    return r;
                }
                sawEnd = true;
                break;
            }
            default: {
                char mb[8];
                std::snprintf(mb, sizeof(mb), "%02x", id);
                r.warnings.push_back(std::string("遇到未知模块 0x") + mb +
                                     "（可能由更高版本软件创建），已跳过 " + std::to_string(sz) +
                                     " 字节");
                rd.skip(sz);
                break;
            }
        }
    }

    if (!sawEnd) {
        r.errors.push_back("缺少结尾标记，文件可能被截断或损坏");
        return r;
    }
    if (!rd.atEnd()) {
        r.errors.push_back("结尾标记之后存在 " + std::to_string(rd.remaining()) + " 字节多余数据");
        return r;
    }
    if (!sawPayload) {
        r.errors.push_back("缺少逻辑块内容模块（0x03）");
        return r;
    }
    if (!sawDesc) r.warnings.push_back("缺少介绍模块，按空介绍处理");
    if (!sawEnc) {
        r.warnings.push_back("缺少加密标记模块，按未加密处理");
    } else if (encVal != FPPX2_ENCRYPT_NONE) {
        char mb[8];
        std::snprintf(mb, sizeof(mb), "%02x", encVal);
        r.errors.push_back(std::string("暂不支持的加密方式: 0x") + mb +
                           "（可能由更高版本软件创建）");
        return r;
    }
    if (sawCrc) {
        uint32_t actual = fppxCrc32(bytes.data(), crcStart);
        if (actual != crcStored) {
            char a[8], b2[8];
            std::snprintf(a, sizeof(a), "%08x", actual);
            std::snprintf(b2, sizeof(b2), "%08x", crcStored);
            r.errors.push_back(std::string("CRC32 校验失败（期望 0x") + b2 + "，实际 0x" + a +
                               "），文件已损坏");
            return r;
        }
    } else {
        r.warnings.push_back("缺少 CRC32 校验模块，跳过完整性校验");
    }

    bool ok = (mode == FPPX2_MODE_NODE_EDITOR) ? parseNodeGraph(payload, force, r)
                                               : parseQuickItems(payload, r);
    if (!ok) return r; // parse 内部已填 errors
    r.success = true;
    r.encrypted = false;
    return r;
}

Fppx2Result fppxAutoImport(const std::string& path, bool force) {
    // 只看文件头 6 字节判别格式，完整解析交给对应导入器
    std::vector<uint8_t> bytes;
    std::string err;
    if (!readFileBytes(path, bytes, err)) {
        Fppx2Result r;
        r.errors.push_back(err);
        return r;
    }
    if (bytes.size() < 6 || std::memcmp(bytes.data(), FPPX_MAGIC, 4) != 0) {
        Fppx2Result r;
        r.errors.push_back("不是 FPPX 配置文件（魔数不匹配）");
        return r;
    }
    Fppx2Result r = (bytes[4] == FPPX2_MARKER) ? fppx2Import(path, force)
                                               : fppxLegacyImport(path);
    r.isNewFormat = (bytes[4] == FPPX2_MARKER);
    return r;
}

} // namespace ffmpegpp
