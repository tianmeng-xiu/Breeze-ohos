#!/usr/bin/env node
/**
 * sync_cargo_config.cjs —— 从仓库根生成 breeze_qjs_ohos/.cargo/config.local.toml
 *
 *   node scripts/sync_cargo_config.cjs            # 生成/更新
 *   node scripts/sync_cargo_config.cjs --check     # 只校验是否需要更新（不写文件）
 *
 * 为什么需要它：
 *   .cargo/config.toml 需要随源码入库，但交叉编译用到的一堆路径（NDK clang、sysroot、
 *   libclang、mingw 头文件、临时目录、CA bundle）每台机器都不一样，硬写进 config.toml
 *   既泄露本机路径又让换机器的人编不动。故 config.toml 只留机器无关项，含路径的部分
 *   由本脚本按仓库根 + 环境变量现算，写进 gitignore 的 config.local.toml，
 *   再由 config.toml 顶部的 include（optional）引入。
 *
 * 可用环境变量覆盖（默认都相对仓库根）：
 *   OHOS_ROOT       仓库根
 *   OHOS_NDK        NDK 根（默认 <root>/toolchain/cli-tools/command-line-tools/sdk/default/openharmony/native）
 *   OHOS_MINGW_INC  宿主侧 mingw-w64 头文件目录（默认 <root>/toolchain/mingw-gcc/mingw64/mingw64/include）
 *   OHOS_CARGO_TMP  编译临时目录（默认 <root>/_tmp/s1/tmp）
 *   OHOS_GIT_CAINFO git 用的 CA bundle（默认 <root>/_tmp/s1/cacert.pem，缺省则不写该项）
 *   OHOS_GIT_PROXY  GitHub 镜像前缀（默认 https://gh-proxy.com/，设为空串则不写 insteadOf）
 */
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(process.env.OHOS_ROOT || path.join(__dirname, '..'));
const toWin = (p) => p.replace(/\\/g, '/');
const NDK = toWin(process.env.OHOS_NDK ||
  path.join(ROOT, 'toolchain', 'cli-tools', 'command-line-tools', 'sdk', 'default', 'openharmony', 'native'));
const MINGW_INC = toWin(process.env.OHOS_MINGW_INC ||
  path.join(ROOT, 'toolchain', 'mingw-gcc', 'mingw64', 'mingw64', 'include'));
const TMPD = toWin(process.env.OHOS_CARGO_TMP || path.join(ROOT, '_tmp', 's1', 'tmp'));
const CAINFO = process.env.OHOS_GIT_CAINFO === undefined
  ? toWin(path.join(ROOT, '_tmp', 's1', 'cacert.pem'))
  : process.env.OHOS_GIT_CAINFO;
const GIT_PROXY = process.env.OHOS_GIT_PROXY === undefined ? 'https://gh-proxy.com/' : process.env.OHOS_GIT_PROXY;

