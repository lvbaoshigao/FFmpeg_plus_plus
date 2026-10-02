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
#include "fppx_crypto.h"
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


// ═══════════════════════════════════════════════
// 索引模块 0x00（通用规则：凡大小不固定的容器，都在其开头放索引）
//   顶层（模块序列）与 0x03 载荷内部（内层索引）共用同一结构、同一偏移口径：
//   一律「从文件首字节起算的绝对偏移」。内层条目指向的是该元素在【明文坐标】
//   中的落点（= 0x03 模块载荷起始 + 载荷内相对偏移）；加密后密文仍落在同一
//   起始位置，故该绝对偏移在加密前后都有意义。
// ═══════════════════════════════════════════════

struct FppxIndexEntry {
    uint8_t id = 0;
    uint32_t offset = 0;
    uint32_t size = 0;
};

// 识别 0x03 载荷开头的内层索引，返回记录区起始偏移（无索引时返回 0）。
// 判定依据：前 4 字节恒为 01 09 00 00（版本1/步长9/保留0）。
// 老 v2 文件此处是 [4B 节点数]，N >= 0x01090000 在现实中不可能，故无歧义；
// 结构非法时同样返回 0 按无索引处理，保住老文件（索引是加速层，非必需层）。
size_t innerIndexSkip(const std::vector<uint8_t>& payload) {
    if (payload.size() < FPPX2_INDEX_HEADER_LEN) return 0;
    if (payload[0] != FPPX2_INDEX_VERSION) return 0;
    if (payload[1] != FPPX2_INDEX_STRIDE) return 0;
    if (payload[2] != 0 || payload[3] != 0) return 0;
    const uint32_t k = (static_cast<uint32_t>(payload[4]) << 24) |
                       (static_cast<uint32_t>(payload[5]) << 16) |
                       (static_cast<uint32_t>(payload[6]) << 8) |
                       static_cast<uint32_t>(payload[7]);
    if (k == 0 || k > FPPX2_INDEX_MAX_ENTRIES) return 0;
    const size_t skip = FPPX2_INDEX_HEADER_LEN + FPPX2_INDEX_STRIDE * k;
    if (skip >= payload.size()) return 0;
    return skip;
}

// 索引模块总长（含 5B 模块头）= 13 + 9K
inline size_t fppxIndexModuleSize(size_t k) {
    return FPPX2_MODULE_HEADER_LEN + FPPX2_INDEX_HEADER_LEN + FPPX2_INDEX_STRIDE * k;
}

void buildIndexPayload(ByteWriter& out, const std::vector<FppxIndexEntry>& entries) {
    out.u8(FPPX2_INDEX_VERSION);
    out.u8(FPPX2_INDEX_STRIDE);
    out.u8(0);
    out.u8(0); // 2B 保留
    out.u32(static_cast<uint32_t>(entries.size()));
    for (const FppxIndexEntry& e : entries) {
        out.u8(e.id);
        out.u32(e.offset);
        out.u32(e.size);
    }
}

// 解析索引载荷并执行规范 §4.3 的校验；任一条不成立返回 false（调用方回退线性扫描）
bool parseIndexPayload(const uint8_t* p, size_t n, size_t fileSize,
                       std::vector<FppxIndexEntry>& out) {
    out.clear();
    if (n < FPPX2_INDEX_HEADER_LEN) return false;
    if (p[0] != FPPX2_INDEX_VERSION) return false;
    if (p[1] != FPPX2_INDEX_STRIDE) return false;
    if (p[2] != 0 || p[3] != 0) return false;
    uint32_t k = (static_cast<uint32_t>(p[4]) << 24) | (static_cast<uint32_t>(p[5]) << 16) |
                 (static_cast<uint32_t>(p[6]) << 8) | static_cast<uint32_t>(p[7]);
    if (FPPX2_INDEX_HEADER_LEN + static_cast<size_t>(k) * FPPX2_INDEX_STRIDE != n) return false;
    if (k == 0) return false;
    // 条目数上限：K 与实际载荷长度挂钩（规则3），但上限仍必要 —— 否则一个
    // 256MB 文件可令 reserve 申请约 340MB（12B/条），放大内存占用。超限按结构非法
    // 处理（回退线性扫描），真机 K 恒为 6/7，不受影响。
    if (k > FPPX2_INDEX_MAX_ENTRIES) return false;
    out.reserve(k);
    size_t q = FPPX2_INDEX_HEADER_LEN;
    for (uint32_t i = 0; i < k; ++i) {
        FppxIndexEntry e;
        e.id = p[q];
        e.offset = (static_cast<uint32_t>(p[q + 1]) << 24) | (static_cast<uint32_t>(p[q + 2]) << 16) |
                   (static_cast<uint32_t>(p[q + 3]) << 8) | static_cast<uint32_t>(p[q + 4]);
        e.size = (static_cast<uint32_t>(p[q + 5]) << 24) | (static_cast<uint32_t>(p[q + 6]) << 16) |
                 (static_cast<uint32_t>(p[q + 7]) << 8) | static_cast<uint32_t>(p[q + 8]);
        q += FPPX2_INDEX_STRIDE;
        out.push_back(e);
    }
    // 规则 4：第 0 条记录索引自身（offset 恒为 6 = 文件头长度）
    if (out[0].id != FPPX2_MODULE_INDEX) return false;
    if (out[0].offset != 6) return false;
    if (out[0].size != fppxIndexModuleSize(k)) return false;
    // 规则 5：偏移严格递增且不重叠
    for (size_t i = 1; i < out.size(); ++i) {
        if (out[i].size == 0) return false;
        // 用 64 位求和不回绕：否则恶意条目（size≈0xFFFFFFF0）可让上一条的
        // offset+size 在 32 位下回绕，从而骗过“偏移严格递增且不重叠”这条校验。
        if (out[i].offset < static_cast<uint64_t>(out[i - 1].offset) + out[i - 1].size)
            return false;
    }
    // 规则 6：末条恰好收在文件末尾，且必须是 0xFF 结尾模块
    const FppxIndexEntry& last = out.back();
    if (last.id != FPPX2_MODULE_END) return false;
    if (static_cast<size_t>(last.offset) + last.size != fileSize) return false;
    return true;
}

