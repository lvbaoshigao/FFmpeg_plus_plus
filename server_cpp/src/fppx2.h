#pragma once
// ═══════════════════════════════════════════════════════════════
// FPPX v2 导入/导出/校验 —— 节点编辑器与快速模式配置文件的读写核心。
// 格式布局见 fppx2_format.h；节点类型映射见 node_registry.h。
//
// 校验分三层（"完善校验机制"）：
//   格式层：魔数/标记/模块结构/尺寸边界/CRC32/结尾标记/加密占位
//   注册表层：16B 节点类型 ID 未知性（强制导入流程）、属性张冠李戴
//   图语义层：连线完整性/自环/环检测/媒体类型兼容/start-output 可达/门上限
// ═══════════════════════════════════════════════════════════════

#include <string>
#include <vector>

#include "nlohmann/json.hpp"

namespace ffmpegpp {

using json = nlohmann::json;

struct Fppx2Result {
    bool success = false;
    int mode = 0;                       // FPPX2_MODE_NODE_EDITOR / FPPX2_MODE_QUICK
    std::string description;
    bool encrypted = false;
    bool isNewFormat = false;           // 自动路由导入时：true = 新版 v2
    json graph;                         // 0x01：{nodes, connections, logicBlocks}
    json quickItems;                    // 0x02：[{key, params, enabled}]
    json legacy;                        // 旧格式 mode!=0x01 时的原始载荷
    std::vector<std::string> errors;
    std::vector<std::string> warnings;
    std::vector<std::string> unknownTypeIds;  // 未知 16B 节点类型 ID（十进制串）
    bool forced = false;

    json toJson() const;
};

// ── v2 格式 ──
// params: {path, mode?, description?, encrypted?, graph?, quick_items?}
// mode 0x01 需要 graph（GUI PipelineGraph.toJson() 的形状）；
// mode 0x02 需要 quick_items（[{key, params, enabled}]）。
// 写入前完整校验；存在 error 则拒绝写文件。写成功后自动重读自校验。
Fppx2Result fppx2Export(const json& params);

// path 指向的文件按 v2 解析。force=false 且存在未知节点类型 ID 时，
// 返回 success=true + unknownTypeIds 非空 + graph=null，由 GUI 弹强制导入确认。
Fppx2Result fppx2Import(const std::string& path, bool force);

// 自动路由导入：按文件头第 5 字节判别新旧格式后分发
// （0xFF → fppx2Import，否则 → fppxLegacyImport）。结果 isNewFormat 标记来源。
// GUI 端不读配置文件的任何字节，路由完全由 C++ 决定。
Fppx2Result fppxAutoImport(const std::string& path, bool force);

// ── 旧版格式（魔数 + 版本号 + gzip(JSON)），完整迁移自 Dart FppxExporter ──
Fppx2Result fppxLegacyImport(const std::string& path);
// params: {path, graph, description}
Fppx2Result fppxLegacyExport(const json& params);

} // namespace ffmpegpp
