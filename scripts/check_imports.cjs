const fs = require('fs');
const path = require('path');
// 仓库根从脚本位置推导；也可用 OHOS_ROOT 覆盖，或把目标目录作为第一个参数传入。
const REPO = process.env.OHOS_ROOT || path.resolve(__dirname, '..');
const ROOT = process.argv[2] || path.join(REPO, 'Breeze-ohos', 'entry', 'src', 'main', 'ets');
if (!fs.existsSync(ROOT)) {
  console.error('[imports] 目录不存在: ' + ROOT);
  process.exit(2);
}
function walk(d, acc) { acc = acc || []; for (const e of fs.readdirSync(d, { withFileTypes: true })) { const p = path.join(d, e.name); if (e.isDirectory()) walk(p, acc); else if (e.name.endsWith('.ets')) acc.push(p); } return acc; }
const files = walk(ROOT);
const cache = new Map();
function exportsOf(p) {
  if (cache.has(p)) return cache.get(p);
  const src = fs.readFileSync(p, 'utf8');
  const set = new Set();
  let m;
  const reDecl = /export\s+(?:default\s+)?(?:abstract\s+)?(?:async\s+)?(?:class|struct|interface|const|let|var|function|enum|type)\s+([A-Za-z0-9_$]+)/g;
  while ((m = reDecl.exec(src))) set.add(m[1]);
  const reList = /export\s*\{([^}]*)\}/g;
  while ((m = reList.exec(src))) { m[1].split(',').forEach(function (s) { const t = s.trim().split(/\s+as\s+/).pop().trim(); if (t) set.add(t); }); }
  cache.set(p, set);
  return set;
}
const problems = [];
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  const re = /import\s*\{([^}]+)\}\s*from\s*['"]([^'"]+)['"]/g;
  let m;
  while ((m = re.exec(src))) {
    const names = m[1].split(',').map(function (s) { return s.trim().split(/\s+as\s+/)[0].trim(); }).filter(Boolean);
    const spec = m[2];
    if (spec.charAt(0) !== '.') continue;
    const base = path.resolve(path.dirname(f), spec);
    const cand = [base + '.ets', path.join(base, 'index.ets')];
    let target = null;
    for (const c of cand) if (fs.existsSync(c)) { target = c; break; }
    if (!target) { problems.push('MISSING FILE ' + path.relative(ROOT, f) + ' -> ' + spec); continue; }
    const ex = exportsOf(target);
    for (const n of names) if (!ex.has(n)) problems.push('MISSING EXPORT ' + n + ' in ' + path.relative(ROOT, target) + ' (by ' + path.relative(ROOT, f) + ')');
  }
}
console.log('files scanned: ' + files.length);
console.log(problems.length ? problems.join('\n') : 'NO IMPORT PROBLEMS');
process.exit(problems.length ? 1 : 0);