#!/usr/bin/env bash
# ============================================================================
# build_rust_ohos.sh —— 把 breeze_qjs_ohos（rquickjs + 上游 playground）交叉编译成
#                        aarch64-linux-ohos 的 NAPI .so，并按需拷进 Breeze-ohos 的 entry/libs。
#
#   bash scripts/build_rust_ohos.sh                  # 只编译 .so
#   bash scripts/build_rust_ohos.sh --install        # 编译后拷进 Breeze-ohos/entry/libs/arm64-v8a
#   bash scripts/build_rust_ohos.sh --clean          # 先 cargo clean 再编译
#
# 产物：breeze_qjs_ohos/target/aarch64-unknown-linux-ohos/release/libbreeze_qjs_ohos.so
#
# 关键约束（真机实测，改动前先读 README「交叉编译」一节列出的四条偏差）：
#   * 宿主工具链必须是 nightly-x86_64-pc-windows-gnu：msvc 宿主没有 link.exe，-Zbuild-std 链接必失败；
#     gnu 宿主自带 self-contained mingw 库（crt2.o/libgcc.a）可直接链接。
#   * TMP / TEMP / TMPDIR 必须逐个别 export —— `export TMP=TEMP=TMPDIR=x` 只会把 TMP 设成字符串
#     "TEMP=TMPDIR=x"，链接器会报 "Cannot create temporary file in ...: Invalid argument"。
#   * 编译临时目录固定落在工作区 _tmp/ 下（沙箱环境用户 Temp 不可写；普通机器也无害）。
#   * rquickjs 的 "macro" feature 会让 rquickjs-sys 也为宿主编一份 quickjs C 源码（proc-macro 依赖
#     rquickjs-core），所以宿主也需要 C 编译器：没有 MSVC/MinGW gcc 时，改用 NDK clang.exe
#     （其默认 target 就是 x86_64-w64-windows-gnu）+ msys2 mingw-w64 头文件。
#   * 交叉编译所需的 CC/CXX/AR/sysroot/libclang 等含本机路径的变量放在
#     breeze_qjs_ohos/.cargo/config.local.toml（gitignore），本脚本每次运行前自动生成。
#
# 原生模块装载三要件（真机踩过，缺一不可；ArkTS 侧 import from "libbreeze_qjs_ohos.so" 静默返回
# undefined 而不是报错，所以只能按这三条逐项自查）：
#   1) nm_modname 必须严格等于 so 文件名去掉 lib 前缀与 .so 后缀，本项目 = breeze_qjs_ohos。
#   2) cdylib 必须显式链 NAPI：.cargo/config.toml 的 [target.aarch64-unknown-linux-ohos].rustflags
#      加 -C link-arg=-lace_napi.z；用 llvm-objdump -p 验 NEEDED 里有 libace_napi.z.so（只有
#      libc.so 就是错的）。
#   3) ArkTS 侧要声明原生包：entry/oh-package.json5 的 dependencies 写
#      "libbreeze_qjs_ohos.so": "file:./src/main/cpp/types/libbreeze_qjs_ohos"，该目录含
#      oh-package.json5 + index.d.ts；index.d.ts 里不能 export const eval（严格模式保留字，
#      报 10505001），改 interface + declare const + export default。改完要 ohpm install --all。
#
# 手写 NAPI 导出注册的 C 串陷阱（本 crate 的 src/lib.rs 已按此实现，新增导出请照抄）：
#   凡是签名里没有 length 参数的 NAPI API —— napi_set_named_property、napi_has_named_property、
#   napi_get_named_property，以及 napi_module 的 nm_modname / nm_filename —— 名字只能传 NUL 结尾
#   C 串。递 Rust &'static str 的 as_ptr() 既不报编译错也不崩：字面量指向 .rodata 的链接器合并池，
#   不保证后面紧跟 0x00，于是第一个键（凑巧有 NUL）侥幸可用，其余全部注册到连读的垃圾键上。
#   ArkTS 侧表现 = import 成功、模块对象拿到了、但只有 init 可调、其余全 undefined，报
#   "X is not callable"，容易被误判成「模块没注册」。正确写法 = ExportSpec.name: &'static CStr
#   配 c"init" 这类字面量；注册循环不要首个失败就 return（否则其余导出全部不注册），逐项容错 +
#   napi_has_named_property 回读自检。字节级判据 = 读 .so 找「前置 0x00 + 名字 + 紧跟 0x00」
#   的出现次数，坏包 1/16、好包 16/16。
#   整包哈希不可复现（HAP 是 zip，头部内嵌 DOS 时间戳），比对包内内容请逐 entry 比 sha256。
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 本机 bash 是 winuxcmd 提供的 MSYS 风格，pwd 给的是 /e/AI/...；cargo/rustup 的环境变量必须是
# Windows 原生路径，所以统一转一次（没有 cygpath / pwd -W 可用）。
to_win() {
  case "$1" in
    /[A-Za-z]/*) printf '%s:/%s' "$(printf '%s' "${1:1:1}" | tr 'a-z' 'A-Z')" "${1:3}" ;;
    *) printf '%s' "$1" ;;
  esac
}
ROOT_W="$(to_win "$ROOT")"
CARGO_HOME_DIR="$ROOT_W/toolchain/rust/cargo"
RUSTUP_HOME_DIR="$ROOT_W/toolchain/rust/rustup"
MINGW_BINUTILS="$ROOT_W/toolchain/mingw-binutils/mingw64/bin"
SPAWN_TMP="$ROOT_W/_tmp/s1/tmp"
CRATE="$ROOT_W/breeze_qjs_ohos"
TARGET="aarch64-unknown-linux-ohos"
SO="$CRATE/target/$TARGET/release/libbreeze_qjs_ohos.so"
DEST="$ROOT_W/Breeze-ohos/entry/libs/arm64-v8a"

DO_INSTALL=0
DO_CLEAN=0
for arg in "$@"; do
  case "$arg" in
    --install) DO_INSTALL=1 ;;
    --clean) DO_CLEAN=1 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "[rust] 未知参数: $arg" >&2; exit 2 ;;
  esac
done

[ -x "$CARGO_HOME_DIR/bin/cargo.exe" ] || { echo "[rust] 缺 cargo：$CARGO_HOME_DIR/bin" >&2; echo "[rust] 请安装 Rust（rustup）并把 RUSTUP_HOME/CARGO_HOME 指到该目录，或设置这两个环境变量后重跑。" >&2; exit 3; }
mkdir -p "$SPAWN_TMP"

# 交叉编译的机器相关配置（NDK 路径 / sysroot / libclang / mingw 头文件 / git 参数）
# 不入库，每次按本机现算，写进 gitignore 的 breeze_qjs_ohos/.cargo/config.local.toml。
"$ROOT/toolchain/cli-tools/command-line-tools/tool/node/node.exe" "$ROOT/scripts/sync_cargo_config.cjs" 2>/dev/null \
  || node "$ROOT/scripts/sync_cargo_config.cjs" || echo "[rust] WARN 未能生成 config.local.toml，若编译失败请先手工跑 node scripts/sync_cargo_config.cjs" >&2

export RUSTUP_HOME="$RUSTUP_HOME_DIR"
export CARGO_HOME="$CARGO_HOME_DIR"
export PATH="$MINGW_BINUTILS:$CARGO_HOME_DIR/bin:$PATH"
export TMP="$SPAWN_TMP"
export TEMP="$SPAWN_TMP"
export TMPDIR="$SPAWN_TMP"

cd "$CRATE" || exit 3
if [ "$DO_CLEAN" = 1 ]; then
  echo "[rust] cargo clean"
  cargo +nightly-x86_64-pc-windows-gnu clean || exit 4
fi

echo "[rust] building $TARGET (release, build-std) ..."
LOG_DIR="$ROOT_W/_tmp/build-logs"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/rust-ohos-$(date +%Y%m%d-%H%M%S).log"
cargo +nightly-x86_64-pc-windows-gnu build -Zbuild-std --target "$TARGET" --release >"$LOG" 2>&1
RC=$?
if [ $RC -ne 0 ]; then
  echo "[rust] FAILED (rc=$RC)  log: $LOG" >&2
  grep -nE '^error|error\[|fatal error|cannot find|not found' "$LOG" | head -20 >&2
  exit $RC
fi

[ -f "$SO" ] || { echo "[rust] 编译成功但产物缺失: $SO" >&2; exit 5; }
echo "[rust] OK  $SO  ($(stat -c %s "$SO" 2>/dev/null || wc -c <"$SO") bytes)"

if [ "$DO_INSTALL" = 1 ]; then
  mkdir -p "$DEST"
  cp "$SO" "$DEST/" || exit 6
  echo "[rust] installed -> $DEST/libbreeze_qjs_ohos.so"
  echo "[rust] 下一步：bash scripts/build_hap.sh Breeze-ohos --mode release --noclean"
fi