// ═══════════════════════════════════════════════
// 模块 0x02 加密信息
// ═══════════════════════════════════════════════

struct FppxEncInfo {
    uint8_t algo = FPPX2_ENCRYPT_NONE;
    uint8_t kdf = FPPX2_KDF_PBKDF2_SHA256;
    uint32_t iters = 0;
    uint8_t macAlgo = FPPX2_MAC_NONE;
    uint16_t macLen = 0;
    std::vector<uint8_t> salt;
    std::vector<uint8_t> iv;
};

inline bool algoIsAes128(uint8_t algo) { return algo == FPPX2_ALGO_AES128_CBC; }
inline bool algoIsEncrypted(uint8_t algo) { return algo != FPPX2_ENCRYPT_NONE; }

inline size_t fppxEncInfoModuleSize(size_t encPayloadLen) {
    return FPPX2_MODULE_HEADER_LEN + encPayloadLen;
}

std::string hexByte(uint8_t v) {
    char b[8];
    std::snprintf(b, sizeof(b), "%02x", v);
    return std::string(b);
}

// 解析 0x02 载荷。旧形态（长度 1、值 0x00）必须继续可读。
bool parseEncInfo(const uint8_t* p, size_t n, FppxEncInfo& out, std::string& err) {
    if (n == 1) {
        if (p[0] != FPPX2_ENCRYPT_NONE) {
            err = "暂不支持的加密方式: 0x" + hexByte(p[0]) + "（可能由更高版本软件创建）";
            return false;
        }
        out = FppxEncInfo{};
        return true;
    }
    if (n < FPPX2_ENCINFO_FIXED_LEN) {
        err = "加密信息模块大小异常（应为 1 或 >= 13 字节）";
        return false;
    }
    out = FppxEncInfo{};
    out.algo = p[0];
    out.kdf = p[1];
    out.iters = (static_cast<uint32_t>(p[2]) << 24) | (static_cast<uint32_t>(p[3]) << 16) |
                (static_cast<uint32_t>(p[4]) << 8) | static_cast<uint32_t>(p[5]);
    out.macAlgo = p[6];
    uint16_t saltLen = static_cast<uint16_t>((p[7] << 8) | p[8]);
    uint16_t ivLen = static_cast<uint16_t>((p[9] << 8) | p[10]);
    out.macLen = static_cast<uint16_t>((p[11] << 8) | p[12]);
    if (!algoIsEncrypted(out.algo) || out.algo == FPPX2_ALGO_AES128_GCM ||
        out.algo == FPPX2_ALGO_AES256_GCM) {
        err = "暂不支持的加密方式: 0x" + hexByte(out.algo) + "（可能由更高版本软件创建）";
        return false;
    }
    if (out.kdf != FPPX2_KDF_PBKDF2_SHA256) {
        err = "不支持的密钥派生算法: 0x" + hexByte(out.kdf);
        return false;
    }
    if (out.iters == 0 || out.iters > FPPX2_PBKDF2_ITERS_MAX) {
        err = "密钥派生迭代次数越界";
        return false;
    }
    if (out.macAlgo != FPPX2_MAC_HMAC_SHA256) {
        err = "不支持的认证算法（本版须为 HMAC-SHA256）";
        return false;
    }
    if (out.macLen != FPPX2_MAC_LEN_SHA256) {
        err = "认证标签长度异常";
        return false;
    }
    if (saltLen == 0 || saltLen > FPPX2_ENCINFO_MAX_SALT) {
        err = "salt 长度越界";
        return false;
    }
    if (ivLen != 16) {
        err = "IV 长度异常（CBC 须为 16 字节）";
        return false;
    }
    const size_t need = FPPX2_ENCINFO_FIXED_LEN + static_cast<size_t>(saltLen) + ivLen;
    if (need > n) {
        err = "加密信息模块被截断";
        return false;
    }
    // need < n：尾部为将来扩展字段（如 verifier），按未知扩展忽略（规范 §6.8）
    out.salt.assign(p + FPPX2_ENCINFO_FIXED_LEN, p + FPPX2_ENCINFO_FIXED_LEN + saltLen);
    out.iv.assign(p + FPPX2_ENCINFO_FIXED_LEN + saltLen,
                  p + FPPX2_ENCINFO_FIXED_LEN + saltLen + ivLen);
    return true;
}

