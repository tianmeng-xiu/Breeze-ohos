/**
 * 职责：网络图片两级缓存。内存 LRU(64)+磁盘 cacheDir/breeze_img/<sha256>.img，命中直接返回 PixelMap。
 * 替换原 Flutter 依赖：Flutter ImageCache / cached_network_image / photo_view 的取图逻辑。
 * 依据系统 Kit：@kit.ImageKit (decode)，@kit.CoreFileKit (磁盘)，@kit.CryptoArchitectureKit (sha256)。
 *
 * 两条取图路（s6j 加）：
 *   load(url)                     —— 封面/头像等普通图：宿主 HTTP，行为与以前完全一致。
 *   loadPage(url, uuid, chapterId) —— 漫画页：先问插件通道（带 Referer/风控头），再按意图做
 *                                     JM 分块反混淆；**反混淆结果与未反混淆结果分开缓存**
 *                                     （缓存键带意图后缀），否则一次检测会把错图永久钉住。
 *
 * 占用统计口径（真机回传 BUG2/BUG5 之后定死）：UI 侧一律走 diskUsageAsync()，
 *   同步版 diskUsage() 只留给「确定不在 UI 线程上」的场合（诊断面板、离线自检）。
 *
 * s9 真机复现（11-12 回传「统计持续失败、点重试无效」）追加的三条纪律，都在 diskUsageAsync：
 *   单飞 —— 同一时刻最多一条 walk，两页同在与连点重试都复用同一条 promise；
 *   可取消 —— clear() 期间取消进行中的统计（目录都要删了，再报旧占用数是错的）；
 *   不轻易失败 —— 只有列举本身超时/报错才 reject，stat 数不完一律交部分结果（文案带「≈」）。
 * 为什么必须这么改：磁盘缓存没有容量上限与淘汰（唯一删除入口是 clear 全清，见 clear()），
 *   文件数只增不减 ⇒「一次数不完」是常态而不是故障，旧写法用一个 20s 超时同时管列举与
 *   几万次 stat，把常态判成失败，用户就永远停在「统计失败，点此重试」。
 */
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../util/Logger';
import { HttpClient } from '../net/HttpClient';
import { BytesChannels } from './BytesChannel';
import { deobfuscatePixelMap, isGifBytes } from './JmDeobfuscate';
import { PLUGIN_SOURCE_PREFIX, PluginSourceAdapter } from '../source/PluginSourceAdapter';

/** 内存缓存条目上限。 */
const MAX_MEM: number = 64;
/** 页图内存上限（页图体积大，单独一条更短的 LRU）。 */
const MAX_PAGE_MEM: number = 24;
/** 磁盘缓存目录名（位于 cacheDir 下，系统可随应用清理）。 */
const CACHE_DIR_NAME: string = 'breeze_img';
const DISK_EXT: string = '.img';
/** 异步统计的批大小：每批最多 64 个 stat，批与批之间让出一帧。 */
const STAT_BATCH: number = 64;
/**
 * 占用统计的三段时限（替代原单一 USAGE_TIMEOUT_MS=20000：那一个值同时管「列举」和
 * 「几万次 stat」，文件一多必输，且到点只能抛错 ⇒ 用户看到的就是「持续失败」）：
 *   LIST   20s  只兜「fs.listFile 没回来」这一种真卡死；超时才抛（唯一进失败态的路径）。
 *   BUDGET  6s  stat 阶段的软预算：到点不抛错，返回已数到的部分结果（complete=false，
 *               文案渲染成「≈ 12.3 MB · 3480 个文件（未数完）」，用户拿到数量级即可。
 *   BATCH   5s  单批 stat 的等待上限：任一次 fs.stat 卡住会挂死整条链路，那也是旧 BUG2
 *               「永远统计中」的同族，所以批等待单独封顶，到点同样交部分结果。
 * 三段合起来：正常情况几百个文件远低于软预算（出准确值），极端情况最坏约 31s 结束且
 * 给的是真数字，而不是 20s 后一句「统计失败」。
 */
const USAGE_LIST_TIMEOUT_MS: number = 20000;
const USAGE_SOFT_BUDGET_MS: number = 6000;
const USAGE_BATCH_TIMEOUT_MS: number = 5000;
/** stat 失败率超过这个比例就不再当作「文件刚好被淘汰」，结果标未数完并带上首个错因。 */
const STAT_FAIL_RATIO: number = 0.1;

/** 让出一帧：setTimeout(0) 排到下一轮宏任务，让 UI 有机会绘制与响应输入。 */
function yieldFrame(): Promise<boolean> {
  return new Promise<boolean>((resolve: (v: boolean) => void): void => {
    setTimeout((): void => {
      resolve(true);
    }, 0);
  });
}

/**
 * 超时包裹（写法同 data/source/PluginSettings.ets:143，但补了 clearTimeout）。
 * 原写法用 Promise.race 且计时器不 clear、超时后原 promise 继续跑：单看统计这一路，
 * 「超时」并没有真的结束任何工作，只是让调用方先走开 —— 于是每次点重试都再挂上一条
 * 完整 walk，旧的还在原地跑，磁盘 I/O 越抢越慢，表现就是「点重试反而更没反应」。
 * 现在两条 settled 路径都 clearTimeout；被超时的 promise 交由调用方（walkUsage）
 * 用代数与 stopped 标志自行收尾，不再留下无人认领的在途链路。
 */
function withTimeout<T>(p: Promise<T>, ms: number, tag: string): Promise<T> {
  return new Promise<T>((resolve: (v: T) => void, reject: (err: Error) => void): void => {
    const timer: number = setTimeout((): void => {
      reject(new Error(tag + ' 超时 ' + ms + 'ms'));
    }, ms);
    p.then((v: T): void => {
      clearTimeout(timer);
      resolve(v);
    }, (err: Object): void => {
      clearTimeout(timer);
      reject(err as Error);
    });
  });
}

/**
 * BusinessError 与普通 Error 通用的一行错因：带 code 就写 code，没有就只写 message。
 * （不写成 BusinessError 专用：withTimeout 抛的是普通 Error，直接取 code 会拼出 undefined。）
 */
function errBrief(err: Object): string {
  const be = err as BusinessError;
  let msg: string = '';
  if (typeof be.message === 'string') {
    msg = be.message;
  }
  if (msg.length === 0) {
    msg = String(err);
  }
  if (typeof be.code === 'number') {
    return 'code=' + be.code + ' ' + msg;
  }
  return msg;
}

/** 取 URL 的 host（解析不出来就给短前缀，只为诊断可读，绝不抛）。 */
function hostOf(url: string): string {
  const i: number = url.indexOf('//');
  const rest: string = i >= 0 ? url.slice(i + 2) : url;
  const j: number = rest.indexOf('/');
  const h: string = j >= 0 ? rest.slice(0, j) : rest;
  return h.length > 60 ? h.slice(0, 60) : h;
}

/** 错误码（取不到返回 0）：UI 只放数字码，完整错因留在日志里（系统 message 可能带路径）。 */
function errCode(err: Object): number {
  const be = err as BusinessError;
  if (typeof be.code === 'number') {
    return be.code;
  }
  return 0;
}

/** 磁盘缓存占用统计结果（设置页「存储」分组用）。 */
export class DiskUsage {
  /** 文件数 */
  files: number = 0;
  /** 总字节数 */
  bytes: number = 0;
  /**
   * 本次统计是否有效：false = 缓存目录还没就绪（ImageCache.init 未完成或失败），
   * 此时 bytes/files 全 0 是「没数」而不是「0 字节」，UI 必须显示可重试的提示而不是 0 B。
   */
  ready: boolean = false;
  /**
   * 是否数完：false = 部分结果（软预算用尽 / 某批 stat 无响应 / 失败率过高）。
   * 部分结果的 files 是准的（来自目录列举），bytes 是偏小的下界，文案加「≈」并标未数完。
   */
  complete: boolean = true;
  /** 字节数是否可信：false = 一次 stat 都没成功，只剩文件数（保底口径，见 walkUsage） */
  sized: boolean = true;
  /** 未数完或失败的真实原因（含 code 与 message），同时写进 Logger 供真机回传 */
  note: string = '';
}

/**
 * walkUsage 的内部计数：只活在一次统计里，不进 DiskUsage（对外只给结论不给中间量）。
 * 必须是具名类而不是对象字面量（ArkTS 严格模式 10605038）。
 */
class WalkState {
  /** stat 成功个数 */
  sized: number = 0;
  /** stat 逐个失败的文件数（正常淘汰也会落在这里，与 missing 同量纲） */
  fails: number = 0;
  /** 整批超时的批数（一卡就是 STAT_BATCH 个文件，量纲是批不是文件，只进日志） */
  batchFails: number = 0;
  /** 首个失败的一行错因 */
  firstCode: string = '';
  /** 结果已交出（超时/取消提前返回）：迟到的 stat 不再回写，避免改写已展示的数字 */
  stopped: boolean = false;
}

/**
 * 缓存占用的展示口径：设置页与「更多」页共用一份文案，避免两处漂移
 * （要求1 去重同时把「同一件事两处写法不同」也一并消掉）。
 */
export class CacheUsageText {
  /** 阶段：统计进行中 */
  static readonly P_MEASURING: string = 'measuring';
  /** 阶段：统计失败或超时 */
  static readonly P_FAILED: string = 'failed';
  /** 阶段：缓存目录未就绪 */
  static readonly P_NOT_READY: string = 'notReady';
  /** 阶段：已有有效结果 */
  static readonly P_DONE: string = 'done';
  /** 统计进行中 */
  static readonly MEASURING: string = '统计中…';
  /** 统计失败/超时（点击可重试） */
  static readonly FAILED: string = '统计失败，点此重试';
  /** 缓存目录未就绪（点击可重试） */
  static readonly NOT_READY: string = '缓存未就绪，点此重试';
  /**
   * 最近一次统计的「未数完」标记与字节数可信标记，以及失败错误码。
   *
   * 为什么放这里而不是加 of() 的形参：这两页的文案入口都是 of(phase,bytes,files)，
   * 「更多」页本轮不在改动范围内，改签名会波及它（约束 4）。部分结果与错误码是**同一次
   * 统计**的属性、两页显示的又必是同一份缓存，所以放在文案类里由 walkUsage 单点写入，
   * 仍是唯一真源（写入点只有 walkUsage 与 diskUsage 两处，见那边的 note 赋值）。
   * 值随每次统计整体重置，不会把上一轮的部分结果带到新结果上。
   */
  static lastPartial: boolean = false;
  static lastSized: boolean = true;
  static lastFailCode: number = 0;
  /** 已接受结果的统计代数（被取消的旧 walk 晚到也不许改写本轮口径） */
  private static qualityGen: number = 0;