const TARGET = 'aarch64-unknown-linux-ohos';
const SYSROOT = `${NDK}/sysroot`;
const Q = (s) => `"${s}"`;
const lines = [];
lines.push('# 本文件由 scripts/sync_cargo_config.cjs 生成，已 gitignore，请勿手工编辑、请勿提交。');
lines.push(`# 生成时间 ${new Date().toISOString()}；仓库根 ${toWin(ROOT)}`);
lines.push('[env]');
lines.push(`TMP = ${Q(TMPD)}`);
lines.push(`TEMP = ${Q(TMPD)}`);
lines.push(`TMPDIR = ${Q(TMPD)}`);
lines.push(`CC = ${Q(`${NDK}/llvm/bin/clang.exe`)}`);
lines.push(`CXX = ${Q(`${NDK}/llvm/bin/clang++.exe`)}`);
lines.push(`AR = ${Q(`${NDK}/llvm/bin/llvm-ar.exe`)}`);
lines.push(`CC_aarch64_unknown_linux_ohos = ${Q(`${NDK}/llvm/bin/clang.exe`)}`);
lines.push(`CXX_aarch64_unknown_linux_ohos = ${Q(`${NDK}/llvm/bin/clang++.exe`)}`);
lines.push(`AR_aarch64_unknown_linux_ohos = ${Q(`${NDK}/llvm/bin/llvm-ar.exe`)}`);
lines.push('CC_aarch64_unknown_linux_ohos_ar = "llvm-ar"');
const xflags = `--target=${TARGET} --sysroot=${SYSROOT} -D__MUSL__`;
lines.push(`CFLAGS_${TARGET.replace(/-/g, '_')} = ${Q(xflags)}`);
lines.push(`CXXFLAGS_${TARGET.replace(/-/g, '_')} = ${Q(xflags)}`);
lines.push(`CFLAGS_x86_64_pc_windows_gnu = ${Q(`-isystem ${MINGW_INC}`)}`);
lines.push(`CXXFLAGS_x86_64_pc_windows_gnu = ${Q(`-isystem ${MINGW_INC}`)}`);
lines.push(`LIBCLANG_PATH = ${Q(`${NDK}/llvm/lib`)}`);
lines.push(`BINDGEN_EXTRA_CLANG_ARGS_${TARGET.replace(/-/g, '_')} = ${Q(xflags)}`);
if (CAINFO) lines.push(`GIT_SSL_CAINFO = ${Q(CAINFO)}`);
// git-fetch-with-cli 需要走 git 可执行文件；镜像与 http 调参随本机网络环境而定，故不进 config.toml
let gi = 0;
const gitCfg = (k, v) => { lines.push(`GIT_CONFIG_KEY_${gi} = ${Q(k)}`); lines.push(`GIT_CONFIG_VALUE_${gi} = ${Q(v)}`); gi += 1; };
gitCfg('http.sslBackend', 'openssl');
gitCfg('http.version', 'HTTP/1.1');
if (GIT_PROXY) gitCfg('url.' + GIT_PROXY + 'https://github.com/.insteadOf', 'https://github.com/');
gitCfg('http.postBuffer', '524288000');
gitCfg('http.lowSpeedLimit', '0');
gitCfg('http.lowSpeedTime', '999999');
lines.push(`GIT_CONFIG_COUNT = "${gi}"`);
lines.push('');
lines.push(`[target.${TARGET}]`);
lines.push(`linker = ${Q(`${NDK}/llvm/bin/clang.exe`)}`);
lines.push('rustflags = [');
lines.push(`  "-C", "link-arg=--sysroot=${SYSROOT}",`);
lines.push(']');
const text = lines.join('\n') + '\n';

const cargoDir = path.join(ROOT, 'breeze_qjs_ohos', '.cargo');
const out = path.join(cargoDir, 'config.local.toml');
if (process.argv.includes('--check')) {
  const cur = fs.existsSync(out) ? fs.readFileSync(out, 'utf8') : '';
  // 只比较生成内容（忽略生成时间行）
  const strip = (s) => s.split('\n').slice(2).join('\n');
  const need = strip(cur) !== strip(text);
  console.log('[cargo-cfg] ' + (need ? 'NEEDS-REGEN (run: node scripts/sync_cargo_config.cjs)' : 'up-to-date') + '  ' + out);
  process.exit(need ? 1 : 0);
}
if (!fs.existsSync(cargoDir)) fs.mkdirSync(cargoDir, { recursive: true });
fs.writeFileSync(out, text, 'utf8');
console.log('[cargo-cfg] wrote ' + out + ' (' + Buffer.byteLength(text) + ' B)');
if (!fs.existsSync(NDK)) console.log('[cargo-cfg] WARN NDK 路径不存在：' + NDK + '（用 OHOS_NDK 指定）');
if (!fs.existsSync(MINGW_INC)) console.log('[cargo-cfg] WARN mingw 头文件目录不存在：' + MINGW_INC + '（用 OHOS_MINGW_INC 指定）');
