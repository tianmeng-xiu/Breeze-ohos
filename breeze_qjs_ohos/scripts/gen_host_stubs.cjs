// 生成宿主单元测试用的 NAPI 桩：src/*.rs 里所有 `extern "C" { ... }` 声明的 napi_* 等
// 外部符号在 windows 宿主上没有实现（真机由 libace_napi.z.so 提供），`cargo test --lib`
// 链接期会报 undefined reference to `napi_xxx`。本脚本扫描 extern 块里的符号名，产出
// src/host_stubs.rs：每个符号一个 #[no_mangle] 空桩（C ABI 只看符号名，签名无需一致），
// 且整文件 #[cfg(all(test, not(target_os = "ohos")))]，真机构建零影响。
// 用法：node scripts/gen_host_stubs.cjs   （改完 extern 块后重跑）
const fs = require("fs");
const path = require("path");
const srcDir = path.join(__dirname, "..", "src");
const names = new Set();
for (const f of fs.readdirSync(srcDir)) {
  if (!f.endsWith(".rs")) continue;
  const text = fs.readFileSync(path.join(srcDir, f), "utf8");
  const blocks = text.match(/extern\s+"C"\s*\{[\s\S]*?\n\}/g) || [];
  for (const b of blocks) {
    // 每条声明形如：fn napi_foo(  或  static FOO:
    for (const m of b.matchAll(/\bfn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g)) names.add(m[1]);
    for (const m of b.matchAll(/^\s*static\s+(?:mut\s+)?([A-Za-z_][A-Za-z0-9_]*)/gm)) names.add(m[1]);
  }
}
const sorted = [...names].sort();
const out = [
  "// 自动生成，勿手改：node scripts/gen_host_stubs.cjs",
  "// 宿主 `cargo test --lib` 链接桩（见脚本头注释）。",
  '#![cfg(all(test, not(target_os = "ohos")))]',
  "",
  ...sorted.map(
    (n) =>
      `#[no_mangle]\npub extern "C" fn ${n}() -> i32 {\n    1\n}`
  ),
  "",
].join("\n");
const dest = path.join(srcDir, "host_stubs.rs");
fs.writeFileSync(dest, out, "utf8");
console.log("WROTE " + dest + " symbols=" + sorted.length);
