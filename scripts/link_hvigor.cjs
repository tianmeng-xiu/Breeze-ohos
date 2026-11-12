#!/usr/bin/env node
/**
 * link_hvigor.cjs —— 为任意 ArkTS 工程准备 hvigor 运行环境
 *
 *   node scripts/link_hvigor.cjs <工程目录>
 *
 * 做三件事：
 *  1. 建立 <工程>/node_modules/@ohos/hvigor 与 @ohos/hvigor-ohos-plugin 的 junction，
 *     指向 Command Line Tools 内的 hvigor 包（避开 hvigorw.js 的 pnpm bootstrap：
 *     那个包装器要 npm install pnpm 并 fork 子进程，在受限环境里必失败）。
 *  2. 缺 hvigor/hvigor-config.json5 时按工程 oh-package.json5 的 modelVersion 生成。
 *  3. 校验 modelVersion / compileSdkVersion 与 CLI 自带 SDK 是否对得上，对不上直接报错。
 */
const fs = require('fs');
const path = require('path');

// Command Line Tools 根：优先环境变量，其次 OHOS_ROOT/toolchain，最后从脚本位置推导仓库根。
const REPO = process.env.OHOS_ROOT || path.resolve(__dirname, '..');
const CT = process.env.OHOS_CLI_TOOLS || path.join(REPO, 'toolchain', 'cli-tools', 'command-line-tools');
if (!fs.existsSync(path.join(CT, 'sdk/default/sdk-pkg.json'))) {
  console.error('[link] 找不到 SDK（' + path.join(CT, 'sdk/default/sdk-pkg.json') + '）。');
  console.error('       请把 Command Line Tools 放在 <仓库根>/toolchain/cli-tools/command-line-tools，');
  console.error('       或设环境变量 OHOS_CLI_TOOLS 指向它的根目录。');
  process.exit(3);
}

const proj = process.argv[2];
if (!proj) { console.error('usage: node link_hvigor.cjs <project-dir>'); process.exit(2); }
const P = path.resolve(proj);
if (!fs.existsSync(path.join(P, 'oh-package.json5'))) {
  console.error('[link] not a HarmonyOS project (no oh-package.json5):', P); process.exit(2);
}

function readText(p) { return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : ''; }
function pick(re, s) { const m = re.exec(s); return m ? m[1] : null; }
const stripJson5 = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1').replace(/, (\s*[}\]])/g, '$1');

// --- 1. 读取 SDK 版本
const sdkPkg = JSON.parse(readText(path.join(CT, 'sdk/default/sdk-pkg.json')) || '{}');
const sdkApi = sdkPkg.data && sdkPkg.data.apiVersion;              // 26
const sdkPlatform = sdkPkg.data && sdkPkg.data.platformVersion;    // 26.0.0

// --- 2. 读取工程版本
const opText = readText(path.join(P, 'oh-package.json5'));
const modelVersion = pick(/"modelVersion"\s*:\s*"([^"]+)"/, opText);
const profileText = readText(path.join(P, 'build-profile.json5'));
const compileSdkVersion = pick(/"compileSdkVersion"\s*:\s*"([^"]+)"/, profileText);
const compatibleSdkVersion = pick(/"compatibleSdkVersion"\s*:\s*"([^"]+)"/, profileText);

// --- 3. 生成/更新 hvigor/hvigor-config.json5
const hvDir = path.join(P, 'hvigor');
const hvCfg = path.join(hvDir, 'hvigor-config.json5');
fs.mkdirSync(hvDir, { recursive: true });
const wantModel = modelVersion || sdkPlatform;
if (!fs.existsSync(hvCfg)) {
  fs.writeFileSync(hvCfg, JSON.stringify({
    modelVersion: wantModel,
    dependencies: {},
    execution: {},
    logging: { level: 'info' },
    debugging: { stacktrace: false }
  }, null, 2) + '\n');
  console.log('[link] created hvigor/hvigor-config.json5 modelVersion=' + wantModel);
} else {
  console.log('[link] hvigor/hvigor-config.json5 exists: ' + hvCfg);
}

// --- 4. junction
const nm = path.join(P, 'node_modules', '@ohos');
fs.mkdirSync(nm, { recursive: true });
for (const pkg of ['hvigor', 'hvigor-ohos-plugin']) {
  const target = path.join(CT, 'hvigor', pkg);
  const link = path.join(nm, pkg);
  if (!fs.existsSync(target)) { console.error('[link] missing CLI package: ' + target); process.exit(1); }
  try {
    const st = fs.lstatSync(link);
    if (st.isSymbolicLink()) { fs.unlinkSync(link); } else { fs.rmSync(link, { recursive: true, force: true }); }
  } catch (e) { /* absent */ }
  fs.symlinkSync(target, link, 'junction');
  console.log('[link] ' + link + ' -> ' + target);
}

// --- 5. 版本校验
const problems = [];
if (sdkPlatform && compileSdkVersion && compileSdkVersion !== sdkPlatform) {
  problems.push('compileSdkVersion=' + compileSdkVersion + ' but CLI SDK platformVersion=' + sdkPlatform);
}
if (modelVersion && sdkPlatform && modelVersion !== sdkPlatform) {
  problems.push('oh-package modelVersion=' + modelVersion + ' but CLI SDK platformVersion=' + sdkPlatform + ' (hvigor 要求两者相等)');
}
console.log('[link] sdk apiVersion=' + sdkApi + ' platformVersion=' + sdkPlatform +
  ' | project modelVersion=' + modelVersion + ' compileSdkVersion=' + compileSdkVersion +
  ' compatibleSdkVersion=' + compatibleSdkVersion);
if (problems.length) {
  console.error('[link] VERSION MISMATCH:');
  for (const p of problems) console.error('   - ' + p);
  process.exit(3);
}
console.log('[link] OK');