// PBKDF2 → 加密密钥 + MAC 密钥（AES-128: 16+32；AES-256: 32+32）
bool deriveKeys(const std::string& password, const FppxEncInfo& info,
                std::vector<uint8_t>& encKey, std::vector<uint8_t>& macKey) {
    const size_t keyLen = algoIsAes128(info.algo) ? 16 : 32;
    std::vector<uint8_t> dk = fppx_crypto::pbkdf2HmacSha256(
        password, info.salt.data(), info.salt.size(), info.iters, keyLen + 32);
    if (dk.size() != keyLen + 32) return false;
    encKey.assign(dk.begin(), dk.begin() + static_cast<long>(keyLen));
    macKey.assign(dk.begin() + static_cast<long>(keyLen), dk.end());
    return true;
}

inline fppx_crypto::AesKeyBits aesBitsOf(uint8_t algo) {
    return algoIsAes128(algo) ? fppx_crypto::AesKeyBits::Aes128
                              : fppx_crypto::AesKeyBits::Aes256;
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

// plaintextStart：本次导出中 0x03 模块【载荷】的绝对文件偏移（= 模块偏移 + 5）。
// 内层索引记的是绝对偏移（规范 §5.4），故写端必须知道自己的落点。
void serializeNodeGraph(ByteWriter& out, size_t plaintextStart, const json& graph,
                        const std::vector<fd::VNode>& vnodes,
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

    // ── ① 节点记录区（结构不变：[4B N] + N 条记录）──
    ByteWriter recW;
    recW.u32(static_cast<uint32_t>(vnodes.size()));
    for (size_t i = 0; i < vnodes.size(); ++i) {
        const fd::VNode& v = vnodes[i];
        uint64_t unknownId = 0;
        std::string err;
        const NodeTypeSpec* spec =
            vnodes[i].isUnknown ? nullptr : specForGuiNode(nodesJson[i], unknownId, err);
        NodeTypeId tid = v.isUnknown ? makeTypeId(v.typeIdInt) : (spec ? spec->id : NodeTypeId{});
        recW.raw(tid.data(), 16);

        size_t sizePos = recW.pos();
        recW.u32(0);                      // 记录剩余大小 S（统计后回填）
        size_t recStart = sizePos + 4;    // S 的统计起点（节点文件 ID 起）
        recW.u32(static_cast<uint32_t>(v.fileId));

        for (int b = 0; b < FPPX2_CONN_BLOCK_COUNT; ++b) writeConnBlock(recW, blocks[i][b]);

        // 属性区：{id, params, x, y}（gate 由 16B 类型 ID 隐含，不再重复存储）
        json attr;
        attr["id"] = v.uuid;
        attr["params"] = nodesJson[i].value("params", json::object());
        attr["x"] = nodesJson[i].value("x", 0.0);
        attr["y"] = nodesJson[i].value("y", 0.0);
        std::string attrStr = attr.dump();
        recW.u32(static_cast<uint32_t>(attrStr.size()));
        recW.rawStr(attrStr);

        recW.patchU32(sizePos, static_cast<uint32_t>(recW.pos() - recStart));
    }

    // ── ② 逻辑块区（结构不变：[4B M] + M 条）──
    // 文件内存 child_ids（文件 ID），GUI JSON 用 childNodeIds（UUID）
    json lbs = graph.contains("logicBlocks") ? graph["logicBlocks"] : json::array();
    json normBlocks = fd::validateLogicBlocks(lbs, uuidToFile, vnodes, r.errors);
    ByteWriter lbW;
    lbW.u32(static_cast<uint32_t>(normBlocks.size()));
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
        lbW.u32(static_cast<uint32_t>(s.size()));
        lbW.rawStr(s);
    }

    // ── ③ 内层索引（无 5B 模块头，尺寸 = 8 + 9K）+ 两区拼接 ──
    const size_t kInner = 3;
    const size_t innerSize = FPPX2_INDEX_HEADER_LEN + FPPX2_INDEX_STRIDE * kInner;
    std::vector<FppxIndexEntry> entries;
    entries.push_back({FPPX2_MODULE_INDEX, static_cast<uint32_t>(plaintextStart),
                       static_cast<uint32_t>(innerSize)});
    entries.push_back({FPPX2_INNER_NODE_RECORDS,
                       static_cast<uint32_t>(plaintextStart + innerSize),
                       static_cast<uint32_t>(recW.buf.size())});
    entries.push_back({FPPX2_INNER_LOGIC_BLOCKS,
                       static_cast<uint32_t>(plaintextStart + innerSize + recW.buf.size()),
                       static_cast<uint32_t>(lbW.buf.size())});
    buildIndexPayload(out, entries);
    out.raw(recW.buf.data(), recW.buf.size());
    out.raw(lbW.buf.data(), lbW.buf.size());
}

