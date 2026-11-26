#!/usr/bin/env python3
"""Tutorial utility: check graph JSON and pack/unpack legacy node-editor FPPX.

Python 3.9+. Standard library only. Does not run media tasks or implement v2/AES.
Checks cover structure and selected parameters, not the complete app validator.
"""
import argparse
from collections import deque
import gzip
import io
import json
import math
from pathlib import Path
import struct
import sys
import zlib

HEADER = b"FPPX" + bytes([1, 2, 3, 2, 1])
MAX_JSON = 16 * 1024 * 1024
MAX_FILE = 256 * 1024 * 1024
NODE_TYPES = set("start avProcess subtitle clip frame speed imageConvert audioConvert audioQuality audioSpeed audioVolume audioCompressor audioMetadata extractAudio concatMedia imageToVideo imageCrop imageRotate imageScale imageBrightness imageNoise imageSharpen imageDenoise imageChannelExtract videoCrop videoFilter videoGeometry videoOverlay audioFade imageAdjust mediaConvert mediaScale mediaCrop mediaRotate mediaColor mediaSharpen mediaOverlay output imageCompress audioNormalize audioNoiseGate videoFrameRate metadataStrip audioDenoise audioSilenceTrim videoDeinterlace audioSpectrum audioWaveform audioReverse videoReverse audioEqualizer videoFade".split())
GATES = set("and or not nand nor xor xnor const1 const0 timeTrigger random filenameMatch extensionMatch".split())
GENERIC = set("mediaConvert mediaScale mediaCrop mediaRotate mediaColor mediaSharpen mediaOverlay metadataStrip".split())


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def object_no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "JSON 中有重复字段: " + key)
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError("JSON 不允许 " + value)


def decode_json(raw):
    require(len(raw) <= MAX_JSON, "本教程工具的 JSON 上限是 16 MiB")
    return json.loads(raw.decode("utf-8-sig"), object_pairs_hook=object_no_duplicates,
                      parse_constant=reject_constant)


def validate(graph):
    require(isinstance(graph, dict), "根必须是图对象，不是 graph 外壳或数组")
    nodes = graph.get("nodes")
    edges = graph.get("connections")
    blocks = graph.get("logicBlocks", [])
    require(isinstance(nodes, list) and nodes, "nodes 必须是非空数组")
    require(isinstance(edges, list), "connections 必须是数组")
    require(isinstance(blocks, list), "logicBlocks 必须是数组")
    by_id = {}
    for node in nodes:
        require(isinstance(node, dict), "每个节点必须是对象")
        ident = node.get("id")
        require(isinstance(ident, str) and bool(ident), "节点 id 必须是非空字符串")
        require(ident not in by_id, "节点 id 重复: " + ident)
        require(node.get("type") in NODE_TYPES, "不支持的 type: " + str(node.get("type")))
        require(isinstance(node.get("params", {}), dict), ident + ": params 必须是对象")
        require(number(node.get("x", 0)) and number(node.get("y", 0)), ident + ": 坐标必须是有限数值")
        gate = node.get("gate")
        if gate is not None:
            require(gate in GATES and node["type"] == "start", ident + ": 门使用 type=start 和已知 gate 名")
        params = node.get("params", {})
        if not gate and node["type"] in GENERIC:
            require(params.get("media_type") in ("video", "audio", "image"), ident + ": 通用节点必须声明 media_type")
        if node["type"] == "clip":
            a, b = params.get("start_time"), params.get("end_time")
            require(number(a) and number(b) and 0 <= a < b, ident + ": 截取时间要用秒数，且 0 <= start_time < end_time")
        if node["type"] in ("audioWaveform", "audioSpectrum"):
            for key in ("width", "height"):
                v = params.get(key, 1280 if key == "width" else 720)
                require(type(v) is int and 64 <= v <= 4096, ident + ": " + key + " 必须为 64～4096 的整数")
            require(params.get("output_format", "png") in ("png", "jpg", "webp"), ident + ": 无效的图像格式")
        by_id[ident] = node
    ordinary = {key: node for key, node in by_id.items() if node.get("gate") is None}
    require(any(n["type"] == "start" for n in ordinary.values()), "缺少普通源文件节点")
    require(any(n["type"] == "output" for n in ordinary.values()), "缺少输出节点")
    incoming = {key: 0 for key in by_id}
    outgoing = {key: 0 for key in by_id}
    indegree = {key: 0 for key in by_id}
    adjacency = {key: [] for key in by_id}
    edge_ids, seen_edges = set(), set()
    for edge in edges:
        require(isinstance(edge, dict), "连线必须是对象")
        ident = edge.get("id")
        require(isinstance(ident, str) and bool(ident) and ident not in edge_ids, "连线 id 缺失或重复")
        edge_ids.add(ident)
        a, b, kind = edge.get("from"), edge.get("to"), edge.get("kind", "data")
        require(isinstance(a, str) and isinstance(b, str) and a in by_id and b in by_id, ident + ": 连线端点不存在")
        require(a != b, ident + ": 不能自连")
        require(kind in ("data", "control"), ident + ": kind 只能为 data 或 control")
        require((a, b, kind) not in seen_edges, ident + ": 重复的连线")
        seen_edges.add((a, b, kind))
        if kind == "data":
            require(a in ordinary and b in ordinary, ident + ": 逻辑门不传媒体数据")
            require(by_id[a]["type"] != "output" and by_id[b]["type"] != "start", ident + ": 数据端口方向不对")
            outgoing[a] += 1
            incoming[b] += 1
        else:
            require(by_id[b].get("gate") is not None or by_id[a].get("gate") is not None,
                    ident + ": 普通节点的使能端只能接逻辑门输出")
        adjacency[a].append(b)
        indegree[b] += 1
    for ident, node in ordinary.items():
        if node["type"] != "start":
            require(incoming[ident] == 1, ident + ": 普通非源节点必须恰有一条数据输入")
        if node["type"] != "output":
            require(outgoing[ident] >= 1, ident + ": 缺少数据输出连线")
    ready = deque(key for key, degree in indegree.items() if degree == 0)
    visited = 0
    while ready:
        ident = ready.popleft()
        visited += 1
        for target in adjacency[ident]:
            indegree[target] -= 1
            if indegree[target] == 0:
                ready.append(target)
    require(visited == len(nodes), "图中存在环路；逻辑块循环不靠回接连线实现")
    block_ids, claimed = set(), set()
    for block in blocks:
        require(isinstance(block, dict), "逻辑块必须是对象")
        ident = block.get("id")
        require(isinstance(ident, str) and bool(ident) and ident not in block_ids, "逻辑块 id 缺失或重复")
        block_ids.add(ident)
        require(block.get("type") in ("loop", "selectiveLoop", "group", "condition"), ident + ": 逻辑块类型无效")
        require(isinstance(block.get("params", {}), dict), ident + ": params 必须是对象")
        children = block.get("childNodeIds", [])
        require(isinstance(children, list), ident + ": childNodeIds 必须是数组")
        for key in children:
            require(isinstance(key, str) and key in ordinary, ident + ": 子节点不存在或是逻辑门")
            require(ordinary[key]["type"] not in ("start", "output"), ident + ": 块内不能放源/输出")
            require(key not in claimed, ident + ": 子节点重复或同时属于多个逻辑块")
            claimed.add(key)
    return graph


