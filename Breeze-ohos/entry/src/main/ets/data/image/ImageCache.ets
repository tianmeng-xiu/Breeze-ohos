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
import { PLUGIN_SOURCE_PREFIX } from '../source/PluginSourceAdapter';

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
    return this.loadPage(url, '', '');
  }

  /**
   * 取漫画页图（s6j）：sourceId 是插件图源且通道已接线 ⇒ 用插件 fetchImageBytes 取字节
   * （带 Referer/风控头），再按意图做 JM 分块反混淆。
   * 缓存口径（重要）：**磁盘存的永远是原始字节**，反混淆每次解码后重做（检测开销 ~1e5 次减法，
   * 相对解码可忽略），因此手动开关 auto/on/off 改完立即生效，不会被旧缓存钉住；
   * 内存/磁盘键都带意图后缀 ⇒ 同 URL 的「原图 / 已重排」不会互相污染。
   */
  async loadPage(url: string, sourceId: string, chapterId: string): Promise<image.PixelMap> {
    if (url === null || url === undefined || url.length === 0) {
      throw new Error('图片地址为空');
    }
    if (!this.ready) {
      throw new Error('图片缓存尚未初始化，请先调用 ImageCache.init(context)');
    }

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
    const key: string = isPlugin ? (url + '|p|' + intent) : url;

    const hit: image.PixelMap | null = this.memGet(key, isPlugin);
    if (hit !== null) {
      return hit;
    }

    const name: string = await this.hashName(key);
    const path: string = this.cacheRoot + '/' + name + DISK_EXT;

    let buf: ArrayBuffer | null = this.readFile(path);
    if (buf === null && isPlugin && ch !== null) {
      // 插件通道优先（这是「部分源画面不正常」的第一半根因：宿主 HTTP 没有插件的 Referer）
      try {
        const got: ArrayBuffer | null = await ch.fetch(sourceId, url);
        if (got !== null) {
          buf = got;
        }
      } catch (err) {
        Logger.w('插件取图失败，回落宿主 HTTP：' + ((err as Error).message ?? String(err)));
      }
    }
    let fromNet: boolean = buf === null;
    if (buf === null) {
      try {
        buf = await HttpClient.getInstance().getBytes(url);
      } catch (err) {
        throw this.wrap(err, '图片下载失败');
      }
    }

    let pm: image.PixelMap | null = null;
    try {
      pm = await this.decode(buf, intent.length > 0);
    } catch (err) {
      // 磁盘文件可能已损坏：删掉，下次重新下载
      this.deleteFile(path);
      throw this.wrap(err, fromNet ? '图片解码失败' : '本地缓存图片已损坏，请重试');
    }
    if (pm === null) {
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

    if (fromNet) {
      this.writeFile(path, buf);
    }
    this.memPut(key, pm, isPlugin);
    return pm;
  }

  /** 诊断面板用：反混淆生效次数 / 跳过次数 / 最后一次状态。 */
  static deobfHits: number = 0;
  static deobfSkips: number = 0;
  static lastDeobf: string = '';

  /** 清空内存与磁盘缓存。 */
  async clear(): Promise<void> {
    // 先取消在途统计：目录马上就要删空，旧 walk 再数下去既浪费 I/O，结果也是错的；
    // 同时放开单飞闸门，保证清理后 measureCache 跑的是全新一条（不会回吐清理前的数字）。
    this.cancelUsage('清理图片缓存');
    this.mem.forEach((pm: image.PixelMap) => {
      try {
        pm.release();
      } catch (err) {
        Logger.w('释放 PixelMap 失败');
      }
    });
    this.mem.clear();
    this.memOrder = [];
    this.pageMem.forEach((pm: image.PixelMap) => {
      try {
        pm.release();
      } catch (err) {
        Logger.w('释放页图 PixelMap 失败');
      }
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
    if (store.has(key)) {
      const idx: number = order.indexOf(key);
      if (idx >= 0) {
        order.splice(idx, 1);
      }
    }
    store.set(key, pm);
    order.push(key);
    while (store.size > cap && order.length > 0) {
      const oldest: string = order[0];
      order.splice(0, 1);
      const evicted: image.PixelMap | undefined = store.get(oldest);
      store.delete(oldest);
      // 被淘汰项是「最久未用」的图像，通常已不在屏上；释放其 native 内存，避免 RLIMIT 累积
      if (evicted !== undefined && !evicted.isReleased) {
        evicted.release().catch((err: BusinessError) => {
          Logger.ex('PixelMap release 失败', err as Object);
        });
      }
    }
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