bool parseNodeGraph(const std::vector<uint8_t>& payload, bool force, Fppx2Result& r) {
    const size_t innerSkip = innerIndexSkip(payload);
    ByteReader rd(payload.data(), payload.size(), innerSkip);
    uint32_t n = rd.u32();
    if (!rd.ok()) {
        r.errors.push_back("节点数量字段不完整，逻辑块内容已损坏");
        return false;
    }
    // 单条节点记录的最小字节数：
    //   16B 类型 ID + 4B recSize + 4B fileId + 4×(4B 块大小 + 4B 计数) + 4B 属性长度 = 60B
    // 旧实现用 /44 作为上限，比真实下界低估约 36%，可让 256MB 恶意文件触发
    // 约 600 万个节点的 vector 分配（数 GB 级），导致 OOM（M-3）。
    constexpr uint32_t kMinNodeRecordBytes = 60;
    if (n > rd.remaining() / kMinNodeRecordBytes) {
        r.errors.push_back("节点数量异常（声明 " + std::to_string(n) +
                           " 个，超出载荷容量）");
        return false;
    }
    // 额外硬上限：任何真实工程的节点数都远低于此值
    constexpr uint32_t kMaxNodes = 200000;
    if (n > kMaxNodes) {
        r.errors.push_back("节点数量超出上限（" + std::to_string(n) + " > " +
                           std::to_string(kMaxNodes) + "）");
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
            // [FIX M-17] 用 64 位计算 4 + 4*k，防止 uint32 回绕绕过校验；限制条目数上限
            // 防 OOM；并要求 peer 表大小不超过声明块大小与实际剩余可读字节。
            constexpr uint32_t kMaxConnections = 1u << 20;
            const uint64_t need = 4ull + 4ull * static_cast<uint64_t>(k);
            if (!rd.ok() || k > kMaxConnections ||
                need > static_cast<uint64_t>(bs) ||
                need > static_cast<uint64_t>(rd.remaining())) {
                r.errors.push_back("连线块大小异常（节点 " + std::to_string(fid) + "）");
                return false;
            }
            if (bs > need)
                r.warnings.push_back("连线块含未知扩展数据（" +
                                     std::to_string(bs - static_cast<uint32_t>(need)) + " 字节），已跳过");
            for (uint32_t p = 0; p < k; ++p) {
                uint32_t peer = rd.u32();
                if (peer >= n) {
                    r.errors.push_back("连线引用了不存在的节点文件 ID: " +
                                       std::to_string(peer));
                    return false;
                }
                blocks[i][b].push_back(static_cast<int>(peer));
            }
            rd.skip(bs - static_cast<uint32_t>(need));
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
    const size_t innerSkip = innerIndexSkip(payload);
    ByteReader rd(payload.data(), payload.size(), innerSkip);
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
    j["need_password"] = needPassword;
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
    r.encrypted = params.value("encrypted", false);
    // 介绍（0x01 载荷）按原始字节写入文件：非合法 UTF-8 一律拒绝，
    // 不让乱码字节进入存档（GUI 侧 JSON 通道理论上是合法 UTF-8，此为防线）
    if (!r.description.empty() &&
        !fppx2IsValidUtf8(reinterpret_cast<const uint8_t*>(r.description.data()),
                          r.description.size())) {
        r.errors.push_back("描述字段不是合法的 UTF-8 文本，已拒绝写入");
        return r;
    }

    // ── 加密参数校验：空口令一律拒绝（避免"以为加密了其实没加"）──
    std::string password = params.value("password", std::string(""));
    FppxEncInfo encInfo;
    if (r.encrypted) {
        if (password.empty()) {
            r.errors.push_back("已启用加密但未提供口令（空口令一律拒绝）");
            return r;
        }
        // 先按 int 校验再收窄：否则 0x102 这类值会被 static_cast 截断成"合法"的 0x02
        const int algoRaw = params.value("encrypt_algo", static_cast<int>(FPPX2_ALGO_AES256_CBC));
        if (algoRaw != FPPX2_ALGO_AES128_CBC && algoRaw != FPPX2_ALGO_AES256_CBC) {
            r.errors.push_back("不支持的加密算法: " + std::to_string(algoRaw));
            return r;
        }
        const uint8_t algo = static_cast<uint8_t>(algoRaw);
        encInfo.algo = algo;
        encInfo.kdf = FPPX2_KDF_PBKDF2_SHA256;
        encInfo.iters = FPPX2_PBKDF2_ITERS_DESKTOP;
        encInfo.macAlgo = FPPX2_MAC_HMAC_SHA256;
        encInfo.macLen = FPPX2_MAC_LEN_SHA256;
        encInfo.salt.resize(16);
        encInfo.iv.resize(16);
        if (!fppx_crypto::randomBytes(encInfo.salt.data(), encInfo.salt.size()) ||
            !fppx_crypto::randomBytes(encInfo.iv.data(), encInfo.iv.size())) {
            r.errors.push_back("无法获取密码学安全随机数（salt/IV 生成失败）");
            return r;
        }
    }

    // ── 布局预算：索引长度只取决于模块个数 K，与载荷大小无关，故可先行定稿 ──
    const size_t moduleCount = r.encrypted ? 7 : 6;
    const size_t indexSize = fppxIndexModuleSize(moduleCount);
    const size_t descModuleSize = FPPX2_MODULE_HEADER_LEN + r.description.size();
    const size_t encPayloadLen = r.encrypted
        ? (FPPX2_ENCINFO_FIXED_LEN + encInfo.salt.size() + encInfo.iv.size())
        : 1;
    const size_t encModuleSize = fppxEncInfoModuleSize(encPayloadLen);
    const uint32_t descOffset = static_cast<uint32_t>(6 + indexSize);
    const uint32_t encOffset = static_cast<uint32_t>(descOffset + descModuleSize);
    const uint32_t payloadOffset = static_cast<uint32_t>(encOffset + encModuleSize);
    const uint32_t plaintextStart = payloadOffset + FPPX2_MODULE_HEADER_LEN;

    // ── 校验并序列化 0x03 载荷（明文；内层索引记绝对偏移，故需 plaintextStart）──
    ByteWriter payloadPlain;
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

        serializeNodeGraph(payloadPlain, plaintextStart, graph, vnodes, uuidToFile, edges, r);
        if (!r.errors.empty()) return r;
    } else {
        // 0x02 快速模式：只存命令参数项
        if (!params.contains("quick_items") || !params["quick_items"].is_array()) {
            r.errors.push_back("缺少快速参数数据 quick_items");
            return r;
        }
        ByteWriter itemW;
        const json& items = params["quick_items"];
        itemW.u32(static_cast<uint32_t>(items.size()));
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
            itemW.u32(static_cast<uint32_t>(s.size()));
            itemW.rawStr(s);
        }
        if (!r.errors.empty()) return r;

        // 内层索引（无模块头，尺寸 = 8 + 9K）+ 参数项区
        const size_t kInner = 2;
        const size_t innerSize = FPPX2_INDEX_HEADER_LEN + FPPX2_INDEX_STRIDE * kInner;
        std::vector<FppxIndexEntry> inner;
        inner.push_back({FPPX2_MODULE_INDEX, plaintextStart, static_cast<uint32_t>(innerSize)});
        inner.push_back({FPPX2_INNER_QUICK_ITEMS,
                         static_cast<uint32_t>(plaintextStart + innerSize),
                         static_cast<uint32_t>(itemW.buf.size())});
        buildIndexPayload(payloadPlain, inner);
        payloadPlain.raw(itemW.buf.data(), itemW.buf.size());
    }

    // ── 加密 0x03 载荷（仅载荷；元数据与索引保持明文）──
    std::vector<uint8_t> encKey, macKey;
    std::vector<uint8_t> payloadBytes = payloadPlain.buf;
    if (r.encrypted) {
        if (!deriveKeys(password, encInfo, encKey, macKey)) {
            r.errors.push_back("密钥派生失败（PBKDF2 输出长度异常）");
            return r;
        }
        std::vector<uint8_t> cipher;
        if (!fppx_crypto::aesCbcEncrypt(aesBitsOf(encInfo.algo), encKey.data(), encInfo.iv.data(),
                                        payloadPlain.buf.data(), payloadPlain.buf.size(), cipher)) {
            r.errors.push_back("载荷加密失败");
            return r;
        }
        payloadBytes.swap(cipher);
    }

    // ── 落定全部模块偏移与大小（索引条目）──
    const uint32_t payloadModuleSize =
        static_cast<uint32_t>(FPPX2_MODULE_HEADER_LEN + payloadBytes.size());
    const uint32_t macOffset = payloadOffset + payloadModuleSize;
    const uint32_t macModuleSize =
        static_cast<uint32_t>(FPPX2_MODULE_HEADER_LEN + FPPX2_MAC_LEN_SHA256);
    const uint32_t crcOffset = r.encrypted ? macOffset + macModuleSize : macOffset;
    const uint32_t crcModuleSize = FPPX2_MODULE_HEADER_LEN + 4;
    const uint32_t endOffset = crcOffset + crcModuleSize;

    std::vector<FppxIndexEntry> idx;
    idx.push_back({FPPX2_MODULE_INDEX, 6, static_cast<uint32_t>(indexSize)});
    idx.push_back({FPPX2_MODULE_DESC, descOffset, static_cast<uint32_t>(descModuleSize)});
    idx.push_back({FPPX2_MODULE_ENCRYPTED, encOffset, static_cast<uint32_t>(encModuleSize)});
    idx.push_back({FPPX2_MODULE_PAYLOAD, payloadOffset, payloadModuleSize});
    if (r.encrypted) idx.push_back({FPPX2_MODULE_MAC, macOffset, macModuleSize});
    idx.push_back({FPPX2_MODULE_CRC32, crcOffset, crcModuleSize});
    idx.push_back({FPPX2_MODULE_END, endOffset, FPPX2_MODULE_HEADER_LEN});

    // ── 两趟写入：文件头 → 索引 → 介绍 → 加密信息 → 载荷 → [MAC] → CRC → 结尾 ──
    ByteWriter w;
    w.raw(FPPX_MAGIC, 4);
    w.u8(FPPX2_MARKER);
    w.u8(static_cast<uint8_t>(mode));

    {
        ByteWriter idxPayload;
        buildIndexPayload(idxPayload, idx);
        writeModuleBytes(w, FPPX2_MODULE_INDEX, idxPayload.buf);
    }
    writeModuleBytes(w, FPPX2_MODULE_DESC,
                     std::vector<uint8_t>(r.description.begin(), r.description.end()));
    {
        ByteWriter encPayload;
        if (r.encrypted) {
            encPayload.u8(encInfo.algo);
            encPayload.u8(encInfo.kdf);
            encPayload.u32(encInfo.iters);
            encPayload.u8(encInfo.macAlgo);
            encPayload.u8(static_cast<uint8_t>(encInfo.salt.size() >> 8));
            encPayload.u8(static_cast<uint8_t>(encInfo.salt.size() & 0xFF));
            encPayload.u8(static_cast<uint8_t>(encInfo.iv.size() >> 8));
            encPayload.u8(static_cast<uint8_t>(encInfo.iv.size() & 0xFF));
            encPayload.u8(static_cast<uint8_t>(encInfo.macLen >> 8));
            encPayload.u8(static_cast<uint8_t>(encInfo.macLen & 0xFF));
            encPayload.raw(encInfo.salt.data(), encInfo.salt.size());
            encPayload.raw(encInfo.iv.data(), encInfo.iv.size());
        } else {
            encPayload.u8(FPPX2_ENCRYPT_NONE);
        }
        writeModuleBytes(w, FPPX2_MODULE_ENCRYPTED, encPayload.buf);
    }
    writeModuleBytes(w, FPPX2_MODULE_PAYLOAD, payloadBytes);

    // MAC 覆盖 [0, 0x05 起始)：文件头 + 索引 + 介绍 + 加密信息 + 密文。
    // 索引因此成为【被认证的元数据】：只护密文的话，攻击者可改写索引偏移再重算 CRC。
    if (r.encrypted) {
        uint8_t mac[FPPX2_MAC_LEN_SHA256];
        fppx_crypto::hmacSha256(macKey.data(), macKey.size(), w.buf.data(), w.buf.size(), mac);
        w.u8(FPPX2_MODULE_MAC);
        w.u32(FPPX2_MAC_LEN_SHA256);
        w.raw(mac, FPPX2_MAC_LEN_SHA256);
    }

    // CRC32 位置与口径不变：覆盖 [0, 本模块起始)，天然含索引与 MAC
    {
        uint32_t crcVal = fppxCrc32(w.buf.data(), w.buf.size());
        w.u8(FPPX2_MODULE_CRC32);
        w.u32(4);
        w.u32(crcVal);
    }
    w.u8(FPPX2_MODULE_END);
    w.u32(0);

    if (w.buf.size() != static_cast<size_t>(endOffset) + FPPX2_MODULE_HEADER_LEN) {
        r.errors.push_back("内部错误：索引预算与实际写入长度不一致（" +
                           std::to_string(w.buf.size()) + " != " +
                           std::to_string(endOffset + FPPX2_MODULE_HEADER_LEN) + "）");
        return r;
    }

    std::string err;
    if (!writeFileBytes(path, w.buf, err)) {
        r.errors.push_back(err);
        return r;
    }

    // 写入后自校验：必须把本次口令传进去。不带口令时加密文件重读必然失败，
    // verify.success==false 会走到删除分支，把刚写好的文件删掉。
    Fppx2Result verify = fppx2Import(path, false, password);
    if (!verify.success || verify.mode != mode) {
        std::string first = verify.errors.empty() ? "未知原因" : verify.errors.front();
        r.errors.push_back("写入后自校验失败，已删除不完整文件: " + first);
        // error_code& 参数必须传左值（NDK libc++ 不接受临时值；MSVC 扩展允许）
        std::error_code rmEc;
        std::filesystem::remove(utf8ToPath(path), rmEc);
        return r;
    }

    r.success = true;
    return r;
}

