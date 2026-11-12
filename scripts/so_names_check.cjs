// S2/S3/S4 export-name byte check: each exported name must appear as an
// NUL-terminated standalone C string (0x00 + name + 0x00) in the .so.
// Bad build = 1/16 (only "init" survives), good = all.
// Historical S2/S3 packages (16 exports): pass "--n16" as argv[3].
const fs = require("fs");
const buf = fs.readFileSync(process.argv[2]);
const BASE = ["init","diagnostics","stats","registerHostCallback","unregisterHostCallback",
  "resolveBridgeCallback","rejectBridgeCallback","cancelTask","evalScript","bundleLoad",
  "bundleCall","bundleCallBytes","bundleCallOnce","bundleUnload","bundleList","selftest"];
const S4 = ["bundleLoadFromPath","pluginRemoveFile","pluginScanDir"];
const NAMES = process.argv.indexOf("--n16") >= 0 ? BASE : BASE.concat(S4);
let ok = 0, bad = [];
for (const n of NAMES) {
  const needle = Buffer.from(n, "utf8");
  let found = false;
  for (let i = 0; i + needle.length + 1 <= buf.length; i++) {
    if (buf[i] !== 0x00) continue;
    if (buf[i + 1 + needle.length] !== 0x00) continue;
    if (buf.compare(needle, 0, needle.length, i + 1, i + 1 + needle.length) === 0) { found = true; break; }
  }
  if (found) ok++; else bad.push(n);
}
console.log("NAMES_STANDALONE " + ok + "/" + NAMES.length + (bad.length ? " MISSING:" + bad.join(",") : ""));
console.log(ok === NAMES.length ? "SO-NAME-CHECK: PASS" : "SO-NAME-CHECK: FAIL");
console.log("SIZE " + buf.length);
