// List a .hap's zip central directory (no python on this box ⇒ pure node, hand-rolled EOCD/CD).
// Also prints sha256 of the archive and of each entry's stored bytes when method=0 (STORE).
// Usage: node scripts/hap_list.cjs <path.hap> [nameFilterSubstring]
const fs = require("fs");
const crypto = require("crypto");

const file = process.argv[2];
const filter = process.argv[3] || "";
if (!file) { console.error("usage: hap_list.cjs <hap> [filter]"); process.exit(2); }
const buf = fs.readFileSync(file);
console.log("FILE " + file);
console.log("SIZE " + buf.length + "  sha256 " + crypto.createHash("sha256").update(buf).digest("hex"));

// locate EOCD (magic 0x06054b50) scanning back up to 64KB
let eocd = -1;
for (let i = buf.length - 22; i >= Math.max(0, buf.length - 65557); i--) {
  if (buf.readUInt32LE(i) === 0x06054b50) { eocd = i; break; }
}
if (eocd < 0) { console.error("EOCD not found (not a zip?)"); process.exit(1); }
const count = buf.readUInt16LE(eocd + 10);
let off = buf.readUInt32LE(eocd + 16);
let shown = 0, hit = 0;
while (off + 46 <= buf.length && buf.readUInt32LE(off) === 0x02014b50) {
  const method = buf.readUInt16LE(off + 10);
  const crc = buf.readUInt32LE(off + 16);
  const csize = buf.readUInt32LE(off + 20);
  const usize = buf.readUInt32LE(off + 24);
  const nlen = buf.readUInt16LE(off + 28);
  const elen = buf.readUInt16LE(off + 30);
  const clen = buf.readUInt16LE(off + 32);
  const lho = buf.readUInt32LE(off + 42);
  const name = buf.toString("utf8", off + 46, off + 46 + nlen);
  shown++;
  if (!filter || name.indexOf(filter) >= 0) {
    hit++;
    let sh = "";
    if (method === 0) {
      const lnl = buf.readUInt16LE(lho + 26);
      const lel = buf.readUInt16LE(lho + 28);
      const start = lho + 30 + lnl + lel;
      sh = "  sha256 " + crypto.createHash("sha256").update(buf.subarray(start, start + csize)).digest("hex");
    }
    console.log(`  ${name}  method=${method} csize=${csize} usize=${usize} crc=${crc.toString(16)}${sh}`);
  }
  off += 46 + nlen + elen + clen;
}
console.log("ENTRIES " + count + " walked=" + shown + " shown=" + hit);