Fppx2Result fppx2Import(const std::string& path, bool force, const std::string& password) {
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

    // ── 索引模块 0x00（可选）──
    // bytes[6]==0x00 即有索引。索引是加速层而非必需层：缺失或结构非法一律
    // 回退线性扫描，不直接报错，否则会把现网已产出的老 v2 文件全部判死。
    std::vector<FppxIndexEntry> mods;   // 复用索引条目结构承载"模块位置"
    bool hasIndex = false;
    if (bytes.size() > 6 && bytes[6] == FPPX2_MODULE_INDEX) {
        ByteReader hr(bytes.data(), bytes.size(), 6);
        uint8_t hid = hr.u8();
        uint32_t hsz = hr.u32();
        const uint8_t* hp = hr.ok() ? hr.peek(hsz) : nullptr;
        if (hid != FPPX2_MODULE_INDEX || !hp || !parseIndexPayload(hp, hsz, bytes.size(), mods)) {
            r.warnings.push_back("索引模块结构非法，已回退线性扫描");
            mods.clear();
        } else {
            hasIndex = true;
            // 规范 §4.3 规则 7：每个条目的 offset 处确实是对应 id
            for (const FppxIndexEntry& e : mods) {
                if (static_cast<size_t>(e.offset) + e.size > bytes.size()) {
                    r.errors.push_back("索引条目越界（偏移 " + std::to_string(e.offset) + "）");
                    return r;
                }
                if (e.size < FPPX2_MODULE_HEADER_LEN) {
                    r.errors.push_back("索引条目大小异常（偏移 " + std::to_string(e.offset) + "）");
                    return r;
                }
                // 模块自身的 4B 载荷长度也必须与条目 size 自洽
                const uint32_t decl = (static_cast<uint32_t>(bytes[e.offset + 1]) << 24) |
                                      (static_cast<uint32_t>(bytes[e.offset + 2]) << 16) |
                                      (static_cast<uint32_t>(bytes[e.offset + 3]) << 8) |
                                      static_cast<uint32_t>(bytes[e.offset + 4]);
                if (decl + FPPX2_MODULE_HEADER_LEN != e.size) {
                    r.errors.push_back("索引条目大小与模块帧不一致（偏移 " +
                                       std::to_string(e.offset) + "），文件已损坏");
                    return r;
                }
                if (bytes[e.offset] != e.id) {
                    char a[8], b2[8];
                    std::snprintf(a, sizeof(a), "%02x", bytes[e.offset]);
                    std::snprintf(b2, sizeof(b2), "%02x", e.id);
                    r.errors.push_back(std::string("索引与实际内容不符（偏移处为 0x") + a +
                                       "，索引声明 0x" + b2 + "），文件已损坏");
                    return r;
                }
            }
        }
    }

    if (!hasIndex) {
        // 线性扫描：模块序列 [1B ID][4B 载荷长度][载荷]
        ByteReader rd(bytes.data(), bytes.size(), 6);
        while (!rd.atEnd()) {
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
                r.errors.push_back(std::string("模块 0x") + mb + " 的载荷声明 " +
                                   std::to_string(sz) + " 字节，超出文件末尾（文件被截断）");
                return r;
            }
            rd.skip(sz);
            mods.push_back({id, static_cast<uint32_t>(moduleStart),
                            static_cast<uint32_t>(FPPX2_MODULE_HEADER_LEN + sz)});
            if (id == FPPX2_MODULE_END) break;
        }
        // 结尾标记之后不得再有字节
        if (!mods.empty() && mods.back().id == FPPX2_MODULE_END) {
            const size_t endOfEnd = mods.back().offset + mods.back().size;
            if (endOfEnd != bytes.size()) {
                r.errors.push_back("结尾标记之后存在 " +
                                   std::to_string(bytes.size() - endOfEnd) +
                                   " 字节多余数据");
                return r;
            }
        }
    }

    // ── 按位置逐个处理模块 ──
    bool sawDesc = false, sawEnc = false, sawPayload = false, sawCrc = false, sawEnd = false,
         sawMac = false;
    FppxEncInfo encInfo;
    size_t crcStart = 0;
    uint32_t crcStored = 0;
    size_t macStart = 0;
    std::vector<uint8_t> macStored;
    std::vector<uint8_t> payload;

    for (const FppxIndexEntry& m : mods) {
        if (m.id == FPPX2_MODULE_INDEX) continue; // 索引自身
        const size_t moduleStart = m.offset;
        const uint32_t loadLen = m.size >= FPPX2_MODULE_HEADER_LEN
                                     ? m.size - FPPX2_MODULE_HEADER_LEN
                                     : 0;
        if (m.size < FPPX2_MODULE_HEADER_LEN ||
            moduleStart + m.size > bytes.size()) {
            r.errors.push_back("模块位置越界，文件被截断");
            return r;
        }
        const uint8_t* load = bytes.data() + moduleStart + FPPX2_MODULE_HEADER_LEN;
        const size_t sz = loadLen;

        switch (m.id) {
            case FPPX2_MODULE_DESC: {
                if (sawDesc) {
                    r.warnings.push_back("介绍模块重复，已忽略后者");
                    break;
                }
                r.description.assign(reinterpret_cast<const char*>(load), sz);
                if (!r.description.empty() &&
                    !fppx2IsValidUtf8(reinterpret_cast<const uint8_t*>(r.description.data()),
                                      r.description.size())) {
                    // 非合法 UTF-8：常见于其它软件按本地代码页（GBK）写出的旧文本。
                    // 尽力按 GBK 转成 UTF-8；仍失败则丢弃，绝不把原始字节透传给 GUI
                    //（此前 GUI 会显示一串 U+FFFD 乱码）。
                    std::string converted;
                    bool ok = false;
#ifdef _WIN32
                    {
                        const std::string& in = r.description;
                        const int wlen = MultiByteToWideChar(
                            936 /*CP_GBK*/, MB_ERR_INVALID_CHARS,
                            in.data(), static_cast<int>(in.size()), nullptr, 0);
                        if (wlen > 0) {
                            std::wstring w(static_cast<size_t>(wlen), L'\0');
                            if (MultiByteToWideChar(
                                    936, MB_ERR_INVALID_CHARS, in.data(),
                                    static_cast<int>(in.size()), w.data(), wlen) > 0) {
                                const int ulen = WideCharToMultiByte(
                                    CP_UTF8, 0, w.data(), wlen, nullptr, 0, nullptr, nullptr);
                                if (ulen > 0) {
                                    converted.assign(static_cast<size_t>(ulen), '\0');
                                    ok = WideCharToMultiByte(
                                             CP_UTF8, 0, w.data(), wlen, converted.data(),
                                             ulen, nullptr, nullptr) > 0;
                                }
                            }
                        }
                    }
#endif
                    if (ok) {
                        r.warnings.push_back("介绍文本不是 UTF-8，已按 GBK 解读并转为 UTF-8");
                        r.description = std::move(converted);
                    } else {
                        r.warnings.push_back("介绍文本不是合法 UTF-8 且无法按 GBK 解读，已丢弃");
                        r.description.clear();
                    }
                }
                sawDesc = true;
                break;
            }
            case FPPX2_MODULE_ENCRYPTED: {
                if (sawEnc) {
                    r.warnings.push_back("加密标记模块重复，已忽略后者");
                    break;
                }
                std::string eerr;
                if (!parseEncInfo(load, sz, encInfo, eerr)) {
                    r.errors.push_back(eerr);
                    return r;
                }
                sawEnc = true;
                break;
            }
            case FPPX2_MODULE_PAYLOAD: {
                if (sawPayload) {
                    r.warnings.push_back("逻辑块内容模块重复，已忽略后者");
                    break;
                }
                payload.assign(load, load + sz);
                sawPayload = true;
                break;
            }
            case FPPX2_MODULE_MAC: {
                if (sawMac) break;
                macStart = moduleStart;
                macStored.assign(load, load + sz);
                sawMac = true;
                break;
            }
            case FPPX2_MODULE_CRC32: {
                if (sawCrc) break;
                if (sz != 4) {
                    r.errors.push_back("CRC32 模块大小异常（应为 4 字节）");
                    return r;
                }
                crcStart = moduleStart;
                crcStored = (static_cast<uint32_t>(load[0]) << 24) |
                            (static_cast<uint32_t>(load[1]) << 16) |
                            (static_cast<uint32_t>(load[2]) << 8) |
                            static_cast<uint32_t>(load[3]);
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
                r.warnings.push_back("遇到未知模块 0x" + hexByte(m.id) +
                                     "（可能由更高版本软件创建），已跳过 " + std::to_string(sz) +
                                     " 字节");
                break;
            }
        }
    }

    if (!sawEnd) {
        r.errors.push_back("缺少结尾标记，文件可能被截断或损坏");
        return r;
    }
    if (!sawPayload) {
        r.errors.push_back("缺少逻辑块内容模块（0x03）");
        return r;
    }
    if (!sawDesc) r.warnings.push_back("缺少介绍模块，按空介绍处理");
    if (!sawEnc) {
        r.warnings.push_back("缺少加密标记模块，按未加密处理");
    }
    r.encrypted = algoIsEncrypted(encInfo.algo);

    // ── 加密：先验 MAC 再解密（encrypt-then-MAC，MAC 只覆盖密文，无需先解密）──
    if (r.encrypted) {
        if (!sawMac) {
            r.errors.push_back("加密文件缺少认证标签模块（0x05），文件已损坏");
            return r;
        }
        if (password.empty()) {
            // 不是错误：Dart 端据此弹出口令框，带口令重调
            r.needPassword = true;
            return r;
        }
        std::vector<uint8_t> encKey, macKey;
        if (!deriveKeys(password, encInfo, encKey, macKey)) {
            r.errors.push_back("密钥派生失败");
            return r;
        }
        uint8_t mac[FPPX2_MAC_LEN_SHA256];
        fppx_crypto::hmacSha256(macKey.data(), macKey.size(), bytes.data(), macStart, mac);
        if (macStored.size() != FPPX2_MAC_LEN_SHA256 ||
            !fppx_crypto::constantTimeEquals(mac, macStored.data(), FPPX2_MAC_LEN_SHA256)) {
            r.errors.push_back("口令错误，或文件已损坏 / 被篡改");
            return r;
        }
        std::vector<uint8_t> plain;
        if (!fppx_crypto::aesCbcDecrypt(aesBitsOf(encInfo.algo), encKey.data(), encInfo.iv.data(),
                                        payload.data(), payload.size(), plain)) {
            r.errors.push_back("口令错误，或文件已损坏 / 被篡改");
            return r;
        }
        payload.swap(plain);
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

    // 未知节点类型的检查在 parseNodeGraph 内部，故必然晚于解密（规范 §6.1 代价 3）
    // 载荷源自文件（不可信）：JSON 字段类型不符时 nlohmann 会抛异常。dll_main 虽已有
    // 兜底，但那会变成 "服务器异常: [json.exception.type_error.302] ..." 这种无用提示，
    // 故在此转成干净的错误信息。
    bool ok = false;
    try {
        ok = (mode == FPPX2_MODE_NODE_EDITOR) ? parseNodeGraph(payload, force, r)
                                              : parseQuickItems(payload, r);
    } catch (const std::exception& e) {
        r.errors.push_back(std::string("配置载荷结构非法（解析中止）: ") + e.what());
        return r;
    }
    if (!ok) return r; // parse 内部已填 errors
    r.success = true;
    return r;
}

Fppx2Result fppxAutoImport(const std::string& path, bool force,
                           const std::string& password) {
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
    Fppx2Result r = (bytes[4] == FPPX2_MARKER) ? fppx2Import(path, force, password)
                                               : fppxLegacyImport(path);
    r.isNewFormat = (bytes[4] == FPPX2_MARKER);
    return r;
}

} // namespace ffmpegpp
