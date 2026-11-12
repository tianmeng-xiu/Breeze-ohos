/**
 * 职责：纯 ArkTS 的 MD5（RFC 1321）—— 只为 JM 系图站的「分块混淆块数」推导服务。
 * 为什么自己实现（重要，勿改回 SDK）：本 SDK 的 @ohos.security.cryptoFramework **没有 MD5**
 *   （ets/api/@ohos.security.cryptoFramework.d.ts 全文 grep 'MD5' = 0 命中，createMd 只接算法名，
 *    传 'MD5' 属未声明行为，真机可能抛 2203805），而块数公式要求 md5(chapterId + 图片文件名)。
 *   上游那份是 Rust 侧 md-5 crate（Breeze/rust/src/decode/segmentation.rs:59 md5::compute）。
 *   引擎 polyfill 里虽有 crypto.md5 路由，但每页跨一次 QJS 往返不值，且阅读器不该依赖引擎可达。
 * 依据系统 Kit：@kit.ArkTS（TextEncoder 取 UTF-8 字节，与 node Buffer.from(s,'utf8') 同字节序）。
 */
import { util } from '@kit.ArkTS';

/** 每轮左移位数（RFC 1321 表）。 */
const S: number[] = [
  7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
  5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21
];

/** K[i] = floor(abs(sin(i+1)) * 2^32)。 */
const K: number[] = buildK();

function buildK(): number[] {
  const out: number[] = [];
  for (let i = 0; i < 64; i++) {
    out.push((Math.floor(Math.abs(Math.sin(i + 1)) * 4294967296)) >>> 0);
  }
  return out;
}

function rotl(x: number, c: number): number {
  return ((x << c) | (x >>> (32 - c))) >>> 0;
}

/** 小端 32bit 读。 */
function le32(b: Uint8Array, p: number): number {
  return (b[p] | (b[p + 1] << 8) | (b[p + 2] << 16) | (b[p + 3] << 24)) >>> 0;
}

/**
 * 32bit 乘法：JS 双精度直接 a*b 会丢精度（两个 32 位无符号相乘可达 1.8e19 > 2^53），
 * 必须 Math.imul（等价 C 的 uint32 乘法）。
 */
function mul32(a: number, b: number): number {
  return Math.imul(a, b) >>> 0;
}

/**
 * 对字符串取 MD5，返回 32 位小写十六进制。
 * 上游只用到「十六进制串的最后一个字符」，但完整返回便于离线桩逐字节对拍。
 */
export function md5Hex(text: string): string {
  const encoder: util.TextEncoder = new util.TextEncoder();
  const bytes: Uint8Array = encoder.encodeInto(text);
  const bitLenLo: number = (bytes.length * 8) >>> 0;
  const bitLenHi: number = Math.floor(bytes.length / 536870912) >>> 0; // 2^29 字节 = 2^32 bit

  // 填充：0x80 + 若干 0 + 8 字节小端长度，总长为 64 的倍数
  let withOne: number = bytes.length + 1;
  const padZeros: number = ((56 - withOne) % 64 + 64) % 64;
  const total: number = withOne + padZeros + 8;
  const buf: Uint8Array = new Uint8Array(total);
  buf.set(bytes, 0);
  buf[bytes.length] = 0x80;
  const tail: number = total - 8;
  buf[tail] = bitLenLo & 0xff;
  buf[tail + 1] = (bitLenLo >>> 8) & 0xff;
  buf[tail + 2] = (bitLenLo >>> 16) & 0xff;
  buf[tail + 3] = (bitLenLo >>> 24) & 0xff;
  buf[tail + 4] = bitLenHi & 0xff;
  buf[tail + 5] = (bitLenHi >>> 8) & 0xff;
  buf[tail + 6] = (bitLenHi >>> 16) & 0xff;
  buf[tail + 7] = (bitLenHi >>> 24) & 0xff;

  let a0: number = 0x67452301;
  let b0: number = 0xefcdab89;
  let c0: number = 0x98badcfe;
  let d0: number = 0x10325476;

  const m: number[] = [];
  for (let off = 0; off < total; off += 64) {
    for (let i = 0; i < 16; i++) {
      m[i] = le32(buf, off + i * 4);
    }
    let a: number = a0;
    let b: number = b0;
    let c: number = c0;
    let d: number = d0;
    for (let i = 0; i < 64; i++) {
      let f: number = 0;
      let g: number = 0;
      if (i < 16) {
        f = (b & c) | ((~b) & d);
        g = i;
      } else if (i < 32) {
        f = (d & b) | ((~d) & c);
        g = (5 * i + 1) % 16;
      } else if (i < 48) {
        f = (b ^ c ^ d) >>> 0;
        g = (3 * i + 5) % 16;
      } else {
        f = (c ^ (b | ((~d) >>> 0))) >>> 0;
        g = (7 * i) % 16;
      }
      f = (f + a + K[i] + m[g]) >>> 0;
      a = d;
      d = c;
      c = b;
      b = (b + rotl(f, S[i])) >>> 0;
    }
    a0 = (a0 + a) >>> 0;
    b0 = (b0 + b) >>> 0;
    c0 = (c0 + c) >>> 0;
    d0 = (d0 + d) >>> 0;
  }

  const words: number[] = [a0, b0, c0, d0];
  let hex: string = '';
  for (let w = 0; w < 4; w++) {
    for (let k = 0; k < 4; k++) {
      const byte: number = (words[w] >>> (k * 8)) & 0xff;
      hex += byte < 16 ? '0' + byte.toString(16) : byte.toString(16);
    }
  }
  return hex;
}