  /**
   * 统计侧写入口径（walkUsage 每个出口各调一次）。gen = 本次统计的代数，晚到的旧一轮
   * （被 clear 或新请求取消、但仍卡在最后一批 stat 上）gen 较小，直接丢弃 —— 否则
   * 「新结果已完整、旧取消结果晚到」会把完整结果标成未数完。
   */
  static recordQuality(gen: number, complete: boolean, sized: boolean, code: number): void {
    if (gen < CacheUsageText.qualityGen) {
      return;
    }
    CacheUsageText.qualityGen = gen;
    CacheUsageText.lastPartial = !complete;
    CacheUsageText.lastSized = sized;
    CacheUsageText.lastFailCode = code;
  }

  /** 阶段 → 整行文案：两页共用，杜绝「统计中/计算中」这类同义漂移 */
  static of(phase: string, bytes: number, files: number): string {
    if (phase === CacheUsageText.P_FAILED) {
      // 带上错误码：旧文案只有四个字，真机回传一张截图我们无法定位（本轮追加要求）
      if (CacheUsageText.lastFailCode > 0) {
        return '统计失败(' + CacheUsageText.lastFailCode + ')，点此重试';
      }
      return CacheUsageText.FAILED;
    }
    if (phase === CacheUsageText.P_NOT_READY) {
      return CacheUsageText.NOT_READY;
    }
    if (phase === CacheUsageText.P_DONE) {
      return CacheUsageText.done(bytes, files);
    }
    return CacheUsageText.MEASURING;
  }

  /** 字节数 → 人类可读（B / KB / MB，保留一位小数） */
  static bytes(n: number): string {
    if (n < 1024) {
      return n + ' B';
    }
    if (n < 1024 * 1024) {
      return (n / 1024).toFixed(1) + ' KB';
    }
    return (n / 1024 / 1024).toFixed(1) + ' MB';
  }

  /**
   * 设置页整行摘要。三档口径（s9 复现轮加）：
   *   数完        '12.3 MB · 208 个文件'
   *   未数完      '≈ 12.3 MB · 3480 个文件（未数完）' —— 字节数是下界，文件数是准的（来自列举）
   *   只数到文件  '3480 个文件（读不到大小）' —— 一次 stat 都没成功，宁可不给 MB 也不给假的 0 B
   * 「≈」比另起一行说明更省位置，两页都是单行 maxLines(1)。
   */
  static done(bytes: number, files: number): string {
    if (!CacheUsageText.lastSized && files > 0) {
      return files + ' 个文件（读不到大小）';
    }
    if (CacheUsageText.lastPartial) {
      return '≈ ' + CacheUsageText.bytes(bytes) + ' · ' + files + ' 个文件（未数完）';
    }
    return CacheUsageText.bytes(bytes) + ' · ' + files + ' 个文件';
  }
}

export class ImageCache {
  private static instance: ImageCache | null = null;
  private mem: Map<string, image.PixelMap> = new Map();
  /** LRU 顺序，最旧在前（ArkTS 对 Map 迭代器支持有限，这里用数组显式维护顺序）。 */
  private memOrder: string[] = [];
  /** 页图单独一条 LRU（体积大、生命周期短，与封面/头像分桶才不会互相挤掉）。 */
  private pageMem: Map<string, image.PixelMap> = new Map();
  private pageOrder: string[] = [];
  /**
   * s21 黑区修法：消费侧正在挂载展示的位图计数（键 = 位图实例本身）。
   * 缓存淘汰与 clear() 遇到计数非零的位图一律不 release —— 屏上位图被 release 后
   * Image 组件画出来是整幅纯黑，不抛异常、不留日志，且 probeBlack 早在解码阶段就跑完
   * （字节侧确实是一张好图），所以旧现场才表现为「全宽纯黑、无页码角标、blk 查不出黑图」。
   */
  private pinned: Map<image.PixelMap, number> = new Map<image.PixelMap, number>();
  /** 已被逐出缓存但当时仍被持有的位图：等持有归零再真 release。 */
  private pendingRelease: Map<image.PixelMap, boolean> = new Map<image.PixelMap, boolean>();
  private cacheRoot: string = '';
  private ready: boolean = false;
  private initPromise: Promise<void> | null = null;
  /**
   * 在途的占用统计（单飞闸门）：为 null 表示没人在数。
   * 必须是实例字段而不是页面字段 —— 「更多」页与「通用设置」可以同时活着（TabContent
   * 不销毁），两边的 measureCache 各自只看自己的 cacheBusy，谁也拦不住谁 ⇒ 旧写法在
   * 两页来回切时会并发跑两条完整 walk。放在这里才是唯一真源。
   */
  private usagePromise: Promise<DiskUsage> | null = null;
  /** 统计代数：新一轮开始或 clear() 取消都抬它，walkUsage 每批之间对照自查退出。 */
  private usageGen: number = 0;

  static getInstance(): ImageCache {
    if (ImageCache.instance === null) {
      ImageCache.instance = new ImageCache();
    }
    return ImageCache.instance;
  }

