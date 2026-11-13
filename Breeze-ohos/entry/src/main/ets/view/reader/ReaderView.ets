/**
 * 职责：阅读器视图 —— 两档阅读模式（s13 第 6 条）：横向翻页（Swiper）与从上向下连续滚动
 *      （List 加 LazyForEach）共用同一套顶栏、单击显隐、左右点按、图片解码通道与进度落库；
 *      双指缩放与平移只在横向档生效。
 * 设置接线（s7a）：阅读方向读 util/UserSettings.readDirection()，rtl 时给 Swiper 加 .direction(Rtl)
 *      —— 布局方向会向下继承，页内左中右三个点按热区随 Row 一起镜像，所以热区的回调不换位
 *      （child0 恒为「上一页」，rtl 下它自然落到屏幕右侧），与上游 reverseHorizontalPageTurn
 *      「交换左右翻页方向」的用户预期一致。放大后点按的行为由 reader_tap_to_scroll 决定：
 *      开 = 平移画面（钳在放大后的可视边界内），关 = 仍然翻页。两项都在 pages/SettingPage 里改。
 * 阅读模式（s13 第 6 条，用户原话「阅读器增加一个选项，添加从上向下滚动观看的功能，暂时把这个设置
 *      放在更多的阅读设置里面」）：档位存 util/UserSettings.readScrollMode()（键 reader_scroll_mode），
 *      入口在 view/mine/MinePage 的「更多 加 阅读设置」。默认档 = 横向翻页，老用户升级后第一眼看到的
 *      东西与升级前完全一致。两档互切只走 applyScrollMode 一个入口：切之前把「正在看的那一页」交给
 *      对方，所以互切不丢进度；写档同时推 AppStorage 的 readerScrollMode，阅读器若还活着，
 *      靠 @StorageProp 加 @Watch 立刻翻档（口径见 applyScrollMode 上方注释）。
 * 依赖：Theme/Dim；data 层 SourceManager / MangaSource / ImageCache / MangaRepository；@kit.ImageKit。
 * 对应 Flutter：lib/page/comic_read/widgets/modes/row_mode.dart（横向阅读）
 *              + widgets/chrome/app_bar.dart / bottom.dart（阅读器顶底栏）。
 * 说明：本页是二级全屏页（无底栏），由 pages/ReaderPage.ets 承载路由；
 *      阅读器不依赖系统状态栏，顶栏显隐即「全屏沉浸」。
 * 纵向档三条硬口径（s13 第 6 条，写死的理由都在正文注释里）：
 *      1) List 的 scroller 走对象参数（本仓 DiscoverPage.ets:380 同形），不是位置参数；
 *      2) 页码一律用 onScrollIndex 的 center（次选 start），绝不用 onDidScroll 的每帧增量；
 *      3) 回章定位是「尽力而为」：跳 index 会前移一页兜高图，误差一页以内，见 resumeOnOpen。
 * s16 第 2 条口径（竖向滚动「两图之间大片黑区」真机成因 = 未解码行按估算占位比撑出约 1.33 屏的
 *      纯黑容器，里面只有一枚 32vp 转圈；各源真实比不同，所以黑区长短随源变化）：
 *      甲 尺寸未知的未就绪行一律窄骨架固定高 SKELETON_H（再按 1/4 屏封顶），浅色圆角块加转圈，
 *         不再按任何估算比例撑行 —— 行高只允许两种口径：真实宽高比，或窄骨架固定高；
 *      乙 尺寸按「章节id 加 # 加 页码」登记（对齐上游 resolveStableSizeCacheIndex 的章序加页序，
 *         按 url 记会在换 CDN 域名或带签名参数时 miss），满一批淘汰；同页再次进组件按真比排行；
 *      丙 预取：进章节与每次换页时，对当前页「后 PREFETCH_AHEAD 行、前 PREFETCH_BEHIND 行」窗口内的
 *         地址调 ImageCache.loadPage（结果整个丢弃，只为让字节先进内存 LRU），在途地址跳过以免重复发；
 *         窗口按上游「2 屏」折算得出，推导见 PREFETCH_AHEAD 与 prefetchAround 两处注释；
 *      丁 失败行同窄骨架高 + 可见「点按重试」文案，首次失败自动补一次（双层限频，见 scheduleAutoRetry），
 *         手动重试走 AppStorage 信号（键 = 该行尺寸键，只有那一行自己响应），见 tapCenter。
 */

import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { Theme, Dim } from '../common/Theme';
import { SourceManager } from '../../data/source/SourceManager';
import { MangaSource } from '../../data/source/Source';
import { ImageCache } from '../../data/image/ImageCache';
import { MangaRepository } from '../../data/db/MangaRepository';
import { UserSettings, ReadScrollMode } from '../../util/UserSettings';
import { ChapterInfo, PageImage, ReadProgress } from '../../data/model/Models';

/**
 * 手动重试信号的 AppStorage 键（s16 第 2 条丁）。推给它的值 = 被要求重试那一行的「尺寸键加 @ 加 序号」，
 * 每个 ReaderPageImage 自己比前缀，只有那一行重取，其余行忽略这次广播。
 *
 * 为什么不用 @Prop 传令牌：LazyForEach 的行不重建时父组件的条目样条不会重跑，@Prop 的新值下发不到行内，
 * 用户点了没反应；本仓跨组件推送一律走「AppStorage 推一个新值 + 子组件 @StorageProp 加 @Watch」这条
 * 已验口径（现四例 readHistoryCount / searchHistoryCount / shelfRevision / historyRevision）。
 * 本仓 @StorageProp 全部写字面量、无常量入参的先例，所以下面装饰器里是字面量、这里是常量，
 * 两处必须同串 —— 自检探针有一条断言逐字比这两处。
 */
const READER_RETRY_KEY: string = 'readerRetryKey';

/**
 * 纵向档数据源（s13 第 6 条，全仓首例 LazyForEach）：把整章 url 列表交给 LazyForEach，
 * 由框架只实例化可见项与 cachedCount 范围内的邻居，滚远的项自动回收 —— 这是纵向档「跨页续加载」
 * 的实现前提：整章几百张位图不可能同时挂在内存里（ImageCache 的内存 LRU 只有 24 张，
 * 全靠这里不把整章一次性实例化才不会反复解码回吐）。
 *
 * 本类不做原地增删：换章节 = 换整个实例（见 loadPages 里 new WebtoonPageSource），
 * 所以只把监听器存下来（IDataSource 契约要求这两个方法存在，LazyForEach 绑定时会调 register），
 * 不实现 onDataReloaded 那组通知。将来若要「滚到底自动追加下一章」，再在这里补通知。
 */
class WebtoonPageSource implements IDataSource {
  private readonly urls: string[];
  /** LazyForEach 绑定时注册进来的监听器：本类不主动通知，存下来只为满足契约 */
  private listeners: DataChangeListener[] = [];

  constructor(urls: string[]) {
    this.urls = urls;
  }

  totalCount(): number {
    return this.urls.length;
  }

  getData(index: number): string {
    return this.urls[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const i: number = this.listeners.indexOf(listener);
    if (i >= 0) {
      this.listeners.splice(i, 1);
    }
  }
}

/**
 * s15 第 4 条（甲）与第 1 条的取证面。全部放在 struct 外的模块级导出类里，由 pages/Index.ets
 * 的诊断面板读取（本文件不自己上屏，屏上只多加一枚页码角标）。
 *
 * 为什么是「导出类的静态字段」而不是「模块级可变导出」：本仓所有诊断计数都是这个形态
 * （data/image/ImageCache.ets:539-663 与 :197-199 同形，全仓顶层可变导出 0 命中），
 * 沿用最稳的一条口径，不为省一个类名去试没验过的写法。
 *
 * 三条页计数刻意做成互斥可自洽的形式：load() 起笔记 pending，出结果时把同一笔从 pending
 * 挪到 shown/failed（见 movePage），所以 pageShown + pagePending + pageFailed
 * 恒等于「本文件当前活着的组件里，各自最后一笔状态的总数」。之所以不全局按 url 去重：
 * 全局表要按访问过的 url 无界长大（一章上千张），而按组件实例记账天然有界（活组件几十个）。
 * 残余偏差 = 同一 url 同时挂在两个组件实例上会各记一笔（横向档与纵向档互斥、
 * LazyForEach 回收换 url 时上一笔会摘掉，实测只在切档重建那一瞬可能出现）。
 */
export class ReaderDiag {
  /** 页记账状态：未记账 */
  static readonly K_NONE: number = 0;
  /** 页记账状态：已发起解码、还没出结果（屏上 = 占位态） */
  static readonly K_PENDING: number = 1;
  /** 页记账状态：成功上屏 */
  static readonly K_SHOWN: number = 2;
  /** 页记账状态：失败 */
  static readonly K_FAILED: number = 3;

  /** 仍停在占位态的页数（出结果会被挪走，所以这个数只在「真的还没到」时非零） */
  static pagePending: number = 0;
  /** 成功上屏的页数 */
  static pageShown: number = 0;
  /** 解码失败的页数 */
  static pageFailed: number = 0;
  /** 最后一次 aspect() 的口径：real 真比值 / placeholder-median 同章中位 / placeholder-const 回落常量 */
  static lastShownRatio: string = '';
  /** 最后一次成功解码的像素尺寸（宽x高）；没解出过 = 空串 */
  static lastShownSize: string = '';

  /** 最后一次章级失败的落点：五档 errorMsg 之一，catch 档附真因（s15 第 1 条） */
  static readerChapterErrLast: string = '';
  /** 章级失败次数：五档全计（含「该漫画暂无章节」「本章节没有图片」两档非异常） */
  static readerChapterErrCount: number = 0;
  /** fetchPages 成功返回且页表非空的次数 —— 与 readerChapterErrCount 互斥 */
  static readerPagesLoaded: number = 0;

  /** readerChapterErrLast 的截断长度（诊断面板每行有 cap，超了会被吞） */
  private static readonly ERR_LAST_MAX: number = 80;
  /** 每章最多留几个比例样本：够算中位数，又不让模块级 Map 无界长大 */
  private static readonly RATIO_SAMPLES: number = 12;
  /** 比例表最多留几章：阅读器退出后这些数据还留在进程里，必须有界 */
  private static readonly RATIO_CHAPTERS: number = 4;

  /** s15 第 4 条（乙）的落点：章节 id 到该章已解码页宽高比样本表 */
  private static readonly ratios: Map<string, number[]> = new Map<string, number[]>();
  /** ratios 的入表顺序（淘汰时移第 0 个）。刻意不用 Map.keys().next().value：那条拿到的值在
   *  ArkTS 严格模式下是 any 形态，本仓不靠 any 传值。 */
  private static readonly ratioOrder: string[] = [];

