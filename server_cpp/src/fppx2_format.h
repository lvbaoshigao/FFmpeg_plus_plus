#pragma once
// ═══════════════════════════════════════════════════════════════
// FPPX v2 —— 节点配置文件重构版二进制格式规范（本文件即权威定义）
//
// 与旧版（魔数 + configMajor/Minor + gzip(JSON)）的区别：
//   * 彻底抛弃版本号，第 5 字节固定 0xFF 表示"重构版"；
//     旧版该字节是 configMajor(0x01)，因此两种格式天然可区分。
//   * 载荷改为模块化帧结构，每个模块自描述（ID + 大小前缀），
//     未来新增模块时旧程序可跳过不认识的模块（forward compatible）。
//   * 所有整数一律大端（与旧版 descLen/dataLen 一致）。
//
// 文件总体布局：
//   [4B] 魔数 "FPPX" (0x46 0x50 0x50 0x58)
//   [1B] 0xFF —— 重构版标记
//   [1B] 模式：0x01 节点编辑器 / 0x02 快速模式
//   之后为模块序列，每个模块：
//     [1B] 模块 ID
//     [4B] 载荷字节数 N（大端；保存时先写载荷、统计大小后回填——"统计逻辑"）
//     [NB] 载荷
//
// 模块 ID 分配：
//   0x00 索引       恒为第一个模块；记录自身与后续各模块的绝对偏移与大小
//   0x01 介绍       UTF-8 文本，可为空
//   0x02 是否加密   未加密时固定 1B：0x00；加密时为变长记录
//                   （algo/kdf/iters/macAlgo/saltLen/ivLen/macLen + salt + iv）
//   0x03 逻辑块内容（0x01 模式）/ 快速参数（0x02 模式），结构见下；
//                   加密时本模块载荷【整体为密文】（含其内层索引）
//   0x04 CRC32      4B 大端，对文件开头到本模块之前的所有字节计算
//   0x05 认证标签   仅加密时存在（HMAC-SHA256，32B）；位于 0x03 之后、0x04 之前
//   0xFF 结尾标记   载荷 0 字节；其后不得再有字节
//
// ── 索引模块 0x00（通用规则：凡大小不固定的容器，都在其开头放索引）──
//   [1B] 版本      = 0x01
//   [1B] 步长      = 9（单条目字节数）
//   [2B] 保留      = 0
//   [4B] 条目数 K  大端
//   K × 条目：[1B 元素 ID][4B 绝对偏移][4B 大小]（大小含 5B 模块头）
//   第 0 条恒为索引自身：offset=6、size=13+9K
//   0x03 载荷内部同款（内层索引，元素 ID 见 FPPX2_INNER_*）
//
// ── 索引存在性判定 ──
//   bytes[6] == 0x00 → 有索引；否则为无索引的老 v2 文件，回退线性扫描。
//   索引结构非法时亦回退线性扫描（保住老文件），不直接报错。
//
// ── 0x01 模式 · 模块 0x03 载荷 ──
//   [4B] 节点数量 N
//   N × 节点记录：
//     [16B]   节点类型 ID（node_registry 的 16 字节大端 ID）
//     [4B]    本节点记录剩余部分总大小 S（不含 16B 类型 ID 与 4B 大小字段自身）
//     [4B]    节点文件 ID（从 0 起递增；连线与逻辑块都用它引用节点）
//     连线区（固定顺序 4 块：①左逻辑输入 ②右数据输出 ③左数据输入 ④右逻辑输出）：
//       每块 [4B 块大小] [4B 对端数 K] [K × 4B 对端节点文件 ID]
//       （块大小 = 4 + 4K；①④仅逻辑门节点使用，③仅可被连线输入的节点使用）
//     属性区 [4B 大小] [UTF-8 JSON：{id, params, x, y, gate?}]
//       id 为原节点 UUID（保证导入导出往返稳定）；gate 为门类型名（如 "and"）；
//       未知节点回填 {type_id: 十进制} 到 JSON 的 type_id 字段
//   [4B] 逻辑块分组数量 M
//   M × [4B 块大小] [UTF-8 JSON：{id,type,name,params,x,y,width,height,child_ids:[文件ID...]}]
//
// ── 0x02 模式 · 模块 0x03 载荷（无节点类型 ID，只存命令参数项）──
//   [4B] 参数项数量 K
//   K × [4B 项大小] [UTF-8 JSON：{key, params:{...}, enabled}]
// ═══════════════════════════════════════════════════════════════

#include <cstdint>

