#!/usr/bin/env python3
"""Mirror reviewed SDK text resources to one flat Flutter asset directory."""
import argparse
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT.parent / "ffmpegpp_gui" / "assets" / "plugin_sdk"
FILES = [
    "README.md", "LICENSE", "include/ffmpegpp_plugin.h",
    "schema/manifest.schema.json", "schema/theme.schema.json", "schema/ai-config.schema.json",
    "tools/build_plugin.py", "tools/self_test.mjs",
    "examples/audio-gain/manifest.json", "examples/audio-gain/plugin.c",
    "examples/video-flip/manifest.json", "examples/video-flip/plugin.c",
    "examples/theme-ai/manifest.json",
]


def synchronize(check=False):
    expected = {name.replace("/", "__"): (ROOT / name).read_bytes() for name in FILES}
    expected["files.json"] = (json.dumps(FILES, indent=2) + "\n").encode("utf-8")
    if len(expected) != len(FILES) + 1:
        raise ValueError("flat SDK asset names collide")
    stale = [name for name, data in expected.items() if not (ASSETS / name).is_file() or (ASSETS / name).read_bytes() != data]
    if check:
        if stale:
            print("Outdated SDK assets:", ", ".join(stale), file=sys.stderr)
            return 1
    else:
        ASSETS.mkdir(parents=True, exist_ok=True)
        for name, data in expected.items():
            (ASSETS / name).write_bytes(data)
    print("SDK assets:", len(FILES), "sources", "verified" if check else "synchronized")
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    sys.exit(synchronize(parser.parse_args().check))