  /**
   * 把一笔页记账从 from 挪到 to 并返回 to（调用点直接存回自己的字段）。
   * from 与 to 相同时原样返回：LazyForEach 回收重挂、Swiper 节点复用都会重复调 load()，
   * 少了这一步同一 url 会被累加好几遍（派工书「同一 url 只计最终态一次」）。
   */
  static movePage(from: number, to: number): number {
    if (from === to) {
      return to;
    }
    if (from === ReaderDiag.K_PENDING) {
      ReaderDiag.pagePending -= 1;
    } else if (from === ReaderDiag.K_SHOWN) {
      ReaderDiag.pageShown -= 1;
    } else if (from === ReaderDiag.K_FAILED) {
      ReaderDiag.pageFailed -= 1;
    }
    if (to === ReaderDiag.K_PENDING) {
      ReaderDiag.pagePending += 1;
      // s16 第 2 条（丙）：每次进 pending 都刷一次峰值，peak 是进程生命周期量（口径同行 16）
      if (ReaderDiag.pagePending > ReaderDiag.pendingPeak) {
        ReaderDiag.pendingPeak = ReaderDiag.pagePending;
      }
    } else if (to === ReaderDiag.K_SHOWN) {
      ReaderDiag.pageShown += 1;
    } else if (to === ReaderDiag.K_FAILED) {
      ReaderDiag.pageFailed += 1;
    }
    return to;
  }

  /** 章级失败统一入口：屏上文案即取证文案，五档共用 */
  static noteChapterError(msg: string): void {
    ReaderDiag.readerChapterErrCount += 1;
    ReaderDiag.readerChapterErrLast =
      msg.length > ReaderDiag.ERR_LAST_MAX ? msg.substring(0, ReaderDiag.ERR_LAST_MAX) : msg;
  }

  /**
   * 解码成功后登记真实宽高比（s15 第 4 条乙）：同一章节后续未解码行的占位比就取这批样本的中位数。
   * 刻意不收录非正数（aspectRatio 给 0 或负数等于没设、行高会塌成 0，SDK common.d.ts:20548 口径）。
   */
  static rememberRatio(chapterId: string, ratio: number): void {
    if (chapterId.length === 0 || !(ratio > 0)) {
      return;
    }
    let arr: number[] | undefined = ReaderDiag.ratios.get(chapterId);
    if (arr === undefined) {
      // 新章节入表前先把最久的那章挤掉（入表序记在 ratioOrder 里），保持整表有界
      while (ReaderDiag.ratios.size >= ReaderDiag.RATIO_CHAPTERS && ReaderDiag.ratioOrder.length > 0) {
        const oldest: string = ReaderDiag.ratioOrder.shift() ?? '';
        if (oldest.length > 0) {
          ReaderDiag.ratios.delete(oldest);
        }
      }
      arr = [];
      ReaderDiag.ratios.set(chapterId, arr);
      ReaderDiag.ratioOrder.push(chapterId);
    }
    if (arr.length >= ReaderDiag.RATIO_SAMPLES) {
      return;
    }
    if (arr.length > 0 && arr[arr.length - 1] === ratio) {
      // 同一张图被反复测量（重挂、复用）不重复占样本位
      return;
    }
    arr.push(ratio);
  }

