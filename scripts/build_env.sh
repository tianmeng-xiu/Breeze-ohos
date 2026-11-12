#!/usr/bin/env bash
# ============================================================================
# build_env.sh —— HarmonyOS 命令行构建环境（source 使用，不要直接执行）
#
#   用法:  source scripts/build_env.sh
#   之后可用: $NODE_EXE $HVIGOR_JS_REL ... assembleHap
#
# 仓库根自动从本脚本位置推导，因此不依赖任何写死的盘符路径；
# 想指向别处的工具链，用环境变量覆盖即可：
#   OHOS_ROOT          仓库根（默认 = 本脚本的上一级目录）
#   OHOS_CLI_TOOLS     Command Line Tools 根
#   OHOS_JAVA_HOME     JDK 17 根
#
# 路径一律使用 Windows 形式 (X:/...)，MSYS 的 /x/... 传给 node.exe
# 会被拼成 X:\x\... 而 ENOENT。
# ============================================================================

# MSYS/Cygwin 路径 → Windows 路径（没有 cygpath 时手工转换）
_ohos_to_win() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$p"
    return
  fi
  if [[ "$p" =~ ^/([a-zA-Z])/ ]]; then
    local drive="${BASH_REMATCH[1]}"
    printf '%s:/%s' "${drive^^}" "${p:3}"
  else
    printf '%s' "$p"
  fi
}

if [ -z "${OHOS_ROOT:-}" ]; then
  _be_self="${BASH_SOURCE[0]:-$0}"
  OHOS_ROOT="$(_ohos_to_win "$(cd "$(dirname "$_be_self")/.." && pwd)")"
  unset _be_self
fi
export OHOS_ROOT

# Command Line Tools 根（含 bin/ hvigor/ ohpm/ tool/node sdk/）
export OHOS_CLI_TOOLS="${OHOS_CLI_TOOLS:-$OHOS_ROOT/toolchain/cli-tools/command-line-tools}"

export DEVECO_SDK_HOME="$OHOS_CLI_TOOLS/sdk"
export DEVECO_NODE_HOME="$OHOS_CLI_TOOLS/tool/node"
export HVIGOR_USER_HOME="${HVIGOR_USER_HOME:-$OHOS_ROOT/toolchain/.hvigor}"

# JDK：优先用显式指定，否则在 toolchain/jdk 下找任意一个 jdk-17*
if [ -z "${JAVA_HOME:-}" ]; then
  if [ -n "${OHOS_JAVA_HOME:-}" ]; then
    JAVA_HOME="$OHOS_JAVA_HOME"
  else
    JAVA_HOME="$(ls -d "$OHOS_ROOT"/toolchain/jdk/jdk-17* 2>/dev/null | head -n 1)"
    [ -n "$JAVA_HOME" ] && JAVA_HOME="$(_ohos_to_win "$JAVA_HOME")"
  fi
fi
export JAVA_HOME

export NODE_EXE="$DEVECO_NODE_HOME/node.exe"
export npm_config_cache="${npm_config_cache:-$OHOS_ROOT/toolchain/.npm-cache}"

# 沙箱内 node 用 pipe stdio spawn 会 EPERM 的通用修复（必须预加载）
export NODE_OPTIONS="--require $OHOS_ROOT/scripts/spawn-shim.cjs"

# 调试时可打开子进程命令日志（JSONL）
# export HVIGOR_SPAWN_LOG="$OHOS_ROOT/_tmp/spawn.log"

export PATH="$DEVECO_NODE_HOME:${JAVA_HOME:+$JAVA_HOME/bin:}$PATH"

mkdir -p "$HVIGOR_USER_HOME" "$npm_config_cache" 2>/dev/null

# hvigor 入口（工程内 junction 后的路径，link_hvigor.cjs 负责建立）
export HVIGOR_JS_REL="node_modules/@ohos/hvigor/bin/hvigor.js"

build_env_summary() {
  echo "OHOS_ROOT        = $OHOS_ROOT"
  echo "DEVECO_SDK_HOME  = $DEVECO_SDK_HOME"
  echo "DEVECO_NODE_HOME = $DEVECO_NODE_HOME"
  echo "HVIGOR_USER_HOME = $HVIGOR_USER_HOME"
  echo "JAVA_HOME        = ${JAVA_HOME:-<未找到，设 OHOS_JAVA_HOME>}"
  echo "NODE_EXE         = $NODE_EXE"
  echo "NODE_OPTIONS     = $NODE_OPTIONS"
}
