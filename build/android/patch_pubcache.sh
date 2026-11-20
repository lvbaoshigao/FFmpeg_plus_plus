#!/usr/bin/env bash
# Only old file-picker Android implementations pin compileSdk below 36.
# file_picker 13.x may delegate to android_file_picker; follow package_config
# instead of assuming the Dart facade contains an Android Gradle project.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

python3 - "$FFMPEGPP_ROOT/ffmpegpp_gui/.dart_tool/package_config.json" <<'PY'
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urljoin, urlparse

config = Path(sys.argv[1]).resolve()
if not config.exists():
    print('INFO: package_config.json is absent; no legacy file-picker patch applied')
    raise SystemExit(0)

matched = False
for package in json.loads(config.read_text()).get('packages', []):
    if package.get('name') not in {'file_picker', 'android_file_picker'}:
        continue
    uri = urlparse(urljoin(config.as_uri(), package['rootUri']))
    if uri.scheme != 'file':
        continue
    root = Path(unquote(uri.path))
    for relative in ['android/build.gradle', 'android/build.gradle.kts']:
        build = root / relative
        if not build.is_file():
            continue
        matched = True
        original = build.read_text()
        pattern = re.compile(r'^(\s*compileSdk(?:Version)?\s*(?:=\s*|\s+))(\d+)', re.MULTILINE)
        def update(match):
            return match.group(1) + str(max(36, int(match.group(2))))
        patched = pattern.sub(update, original)
        if patched != original:
            build.write_text(patched)
            print(f'pubcache: raised legacy compileSdk to 36: {build}')
        else:
            print(f'INFO: {package["name"]} compileSdk needs no legacy patch: {build}')
if not matched:
    print('INFO: file-picker uses no legacy Android Gradle file; no patch needed')
PY