  /** 取该章样本中位数当占位比；没有样本（含 chapterId 为空）返回 0，让调用方回落到常量 */
  static medianRatio(chapterId: string): number {
    const arr: number[] | undefined = ReaderDiag.ratios.get(chapterId);
    if (arr === undefined || arr.length === 0) {
      return 0;
    }
    const sorted: number[] = arr.slice(0);
    sorted.sort((a: number, b: number): number => a - b);
    const mid: number = Math.floor(sorted.length / 2);
    if (sorted.length % 2 === 1) {
      return sorted[mid];
    }
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  /** s16 第 2 条（丙）：本进程见过的最大同时在途页数（movePage 里每进一笔 pending 刷新） */
  static pendingPeak: number = 0;
  /** s16 第 2 条（丁）：失败后自动补发的重试总次数（只算自动，用户点按不计） */
  static retryTotal: number = 0;
  /**
   * s16 第 2 条（乙）：本文件内「位图还没到手、但按尺寸键查到真比」因而直接按真比排行的次数。
   * 口径只在本文件内成立。它与诊断 16 号行的 hit=（ImageCache.pageCacheHits，取图字节命中磁盘缓存）
   * **不是同一个东西**，两者只是恰好都叫 hit（ACCEPT 已限定「按行取」，这里不再往那边靠）：
   * 这里数的是「行高不用再走窄骨架」，那边数的是「字节不用再走网络」。
   */
  static sizeHits: number = 0;
  /** s16 第 2 条（丙）：预取发起的取页次数（不与页组件记账重叠，专门用来和 16 号行 pageCalls 对账） */
  static prefetchTotal: number = 0;
  /**
   * s16 第 2 条（乙，lead 追加 D2）：**解码前**就量到真实比、并因此让首次布局直接落真高的行数。
   * 这是 D2 那条「行高不得从窄骨架跳到真实比」的直接证据计数 —— 它只在消费侧数得到：
   * ImageCache 那边只知道「预探了几次、读到几次字节」（16 号行 sz=命中/读字节/调用），
   * 不知道调用方是不是纵向档、那一行后来到底有没有按这个比例排。所以这里刻意只留一枚分子、
   * 不复述分母（两个文件各数一遍同一个分母 = 将来必然对不上，一个事实一个权威位置）。
   * 刻意只在纵向档发探针：横向档行高恒 height 100%，量了不参与布局 = 纯浪费一次文件读。
   */
  static sizeProbeHits: number = 0;

  /** s16 第 2 条（乙，按 lead 追加 C-乙 改按页记）：尺寸表条目上限（满了一批淘汰，仿 ImageCache 的有界 LRU） */
  private static readonly SIZE_KEY_MAX: number = 1024;
  /** 一批淘汰的条数：按入表顺序移前 1/4，摊薄淘汰开销 */
  private static readonly SIZE_KEY_EVICT: number = 256;

  /** s16 第 2 条（乙）落点：尺寸键（章节id 加 # 加 页码）到该页已解码的宽高比。
   *  键形态对齐上游 resolveStableSizeCacheIndex(chapterOrder, localPageIndex)（章序+章内页序）：
   *  按 url 记会在「同一页换 CDN 域名或带签名参数」时 miss，按页记不会。竖屏漫画 h>w，比例恒小于 1。 */
  private static readonly sizeRatios: Map<string, number> = new Map<string, number>();
  /** sizeRatios 的入表顺序（淘汰按它移最旧一批）。刻意不用 Map.keys() 迭代器：
   *  ArkTS 严格模式下那条拿到的值是 any 形态，本仓不靠 any 传值（口径同 ratioOrder）。 */
  private static readonly sizeKeyOrder: string[] = [];

  /**
   * 解码成功后按尺寸键登记真实宽高比（s16 第 2 条乙）：同一页再次进组件（LazyForEach 回收重挂、
   * 切档重建、翻回上一页）直接按真比排行，不再退骨架。上游同构 = ImageSizeCubit 按 index 缓存
   * （image_display.dart:125-140 解码后回写 + prefetch_image_sizes.dart 预探回写）。
   * 与 rememberRatio 同款有界纪律：映射是进程级的（跨章节、跨书活），必须有容量上限。
   */
  static rememberPageRatio(sizeKey: string, ratio: number): void {
    if (sizeKey.length === 0 || !(ratio > 0)) {
      return;
    }
    if (ReaderDiag.sizeRatios.has(sizeKey)) {
      return;
    }
    while (ReaderDiag.sizeRatios.size >= ReaderDiag.SIZE_KEY_MAX && ReaderDiag.sizeKeyOrder.length > 0) {
      for (let i = 0; i < ReaderDiag.SIZE_KEY_EVICT && ReaderDiag.sizeKeyOrder.length > 0; i++) {
        const oldest: string = ReaderDiag.sizeKeyOrder.shift() ?? '';
        if (oldest.length > 0) {
          ReaderDiag.sizeRatios.delete(oldest);
        }
      }
    }
    ReaderDiag.sizeRatios.set(sizeKey, ratio);
    ReaderDiag.sizeKeyOrder.push(sizeKey);
  }

  /** 按尺寸键取已知的真实宽高比；没见过返回 0，调用方回落窄骨架（绝不按估算比例撑行） */
  static pageRatio(sizeKey: string): number {
    const v: number | undefined = ReaderDiag.sizeRatios.get(sizeKey);
    if (v === undefined || !(v > 0)) {
      return 0;
    }
    return v;
  }

  /** 失败地址表容量上限：只用于「这一按该不该当重试」的判定，到量就不再新增，永不参与拦截 */
  private static readonly FAILED_MAX: number = 512;
  /**
   * 最后一次取图失败的地址（s16 第 2 条丁）。刻意做成「提示表」而不是负缓存：
   * 屏中热区要靠它区分「这一按是重试还是显隐顶栏」，某页成功一次就从表里摘掉，
   * 所以它不会拦住任何一次真实请求 —— 自动重试与手动重试都是直接再调 ImageCache.loadPage。
   * （ImageCache 侧的失败负缓存不属本文件写域；本文件也不自建，否则重试就发不出去了。）
   */
  private static readonly failedUrls: Set<string> = new Set<string>();

  /** 记一笔取图失败（空串不记：那是「没有地址」，不是「取回失败」） */
  static noteFailed(url: string): void {
    if (url.length === 0 || ReaderDiag.failedUrls.has(url)) {
      return;
    }
    if (ReaderDiag.failedUrls.size >= ReaderDiag.FAILED_MAX) {
      return;
    }
    ReaderDiag.failedUrls.add(url);
  }

  /** 该页成功过就摘掉：判据必须只反映「最后一次结果」，否则修好的页会被一直当成失败页 */
  static noteOk(url: string): void {
    if (url.length > 0) {
      ReaderDiag.failedUrls.delete(url);
    }
  }

  /** 该地址最后一次取图是不是失败（父组件的屏中热区判定用） */
  static isFailed(url: string): boolean {
    return url.length > 0 && ReaderDiag.failedUrls.has(url);
  }

  /** 在途表容量上限：只当「这一条别再重复发」的判重器，到量就不再登记（宁可多发的退化，不是错） */
  private static readonly IN_FLIGHT_MAX: number = 256;
  /**
   * 正在取（load 已发起、还没出结果）的地址。两个用途：
   * ① 预取跳过它 —— 否则「行组件正在取 + 预取又取同一条」会真的发两遍，把 16 号行的 pageCalls
   *   打成对不上账的数（ImageCache 侧的在途去重是 cache-fix 那条并行改的事，这里不越界改它）；
   * ② 只在 load() 的 try 前后一登一摘，摘在成功/失败/空 url 三条出口之前，不会漏（见 load 的 finally）。
   */
  private static readonly inFlight: Set<string> = new Set<string>();

  /** 登记在途（超上限就不登记：判重器退化成「少判几次」，绝不因此漏发请求） */
  static noteInFlight(url: string): void {
    if (url.length === 0 || ReaderDiag.inFlight.has(url)) {
      return;
    }
    if (ReaderDiag.inFlight.size >= ReaderDiag.IN_FLIGHT_MAX) {
      return;
    }
    ReaderDiag.inFlight.add(url);
  }

  /** 摘掉在途标记（load 的 finally 必调） */
  static noteNotInFlight(url: string): void {
    if (url.length > 0) {
      ReaderDiag.inFlight.delete(url);
    }
  }

  /** 该地址此刻是否在途（预取判重用） */
  static isInFlight(url: string): boolean {
    return url.length > 0 && ReaderDiag.inFlight.has(url);
  }

  /** 重试信号的自增尾巴：保证同一个键连点两次也是两个新值（同值不会触发 @Watch） */
  private static retrySeq: number = 0;

  /** 推一次手动重试信号：值 = 尺寸键 加 @ 加 自增序号；只有前缀匹配的那个行会响应 */
  static pushRetry(sizeKey: string): void {
    if (sizeKey.length === 0) {
      return;
    }
    ReaderDiag.retrySeq += 1;
    AppStorage.setOrCreate<string>(READER_RETRY_KEY, sizeKey + '@' + ReaderDiag.retrySeq);
  }

  /** 诊断面板用的一行文本（页） */


  static pageHint(): string {
    return 'shown=' + ReaderDiag.pageShown + ' pending=' + ReaderDiag.pagePending +
      ' failed=' + ReaderDiag.pageFailed + ' ratio=' + ReaderDiag.lastShownRatio +
      ' size=' + ReaderDiag.lastShownSize +
      // s16 第 2 条诊断四枚扩展位，判读口径见 _tmp/s16/ACCEPT.md 第五段（不在这里重复）：
      // peak = 同时在途峰值（对 pending）、retry = 自动补发次数（对 failed）、
      // hit = 本文件内按尺寸键取回真比的行数（对 shown，与 16 号行的 hit 不同义）、
      // pre = 预取发起的取页次数（16 号行 pageCalls 里混着「行组件取页」与「预取取页」两条来源，
      // 没有 pre 那两行对不上账：pageCalls 里属于本文件的部分 ≈ shown + failed + pending）；
      // probe = 解码前就量到真比的行数（分母在 16 号行 sz= 里，这里只给分子，见字段注释）。
      ' peak=' + ReaderDiag.pendingPeak + ' retry=' + ReaderDiag.retryTotal +
      ' hit=' + ReaderDiag.sizeHits + ' pre=' + ReaderDiag.prefetchTotal +
      ' probe=' + ReaderDiag.sizeProbeHits;
  }

  /** 诊断面板用的一行文本（章） */
  static chapterHint(): string {
    return 'pagesOk=' + ReaderDiag.readerPagesLoaded + ' errCount=' + ReaderDiag.readerChapterErrCount +
      ' last=' + ReaderDiag.readerChapterErrLast;
  }
}

/**
 * 行高的「页身份」（s16 第 2 条乙，按 lead 追加口径 D1 抽成模块级函数）：
 * 章节 id 加 # 加 章内页码，与上游 image_size_cubit.dart 的
 * resolveStableSizeCacheIndex(chapterOrder, localPageIndex) 同构（章序 加 章内页序）。
 *
 * 为什么必须共用一个函数而不是各自拼一遍串：这个键同时被两处拼 ——
 * ① ReaderPageImage.sizeKey()（读写尺寸表，决定行高）、② ReaderView.tapCenter()
 * （手动重试信号的键，行内按前缀认领）。两处字面量手抄迟早会因一次改动错位一次，
 * 而错位的表现是「点了重试没有任何一行响应」或「明明量到了真比、那一行却还是窄骨架」
 * 这种要拿诊断串一行行对的缺陷。收成一个函数后结构性不可能错位，自检探针只核这一处定义。
 * 页码非法（<= 0，父组件没传 pageNo 的调用点）返回空串：尺寸表与重试信号都按空串忽略，
 * 不会写进脏键，也不会把「第 0 页」当成一个真实存在的格子。
 * 按 url 记为什么不行（派工 C-乙）：同一页换 CDN 域名或带签名参数时键会变，真比 miss，
 * 于是每次都退回窄骨架，跳动又回来。
 */
function pageSizeKey(chapterId: string, pageNo: number): string {
  if (pageNo <= 0) {
    return '';
  }
  return chapterId + '#' + pageNo;
}

/** 比例写进诊断串时统一两位小数，避免同一比例打出两种长度把面板 cap 撑爆。 */
function fixed2(n: number): string {
  return n.toFixed(2);
}

/** 全角左括号：适配器把 chapterId 装在这段里，截掉它就同时去掉了用户浏览痕迹 */
const FULL_OPEN_PAREN: string = '（';

/** 能上屏的短句上限（超长按兜底处理，屏上不铺长串） */
const BRIEF_MAX: number = 40;

/**
 * s15 第 1 条 / 第 2 条共用的判据：把底层错误洗成「能给用户看的一句中文」，判不上就兜底。
 * 与 pages/PluginLoginPage.ets 里的同名函数同一口径（两份各留一份实现：跨文件共享要新增导出面，
 * 而两边调用点各只有本文件用得着；改判据时请同时改两处）。依据逐条：
 * 1) 空串 = 没有可用信息，直接兜底；
 * 2) 先砍掉全角左括号及其后面全部内容 —— data/source/PluginSourceAdapter.ets:375 与 :390
 *    那两条本来就是给人看的中文，但把 chapterId 塞在括号里，而 chapterId 可能含作品号
 *    （用户浏览痕迹），所以只留前半句；:159 的 action（fnPath）：+ 底层原文同理被截掉；
 * 3) 剩下的串里只要出现堆栈、URL、包路径、JSON 花括号/方括号、英文异常名任一形态就整体兜底
 *    （判据见 looksTechnical）；
 * 4) 都不命中才原样展示 —— 插件明确写给用户的中文提示（如「用户名或密码错误」）要留给用户。
 */
function briefForScreen(msg: string, fallback: string): string {
  if (typeof msg !== 'string') {
    return fallback;
  }
  let s: string = msg.trim();
  if (s.length === 0) {
    return fallback;
  }
  const cut: number = s.indexOf(FULL_OPEN_PAREN);
  if (cut > 0) {
    s = s.substring(0, cut).trim();
  }
  if (s.length === 0 || s.length > BRIEF_MAX) {
    return fallback;
  }
  if (looksTechnical(s)) {
    return fallback;
  }
  return s;
}

/** 技术细节形态判定：命中任一条就不该上屏（判据用码位比，源码里不写字面花括号，配平判据不受影响）。 */
function looksTechnical(s: string): boolean {
  if (s.indexOf('://') >= 0) {
    return true;
  }
  if (s.indexOf(' at ') >= 0 || s.indexOf('Error:') >= 0 || s.indexOf('error:') >= 0) {
    return true;
  }
  if (s.indexOf('@ohos.') >= 0 || s.indexOf('@hms.') >= 0 || s.indexOf('@kit.') >= 0) {
    return true;
  }
  const marks: string[] = ['.ets', '.ts', '.js', '.dart', '.so', '.json', '/data/', '/storage/'];
  for (let i = 0; i < marks.length; i++) {
    if (s.indexOf(marks[i]) >= 0) {
      return true;
    }
  }
  const BACKSLASH: number = 92;
  const SQ_OPEN: number = 91;
  const SQ_CLOSE: number = 93;
  const CU_OPEN: number = 123;
  const CU_CLOSE: number = 125;
  let cjk: number = 0;
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c === BACKSLASH || c === SQ_OPEN || c === SQ_CLOSE || c === CU_OPEN || c === CU_CLOSE) {
      return true;
    }
    if (c >= 0x4E00 && c <= 0x9FFF) {
      cjk += 1;
    }
  }
  // 一个中日韩汉字都没有 = 英文异常名 / 裸 code / 纯英文堆栈行，一律不上屏
  if (cjk === 0) {
    return true;
  }
  if (s.indexOf('Exception') >= 0 || s.indexOf('Traceback') >= 0) {
    return true;
  }
  return false;
}

