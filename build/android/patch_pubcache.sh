#!/usr/bin/env bash
# 幂等修补 pub 缓存中 file_picker 的 compileSdk（34 → 36）。
# 原因：file_picker 8.x 固定 compileSdk 34，而其依赖
# flutter_plugin_android_lifecycle 2.0.35 要求 ≥36，否则 Gradle 的
# checkReleaseAarMetadata 失败。
#
# 自动搜索多个可能的 pub 缓存位置（+ 从 package_config.json 推导），
# 不依赖 $PUB_CACHE 环境变量是否与 flutter pub get 实际使用的路径一致。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# ── 收集候选 pub 缓存根目录 ──
CANDIDATES=()

# 1. PUB_CACHE 环境变量（如果非空）
if [ -n "${PUB_CACHE:-}" ]; then
  CANDIDATES+=("$PUB_CACHE")
fi

# 2. 默认 pub 缓存
CANDIDATES+=("$HOME/.pub-cache")

# 3. GitHub Actions runner tool cache（subosito/flutter-action 可能设 PUB_CACHE 在此）
if [ -n "${RUNNER_TOOL_CACHE:-}" ]; then
  CANDIDATES+=("$RUNNER_TOOL_CACHE/flutter/.pub-cache")
fi

# 4. 从 package_config.json 推导插件真实路径（权威，不受环境变量影响）
PC="$FFMPEGPP_ROOT/ffmpegpp_gui/.dart_tool/package_config.json"
PC_ROOT=""
if [ -f "$PC" ]; then
  PC_ROOT=$(python3 - "$PC" <<'PYEOF' 2>/dev/null || true
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
    for p in cfg.get("packages", []):
        if p.get("name") == "file_picker":
            u = p.get("rootUri", "").replace("file://", "")
            print(u.strip())
            break
except Exception:
    pass
PYEOF
)
fi

# ── 去重候选（保留顺序） ──
declare -A _seen
DEDUP=()
for c in "${CANDIDATES[@]}"; do
  [ -z "$c" ] && continue
  [ -n "${_seen[$c]:-}" ] && continue
  _seen[$c]=1
  DEDUP+=("$c")
done

# ── 在候选目录中查找 file_picker 并修补 ──
PATCHED=0
SEARCHED_DIRS=""

# 候选 pub 根目录下的 hosted/pub.dev
for root in "${DEDUP[@]}"; do
  hostdir="$root/hosted/pub.dev"
  [ -d "$hostdir" ] || continue
  for d in "$hostdir"/file_picker-*; do
    [ -d "$d" ] || continue
    fp_build="$d/android/build.gradle"
    [ -f "$fp_build" ] || continue
    SEARCHED_DIRS="$SEARCHED_DIRS $fp_build"
    if grep -qE '^[[:space:]]*compileSdk[[:space:]]+36' "$fp_build"; then
      echo "pubcache: $fp_build 已是 compileSdk 36，无需修补"
      PATCHED=1
      continue
    fi
    if grep -qE '^[[:space:]]*compileSdk[[:space:]]+3[0-9]+' "$fp_build"; then
      sed -i -E 's/^([[:space:]]*)compileSdk[[:space:]]+3[0-9]+/\1compileSdk 36/' "$fp_build"
      # 验证
      if grep -qE '^[[:space:]]*compileSdk[[:space:]]+36' "$fp_build"; then
        echo "pubcache: 已修补 $fp_build → compileSdk 36"
        PATCHED=1
      else
        echo "pubcache: 修补失败（sed 后未找到 compileSdk 36）: $fp_build" >&2
        echo "pubcache: 实际内容: $(grep compileSdk "$fp_build")" >&2
      fi
    fi
  done
done

# 如果 package_config.json 指向的路径不在候选目录中，也尝试修补
if [ -n "$PC_ROOT" ]; then
  pc_build="$PC_ROOT/android/build.gradle"
  if [ -f "$pc_build" ]; then
    case "$SEARCHED_DIRS" in
      *"$pc_build"*) ;;  # 已在候选中被覆盖
      *)
        if grep -qE '^[[:space:]]*compileSdk[[:space:]]+34' "$pc_build" && ! grep -qE '^[[:space:]]*compileSdk[[:space:]]+36' "$pc_build"; then
          sed -i -E 's/^([[:space:]]*)compileSdk[[:space:]]+3[0-9]+/\1compileSdk 36/' "$pc_build"
          if grep -qE '^[[:space:]]*compileSdk[[:space:]]+36' "$pc_build"; then
            echo "pubcache: 已修补（package_config.json 路径）$pc_build → compileSdk 36"
            PATCHED=1
          fi
        fi
        ;;
    esac
  fi
fi

if [ "$PATCHED" -eq 0 ]; then
  echo "WARN: 未找到需要修补的 file_picker build.gradle" >&2
  echo "WARN: 候选 pub 根目录: ${DEDUP[*]:-(none)}" >&2
  [ -n "$PC_ROOT" ] && echo "WARN: package_config.json 指向: $PC_ROOT" >&2
  echo "WARN: 若 file_picker 未在 pub 缓存中，请先运行 flutter pub get" >&2
  exit 0
fi