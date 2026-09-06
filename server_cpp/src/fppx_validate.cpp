#include "fppx_validate.h"

#include <algorithm>
#include <cstdio>
#include <functional>
#include <map>
#include <mutex>
#include <random>
#include <set>

#include "fppx2_format.h"

namespace ffmpegpp {
namespace fppx_detail {

std::string shortId(const std::string& uuid) {
    return uuid.size() > 8 ? uuid.substr(0, 8) : uuid;
}

// UUID v4
std::string genUuid() {
    static std::mutex m;
    static std::mt19937_64 gen(std::random_device{}());
    std::lock_guard<std::mutex> lock(m);
    uint64_t a = gen(), b = gen();
    a = (a & 0xFFFFFFFFFFFF0FFFULL) | 0x0000000000004000ULL; // version 4
    b = (b & 0x3FFFFFFFFFFFFFFFULL) | 0x8000000000000000ULL; // variant
    char buf[40];
    std::snprintf(buf, sizeof(buf), "%08x-%04x-%04x-%04x-%04x%08x",
                  static_cast<unsigned>(a >> 32), static_cast<unsigned>((a >> 16) & 0xFFFF),
                  static_cast<unsigned>(a & 0xFFFF), static_cast<unsigned>(b >> 48),
                  static_cast<unsigned>((b >> 32) & 0xFFFF), static_cast<unsigned>(b & 0xFFFFFFFF));
    return buf;
}

uint8_t startMediaOut(const json& params) {
    std::string t = params.value("file_media_type", std::string("video"));
    if (t == "image") return MK_IMAGE;
    if (t == "audio") return MK_AUDIO;
    return MK_VIDEO;
}

void buildVNodesFromJson(const json& nodes, std::vector<VNode>& out,
                         std::vector<std::string>& errors, std::vector<std::string>& warnings) {
    (void)warnings;
    std::set<std::string> seen;
    int idx = 0;
    for (const auto& n : nodes) {
        std::string uuid = n.value("id", std::string(""));
        std::string type = n.value("type", std::string(""));
        if (uuid.empty() || type.empty()) {
            errors.push_back("第 " + std::to_string(idx) + " 个节点缺少 id 或 type");
            ++idx;
            continue;
        }
        if (seen.count(uuid)) errors.push_back("节点 id 重复: " + shortId(uuid));
        seen.insert(uuid);

        VNode v;
        v.uuid = uuid;
        v.fileId = idx;
        std::string gate = n.value("gate", std::string(""));
        if (type == "unknown") {
            v.isUnknown = true;
            v.typeIdInt = n.value("type_id", static_cast<uint64_t>(0));
            if (v.typeIdInt == 0) {
                errors.push_back("未知节点 " + shortId(uuid) + " 缺少 type_id，无法写入文件");
            }
            v.label = "未知节点(" + std::to_string(v.typeIdInt) + ")";
        } else if (!gate.empty()) {
            v.spec = findGateByName(gate);
            if (!v.spec) {
                errors.push_back("未知的逻辑门类型: " + gate);
                v.label = "未知门(" + gate + ")";
            } else {
                v.label = v.spec->zhLabel;
                v.isStart = false; // 门节点不是源文件
            }
        } else {
            v.spec = findTypeByName(type);
            if (!v.spec) {
                errors.push_back("未知的节点类型: " + type);
                v.label = "未知类型(" + type + ")";
            } else {
                v.label = v.spec->zhLabel;
                v.isStart = (v.spec->name == std::string("start"));
                v.isOutput = (v.spec->name == std::string("output"));
                if (v.isStart) v.mediaOut = startMediaOut(n.value("params", json::object()));
            }
        }
        out.push_back(v);
        ++idx;
    }
}

void validateGraphSemantics(const std::vector<VNode>& nodes, const std::vector<VEdge>& edges,
                            std::vector<std::string>& errors, std::vector<std::string>& warnings) {
    const int n = static_cast<int>(nodes.size());
    auto labelOf = [&](int i) -> std::string {
        return (i >= 0 && i < n) ? nodes[i].label : "???";
    };
    auto known = [&](int i) {
        return i >= 0 && i < n && !nodes[i].isUnknown && nodes[i].spec != nullptr;
    };

    // 结构节点必须齐备
    int startCount = 0, outputCount = 0;
    for (const auto& v : nodes) {
        if (v.isStart) ++startCount;
        if (v.isOutput) ++outputCount;
    }
    if (startCount == 0) errors.push_back("图中没有源文件节点");
    if (outputCount == 0) errors.push_back("图中没有输出节点");

    // 非门节点（除 start/output）必须各有一进一出数据连线
    std::vector<bool> hasDataIn(n, false), hasDataOut(n, false);
    for (const auto& e : edges) {
        if (!e.control) {
            if (e.from >= 0 && e.from < n) hasDataOut[e.from] = true;
            if (e.to >= 0 && e.to < n) hasDataIn[e.to] = true;
        }
    }
    for (int i = 0; i < n; ++i) {
        const VNode& v = nodes[i];
        if (v.isUnknown || v.isStart || v.isOutput || (v.spec && v.spec->isGate)) continue;
        if (!hasDataIn[i]) errors.push_back("节点「" + v.label + "#" + shortId(v.uuid) + "」缺少数据输入连线");
        if (!hasDataOut[i]) errors.push_back("节点「" + v.label + "#" + shortId(v.uuid) + "」缺少数据输出连线");
    }

    std::map<int, int> gateCtrlIn; // 门节点 → 控制输入数
    for (const auto& e : edges) {
        if (e.from == e.to) {
            errors.push_back("节点「" + labelOf(e.from) + "」不能连接自身");
            continue;
        }
        if (e.control) {
            // 源端必须有控制输出能力：门节点或非起始节点（状态输出）
            if (known(e.from) && nodes[e.from].spec && !nodes[e.from].spec->isGate &&
                nodes[e.from].isStart) {
                errors.push_back("源文件节点「" + labelOf(e.from) + "」没有控制输出端口");
            }
            // 目标端：非起始节点（使能端）；源文件节点没有使能输入
            if (known(e.to) && nodes[e.to].spec && !nodes[e.to].spec->isGate && nodes[e.to].isStart) {
                errors.push_back("源文件节点「" + labelOf(e.to) + "」没有使能输入端");
            }
            if (known(e.to) && nodes[e.to].spec && nodes[e.to].spec->isGate) {
                ++gateCtrlIn[e.to];
            }
        } else {
            // 数据连线：端口方向 + 媒体类型兼容
            if (known(e.from) && nodes[e.from].spec && !nodes[e.from].spec->isGate &&
                nodes[e.from].mediaOut == MK_NONE && nodes[e.from].spec->mediaOut == MK_NONE) {
                errors.push_back("节点「" + labelOf(e.from) + "」没有数据输出端口");
            }
            if (known(e.to) && nodes[e.to].spec && nodes[e.to].spec->mediaIn == MK_NONE) {
                errors.push_back("节点「" + labelOf(e.to) + "」没有数据输入端口");
            }
            if (known(e.from) && known(e.to) && nodes[e.from].spec && nodes[e.to].spec &&
                !nodes[e.from].spec->isGate && !nodes[e.to].spec->isGate) {
                uint8_t outM = nodes[e.from].mediaOut ? nodes[e.from].mediaOut
                                                      : nodes[e.from].spec->mediaOut;
                uint8_t inM = nodes[e.to].spec->mediaIn;
                if ((outM & inM) == 0) {
                    auto mk = [](uint8_t m) {
                        std::string s;
                        if (m & MK_VIDEO) s += "视频";
                        if (m & MK_IMAGE) s += "图片";
                        if (m & MK_AUDIO) s += "音频";
                        return s.empty() ? std::string("无") : s;
                    };
                    errors.push_back("连线媒体类型不兼容：「" + labelOf(e.from) + "」输出(" +
                                     mk(outM) + ") → 「" + labelOf(e.to) + "」只接受(" + mk(inM) + ")");
                }
            }
            if (nodes[e.from].isUnknown || nodes[e.to].isUnknown) {
                warnings.push_back("连线涉及未知节点，跳过其媒体类型检查");
            }
        }
    }
    // 门输入数上限
    for (const auto& [gi, cnt] : gateCtrlIn) {
        const VNode& v = nodes[gi];
        if (v.spec && cnt > v.spec->gateArity) {
            errors.push_back("逻辑门「" + v.label + "」的控制输入数 " + std::to_string(cnt) +
                             " 超过上限 " + std::to_string(v.spec->gateArity));
        }
    }

    // start → output 可达性（沿数据连线）
    {
        std::vector<std::vector<int>> adj(n);
        for (const auto& e : edges)
            if (!e.control && e.from >= 0 && e.from < n && e.to >= 0 && e.to < n)
                adj[e.from].push_back(e.to);
        for (int s = 0; s < n; ++s) {
            if (!nodes[s].isStart) continue;
            std::vector<bool> vis(n, false);
            std::vector<int> stack{s};
            vis[s] = true;
            bool reach = false;
            while (!stack.empty() && !reach) {
                int cur = stack.back();
                stack.pop_back();
                for (int nxt : adj[cur]) {
                    if (vis[nxt]) continue;
                    vis[nxt] = true;
                    if (nodes[nxt].isOutput) { reach = true; break; }
                    stack.push_back(nxt);
                }
            }
            if (!reach) {
                errors.push_back("源文件节点「" + labelOf(s) + "」没有连到任何输出节点");
            }
        }
    }

    // 环检测（数据 + 控制连线，DFS 三色标记）
    {
        std::vector<std::vector<int>> adj(n);
        for (const auto& e : edges)
            if (e.from >= 0 && e.from < n && e.to >= 0 && e.to < n)
                adj[e.from].push_back(e.to);
        std::vector<int> color(n, 0); // 0 未访问 1 栈内 2 完成
        std::vector<int> path;
        std::vector<std::string> cycleNodes;
        std::function<bool(int)> dfs = [&](int u) -> bool {
            color[u] = 1;
            path.push_back(u);
            for (int v : adj[u]) {
                if (color[v] == 1) {
                    cycleNodes.clear();
                    bool in = false;
                    for (int x : path) {
                        if (x == v) in = true;
                        if (in) cycleNodes.push_back(nodes[x].label);
                    }
                    return true;
                }
                if (color[v] == 0 && dfs(v)) return true;
            }
            path.pop_back();
            color[u] = 2;
            return false;
        };
        for (int i = 0; i < n; ++i) {
            if (color[i] == 0 && dfs(i)) {
                std::string cyc;
                for (size_t k = 0; k < cycleNodes.size(); ++k) {
                    if (k) cyc += " → ";
                    cyc += "「" + cycleNodes[k] + "」";
                }
                errors.push_back("图中存在环路: " + cyc);
                break;
            }
        }
    }
}

json validateLogicBlocks(const json& logicBlocks, const std::map<std::string, int>& uuidToFile,
                         const std::vector<VNode>& nodes, std::vector<std::string>& errors) {
    json outBlocks = json::array();
    std::map<int, int> owner; // fileId → 逻辑块序号
    int bi = 0;
    if (!logicBlocks.is_array()) return outBlocks;
    for (const auto& lb : logicBlocks) {
        json out;
        out["id"] = lb.value("id", std::string(""));
        if (out["id"].get<std::string>().empty()) out["id"] = genUuid();
        out["type"] = lb.value("type", std::string("loop"));
        out["name"] = lb.value("name", std::string(""));
        out["params"] = lb.value("params", json::object());
        out["x"] = lb.value("x", 0.0);
        out["y"] = lb.value("y", 0.0);
        out["width"] = lb.value("width", 200.0);
        out["height"] = lb.value("height", 100.0);
        json children = json::array();
        if (lb.contains("childNodeIds") && lb["childNodeIds"].is_array()) {
            for (const auto& cid : lb["childNodeIds"]) {
                std::string cuuid = cid.get<std::string>();
                auto it = uuidToFile.find(cuuid);
                if (it == uuidToFile.end()) {
                    errors.push_back("逻辑块「" + out["name"].get<std::string>() +
                                     "」引用了不存在的节点 " + shortId(cuuid));
                    continue;
                }
                auto owned = owner.find(it->second);
                if (owned != owner.end() && owned->second != bi) {
                    errors.push_back("节点同时属于多个逻辑块: " + shortId(cuuid));
                    continue;
                }
                owner[it->second] = bi;
                const VNode& v = nodes[it->second];
                if (v.isStart || v.isOutput) {
                    errors.push_back("逻辑块不能包含源文件/输出节点: " + v.label);
                    continue;
                }
                children.push_back(cuuid);
            }
        }
        out["childNodeIds"] = children;
        outBlocks.push_back(out);
        ++bi;
    }
    return outBlocks;
}

} // namespace fppx_detail
} // namespace ffmpegpp
