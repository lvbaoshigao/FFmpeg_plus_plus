#!/usr/bin/env python3
"""生成 fppx_test 使用的旧版格式 fixture（Dart/Python gzip 互操作性验证）。

用法：python tests/gen_fixtures.py
fixture 写入系统临时目录 ffmpegpp_fppx_test/ 下，测试运行时若存在则自动加载。
"""
import json
import os
import struct
import sys
import zlib


def main():
    tmp = os.path.join(
        os.environ.get("TEMP", os.environ.get("TMPDIR", "/tmp")), "ffmpegpp_fppx_test"
    )
    os.makedirs(tmp, exist_ok=True)

    graph = {
        "nodes": [
            {"id": "da", "type": "start", "params": {"file_media_type": "video"}, "x": 0, "y": 0},
            {"id": "db", "type": "speed", "params": {"speed": 2.0}, "x": 10, "y": 10},
            {"id": "dc", "type": "output", "params": {}, "x": 20, "y": 0},
        ],
        "connections": [
            {"id": "c1", "from": "da", "to": "db", "kind": "data"},
            {"id": "c2", "from": "db", "to": "dc", "kind": "data"},
        ],
        "logicBlocks": [],
    }
    # wbits=16+zlib.MAX_WBITS → gzip 包装，等价 Dart gzip.encode
    gz = zlib.compress(json.dumps(graph).encode("utf-8"), 9, wbits=16 + zlib.MAX_WBITS)
    desc = b"python dart fixture"
    out = (
        b"FPPX"
        + bytes([1, 2, 3, 2, 1])  # config 1.2 / minSw 3 / compat 2 / mode 0x01
        + struct.pack(">H", len(desc))
        + desc
        + struct.pack(">I", len(gz))
        + gz
    )
    path = os.path.join(tmp, "dart_fixture.fppx")
    with open(path, "wb") as f:
        f.write(out)
    print(f"fixture written: {path} ({len(out)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