  /** 幂等初始化：创建磁盘目录。 */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.ready) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.doInit(context);
    try {
      await this.initPromise;
    } catch (err) {
      this.initPromise = null;
      throw err as Error;
    }
  }

  private async doInit(context: common.UIAbilityContext): Promise<void> {
    try {
      this.cacheRoot = context.cacheDir + '/' + CACHE_DIR_NAME;
      // 目录不在就补。recursion=true（@since 11）连父级 cacheDir 一起补：单级 mkdir 在父目录
      // 也被系统回收时会再抛 13900002。
      //
      // 这一支在 s10a 之前是死代码（pathExists 恒 true，判据见下方 pathExists 的方法注释），修好后它才真正
      // 会跑，所以把它做成非致命：这里抛出会让 DataBootstrap 排在 init 之后的四步
      // （PluginImageOps.install、SourceManager.initBuiltIn、PluginSourceRegistry.syncFromStore）
      // 整个不跑，而 EntryAbility 不 await、只有一行 hilog ⇒ 表现为「图源全没了」，
      // 比「缓存目录晚一步建起来」重得多。运行期每条磁盘链路进门都过 ensureCacheRoot()，
      // 它会再补一次 ⇒ 此处失败只是「稍后再补」，不是「永远没有目录」。
      if (!this.pathExists(this.cacheRoot)) {
        try {
          fs.mkdirSync(this.cacheRoot, true);
          // 固定前缀、只在启动期打一次：这一行是「accessSync 对缺失目录返回 false（本机语义）」
          // 的现场证据。反过来，若真机日志里始终看不到这一行、却出现 ensureCacheRoot 的
          // 「已重建」，说明启动时判定为「已存在」、运行期才被系统回收 —— 两种走向靠它分辨。
          Logger.i('启动时图片缓存目录不存在，已创建：' + this.cacheRoot);
        } catch (err) {
          Logger.w('启动时创建图片缓存目录失败，交给运行期闸门重试：' + errBrief(err as Object));
        }
      }
      this.ready = true;
      Logger.i('图片缓存目录就绪：' + this.cacheRoot);
    } catch (err) {
      const be = err as BusinessError;
      Logger.e('图片缓存初始化失败 code=' + be.code + ' message=' + be.message);
      throw new Error('图片缓存初始化失败(' + be.code + ')：' + be.message);
    }
  }

  isReady(): boolean {
    return this.ready;
  }

  /**
   * 取图：内存 -> 磁盘 -> 网络。返回的 PixelMap 由缓存持有，
   * 仅供参考展示，调用方不要 release（否则其它页面复用同一对象会白屏）。
   */
  async load(url: string): Promise<image.PixelMap> {
    // 封面/头像/缩略图这条路没有页表，也就没有 extern：空串 = 「本页没有页面上下文」，
    // 与插件图源里 ext 为空是同一含义；缓存键按「非空才拼」的口径保持与改造前逐字节相同。
    return this.loadPage(url, '', '', '');
  }

  /**
   * 取漫画页图（s6j）：sourceId 是插件图源且通道已接线 ⇒ 用插件 fetchImageBytes 取字节
   * （带 Referer/风控头），再按意图做 JM 分块反混淆。
   * 缓存口径（重要）：**磁盘存的永远是原始字节**，反混淆每次解码后重做（检测开销 ~1e5 次减法，
   * 相对解码可忽略），因此手动开关 auto/on/off 改完立即生效，不会被旧缓存钉住；
   * 内存/磁盘键都带意图后缀 ⇒ 同 URL 的「原图 / 已重排」不会互相污染。
   *
   * ext（s17 第 5 条）= 该页在插件页表里的 extern JSON 串（PageImage.ext），没有传空串。两个用途：
   *   ① 原样透传给 fetchImageBytes —— e-hentai 这类插件整章每页 url 都是同一个哨兵地址
   *     （https://<host>/_breeze/read-image），真图页地址只在 extern.href 里；丢了它插件必抛
   *     「missing deferred image page href」且 0 次网络请求 = 真机整章「图片加载失败」。
   *   ② 参与缓存键（见 pageKey）：这类图源整章 url 逐字节相同，不按页分开 = 第 2 页命中第 1 页的图。
   */
  async loadPage(url: string, sourceId: string, chapterId: string, ext: string): Promise<image.PixelMap> {
    if (url === null || url === undefined || url.length === 0) {
      throw new Error('图片地址为空');
    }
    // s15 第 1 条可诊断化（入口总闸）：pageCalls = 真正进入取页流程的次数（URL 非空才算）。
    // 出口侧五档互斥计数与之对账，恒等式写在 imageHint 上方。
    ImageCache.pageCalls++;
    if (!this.ready) {
      ImageCache.pageFailed++;
      throw new Error('图片缓存尚未初始化，请先调用 ImageCache.init(context)');
    }

    const ch = BytesChannels.get();
    const isPlugin: boolean = sourceId.length > 0 && sourceId.startsWith(PLUGIN_SOURCE_PREFIX);
    if (!isPlugin) {
      // s15 第 1 条：只记**形态**不记原值。空串是 load()（封面、头像、详情页缩略图那条路）独有的
      // 特征，是「诊断里那一串宿主取图其实一次翻页都不是」这条解释的唯一判据；长度截到 24 ——
      // 非插件支路的 sourceId 可能被传成完整 URL，而 URL 路径里带作品号 = 用户浏览痕迹。
      ImageCache.lastNonPluginSource = sourceId.length === 0 ? '<empty>'
        : (sourceId.length > 24 ? sourceId.slice(0, 24) : sourceId);
    } else if (ch === null) {
      // 是插件图源但那一刻通道还没接线：npSrc 与 pil 两个字段都不会赋值，现场会呈现
      // 「pc 在涨而 npSrc/pil 都不动」这种三无形态，单独计一枚才把它跟别的形态分开。
      ImageCache.pagePluginNoChannel++;
    }
    let intent: string = '';
    if (isPlugin && ch !== null) {
      try {
        intent = await ch.deobfIntent(sourceId, chapterId, url);
      } catch (err) {
        intent = '';
      }
      // 意图串可能带插件自定义参数形态，刻意不上屏，只记长度：0 = 插件明说这张不用反混淆；
      // 「长度大于 0 而 deobf 两档都不涨」才是真问题（s14 回传 deobf=0/0 正卡在这两者之间）。
      ImageCache.lastPageIntentLen = intent.length;
    }
    // 键式统一走 pageKey（与 loadSize 共用同一定义）：两把键必须逐字节相同，否则 sz= 那三档
    // 预探命中与真取图命中永远对不上，第 2 条的判据就废了。
    const key: string = this.pageKey(isPlugin, url, intent, ext);

    const hit: image.PixelMap | null = this.memGet(key, isPlugin);
    if (hit !== null) {
      // 内存命中既不是插件、宿主，也不是磁盘：单列一档才能把出口恒等式闭合。
      ImageCache.pageFromMem++;
      return hit;
    }

    const name: string = await this.hashName(key);
    const path: string = this.cacheRoot + '/' + name + DISK_EXT;

    let buf: ArrayBuffer | null = this.readFile(path);
    // fromNet 只区分「磁盘 vs 网络」，插件取回的字节同样算非网络，所以「字节最终来自哪条通道」
    // 必须另钉一枚旗子，否则 pf 与 df 永远分不开。
    let fromPlugin: boolean = false;
    if (buf !== null) {
      // 磁盘命中既不进插件档也不进宿主档 ⇒ 诊断行会显示 plugin=0/0 host=0/0，跟「根本没翻过页」
      // 一模一样（真机第一次回传就是这样，白跑一趟）。这里单独计一次，两者才分得开。
      ImageCache.pageCacheHits++;
    }
    if (buf === null && isPlugin && ch !== null) {
      // 插件通道优先（这是「部分源画面不正常」的第一半根因：宿主 HTTP 没有插件的 Referer）
      ImageCache.pluginImageTries++;
      ImageCache.lastImageSource = sourceId;
      ImageCache.lastImageHost = hostOf(url);
      try {
        const got: ArrayBuffer | null = await ch.fetch(sourceId, url, ext);
        if (got !== null) {
          buf = got;
          fromPlugin = true;
          ImageCache.pluginImageHits++;
        } else {
        // 通道在但适配器没装载：不是异常，却等价于「这一张只能走宿主」，必须留痕
        // s15 补计数：旧版这里只写 lastPluginImageErr，而宿主兜底一旦成功就再没痕迹；
        // cn 与 hf 同步上涨即坐实「适配器没装载、全靠宿主硬取」这条路径。
          ImageCache.channelNull++;
          ImageCache.lastPluginImageErr = 'channel returned null';
        }
      } catch (err) {
        ImageCache.pluginImageFails++;
        ImageCache.lastPluginImageErr = errBrief(err as Object);
        Logger.w('插件取图失败，回落宿主 HTTP：' + ((err as Error).message ?? String(err)));
      }
    }
    let fromNet: boolean = buf === null;
    if (buf === null) {
      ImageCache.hostImageTries++;
      ImageCache.lastImageHost = hostOf(url);
      try {
        buf = await HttpClient.getInstance().getBytes(url);
      } catch (err) {
        ImageCache.hostImageFails++;
        // 这一条 catch 必抛 ⇒ 直接记一次失败出口（对账恒等式见字段块注释）
        ImageCache.pageFailed++;
        ImageCache.lastHostImageErr = errBrief(err as Object);
        throw this.wrap(err, '图片下载失败');
      }
    }

    let pm: image.PixelMap | null = null;
    try {
      pm = await this.decode(buf, intent.length > 0);
    } catch (err) {
      ImageCache.pageFailed++;
      // 磁盘文件可能已损坏：删掉，下次重新下载
      this.deleteFile(path);
      throw this.wrap(err, fromNet ? '图片解码失败' : '本地缓存图片已损坏，请重试');
    }
    if (pm === null) {
      ImageCache.pageFailed++;
      throw new Error('图片解码失败：结果为空');
    }

    if (intent.length > 0 && !isGifBytes(buf)) {
      const status: string = await deobfuscatePixelMap(pm, chapterId, url, intent);
      if (status === 'detected' || status === 'forced') {
        ImageCache.deobfHits++;
        ImageCache.lastDeobf = status + ' ' + chapterId;
      } else if (status.length > 0) {
        ImageCache.deobfSkips++;
        ImageCache.lastDeobf = status + ' ' + chapterId;
      }
    }

    // s14 第 5 条可诊断化：真机回传「上下滑动时两图之间一大片纯黑」有两种成因，屏上看不出区别 ——
    //   ① 布局间隙（行高比图高，多出来的容器露出黑底）② 取回来/解码出来本来就是一张黑图。
    // 量过那张截图：黑区自身宽高比 = 1252/1858 = 0.674，是正常竖页比例，说明行高按真实图比算过
    // ⇒ 更像 ②。但没有现场计数不能定案，所以这里对**已上屏的 PixelMap** 抽中心小块自己量一遍。
    // 刻意用 readPixelsToArea（@since 12）只取中心 16x16：整幅 readPixelsToBuffer 每张页图要多拷几 MB，
    // 为一个诊断指标不值当。
    const blk: number = await ImageCache.probeBlack(pm);
    ImageCache.probed++;
    // s15 补：-1（取样失败）此前也混进 probed 分母 ⇒ blk=0/14 分不清「14 张全有内容」
    // 和「14 张全部取样失败」这两种相反结论。单列 u 档（imageHint 的 blk=a/b/u）。
    if (blk === -1) {
      ImageCache.probeUnknown++;
    }
    let blackPage: boolean = false;
    if (blk === 1) {
      ImageCache.blackPages++;
      blackPage = true;
      const bi: image.ImageInfo = pm.getImageInfoSync();
      ImageCache.lastBlack = bi.size.width + 'x' + bi.size.height;
      ImageCache.lastBlackHost = hostOf(url);
      ImageCache.lastBlackBytes = buf.byteLength;
      Logger.w('页图像素近乎全黑：' + bi.size.width + 'x' + bi.size.height
        + ' bytes=' + buf.byteLength + ' host=' + hostOf(url));
    }
    // 纯黑页一律不落盘（连原始字节一起跳）：磁盘存的虽然是人家的原字节，但一张「解码成功、
    // 尺寸正常、像素全黑」的页最像**站方防盗链回的黑图占位**。写盘 = 把这张占位永久钉住，
    // 之后每次进来都命中缓存、插件通道再也不会被叫起来第二遍 ⇒ 用户看到的是「永远黑」。
    //
    // 现场依据（1252x1900 那张截图逐行 luma 量算）：黑区上下两条邻居页图**渲染正常**，
    // 只有中间这一张是纯黑 ⇒ 同一插件、同一解码档位下邻居能出画 ⇒ 不是渲染档位问题，
    // 是这一张的位图本身就是黑的（站方按页返回的占位）。所以修法在「别把它钉住」这一侧。
    if (fromNet && !blackPage) {
      this.writeFile(path, buf);
    }
    // s12/s13 的旧包把黑页写进过磁盘 ⇒ 升到本版后那些文件仍会命中并画黑。这里反向自愈一次：
    // 黑页 + 本次是磁盘命中 ⇒ 删掉这个缓存文件（本次仍显示黑，下一次进来就重新走取图）。
    // 刻意不当场重取：重取要在同一次调用里把「取图 → 解码 → 再判黑」整条链跑第二遍，
    // 换来的是「第一次看到黑也白等一轮」，不值当；删文件已足够让下一次恢复。
    if (blackPage && !fromNet) {
      this.deleteFile(path);
      Logger.w('黑页缓存已删除，下次重取：' + hostOf(url));
    }
    // s15 第 1 条：出口侧唯一权威 —— 这张最终上屏的图，字节到底来自哪条通道。
    // 只在成功返回处累加，失败那次只涨 pageCalls/pageFailed，不污染三档分布。
    if (fromPlugin) {
      ImageCache.pageFromPlugin++;
    } else if (fromNet) {
      ImageCache.pageFromHost++;
    } else {
      ImageCache.pageFromDisk++;
    }
    this.memPut(key, pm, isPlugin);
    return pm;
  }

  /** 诊断面板用：反混淆生效次数 / 跳过次数 / 最后一次状态。 */
  static deobfHits: number = 0;
  static deobfSkips: number = 0;
  static lastDeobf: string = '';

  // ---- 取图链取证（s13 第 5 条：真机回传「某图源任何情况下都显示拿不到图」）----
  /**
   * 为什么单独记这四组数：loadPage 的插件通道 catch 之后会**静默回落宿主 HTTP**（只写 Logger.w，
   * 页面上看不见），而宿主 HttpClient 不带插件的鉴权/风控头 ⇒ 对需要风控头的源必然拿回错误页，
   * 最终上屏只剩一句「图片加载失败」。没有这几枚计数，一张截图区分不了下面三种情况：
   *   A 插件取图整条没跑（tries=0 ⇒ 通道未接线 / 不是插件图源 / 命中磁盘缓存）
   *   B 插件取图抛错、宿主兜底也失败（fails>0 且 host 也失败 ⇒ 真取不到）
   *   C 插件取图抛错、宿主兜底回了字节（fails>0 且 host 成功 ⇒ 十有八九是错误页，
   *     此时用户看到的是「解码失败」或画面花屏，不是「下载失败」）
   * 三种情况的修法完全不同，所以宁可多写六枚静态计数，也不在没证据时猜修。
   */
  static pluginImageTries: number = 0;
  static pluginImageHits: number = 0;
  static pluginImageFails: number = 0;
  static hostImageTries: number = 0;
  static hostImageFails: number = 0;
  /** 最后一次「插件取图」错因（含通道返回 null）。刻意截断由诊断行统一做。 */
  static lastPluginImageErr: string = '';
  /** 最后一次宿主 HTTP 兜底错因（判「回落有没有救回来」）。 */
  static lastHostImageErr: string = '';
  /** 最后一次走插件通道的图源 id（形如 plugin:uuid，多图并存时用来对上号）。 */
  static lastImageSource: string = '';
  /**
   * 最后一次取图的**主机名**（刻意只到 host：像 s3 / img / storage-b 这类 CDN 域名是判
   * 「可达性问题」还是「风控问题」的关键；完整 URL 的路径里带作品号 = 用户浏览痕迹，不进诊断）。
   */
  static lastImageHost: string = '';

  /** 纯黑页探针：检出的纯黑页张数 / 总探测张数 / 最后一张的像素尺寸（s14 第 5 条）。 */
  static blackPages: number = 0;
  static probed: number = 0;
  /** 纯黑页最后一次：主机名与原始字节数（字节数是「黑图占位」与「真黑页」的主要分辨依据）。 */
  static lastBlackHost: string = '';
  static lastBlackBytes: number = 0;
  /** 页图**磁盘缓存**命中次数（与 plugin/host 两个计数互不重叠，三者相加 = 取页总次数）。 */
  static pageCacheHits: number = 0;
  static lastBlack: string = '';

  // ---- s15 第 1 条：取图链「字节最终从哪条通道来」的可诊断化（纯取证，不改任何行为）----
  /**
   * 为什么要有这一组（s14 真机回传 imageChain: plugin=0/0 host=12/12 src=- deobf=0/0）：
   * 旧的 plugin=/host= 是两个**互相重叠、且会被静默回落污染**的二维计数 —— tries 只在
   * 「未命中磁盘 && isPlugin && 通道在」那一条分支里自增，宿主支路又无条件自增，
   * 所以 plugin=0/0 这一项单独看什么也证明不了：可能是根本没进插件支路，也可能是
   * 十二次全部命中磁盘之外还有别的调用方（封面/头像那条 load() 传的是空 sourceId）。
   * 这组计数换成**互斥出口**口径：一次 loadPage 只可能落在下面六个出口里的一个，
   * 于是有一条例程可自查的恒等式（不必再靠现场猜）：
   *
   *   pageFromPlugin + pageFromHost + pageFromDisk + pageFromMem + pageFailed == pageCalls
   *
   * （派工书原话是「pf+hf+df == pageCalls」，那条只在这一次既没命中内存、又没失败时成立；
   *   内存命中与失败出口各占一档才能把它写成无条件恒等式。对不上账 = 有第七条出口，
   *   说明我对 loadPage 的控制流理解有误，这本身就是最有价值的信号。）
   *
   * 读法上的一条硬口径（lead 11-13 17:31 现场更新 + 本机按代码修正其表述）：
   *   用户补述「点进 pic 源漫画直接显示无法加载 + 重试按钮、连下一页都切不了」⇒ 真实形态是
   *   整章没起来（ReaderView 章级错误分支、urls 空数组），**阅读器一次都没取页**。所以上一轮
   *   那个 plugin=0/0 的自然解释是「阅读器根本没翻页」，而不是「sourceId 不带 plugin: 前缀」。
   *   但这条现场不能读成「pc=0 而 host>0」：load()（封面/头像/详情页缩略图）本身就是 loadPage
   *   的一层包装（见上方 load），而 hostImageTries 的自增点在 pageCalls 之后 ⇒ 恒有
   *   pc >= host 那档的张数，pc=0 只可能出现在「连封面都没取过」，那时 host 必然也是 0。
   *   「阅读器没翻页」在诊断行里的**正确读法**是：pc>0、pf=0、hf 或 df == pc、npSrc=<empty>
   *   —— 即这些取图全部来自非插件的封面类调用，与阅读器翻页无关；这是合法组合、不是异常形态。
   *   这组计数本轮的判据因此收窄成一条：用 npSrc 分清 host 那十几张的来源。
   *
   * pageCacheHits 保留不动（设置页与旧诊断行都读它）：磁盘命中除了 pageFromDisk 之外
   * 仍照旧 ++，两个字段是同一件事的新旧两种写法，旧字段不得失效。
   */
  /** 进入 loadPage 且 url 非空的总次数（对账用的分母） */
  static pageCalls: number = 0;
  /**
   * 出口 1/2/3：成功返回，字节来自插件通道 / 宿主 HTTP / 磁盘缓存。
   *
   * 三处既有行为决定这三档怎么读（本轮按派工书 D 段「只做诊断化、不改行为」原样保留，只写口径；
   * 下面每一条都是离线桩在真代码上跑出来的，不是读代码猜的）：
   *   ① 落盘条件是 if (fromNet && !blackPage)，而 fromNet 的定义是「进宿主支路前 buf 仍为空」
   *      ⇒ **插件通道亲自取回的那一张从不写盘**，同一张每次翻到都要重新问插件（内存只有 24 张）。
   *   ② 但插件图源仍可能磁盘命中：同一次调用里插件失败、回落宿主成功时，宿主字节是按**插件键**
   *      （url + |p| + 意图后缀）落盘的，此后同键的插件调用就落在 df 这一档。
   *   ③ 所以 df>0 不可反推「这张不是插件页」；反过来 pf>0 那张必定没落盘。
   *      hit（旧字段）同理：既可能是 load() 的裸 url 键，也可能是 ② 那种插件键，本轮这几个字段
   *      分不开二者 —— 想分开只能看 npSrc（本轮出现过非插件调用）与 cn/pnc（出现过宿主回落）的组合。
   */
  static pageFromPlugin: number = 0;
  static pageFromHost: number = 0;
  static pageFromDisk: number = 0;
  /** 出口 4：内存命中，压根没走到磁盘与网络 */
  static pageFromMem: number = 0;
  /** 出口 5：这次没拿到图（缓存未就绪、下载失败、解码失败、解码返回空） */
  static pageFailed: number = 0;
  /**
   * 是插件图源、但 BytesChannels 还没接线（install 晚于第一次取页）的次数。
   * 这一档刻意不进上面六个出口之外的第七档，只是把「为什么会走宿主」的原因写清楚：
   * 它表现为 npSrc 与 pil 都不赋值、pf=0 而 hf 在涨 —— 三个字段联立才能和
   * 「适配器没装载（cn）」与「sourceId 根本不是插件源（npSrc 非空）」区分开。
   */
  static pagePluginNoChannel: number = 0;
  /** 插件通道在、但 ch.fetch 返回 null 的次数（s15 补：旧版只写错误串、没有计数） */
  static channelNull: number = 0;
  /**
   * 最后一次**非插件**取页的 sourceId 形态：空串记 <empty>，超过 24 字符截断。
   * 只在 !isPlugin 那一支赋值 ⇒ 插件取页不会覆盖它，一次会话里混过多少调用都留得下最后一次。
   * 判据强度（桩实测，别夸大）：它证明的是「**这一轮里出现过**非插件取页」，
   * 因为只记最后一次，不能把某一张具体的 host/disk 取图归因到它。
   * npSrc=<empty> ⇒ 出现过 load()（封面、头像、详情页缩略图那条路，sourceId 传空串）。
   */
  static lastNonPluginSource: string = '';
  /**
   * 最后一次 ch.deobfIntent 返回串的**长度**（刻意不记串本身：意图串里可能带
   * 插件自定义参数，属用户数据）。0 = 插件说这张不用反混淆。
   */
  static lastPageIntentLen: number = 0;
  /**
   * probeBlack 返回 -1（取样失败）的次数。
   * 必须有：probed 对 -1 也累加，所以 blk=0/14 同时兼容「14 张全都有内容」与
   * 「14 张全部取样失败」两种相反结论。**u == b 时 blk 这条判据整体作废，
   * 不得据 blk=0 排除黑图。**
   */
  static probeUnknown: number = 0;
  /** 最后一次取样失败的原因（small WxH 或 readPixelsToArea 抛出的 code+message） */
  static lastProbeErr: string = '';
  /**
   * s21 黑区修法三个计数器（拼在诊断 16 号行末尾 pin= 三档）：
   *   pinLive    = 当前仍被消费侧（阅读器行的 @State pm）挂着的位图张数
   *   evictHeld  = 淘汰或清理时因为「还在屏上」而跳过 release 的次数
   *   pmReleased = 真调用 release 的次数
   * 判读：evictHeld 长期大于 0 = 确实存在「淘汰打到屏上位图」这种时序（黑区的直接证据）；
   * 修法生效后 pmReleased 只在持有归零时增长；pinLive 单调上升不回落 = 消费侧漏 unpin。
   */
  /**
   * s21 黑区修法第二组计数器（诊断 16 号行 at= 三档 = 有/黑/取不到样本）：
   * 与 blk= 的区别 = 探针时机。blk= 只在**首次解码**那次跑（memGet 命中直接返回、重挂也不再探），
   * 所以「位图本身是黑的」在「命中缓存后重新挂上屏」这条路上永远看不见。at= 挂在消费侧挂载那一刻，
   * 每张位图每次挂载只补一次（消费侧按实例去重），用来把两种黑分开：
   *   at 的第二档（黑）大于 0 = 图源交来的位图本身就是纯黑（与布局/尺寸无关，走图源侧）；
   *   at 的第三档（取不到样本）大于 0 且 dead= 也在涨 = 挂载后位图被 release（走持有链那条）。
   */
  static showOk: number = 0;
  static showBlack: number = 0;
  static showUnknown: number = 0;
  static pinLive: number = 0;
  static evictHeld: number = 0;
  static pmReleased: number = 0;
  /** 中心区取样边长（像素）：16x16 足够判「整幅是不是黑的」。 */
  private static readonly BLACK_SAMPLE: number = 16;

  /**
   * 抽中心 16x16 判「这张图是不是近乎纯黑」：返回 1 = 纯黑、0 = 有内容、-1 = 取不到样本
   * （图太小 / 区域 API 不可用 / 已释放），-1 不计入纯黑页计数。
   * 阈值 8 而不是 0：真黑页解码成 RGBA 后常见 0~2 的底噪，而漫画页中心区必然有笔画或上色。
   */
  private static async probeBlack(pm: image.PixelMap): Promise<number> {
    try {
      const info: image.ImageInfo = pm.getImageInfoSync();
      const side: number = ImageCache.BLACK_SAMPLE;
      if (info.size.width < side || info.size.height < side) {
        ImageCache.lastProbeErr = 'small ' + info.size.width + 'x' + info.size.height;
        return -1;
      }
      const stride: number = side * 4;
      const area: image.PositionArea = {
        pixels: new ArrayBuffer(stride * side),
        offset: 0,
        stride: stride,
        region: {
          size: { width: side, height: side },
          x: Math.floor(info.size.width / 2) - Math.floor(side / 2),
          y: Math.floor(info.size.height / 2) - Math.floor(side / 2)
        }
      };
      await pm.readPixelsToArea(area);
      const v: Uint8Array = new Uint8Array(area.pixels);
      let m: number = 0;
      for (let i = 0; i < v.length; i += 4) {
        // 区域 API 固定按 BGRA_8888 交付（SDK :2794「Only pixel data in BGRA_8888 format is supported」），
        // 与 PixelMap 自身的 RGBA 顺序不同；判黑只看三通道最大值，通道顺序不影响结论。
        for (let c = 0; c < 3; c++) {
          if (v[i + c] > m) {
            m = v[i + c];
          }
        }
      }
      return m <= 8 ? 1 : 0;
    } catch (err) {
      // s15 补：旧版把错因整个吞掉，blk 的 -1 到底是「图太小」还是 readPixelsToArea 在
      // 解码产出的 PixelMap 上不可用，现场完全分不开（s14 blk=0/14 有两种相反解释）。
      // 沿用 errBrief 口径，只截一次。
      ImageCache.lastProbeErr = errBrief(err as Object);
      return -1;
    }
  }

  /**
   * 诊断行文案（一条看完整取图链）：插件档成功/尝试、宿主兜底成功/尝试、两侧最后一次错因、
   * 通道是否已接线、最后一次是哪个图源。未取过图时全 0，属正常。
   */
  static imageHint(): string {
    const hostOk: number = ImageCache.hostImageTries - ImageCache.hostImageFails;
    return 'plugin=' + ImageCache.pluginImageHits + '/' + ImageCache.pluginImageTries
      + ' host=' + hostOk + '/' + ImageCache.hostImageTries
      + ' ch=' + (BytesChannels.get() !== null ? 'on' : 'off')
      + ' src=' + (ImageCache.lastImageSource.length > 0 ? ImageCache.lastImageSource : '-')
      + ' host=' + (ImageCache.lastImageHost.length > 0 ? ImageCache.lastImageHost : '-')
      + ' pErr=' + (ImageCache.lastPluginImageErr.length > 0 ? ImageCache.lastPluginImageErr : '-')
      + ' hErr=' + (ImageCache.lastHostImageErr.length > 0 ? ImageCache.lastHostImageErr : '-')
      + ' deobf=' + ImageCache.deobfHits + '/' + ImageCache.deobfSkips
      // blk 三位口径：a = 判成纯黑的张数，b = 探测总张数，u = 其中取样失败（-1）的张数。
      // u == b 时整条判据作废（详见 probeUnknown 的字段注释），不得据 a=0 排除黑图。
      + ' blk=' + ImageCache.blackPages + '/' + ImageCache.probed + '/' + ImageCache.probeUnknown
      + (ImageCache.lastBlack.length > 0 ? ' last=' + ImageCache.lastBlack : '')
      + (ImageCache.lastBlackHost.length > 0 ? ' blkHost=' + ImageCache.lastBlackHost : '')
      + (ImageCache.lastBlackBytes > 0 ? ' blkBytes=' + ImageCache.lastBlackBytes : '')
      + ' hit=' + ImageCache.pageCacheHits
      // ↓ 以下全部是 s15 追加，一律排在既有字段之后（旧诊断行的读法不受影响）
      + (ImageCache.lastNonPluginSource.length > 0 ? ' npSrc=' + ImageCache.lastNonPluginSource : '')
      + ' pf=' + ImageCache.pageFromPlugin
      + ' hf=' + ImageCache.pageFromHost
      + ' df=' + ImageCache.pageFromDisk
      + ' mf=' + ImageCache.pageFromMem
      + (ImageCache.pagePluginNoChannel > 0 ? ' pnc=' + ImageCache.pagePluginNoChannel : '')
      + ' pc=' + ImageCache.pageCalls
      + ' pfail=' + ImageCache.pageFailed
      + (ImageCache.channelNull > 0 ? ' cn=' + ImageCache.channelNull : '')
      + (ImageCache.lastPageIntentLen > 0 ? ' pil=' + ImageCache.lastPageIntentLen : '')
      + (ImageCache.lastProbeErr.length > 0 ? ' pkb=' + ImageCache.lastProbeErr : '')
      // s16 第 2 条：sz= 命中/读到字节/调用 三档（只在 16 号行内读，别和 17 号行的 hit= 混义）
      + ' sz=' + ImageCache.sizeProbeHits + '/' + ImageCache.sizeProbeDisk + '/' + ImageCache.sizeProbeCalls
      // s17 第 5 条：extMiss = 地址是插件取图哨兵而手里没有 extern（页表那一位在链路上被丢了）；
      // extBad = 页表带了 extern 但 JSON.parse 不动。两档都为 0 才是健康形态（无异常时返回空串）。
      // s21 黑区修法：pin= 当前持有 / 因持有跳过 release / 真 release 三档（同时充当包代次标记）
      + ' pin=' + ImageCache.pinLive + '/' + ImageCache.evictHeld + '/' + ImageCache.pmReleased
      + ' at=' + ImageCache.showOk + '/' + ImageCache.showBlack + '/' + ImageCache.showUnknown
      + PluginSourceAdapter.externHint();
  }

  /** 恒等式自查（离线桩与诊断面板都可用）：五档互斥出口相加必须等于调用总数。 */
  static imageChainBalanced(): boolean {
    return ImageCache.pageFromPlugin + ImageCache.pageFromHost + ImageCache.pageFromDisk
      + ImageCache.pageFromMem + ImageCache.pageFailed === ImageCache.pageCalls;
  }

  // ------------------------------------------------------------ 尺寸预探（s16 第 2 条）

  /** 预探调用总数（URL 非空且缓存已就绪才计数）。 */
  static sizeProbeCalls: number = 0;
  /** 其中真从磁盘读到字节的次数。 */
  static sizeProbeDisk: number = 0;
  /** 其中量到有效宽高比（宽与高都大于 0）的次数。 */
  static sizeProbeHits: number = 0;

  /**
   * 只从**磁盘缓存**量图片宽高比：一次网络请求都不发，取不到一律返 0，任何异常都不外抛。
   *
   * 为什么要有这一枚（s16 真机第 2 条「上下滑动两图之间大片黑填充」定案）：旧链路只能等整页解码完
   * 才能在 ReaderPageImage.aspect() 里从 PixelMap 量到真实比，于是「尺寸未知的那一帧」先按窄骨架排高、
   * 解码完又跳到真实等比高（真机 1756x2479 约 1.4 屏）= 把黑区换成可见跳动。上游同一处是
   * method/prefetch_image_sizes.dart：章节就绪后**只读已落盘图片的文件头**填尺寸，未下载的直接跳过、
   * 零网络请求（本机 Breeze/lib/page/comic_read/ 逐行核过），本方法就是它的 ArkTS 等价物 ——
   * 不整页解码同步取宽高的唯一正规入口 = image.createImageSource + ImageSource.getImageInfoSync
   * （@ohos.multimedia.image.d.ts :4258 / :11787），用完必须 release()。Image 组件没有 autoSize
   * （SDK component/ 全目录 grep = 0 命中，API26 无此属性，别去找）。
   *
   * 缓存键必须与 loadPage 逐字符同形（isPlugin 时 url 加 |p| 加 intent，否则量到的尺寸与 loadPage
   * 命中的不是同一份缓存）：intent 走同一条 deobfIntent 通道、异常同样回落空串，两边不得各自演化。
   * 反混淆只重排块、不改画布尺寸，所以按带意图的键读到的原始字节，宽高比与展示尺寸一致。
   *
   * 定位 = 优化而非功能：读不到、目录被回收、字节坏掉、GIF 首帧异常 —— 全部返 0 让调用方回落到
   * 窄骨架，绝不能把一次预探失败变成翻页失败（故整个方法体包 try/catch，与 loadPage 的抛出口径相反）。
   *
   * 代价（有意接受）：同一份磁盘字节会被读两次（本方法一次、随后 loadPage 一次）。页图几百 KB 的顺序
   * 读是毫秒级，换来首帧行高就正确；不做字节常驻 —— 缓存一页 ArrayBuffer 等于偷偷改大 LRU 内存口径。
   */
  async loadSize(url: string, sourceId: string, chapterId: string, ext: string): Promise<number> {
    try {
      if (url === null || url === undefined || url.length === 0) {
        return 0;
      }
      if (!this.ready) {
        return 0;
      }
      ImageCache.sizeProbeCalls++;
      const ch = BytesChannels.get();
      const isPlugin: boolean = sourceId.length > 0 && sourceId.startsWith(PLUGIN_SOURCE_PREFIX);
      let intent: string = '';
      if (isPlugin && ch !== null) {
        try {
          intent = await ch.deobfIntent(sourceId, chapterId, url);
        } catch (err) {
          intent = '';
        }
      }
      // 与 loadPage 同一条 pageKey（见那边注释）：两把键不一致 = 预探永远探不到真取图要用的那份文件。
      const key: string = this.pageKey(isPlugin, url, intent, ext);
      const name: string = await this.hashName(key);
      const path: string = this.cacheRoot + '/' + name + DISK_EXT;
      // readFile 自带 pathExists 闸门（accessSync 取返回值那条口径），目录被系统回收时返 null 而不抛。
      const buf: ArrayBuffer | null = this.readFile(path);
      if (buf === null) {
        return 0;
      }
      ImageCache.sizeProbeDisk++;
      const source: image.ImageSource = image.createImageSource(buf);
      try {
        const info: image.ImageInfo = source.getImageInfoSync();
        const w: number = info.size.width;
        const h: number = info.size.height;
        if (w > 0 && h > 0) {
          ImageCache.sizeProbeHits++;
          return w / h;
        }
        return 0;
      } finally {
        try {
          await source.release();
        } catch (err) {
          Logger.w('释放尺寸预探 ImageSource 失败');
        }
      }
    } catch (err) {
      return 0;
    }
  }

  /** 清空内存与磁盘缓存。 */
  async clear(): Promise<void> {
    // 先取消在途统计：目录马上就要删空，旧 walk 再数下去既浪费 I/O，结果也是错的；
    // 同时放开单飞闸门，保证清理后 measureCache 跑的是全新一条（不会回吐清理前的数字）。
    this.cancelUsage('清理图片缓存');
    // s21 黑区修法：清理同样不得 release 仍挂在屏上的位图（阅读器就在上一层页面时，
    // 旧写法点一次「清理图片缓存」就把正在看的那几张释放掉 = 整行纯黑）。仍被持有的挂待释放表。
    this.mem.forEach((pm: image.PixelMap) => {
      this.releaseMaybe(pm);
    });
    this.mem.clear();
    this.memOrder = [];
    this.pageMem.forEach((pm: image.PixelMap) => {
      this.releaseMaybe(pm);
    });
    this.pageMem.clear();
    this.pageOrder = [];
    // 目录不是一定存在：cacheDir 下的子目录会被系统在存储紧张时回收（真机回传 s8 的
    // 「清理失败：No such file or directory」就是这里直接 listFile 撞 ENOENT）。
    // 拿不到目录 = 本来就没有可删的文件，内存部分已经清完 ⇒ 按成功返回，不冒泡成「清理失败」。
    if (!this.ensureCacheRoot()) {
      Logger.w('图片缓存目录未就绪，跳过磁盘清理');
      return;
    }
    // 磁盘部分同样分批异步：几百次 unlinkSync 串在一条 for 里，就是 BUG2 同款的卡顿，
    // 而且这次是「点清理」触发，卡得更明显。列举失败改为**抛出**（旧实现静默记日志⇒ 上层
    // 误报「已清空」，是真机上「清了但还在」的来源之一）。
    const names: string[] = await fs.listFile(this.cacheRoot);
    let i: number = 0;
    while (i < names.length) {
      const end: number = Math.min(i + STAT_BATCH, names.length);
      const jobs: Promise<void>[] = [];
      for (let k = i; k < end; k++) {
        jobs.push(this.deleteOne(this.cacheRoot + '/' + names[k]));
      }
      await Promise.all(jobs);
      i = end;
      if (i < names.length) {
        await yieldFrame();
      }
    }
    Logger.i('图片缓存已清空，共删除 ' + names.length + ' 个文件');
  }

  /** 单个文件异步删除：目录项与文件间的短暂不一致按「已删」处理。 */
  private async deleteOne(path: string): Promise<void> {
    try {
      await fs.unlink(path);
    } catch (err) {
      Logger.w('删除缓存文件失败：' + path);
    }
  }

  /** 当前内存缓存条目数（调试/内存面板用）。 */
  memSize(): number {
    return this.mem.size;
  }

  /**
   * 磁盘缓存占用的**同步**版：仅留给确定不在 UI 线程上的调用方（诊断面板、离线自检）。
   * 真机回传 BUG2/BUG5 就是它被放进 setTimeout 后仍在主线程跑 ⇒ 文件一多 UI 长时间停在
   * 「统计中」并把设置页首帧卡白。UI 请一律用 diskUsageAsync()。
   *
   * 刻意不写 CacheUsageText 的共享口径：那是两行 UI 文案的唯一来源，只允许异步链路写。
   * 诊断面板可见期间也会调这个同步版，若一并写进去，下一次重绘会把「未数完」贴到与
   * 本结果无关的那一行上。口径只在返回的 DiskUsage 自己身上带（complete/note 字段）。
   */
  diskUsage(): DiskUsage {
    const u: DiskUsage = new DiskUsage();
    // 与异步版同一道闸门：目录缺失时报 ready=false（「没数」），不是 0 B（「没有」）。
    if (!this.ensureCacheRoot()) {
      return u;
    }
    u.ready = true;
    let names: string[] = [];
    try {
      names = fs.listFileSync(this.cacheRoot);
    } catch (err) {
      // 列举失败 = 一个数都没拿到。旧写法只记日志仍返回 ready=true，
      // 诊断面板于是把「没数」读成「0 B」，与异步版口径相反 ⇒ 改为未就绪。
      const why: string = errBrief(err as Object);
      u.ready = false;
      u.complete = false;
      u.note = why;
      Logger.ex('统计图片缓存占用失败（列举）：' + why, err as Object);
      return u;
    }
    u.files = names.length;
    let fails: number = 0;
    for (let i = 0; i < names.length; i++) {
      try {
        u.bytes += fs.statSync(this.cacheRoot + '/' + names[i]).size;
      } catch (err) {
        // 单个文件刚好被淘汰掉：跳过即可，不影响总数口径
        fails += 1;
      }
    }
    if (fails > 0) {
      u.complete = false;
      u.note = fails + ' 个文件读不到大小';
    }
    return u;
  }

  /**
   * 磁盘缓存占用（异步分片版，**UI 侧唯一入口**）。四条保证，按重要度排：
   *
   *   ① 单飞：已有统计在跑就直接复用那条 promise（含另一个页面发起的），连点重试只会
   *      得到同一个结果，不会堆出第二条并发 walk 抢同一批文件。
   *   ② 「数不完」不算失败：stat 阶段只受软预算 USAGE_SOFT_BUDGET_MS 与单批上限
   *      USAGE_BATCH_TIMEOUT_MS 约束，到点交**部分结果**（complete=false、bytes 偏小、
   *      files 仍是列举得到的准数）。缓存没有容量上限（见 clear 的注释），数不完是常态。
   *   ③ 唯一进失败态的路径 = 列举本身超时/报错（真卡死），错因带 code 与 message 上抛，
   *      并由 walkUsage 同时写进 Logger，真机回传能看到到底卡在哪一步。
   *   ④ 可取消：clear() 抬代数让在途 walk 在批边界自行退出，并释放单飞闸门，
   *      所以「清理后立刻重测」一定是新一条 walk，不会把清理前的旧数字当成清理结果。
   *
   * 最坏耗时 = 列举 20s（失败）或 列举 + 6s 软预算（成功交部分结果），不再是 20s 一句「失败」。
   */
  async diskUsageAsync(): Promise<DiskUsage> {
    const running: Promise<DiskUsage> | null = this.usagePromise;
    if (running !== null) {
      return await running;
    }
    const gen: number = this.usageGen + 1;
    this.usageGen = gen;
    const p: Promise<DiskUsage> = this.walkUsage(gen);
    this.usagePromise = p;
    try {
      return await p;
    } finally {
      // 只清自己这一条：cancelUsage 已把闸门让给新一轮时，不能把新 promise 误置 null
      if (this.usagePromise === p) {
        this.usagePromise = null;
      }
    }
  }

  /**
   * 取消在途统计（clear 用）：抬代数让旧 walk 在下一个批边界退出，同时放开单飞闸门，
   * 让清理后的重测必定是全新一条。被取消那条 walk 仍会跑完当前批再自行收尾（结果作废）。
   */
  private cancelUsage(why: string): void {
    if (this.usagePromise === null) {
      return;
    }
    this.usageGen += 1;
    this.usagePromise = null;
    Logger.i('取消在途的图片缓存统计：' + why);
  }

  private async walkUsage(gen: number): Promise<DiskUsage> {
    const u: DiskUsage = new DiskUsage();
    const st: WalkState = new WalkState();
    // 目录没就绪（init 没跑完，或目录已被系统回收且重建失败）：ready=false，
    // 让 UI 走「缓存未就绪，点此重试」而不是 0 B，也不冒泡成「统计失败」。
    if (!this.ensureCacheRoot()) {
      CacheUsageText.recordQuality(gen, u.complete, u.sized, 0);
      return u;
    }
    u.ready = true;
    let names: string[] = [];
    try {
      // 只有这一段允许判定失败：目录都读不到，就真的没有任何可展示的数字
      names = await withTimeout(fs.listFile(this.cacheRoot), USAGE_LIST_TIMEOUT_MS, '列举图片缓存目录');
    } catch (err) {
      const why: string = errBrief(err as Object);
      // 错因两头落：日志给回传取证，数字码进文案给用户看。两页 catch 之后都只渲染 FAILED，
      // 所以口径写在这里而不在页面里各写一套（MinePage 本轮不归我改，更不可能去它里面写）
      CacheUsageText.recordQuality(gen, false, false, errCode(err as Object));
      Logger.e('图片缓存统计失败（列举）：' + why + '，目录=' + this.cacheRoot);
      throw new Error(why);
    }
    // 文件数来自目录列举，与 stat 成不成功无关 ⇒ 先落成准数，字节数再按 stat 进度累加
    u.files = names.length;
    const deadline: number = Date.now() + USAGE_SOFT_BUDGET_MS;
    let i: number = 0;
    while (i < names.length) {
      if (gen !== this.usageGen) {
        st.stopped = true;
        u.complete = false;
        u.note = '统计被新的请求取消';
        CacheUsageText.recordQuality(gen, u.complete, u.sized, 0);
        Logger.w('图片缓存统计被取消：已 stat ' + st.sized + '/' + names.length + '，交部分结果');
        return u;
      }
      const end: number = Math.min(i + STAT_BATCH, names.length);
      const jobs: Promise<void>[] = [];
      for (let k = i; k < end; k++) {
        jobs.push(this.addSize(this.cacheRoot + '/' + names[k], u, st));
      }
      try {
        // 单批封顶：一次 fs.stat 不返回就会挂死整条链路（旧 BUG2「永远统计中」的同族）
        await withTimeout(Promise.all(jobs), USAGE_BATCH_TIMEOUT_MS, '图片缓存 stat 批次');
      } catch (err) {
        if (!st.stopped) {
          // 这里加的是「批」不是「个文件」：一卡最多含 STAT_BATCH 个文件，
          // 计入 fails 会把「一批没数到」算成「一个没数到」，下面的比例判据就废了
          st.batchFails += 1;
          if (st.firstCode.length === 0) {
            st.firstCode = errBrief(err as Object);
          }
        }
        Logger.w('图片缓存 stat 批次未按时返回：' + errBrief(err as Object));
      }
      i = end;
      if (i >= names.length) {
        break;
      }
      if (Date.now() >= deadline) {
        st.stopped = true;
        u.complete = false;
        u.note = '文件较多，已数 ' + st.sized + '/' + names.length;
        CacheUsageText.recordQuality(gen, u.complete, u.sized, 0);
        Logger.i('图片缓存统计达到软预算，交部分结果：已 stat ' + st.sized + '/' + names.length);
        return u;
      }
      await yieldFrame();
    }
    st.stopped = true;
    // 结果分级：全数到 / 少量文件读不到（正常淘汰）/ 大面积读不到（降级只数文件）
    if (st.sized === 0 && names.length > 0) {
      u.sized = false;
      u.bytes = 0;
      u.complete = false;
      u.note = '读不到文件大小' + (st.firstCode.length > 0 ? '（' + st.firstCode + '）' : '');
      Logger.w('图片缓存统计降级为只数文件：' + u.files + ' 个文件，' + u.note);
    } else {
      // missing 与 names 同量纲（文件个数）：既含逐个 stat 失败，也含整批超时没数到的那些
      const missing: number = names.length - st.sized;
      if (missing > names.length * STAT_FAIL_RATIO) {
        u.complete = false;
        u.note = missing + ' 个文件读不到大小' + (st.firstCode.length > 0 ? '（' + st.firstCode + '）' : '');
        Logger.w('图片缓存占用统计不完整：' + u.note);
      }
    }
    CacheUsageText.recordQuality(gen, u.complete, u.sized, 0);
    Logger.i('图片缓存占用统计' + (u.complete ? '完成' : '部分') + '：' + u.files + ' 个文件 / '
      + u.bytes + ' B / stat 成功 ' + st.sized + ' 失败 ' + st.fails + ' 卡批 ' + st.batchFails);
    return u;
  }

  /**
   * 单文件体积累加（异步）。失败不再逐条写日志（几千个文件会把真机日志刷满，
   * 反倒把关键行冲掉），改为计数 + 首个错因，由 walkUsage 汇总一条。
   */
  private async addSize(path: string, u: DiskUsage, st: WalkState): Promise<void> {
    try {
      const info: fs.Stat = await fs.stat(path);
      if (st.stopped) {
        return;
      }
      u.bytes += info.size;
      st.sized += 1;
    } catch (err) {
      if (st.stopped) {
        return;
      }
      st.fails += 1;
      if (st.firstCode.length === 0) {
        st.firstCode = errBrief(err as Object);
      }
    }
  }

  /** 缓存内容变更的版本号键（AppStorage）：清理/统计完成后 push。 */
  static readonly CACHE_REVISION_KEY: string = 'cacheRevision';

  /**
   * 推一次缓存版本号，驱动别的页面重算。
   * 为什么必须走 AppStorage：MinePage 是 TabContent 子组件，router.back 回来不重跑
   * aboutToAppear，onPageShow 也不生效 ⇒ 只能 @StorageProp + @Watch（同 DetailPage 的
   * 'shelfRevision' 口径）。
   */
  static bumpCacheRevision(): void {
    const cur: number = AppStorage.get<number>(ImageCache.CACHE_REVISION_KEY) ?? 0;
    AppStorage.setOrCreate<number>(ImageCache.CACHE_REVISION_KEY, cur + 1);
  }

  // ------------------------------------------------------------ 内存 LRU

  /**
   * 命中查找（page=true 走页图桶，容量更小）。
   * 注意 key 可能是「url|intent」形态，只做键匹配，不解析。
   */
  private memGet(key: string, page: boolean): image.PixelMap | null {
    const store: Map<string, image.PixelMap> = page ? this.pageMem : this.mem;
    const order: string[] = page ? this.pageOrder : this.memOrder;
    const pm: image.PixelMap | undefined = store.get(key);
    if (pm === undefined) {
      return null;
    }
    // 命中后移到队尾，保证 LRU 顺序
    const idx: number = order.indexOf(key);
    if (idx >= 0) {
      order.splice(idx, 1);
    }
    order.push(key);
    return pm;
  }

  private memPut(key: string, pm: image.PixelMap, page: boolean): void {
    const store: Map<string, image.PixelMap> = page ? this.pageMem : this.mem;
    const order: string[] = page ? this.pageOrder : this.memOrder;
    const cap: number = page ? MAX_PAGE_MEM : MAX_MEM;
    const prev: image.PixelMap | undefined = store.get(key);
    if (store.has(key)) {
      const idx: number = order.indexOf(key);
      if (idx >= 0) {
        order.splice(idx, 1);
      }
    }
    // 同键换实例（并发 loadPage 同址、或手动重试重新解码）：旧实例也可能还挂在屏上，
    // 走同一条出口，不再静默覆盖后不管（旧写法这条路径既漏 release 也不计数）
    if (prev !== undefined && prev !== pm) {
      this.releaseMaybe(prev);
    }
    store.set(key, pm);
    order.push(key);
    while (store.size > cap && order.length > 0) {
      const oldest: string = order[0];
      order.splice(0, 1);
      const evicted: image.PixelMap | undefined = store.get(oldest);
      store.delete(oldest);
      // s21 黑区修法：被淘汰项「最久未用」不等于「不在屏上」—— 阅读器行的 pm 只有 memGet
      // 命中才 bump LRU，屏上静止阅读的那几行从不 bump，快翻时正是它们被判成最久未用。
      // 对仍被持有的位图 release = Image 画整幅纯黑（无异常无日志），所以一律走 releaseMaybe。
      if (evicted !== undefined) {
        this.releaseMaybe(evicted);
      }
    }
  }
  // ---------------------------------------------------------- 持有登记（s21 黑区修法）

  /**
   * 消费侧挂载期间持有：把 loadPage 返回的位图写进组件状态之前调用，与 unpin 严格配对
   * （阅读器侧由 setShown 一步做完，见 view/reader/ReaderView.ets）。
   */
  retain(pm: image.PixelMap): void {
    const c: number = this.pinned.get(pm) ?? 0;
    this.pinned.set(pm, c + 1);
    ImageCache.pinLive++;
    // 曾被逐出、又被同一实例重新挂载（翻回上一页命中缓存）：撤回待释放标记
    this.pendingRelease.delete(pm);
  }

  /** 与 retain 配对的归还：计数归零且已不在缓存里（挂在待释放表上）才真 release。 */
  unpin(pm: image.PixelMap | undefined): void {
    if (pm === undefined) {
      return;
    }
    const c: number = this.pinned.get(pm) ?? 0;
    if (c <= 1) {
      this.pinned.delete(pm);
    } else {
      this.pinned.set(pm, c - 1);
    }
    if (ImageCache.pinLive > 0) {
      ImageCache.pinLive--;
    }
    if (this.pinned.get(pm) === undefined && this.pendingRelease.get(pm) === true) {
      this.pendingRelease.delete(pm);
      this.releaseNow(pm, 'unpin');
    }
  }

  /**
   * 消费侧挂载那一刻补一次纯黑探针（异步、只记账、不参与任何渲染判定）。
   * 调用方负责按实例去重（同一次挂载只报一次），见 view/reader/ReaderView.ets 的 setShown。
   */
  static probeShown(pm: image.PixelMap): void {
    ImageCache.probeBlack(pm).then((v: number): void => {
      if (v === 1) {
        ImageCache.showBlack++;
      } else if (v === -1) {
        ImageCache.showUnknown++;
      } else {
        ImageCache.showOk++;
      }
    }).catch((): void => {
      ImageCache.showUnknown++;
    });
  }

  /** 淘汰与清理的统一出口：仍被持有的只挂进待释放表，绝不 release（黑区修法核心）。 */
  private releaseMaybe(pm: image.PixelMap): void {
    if (this.pinned.get(pm) !== undefined) {
      this.pendingRelease.set(pm, true);
      ImageCache.evictHeld++;
      return;
    }
    this.releaseNow(pm, 'evict');
  }

  /** 真 release（异步、吞异常）并计数，供诊断行核对「到底释放了几张」。 */
  private releaseNow(pm: image.PixelMap, why: string): void {
    try {
      // isReleased 是方法（@ohos.multimedia.image.d.ts:5970，@since 22）；旧写法取方法引用恒真，
      // 见 memPut 里 s14 那段历史注释。这里必须真调用。
      if (pm.isReleased()) {
        return;
      }
    } catch (err) {
      // 已释放对象上调 isReleased 可能直接抛：按「无需再释放」处理，不冒泡
      return;
    }
    ImageCache.pmReleased++;
    pm.release().catch((err: BusinessError) => {
      Logger.ex('PixelMap release 失败(' + why + ')', err as Object);
    });
  }


  // ------------------------------------------------------------ 解码

  /**
   * editable=true 时申请可写 PixelMap —— 反混淆要 writeBufferToPixels。
   * 普通图保持 editable:false（解码器可走只读快路径，内存也更省）。
   */
  private async decode(buf: ArrayBuffer, editable: boolean): Promise<image.PixelMap> {
    const source: image.ImageSource = image.createImageSource(buf);
    let pm: image.PixelMap | null = null;
    try {
      const opts: image.DecodingOptions = {
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
        editable: editable
      };
      pm = await source.createPixelMap(opts);
    } finally {
      try {
        await source.release();
      } catch (err) {
        Logger.w('释放 ImageSource 失败');
      }
    }
    if (pm === null) {
      throw new Error('图片解码返回空结果');
    }
    return pm;
  }

  // ------------------------------------------------------------ 磁盘

  /**
   * 存在性判定：accessSync 的返回值本身就是答案，不能只看它抛不抛。
   *
   * SDK 原文（@ohos.file.fs.d.ts:316-318）：mode 留空时「the system checks whether the file
   * or directory exists」，返回值「The value true means the file exists; the value false means
   * the opposite」⇒ 目录不存在时它返回 false 并且**不抛**。旧写法只在 catch 里返回 false，
   * 于是恒为 true，两个目录判定（doInit 的补目录、ensureCacheRoot 的闸门）恒判「已存在」：
   * 启动期从不补目录（这就是运行期缺目录的来源），运行期被系统回收后也永远补不回来，
   * 下游 fs.listFile 必抛 13900002 ⇒ s10a 真机回传的「统计失败13900002」。
   *
   * catch 保留不删：accessSync 的 throws 表里另有 13900012（权限）这类真抛出的档，
   * 抛出来同样按「不可用」处理。这样「返回 false」与「抛异常」两种实现都收敛到 false，
   * 本判定不依赖 SDK 在「不存在」这一档到底选哪一种。
   *
   * 同 API 在本仓另两处用法都是取返回值的（PluginAutoLoader.ets:181、
   * PluginSourceRegistry.ets:68），本方法是唯一按「抛没抛」判的，属笔误而非另一种口径。
   */
  private pathExists(path: string): boolean {
    try {
      return fs.accessSync(path) === true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 缓存目录就绪自检：clear、diskUsage、diskUsageAsync、writeFile 四条磁盘链路进门先过这里。
   *
   * 为什么必须有（真机回传 s8 定案）：cacheDir 下的子目录是系统可回收的（文件头 CACHE_DIR_NAME
   * 定位就是「系统可随应用清理」），并且 doInit 只在「不存在时」mkdir 一次 ⇒ 运行期目录消失
   * 是完全正常的状态，不是异常。旧写法直接 fs.listFile(cacheRoot) 会抛 13900002
   * No such file or directory，冒到上层就是「统计失败，点此重试」和「清理失败：…」。
   *
   * 三条出口：cacheRoot 为空（init 未跑）false；目录在 true；目录不在则幂等重建，
   * （「目录在不在」完全由 pathExists 读 accessSync 返回值给出，它一旦退回「只看抛没抛」，
   *   本闸门与 doInit 会同时变成空操作 —— 判定处的注释已记着这条，勿再改回去）
   * 重建成功 true、失败 false（只记日志不抛）。返回 false 的语义 = 拿不到目录，
   * 调用方一律按「空缓存」处理：统计给 ready=false，清理按成功返回。
   *
   * 与 doInit 里那处补目录的分工（两处都是 recursion=true 的 mkdirSync，因为「父级 cacheDir 一起
   * 被回收」在启动期和运行期都可能发生）：doInit 只管启动那一次，跑完就不再回来；
   * 本方法是每次读/写磁盘链路进门都要过的运行期闸门。
   */
  private ensureCacheRoot(): boolean {
    if (this.cacheRoot.length === 0) {
      return false;
    }
    if (this.pathExists(this.cacheRoot)) {
      return true;
    }
    try {
      fs.mkdirSync(this.cacheRoot, true);
      Logger.i('图片缓存目录缺失，已重建：' + this.cacheRoot);
      return true;
    } catch (err) {
      const be = err as BusinessError;
      Logger.w('重建图片缓存目录失败 code=' + be.code + ' message=' + be.message);
      return false;
    }
  }

  private readFile(path: string): ArrayBuffer | null {
    let fd: number = -1;
    try {
      if (!this.pathExists(path)) {
        return null;
      }
      const size: number = fs.statSync(path).size;
      if (size <= 0) {
        return null;
      }
      const file: fs.File = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fd = file.fd;
      const buf: ArrayBuffer = new ArrayBuffer(size);
      const readLen: number = fs.readSync(fd, buf);
      if (readLen <= 0) {
        return null;
      }
      if (readLen === size) {
        return buf;
      }
      return buf.slice(0, readLen);
    } catch (err) {
      Logger.ex('读取图片缓存失败', err as Object);
      return null;
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (err) {
          Logger.w('关闭图片文件失败');
        }
      }
    }
  }

  private writeFile(path: string, buf: ArrayBuffer): void {
    let fd: number = -1;
    try {
      // 同根因的第四个出口：目录被系统回收后 openSync(CREATE) 必抛 13900002，
      // 旧写法只记日志 ⇒ 从回收那刻起「旧图读得到、新图一律写不进」的静默降级。
      // 先补目录再写；补不上仍按原语义「本次不落盘、不影响展示」。
      if (!this.ensureCacheRoot()) {
        // 日志文案带固定前缀：真机回传时这一行是「新图没落盘」的唯一证据
        Logger.w('图片缓存目录缺失，本次未落盘：' + path);
        return;
      }
      const file: fs.File = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fd = file.fd;
      fs.writeSync(fd, buf);
    } catch (err) {
      // 磁盘写失败只影响下次命中，不影响本次展示
      Logger.ex('写入图片缓存失败', err as Object);
    } finally {
      if (fd >= 0) {
        try {
          fs.closeSync(fd);
        } catch (err) {
          Logger.w('关闭图片文件失败');
        }
      }
    }
  }

  private deleteFile(path: string): void {
    try {
      if (this.pathExists(path)) {
        fs.unlinkSync(path);
      }
    } catch (err) {
      Logger.w('删除缓存文件失败：' + path);
    }
  }

  // ------------------------------------------------------------ 缓存键

  /**
   * 页图缓存键（loadPage 与 loadSize 共用，s17 第 5 条）。三条设计约束：
   * ① **非插件支路与「插件但没 extern」支路的键式与改造前逐字节相同**（'|x|' 段只在 ext 非空时才拼）。
   *    理由：这两类占本机九个插件载荷里的八个，无条件拼接会让它们真机上的存量磁盘缓存整批失配
   *    = 白白重下一整章；而哨兵 url 图源只有 eh 一家，它本来就必须换键。
   * ② ext 原样拼、不做 encodeURIComponent 之类转义：ext 可达数百字节（href + 分块信息），转义只会更长；
   *    键最终进 sha256 定文件名（hashName），长度不影响磁盘侧，内存侧上限 MAX_PAGE_MEM=24 条。
   * ③ 不在这把键上做「同章各页去重」：哨兵 url 下整章 url 相同，靠 ext 天然分开 = 就是要分开，
   *    共用一把键会让第 2 页显示第 1 页的图（这是本次修复的另一半动机）。
   */
  private pageKey(isPlugin: boolean, url: string, intent: string, ext: string): string {
    if (!isPlugin) {
      return url;
    }
    return url + '|p|' + intent + (ext.length > 0 ? '|x|' + ext : '');
  }

  // ------------------------------------------------------------ 文件名

  /** 文件名 = sha256(url)，失败时退化为 djb2（仍然稳定，只是碰撞概率稍高）。 */
  private async hashName(url: string): Promise<string> {
    try {
      const md: cryptoFramework.Md = cryptoFramework.createMd('SHA256');
      const encoder: util.TextEncoder = new util.TextEncoder();
      const data: Uint8Array = encoder.encodeInto(url);
      await md.update({ data: data });
      const digest: cryptoFramework.DataBlob = await md.digest();
      const bytes: Uint8Array = digest.data;
      let hex: string = '';
      for (let i = 0; i < bytes.length; i++) {
        const b: number = bytes[i];
        hex += b < 16 ? '0' + b.toString(16) : b.toString(16);
      }
      if (hex.length > 0) {
        return hex;
      }
    } catch (err) {
      Logger.ex('sha256 计算失败，退化为 djb2', err as Object);
    }
    return this.djb2(url);
  }

  private djb2(text: string): string {
    let h: number = 5381;
    for (let i = 0; i < text.length; i++) {
      h = ((h << 5) + h + text.charCodeAt(i)) & 0x7fffffff;
    }
    let hex: string = h.toString(16);
    while (hex.length < 8) {
      hex = '0' + hex;
    }
    return 'djb2_' + hex;
  }

  private wrap(err: Object, prefix: string): Error {
    const be = err as BusinessError;
    const code: number = be.code;
    const rawMsg: string = be.message;
    const msg: string = rawMsg ? rawMsg : '未知错误';
    if (typeof code === 'number') {
      return new Error(prefix + '(' + code + ')：' + msg);
    }
    return new Error(prefix + '：' + msg);
  }
}