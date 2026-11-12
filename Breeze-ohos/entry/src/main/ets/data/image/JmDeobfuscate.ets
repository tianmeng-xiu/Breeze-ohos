/**
 * 职责：JM 系图站「水平分块混淆」的反混淆 + 内容自适应检测。
 *   真机 BUG（截图 m05809）：一张漫画页被切成约 10 个等高水平条带且**顺序倒置**（上半黑边、下半天空）。
 *   下载与解码都成功，只是块序反了；插件不做还原（bundle 里 scramble/segment/decodeImage 计数全 = 0）
 *   ⇒ 必须宿主自己做。
 *
 * 算法逐条对齐上游 Rust（**勿自创**）：
 *   - Breeze/rust/src/decode/decode.rs:9   `const SCRAMBLE_ID: i32 = 220980;`
 *   - Breeze/rust/src/decode/segmentation.rs:13  picture_name = url 末段再按 '.' 切第一段
 *   - :52 get_segmentation_num（三段阈值 + md5 十六进制串**最后一个字符的 ASCII 码**取模）
 *   - :29-41 block_size = h/num，remainder = h%num，**最后一块吃 remainder**
 *   - :81 `for &(start,end) in blocks.iter().rev()` ⇒ 源块倒序依次拷到目标顶部往下
 * 与上游三处有意差异：
 *   1. 上游重编码 quality 75 webp；我们直接改 PixelMap 像素（不重编码 ⇒ 无损、省 CPU）。
 *   2. 上游按 RgbImage（3 通道）搬；我们按 PixelMap 缓冲区（RGBA_8888，4 通道）搬，
 *      并先用 getPixelBytesNumber() 校验 stride == w*4，不等直接跳过 —— 宁花屏不崩。
 *   3. **判据**：上游 = `uuid == bf99008d… || 插件 isJm 返回裸 true`（picture.dart:42-89）。
 *      实测手里两个 JM 系 bundle（jjmhw 0.4.0 / mhg 0.1.0）**都没导出 isJm**、uuid 也不同
 *      ⇒ 上游那套对真机这批插件恒 false（上游同样不会反混淆它们）。故本方在 uuid/isJm 之外
 *      再加「内容自证」检测 + 插件设置页手动强开/强关，判据三级：手动 > uuid/isJm > 内容检测。
 * ★ 与上游一致的一处**已知不完美**（bug-compatible，勿改）：h % num ≠ 0 时，上游与本实现都把
 *   remainder 加在**源侧最后一块**，于是重排后接缝会偏移最多 remainder 行（1080 高、num=14/16 时
 *   2–8 行的错位）。要「数学正确」就得改成目标侧 tall-first，那会与上游产物不一致 ⇒ 保持原样。
 */
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { md5Hex } from './Md5';
import { Logger } from '../../util/Logger';

/** 与上游 decode.rs:9 同值，勿改。 */
export const SCRAMBLE_ID: number = 220980;

/** 上游 picture.dart:23 写死的 JM 插件 uuid（仅白名单用，见文件头差异 3）。 */
export const JM_PLUGIN_UUID: string = 'bf99008d-010b-4f17-ac7c-61a9b57dc3d9';

/** 反混淆模式（preferences 键 `jmDeobf:<插件 uuid>`）。 */
export class JmMode {
  static readonly AUTO: string = 'auto';
  static readonly ON: string = 'on';
  static readonly OFF: string = 'off';
}

/**
 * 分块数（逐字对应上游 get_segmentation_num）。
 * 注意上游取 **md5 十六进制串最后一个字符的 ASCII 码**再取模，不是该字符的数值。
 */
export function segmentationNum(chapterId: number, pictureName: string): number {
  if (chapterId < SCRAMBLE_ID) {
    return 0;
  }
  if (chapterId < 268850) {
    return 10;
  }
  const hex: string = md5Hex('' + chapterId + pictureName);
  if (hex.length === 0) {
    return 0;
  }
  const lastCode: number = hex.charCodeAt(hex.length - 1);
  if (chapterId > 421926) {
    return (lastCode % 8) * 2 + 2;
  }
  return (lastCode % 10) * 2 + 2;
}

