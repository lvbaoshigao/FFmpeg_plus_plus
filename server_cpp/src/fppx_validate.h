#pragma once
// 图语义校验的内部共享层 —— fppx2（新版）与 fppx_legacy（旧版）导出/导入
// 共用的中间表示与校验函数。不对外暴露，仅 fppx_* 模块使用。

#include <string>
#include <vector>

#include "nlohmann/json.hpp"
#include "node_registry.h"

namespace ffmpegpp {
namespace fppx_detail {

using json = nlohmann::json;

struct VNode {
    std::string uuid;
    const NodeTypeSpec* spec = nullptr;  // 未知节点为 nullptr
    bool isUnknown = false;
    uint64_t typeIdInt = 0;              // 未知节点的原始 16B ID 值
    int fileId = 0;
    bool isStart = false;                // 非门源文件节点
    bool isOutput = false;
    std::string label;                   // 报错用显示名
    uint8_t mediaOut = 0;                // start 节点按 params 解析后的输出媒体类型
};

struct VEdge {
    int from = 0, to = 0;
    bool control = false;
};

std::string shortId(const std::string& uuid);

// UUID v4（导入时属性区缺 id、连线对象需要新 id、逻辑块缺 id 时使用）
std::string genUuid();

// start 节点的实际输出媒体类型由 params.file_media_type 决定
uint8_t startMediaOut(const json& params);

// 由 GUI JSON 节点数组构建 VNode（fileId = 数组序；缺 id/type 记入 errors）
void buildVNodesFromJson(const json& nodes, std::vector<VNode>& out,
                         std::vector<std::string>& errors, std::vector<std::string>& warnings);

// 图语义校验：连线完整性/端口方向/媒体类型/门上限/缺连线/可达性/环
void validateGraphSemantics(const std::vector<VNode>& nodes, const std::vector<VEdge>& edges,
                            std::vector<std::string>& errors, std::vector<std::string>& warnings);

// 逻辑块分组校验（入参为 GUI 形状：childNodeIds 为 UUID），返回规范化 JSON
json validateLogicBlocks(const json& logicBlocks, const std::map<std::string, int>& uuidToFile,
                         const std::vector<VNode>& nodes, std::vector<std::string>& errors);

} // namespace fppx_detail
} // namespace ffmpegpp
