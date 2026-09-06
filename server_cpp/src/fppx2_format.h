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
//   0x01 介绍       UTF-8 文本，可为空
//   0x02 是否加密   固定 1B：0x00 未加密。本版仅占位，
//                   导入遇到非 0x00 报"暂不支持的加密方式"
//   0x03 逻辑块内容（0x01 模式）/ 快速参数（0x02 模式），结构见下
//   0x04 CRC32      4B 大端，对文件开头到本模块之前的所有字节计算
//   0xFF 结尾标记   载荷 0 字节；其后不得再有字节
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
inline constexpr uint8_t FPPX2_MODULE_DESC = 0x01;        // 介绍
inline constexpr uint8_t FPPX2_MODULE_ENCRYPTED = 0x02;   // 是否加密
inline constexpr uint8_t FPPX2_MODULE_PAYLOAD = 0x03;     // 逻辑块内容 / 快速参数
inline constexpr uint8_t FPPX2_MODULE_CRC32 = 0x04;       // CRC32 完整性校验
inline constexpr uint8_t FPPX2_MODULE_END = 0xFF;         // 结尾标记

// 加密占位：本版只接受 0x00
inline constexpr uint8_t FPPX2_ENCRYPT_NONE = 0x00;

// 节点记录内的连线块（固定顺序）
enum Fppx2ConnBlock : int {
    FPPX2_BLOCK_CTRL_IN = 0,   // ① 左逻辑输入（使能端，接收门输出/上游状态输出）
    FPPX2_BLOCK_DATA_OUT = 1,  // ② 右数据输出
    FPPX2_BLOCK_DATA_IN = 2,   // ③ 左数据输入
    FPPX2_BLOCK_CTRL_OUT = 3,  // ④ 右逻辑输出（控制输出）
};
inline constexpr int FPPX2_CONN_BLOCK_COUNT = 4;

} // namespace ffmpegpp