/** 单页图片：自己按 url 从 ImageCache 取 PixelMap（懒加载，Swiper 只实例化可见页） */
@Component
struct ReaderPageImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  /** 图源 id（空 = 未知，走宿主 HTTP；插件图源才走插件取图 + 反混淆意图）。 */
  @Prop sourceId: string = '';
  /**
   * s13 第 6 条：纵向档专用。true = 容器按图片真实宽高比定高（图多高行多高，一张接一张，
   * 中间不留一屏高的空白）；默认 false = 现役横向档的「一页一屏铺满」。两档共用本组件、
   * 只靠这一个开关分形，是为了让解码、失败态、串图修复（onUrlChanged）只有一份实现。
   */
  @Prop fitHeight: boolean = false;
  /** 章节 id（JM 分块数按章节号推导，必须传）。 */
  @Prop chapterId: string = '';
  /**
   * 页码（1 起，调用方传 index+1；<=0 = 不传则不渲染角标）。s15 第 4 条（甲）：占位态与失败态
   * 在左上角显示 P+页码，用户回传截图时我们能直接从图上读出「第几页、什么状态」，
   * 不必再靠猜。成功态不显示（图满了没处放，也没必要）。
   */
  @Prop pageNo: number = -1;
  /**
   * 阅读区可视高度（vp）：由父组件的 onAreaChange 实测后传下来，只用来给窄骨架封顶
   * （判据「未取到位图的格子 <= 1/4 屏」按真机屏高算，不写死设备常量）。
   * 与 BUG6 那条「实测尺寸反哺自身布局」无冲突：这是父容器高喂子行高，行高变不回灌父高。
   */
  @Prop viewportH: number = 0;
  /**
   * 手动重试信号（s16 第 2 条丁）：屏中热区落在「最后一次取图失败」的当前页时，父组件 tapCenter
   * 把「本页尺寸键加 @ 加 自增序号」推进 READER_RETRY_KEY；本组件只在信号前缀是自己尺寸键时清态重取。
   * 尾巴带序号 = 同一个键连点两次也是两个新值，否则第二次推送值不变、@Watch 不触发（点了没反应）。
   * 刻意不在本组件内挂 onClick：行内最上层是 TapZonesBody（三个透明热区占满整行），
   * 子组件的点按会被它整个吃掉，所以可见文案「点按重试」画在本组件、事件入口在父组件的热区。
   * 键名与模块级 READER_RETRY_KEY 同串（装饰器入参本仓只用字面量，探针有断言核这两处一致）。
   */
  @StorageProp('readerRetryKey') @Watch('onRetrySignal') retrySignal: string = '';
  @State pm: image.PixelMap | undefined = undefined;
  @State failed: boolean = false;
  /**
   * 解码前量到的真实宽高比（s16 第 2 条乙，lead 追加 D2）。必须做成 @State 而不是只写进尺寸表：
   * 探针回来时位图还没解码，若行高只读那张静态表，表变了 build 也不会重跑，
   * 行会一直停在窄骨架直到解码完成 —— 等于「首次布局仍是估高」，跳动一点没少。
   * 换 url 与重试信号两处复位（否则 Swiper/LazyForEach 复用节点会把上一页的比例带到下一页）。
   */
  @State preRatio: number = 0;
  /** 页计数的本组件台账：记的是哪个 url、当前算在哪一档（见 mark） */
  private tallyUrl: string = '';
  private tallyKind: number = ReaderDiag.K_NONE;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    // s16 第 2 条（丁）：自动重试挂在延迟窗上，节点销毁后回调仍会跑并改已销毁组件的状态
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /** Swiper 会复用节点，url 变更必须重新解码，否则翻页出现上一张图（串图） */
  onUrlChanged(): void {
    this.clearRetryTimer();
    this.autoRetried = false;
    this.pm = undefined;
    this.failed = false;
    this.preRatio = 0;
    this.load();
  }

  /**
   * 重试信号进来：只有信号前缀是本页尺寸键才动手（一次广播会叫醒所有活着的行，绝大多数要自己忽略）。
   * 前缀比的是「尺寸键加 @」，@ 是分隔符，不会有别的行误命中（页 1 的键 ch#1 加 @ 撞不上 ch#11）。
   * 刻意不重置 autoRetried —— 「自动补一次」是每页每挂载一次的上限，
   * 用户点按的手动重试既不计入也不解锁第二次自动补发（否则坏网下会被连点成请求风暴）。
   */
  onRetrySignal(): void {
    if (this.retrySignal.indexOf(this.sizeKey() + '@') !== 0) {
      return;
    }
    this.clearRetryTimer();
    this.pm = undefined;
    this.failed = false;
    this.preRatio = 0;
    this.load();
  }

  /**
   * 兜底宽高比 1/1.2 = 0.8333（s16 第 2 条，lead 追加 C-甲：与上游
   * image_size_cubit.dart:78 defaultHeight = defaultWidth * 1.2 对齐，替掉原先的 0.75）。
   * 现役只剩一条路径会读到它：位图已到手但 getImageInfoSync 抛异常/尺寸非法（真机极罕见）。
   * 「尺寸未知的未就绪行」不再用它撑高 —— 那种行走 SKELETON_H 的窄骨架分支（见 build 与戊条自洽说明）。
   */
  static readonly PLACEHOLDER_RATIO: number = 1 / 1.2;
  /**
   * 窄骨架行高（vp，s16 第 2 条甲/丁）：尺寸未知或已失败的行一律这个高，不再按任何比例撑
   * 一屏（旧值 0.75 = 宽/0.75 约 1.33 屏，就是「两图之间大片黑色填充」的成因）。
   * 再按 viewportH/4 封顶，保证「未取到位图的格子」不超过 1/4 屏。
   */
  static readonly SKELETON_H: number = 168;
  /** 骨架条本身的高（vp）：横向档一屏一行、纵向档已知真比的行都可能很高，骨架只画一条居中的浅色块 */
  static readonly SKELETON_BLOCK_H: number = 120;
  /** 首次失败后自动补一次的基础延迟（ms） */
  private static readonly RETRY_DELAY_MS: number = 1200;
  /** 进程级最小间隔（ms）：整章同时失败时（真机 pfail=27 那种）别在同一帧打一轮重试请求 */
  private static readonly RETRY_MIN_GAP_MS: number = 400;
  /** 上一次自动补发的排期时刻（进程级节流用）；0 = 从未发过 */
  private static retryClock: number = 0;
  /** 本页本次挂载是否已自动补发过（换 url 会复位） */
  private autoRetried: boolean = false;
  /** 自动补发的延迟计时器；-1 = 空闲 */
  private retryTimer: number = -1;

  /**
   * 纵向档行高口径（s16 第 2 条改写；装机判据 = 屏上任何「没取到位图的格子」高度不超过 1/4 屏）。
   * 只有两种口径，没有第三种：
   * 真比（返回正数）：位图在手就量它（pm.getImageInfoSync()，仓内先例 = data/image/JmDeobfuscate.ets:218），
   *   并把「尺寸键」与「同章样本」两处都登记；位图不在手但 乙 表里这一页登记过，直接复用那个真比；
   * 尺寸未知（返回 0 = 哨兵「本行不用比例」）：build 走 skeletonHeight() 的固定窄高。
   * 旧口径在这里返回「同章中位数或 0.75 常量」，未解码行因此按约 1.33 屏排高、行内又是纯黑底，
   * 滚动时行高来回变 = 用户报的「两图之间大片黑色填充」；各源真实比不同所以黑区长短也不同（同一配方指纹）。
   * 兜底比 PLACEHOLDER_RATIO 只剩一条路径可达：位图已到手但量不到尺寸（真机极罕见）。那时行内是有图的
   * （不是黑洞），按 1/1.2 排行加图在里面 Contain，最多留细边，不会拉伸变形。
   * 戊（objectFit）自洽说明：本行有图时行高恒等于真实等比高，Fill 与 Contain 等价，留 Contain 更保险
   * （万一行高算错只是留细边，不是拉伸变形）；尺寸未知期不再撑行，黑边由甲的窄骨架兜住 —— 于是
   * 「估算比 + Contain + 0.75 占位」三件同时存在这个真机配方被拆掉了（估算比已不存在）。
   */
  private aspect(): number {
    if (this.pm === undefined) {
      // 第一优先 = 解码探针量到的真比（load() 里 probeSize() 写进来的）。
      // 它的意义是「位图还没解码、行高已经是对的」：磁盘已命中的页首次布局就是真高，
      // 不再从 168 长到真实比 = lead 追加 D2 要治的那个「行高从窄骨架猛涨到 1.4 屏」的跳动。
      // 刻意不计 sizeHits：那枚统计的是「重挂时命中此前登记过的尺寸」，与探针命中是两件事，
      // 混在一起会让 17 号行 hit= 失去意义（探针命中另有 probe=命中/发起 一档）。
      if (this.preRatio > 0) {
        ReaderDiag.lastShownRatio = 'probe ' + fixed2(this.preRatio);
        return this.preRatio;
      }
      const known: number = ReaderDiag.pageRatio(this.sizeKey());
      if (known > 0) {
        // 乙 命中：这一页以前解出来或量到过（LazyForEach 回收重挂、切档重建、翻回上一页），按真比排行
        ReaderDiag.sizeHits += 1;
        ReaderDiag.lastShownRatio = 'size-key ' + fixed2(known);
        return known;
      }
      ReaderDiag.lastShownRatio = 'skeleton';
      return 0;
    }
    try {
      const info: image.ImageInfo = this.pm.getImageInfoSync();
      const w: number = info.size.width;
      const h: number = info.size.height;
      if (w > 0 && h > 0) {
        const r: number = w / h;
        ReaderDiag.rememberRatio(this.chapterId, r);
        ReaderDiag.rememberPageRatio(this.sizeKey(), r);
        ReaderDiag.lastShownRatio = 'real ' + fixed2(r);
        ReaderDiag.lastShownSize = w + 'x' + h;
        return r;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[Reader] getImageInfoSync failed: code=${e.code} msg=${e.message}`);
    }
    // 位图在手但量不到尺寸（极罕见）：同章中位数优先，没样本才用 1/1.2 —— 两者都比旧的 0.75 矮
    const med: number = ReaderDiag.medianRatio(this.chapterId);
    const use: number = med > 0 ? med : ReaderPageImage.PLACEHOLDER_RATIO;
    ReaderDiag.lastShownRatio = (med > 0 ? 'placeholder-median ' : 'placeholder-const ') + fixed2(use);
    return use;
  }

  /**
   * 尺寸键（乙）：直接转调模块级 pageSizeKey（与父组件 tapCenter 共用同一处定义，见那边的注释）。
   */
  private sizeKey(): string {
    return pageSizeKey(this.chapterId, this.pageNo);
  }

  /**
   * 本行走「按真比排高」还是走「窄骨架高」的判据。刻意不计数、不改状态，
   * 好让 build 里 height 与 aspectRatio 各问一次而不会把 sizeHits 加两遍
   * （aspect 里唯一会自增的就是尺寸表那一档，探针档与骨架档都不计数）。
   * 判据顺序 = pm、failed、preRatio（解码探针量到的真比）、尺寸表，四档里任一命中即「真比档」。
   * failed 必须排在 preRatio 与尺寸表之前（丁）：曾经成功过、后来某一轮取图失败的那一行，
   * 它的真比可能同时存在于探针结果与尺寸表里 —— 若先查那两处，失败行会继续按真实比排到一整屏高，
   * 「失败行不得占一屏」与「屏上未取到位图的格子 <= 1/4 屏」两条判据同时被破。
   * 所以失败一律退回窄骨架（骨架里带「点按画面中部可重试」文案）。
   */
  private ratioKnown(): boolean {
    if (this.pm !== undefined) {
      return true;
    }
    if (this.failed) {
      return false;
    }
    if (this.preRatio > 0) {
      return true;
    }
    return ReaderDiag.pageRatio(this.sizeKey()) > 0;
  }

  /** 窄骨架高：常量与「1/4 屏」取小；viewportH 还没量到时用常量本身（168vp 已小于真机 1/4 屏 203vp） */
  private skeletonHeight(): number {
    if (this.viewportH > 0 && this.viewportH / 4 < ReaderPageImage.SKELETON_H) {
      return this.viewportH / 4;
    }
    return ReaderPageImage.SKELETON_H;
  }

  /** 摘掉自动重试的延迟窗（换 url、重试信号进来、节点销毁三处都要摘） */
  private clearRetryTimer(): void {
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
  }

  /**
   * 首次失败自动补一次（丁），两层限频：
   * 一、本页本次挂载只补一次（autoRetried，换 url 才复位）；
   * 二、进程级排队（retryClock）：真机 pfail=27 那种「整章一起失败」，几十个格子同一帧各自补发
   *     就是第二轮风暴，所以补发时刻全局串成一条队，两次之间至少隔 RETRY_MIN_GAP_MS。
   * 直接再调 ImageCache.loadPage：本文件那张 failedUrls 表只做热区判定、不参与拦截，
   * ImageCache 侧目前也没有失败负缓存（在途去重是 cache-fix 那条并行改的事），重试必须真发得出去。
   */
  private scheduleAutoRetry(): void {
    if (this.autoRetried) {
      return;
    }
    this.autoRetried = true;
    const now: number = Date.now();
    const base: number = now > ReaderPageImage.retryClock ? now : ReaderPageImage.retryClock;
    const at: number = base + ReaderPageImage.RETRY_DELAY_MS;
    ReaderPageImage.retryClock = at + ReaderPageImage.RETRY_MIN_GAP_MS;
    this.retryTimer = setTimeout((): void => {
      this.retryTimer = -1;
      ReaderDiag.retryTotal += 1;
      this.failed = false;
      this.load();
    }, at - now);
  }

  /**
   * 解码前量尺寸（s16 第 2 条乙，lead 追加 D2 的正解）：字节到手、**解码之前**读出宽高比，
   * 让这一行的首次布局就是真高。执行体在 ImageCache.loadSize（该文件写域归 lead，2026-11-13 授权
   * 分工：他落 loadSize、我只调用）= 复用 loadPage 那一份缓存键与在途表，字节来自磁盘已命中的缓存文件
   * 时 createImageSource 加 getImageInfoSync 读文件头、finally 里 release，不缓存 PixelMap，取不到返 0。
   *
   * 为什么非要在解码前量（而不是等 pm 到手在 aspect 里量）：尺寸未知的行按甲的窄骨架 168 排高，
   * 真机竖页比约 0.71 ⇒ 解码完成那一帧行高从 168 猛涨到约 1.4 屏 = 可见跳动加滚动位置漂移。
   * 上游为躲这个专门写了 method/prefetch_image_sizes.dart（只读已落盘图片的文件头填尺寸），
   * cubit/image_size_cubit.dart:78 的注释原话就是「解析出真实尺寸后高度突变会造成可见的布局跳动」。
   * 所以这里同样是**零新增网络**：只问「磁盘已命中的那份字节」，未命中直接返 0 走窄骨架，
   * 取字节的网络活留给随后的 loadPage 一次做完（探针多发一轮网络 = 每张页图两次请求，不值当）。
   *
   * 四条闸门：① 只在 fitHeight（纵向档）发 —— 横向档行高恒 height 100%，量了不参与布局是纯浪费；
   * ② 已知尺寸不发（探针结果或尺寸表任一有值就跳过，重复问 = 白读一次文件）；
   * ③ isReady() 为假不发（缓存目录没就绪时它只能返 0，白跑一趟）；
   * ④ 整个 catch 掉：探针是**优化项不是功能**，它失败绝不能把这一行判成取图失败（真正上屏只由
   *    下面的 loadPage 决定）。写 preRatio 前先复查 url 没变（复用节点的探针晚到不该污染新页）。
   */
  private async probeSize(): Promise<void> {
    if (!this.fitHeight || this.url.length === 0) {
      return;
    }
    const key: string = this.sizeKey();
    if (key.length === 0 || this.preRatio > 0 || ReaderDiag.pageRatio(key) > 0) {
      return;
    }
    if (!ImageCache.getInstance().isReady()) {
      return;
    }
    const probeUrl: string = this.url;
    try {
      const r: number = await ImageCache.getInstance().loadSize(probeUrl, this.sourceId, this.chapterId);
      if (!(r > 0)) {
        return;
      }
      ReaderDiag.sizeProbeHits += 1;
      // 探针量到的也是「这一页的真实宽高比」，与解码后量到的同性质，一并登记进尺寸表：
      // 于是本页之后任何一次重挂（回收、切档、翻回来）都能不走解码就按真比排行。
      // 登记走 rememberPageRatio 的首次为准语义，解码后 pm 再量一次同值也不会打架。
      ReaderDiag.rememberPageRatio(key, r);
      if (this.url === probeUrl) {
        this.preRatio = r;
      }
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[Reader] size probe failed: code=${e.code} msg=${e.message}`);
    }
  }

  async load(): Promise<void> {
    this.mark(ReaderDiag.K_PENDING);
    if (this.url.length === 0) {
      this.failed = true;
      this.mark(ReaderDiag.K_FAILED);
      return;
    }
    // 在途标记必须在探针**之前**登记：探针自己是一次 await（读文件加解文件头，毫秒级但不是零），
    // 若照旧在探针之后才登记，这段空隙里 prefetchAround 的 isInFlight 判重会看不见这一条，
    // 于是同一次翻页里预取会再发一条同样的 loadPage —— 正是预取注释里承诺要避免的重复请求。
    // 摘除仍在下面的 finally，三条出口（成功/失败/探针后早退）都不会漏。
    ReaderDiag.noteInFlight(this.url);
    try {
      // 先量尺寸再取位图（顺序不能倒：倒了就是「首次布局按估高、解码完才跳」的旧链路）。
      // 探针自身把异常全吞了（见 probeSize 第 ④ 条闸门），放不进 catch 也不会把行判成取图失败。
      await this.probeSize();
      const map: image.PixelMap = await ImageCache.getInstance()
        .loadPage(this.url, this.sourceId, this.chapterId);
      this.pm = map;
      ReaderDiag.noteOk(this.url);
      this.mark(ReaderDiag.K_SHOWN);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Reader] decode failed: code=${e.code} msg=${e.message}`);
      this.failed = true;
      ReaderDiag.noteFailed(this.url);
      this.mark(ReaderDiag.K_FAILED);
      // 丁 首次失败自动补一次（限频见 scheduleAutoRetry）：真机 pfail=27 里相当一部分是单帧并发把
      // 图源打爆的瞬时失败，用户什么都没做也只是慢，不该让他一格一格点
      this.scheduleAutoRetry();
    } finally {
      // 登记点在上面（探针之前），摘点放 finally：探针、取图、解码任一环节抛出都照样摘掉，
      // 不会留下永挂在途的地址把后续预取永久挡掉。空 url 那条早退在登记之前，本来就没登记过。
      ReaderDiag.noteNotInFlight(this.url);
    }
  }

  /**
   * 把本页的记账挪到 to 档。换 url（Swiper 复用节点、LazyForEach 回收重挂）时先把上一笔
   * 摘掉再重新起笔，否则被复用掉的节点会留下一笔永远不结的 pending，三个数就再也对不上了。
   */
  private mark(to: number): void {
    if (this.tallyUrl !== this.url) {
      this.tallyKind = ReaderDiag.movePage(this.tallyKind, ReaderDiag.K_NONE);
      this.tallyUrl = this.url;
    }
    this.tallyKind = ReaderDiag.movePage(this.tallyKind, to);
  }

  build() {
    if (this.fitHeight) {
      if (this.ratioKnown()) {
        // 有真比（位图在手，或 乙 表登记过这一页）：aspectRatio 挂在**容器**上（不是 Image 上）。
        // SDK common.d.ts:20536 明确「width、height、aspectRatio 三者全设时显式 height 被忽略」，
        // 所以这个比例必须与内部 Image 的 height('100%') 分家：容器定高、图在里面 Contain，互不覆盖。
        Stack({ alignContent: Alignment.Center }) {
          this.Body()
          this.PageBadge()
        }
        .width('100%')
        .aspectRatio(this.aspect())
      } else {
        // 甲 窄骨架行（尺寸未知 = 位图没到且这一页没登记过尺寸）：固定窄高，**不走 aspectRatio**。
        // 旧口径在这里也走 aspectRatio，值取「同章中位数或 0.75」，于是未解码行按约 1.33 屏排高，
        // 行内纯黑底加一枚 32vp 转圈 = 用户报的「两图之间大片黑色填充」（判据：<= 1/4 屏）。
        // 这里 Body() 渲染的就是骨架（pm 为 undefined 那条分支），两档共用一份 Body 不复制样条。
        Stack({ alignContent: Alignment.Center }) {
          this.Body()
          this.PageBadge()
        }
        .width('100%')
        .height(this.skeletonHeight())
      }
    } else {
      // 横向档（现役语义不动）：一页一屏，图在屏内 Contain 居中；高度语义保持 height('100%')。
      Stack({ alignContent: Alignment.Center }) {
        this.Body()
        this.PageBadge()
      }
      .width('100%')
      .height('100%')
    }
  }

  /** 三种显示态（成功图 / 失败 / 加载中）两档共用，只有外层尺寸口径不同 */
  @Builder
  Body() {
    if (this.pm !== undefined) {
      Image(this.pm)
        .width('100%')
        .height('100%')
        // 戊：行高在纵向档恒等于真实等比高（有真比才走 aspectRatio，见上面 build），Fill 与 Contain
        // 等价，留 Contain 更保险 —— 万一某次行高算错只是上下留细边，不会出现拉伸变形
        .objectFit(ImageFit.Contain)
        .draggable(false)
    } else {
      // 没位图：浅色骨架块（加载中）或骨架块加「点按重试」文案（失败）。
      // 「点按重试」的可见文案画在这里，事件入口在父组件的屏中热区（tapCenter）——
      // 行内最上层是 TapZonesBody（三个透明热区占满整行），本组件挂的 onClick 轮不到。
      this.Skeleton()
    }
  }

  /**
   * 未就绪/失败行的可见骨架（s16 第 2 条甲与丁）：圆角浅色块 + 居中内容，不再是一整块纯黑。
   * 底色口径：阅读区根容器恒 Theme.black（见 ReaderView.build 的 backgroundColor，不随深浅色档变），
   * 所以这里固定取深色档令牌 Theme.dCard 铺底 + Theme.dDivider 描边 —— 两块令牌在纯黑上都能看出边界，
   * 「必须在深色下也看得见」这条判据因此与系统深浅色无关，恒成立。
   */
  @Builder
  Skeleton() {
    Column() {
      if (this.failed) {
        Text('图片加载失败')
          .fontSize(13)
          .fontColor(Theme.dTextPrimary)
          .maxLines(1)
        Text('点按画面中部可重试')
          .fontSize(12)
          .fontColor(Theme.brand)
          .maxLines(1)
          .margin({ top: 6 })
      } else {
        LoadingProgress()
          .width(28)
          .height(28)
          .color(Theme.dTextSecondary)
      }
    }
    .width('92%')
    .height(ReaderPageImage.SKELETON_BLOCK_H)
    .borderRadius(Dim.radius)
    .backgroundColor(Theme.dCard)
    .border({ width: 1, color: Theme.dDivider, radius: Dim.radius })
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 页码角标（s15 第 4 条甲）：只在占位态/失败态出现，成功态让位给整幅图。
   * 形如 P12，走 Theme.dTextSecondary（阅读区底色恒 Theme.black，深色次要文字在纯黑上实测
   * 6.00:1，够看清又不抢图）。用 position 挂在容器左上角，不占布局、不影响 aspectRatio 行高。
   */
  @Builder
  PageBadge() {
    if (this.pageNo > 0 && this.pm === undefined) {
      Text('P' + this.pageNo)
        .fontSize(11)
        .fontColor(Theme.dTextSecondary)
        .maxLines(1)
        .position({ x: 8, y: 8 })
    }
  }
}

@Component
export struct ReaderView {
  /** 漫画 id（必填） */
  @Prop mangaId: string = '';
  /** 图源 id（必填） */
  @Prop sourceId: string = '';
  /** 漫画标题（顶栏展示） */
  @Prop title: string = '';
  /** 指定章节 id，空则取第一章 */
  @Prop chapterId: string = '';

  @StorageProp('topSafeHeight') topSafe: number = 0;
  /**
   * 阅读模式的响应式副本（s13 第 6 条）：初值在 aboutToAppear 从偏好灌进 AppStorage，
   * 之后只由「更多页选项」或本文件的 applyScrollMode 改写 ⇒ 阅读器还活着时改档也能立刻翻档。
   */
  @StorageProp('readerScrollMode') @Watch('onScrollModeStorage') scrollMode: string = ReadScrollMode.PAGER;
  @State urls: string[] = [];
  @State pageIndex: number = 0;
  @State chapterName: string = '';
  /** 实际打开的章节 id（用于落库进度；入参 chapterId 为空时取首章） */
  @State currentChapterId: string = '';
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State chromeVisible: boolean = true;
  @State zoomScale: number = 1;
  @State baseZoomScale: number = 1;
  /** 放大后的平移量（vp）：只有 zoomScale>1 时非零，翻页/重进章节都归零 */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 阅读区实际尺寸（平移钳位与步长都按它算，onAreaChange 提供） */
  @State areaW: number = 0;
  @State areaH: number = 0;
  /** 进页时读一次：rtl 方向 + 放大后点按是否平移 */
  @State rtl: boolean = false;
  @State tapPans: boolean = false;
  /**
   * 纵向档数据源。刻意**不是** @State：它自己不是可观察数组，交给 LazyForEach 后由框架按
   * totalCount 取数；换章节时整体换成新实例，@State urls 负责触发 this.build() 重算即可。
   */
  private webtoonSource: WebtoonPageSource = new WebtoonPageSource([]);
  /** 纵向档滚动容器（List 用对象参数绑它，见 WebtoonArea 注释） */
  private webtoonScroller: Scroller = new Scroller();
  /**
   * 纵向档 List 的首项下标（ListOptions.initialIndex，@since 7）。只在三处被赋值：
   * 进章节读档、切档交接、点按重试后重载 —— 滚动本身绝不写它，否则每次 onScrollIndex
   * 触发重渲染都会把列表拽回那一页（ArkUI 是细粒度更新，表达式引用的变量没变就不重下发）。
   */
  @State webtoonStartIndex: number = 0;
  /** 待执行的定位目标；-1 = 无。List 挂载（onAppear，此时布局已就绪）时消费一次，不重复生效 */
  private pendingJumpIndex: number = -1;
  /** 纵向档落库节流计时器；-1 = 空闲 */
  private webtoonSaveTimer: number = -1;

  private swiperController: SwiperController = new SwiperController();
  /** 放大判定的死区：缩放回到 1 附近就恢复「点按翻页」，别留 1.0000001 的尾巴 */
  private static readonly ZOOM_EPS: number = 0.02;
  /** 纵向档落库节流窗口：一屏滚到底最多写一次库 */
  private static readonly WEBTOON_SAVE_DEBOUNCE_MS: number = 800;
  /** 纵向档点按一侧的滚动距离 = 视口高的 80%（留 20% 当上下文，避免整屏替换看不出衔接） */
  private static readonly WEBTOON_PAGE_STEP_RATIO: number = 0.8;
  /**
   * 预取窗口（s16 第 2 条丙，按上游「预取量 = 2 屏」折算，不是拍脑袋的 N 页）：
   * 参考机阅读区 377 x 814 vp（截图 1320x2848 除以 density 3.5）；一行的高 = 宽 / 宽高比，
   * 尺寸未知期按甲的 1/1.2 = 0.8333 估一行约 452vp，按 pic 源实测竖页比 0.6783 估一行约 556vp，
   * 于是 2 屏 = 1,628vp ≈ 2.9 到 3.6 行。上游那 2 屏是「前 1 屏加后 1 屏」，而阅读只朝一个方向走，
   * 所以把这 2 屏整个挪到前方 = 3 到 4 行，取上限再加一档余量凑成 6 行（约 2.7 屏）；
   * 后方只留 2 行（翻回去时行通常还 cachedCount 里挂着，不必再预取）。
   * 上限的余量是给「行还没被框架创建就先让字节进内存」留的时间差 —— 预取的意义就在于此。
   */
  private static readonly PREFETCH_AHEAD: number = 6;
  private static readonly PREFETCH_BEHIND: number = 2;
  /**
   * LazyForEach 的 cachedCount（s16 第 2 条丙同一折算口径，取代原先的 3）：
   * 按上面一行 452 到 556 vp 折，4 行一侧 ≈ 1.8 到 2.2 屏，与上游 2 屏缓存量级一致，
   * 两侧合计约 4 屏；活组件数 = 可见 2 行加两侧各 4 = 约 10 个，位图数仍在 ImageCache
   * 的内存 LRU（MAX_PAGE_MEM 24 张，data/image/ImageCache.ets:38）之内，不会把整章位图顶出来反复解码。
   * 刻意不上两位数：每个 cached 行就是一张竖页位图，堆到 8 以上会挤爆那 24 张的额度。
   */
  private static readonly WEBTOON_CACHED_COUNT: number = 4;

  aboutToAppear(): void {
    this.rtl = UserSettings.isRtl();
    this.tapPans = UserSettings.tapToScroll();
    // 先把偏好里的档位灌进 AppStorage 再读：@StorageProp 的初值取的就是那个键，
    // 灌晚了首帧会闪一下默认档（冷启动阅读器时最容易看到）
    const mode: string = UserSettings.readScrollMode();
    UserSettings.pushScrollMode(mode);
    this.scrollMode = mode;
    this.loadPages();
  }

  aboutToDisappear(): void {
    // 退出阅读器：取消未落地的节流落库，并补写一次当前页
    // （旧版没有这次补写，纵向档「滚到一半直接退出」会把最后不到 800ms 的进度丢掉）
    if (this.webtoonSaveTimer >= 0) {
      clearTimeout(this.webtoonSaveTimer);
      this.webtoonSaveTimer = -1;
    }
    this.saveProgress();
  }

  /** 是否纵向档：build 的分支、手势、点按热区、页码都只看这一个判定 */
  private isWebtoon(): boolean {
    return this.scrollMode === ReadScrollMode.WEBTOON;
  }

  /** 档位版本号变化（更多页选完推过来）：阅读器还在路由栈里时靠它即时翻档 */
  private onScrollModeStorage(): void {
    this.applyScrollMode(this.scrollMode);
  }

  /**
   * 切档唯一入口（要求 4「互切即时生效」的实现点）。
   * 两档互切都是**整棵子树重建**，不是一次属性变更：横向档用 ForEach 铺满整章、
   * 纵向档用 LazyForEach 按需取数，两者不能同时挂在树上（同时挂 = 整章位图全解码，
   * 直接顶穿 ImageCache 的 24 张内存上限）。因此「即时」的实现方式是：
   * 切档前把当前页留在 this.pageIndex（两档共用的页码权威），重建后各档自己贴到该页：
   * 横向档靠 .index(this.pageIndex)（重建即到位，不需要命令）；纵向档靠 ListItem 的
   * .onAppear 调 jumpToIndex（此刻布局已完成，scrollToIndex 才有效；见 WebtoonArea 注释）。
   * 验证边界见交卷说明：静态与离线桩能验到「页码交接 + 重建顺序 + 定位目标算法」，
   * 真机上列表贴到第几行还需一次装机确认。
   */
  private applyScrollMode(mode: string): void {
    const next: string = mode === ReadScrollMode.WEBTOON ? ReadScrollMode.WEBTOON : ReadScrollMode.PAGER;
    if (next === this.scrollMode) {
      return;
    }
    if (next === ReadScrollMode.WEBTOON) {
      // 缩放与平移只在横向档有意义，切走前先归位，否则切回来还是歪的
      this.zoomScale = 1;
      this.baseZoomScale = 1;
      this.offsetX = 0;
      this.offsetY = 0;
    }
    // setScrollMode 第一步就同步推 AppStorage 副本（界面立刻跟手），第二步才异步落库；
    // 这里再把本地 @State 也置上，是因为 @Watch 由 @StorageProp 触发，同帧内先手动置一次
    // 更稳（避免依赖 watch 与本地赋值的先后顺序）
    this.scrollMode = next;
    UserSettings.setScrollMode(next).catch((e: Object): void => {
      console.error('[Reader] persist scroll mode failed: ' + String(e));
    });
    // 页码交接给新档：横向靠 .index、纵向靠 onAppear 里那次 jumpToIndex
    this.jumpToIndex(this.pageIndex);
    this.saveProgress();
  }


  /**
   * 让纵向档定位到指定页（要求 3 的定位实现）。两条腿一起走，覆盖「容器还没建好」和
   * 「容器已建好」两种时刻，且两者目标一致、重复执行幂等：
   * 1) 声明式：写 webtoonStartIndex = List 的 initialIndex。切档与进章节都是**整棵子树新建**，
   *    新 List 构造时就从这一页开始排，不依赖任何命令时机（initialIndex 用不了的情况最多是
   *    「同一棵已存在的 List 不重读构造参数」，那种情况由第 2 条兜住）。
   * 2) 命令式：记 pendingJumpIndex，等 List 的 onAppear（挂载后回调，布局已就绪）补一次
   *    scrollToIndex。不传 align —— SDK scroll.d.ts:519 写明 List 的默认对齐就是 START。
   * 不在这里直接调 scrollToIndex：此刻 List 可能还没建（切档前横向档没有 List），
   * 未绑定的 Scroller 调滚动命令是空操作，静默不报错 = 最难查的那种失败。
   */
  private jumpToIndex(index: number): void {
    const n: number = this.urls.length;
    if (n === 0) {
      return;
    }
    let i: number = index;
    if (i < 0) {
      i = 0;
    }
    if (i > n - 1) {
      i = n - 1;
    }
    this.pageIndex = i;
    this.webtoonStartIndex = i;
    this.pendingJumpIndex = i;
  }

  /** List 挂载后补一次定位：只消费一次，之后用户怎么滚都不再插手 */
  private consumePendingJump(): void {
    const i: number = this.pendingJumpIndex;
    if (i < 0) {
      return;
    }
    this.pendingJumpIndex = -1;
    try {
      this.webtoonScroller.scrollToIndex(i, false);
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[Reader] scrollToIndex failed: code=${e.code} msg=${e.message}`);
    }
  }

  /** 页码变化后节流落库：滚动时每帧都会改页码，逐次写库会把 DB 打在滚动帧上 */
  private scheduleProgressSave(): void {
    if (this.webtoonSaveTimer >= 0) {
      return;
    }
    this.webtoonSaveTimer = setTimeout((): void => {
      this.webtoonSaveTimer = -1;
      this.saveProgress();
    }, ReaderView.WEBTOON_SAVE_DEBOUNCE_MS);
  }

  /** 纵向档页码判定（要求 3 的口径）：见方法内注释 */
  private onWebtoonScrollIndex(start: number, end: number, center: number): void {
    if (this.urls.length === 0) {
      return;
    }
    // 取 center（屏幕中央那一页）：纵向档一屏常跨两三页，取 start 会让页码长期停在
    // 刚露头的那页、看着「比看到的落后一页」，取 end 会跑到还没读的那页。
    // SDK list.d.ts:1605 未写明三值不可见时的哨兵值，所以 center 非法时退回 start。
    let idx: number = center;
    if (idx < 0 || idx >= this.urls.length) {
      idx = start;
    }
    if (idx < 0 || idx >= this.urls.length) {
      return;
    }
    if (idx !== this.pageIndex) {
      this.pageIndex = idx;
      this.scheduleProgressSave();
      // 换页就补一轮预取：onScrollIndex 只在跨页时回调（不是每帧），所以这里发不出几轮，
      // 且 isInFlight 判重会把「行组件已在取」的地址全部挡掉，不会把请求队列灌爆
      this.prefetchAround(idx);
    }
  }

  /**
   * 预取（s16 第 2 条丙）：把当前页前后窗口内的字节先塞进 ImageCache，等行被框架创建时
   * 直接走内存/磁盘命中，不再临到眼前才发请求。窗口口径与折算见 PREFETCH_AHEAD 注释。
   * 四条刻意的约束：
   * ① 只在 isReady() 为真时发（数据层没就绪时 loadPage 会直接记一次 pageFailed，那是假失败）；
   * ② 跳过 ReaderDiag.isInFlight 的地址 —— ImageCache 目前没有「在途去重」（那是 cache-fix 那条
   *   并行改的事，不属我写域），不去重就会出现「行组件正在取 + 预取又取同一条」的真重复请求，
   *   把 16 号行 imageChain 的 pageCalls 打成对不上账的数；
   * ③ 结果整个吞掉：预取的产物只有「缓存里多了一条」这一个作用，成功不必提，失败也不许冒泡
   *   到界面（行自己的 load 会给出唯一的失败口径，两处上屏 = 用户看到两次报错）；
   * ④ 记 prefetchTotal（诊断 17 号行的 pre= 字段）：ImageCache 没有「只预取不计数」的入口，
   *   loadPage 每次进来都在 :368 自增 pageCalls，所以 pre= 是把 16 号行 pageCalls 与真实
   *   用户可见取图量对回去的唯一换算项。
   */
  private prefetchAround(index: number): void {
    const n: number = this.urls.length;
    if (n === 0 || !ImageCache.getInstance().isReady()) {
      return;
    }
    let from: number = index - ReaderView.PREFETCH_BEHIND;
    if (from < 0) {
      from = 0;
    }
    let to: number = index + ReaderView.PREFETCH_AHEAD;
    if (to >= n) {
      to = n - 1;
    }
    for (let i = from; i <= to; i++) {
      const u: string = this.urls[i];
      if (u.length === 0 || ReaderDiag.isInFlight(u)) {
        continue;
      }
      ReaderDiag.prefetchTotal += 1;
      ImageCache.getInstance().loadPage(u, this.sourceId, this.currentChapterId)
        .then((): void => {})
        .catch((): void => {});
    }
  }

  /**
   * 回章定位（要求 3）：读库里的进度，命中「同一本书 + 同一章」才从该页继续，否则从首页开始。
   * 只在纵向档生效（默认档 = 横向，老用户看到的行为一字不变）；横向档要不要也续读
   * 属产品决定，已写进交卷报告交 lead，不在本轮自作主张。
   * 落点前移一页：jumpToIndex 的顶部对齐会把目标行顶到屏幕最上沿，而顶栏是浮层会盖住它，
   * 前移一页后目标页必然在顶栏下方可见。代价 = 高图章节可能多露上一页尾巴，误差一页以内。
   */
  private async resumeOnOpen(): Promise<void> {
    if (!this.isWebtoon() || this.urls.length === 0) {
      return;
    }
    try {
      const p: ReadProgress | null = await MangaRepository.getInstance().getProgress(this.mangaId);
      if (p === null || p.chapterId !== this.currentChapterId) {
        return;
      }
      const target: number = p.page > 0 ? p.page - 1 : 0;
      if (target >= this.urls.length) {
        return;
      }
      this.jumpToIndex(target);
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[Reader] resume failed: code=${e.code} msg=${e.message}`);
    }
  }

  async loadPages(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      if (this.mangaId.length === 0) {
        this.errorMsg = '缺少漫画参数';
        ReaderDiag.noteChapterError(this.errorMsg);
        return;
      }
      const src: MangaSource | null = SourceManager.getInstance().get(this.sourceId);
      if (src === null) {
        this.errorMsg = '图源未就绪';
        ReaderDiag.noteChapterError(this.errorMsg);
        return;
      }
      const chapters: ChapterInfo[] = await src.fetchChapters(this.mangaId);
      if (chapters.length === 0) {
        this.errorMsg = '该漫画暂无章节';
        // 不是异常，但用户看到的是同一个界面，一样进取证（s15 第 1 条第 3 点）
        ReaderDiag.noteChapterError(this.errorMsg);
        return;
      }
      let target: ChapterInfo = chapters[0];
      if (this.chapterId.length > 0) {
        for (let i = 0; i < chapters.length; i++) {
          if (chapters[i].id === this.chapterId) {
            target = chapters[i];
            break;
          }
        }
      }
      this.chapterName = target.title;
      this.currentChapterId = target.id;
      const pages: PageImage[] = await src.fetchPages(target.id);
      const list: string[] = [];
      for (let i = 0; i < pages.length; i++) {
        list.push(pages[i].url);
      }
      this.urls = list;
      // 换章节 = 换整个数据源实例（LazyForEach 不认「同实例换内容」，靠 @State urls 变化
      // 重跑 build，LazyForEach 重新按 key 取数）。页码同步归零，再按存档续读。
      this.webtoonSource = new WebtoonPageSource(list);
      this.pageIndex = 0;
      if (list.length === 0) {
        this.errorMsg = '本章节没有图片';
        // 同上：fetchPages 没抛但交了空页表，界面与失败一模一样，必须记账
        ReaderDiag.noteChapterError(this.errorMsg);
      } else {
        ReaderDiag.readerPagesLoaded += 1;
        // 必须在 finally 置 loading=false（列表真正开始布局）之前把 pageIndex 落好，
        // 否则首帧先画第一页、下一帧才跳走，看着像进章节抖一下
        await this.resumeOnOpen();
        // 章节就绪 + 落点定好之后立刻按窗口预取一轮（首屏之后的几页在用户还没翻到时就进内存）
        this.prefetchAround(this.pageIndex);
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Reader] load failed: code=${e.code} msg=${e.message}`);
      // s15 第 1 条（用户原话「进入pic源提供的漫画并点击阅读后，直接显示无法加载和重试按钮，
      // 根本无法切到下一页」）：屏上原来只有「章节加载失败」五个字，真因只进 console.error，
      // 用户回传截图无从判断坏在哪一步。现在按 briefForScreen 判据把真因洗成一句中文上屏：
      // 适配器那两条自撰中文可用（其括号内的 chapterId 属用户浏览痕迹，helper 里已截掉），
      // 堆栈 / URL / 包路径 / JSON / 英文异常名一律回兜底短句，不把底层原文铺给用户。
      const raw: string = typeof (err as Error).message === 'string' ? (err as Error).message : '';
      this.errorMsg = briefForScreen(raw, '章节加载失败，可点按重试');
      ReaderDiag.noteChapterError(this.errorMsg);
    } finally {
      this.loading = false;
    }
  }

  /**
   * 落库进度，并把 sourceId / title 一起带上（bug④ 修法）。
   * manga 表只有「加入书架」才会写 ⇒ 从发现页直接读的书若不带上这两项，
   * 阅读记录页会因查不到元数据而整页空白。
   */
  private async saveProgress(): Promise<void> {
    try {
      await MangaRepository.getInstance()
        .saveProgress(this.mangaId, this.currentChapterId, this.pageIndex, this.sourceId, this.title);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Reader] saveProgress failed: code=${e.code} msg=${e.message}`);
    }
  }

  private prevPage(): void {
    if (this.pageIndex > 0) {
      this.swiperController.showPrevious();
    }
  }

  private nextPage(): void {
    if (this.pageIndex < this.urls.length - 1) {
      this.swiperController.showNext();
    }
  }

  /** 放大后允许的最大平移：内容放大后超出视口的那一半（锚点是中心） */
  private maxOffsetX(): number {
    return this.areaW * (this.zoomScale - 1) / 2;
  }

  private maxOffsetY(): number {
    return this.areaH * (this.zoomScale - 1) / 2;
  }

  /** 把当前平移量收进钳位框（缩放变小、或视口尺寸刚拿到时都要重算一次） */
  private clampOffsets(): void {
    if (this.zoomScale <= 1 + ReaderView.ZOOM_EPS) {
      this.offsetX = 0;
      this.offsetY = 0;
      return;
    }
    const mx: number = this.maxOffsetX();
    const my: number = this.maxOffsetY();
    if (this.offsetX > mx) {
      this.offsetX = mx;
    } else if (this.offsetX < -mx) {
      this.offsetX = -mx;
    }
    if (this.offsetY > my) {
      this.offsetY = my;
    } else if (this.offsetY < -my) {
      this.offsetY = -my;
    }
  }

  /**
   * 左右热区。横向档（现役语义不变）：未放大 = 翻页；放大且开了「点按平移」= 沿点的那一侧
   * 平移约一屏宽（80% 视口）；放大但没开该设置时仍按原来的翻页走，行为对老用户零惊喜。
   * 纵向档（s13 第 6 条）：左右两侧 = 沿阅读方向前后滚约一屏高（右侧向下 = 继续往下读）。
   */
  private tapSide(forward: boolean): void {
    if (this.isWebtoon()) {
      const vh: number = this.areaH > 0 ? this.areaH : 600;
      const step: number = vh * ReaderView.WEBTOON_PAGE_STEP_RATIO;
      // scrollBy(dx, dy) 正值 = 内容向上移 = 往下看，所以「下一屏」是 +step。
      // scrollBy 只收绝对值、不支持百分比（scroll.d.ts:542-543），所以步长必须用 areaH 换算，
      // 而 areaH 由阅读区的 onAreaChange 提供（纵向档仍然挂在同一个外层 Stack 上，量得到）。
      this.webtoonScroller.scrollBy(0, forward ? step : -step);
      return;
    }
    if (this.tapPans && this.zoomScale > 1 + ReaderView.ZOOM_EPS) {
      const step: number = this.areaW > 0 ? this.areaW / this.zoomScale * 0.8 : 200;
      this.offsetX += forward ? -step : step;
      this.clampOffsets();
      return;
    }
    if (forward) {
      this.nextPage();
    } else {
      this.prevPage();
    }
  }

  /**
   * 屏中热区（s16 第 2 条丁）：当前页「最后一次取图是失败的」→ 这一按当手动重试，
   * 并且**不切顶栏**（用户点重试时顶栏跳出来正好盖住他要看的那一页）；其余情况保持现役语义 =
   * 切顶栏显隐，一字不变。信号只推尺寸键，只有前缀匹配的那一行会响应（见 ReaderPageImage.onRetrySignal）。
  * 键直接取模块级 pageSizeKey（与 ReaderPageImage.sizeKey() 共用同一处定义，见那边注释），
  * 所以「点了重试没有一行响应」这种键错位在这里结构性不可能发生，探针只核那一处定义。
   */
  private tapCenter(): void {
    const idx: number = this.pageIndex;
    if (idx >= 0 && idx < this.urls.length && ReaderDiag.isFailed(this.urls[idx])) {
      ReaderDiag.pushRetry(pageSizeKey(this.currentChapterId, idx + 1));
      return;
    }
    this.chromeVisible = !this.chromeVisible;
  }

  /** 左/中/右点按热区（横向档：放在每一页内，避免遮挡 Swiper 的左右滑动手势） */
  @Builder
  TapZones() {
    this.TapZonesBody();
  }

  /** 热区本体，两档共用：语义随档位变（见 tapSide），横向左翻右翻、纵向左右前后滚、屏中显隐顶栏 */
  @Builder
  TapZonesBody() {
    Row() {
      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.tapSide(false);
        })

      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.tapCenter();
        })

      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.tapSide(true);
        })
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 纵向档阅读区：单列 List 连续滚动，从上向下读。
   * 形态要点（每条都是刻意的，改动前先读注释）：
   * - List 的 scroller **走对象参数**：List(scroller) 会把 Scroller 当 ListOptions，
   *   报「Type 'Scroller' has no properties in common with type 'ListOptions'」；
   *   Grid/Scroll 才是位置参数（本仓 DiscoverPage.ets:380 是同款写法，别照抄成 Grid 那种）。
   * - 每项高度交给 ReaderPageImage(fitHeight=true) 按图片真实宽高比排：图多高行多高，
   *   连续衔接不留空白；用固定屏高会让一条长图被塞进一屏、上下全是黑边。
   * - LazyForEach 加 cachedCount(ReaderView.WEBTOON_CACHED_COUNT=4)：只实例化可见行与上下
   *   各 4 行邻居（s16 第 2 条丙按上游 2 屏折算，见该常量注释），滚远的行销毁重建

   *   （本仓没开 shouldBend 节点复用，所以重建会重跑 aboutToAppear 重新解码，
   *   不会拿到上一个 url 的 PixelMap = 不会串图）。
   * - edgeEffect(None)：顶底不要回弹。阅读器里「拉到顶还想再拉」不该给出弹性反馈，
   *   那下回弹在长条漫里看着像整章在抖（默认值是 EdgeEffect.Spring，list.d.ts:1025）。
   * - key 用 'p' 加下标、不带 url：与横向档同一份 key 语义。章节变化时 @State urls 变化
   *   会让 LazyForEach 整体重建（数据源也是新实例），所以「同章内 url 换了 key 不变」
   *   这种情况不存在（页列表一次取全，不会原地改）；若将来做「追加下一章」，key 必须改成带 url。
   */
  @Builder
  WebtoonArea() {
    List({ space: 0, scroller: this.webtoonScroller, initialIndex: this.webtoonStartIndex }) {
      LazyForEach(this.webtoonSource, (item: string, index: number) => {
        ListItem() {
          // 热区必须挂在**行内**（与横向档同一套结构），不能整屏盖一层在 List 之上：
          // ArkUI 的命中测试只沿「根到命中节点」这条链派发，List 是热区的兄弟而不是祖先时，
          // 起于热区的拖动永远进不了 List 的滚动手势识别器 = 滚不动。
          Stack({ alignContent: Alignment.Center }) {
            ReaderPageImage({
              url: item,
              sourceId: this.sourceId,
              chapterId: this.currentChapterId,
              fitHeight: true,
              pageNo: index + 1,
              viewportH: this.areaH
            })
            this.TapZonesBody()
          }
          .width('100%')
        }
        .width('100%')
      }, (item: string, index: number) => 'p' + index)
    }
    .width('100%')
    .height('100%')
    .cachedCount(ReaderView.WEBTOON_CACHED_COUNT)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .onAppear(() => {
      // 挂载后补一次待执行定位（见 consumePendingJump）
      this.consumePendingJump();
    })
    .onScrollIndex((start: number, end: number, center: number): void => {
      this.onWebtoonScrollIndex(start, end, center);
    })
  }

  @Builder
  ReaderTopBar() {
    Column() {
      Row() {
        Stack() {
          Path({
            width: Dim.backIcon,
            height: Dim.backIcon,
            commands: 'M15.5 5 L7.5 12 L15.5 19'
          })
            .stroke(Theme.white)
            .strokeWidth(2)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
            .fill(Color.Transparent)
        }
        .width(Dim.backHit)
        .height(Dim.backHit)
        .borderRadius(Dim.backHit / 2)
        .onClick(() => {
          // s10 第 4 条补口：进度落库是异步的，旧写法「发了不等」= 首次读某本书时新增的 history 行
          // 可能落在 pages/ReaderPage.onPageHide 那次 bump 之后 ⇒ 该场景「更多」页条数少 1。
          // 刻意不 await：把返回按钮交给一次 DB 写，库一卡就把人困在阅读页里。改成落库完成后
          // 再补推一次版本号；saveProgress 内部已 catch，所以 then 必然执行。重复 bump 无害 =
          // MinePage.recountHistory 幂等且有 historyBusy 闸门（口径同 view/mine/MinePage.ets:143）。
          this.saveProgress().then((): void => {
            AppStorage.setOrCreate<number>('historyRevision', (AppStorage.get<number>('historyRevision') ?? 0) + 1);
          });
          router.back();
        })

        Column() {
          Text(this.title)
            .fontSize(Dim.topBarTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.white)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          Text(this.chapterName)
            .fontSize(11)
            .fontColor(Theme.dTextSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 4 })

        Text(this.urls.length > 0 ? `${this.pageIndex + 1}/${this.urls.length}` : '0/0')
          .fontSize(12)
          .fontColor(Theme.white)
          .maxLines(1)
      }
      .width('100%')
      .height(Dim.topBarH + this.topSafe)
      .padding({
        top: this.topSafe,
        left: 8,
        right: Dim.pagePadding
      })
      .alignItems(VerticalAlign.Center)

      // 第 5 条(1) 例外：这条**保留**。它在阅读器顶栏的深色 scrim 浮层上（背景 = Theme.scrim，
      // 浮在图片之上），半透明白是浮层的视觉边界而非页面分割线；这里也不该用
      // Theme.dividerColor（那是页面色档的浅灰线，压在黑 scrim 上看不见）。
      Divider()
        .strokeWidth(0.5)
        .color('#33FFFFFF')
    }
    .width('100%')
    .backgroundColor(Theme.scrim)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 阅读区：横向 Swiper + 双指缩放 + 三分区点按（左/中/右）
      Stack({ alignContent: Alignment.Center }) {
        if (this.loading) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(Theme.white)
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text(this.errorMsg)
              .fontSize(14)
              .fontColor(Theme.white)
            Text('点按重试')
              .fontSize(12)
              .fontColor(Theme.brand)
              .margin({ top: 10 })
              .onClick(() => {
                this.loadPages();
              })
          }
        } else if (this.isWebtoon()) {
          // s13 第 6 条：纵向档（从上向下连续滚动），形态与口径见 WebtoonArea
          this.WebtoonArea()
        } else {
          Swiper(this.swiperController) {
            ForEach(this.urls, (item: string, index: number) => {
              // 每页内部分左/中/右三个点按热区：点按不阻断 Swiper 的左右滑动
              Stack({ alignContent: Alignment.Center }) {
                ReaderPageImage({
                  url: item,
                  sourceId: this.sourceId,
                  chapterId: this.currentChapterId,
                  pageNo: index + 1,
                  // 横向档高度语义不动（仍是 height 100% 一屏一页），这里只是把视口高透下去，
                  // 让「万一某页没到位图」时的骨架也按同一个 1/4 屏封顶，两档不会一个矮一个高
                  viewportH: this.areaH
                })
                this.TapZones()
              }
              .width('100%')
              .height('100%')
            }, (item: string, index: number) => 'p' + index)
          }
          .index(this.pageIndex)
          .loop(false)
          .vertical(false)
          .indicator(false)
          .duration(200)
          .width('100%')
          .height('100%')
          .scale({ x: this.zoomScale, y: this.zoomScale })
          .translate({ x: this.offsetX, y: this.offsetY })
          .onChange((index: number) => {
            this.pageIndex = index;
            // 横向档同样预取（它是一页一屏，窗口 6 页 = 6 屏，比纵向档更该预取）
            this.prefetchAround(index);
            // 换页必须清平移，否则新页一进来就是歪的（放大态下翻页最容易撞到这个）
            this.offsetX = 0;
            this.offsetY = 0;
            this.saveProgress();
          })
        }
      }
      .direction(this.rtl ? Direction.Rtl : Direction.Ltr)
      .width('100%')
      .height('100%')
      // 平移钳位要有视口尺寸：onAreaChange 比 getWindowSize 可靠（分屏/折叠屏变化会回调）
      .onAreaChange((_o: Area, n: Area) => {
        const w: number = Number(n.width);
        const h: number = Number(n.height);
        if (w > 0 && h > 0 && (w !== this.areaW || h !== this.areaH)) {
          this.areaW = w;
          this.areaH = h;
          this.clampOffsets();
        }
      })
      // 缩放只在横向档生效（s13 第 6 条）：SDK 只有一条 gesture(gesture: GestureType, mask?)
      // 重载（common.d.ts:19002），没法按档位挂或不挂，所以手势常驻、三个回调里各自早退。
      // 纵向档为什么不缩放：给整棵 List 加 scale 会让行高跟着插值、LazyForEach 的可见区间
      // 每帧重算，长条漫必然抖；要放大单张图属阅读器下一轮的事。
      .gesture(
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            if (this.isWebtoon()) {
              return;
            }
            this.baseZoomScale = this.zoomScale;
          })
          .onActionUpdate((event: GestureEvent) => {
            if (this.isWebtoon()) {
              return;
            }
            let s: number = this.baseZoomScale * event.scale;
            if (s < 1) {
              s = 1;
            }
            if (s > 4) {
              s = 4;
            }
            this.zoomScale = s;
          })
          .onActionEnd(() => {
            if (this.isWebtoon()) {
              return;
            }
            if (this.zoomScale < 1.05) {
              this.zoomScale = 1;
            }
            this.baseZoomScale = this.zoomScale;
            // 缩放变小后原平移量可能出界，收尾统一钳一次
            this.clampOffsets();
          })
      )


      // 顶栏：单击屏中切换显隐（隐藏即全屏沉浸）
      if (this.chromeVisible) {
        this.ReaderTopBar();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.black)
  }
}