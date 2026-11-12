#!/usr/bin/env bash
# ============================================================================
# build_hap.sh —— 一条命令把 ArkTS(Stage) 工程编成未签名 .hap
#
#   bash scripts/build_hap.sh <工程目录|工程名> [--mode debug|release] [--clean|--noclean]
#   bash scripts/build_hap.sh Breeze-ohos --mode release
#   bash scripts/build_hap.sh Breeze-ohos --mode release --noclean
#
# 说明:
#   * 工程名相对 $OHOS_ROOT 解析；也可给绝对路径 / 相对当前目录的路径。
#   * 内部会 source scripts/build_env.sh，所以干净 bash 里直接跑即可，
#     无需手工 export 任何变量。
#   * 自动为工程建立 node_modules/@ohos 两个 junction（见 link_hvigor.cjs）。
#   * 产物: <工程>/entry/build/default/outputs/default/entry-default-unsigned.hap
#   * 失败时把日志里 ERROR/At File: 等关键行 tail 40 行到 stderr，退出码非 0。
# ============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/build_env.sh"

PROJ_ARG=""
BUILD_MODE="debug"
DO_CLEAN="clean"

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) BUILD_MODE="${2:-debug}"; shift 2 ;;
    --mode=*) BUILD_MODE="${1#*=}"; shift ;;
    --project) PROJ_ARG="${2:-}"; shift 2 ;;
    --project=*) PROJ_ARG="${1#*=}"; shift ;;
    --clean) DO_CLEAN="clean"; shift ;;
    --noclean) DO_CLEAN="noclean"; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) PROJ_ARG="$1"; shift ;;
  esac
done
PROJ_ARG="${PROJ_ARG:-Breeze-ohos}"

case "$BUILD_MODE" in debug|release) ;; *) echo "[build] --mode 只能是 debug 或 release" >&2; exit 2 ;; esac

case "$PROJ_ARG" in
  /*|[A-Za-z]:*) PROJ="$PROJ_ARG" ;;
  *)
    if [ -f "$PROJ_ARG/oh-package.json5" ]; then PROJ="$(cd "$PROJ_ARG" && pwd)"
    else PROJ="$OHOS_ROOT/$PROJ_ARG"; fi ;;
esac
if [ ! -f "$PROJ/oh-package.json5" ]; then
  echo "[build] 不是工程目录（缺 oh-package.json5）: $PROJ" >&2
  exit 2
fi

echo "[build] project = $PROJ  mode=$BUILD_MODE  $DO_CLEAN"
"$NODE_EXE" "$SCRIPT_DIR/link_hvigor.cjs" "$PROJ" || { echo "[build] 环境准备失败" >&2; exit 3; }

cd "$PROJ" || exit 3
LOG_DIR="$OHOS_ROOT/_tmp/build-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$(basename "$PROJ")-$BUILD_MODE-$(date +%Y%m%d-%H%M%S).log"
: >"$LOG"

if [ "$DO_CLEAN" = "clean" ]; then
  echo "[build] clean ..."
  "$NODE_EXE" "$HVIGOR_JS_REL" --mode module -p product=default -p buildMode="$BUILD_MODE" clean --no-daemon >>"$LOG" 2>&1
fi

echo "[build] assembleHap ... (log: $LOG)"
"$NODE_EXE" "$HVIGOR_JS_REL" --mode module -p product=default -p buildMode="$BUILD_MODE" assembleHap --no-daemon >>"$LOG" 2>&1
RC=$?

HAP="entry/build/default/outputs/default/entry-default-unsigned.hap"
if [ $RC -eq 0 ] && [ -f "$HAP" ]; then
  SIZE=$(stat -c %s "$HAP" 2>/dev/null || echo 0)
  echo "[build] SUCCESS  $PROJ/$HAP  ($SIZE bytes, mode=$BUILD_MODE)"
  exit 0
fi

echo "[build] FAILED (exit $RC)" >&2
sed 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -aE "ERROR|Error Message|COMPILE RESULT|At File:|BUILD FAILED" | tail -40 >&2
echo "[build] full log: $LOG" >&2
exit $RC