/** url → picture_name（上游 rsplit('/').next().split('.').next()）。 */
export function pictureNameOf(url: string): string {
  const idx: number = url.lastIndexOf('/');
  const last: string = idx >= 0 ? url.slice(idx + 1) : url;
  const dot: number = last.indexOf('.');
  return dot >= 0 ? last.slice(0, dot) : last;
}

/** 字节魔数是否 GIF（上游 num<=1 || GIF 直接原样返回）。 */
export function isGifBytes(buf: ArrayBuffer): boolean {
  if (buf.byteLength < 4) {
    return false;
  }
  const b: Uint8Array = new Uint8Array(buf, 0, 4);
  return b[0] === 0x47 && b[1] === 0x49 && b[2] === 0x46 && b[3] === 0x38; // 'GIF8'
}

/** 判据：手动开关优先，其次 uuid 白名单，最后插件 isJm 探测结果。 */
export function shouldDeobfuscate(mode: string, uuid: string, probedIsJm: boolean): boolean {
  if (mode === JmMode.OFF) {
    return false;
  }
  if (mode === JmMode.ON) {
    return true;
  }
  if (uuid === JM_PLUGIN_UUID) {
    return true;
  }
  return probedIsJm;
}

/**
 * 把 src 的 num 个水平块**倒序**搬进 dst（上游 :79-93 的逐字实现，纯函数便于离线对拍）。
 * 返回 false = 参数越界（未完整写 dst）。
 */
export function rearrangeBlocks(
  sv: Uint8Array,
  dv: Uint8Array,
  h: number,
  num: number,
  rowBytes: number
): boolean {
  const blockRows: number = Math.floor(h / num);
  if (blockRows <= 0) {
    return false;
  }
  const blockBytes: number = blockRows * rowBytes;
  const lastBlockBytes: number = blockBytes + (h % num) * rowBytes;
  const total: number = sv.length;
  let dstY: number = 0;
  for (let i = num - 1; i >= 0; i--) {
    const len: number = i === num - 1 ? lastBlockBytes : blockBytes;
    const srcBegin: number = i * blockBytes;
    const srcEnd: number = srcBegin + len;
    const dstBegin: number = dstY * rowBytes;
    if (srcEnd > total || dstBegin + len > total) {
      return false;
    }
    for (let k = 0; k < len; k++) {
      dv[dstBegin + k] = sv[srcBegin + k];
    }
    dstY += len / rowBytes;
  }
  return true;
}

// ------------------------------------------------------------------ 内容自证检测
//
// 判据不用「块边界处是否断裂」，用**全图纵向不连续总量**：
//   设原图 O 被切成 num 块倒序存成 S。S 里「相邻两行」的集合 = O 里除 num-1 对之外全部相邻行
//   + num-1 对「跨整块」的行。⇒ Total(S) - Total(O) = Σ (大跳变 - 小相邻) > 0 几乎必然成立；
//   反过来对正常图做重排只会让总量变大。⇒ 同一指标既当检测又当自校验，无需任何绝对阈值。
//   （边界占比法在「真实图恰好每块边界都是硬边」时会误报，且无法自证，故弃用。）
// 采样：每行 12 列 × 3 通道取均值，1080 行 ≈ 3.9 万次运算，相对解码可忽略。

/** 采样列数（12 列足够分辨，又对单列噪声不敏感）。 */
const SAMPLE_COLS: number = 12;

/** 相邻两行在采样列上的平均绝对差（RGB 三通道）。 */
function rowDiff(v: Uint8Array, w: number, rowBytes: number, y0: number, y1: number): number {
  const p0: number = y0 * rowBytes;
  const p1: number = y1 * rowBytes;
  let sum: number = 0;
  for (let c = 0; c < SAMPLE_COLS; c++) {
    const x: number = Math.floor((w * (c + 0.5)) / SAMPLE_COLS);
    const o: number = x * 4;
    for (let ch = 0; ch < 3; ch++) {
      const a: number = v[p0 + o + ch];
      const b: number = v[p1 + o + ch];
      sum += a > b ? a - b : b - a;
    }
  }
  return sum / (SAMPLE_COLS * 3);
}

/** 全图纵向不连续总量（越小 = 上下衔接越自然）。 */
export function totalRowDiff(v: Uint8Array, w: number, h: number, rowBytes: number): number {
  if (h < 2 || w < SAMPLE_COLS * 2) {
    return 0;
  }
  let t: number = 0;
  for (let y = 1; y < h; y++) {
    t += rowDiff(v, w, rowBytes, y - 1, y);
  }
  return t;
}