namespace ffmpegpp {

// 魔数与标记
inline constexpr uint8_t FPPX_MAGIC[4] = {0x46, 0x50, 0x50, 0x58};  // "FPPX"
inline constexpr uint8_t FPPX2_MARKER = 0xFF;                       // 第 5 字节：重构版标记

// 模式
inline constexpr uint8_t FPPX2_MODE_NODE_EDITOR = 0x01;
inline constexpr uint8_t FPPX2_MODE_QUICK = 0x02;

// 模块 ID
inline constexpr uint8_t FPPX2_MODULE_INDEX = 0x00;       // 索引（恒为第一个模块）
inline constexpr uint8_t FPPX2_MODULE_DESC = 0x01;        // 介绍
inline constexpr uint8_t FPPX2_MODULE_ENCRYPTED = 0x02;   // 是否加密
inline constexpr uint8_t FPPX2_MODULE_PAYLOAD = 0x03;     // 逻辑块内容 / 快速参数
inline constexpr uint8_t FPPX2_MODULE_CRC32 = 0x04;       // CRC32 完整性校验
inline constexpr uint8_t FPPX2_MODULE_MAC = 0x05;         // 认证标签（仅加密时）
inline constexpr uint8_t FPPX2_MODULE_END = 0xFF;         // 结尾标记

// 模块帧头固定 5 字节：1B ID + 4B 载荷长度
inline constexpr uint32_t FPPX2_MODULE_HEADER_LEN = 5;

// ── 索引模块 0x00 ──
inline constexpr uint8_t FPPX2_INDEX_VERSION = 0x01;
inline constexpr uint8_t FPPX2_INDEX_STRIDE = 9;    // 单条目：1B ID + 4B 偏移 + 4B 大小
inline constexpr uint32_t FPPX2_INDEX_HEADER_LEN = 8;  // 版本1 + 步长1 + 保留2 + 条目数4
// 条目数上限：顶层索引恒为 6/7（§9），内层为 2/3。上限只为挡住恶意 K 触发大额
// reserve 分配（对照 parseNodeGraph 的 kMaxNodes、innerIndexSkip 的 k<=64）。
inline constexpr uint32_t FPPX2_INDEX_MAX_ENTRIES = 64;

// 内层元素 ID（独立命名空间，不与模块 ID 共用）
inline constexpr uint8_t FPPX2_INNER_NODE_RECORDS = 0x01;   // 节点记录区
inline constexpr uint8_t FPPX2_INNER_LOGIC_BLOCKS = 0x02;   // 逻辑块区
inline constexpr uint8_t FPPX2_INNER_QUICK_ITEMS = 0x03;    // 参数项区

// ── 加密 ──
inline constexpr uint8_t FPPX2_ENCRYPT_NONE = 0x00;         // 不加密
inline constexpr uint8_t FPPX2_ALGO_AES128_CBC = 0x01;      // AES-128-CBC + PKCS#7
inline constexpr uint8_t FPPX2_ALGO_AES256_CBC = 0x02;      // AES-256-CBC + PKCS#7（默认）
inline constexpr uint8_t FPPX2_ALGO_AES128_GCM = 0x11;      // 预留，本版不实现
inline constexpr uint8_t FPPX2_ALGO_AES256_GCM = 0x12;      // 预留，本版不实现

inline constexpr uint8_t FPPX2_KDF_PBKDF2_SHA256 = 0x01;    // PBKDF2-HMAC-SHA256
inline constexpr uint8_t FPPX2_MAC_NONE = 0x00;
inline constexpr uint8_t FPPX2_MAC_HMAC_SHA256 = 0x01;

// 模块 0x02 载荷：未加密 = 1B(0x00)；加密 = 13B 定长头 + salt + iv
inline constexpr uint32_t FPPX2_ENCINFO_FIXED_LEN = 13;
inline constexpr uint32_t FPPX2_ENCINFO_MAX_SALT = 64;
inline constexpr uint32_t FPPX2_ENCINFO_MAX_IV = 32;
inline constexpr uint32_t FPPX2_MAC_LEN_SHA256 = 32;

// 默认迭代次数（写端决定并存入 0x02，读端照用）
inline constexpr uint32_t FPPX2_PBKDF2_ITERS_DESKTOP = 200000;
inline constexpr uint32_t FPPX2_PBKDF2_ITERS_MOBILE = 100000;
inline constexpr uint32_t FPPX2_PBKDF2_ITERS_MAX = 1000000;  // 读端上限；实测 /O2 约 2.6s，
                                                             // 远低于 GUI 的 30s 请求超时
                                                             // （5e6 需 14.1s，慢机上会撞超时）

// 节点记录内的连线块（固定顺序）
enum Fppx2ConnBlock : int {
    FPPX2_BLOCK_CTRL_IN = 0,   // ① 左逻辑输入（使能端，接收门输出/上游状态输出）
    FPPX2_BLOCK_DATA_OUT = 1,  // ② 右数据输出
    FPPX2_BLOCK_DATA_IN = 2,   // ③ 左数据输入
    FPPX2_BLOCK_CTRL_OUT = 3,  // ④ 右逻辑输出（控制输出）
};
inline constexpr int FPPX2_CONN_BLOCK_COUNT = 4;

// ── UTF-8 严格校验：0x01 介绍模块的载荷是原始字节进文件，格式上要求
// 必须是合法 UTF-8（不含代理区、不含超长编码、不越过 U+10FFFF）。
// 写端据此拒绝非法描述；读端据此识别旧文本并尽力转码。
inline bool fppx2IsValidUtf8(const uint8_t* s, size_t n) {
    size_t i = 0;
    while (i < n) {
        const uint8_t c = s[i];
        if (c < 0x80) { ++i; continue; }
        size_t extra;
        uint32_t cp;
        if ((c & 0xE0u) == 0xC0u) { extra = 1; cp = c & 0x1Fu; }
        else if ((c & 0xF0u) == 0xE0u) { extra = 2; cp = c & 0x0Fu; }
        else if ((c & 0xF8u) == 0xF0u) { extra = 3; cp = c & 0x07u; }
        else return false;
        if (n - i < extra + 1) return false; // 序列被截断
        for (size_t k = 1; k <= extra; ++k) {
            if ((s[i + k] & 0xC0u) != 0x80u) return false; // 后续字节非 10xxxxxx
            cp = (cp << 6) | (s[i + k] & 0x3Fu);
        }
        if ((extra == 1 && cp < 0x80) || (extra == 2 && cp < 0x800) ||
            (extra == 3 && cp < 0x10000) || cp > 0x10FFFF ||
            (cp >= 0xD800 && cp <= 0xDFFF)) {
            return false; // 超长编码 / 代理区 / 越界
        }
        i += extra + 1;
    }
    return true;
}

} // namespace ffmpegpp
