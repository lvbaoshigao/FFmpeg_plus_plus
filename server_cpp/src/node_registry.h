#pragma once
// ═══════════════════════════════════════════════════════════════
// 节点类型注册表 —— FPPX v2 的 16 字节节点类型 ID 与 GUI 节点类型的
// 唯一映射，同时携带媒体类型、门信息与参数键白名单（张冠李戴检查依据）。
//
// 与 GUI 的对应关系：GUI JSON 里节点形如 {type:"avProcess", gate?:"and"}；
// 门节点在 GUI 中 type 固定为 "start" + gate 字段标识门类型，
// 因此门类型在注册表中拥有独立 ID，导入/导出时按 gate 字段换算。
// ═══════════════════════════════════════════════════════════════

#include <array>
#include <cstdint>
#include <set>
#include <string>

#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

// 16 字节节点类型 ID（大端整数，高位补零；预留未来大量节点）
using NodeTypeId = std::array<uint8_t, 16>;

// 由 uint64 构造 16 字节大端 ID
NodeTypeId makeTypeId(uint64_t v);
// 十进制字符串（未知节点提示与回退显示用，如 "19243"）
std::string typeIdToDec(const NodeTypeId& id);

// 媒体类型位集（与 GUI MediaType video/image/audio 对应）
enum MediaKind : uint8_t {
    MK_NONE = 0,
    MK_VIDEO = 1 << 0,
    MK_IMAGE = 1 << 1,
    MK_AUDIO = 1 << 2,
};

struct NodeTypeSpec {
    NodeTypeId id;
    const char* name;        // GUI PipelineStepType.name（门节点恒为 "start"）
    const char* gateName;    // 门类型名（非门为 nullptr）
    const char* zhLabel;     // 中文名
    uint8_t mediaIn;         // 可接受的数据输入媒体类型（MK_* 按位或）
    uint8_t mediaOut;        // 数据输出媒体类型；MK_NONE = 无数据输出
    bool isGate;             // 逻辑门（控制流节点）
    int gateArity;           // 门常规输入数（非门为 0）
    std::set<std::string> paramKeys;  // 该节点允许的参数键白名单
};

// 按 GUI 类型名查找（门节点用 gate 名查 findGateByName）
const NodeTypeSpec* findTypeByName(const std::string& name);
const NodeTypeSpec* findGateByName(const std::string& gateName);
const NodeTypeSpec* findTypeById(const NodeTypeId& id);
const NodeTypeSpec* findGateById(const NodeTypeId& id);

// 参数键归属检查结果
enum ParamKeyClass {
    PKC_OK = 0,        // 登记在本节点名下，合法
    PKC_MISMATCH = 1,  // 登记在其他节点名下 —— 张冠李戴
    PKC_UNLISTED = 2,  // 完全未登记 —— 视为新版本新增键，仅警告
};
// key 为节点属性键；gate 传门类型名（非门节点传 nullptr）
ParamKeyClass classifyParamKey(const std::string& key, const NodeTypeSpec* spec,
                               const char* gateName);

// 快速模式（0x02）参数项 key 白名单（与 GUI quick_config.dart 的 item key 对应）
bool isKnownQuickKey(const std::string& key);

} // namespace ffmpegpp