/**
 * 是否保留重排结果。
 * ★ 为什么只要「严格下降 + 极小地板」而不要大余量（实测教训）：
 *   设原图 O、混淆图 S（= O 切 num 块倒序）。S 相对 O 只做了两种改动：
 *   丢掉 num-1 对「本来相邻」的行对（接缝处），换来 num-1 对「跨整块」的行对。
 *   ⇒ Total(S) - Total(O) = Σ(跨块跳变 - 原相邻差)，对同一张图是**同一个量的相反数**：
 *     混淆图重排 ⇒ 总量下降这个量；正常图重排 ⇒ 总量上升同一个量。
 *   两个值由同一趟确定性遍历算出、无统计噪声 ⇒ 判据就是**符号**，大余量只会把
 *   「噪点较多的真实页」（增益只有几个百分点）误判成「不该动」，即漏报。
 *   （真图像样本实测：natural=6797 / scrambled(10)=7479 ⇒ 增益 9.1%，10% 闸门会漏报。）
 *   地板 0.5% 只为挡「增益≈0」的退化图（纯黑页等 —— 那种图重排与否看不出区别）。
 */
export function keepRearranged(totalBefore: number, totalAfter: number): boolean {
  if (totalBefore <= 0) {
    return false;
  }
  return totalAfter < totalBefore - totalBefore * 0.005;
}

/**
 * 就地反混淆。intent：
 *   'force'  无条件重排（uuid 白名单 / isJm=true / 用户手动强开）
 *   'detect' 由内容自证决定，不通过就不动
 *   其它     直接返回 ''（调用方已判过，这里再兜一层）
 * 返回状态串（写日志/诊断，别只回 bool —— 真机排障要知道为什么没动）：
 *   '' | 'forced' | 'detected' | 'not-scrambled'
 * 任何异常都吞掉返回 ''（调用方继续显示原图 = 最多花屏，不崩）。
 */
export async function deobfuscatePixelMap(
  pm: image.PixelMap,
  chapterIdStr: string,
  url: string,
  intent: string
): Promise<string> {
  if (intent !== 'force' && intent !== 'detect') {
    return '';
  }
  try {
    const epsId: number = parseInt(chapterIdStr, 10);
    if (!isFinite(epsId)) {
      return '';
    }
    const num: number = segmentationNum(epsId, pictureNameOf(url));
    if (num <= 1) {
      return '';
    }
    const info: image.ImageInfo = pm.getImageInfoSync();
    const w: number = info.size.width;
    const h: number = info.size.height;
    if (w <= 0 || h <= 0) {
      return '';
    }
    const rowBytes: number = w * 4;
    const totalBytes: number = pm.getPixelBytesNumber();
    // stride 假设：RGBA_8888 无行填充。不等就不动（上游 RgbImage 一定无填充，PixelMap 不保证）。
    if (totalBytes !== rowBytes * h) {
      Logger.w('反混淆跳过：stride 非 w*4（bytes=' + totalBytes + ' w=' + w + ' h=' + h + '）');
      return '';
    }
    const src: ArrayBuffer = new ArrayBuffer(totalBytes);
    await pm.readPixelsToBuffer(src);
    const sv: Uint8Array = new Uint8Array(src);

    let before: number = 0;
    if (intent === 'detect') {
      before = totalRowDiff(sv, w, h, rowBytes);
    }

    const dst: ArrayBuffer = new ArrayBuffer(totalBytes);
    const dv: Uint8Array = new Uint8Array(dst);
    if (!rearrangeBlocks(sv, dv, h, num, rowBytes)) {
      Logger.w('反混淆跳过：块越界');
      return '';
    }

    if (intent === 'detect') {
      const after: number = totalRowDiff(dv, w, h, rowBytes);
      if (!keepRearranged(before, after)) {
        return 'not-scrambled';
      }
      await pm.writeBufferToPixels(dst);
      return 'detected';
    }
    await pm.writeBufferToPixels(dst);
    return 'forced';
  } catch (err) {
    const be = err as BusinessError;
    Logger.w('反混淆失败 code=' + be.code + ' message=' + be.message);
    return '';
  }
}
