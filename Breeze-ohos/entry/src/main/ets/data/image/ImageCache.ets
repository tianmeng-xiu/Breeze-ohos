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
/** 整次统计的兜底超时：底层卡住也要给 UI 一个「失败重试」出口，而不是永远「统计中」。 */
const USAGE_TIMEOUT_MS: number = 20000;

/** 让出一帧：setTimeout(0) 排到下一轮宏任务，让 UI 有机会绘制与响应输入。 */
function yieldFrame(): Promise<boolean> {
  return new Promise<boolean>((resolve: (v: boolean) => void): void => {
    setTimeout((): void => {
      resolve(true);
    }, 0);
  });
}

/** 超时包裹（写法同 data/source/PluginSettings.ets:143）：给统计链路上一道硬上限。 */
function withTimeout<T>(p: Promise<T>, ms: number, tag: string): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_resolve: (v: T) => void, reject: (err: Error) => void): void => {
      setTimeout((): void => {
        reject(new Error(tag + ' 超时 ' + ms + 'ms'));
      }, ms);
    })
  ]);
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

  /** 阶段 → 整行文案：两页共用，杜绝「统计中/计算中」这类同义漂移 */
  static of(phase: string, bytes: number, files: number): string {
    if (phase === CacheUsageText.P_FAILED) {
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

  /** 设置页整行摘要：'12.3 MB · 208 个文件' */
  static done(bytes: number, files: number): string {
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
      // recursion=true（@since 11）：连父级 cacheDir 一起补。单级 mkdir 在父目录也被系统回收时
      // 会再次抛 13900002，把整个数据层 init 一起带失败（EntryAbility 只记日志 ⇒ 全站静默降级）。
      if (!this.pathExists(this.cacheRoot)) {
        fs.mkdirSync(this.cacheRoot, true);
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
   */
  diskUsage(): DiskUsage {
    const u: DiskUsage = new DiskUsage();
    // 与异步版同一道闸门：目录缺失时报 ready=false（「没数」），不是 0 B（「没有」）。
    if (!this.ensureCacheRoot()) {
      return u;
    }
    u.ready = true;
    try {
      const names: string[] = fs.listFileSync(this.cacheRoot);
      for (let i = 0; i < names.length; i++) {
        try {
          u.bytes += fs.statSync(this.cacheRoot + '/' + names[i]).size;
          u.files += 1;
        } catch (err) {
          // 单个文件刚好被淘汰掉：跳过即可，不影响总数口径
        }
      }
    } catch (err) {
      Logger.ex('统计图片缓存占用失败', err as Object);
    }
    return u;
  }

  /**
   * 磁盘缓存占用（异步分片版，**UI 侧唯一入口**）：
   *   列举走 fs.listFile（native 线程），stat 每批最多 STAT_BATCH 个并发、批间 await 一帧
   *   ⇒ 几百个 .img 也不会把主线程一次占住；整体超时 USAGE_TIMEOUT_MS 后抛错，
   *   由调用方落到「统计失败，点此重试」，不会永远停在「统计中」。
   * 口径与同步版一致：单文件 stat 失败（刚好被淘汰）跳过，不计入 files。
   */
  async diskUsageAsync(): Promise<DiskUsage> {
    return await withTimeout(this.walkUsage(), USAGE_TIMEOUT_MS, '统计图片缓存占用');
  }

  private async walkUsage(): Promise<DiskUsage> {
    const u: DiskUsage = new DiskUsage();
    // 目录没就绪（init 没跑完，或目录已被系统回收且重建失败）：ready=false，
    // 让 UI 走「缓存未就绪，点此重试」而不是 0 B，也不冒泡成「统计失败」。
    if (!this.ensureCacheRoot()) {
      return u;
    }
    u.ready = true;
    const names: string[] = await fs.listFile(this.cacheRoot);
    let i: number = 0;
    while (i < names.length) {
      const end: number = Math.min(i + STAT_BATCH, names.length);
      const jobs: Promise<void>[] = [];
      for (let k = i; k < end; k++) {
        jobs.push(this.addSize(this.cacheRoot + '/' + names[k], u));
      }
      await Promise.all(jobs);
      i = end;
      if (i < names.length) {
        await yieldFrame();
      }
    }
    Logger.i('图片缓存占用统计完成：' + u.files + ' 个文件 / ' + u.bytes + ' B');
    return u;
  }

  /** 单文件体积累加（异步）；失败只跳过一个文件，不影响整体口径。 */
  private async addSize(path: string, u: DiskUsage): Promise<void> {
    try {
      const st: fs.Stat = await fs.stat(path);
      u.bytes += st.size;
      u.files += 1;
    } catch (err) {
      Logger.w('stat 跳过（文件可能刚被淘汰）：' + path);
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

  private pathExists(path: string): boolean {
    try {
      fs.accessSync(path);
      return true;
    } catch (err) {
      return false;
    }
  }

  /**
   * 缓存目录就绪自检：clear、diskUsage、diskUsageAsync、writeFile 四条磁盘链路进门先过这里。
   *
   * 为什么必须有（真机回传 s8 定案）：cacheDir 下的子目录是系统可回收的（本文件 :31 的目录
   * 定位就是「系统可随应用清理」），并且 doInit 只在「不存在时」mkdir 一次 ⇒ 运行期目录消失
   * 是完全正常的状态，不是异常。旧写法直接 fs.listFile(cacheRoot) 会抛 13900002
   * No such file or directory，冒到上层就是「统计失败，点此重试」和「清理失败：…」。
   *
   * 三条出口：cacheRoot 为空（init 未跑）false；目录在 true；目录不在则幂等重建，
   * 重建成功 true、失败 false（只记日志不抛）。返回 false 的语义 = 拿不到目录，
   * 调用方一律按「空缓存」处理：统计给 ready=false，清理按成功返回。
   *
   * 与 doInit :167 的分工（两处都是 recursion=true 的 mkdirSync，因为「父级 cacheDir 一起
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