def read_graph(path):
    require(path.stat().st_size <= MAX_JSON, "JSON 超过工具的 16 MiB 上限")
    return validate(decode_json(path.read_bytes()))


def write_new(path, data):
    # Exclusive creation: never silently replace a reader's existing work.
    with path.open("xb") as stream:
        stream.write(data)


def pack(source, target, description):
    graph = read_graph(source)
    desc = description.encode("utf-8")
    require(len(desc) <= 65535, "描述最长 65535 个 UTF-8 字节，不是字符")
    raw = json.dumps(graph, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")
    require(len(raw) <= MAX_JSON, "JSON 超过工具的 16 MiB 上限")
    payload = gzip.compress(raw, mtime=0)
    write_new(target, HEADER + struct.pack(">H", len(desc)) + desc + struct.pack(">I", len(payload)) + payload)


def unpack(source, target):
    require(source.stat().st_size <= MAX_FILE, "文件超过工具的 256 MiB 上限")
    data = source.read_bytes()
    require(len(data) >= 15 and data[:4] == b"FPPX", "不是有效的旧版 FPPX 文件")
    require(data[4] != 255, "这是新版 FPPX；请先在应用中导出旧版，本工具不解码 v2/AES")
    require(data[8] == 1, "本工具只支持节点编辑器模式 0x01")
    require(data[4:6] == bytes([1, 2]), "本教程工具仅解包旧版配置格式 1.2")
    require(data[6] <= 5 <= data[6] + data[7], "文件头与当前旧版内部兼容值 5 不兼容")
    desc_size = struct.unpack_from(">H", data, 9)[0]
    offset = 11 + desc_size
    require(offset + 4 <= len(data), "描述或数据长度区被截断")
    description = data[11:offset].decode("utf-8")
    size = struct.unpack_from(">I", data, offset)[0]
    require(offset + 4 + size == len(data), "数据长度不匹配或有多余字节")
    with gzip.GzipFile(fileobj=io.BytesIO(data[offset + 4:])) as stream:
        raw = stream.read(MAX_JSON + 1)
    graph = validate(decode_json(raw))
    write_new(target, (json.dumps(graph, ensure_ascii=False, allow_nan=False, indent=2) + "\n").encode("utf-8"))
    return description


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check", help="检查一个 JSON 或目录内的全部 *.json")
    check.add_argument("source", type=Path)
    pack_parser = sub.add_parser("pack", help="JSON -> 旧版节点编辑器 .fppx")
    pack_parser.add_argument("source", type=Path)
    pack_parser.add_argument("target", type=Path)
    pack_parser.add_argument("--description", default="手写节点图示例")
    unpack_parser = sub.add_parser("unpack", help="旧版 .fppx -> JSON")
    unpack_parser.add_argument("source", type=Path)
    unpack_parser.add_argument("target", type=Path)
    args = parser.parse_args()
    if args.command == "check":
        paths = sorted(args.source.glob("*.json")) if args.source.is_dir() else [args.source]
        require(bool(paths), "没有找到 JSON 文件")
        for path in paths:
            graph = read_graph(path)
            print("PASS", path.name, len(graph["nodes"]), "nodes", len(graph["connections"]), "connections")
        print("结构检查通过；媒体兼容、其余参数和执行结果仍需应用检查。")
    elif args.command == "pack":
        pack(args.source, args.target, args.description)
        print("已生成旧版 1.2 节点配置:", args.target)
    else:
        description = unpack(args.source, args.target)
        print("已解包:", args.target, "描述:", description)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, OverflowError, EOFError, struct.error, zlib.error) as error:
        print("错误:", error, file=sys.stderr)
        sys.exit(1)
