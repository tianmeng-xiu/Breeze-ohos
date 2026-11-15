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
 * s17 口径（同一条黑区的第二段成因，s16 修完之后剩下的那一半）：s16 让「尺寸已知」的行从首次布局
 *      就按真实比排高，于是多出一种中间态 —— 行高已经是整页真高、位图却还没解码，而骨架只画一枚
 *      居中 120vp 的浅色块，剩下的整页高度全是裸底色 = 用户看到的那条黑区，长度 = 页宽 / 真实比
 *      - 120，纯粹随各源真实比变化（pic 与 jm 黑区长短不同正是这个式子）。s17 = 「尺寸已知而位图未
 *      到」的行，骨架必须铺满整行（只留固定细缝），行高与骨架高同源同一次求值，裸底色恒 <= 12vp。
 * s18 口径（第 5 条 e-hentai 取图修复的宿主侧）：ImageCache 三个取图入口都多了一枚页级 ext
 *      （插件页对象 extern 的 JSON 串），本页必须把 ext 一路带到 loadPage/loadSize，所以
 *      loadPages 除了 url 还要存 pages[i].ext（pageExts 与 urls 同下标）；同时失败表与在途表
 *      的键从 url 改成 pageSizeKey —— e-hentai 整章各页 url 逐字节相同（哨兵地址），按 url 记
 *      会让一页失败摊成整章失败、一页在途摊成整章预取全废。
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

import { router, promptAction } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { SourceManager } from '../../data/source/SourceManager';
import { MangaSource } from '../../data/source/Source';
import { ImageCache } from '../../data/image/ImageCache';
import { MangaRepository } from '../../data/db/MangaRepository';
import { UserSettings, ReadScrollMode, ReadDirection, SettingLabels } from '../../util/UserSettings';
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
 * 纵向档数据源（s13 第 6 条，全仓首例 LazyForEach）：把整章页表交给 LazyForEach，
 * 由框架只实例化可见项与 cachedCount 范围内的邻居，滚远的项自动回收 —— 这是纵向档「跨页续加载」
 * 的实现前提：整章几百张位图不可能同时挂在内存里（ImageCache 的内存 LRU 只有 24 张，
 * 全靠这里不把整章一次性实例化才不会反复解码回吐）。
 *
 * 换章节 = 换整个实例（见 loadChapterAt 里 new WebtoonPageSource）；**同一实例内只做尾部追加**
 * （五项轮无缝转场，appendAndNotify），不做删除与前插。
 */
class WebtoonPageSource implements IDataSource {
  /**
   * 五项轮（无缝转场）：条目类型从 string 换成 PageRef（每格自带章身份，理由见 PageRef 注释），
   * 并去掉 readonly 支持尾部追加。追加走 appendAndNotify（同帧逐条通知 onDataAdd），
   * 不整体替换数组实例：LazyForEach 的 key 见 WebtoonArea，跨章唯一，已有行的 key 不变
   * ⇒ 不重建、不重新解码，画面不跳（上游 prependedSlotCount 那套位移在 ArkUI 这边不需要
   * —— 我们只在尾部追加，视觉位置天然不动）。
   */
  private items: PageRef[];
  /** LazyForEach 绑定时注册进来的监听器：追加下一章要靠它通知（五项轮前只存不通知） */
  private listeners: DataChangeListener[] = [];

  constructor(items: PageRef[]) {
    this.items = items;
  }

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): PageRef {
    return this.items[index];
  }

  /** 尾部追加后的总格数（调用方拿它算追加起点，见 tryAppendNextChapter） */
  size(): number {
    return this.items.length;
  }

  /**
   * 尾部追加一批格子并逐条通知 onDataAdd。两条刻意的口径：
   * ① 不用 onDataReloaded：那会让 LazyForEach 重比对全部条目，代价是整章重新解码，
   *    与"无缝"正好相反；逐条 onDataAdd 只新增末尾那几个格子。
   * ② 顺序 = 先改数组再通知，且 index 用追加后的绝对下标（DataChangeListener.onDataAdd
   *    语义 = 数据被加到该下标处，lazy_for_each.d.ts:644-656）。
   * ③ 一次一格的循环通知（不是整批一次 onDataAdd）：ArkUI 的 onDataAdd 只带一个下标，
   *    整批只通知末位会让中间那些格子在 LazyForEach 的计数里缺席 = 少画几页。
   */
  appendAndNotify(more: PageRef[]): void {
    for (let i = 0; i < more.length; i++) {
      this.items.push(more[i]);
      const at: number = this.items.length - 1;
      for (let k = 0; k < this.listeners.length; k++) {
        this.listeners[k].onDataAdd(at);
      }
    }
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
 * 纵向档渲染列表里的**一格**（五项轮，无缝转场的身份载体）。
 *
 * 为什么不能只塞 url：无缝转场把下一章的页拼进同一条 List 之后，行内三件事都必须按
 * 「这一格真正属于哪一章」来算，按渲染列表的下标算必错：
 * ① pageSizeKey(章, 页码) = 尺寸表键与手动重试信号键（跨章同页码会撞键 → 行高表串章）；
 * ② ImageCache.loadPage/loadSize 的 chapterId 入参 = 插件取图上下文与反混淆意图判定；
 * ③ 进度落库的 chapterId + page（滚进下一章还记在上一章 = 下次续读回到旧位置）。
 * 上游同一件事的做法是给整条槽流配两个纯函数 mapGlobalToLocalSlot / mapLocalToGlobalSlot
 * （reader_seamless_cubit.dart:448-463），本质也是"每格自带章身份"，只是它把映射收在 cubit 里。
 * 我方只从尾部追加（不 prepend），所以全局下标 → 本地下标只需减去所属章的起点，
 * 而那一起点直接存在格子上，比维护一张映射表更不容易错。
 */
class PageRef {
  url: string = '';
  ext: string = '';
  /** 这一格真正属于的章节 id（不是当前打开的章） */
  chapterId: string = '';
  /** 章内页码（1 起），与 pageSizeKey 的口径一致 */
  pageNo: number = 0;
  /** 所属章的总页数（顶栏页码与滑杆分母 = 章内口径，不是整条流的长度） */
  pageTotal: number = 0;
  /** 属于 chapters 的哪一章（0 起）；进度落库与目录高亮按它判"现在在读第几章" */
  chIdx: number = 0;

  constructor(url: string, ext: string, chapterId: string, pageNo: number, pageTotal: number, chIdx: number) {
    this.url = url;
    this.ext = ext;
    this.chapterId = chapterId;
    this.pageNo = pageNo;
    this.pageTotal = pageTotal;
    this.chIdx = chIdx;
  }
}

/**
 * 无缝转场用的一章装载结果（五项轮）。刻意只带**已折好的格子**不带 ChapterInfo：追加时
 * 页表已在手，再回源取一次是多余的请求；title 只给日志与目录高亮对账用。
 * 载体是 PageRef[]（不是 urls/exts 两条平行数组）：追加路径与首载路径必须走同一枚
 * buildCells，否则两条路折出来的格子字段口径会漂（chIdx 少写一位 = 追加闸永远不开）。
 */
class SeamlessChapter {
  chapterId: string = '';
  title: string = '';
  cells: PageRef[] = [];
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

  /**
   * s17：本进程见过的「尺寸已知/未知而位图未到」那一行里，**裸底色高度**的最大值（vp）。
   * 这是黑区的直接量纲：修好之前 = 整页真高减 120（真机页宽 377vp、竖页比 0.62 到 0.71 时是
   * 412 到 488vp，约半屏）；修好之后恒等于骨架细缝常量 SKELETON_FILL_INSET（12vp）。
   * 初值 -1 = 本进程从未渲染过占位行（真机读到 bare=-1 说明占位分支一次没走，不是「黑区=−1」）。
   * 刻意取最大值而不是计数：计数会被重复渲染灌大（同一次挂载里 @State 每变一次就重跑一遍 build），
   * 而「最大裸底色」是幂等的，天然抗重复，单值就能当验收判据。
   */
  static bareVoidMax: number = -1;

  /**
   * s17 追加 A1（lead 派工）：行**实测落高**的最近值与竖向档历史最大值（vp，onAreaChange 直接量）。
   * 为什么还要再量一遍：bare= 量的是「我以为的行高减骨架高」，它吃的是 pendingRowH 的口径 ——
   * 首帧父宽没落地（viewportW<=0）时它按窄骨架自算，量不到真实落位；行内热区那枚 height 100% 的
   * Stack 若真把行撑到一屏（嫌疑 e2），bare= 也看不见。只有 onAreaChange 是 ArkUI 落位后的真数。
   * rowHLast：最近一次上报（两档都记，指当前渲染的那一档）。
   * rowHMax：只记竖向档的历史最大值（取大不取小 = 幂等，抗 LazyForEach 重复重挂与 @State 重复渲染；
   *  横向档行高恒 = 视口高，记进去会让「rowHMax >= 视口高」这条判据永久打红，所以刻意排除）。
   * 判据：竖向档下 rowHLast 应约等于 宽/真比（真比档）或 skeletonHeight()（窄骨架档）；
   * 持续 >= 阅读区视口高 = 嫌疑 e2 成立（行高被热区撑到一屏）。rowHMax=0 = 本进程没渲染过竖向档。
   */
  static rowHLast: number = 0;
  static rowHMax: number = 0;
  /**
   * 与 rowH 配对的**行盒**实测高（vp）： ListItem 内那枚热区 Stack 的实测高 = 真机上这一行真正占掉的高。
   * 为什么两枚都要量（这是 A1 的关键补刀）：行内 ReaderPageImage 的根容器自带 aspectRatio 或显式 height，
   * 它自己报的高**永远等于它请求的高**，就算兄弟那枚热区 Row 用 height 100% 把行盒撑到一屏，它也照样报
   * 宽/真比 —— 只量组件会**必然读到健康值**，把 e2 遮成假 PASS。所以真正的判据是两条之差：
   *   rowBox - rowH 持续 > 0（且差值接近一屏）= 行盒比组件请求的高 = e2 成立（热区把行撑高）；
   *   rowBox == rowH（差一两条 vp 的取整）= 行高就是组件给的 = e2 排除。
   * 配套告警：e2 若成立，bare= 仍会读到 12.00（骨架铺满的是组件，不是行），所以 bare= 单条**不能**证伪 e2。
   * 取最大值同理幂等；初值 0 = 本进程没量过纵向行盒。
   */
  static rowBoxLast: number = 0;
  static rowBoxMax: number = 0;
  /**
   * s21 黑区修法：**挂在屏上的位图被 release 之后**再读一次它的尺寸必然抛（Image 那边则画整幅纯黑，
   * 不抛给 UI 线程）。aspect() 里 getImageInfoSync 的 catch 是这条链路唯一的可观测指纹，命中就 +1。
   * 判读：dead= 持续大于 0 = 确实有「位图挂在一行上却被缓存释放掉」发生（与 16 号行 pin= 的
   * evictHeld 一档互为旁证）；修法生效后应恒为 0。
   */
  static pmDead: number = 0;
  /**
   * s25 纯探针批次（1）同页行高配对表：本轮新截图 shot4 推翻了旧主攻假设 —— 那条黑带宽高比
   * 1851/1320 = 1.4023 与位图比 1807/1280 = 1.4117 只差 0.7%，且 1851px / 3.376 = 548.3vp 恰等于
   * 实测 rowH，说明「黑段 = 一整行整幅」而不是「行盒比等比落高多出来的那 292vp 上下留边」。
   * 而旧 rowH= 与 rowBox= 各是 last/max 两枚**独立**计数、很可能来自不同页，拿它们相减是跨页相减。
   * 本表按页身份（pageSizeKey）把两侧存进同一格，只有同一页两侧都量到过才计 gap，并记 pairN 配对次数：
   *   pairN = 0 = 一条都没配上（别读 gap=）；pairN > 0 且 gap= 持续为正且量级近一屏 = 行盒被撑高（e2 成立）；
   *   pairN > 0 且 gap= 接近 0 = e2 排除，主攻转向位图内容侧（与 late= / edge= 联立）。
   * gap= 只记正差（行盒理应 >= 组件高，负值不记）；取最大值幂等，抗 LazyForEach 重挂。
   */
  private static readonly rowPairH: Map<string, number> = new Map<string, number>();
  private static readonly rowPairBox: Map<string, number> = new Map<string, number>();
  /** 配对表的入表顺序（有界淘汰按它移最旧一批，口径同 sizeKeyOrder） */
  private static readonly rowPairOrder: string[] = [];
  /** 同页最大差（vp）与它所属页码。刻意只存 '#' 之后的页码：chapterId 里带用户浏览痕迹，不进诊断行。 */
  static rowGapMax: number = 0;
  static rowGapKey: string = '';
  /**
   * s27 判代 + 回归双用计数：本进程里 ReaderPageImage 自己的 TapLayer（下沉后的三列热区）收到过多少次点按。
   * ① 判代：装机包没这个字段 = 包早于 s27，回传读数一律作废（既有判代铁律：看新字段在不在）。
   * ② 回归：热区从行盒挪进图片容器后点按必须照样生效 —— 用户明确点过画面而 tap= 仍 0 = 新热区没接住事件。
   * ★ s30 第 6 条起口径变更：中心列的命中面从「整条竖列」收成居中 96vp 方块 ⇒ 本计数只统计
   *   ①左右两列翻页 ②中心那一小块。用户点了画面中部但没点中小块时 tap= 不涨属预期，
   *   判代照看「字段在不在」，回归判定改看「点中小块后涨不涨」，别再拿 tap=>0 当「点过画面」的证据。
   */
  static tapHits: number = 0;
  /** 配对成功次数（同页两侧都量到才算一次）：gap= 的可信度分母，0 时 gap= 无意义 */
  static rowPairCount: number = 0;
  /** s25 纯探针批次（2）阅读区视口实测宽高（vp），来自页面根 Stack 的 onAreaChange */
  static viewportW: number = 0;
  static viewportH: number = 0;

  /**
   * 把一次实测高写进「这一页」的那一侧（isRow=true 组件侧 / false 行盒侧），两侧齐了就更新 gap。
   * 空 pageKey 直接忽略（父组件没传 pageNo 的调用点属「没有这一页」，不是「高为 0」）。
   * 有界纪律与 rememberPageRatio 同款：表是进程级的，必须有容量上限。
   */
  private static pairRow(pageKey: string, h: number, isRow: boolean): void {
    if (pageKey.length === 0) {
      return;
    }
    if (!ReaderDiag.rowPairH.has(pageKey) && !ReaderDiag.rowPairBox.has(pageKey)) {
      while (ReaderDiag.rowPairOrder.length >= ReaderDiag.SIZE_KEY_MAX) {
        for (let i = 0; i < ReaderDiag.SIZE_KEY_EVICT && ReaderDiag.rowPairOrder.length > 0; i++) {
          const oldest: string = ReaderDiag.rowPairOrder.shift() ?? '';
          if (oldest.length > 0) {
            ReaderDiag.rowPairH.delete(oldest);
            ReaderDiag.rowPairBox.delete(oldest);
          }
        }
      }
      ReaderDiag.rowPairOrder.push(pageKey);
    }
    if (isRow) {
      ReaderDiag.rowPairH.set(pageKey, h);
    } else {
      ReaderDiag.rowPairBox.set(pageKey, h);
    }
    const hv: number | undefined = ReaderDiag.rowPairH.get(pageKey);
    const bv: number | undefined = ReaderDiag.rowPairBox.get(pageKey);
    if (hv === undefined || bv === undefined || !(hv > 0) || !(bv > 0)) {
      return;
    }
    ReaderDiag.rowPairCount++;
    const gap: number = bv - hv;
    if (gap > ReaderDiag.rowGapMax) {
      ReaderDiag.rowGapMax = gap;
      const at: number = pageKey.lastIndexOf('#');
      ReaderDiag.rowGapKey = at >= 0 ? pageKey.substring(at + 1) : '';
    }
  }



  /**
   * 记一笔行实测落高（h 非法或为 0 直接忽略：首帧 onAreaChange 可能给 0）。vertical=false 只更新 last。
   * s25 追加 pageKey 形参：last/max 是两枚独立计数，跨页相减不成立，同页比较走 pairRow（见 rowGapMax）。
   */
  static noteRowH(h: number, vertical: boolean, pageKey: string): void {
    if (!(h > 0)) {
      return;
    }
    ReaderDiag.rowHLast = h;
    if (vertical && h > ReaderDiag.rowHMax) {
      ReaderDiag.rowHMax = h;
    }
    ReaderDiag.pairRow(pageKey, h, true);
  }

  /** 记一笔纵向行盒实测高（与 noteRowH 同口径：非正数丢弃、max 幂等；pageKey 同上新增） */
  static noteRowBox(h: number, pageKey: string): void {
    if (!(h > 0)) {
      return;
    }
    ReaderDiag.rowBoxLast = h;
    if (h > ReaderDiag.rowBoxMax) {
      ReaderDiag.rowBoxMax = h;
    }
    ReaderDiag.pairRow(pageKey, h, false);
  }

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
   * 最后一次取图**失败的那一页**（s16 第 2 条丁；s18 改按页定键）。刻意做成「提示表」
   * 而不是负缓存：屏中热区要靠它区分「这一按是重试还是显隐顶栏」，某页成功一次就从表里摘掉，
   * 所以它不会拦住任何一次真实请求 —— 自动重试与手动重试都是直接再调 ImageCache.loadPage。
   * （ImageCache 侧的失败负缓存不属本文件写域；本文件也不自建，否则重试就发不出去了。）
   *
   * 键为什么从 url 换成 pageSizeKey（章节id 加 # 加 页码）：e-hentai 这类图源整章各页 url
   * 逐字节相同（哨兵地址，真机实测），按 url 记会让「第 1 页失败」把整章一起判死 ——
   * 用户看到的就是整章同时挂上「加载失败」且点哪一格都在重试第 1 页。页身份本来就带章节，
   * 不会跨章串，也不依赖 extern 的具体内容（extern 换了同一页仍是同一格）。
   * 表名沿用 failedUrls 不改名是刻意的：改名的收益只有可读性，代价是本文件与探针多处连锁，
   * 语义已经由这段注释与三个形参名 pageKey 锁死。
   */
  private static readonly failedUrls: Set<string> = new Set<string>();

  /** 记一笔取图失败（pageKey = pageSizeKey(章节id, 页码)；空串不记 = 「没有这一页」，不是「取回失败」） */
  static noteFailed(pageKey: string): void {
    if (pageKey.length === 0 || ReaderDiag.failedUrls.has(pageKey)) {
      return;
    }
    if (ReaderDiag.failedUrls.size >= ReaderDiag.FAILED_MAX) {
      return;
    }
    ReaderDiag.failedUrls.add(pageKey);
  }

  /** 该页成功过就摘掉：判据必须只反映「最后一次结果」，否则修好的页会被一直当成失败页 */
  static noteOk(pageKey: string): void {
    if (pageKey.length > 0) {
      ReaderDiag.failedUrls.delete(pageKey);
    }
  }

  /** 该页最后一次取图是不是失败（父组件的屏中热区判定用） */
  static isFailed(pageKey: string): boolean {
    return pageKey.length > 0 && ReaderDiag.failedUrls.has(pageKey);
  }

  /** 在途表容量上限：只当「这一条别再重复发」的判重器，到量就不再登记（宁可多发的退化，不是错） */
  private static readonly IN_FLIGHT_MAX: number = 256;
  /**
   * 正在取（load 已发起、还没出结果）的**页**。两个用途：
   * ① 预取跳过它 —— 否则「行组件正在取 + 预取又取同一条」会真的发两遍，把 16 号行的 pageCalls
   *   打成对不上账的数（ImageCache 侧的在途去重是 cache-fix 那条并行改的事，这里不越界改它）；
   * ② 只在 load() 的 try 前后一登一摘，摘在成功/失败/空 url 三条出口之前，不会漏（见 load 的 finally）。
   *
   * 键与失败表同源改成 pageSizeKey（s18）：按 url 记在哨兵地址图源上是**反向**的坏 ——
   * 整章共用一个 url，第 1 页在途会让预取把整章全部当成「已在取」而全部跳过，
   * 于是那类图源永远预取不到任何一页（比判重失效更糟，是静默的预取全废）。
   */
  private static readonly inFlight: Set<string> = new Set<string>();

  /** 登记在途（超上限就不登记：判重器退化成「少判几次」，绝不因此漏发请求） */
  static noteInFlight(pageKey: string): void {
    if (pageKey.length === 0 || ReaderDiag.inFlight.has(pageKey)) {
      return;
    }
    if (ReaderDiag.inFlight.size >= ReaderDiag.IN_FLIGHT_MAX) {
      return;
    }
    ReaderDiag.inFlight.add(pageKey);
  }

  /** 摘掉在途标记（load 的 finally 必调） */
  static noteNotInFlight(pageKey: string): void {
    if (pageKey.length > 0) {
      ReaderDiag.inFlight.delete(pageKey);
    }
  }

  /** 该页此刻是否在途（预取判重用） */
  static isInFlight(pageKey: string): boolean {
    return pageKey.length > 0 && ReaderDiag.inFlight.has(pageKey);
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
      ' probe=' + ReaderDiag.sizeProbeHits +
      // s17 新增 bare = 本进程见过的「占位行裸底色高度」最大值（vp）：黑区的直接量纲，
      // 行高按各档真实口径取（纵向 = 宽/真比或窄骨架，横向 = 阅读区高）。
      // 期望恒 = 2 x SKELETON_FILL_INSET = 12；-1 = 本进程没渲染过占位行；大于 12 = 黑区回归。
      ' bare=' + fixed2(ReaderDiag.bareVoidMax) +
      // s17 A1（度量）rowH = 最近一行实测落高 / 竖向档历史最大（vp）。bare= 两条盲区里的第一条由它补：
      // 首帧父宽未落地时 bare= 用的是「它以为的行高」，rowH 是 ArkUI 落位后的真数；左右横向露底两者都量不到。
      // 判据：竖向档应约 = 宽/真比（真比档）或 skeletonHeight()（窄骨架档）；持续 >= 阅读区视口高 = 嫌疑 e2 成立。
      // max 只统计竖向档（横向档行高恒 = 视口高，记进去会永久打红）；0 = 本进程没渲染过竖向档。
      ' rowH=' + ReaderDiag.rowHLast.toFixed(0) + '/' + ReaderDiag.rowHMax.toFixed(0) +
      // s17 A1 配对位 rowBox = 纵向**行盒**实测高（rowH 是组件自报高）：两者之差才是 e2（热区撑高行）的判据，
      // 因为组件自带 aspectRatio，它自报的高永远 == 它请求的高，单量它会把 e2 遮成假 PASS。e2 成立时 bare= 仍 12.00。
      ' rowBox=' + ReaderDiag.rowBoxLast.toFixed(0) + '/' + ReaderDiag.rowBoxMax.toFixed(0) +
      // s21 黑区修法 dead= 屏上位图被 release 的指纹次数（ImageCache 侧对应 pin= 的 evictHeld 一档）：
      // 期望恒 0；大于 0 = 有行在展示期间位图被释放（修不干净就靠这条继续定位）。
      ' dead=' + ReaderDiag.pmDead +
      // s25 纯探针 gap=@p页码 = 同一页「行盒实测高 - 组件实测高」历史最大与所属页码，pairN = 同页配对成功次数。
      // 旧 rowH=/rowBox= 是两枚独立 last/max，跨页相减不成立（shot4 复盘发现的判据缺陷），同页比较只看这两档：
      // pairN=0 时 gap= 无意义；pairN>0 且 gap 持续近一屏 = 行盒被撑高（e2）；pairN>0 且 gap≈0 = e2 排除，转位图内容侧。
      // vw=/vh= 阅读区视口实测宽高，用来把上面这些 vp 数与截图 px 数对上，不再靠反推 density 回代自证。
      ' gap=' + ReaderDiag.rowGapMax.toFixed(0) + '@p' + ReaderDiag.rowGapKey +
      ' pairN=' + ReaderDiag.rowPairCount +
      ' vw=' + ReaderDiag.viewportW.toFixed(0) + ' vh=' + ReaderDiag.viewportH.toFixed(0) +
      // s27 判代 + 回归两用：tap= 下沉后热区收到的点按总数（无此字段 = 包早于 s27；点过画面却恒 0 = 热区搬完没接住事件）。
      ' tap=' + ReaderDiag.tapHits;
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
  /**
   * 中心热区高度（vp；s31 第 4 条把热区放大）。宽度不在这里给 —— 由下面 TapLayer 中列的
   * width('100%') 撑满整列（中列 = 40% 屏宽，见三列宽度那条注释），本常量只管竖向 220vp。
   * s30 那版是居中 96×96 方块，真机反馈「扩大打开设置的中央区域，当前太小」⇒ 现约 154×220vp，
   * 面积是原来的五倍多。**刻意不让热区超出父 Stack 边界**（超出边界能否命中是未验证行为，不赌），
   * 所以只把中列从 1/3 屏宽扩到 2/5、竖向给 220vp，而不是给一个会顶出屏幕的定值。
   * ★ 必须声明在**本 struct**：TapLayer 是本组件的 @Builder，而常量原先声明在 ReaderView 上是
   *   private static —— 跨 struct 取别人的 private 成员在 ArkTS 严格模式下就是访问权限错误
   *   （补丁 C 搬的就是这一处）。static 成员写在 @Component struct 内是仓内既有做法
   *   （先例 = ReaderView.SLIDER_JUMP_DEBOUNCE_MS）。
   */
  private static readonly TAP_CENTER_H: number = 220;
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
   * 本页的取图入参（s18 第 5 条 e-hentai 修复的下游）：插件页对象 extern 的 JSON 串，
   * 无 extern 的插件与全部内置图源恒空串。必须由**页**带下来：e-hentai 这类图源整章
   * 各页 url 逐字节相同（哨兵地址），真正区分一页的是这份 extern，丢了它 = 第 2 页命中
   * 第 1 页的图。透传口径与 ImageCache.pageKey(:1363) 一致（空串就不参与键）。
   */
  @Prop pageExt: string = '';
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
   * 阅读区可视宽度（vp）：与 viewportH 同一处 onAreaChange 实测后传下来。s17 专用 ——
   * 「尺寸已知而位图未到」的行要把骨架铺满整行，而那一行的高是 aspectRatio 从**父容器给的宽度**
   * 推出来的，组件内部拿不到这个宽度（Stack 自身高度由 aspectRatio 反推，属被定义方）。
   * 所以骨架高 = viewportW / 真实比，与 aspectRatio 落出的行高是同一个式子、同一次求值，
   * 差值只剩下面那条固定细缝 —— 不需要组件自己量自己（BUG6 那条「实测反哺自身布局」的坑）。
   */
  @Prop viewportW: number = 0;
  /**
   * 手动重试信号（s16 第 2 条丁）：屏中热区落在「最后一次取图失败」的当前页时，父组件 tapCenter
   * 把「本页尺寸键加 @ 加 自增序号」推进 READER_RETRY_KEY；本组件只在信号前缀是自己尺寸键时清态重取。
   * 尾巴带序号 = 同一个键连点两次也是两个新值，否则第二次推送值不变、@Watch 不触发（点了没反应）。
   * s27 改造：热区已从父组件的行盒下沉进本组件容器（见下面三枚回调属性与 TapLayer），
   * 本组件仍刻意不自己挂 onClick —— 可见文案画在这里，事件入口统一只留 TapLayer 一处。
   * 键名与模块级 READER_RETRY_KEY 同串（装饰器入参本仓只用字面量，探针有断言核这两处一致）。
   */
  @StorageProp('readerRetryKey') @Watch('onRetrySignal') retrySignal: string = '';
  // s27 黑区修法 R1：点按热区从父组件的行盒 Stack 下沉进本组件容器。
  // 原先挂在行盒上时，那三列 .height('100%') 的透明热区把**行盒**撑大了 —— 行盒只有
  // .width('100%') 没有确定高，height('100%') 取到的是 List 给 ListItem 的高度约束 = 可视高
  // （真机 vh=844），于是每行都被撑成一整屏，行内 Image 走 Contain 就在上下各留一截阅读区
  // 底色（= 用户报的黑区；真机同页配对读数 gap=676@p2、rowBox=844/vh=844）。
  // 点按语义一字未动：三列仍分别回调父组件的 tapSide(false) / tapCenter() / tapSide(true)。
  onTapPrev: () => void = () => {};
  onTapCenter: () => void = () => {};
  onTapNext: () => void = () => {};
  @State pm: image.PixelMap | undefined = undefined;
  @State failed: boolean = false;
  /**
   * 解码前量到的真实宽高比（s16 第 2 条乙，lead 追加 D2）。必须做成 @State 而不是只写进尺寸表：
   * 探针回来时位图还没解码，若行高只读那张静态表，表变了 build 也不会重跑，
   * 行会一直停在窄骨架直到解码完成 —— 等于「首次布局仍是估高」，跳动一点没少。
   * 换 url 与重试信号两处复位（否则 Swiper/LazyForEach 复用节点会把上一页的比例带到下一页）。
   */
  @State preRatio: number = 0;
  /**
   * s21 黑区修法：本行**当前真正持有**（已 retain、还没 unpin）的位图，与 @State pm 分开存：
   * pm 是给 build 用的渲染输入，held 是配对账本 —— 只有经 setShown 走一遍才能保证
   * retain/unpin 严格一次对一次（直接赋 pm 的旧写法没有任何记账点）。
   */
  private held: image.PixelMap | undefined = undefined;
  /** at= 探针的去重位：同一个位图实例只补一次挂载态探针。 */
  private probedPm: image.PixelMap | undefined = undefined;
  /** 页计数的本组件台账：记的是哪个 url、当前算在哪一档（见 mark） */
  private tallyUrl: string = '';
  private tallyKind: number = ReaderDiag.K_NONE;

  /**
   * s21 黑区修法：位图挂载/摘除的唯一入口。先 retain 新的再 unpin 旧的，再把新值喂给 @State，
   * 保证「Image 正在画的这一张」在画期间 ImageCache 绝不 release 它。
   * 旧缺陷：LRU 淘汰与「清理图片缓存」都会对屏上位图 release，Image 于是画整幅纯黑 ——
   * 不抛异常、无日志，且 probeBlack 早在解码阶段跑完，blk= 永远查不出（同批修法见 ImageCache.ets）。
   * 顺序要点：retain 新值在前、unpin 旧值在后，同实例重挂（命中缓存翻回本页）时计数不会瞬间归零。
   */
  private setShown(next: image.PixelMap | undefined): void {
    const prev: image.PixelMap | undefined = this.held;
    if (next !== undefined) {
      ImageCache.getInstance().retain(next);
      this.held = next;
      // s21：挂载态补一次黑图探针（每实例一次），与 blk= 的「只探首次解码」互补
      if (this.probedPm !== next) {
        this.probedPm = next;
        ImageCache.probeShown(next);
      }
      // s25 纯探针批次（3）+（4）：延迟一次复检（late=）并采上下边缘（edge=）。
      // 排期条件是「换了另一张位图」而不是「重新挂载」—— 同一张重复复检没有新信息，还会把计数灌虚。
      if (this.lateProbedPm !== next) {
        this.lateProbedPm = next;
        if (this.lateTimer >= 0) {
          clearTimeout(this.lateTimer);
        }
        this.lateTimer = setTimeout((): void => {
          this.lateTimer = -1;
          const pmNow: image.PixelMap | undefined = this.held;
          if (pmNow === undefined) {
            return;
          }
          ImageCache.probeShownLate(pmNow);
          ImageCache.probeEdges(pmNow);
        }, ReaderPageImage.LATE_PROBE_MS);
      }
    } else {
      this.held = undefined;
    }
    this.pm = next;
    if (prev !== undefined && prev !== next) {
      ImageCache.getInstance().unpin(prev);
    }
  }

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    // s16 第 2 条（丁）：自动重试挂在延迟窗上，节点销毁后回调仍会跑并改已销毁组件的状态
    if (this.retryTimer >= 0) {
      clearTimeout(this.retryTimer);
      this.retryTimer = -1;
    }
    // s25：延迟复检同理必须在节点销毁前取消（回调里读 this.held，销毁后再跑属未定义行为）
    if (this.lateTimer >= 0) {
      clearTimeout(this.lateTimer);
      this.lateTimer = -1;
    }
    // s21 黑区修法：节点销毁 = 这一行不再上屏，归还持有（否则 pinLive 只涨不落）
    this.setShown(undefined);
  }

  /** Swiper 会复用节点，url 变更必须重新解码，否则翻页出现上一张图（串图） */
  onUrlChanged(): void {
    this.clearRetryTimer();
    this.autoRetried = false;
    this.setShown(undefined);
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
    this.setShown(undefined);
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
  /**
   * s17：骨架铺满整行时上下各留的细缝（vp，合计 = 本常量）。留缝的两个理由：
   * ① 骨架带 1vp 描边，紧贴邻居时两条描边并成一条看不出页界；② 位图到达换成图片时
   * 边界有一次极小的位移（6vp），不至于让人眼看到「块在动」。这条缝就是 bareVoidMax 的期望上限。
   */
  static readonly SKELETON_FILL_INSET: number = 6;
  /** 骨架块的地板高（vp）：行高被算得极小（父宽未量到 + 极矮视口）时兜住可见性，不至于缩成一枚点 */
  static readonly SKELETON_MIN_BLOCK_H: number = 56;
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
   * s25 纯探针批次（3）：挂载后延迟复检的计时器与已复检过的那张位图（每实例每张一次）。
   * 复检只走 ImageCache.probeShownLate / probeEdges，不改任何渲染输入。
   */
  private lateTimer: number = -1;
  /** 已排过延迟复检的那张位图；换图才重新排一次（同图重挂不重复排期） */
  private lateProbedPm: image.PixelMap | undefined = undefined;
  /** 延迟复检的等待时长（ms）：短到能在「慢滑看到黑洞」之前拿到读数，长到越过解码与挂载那一帧 */
  private static readonly LATE_PROBE_MS: number = 700;
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
      // 真比来源只有 knownRatio() 这一处定义（s17 收口）：探针优先、尺寸表其次。
      // 行高（本方法）与骨架高（pendingRowH 走同一枚）因此**结构上不可能**各拿一套来源 ——
      // 两处各自枚举来源迟早会因一次改动错位一次，错位的现场正是 s17 那条黑区。
      // 档位标签仍分两档打：探针命中刻意不计 sizeHits（那枚统计的是「重挂时命中此前登记过的尺寸」，
      // 与探针命中混在一起会让 17 号行 hit= 失去意义，探针命中另有 probe= 一档）。
      const r: number = this.knownRatio();
      if (r > 0) {
        if (this.preRatio > 0) {
          ReaderDiag.lastShownRatio = 'probe ' + fixed2(r);
        } else {
          // 乙 命中：这一页以前解出来或量到过（LazyForEach 回收重挂、切档重建、翻回上一页），按真比排行
          ReaderDiag.sizeHits += 1;
          ReaderDiag.lastShownRatio = 'size-key ' + fixed2(r);
        }
        return r;
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
      // s21 黑区修法：位图在手却量不到尺寸，最主要成因就是它已被缓存 release ——
      // 这是「屏上位图被释放」唯一的可观测指纹（Image 侧只画纯黑不抛给 UI 线程）。
      ReaderDiag.pmDead += 1;
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
    return this.knownRatio() > 0;
  }

  /**
   * 本行**位图未到手时**能用的真实宽高比（s17 收口：行高与骨架高唯一共用的来源）。
   * 两条来源按优先级：① 解码探针量到的 preRatio（本行本次挂载量到的）；② 进程级尺寸表里
   * 这一页（尺寸键 = 章节id 加 # 加 页码）以前量到过的值。都没有则返回 0 = 尺寸未知。
   * 刻意纯读、不计数、不改状态：aspect()（排行高）、ratioKnown()（选分支）、
   * pendingRowH()（排骨架高）三处都要问它，任何一处计数就会把 hit= 打成渲染次数。
   */
  private knownRatio(): number {
    if (this.preRatio > 0) {
      return this.preRatio;
    }
    return ReaderDiag.pageRatio(this.sizeKey());
  }

  /**
   * 占位态（位图未到）这一行的行高（s17）：必须与 build 的两个分支逐一对齐，
   * 因为骨架高要从它减出来 —— 两者不同源就必然留出裸底色，那正是黑区。
   * 真比档 = 容器宽 / 真实比（build 走 .width('100%') 加 .aspectRatio(真比)，
   * 而 aspectRatio 的落高 = 父给的宽 / 比例，父宽就是父组件 onAreaChange 实测的 areaW，
   * 所以这里用 viewportW / 真比 复算同一个数；父宽还没量到（viewportW<=0）时退回窄骨架，
   * 宁可得矮一点也不会留出裸底色（骨架高随后取小，不会超过行高）。
   * 失败行永远窄骨架高（丁 的「失败行不得占一屏」判据优先于本条）。
   * 调用面（探针有一条静态断言核它，注释与代码背离正是 s16 那轮抓出的缺陷形态）：本方法只在
   * pm 未到手时被 skeletonBlockH 调用 —— 位图在手那一支画的是图片本身、没有骨架，
   * 所以不必为 pm 情形定义「占位行高」。
   */
  private pendingRowH(): number {
    if (!this.fitHeight) {
      // 横向档 build 走 height('100%')，行高恒 = 阅读区高；量不到就退回窄骨架口径
      return this.viewportH > 0 ? this.viewportH : this.skeletonHeight();
    }
    if (this.failed) {
      return this.skeletonHeight();
    }
    const r: number = this.knownRatio();
    if (r > 0 && this.viewportW > 0) {
      return this.viewportW / r;
    }
    return this.skeletonHeight();
  }

  /**
   * 骨架块的高（s17 核心）：铺满占位行的行高、只留上下各一条固定细缝。
   * 旧口径恒 120vp 居中，于是「尺寸已知而位图未到」的行上下各留 (行高-120)/2 的裸底色 ——
   * 真机竖页比 0.62 到 0.71 时那一整段是 412 到 488vp（约半屏）纯黑，且**长度只随各源真实比变**，
   * 用户实测 pic 与 jm 黑区长短不同正是这个式子。位图到达换成图片时几何零变化 = 不跳。
   * 顺带把 bareVoidMax 记进诊断（取最大值，幂等抗重复渲染）：真机读 bare= 就直接量到残余黑边，
   * 期望恒等于 2 x SKELETON_FILL_INSET = 12vp，任何大于它的值 = 骨架没铺满 = 黑区回归。
   */
  private skeletonBlockH(): number {
    const row: number = this.pendingRowH();
    const want: number = row - ReaderPageImage.SKELETON_FILL_INSET * 2;
    let h: number = want;
    if (h < ReaderPageImage.SKELETON_MIN_BLOCK_H) {
      // 地板也不能超过行高本身：横屏/分屏下窄骨架只有 viewportH/4（视口 400vp 时是 100vp），
      // 盲目抬到地板会让骨架高出这一行、画到邻居身上。Stack 不裁子节点，越界就是叠字。
      h = ReaderPageImage.SKELETON_MIN_BLOCK_H > row ? row : ReaderPageImage.SKELETON_MIN_BLOCK_H;
    }
    const bare: number = row > h ? row - h : 0;
    if (bare > ReaderDiag.bareVoidMax) {
      ReaderDiag.bareVoidMax = bare;
    }
    return h;
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
      const r: number = await ImageCache.getInstance().loadSize(probeUrl, this.sourceId, this.chapterId, this.pageExt);
      if (!(r > 0)) {
        return;
      }
      ReaderDiag.sizeProbeHits += 1;
      // 探针量到的也是「这一页的真实宽高比」，与解码后量到的同性质，一并登记进尺寸表：
      // 于是本页之后任何一次重挂（回收、切档、翻回来）都能不走解码就按真比排行。
      // 登记走 rememberPageRatio 的首次为准语义，解码后 pm 再量一次同值也不会打架。
      ReaderDiag.rememberPageRatio(key, r);
      // 晚到的探针只允许写回「同一页」：哨兵地址图源上整章 url 逐字节相同，光比 url 已经证明不了
      // 这一行还是发探针时那一页（复用节点会 url 不变而 pageNo 变），所以页键也要一起核。
      if (this.url === probeUrl && this.sizeKey() === key) {
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
    // 两张表都按页身份定键（s18，理由见 failedUrls / inFlight 各自的注释块）：哨兵地址图源上
    // 按 url 记会把一页的失败/在途摊到整章，是静默的连锁错。键就是尺寸键同一处定义。
    const pk: string = this.sizeKey();
    ReaderDiag.noteInFlight(pk);
    try {
      // 先量尺寸再取位图（顺序不能倒：倒了就是「首次布局按估高、解码完才跳」的旧链路）。
      // 探针自身把异常全吞了（见 probeSize 第 ④ 条闸门），放不进 catch 也不会把行判成取图失败。
      await this.probeSize();
      const map: image.PixelMap = await ImageCache.getInstance()
        .loadPage(this.url, this.sourceId, this.chapterId, this.pageExt);
      this.setShown(map);
      ReaderDiag.noteOk(pk);
      this.mark(ReaderDiag.K_SHOWN);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Reader] decode failed: code=${e.code} msg=${e.message}`);
      this.failed = true;
      ReaderDiag.noteFailed(pk);
      this.mark(ReaderDiag.K_FAILED);
      // 丁 首次失败自动补一次（限频见 scheduleAutoRetry）：真机 pfail=27 里相当一部分是单帧并发把
      // 图源打爆的瞬时失败，用户什么都没做也只是慢，不该让他一格一格点
      this.scheduleAutoRetry();
    } finally {
      // 登记点在上面（探针之前），摘点放 finally：探针、取图、解码任一环节抛出都照样摘掉，
      // 不会留下永挂在途的地址把后续预取永久挡掉。空 url 那条早退在登记之前，本来就没登记过。
      ReaderDiag.noteNotInFlight(pk);
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
          // s27：热区在下沉后的本组件内，量的是本容器的确定高，不再是行盒
          this.TapLayer()
        }
        .width('100%')
        .aspectRatio(this.aspect())
        .onAreaChange((_o: Area, n: Area) => {
          // s17 A1（纯度量，不参与布局）：把这一行的实测落高记进诊断
          ReaderDiag.noteRowH(Number(n.height), true, this.sizeKey());
        })
      } else {
        // 甲 窄骨架行（尺寸未知 = 位图没到且这一页没登记过尺寸）：固定窄高，**不走 aspectRatio**。
        // 旧口径在这里也走 aspectRatio，值取「同章中位数或 0.75」，于是未解码行按约 1.33 屏排高，
        // 行内纯黑底加一枚 32vp 转圈 = 用户报的「两图之间大片黑色填充」（判据：<= 1/4 屏）。
        // 这里 Body() 渲染的就是骨架（pm 为 undefined 那条分支），两档共用一份 Body 不复制样条。
        Stack({ alignContent: Alignment.Center }) {
          this.Body()
          this.PageBadge()
          // s27：热区在下沉后的本组件内，量的是本容器的确定高，不再是行盒
          this.TapLayer()
        }
        .width('100%')
        .height(this.skeletonHeight())
        .onAreaChange((_o: Area, n: Area) => {
          // s17 A1（纯度量，不参与布局）：把这一行的实测落高记进诊断
          ReaderDiag.noteRowH(Number(n.height), true, this.sizeKey());
        })
      }
    } else {
      // 横向档（现役语义不动）：一页一屏，图在屏内 Contain 居中；高度语义保持 height('100%')。
      Stack({ alignContent: Alignment.Center }) {
        this.Body()
        this.PageBadge()
        // s27：横向档同样进容器（外层 Stack 本就有 height('100%')，行为与画面均不变）
        this.TapLayer()
      }
      .width('100%')
      .height('100%')
      .onAreaChange((_o: Area, n: Area) => {
        // s17 A1（纯度量，不参与布局）：把这一行的实测落高记进诊断
        ReaderDiag.noteRowH(Number(n.height), false, this.sizeKey());
      })
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
      // 「点按重试」的可见文案画在这里，事件入口 = 本组件自己的屏中热区（s27 下沉后的 TapLayer
      // 中列，行为仍回到父组件 tapCenter）—— 一个组件内只保留一处热区，不再叠第二层。
      this.Skeleton()
    }
  }

  /**
   * 未就绪/失败行的占位内容（s16 第 2 条甲与丁）。
   * **s21 第 3 条（用户拍板）：只留转圈，去掉下面的卡片** —— 原来这枚 Column 带 Theme.dCard 铺底 +
   * Theme.dDivider 描边 + 圆角 + 92% 宽，本意是「别露一整块纯黑」，真机上反而变成第二个视觉缺陷：
   * 卡片永远比行矮，上下各露出一截阅读区底色（bare= 量的就是这个），且浅灰卡片压在纯黑上像图片
   * 被切了一刀。现在只留居中的 LoadingProgress / 失败文案，卡片本体不再画。
   * 行高链（pendingRowH -> skeletonBlockH）**原样保留**：占位行仍按「宽/真比或窄骨架」占位，
   * 位图到达时几何零变化，不会因为去掉卡片而重新引入跳动。
   * 判读连带更新（务必同步 _tmp/s17/ACCEPT.md 第七段）：去掉铺底后 bare=（裸底色最大值）
   * 不再是「恒 12」这条安全判据，而退化成占位行高与块高之差的观测值；
   * 黑区是否修好改看 17 号行新增的 dead= 与 16 号行的 pin=（屏上位图被 release 的指纹），
   * 以及 17 号行 rowH= / rowBox= 之差（行盒被撑高那条嫌疑）。
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
    .height(this.skeletonBlockH())
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
  /**
   * s27 黑区修法 R1：三列点按热区（左/中/右），由父组件原先挂在行盒上的那两枚 @Builder 逐字
   * 变换而来 —— 只把 tapSide(false) / tapCenter() / tapSide(true) 换成下面三枚回调属性，列结构、
   * layoutWeight(1)、height('100%')、Transparent、onClick 全部原样。唯一区别是**挂载位置**：这里的
   * 外层容器有 aspectRatio 或显式 height 定出的确定高，height('100%') 只解析成本行自己的尺寸，
   * 不再把行盒撑大。仍排在 Body 与 PageBadge 之后 = 命中层级与旧版逐列一致。
   */
  @Builder
  TapLayer() {
    Row() {
      // 三列宽度（s31 第 4 条）：左 30% / 中 40% / 右 30%（原先三等分 = 中列最多 1/3 屏宽，
      // 中心热区跟着受限）。左右各留 30% ≈ 115vp，翻页照样好点。
      Column()
        .width('30%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          ReaderDiag.tapHits += 1; // s27 判代 + 回归双用
          this.onTapPrev();
        })

      // 中列 = 纯容器（自身不挂 onClick ⇒ 不吞事件），真正的命中面是居中的一块矩形热区：
      // s30 第 6 条「点击区域中心一定面积的区域内设置才弹出，再点一下中心，关闭设置」；
      // s31 第 4 条按真机反馈把它放大成「中列整宽 × TAP_CENTER_H」= 约 154×220vp（原 96×96）。
      // 竖向给 TAP_CENTER_H、横向 width('100%') 撑满中列 ⇒ 热区四边都在父 Stack 内。
      // 背景仍写 Transparent —— s27 真机验证过「透明背景 + 空容器 + onClick」在 ArkUI 上可命中，
      // 空 Column 不给背景则不参与命中，这两点是这套热区能用的前提，别顺手删。
      Stack({ alignContent: Alignment.Center }) {
        Column()
          .width('100%')
          .height(ReaderPageImage.TAP_CENTER_H)
          .borderRadius(16)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            ReaderDiag.tapHits += 1; // s27 判代 + 回归双用（s30 起只统计中心小块，见 ReaderDiag.tapHits 注释）
            this.onTapCenter();
          })
      }
        .layoutWeight(1)
        .height('100%')

      Column()
        .width('30%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          ReaderDiag.tapHits += 1; // s27 判代 + 回归双用
          this.onTapNext();
        })
    }
    .width('100%')
    .height('100%')
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
  /** 底栏/抽屉贴底部安全区用（AppStorage 键由 EntryAbility 写入，口径同 BreezeBottomTab） */
  @StorageProp('bottomSafeHeight') bottomSafe: number = 0;
  /** 浮层配色跟全局深浅色（阅读器正文区恒黑底，但抽屉与设置卡片要跟系统） */
  @StorageProp('isDark') isDark: boolean = false;
  /**
   * 阅读模式的响应式副本（s13 第 6 条）：初值在 aboutToAppear 从偏好灌进 AppStorage，
   * 之后只由「更多页选项」或本文件的 applyScrollMode 改写 ⇒ 阅读器还活着时改档也能立刻翻档。
   */
  @StorageProp('readerScrollMode') @Watch('onScrollModeStorage') scrollMode: string = ReadScrollMode.PAGER;
  /**
   * 方向与「放大后点按平移」两档（五项轮）：原先只在 aboutToAppear 读一次，改档要重进阅读器。
   * 阅读器内设置面板要能即时改这两档 ⇒ 照 scrollMode 那套补 AppStorage 副本 + @Watch。
   */
  @StorageProp('readerDirection') @Watch('onDirectionStorage') dirPref: string = ReadDirection.LTR;
  @StorageProp('readerTapPan') @Watch('onTapPanStorage') tapPanPref: boolean = false;
  /**
   * **横向档（Pager）**的页表与取图入参（同下标成对，五项轮之后仍是"一次一章"）：
   * 无缝转场只在纵向档做（上游同样只给条漫做，reader_seamless_cubit 只挂 Column 档），
   * 所以这两枚数组不需要承载跨章身份；纵向档的渲染条目走 webtoonSource 里的 PageRef。
   */
  @State urls: string[] = [];
  /**
   * 与 urls **同下标**的取图入参表（s18 第 5 条）。刻意不做 @State：它不参与任何渲染判定，
   * 只在 loadPage/loadSize 的调用点按下标取用（口径同那条「参与 UI 判定的忙闲态必须是 @State」——
   * 反过来不参与渲染就不必挂装饰器）。与 urls 的唯一写入点是 loadChapterAt 里那一次成对赋值，
   * 换章节 = 两个数组一起换，不存在「urls 新、exts 旧」的中间态。
   */
  private pageExts: string[] = [];
  /**
   * 纵向档当前**渲染流**里的全部格子（五项轮）。与 urls 的分工：urls 只管横向档那一章，
   * 这一枚管纵向档整条流（本章 + 已追加的邻章）。不挂 @State：渲染由 LazyForEach + IDataSource
   * 驱动，挂 @State 反而会让框架在 append 时整表重排（与无缝相反）。
   */
  private cells: PageRef[] = [];
  @State pageIndex: number = 0;
  @State chapterName: string = '';
  /** 实际打开的章节 id（用于落库进度；入参 chapterId 为空时取首章） */
  @State currentChapterId: string = '';
  @State loading: boolean = true;
  @State errorMsg: string = '';
  /**
   * 顶栏 + 底栏的显隐（s30 第 6 条改默认值 = false）：用户裁定「设置默认沉浸，不要影响阅读」⇒
   * 进阅读器两栏都不出，点画面中心那一小块才出（见 tapCenter 与 ReaderPageImage 的中心热区）。
   * ★ 与 s27 那批装机包的判代无关，纯粹是产品口径：chrome 常驻既挡阅读又是 #5 那个全屏遮挡层的开关。
   */
  @State chromeVisible: boolean = false;
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
   * 章节表与当前章下标（五项轮新增）：原先章节表只是 loadPages 里的局部变量，
   * TOC 跳转 / 上下章 / 无缝转场三件事都需要它常驻状态。下标语义 = chapters 的 0 起下标，
   * -1 = 还没定位（加载失败或加载中）。
   */
  @State chapters: ChapterInfo[] = [];
  @State chapterIndex: number = -1;
  /**
   * 阅读器内浮层两枚开关（五项轮）：设置面板 / 章节目录，都是根 Stack 上的兄弟层
   * （全仓统一做法，理由见 SettingPage 的 UaOverlay 注释：ClickEvent 无 stopPropagation，
   * 遮罩与卡片必须是兄弟节点才能各收各的点按）。底栏不另设开关 = 跟 chromeVisible 一起显隐，
   * 与上游 isMenuVisible 同时驱动顶栏底栏的语义一致。
   */
  @State settingsVisible: boolean = false;
  @State tocVisible: boolean = false;
  /** 自动阅读（五项轮）：开关只在本章内有效（切章即停，见 loadChapterAt），速度进 UserSettings 持久化 */
  @State autoReadOn: boolean = false;
  /** 自动阅读计时器句柄；-1 = 空闲。aboutToDisappear 必须清（口径同 webtoonSaveTimer） */
  private autoReadTimer: number = -1;
  /** 进度滑杆的「挪档后 300ms 才真跳」定时器（上游 _jumpDebounce 的对应物，见 onSliderChange 注释） */
  private sliderJumpTimer: number = -1;
  private static readonly SLIDER_JUMP_DEBOUNCE_MS: number = 300;
  /**
   * 自动阅读速度（五项轮，口径**照抄上游** reader_auto_read_controller.dart:111-119：
   * 速度 = 「每 intervalMs 走 distance% 视口高」两参数，不是"秒每张"的显式档）：
   * 竖向默认 1600ms / 72%（界 300–5000 / 10–100），横向 = 纯定时翻页默认 3000ms（界 800–10000）。
   * 存库不存"档位下标"，存实际值 ⇒ 以后调界不作废老数据。
   */
  @State autoReadIntervalMs: number = ReaderView.AUTO_READ_INTERVAL_DEFAULT;
  @State autoReadPagerIntervalMs: number = ReaderView.AUTO_READ_PAGER_INTERVAL_DEFAULT;
  @State autoReadDistancePct: number = ReaderView.AUTO_READ_DIST_DEFAULT;
  /** 自动阅读速度档（横向秒/页旧暂定口径已废，改上游两参数制；常量保留给校验用） */
  private static readonly AUTO_READ_INTERVAL_DEFAULT: number = 1600;
  private static readonly AUTO_READ_INTERVAL_MIN: number = 300;
  private static readonly AUTO_READ_INTERVAL_MAX: number = 5000;
  private static readonly AUTO_READ_PAGER_INTERVAL_DEFAULT: number = 3000;
  private static readonly AUTO_READ_PAGER_INTERVAL_MIN: number = 800;
  private static readonly AUTO_READ_PAGER_INTERVAL_MAX: number = 10000;
  private static readonly AUTO_READ_DIST_DEFAULT: number = 72;
  private static readonly AUTO_READ_DIST_MIN: number = 10;
  private static readonly AUTO_READ_DIST_MAX: number = 100;
  /** 滑杆拖动中的页码（-1 = 未拖动）：Moving 期间只写它，不碰 pageIndex（避免与 Swiper 打架） */
  @State sliderPage: number = -1;
  /** 纵向档 List 是否已挂载：已挂载时 jumpToIndex 需立刻消费 pendingJump（见 jumpToIndex 注释） */
  @State webtoonReady: boolean = false;
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
  /**
   * 最后一次**手指按在滚动区上**的时刻（自动阅读的让位判据用，见 autoTick）。
   * 刻意用 onTouch 而不是 onDidScroll：onDidScroll 也会被自动阅读自己的 scrollBy 触发，
   * 用它判"用户在滚"会让定时器每 tick 都被自己挡掉 = 自动阅读永不生效。
   */
  private lastUserTouchAt: number = 0;
  /**
   * 无缝转场的在途闸门（五项轮）：一次只允许一章在拉。上游用两枚 Set
   * （loadingChapterOrders / prefetchingChapterOrders）做同一件事，因为它是按 order 任意预取；
   * 我方同一时刻只可能追加紧邻的下一章，一枚布尔就够，且**必须是实例字段不能是局部变量** ——
   * onScrollIndex 在阈值区内会连触好几帧，没有这道闸就是同一章并发拉两次。
   */
  private seamlessAppending: boolean = false;
  /**
   * s31 第 2 条：从「贴底」这条驱动已经连续追加了几轮（封顶用）。
   * 判据 = SEAMLESS_CHAIN_MAX，归零点 = onWebtoonScrollIndex 里画面真推进的那一刻。
   * 必须放实例字段不能放局部变量 —— 它要跨多次 onReachEnd 回调累计（口径同 seamlessAppending）。
   */
  private seamlessChainRounds: number = 0;
  /** 上一次贴底追加当时的页码；观察到的页码超过它 = 画面真推进了 ⇒ 轮次归零。-1 = 无 */
  private bottomAnchorIndex: number = -1;
  /** 上一次贴底追加的时刻（0 = 从未；BOTTOM_APPEND_COOLDOWN_MS 的节流基准） */
  private lastBottomAppendAt: number = 0;
  /** 「延后一拍复核贴底」的一次性计时器；-1 = 空闲。销毁口径同 webtoonSaveTimer */
  private touchBottomRetryTimer: number = -1;

  private swiperController: SwiperController = new SwiperController();
  /** 放大判定的死区：缩放回到 1 附近就恢复「点按翻页」，别留 1.0000001 的尾巴 */
  private static readonly ZOOM_EPS: number = 0.02;
  /** 纵向档落库节流窗口：一屏滚到底最多写一次库 */
  private static readonly WEBTOON_SAVE_DEBOUNCE_MS: number = 800;
  /**
   * 无缝转场的追加阈值（**章内剩余页数**，不是渲染流剩余条数）。上游是两个阈值
   * _nextPrefetchThreshold=2 / _nextAutoResolveThreshold=1（reader_seamless_cubit.dart:62-63）：
   * 前者只预取章节信息、后者才真加载并拼接。我方没有「预取章节信息」这一层（chapters 表
   * 进页就已在手，不像上游要先按 order 回源解析），所以两层合成一层 = 取 2：
   * 距本章还剩 2 页就发邻章请求，走到章尾那一屏时邻章基本已到 = 手感是「无缝」的；
   * 取 1 则请求发在最后一屏，弱网下必然还是撞到空白。
   */
  private static readonly SEAMLESS_APPEND_AHEAD: number = 2;
  /**
   * s31 第 2 条：从「已贴在流末尾」这条驱动连续追加的封顶轮数。
   * 它只在**画面没往前走**时累加（归零点见 onWebtoonScrollIndex 里的 bottomAnchorIndex），
   * 所以挡的是「邻章追加进来了却没把画面撑开」（邻章交了空表只剩壳、坏图 0 高）这一类
   * 死循环，不限制用户实际连读多少章 —— 画面一推进就清零。
   */
  private static readonly SEAMLESS_CHAIN_MAX: number = 5;
  /**
   * 贴底追加的最小间隔 = 「画面撑不开」兜底的节流闸：极端情况下把无界重试压成
   * 每 1.2 秒最多一次请求。正常连读两章之间的间隔远大于一秒，撞不到它。
   */
  private static readonly BOTTOM_APPEND_COOLDOWN_MS: number = 1200;
  /**
   * 「延后一拍再看是否贴底」的等待量。SDK 明写内容不满一屏时 onReachEnd 在首帧就触发
   * 一次（list.d.ts:1646-1647），那一刻布局常未定稿、isAtEnd 不可信 ⇒ 延后一拍复核，
   * 且只复核一拍（不轮询）：还没贴底就当噪声丢掉。
   */
  private static readonly TOUCH_BOTTOM_RETRY_MS: number = 420;
  /**
   * 横向档 Swiper 的 cachedCount（s31 第 3 条）：翻页动画进行中，前一页 / 当前页 /
   * 后一页要同时在场。缓存不够时新页是「边滑进来边解码」= 滑进来的是背景，
   * 真机现象就是自动阅读每翻一页露一帧黑底。SDK 建议 1 到 2（swiper.d.ts:1612、1631）。
   */
  private static readonly PAGER_CACHED_COUNT: number = 2;
  /** 节奏滑杆的刻度（0.1 秒/格）。存储域仍是毫秒，这里只决定滑杆分辨率（s31 第 5 条） */
  private static readonly AUTO_READ_SEC_STEP: number = 0.1;
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
    // 五项轮：方向与平移两档改为「灌进 AppStorage + @StorageProp 订阅」，
    // 口径与 scrollMode 完全一致（灌晚了首帧会闪默认档）
    const dir: string = UserSettings.readDirection();
    UserSettings.pushDirection(dir);
    this.dirPref = dir;
    this.rtl = dir === ReadDirection.RTL;
    const pan: boolean = UserSettings.tapToScroll();
    UserSettings.pushTapPan(pan);
    this.tapPanPref = pan;
    this.tapPans = pan;
    // 自动阅读速度灌值（未设置 = 0 ⇒ 回落各档默认；界内钳一道，脏数据不许把间隔打成 0）
    this.autoReadIntervalMs = UserSettings.clampInt(UserSettings.autoColIntervalMs(),
      ReaderView.AUTO_READ_INTERVAL_MIN, ReaderView.AUTO_READ_INTERVAL_MAX, ReaderView.AUTO_READ_INTERVAL_DEFAULT);
    this.autoReadPagerIntervalMs = UserSettings.clampInt(UserSettings.autoPageIntervalMs(),
      ReaderView.AUTO_READ_PAGER_INTERVAL_MIN, ReaderView.AUTO_READ_PAGER_INTERVAL_MAX, ReaderView.AUTO_READ_PAGER_INTERVAL_DEFAULT);
    this.autoReadDistancePct = UserSettings.clampInt(UserSettings.autoDistancePct(),
      ReaderView.AUTO_READ_DIST_MIN, ReaderView.AUTO_READ_DIST_MAX, ReaderView.AUTO_READ_DIST_DEFAULT);
    // 先把偏好里的档位灌进 AppStorage 再读：@StorageProp 的初值取的就是那个键，
    // 灌晚了首帧会闪一下默认档（冷启动阅读器时最容易看到）
    const mode: string = UserSettings.readScrollMode();
    UserSettings.pushScrollMode(mode);
    this.scrollMode = mode;
    this.loadPages();
  }

  aboutToDisappear(): void {
    // 五项轮：自动阅读的定时器必须跟着销毁（口径同 webtoonSaveTimer，漏了 = 退出阅读器还在翻页）
    this.stopAutoRead();
    // 退出阅读器：取消未落地的节流落库，并补写一次当前页
    // （旧版没有这次补写，纵向档「滚到一半直接退出」会把最后不到 800ms 的进度丢掉）
    if (this.webtoonSaveTimer >= 0) {
      clearTimeout(this.webtoonSaveTimer);
      this.webtoonSaveTimer = -1;
    }
    // s31 第 2 条：贴底复核那枚一次性计时器与它同性质 —— 退出阅读器还留着它，
    // 420ms 后就会在已销毁的组件上调 Scroller（轻则空操作、重则抛错），一并清掉。
    this.clearTouchBottomRetry();
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

  /** 方向被阅读器内面板/设置页改动：即时翻向，不必重进阅读器（五项轮补的口子） */
  private onDirectionStorage(): void {
    this.rtl = this.dirPref === ReadDirection.RTL;
  }

  /** 「放大后点按平移」被改动：tapSide 每次现读 this.tapPans，改完下一跳就生效 */
  private onTapPanStorage(): void {
    this.tapPans = this.tapPanPref;
  }

  /**
   * 自动阅读开关（五项轮）。上游语义照搬 reader_auto_read_controller.dart:71-73：
   * 「关→开」强制解除暂停，所以这里不留上次的暂停态；开/关只影响本页会话，
   * 切章会停（loadChapterAt 里 stopAutoRead），重进阅读器默认关 —— 误开自动翻页
   * 比误关更恼火，刻意不进持久化。
   */
  private setAutoRead(on: boolean): void {
    if (on === this.autoReadOn) {
      return;
    }
    this.autoReadOn = on;
    if (on) {
      // s30 第 4 条：按下开关就退沉浸（收 chrome + 两枚浮层）—— 一是让位判据现在与 chrome 无关，
      // 收栏纯粹为了「别拿工具条挡着自动滚的画」；二是浮层若还开着 autoTick 会让位，收起即开始推进。
      this.chromeVisible = false;
      this.settingsVisible = false;
      this.tocVisible = false;
      this.startAutoRead();
    } else {
      this.stopAutoRead();
    }
  }

  /**
   * 起自动阅读定时器。两档分开（口径同上游 _resolveIntervalMs）：
   * 纵向 = 每 intervalMs 滚 distance% 视口高；横向 = 每 intervalMs 翻一页（无距离量）。
   * 用 setInterval 不用递归 setTimeout：本仓没有帧回调先例（displaySync 零使用），
   * 而"每 tick 让位给用户手势"由 autoTick 自己判（见下），不需要帧级精度。
   */
  private startAutoRead(): void {
    this.stopAutoRead();
    if (!this.autoReadOn) {
      return;
    }
    const ms: number = this.isWebtoon()
      ? UserSettings.clampInt(this.autoReadIntervalMs, ReaderView.AUTO_READ_INTERVAL_MIN, ReaderView.AUTO_READ_INTERVAL_MAX, ReaderView.AUTO_READ_INTERVAL_DEFAULT)
      : UserSettings.clampInt(this.autoReadPagerIntervalMs, ReaderView.AUTO_READ_PAGER_INTERVAL_MIN, ReaderView.AUTO_READ_PAGER_INTERVAL_MAX, ReaderView.AUTO_READ_PAGER_INTERVAL_DEFAULT);
    this.autoReadTimer = setInterval((): void => {
      this.autoTick();
    }, ms);
  }

  private stopAutoRead(): void {
    if (this.autoReadTimer >= 0) {
      clearInterval(this.autoReadTimer);
      this.autoReadTimer = -1;
    }
    // 滑杆的去抖定时器与自动阅读同性质：都是「面板一收/一页翻完就该作废」的挂起动作，
    // 放同一处清，避免切章后 300ms 又跳回旧位置。
    if (this.sliderJumpTimer >= 0) {
      clearTimeout(this.sliderJumpTimer);
      this.sliderJumpTimer = -1;
    }
  }

  /**
   * 毫秒 -> 「多少秒」的展示串（s31 第 5 条：节奏改用秒表达，**存储与取值域仍是毫秒**）。
   * 刻意做成方法而不是塞进 build 的表达式：ArkTS 严格模式不容忍把算术结果直接喂进调用
   * （本仓踩过的那条 Return type Object is not supported），一律先落显式类型局部变量。
   * 尾零口径自洽 = 整秒不带小数（3 秒 / 8 秒），非整秒留一位（0.3 秒 / 1.6 秒 / 2.5 秒）；
   * 全程只用整除与取余，不碰字符串切割类 API，免得再踩类型坑。
   */
  private cadenceText(ms: number): string {
    const tenth: number = Math.round(ms / 100);
    const whole: number = Math.floor(tenth / 10);
    const dec: number = tenth - whole * 10;
    if (dec === 0) {
      return whole + ' 秒';
    }
    return whole + '.' + dec + ' 秒';
  }

  /** 毫秒 -> 秒刻度（Slider 的 value/min/max 用）。同样先落显式类型局部变量再返回 */
  private cadenceSec(ms: number): number {
    const sec: number = ms / 1000;
    return sec;
  }

  /** 秒刻度 -> 毫秒：滑杆 step = 0.1，乘回来本就是 100 的整数倍，Math.round 只收浮点尾巴 */
  private msFromCadenceSec(sec: number): number {
    const ms: number = Math.round(sec * 1000);
    return ms;
  }

  /**
   * 一次自动阅读推进。三条让位（上游 canTick = !isMenuVisible && !isSliderRolling && !isComicRolling
   * 的 ArkTS 等价，comic_read_auto_read_part.dart:5-20）：
   * ① 设置面板或目录浮层开着（**s30 起顶/底栏不再参与**，理由见下面函数内注释）
   * ② 滑杆正拖着 ③ 这一章还没页（失败或加载中）。
   * 让位 = 这一 tick 什么都不做（不重置定时器），跟上游「直接 return」一致，
   * 用户关掉面板就接着走，不需要重新开一次。
   */
  private autoTick(): void {
    // s30 第 4 条修正：原先这条含 chromeVisible ⇒ 自动阅读开关长在底栏里，开栏才能开自动阅读，
    // 而栏一开就把自己挡死（真机现象 = 点了完全不动）。上游 canTick 里的 isMenuVisible 是浮层语义，
    // 我们的顶/底栏是常驻 chrome，不能当「用户在操作」看 ⇒ 让位只看两枚浮层与拖动/加载。
    if (this.settingsVisible || this.tocVisible) {
      return;
    }
    if (this.sliderPage >= 0 || this.loading || this.pageCount() === 0) {
      return;
    }
    if (this.isWebtoon()) {
      // 用户手指正按在屏幕上（Down/Move 后 240ms 内）就让位：不硬抢他指下的画面。
      // 判据取 onTouch 不取 onDidScroll —— 后者会被本定时器自己的 scrollBy 触发，
      // 用它等于自己把自己挡死（自动阅读永远不动）。
      if (Date.now() - this.lastUserTouchAt < 240) {
        return;
      }
      const step: number = this.areaH * (this.autoReadDistancePct / 100);
      if (step <= 0) {
        return;
      }
      this.webtoonScroller.scrollBy(0, step);
      this.scheduleProgressSave();
      return;
    }
    // s31 第 3 条：原先这条走 jumpToIndex ⇒ 直接写 @State pageIndex ⇒ Swiper 的 .index()
    // 受控跳页 = 无动画硬切，真机现象 = 自动阅读每翻一页露一帧黑底（lead 给的根因判定）。
    // 改走控制器 showNext()（swiper.d.ts:50 @since 7）：它走原生翻页动画，时长由 .duration(200)
    // 决定，动画结束由 onChange 把 index 回写 pageIndex（swiper.d.ts:1869 明写「因动画引起的
    // 索引变化在动画结束时触发」）⇒ 数据只有「动画 -> onChange」单向流，不会和受控属性互灌。
    if (this.pageIndex < this.pageCount() - 1) {
      this.swiperController.showNext();
      return;
    }
    // s31 第 2 条 B：横向档自动阅读走到最后一页 = 接下一章，不再 clamp 在末页干等。
    // 原先「停住等用户重开」的保守口径要和 loadChapterAt 的自动续开（F2-RESUME）配套，
    // 单独上任何一半都不成立：只上这条 = 每翻进一章都要手动重开一次自动阅读。
    this.advancePagerChapter();
  }

  // ---------------- 五项轮：底栏 / 进度滑杆 / 设置面板 / 目录浮层 ----------------

  /**
   * 顶栏与底栏共用的页码串。★ 章内口径（第 k 页 / 本章共 n 页），不是整条渲染流口径：
   * 无缝转场把下一章追加进同一条流之后，用 cells.length 当分母会打出 137/204 这种
   * 用户看不懂的数（上游同理 = getDisplayPageNumber 只吃章内槽位）。
   * 滑杆拖动中（sliderPage >= 0）显示目标页 = 上游「拖动全程联动页码显示」的对应物。
   */
  private pageLabel(): string {
    const total: number = this.pageTotalAt(this.pageIndex);
    if (total <= 0) {
      return '0/0';
    }
    if (this.sliderPage >= 0) {
      const p: number = this.pageNoAt(this.sliderPage);
      const t: number = this.pageTotalAt(this.sliderPage);
      return p + '/' + (t > 0 ? t : total);
    }
    return this.pageNoAt(this.pageIndex) + '/' + total;
  }

  /** 滑杆分母 = 整条渲染流的格数（跨章追加后滑杆覆盖到底栏打开时所见的全流）。 */
  private sliderMax(): number {
    const n: number = this.pageCount();
    return n > 1 ? n - 1 : 0;
  }

  /**
   * 滑杆拖动 = 「挪一档重启 300ms 去抖，到点才真跳」（上游 _jumpDebounce 语义，
   * 不是「松手才跳」）：Begin/Moving 每次触发都重挂定时器，全程只联动页码显示；
   * End/Click 立即收尾跳一次。sliderPage 保持到 End/Click 才清零 = 拖动与刚跳完的
   * 短暂窗口里顶栏都显示目标页。
   */
  private onSliderChange(value: number, mode: SliderChangeMode): void {
    const n: number = this.pageCount();
    if (n === 0) {
      return;
    }
    let page: number = Math.round(value);
    if (page < 0) {
      page = 0;
    }
    if (page > n - 1) {
      page = n - 1;
    }
    this.sliderPage = page;
    if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
      if (this.sliderJumpTimer >= 0) {
        clearTimeout(this.sliderJumpTimer);
        this.sliderJumpTimer = -1;
      }
      this.jumpToIndex(page);
      this.sliderPage = -1;
      return;
    }
    if (this.sliderJumpTimer >= 0) {
      clearTimeout(this.sliderJumpTimer);
    }
    this.sliderJumpTimer = setTimeout((): void => {
      this.sliderJumpTimer = -1;
      this.jumpToIndex(page);
    }, ReaderView.SLIDER_JUMP_DEBOUNCE_MS);
  }

  /**
   * 阅读器内切章的统一入口（TOC 点选 / 上下章键）。带 loading 与失败上屏：
   * loadChapterAt 里 fetchPages 的异常会抛给调用方，这里不接住就是静默失败
   * （s15 那条「用户只看到五个字、真因在 console」的教训同款）。
   */
  private switchChapter(idx: number): void {
    this.tocVisible = false;
    this.settingsVisible = false;
    if (idx === this.chapterIndex) {
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    this.loadChapterAt(idx, false).then((): void => {
      this.loading = false;
    }).catch((err: Object): void => {
      this.loading = false;
      const raw: string = typeof (err as Error).message === 'string' ? (err as Error).message : '';
      this.errorMsg = briefForScreen(raw, '章节加载失败，可点按重试');
      ReaderDiag.noteChapterError(this.errorMsg);
    });
  }

  /**
   * 上下章键：先弹确认再切（上游 JumpChapter 的 AlertDialog 语义 = 阅读器内切章是
   * 不可逆动作，误触代价 = 丢当前页）。TOC 点选不弹（列表里点 = 显式意图）。
   */
  private confirmJumpChapter(idx: number): void {
    if (idx < 0 || idx >= this.chapters.length) {
      return;
    }
    const title: string = this.chapters[idx].title;
    const opts: promptAction.ShowDialogOptions = {
      title: '切换章节',
      message: title,
      buttons: [
        { text: '切过去', color: Theme.brand },
        { text: '取消', color: Theme.text2(this.isDark) }
      ]
    };
    promptAction.showDialog(opts).then((res: promptAction.ShowDialogSuccessResponse): void => {
      if (res.index !== 0) {
        return;
      }
      this.switchChapter(idx);
    }).catch((): void => {
      // 点遮罩会让 Promise 走失败分支，等同取消（SearchPage:531 同口径）
    });
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg.length > 80 ? msg.slice(0, 80) : msg });
  }

  /**
   * 底栏：chromeVisible 的兄弟层（与顶栏同进同退，对齐上游 isMenuVisible 同时喂两栏）。
   * ★ 必须自己包一层 alignContent Bottom 的 Stack：根 Stack 是 TopStart，裸 Row 会贴顶。
   * 五键全用文字（目录/自动两个图标名在 SDK 里没有已验证的先例，不赌）。
   */
  @Builder
  ReaderBottomBar() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column() {
        // 进度滑杆行：滑杆 + 页码（顶栏页码与此同源 = pageLabel()）
        Row({ space: 10 }) {
          Slider({
            value: this.sliderPage >= 0 ? this.sliderPage : this.pageIndex,
            min: 0,
            max: this.sliderMax(),
            step: 1,
            style: SliderStyle.OutSet
          })
            .layoutWeight(1)
            .blockColor(Theme.brand)
            .selectedColor(Theme.brand)
            .trackColor('#40FFFFFF')
            .enabled(this.sliderMax() > 0)
            .onChange((value: number, mode: SliderChangeMode): void => {
              this.onSliderChange(value, mode);
            })
          Text(this.pageLabel())
            .fontSize(12)
            .fontColor(Theme.white)
            .maxLines(1)
        }
        .width('100%')
        .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 6 })

        // 五键行（键宽随屏宽均分，44vp 最小高保证可点）
        Row() {
          Text('上一章')
            .fontSize(13)
            .fontColor(this.chapterIndex > 0 ? Theme.white : '#66FFFFFF')
            .textAlign(TextAlign.Center)
            .height(36)
            .layoutWeight(1)
            .borderRadius(18)
            .backgroundColor('#26FFFFFF')
            .onClick((): void => {
              if (this.chapterIndex > 0) {
                this.confirmJumpChapter(this.chapterIndex - 1);
              }
            })
          Text('目录')
            .fontSize(13)
            .fontColor(Theme.white)
            .textAlign(TextAlign.Center)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .borderRadius(18)
            .backgroundColor('#26FFFFFF')
            .onClick((): void => {
              this.settingsVisible = false;
              this.tocVisible = true;
            })
          Text(this.autoReadOn ? '停止自动' : '自动阅读')
            .fontSize(13)
            .fontColor(this.autoReadOn ? Theme.brand : Theme.white)
            .textAlign(TextAlign.Center)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .borderRadius(18)
            .backgroundColor('#26FFFFFF')
            .onClick((): void => {
              this.setAutoRead(!this.autoReadOn);
            })
          Text('设置')
            .fontSize(13)
            .fontColor(Theme.white)
            .textAlign(TextAlign.Center)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .borderRadius(18)
            .backgroundColor('#26FFFFFF')
            .onClick((): void => {
              // s30 第 6 条：这枚键改幂等 = 面板已开着时再点一下关它（原先只会重复置 true）
              this.tocVisible = false;
              this.settingsVisible = !this.settingsVisible;
            })
          Text('下一章')
            .fontSize(13)
            .fontColor(this.chapterIndex >= 0 && this.chapterIndex < this.chapters.length - 1
              ? Theme.white : '#66FFFFFF')
            .textAlign(TextAlign.Center)
            .height(36)
            .layoutWeight(1)
            .margin({ left: 8 })
            .borderRadius(18)
            .backgroundColor('#26FFFFFF')
            .onClick((): void => {
              if (this.chapterIndex >= 0 && this.chapterIndex < this.chapters.length - 1) {
                this.confirmJumpChapter(this.chapterIndex + 1);
              }
            })
        }
        .width('100%')
        .padding({
          left: Dim.pagePadding,
          right: Dim.pagePadding,
          top: 8,
          bottom: 8 + this.bottomSafe
        })
      }
      .width('100%')
      .backgroundColor(Theme.scrim)
    }
    .width('100%')
    .height('100%')
    // s30 第 5 条（真机缺陷「点击和滑动失效，无法切换到下一页」的根因）：这层是**定位用的全屏容器**，
    // 自身必须退出命中测试。ArkUI 的命中只按 frame 判，透明背景一样算命中（enums.d.ts:3292 起四个成员，
    // @since 9）—— 全屏 frame + Default 就把下面整片阅读区的点按与 List 拖动全截住了。
    // None 的定义原文：节点自身不响应命中，且**不挡子节点**、不挡兄弟与祖先 ⇒ 滑杆与五枚键照常可点，
    // 遮罩区（这层自己）不再吞事件。
    // s30 第 7 条：底栏与顶栏成对（同进同退 ⇒ 时长曲线也同一条）。转场必须挂在这层**被增删的子树根**上
    // （ArkUI 的 transition 只在组件自身增删时触发，挂在里面的工具条 Column 上不会随 if 分支删除而播退场）。
    // 这层 frame 是全屏且透明的，translate y=56 挪的是它整棵子树的渲染位置 ⇒ 观感 = 工具条从屏幕下沿
    // 升起/落回，透明区挪 56vp 不产生任何可见空档（它本来就没画东西，遮罩那格 Column 贴在底部跟着走）。
    .hitTestBehavior(HitTestMode.None)
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 56 }))
      .animation({ duration: Anim.barCollapse, curve: Anim.curveBarCollapse() }))
  }

  /**
   * 设置面板：底部抽屉，全仓「遮罩 + 卡片兄弟层」口径（SettingPage.UaOverlay 同款结构，
   * ClickEvent 无 stopPropagation，遮罩与卡片必须兄弟）。条目全部即时生效 = 上游口径
   * （无「重进生效」项）：写口先推 AppStorage，@Watch 立刻翻档。
   * 与上游的差距如实登记：上游是四 tab 大面板（60+ 项含逐书偏好/背景四档/滤镜），
   * 本轮只做阅读器最常用五组，其余留 T4 后续档。
   */
  @Builder
  SettingsOverlay() {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick((): void => {
          this.settingsVisible = false;
        })
      Column({ space: 14 }) {
        Text('阅读设置')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)

        // 滚动方式（两档，即时切档 = @Watch + applyScrollMode）
        Column({ space: 8 }) {
          Text('滚动方式')
            .fontSize(13)
            .fontColor(Theme.text3(this.isDark))
            .width('100%')
            .textAlign(TextAlign.Start)
          Row({ space: 8 }) {
            ForEach(SettingLabels.READ_SCROLL_MODE, (label: string, idx: number) => {
              Text(label)
                .fontSize(13)
                .fontColor(this.scrollMode === (idx === 0 ? ReadScrollMode.PAGER : ReadScrollMode.WEBTOON)
                  ? Theme.white : Theme.text2(this.isDark))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(16)
                .backgroundColor(this.scrollMode === (idx === 0 ? ReadScrollMode.PAGER : ReadScrollMode.WEBTOON)
                  ? Theme.brand : Theme.fillColor(this.isDark))
                .onClick((): void => {
                  const v: string = idx === 0 ? ReadScrollMode.PAGER : ReadScrollMode.WEBTOON;
                  if (v !== this.scrollMode) {
                    UserSettings.setScrollMode(v).catch((_e: Object): void => {});
                  }
                })
            }, (label: string, idx: number) => 'sm' + idx)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 阅读方向（两档，即时生效 —— 本轮补了 @StorageProp 订阅，SettingPage 的
        // 「重进阅读器生效」旧口径自本项起作废）
        Column({ space: 8 }) {
          Text('阅读方向')
            .fontSize(13)
            .fontColor(Theme.text3(this.isDark))
            .width('100%')
            .textAlign(TextAlign.Start)
          Row({ space: 8 }) {
            ForEach(SettingLabels.READ_DIRECTION, (label: string, idx: number) => {
              Text(label)
                .fontSize(13)
                .fontColor(this.dirPref === (idx === 0 ? ReadDirection.LTR : ReadDirection.RTL)
                  ? Theme.white : Theme.text2(this.isDark))
                .padding({ left: 14, right: 14, top: 7, bottom: 7 })
                .borderRadius(16)
                .backgroundColor(this.dirPref === (idx === 0 ? ReadDirection.LTR : ReadDirection.RTL)
                  ? Theme.brand : Theme.fillColor(this.isDark))
                .onClick((): void => {
                  const v: string = idx === 0 ? ReadDirection.LTR : ReadDirection.RTL;
                  if (v !== this.dirPref) {
                    UserSettings.setReadDirection(v).catch((_e: Object): void => {});
                  }
                })
            }, (label: string, idx: number) => 'dir' + idx)
          }
          .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 放大后点按平移（仅横向档有意义，开关语义与设置页同一条记录）
        Row() {
          Text('放大后点按平移')
            .fontSize(13)
            .fontColor(Theme.text3(this.isDark))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.tapPans })
            .onChange((on: boolean): void => {
              if (on !== this.tapPans) {
                UserSettings.setTapToScroll(on).catch((_e: Object): void => {});
              }
            })
        }
        .width('100%')

        Divider().strokeWidth(0.5).color(Theme.dividerColor(this.isDark))

        // 自动阅读（两参数口径照上游：竖向 = 每 ms 走 pct% 视口高；横向 = 每 ms 翻一页）
        Row() {
          Text('自动阅读')
            .fontSize(14)
            .fontColor(Theme.text1(this.isDark))
            .layoutWeight(1)
          Toggle({ type: ToggleType.Switch, isOn: this.autoReadOn })
            .onChange((on: boolean): void => {
              this.setAutoRead(on);
            })
        }
        .width('100%')

        if (this.autoReadOn) {
          Column({ space: 4 }) {
            Row() {
              Text('步进距离')
                .fontSize(13)
                .fontColor(Theme.text3(this.isDark))
                .layoutWeight(1)
              Text(this.autoReadDistancePct + '%')
                .fontSize(13)
                .fontColor(Theme.text2(this.isDark))
            }
            .width('100%')
            Slider({
              value: this.autoReadDistancePct,
              min: ReaderView.AUTO_READ_DIST_MIN,
              max: ReaderView.AUTO_READ_DIST_MAX,
              step: 1,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .blockColor(Theme.brand)
              .selectedColor(Theme.brand)
              .onChange((value: number, mode: SliderChangeMode): void => {
                const v: number = UserSettings.clampInt(
                  Math.round(value), ReaderView.AUTO_READ_DIST_MIN, ReaderView.AUTO_READ_DIST_MAX,
                  ReaderView.AUTO_READ_DIST_DEFAULT);
                if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                  this.autoReadDistancePct = v;
                  return;
                }
                this.autoReadDistancePct = v;
                UserSettings.setAutoDistancePct(v).catch((_e: Object): void => {});
              })
          }
          .width('100%')

          Column({ space: 4 }) {
            Row() {
              Text(this.isWebtoon() ? '滚动节奏（秒/步）' : '翻页节奏（秒/页）')
                .fontSize(13)
                .fontColor(Theme.text3(this.isDark))
                .layoutWeight(1)
              // s31 第 5 条：读数换成秒（存储仍是毫秒，cadenceText 只做显示层换算）
              Text(this.cadenceText(this.isWebtoon() ? this.autoReadIntervalMs : this.autoReadPagerIntervalMs))
                .fontSize(13)
                .fontColor(Theme.text2(this.isDark))
            }
            .width('100%')
            // s31 第 5 条：滑杆整条刻度换成秒。换算全走 cadenceSec（内部先落显式类型
            // 局部变量再返回），不把算术结果直接写进 SliderOptions 的字段里。
            // 区间端点由毫秒常量换算而来 = 取值域一个字节都没动，老存档继续有效。
            Slider({
              value: this.cadenceSec(this.isWebtoon() ? this.autoReadIntervalMs : this.autoReadPagerIntervalMs),
              min: this.cadenceSec(this.isWebtoon() ? ReaderView.AUTO_READ_INTERVAL_MIN : ReaderView.AUTO_READ_PAGER_INTERVAL_MIN),
              max: this.cadenceSec(this.isWebtoon() ? ReaderView.AUTO_READ_INTERVAL_MAX : ReaderView.AUTO_READ_PAGER_INTERVAL_MAX),
              step: ReaderView.AUTO_READ_SEC_STEP,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .blockColor(Theme.brand)
              .selectedColor(Theme.brand)
              .onChange((value: number, mode: SliderChangeMode): void => {
                const col: boolean = this.isWebtoon();
                // s31 第 5 条：刻度已是秒 ⇒ 第一步就换算回毫秒，后面的钳位、@State、落库、
                // 重启定时器全部沿用原逻辑（持久化键与取值域不变 = 老存档不失效）。
                // 算术结果一律先落显式类型局部变量：直接塞进 clampInt 会撞 ArkTS 的
                // Return type Object is not supported（本仓既有教训）。
                const sec: number = value;
                const ms: number = this.msFromCadenceSec(sec);
                const v: number = col
                  ? UserSettings.clampInt(ms, ReaderView.AUTO_READ_INTERVAL_MIN,
                    ReaderView.AUTO_READ_INTERVAL_MAX, ReaderView.AUTO_READ_INTERVAL_DEFAULT)
                  : UserSettings.clampInt(ms, ReaderView.AUTO_READ_PAGER_INTERVAL_MIN,
                    ReaderView.AUTO_READ_PAGER_INTERVAL_MAX, ReaderView.AUTO_READ_PAGER_INTERVAL_DEFAULT);
                if (col) {
                  this.autoReadIntervalMs = v;
                } else {
                  this.autoReadPagerIntervalMs = v;
                }
                if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                  return;
                }
                if (col) {
                  UserSettings.setAutoColIntervalMs(v).catch((_e: Object): void => {});
                } else {
                  UserSettings.setAutoPageIntervalMs(v).catch((_e: Object): void => {});
                }
                // 开着自动阅读时改节奏 = 立刻按新节奏重启定时器（上游改参数即时重排程）
                if (this.autoReadOn) {
                  this.startAutoRead();
                }
              })
          }
          .width('100%')
        }
      }
      .width('100%')
      .padding({
        left: Dim.pagePadding,
        right: Dim.pagePadding,
        top: 16,
        bottom: 16 + this.bottomSafe
      })
      .backgroundColor(Theme.cardColor(this.isDark))
      .borderRadius({ topLeft: Dim.radius, topRight: Dim.radius })
    }
    .width('100%')
    .height('100%')
    // s30 第 7 条：设置面板 = 底部抽屉，进/退都走下边（位移量给 220vp ≈ 面板本体高度的一截，
    // 比整块高度小是因为整块位移会把遮罩一起拖出屏幕边缘、露出底色）。
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: 220 }))
      .animation({ duration: Anim.barCollapse, curve: Anim.curveBarCollapse() }))
  }

  /**
   * 目录浮层：左侧抽屉。章节序 = fetchChapters 原序（正序，第 0 章 = 第一章；
   * 倒序只是详情页的显示开关，目录与上下游一致保持原序）。
   * initialIndex 直接给到当前章前 2 行：浮层每次都是 if 新建的子树，构造参数必生效，
   * 不需要命令式定位（上游的 ensureVisible + 3 次 reveal 是它在已有列表里找，场景不同）。
   */
  @Builder
  TocOverlay() {
    Stack({ alignContent: Alignment.Start }) {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick((): void => {
          this.tocVisible = false;
        })
      Column() {
        Text('目录（' + this.chapters.length + '）')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text1(this.isDark))
          .width('100%')
          .padding({
            left: Dim.pagePadding,
            right: Dim.pagePadding,
            top: 12 + this.topSafe,
            bottom: 10
          })
          .textAlign(TextAlign.Start)
        List({ space: 0, initialIndex: this.chapterIndex > 2 ? this.chapterIndex - 2 : 0 }) {
          ForEach(this.chapters, (ch: ChapterInfo, idx: number) => {
            ListItem() {
              Row({ space: 8 }) {
                Text(ch.title)
                  .fontSize(14)
                  .fontColor(idx === this.chapterIndex ? Theme.brand : Theme.text1(this.isDark))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (idx === this.chapterIndex) {
                  Text('当前')
                    .fontSize(11)
                    .fontColor(Theme.brand)
                }
              }
              .width('100%')
              .height(Dim.listItemH - 12)
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
              .backgroundColor(idx === this.chapterIndex ? Theme.fillColor(this.isDark) : Color.Transparent)
              .onClick((): void => {
                this.switchChapter(idx);
              })
            }
          }, (ch: ChapterInfo) => ch.id)
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
        .edgeEffect(EdgeEffect.Spring)
      }
      .width('72%')
      .height('100%')
      .backgroundColor(Theme.cardColor(this.isDark))
    }
    .width('100%')
    .height('100%')
    // s30 第 7 条：目录 = 左侧抽屉，进/退都走左边（x 负向 = 从左侧屏幕外进来）。
    // 目录与设置面板互斥（openToc/openSettings 各自关掉对方）⇒ 两条转场不会同帧打架。
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ x: -160 }))
      .animation({ duration: Anim.barCollapse, curve: Anim.curveBarCollapse() }))
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
    const n: number = this.pageCount();
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
    // 五项轮：List 已挂载时（典型 = 滑杆 / TOC 在「活列表」上跳页）initialIndex 不会再被读，
    // 必须立刻消费这次 scrollToIndex；未挂载保持原语义 = 等 onAppear 消费，
    // 切档与进章节两条老路径到达这里时 webtoonReady 都是 false ⇒ 行为一字不变。
    if (this.isWebtoon() && this.webtoonReady) {
      this.consumePendingJump();
    }
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
    if (this.pageCount() === 0) {
      return;
    }
    // 取 center（屏幕中央那一页）：纵向档一屏常跨两三页，取 start 会让页码长期停在
    // 刚露头的那页、看着「比看到的落后一页」，取 end 会跑到还没读的那页。
    // SDK list.d.ts:1605 未写明三值不可见时的哨兵值，所以 center 非法时退回 start。
    let idx: number = center;
    // ★ 三处分母全改成 pageCount()（无缝转场追加后可滚条数已大于本章页数）：继续拿
    // urls.length 判越界会把邻章的 index 一律打回 start = 页码永远回弹到本章第一页，
    // 且进度会记错章（saveProgress 已改成按 pageIndex 取身份）。
    const n: number = this.pageCount();
    if (idx < 0 || idx >= n) {
      idx = start;
    }
    if (idx < 0 || idx >= n) {
      return;
    }
    if (idx !== this.pageIndex) {
      this.pageIndex = idx;
      // s31 第 2 条：画面真往前走了 = 上一轮「贴底追加」已经兑现成可见内容 ⇒ 连续计数
      // 归零。这样 SEAMLESS_CHAIN_MAX 只掐「追加了却撑不开画面」的死循环，
      // 不会把用户连读几十章的正常路径掐掉。
      if (idx > this.bottomAnchorIndex) {
        this.bottomAnchorIndex = idx;
        this.seamlessChainRounds = 0;
      }
      this.scheduleProgressSave();
      // 换页就补一轮预取：onScrollIndex 只在跨页时回调（不是每帧），所以这里发不出几轮，
      // 且 isInFlight 判重会把「行组件已在取」的地址全部挡掉，不会把请求队列灌爆
      this.prefetchAround(idx);
    }
    // 无缝转场的主驱动点：每次跨页都问一次「是否该把下一章拼进来了」，闸门全在
    // tryAppendNextChapter 里（阈值 + 在途去重 + 已追加判定），这里无条件调即可。
    // s31 第 2 条 A：这条只覆盖「跨页那一帧」。人停在最后一屏不再跨页时它一次都不响，
    // 于是最该接下一章的位置反而永远问不到 ⇒ 另加 onReachEnd 这条腿（两者共用同一批闸门，
    // appendFromBottom 只多一道节流与封顶），不会重复发请求。
    this.tryAppendNextChapter();
  }

  /**
   * s31 第 2 条 A：纵向档「已经贴在流的末尾」时的追加驱动（List .onReachEnd 调它）。
   * 根因：onScrollIndex 只在跨页那一帧回调，用户停在最后一屏 = 不再跨页 = 一次都不再问。
   * 三道自己的闸：① 只在纵向档、非加载态、有页时问；② 沿用 autoTick 那条 240ms 让位判据
   * （手指还按着就不抢他指下的画面）；③ 必须**真贴底**（isAtEnd，scroll.d.ts:566 @since 10）
   * —— SDK 明写内容不满一屏时首帧白触发一次（list.d.ts:1646-1647），那一刻不认，延后一拍复核。
   */
  private onWebtoonReachEnd(): void {
    if (!this.isWebtoon() || this.loading || this.pageCount() === 0) {
      return;
    }
    if (Date.now() - this.lastUserTouchAt < 240) {
      return;
    }
    if (!this.webtoonScroller.isAtEnd()) {
      this.scheduleTouchBottomRetry();
      return;
    }
    this.appendFromBottom();
  }

  /** 延后一拍复核贴底（只一拍、不排第二轮；销毁时在 aboutToDisappear 里清） */
  private scheduleTouchBottomRetry(): void {
    if (this.touchBottomRetryTimer >= 0) {
      return;
    }
    this.touchBottomRetryTimer = setTimeout((): void => {
      this.touchBottomRetryTimer = -1;
      if (!this.isWebtoon() || this.loading || this.pageCount() === 0) {
        return;
      }
      if (Date.now() - this.lastUserTouchAt < 240) {
        return;
      }
      if (this.webtoonScroller.isAtEnd()) {
        this.appendFromBottom();
      }
    }, ReaderView.TOUCH_BOTTOM_RETRY_MS);
  }

  private clearTouchBottomRetry(): void {
    if (this.touchBottomRetryTimer >= 0) {
      clearTimeout(this.touchBottomRetryTimer);
      this.touchBottomRetryTimer = -1;
    }
  }

  /**
   * 「贴在流末尾」这条驱动的追加入口（onReachEnd 与延后一拍共用）。
   * 与 onScrollIndex 那条的关键差别：贴底时流的末格常常**已经是上一轮追加进来的邻章**，
   * 而 tryAppendNextChapter 的第 ④ 道闸（末格 chIdx >= chapterIndex+1 直接返回）会把它挡死
   * ⇒ 原样调它 = 读完已经拼进来的那一章之后，再也不会接下一章（这正是本轮要修的）。
   * 所以这里先把当前章提升到末格所属章。这不是投机：用户此刻就读在那一章上
   * （saveProgress 早就是按 pageIndex 取格子里的身份落库的，与 chapterIndex 无关），
   * 提升只是让 chapterIndex / TOC 高亮与画面上看到的一致，顺带把闸门重新打开。
   * 再叠两道防失控：BOTTOM_APPEND_COOLDOWN_MS 节流 + SEAMLESS_CHAIN_MAX 连续封顶
   * （归零点在 onWebtoonScrollIndex，见 F2-CHAINRESET）。
   */
  private appendFromBottom(): void {
    if (!this.isWebtoon() || this.loading || this.seamlessAppending || this.pageCount() === 0) {
      return;
    }
    const last: PageRef = this.cells[this.cells.length - 1];
    if (last.chIdx > this.chapterIndex) {
      if (this.seamlessChainRounds >= ReaderView.SEAMLESS_CHAIN_MAX) {
        return;
      }
      const now: number = Date.now();
      if (this.lastBottomAppendAt > 0 && now - this.lastBottomAppendAt < ReaderView.BOTTOM_APPEND_COOLDOWN_MS) {
        return;
      }
      this.seamlessChainRounds = this.seamlessChainRounds + 1;
      this.lastBottomAppendAt = now;
      this.bottomAnchorIndex = this.pageIndex;
      this.chapterIndex = last.chIdx;
    }
    this.tryAppendNextChapter();
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
   *   loadPage 每次进来都在入口自增 pageCalls，所以 pre= 是把 16 号行 pageCalls 与真实
   *   用户可见取图量对回去的唯一换算项。
   */
  /** 第 index 页（0 起）的取图入参；越界或该图源没给 = 空串（ImageCache 空串不参与键） */
  private extAt(index: number): string {
    if (this.isWebtoon()) {
      const c: PageRef | null = this.cellAt(index);
      return c === null ? '' : c.ext;
    }
    if (index < 0 || index >= this.pageExts.length) {
      return '';
    }
    return this.pageExts[index];
  }

  // ---------------- 五项轮：两档统一的「按渲染下标问页身份」访问口 ----------------
  // 无缝转场之后，纵向档一条渲染流里跨了好几章，**下标不再是页码、也不再唯一对应一章**，
  // 所以任何"按下标取身份"的地方都必须走这里，禁止就地写 urls[i] / currentChapterId + i + 1。
  // 横向档没有跨章（只挂 Pager 那一章），因此这些口在它身上退化成老语义，行为一字不变。

  /** 当前档这一条流的总格数（顶栏分母、边界判定的分母） */
  private pageCount(): number {
    return this.isWebtoon() ? this.cells.length : this.urls.length;
  }

  /** 纵向档第 index 格；越界 = null（调用方各自早退，不在这里造一个假身份） */
  private cellAt(index: number): PageRef | null {
    if (index < 0 || index >= this.cells.length) {
      return null;
    }
    return this.cells[index];
  }

  /** 第 index 格的 url（横向档 = urls 同下标） */
  private urlAt(index: number): string {
    if (this.isWebtoon()) {
      const c: PageRef | null = this.cellAt(index);
      return c === null ? '' : c.url;
    }
    if (index < 0 || index >= this.urls.length) {
      return '';
    }
    return this.urls[index];
  }

  /** 第 index 格所属章节 id（**不是** currentChapterId：滚进邻章后两者不同） */
  private chapterIdAt(index: number): string {
    if (this.isWebtoon()) {
      const c: PageRef | null = this.cellAt(index);
      return c === null ? this.currentChapterId : c.chapterId;
    }
    return this.currentChapterId;
  }

  /** 第 index 格的章内页码（1 起）——尺寸表键、页码显示、落库 page 三处共用 */
  private pageNoAt(index: number): number {
    if (this.isWebtoon()) {
      const c: PageRef | null = this.cellAt(index);
      return c === null ? index + 1 : c.pageNo;
    }
    return index + 1;
  }

  /** 第 index 格所属章的总页数（页码显示的分母 = 章内口径，与上游 getDisplayPageNumber 一致） */
  private pageTotalAt(index: number): number {
    if (this.isWebtoon()) {
      const c: PageRef | null = this.cellAt(index);
      return c === null ? this.urls.length : c.pageTotal;
    }
    return this.urls.length;
  }

  /** 第 index 格所属章在 chapters 里的下标（横向档 = 当前章） */
  private chIdxAt(index: number): number {
    if (this.isWebtoon()) {
      const c: PageRef | null = this.cellAt(index);
      return c === null ? this.chapterIndex : c.chIdx;
    }
    return this.chapterIndex;
  }

  /** 当前页的「页身份」键 = 章 id + 章内页码，与行内 sizeKey() 逐字同源（都转调 pageSizeKey） */
  private pageKeyAt(index: number): string {
    return pageSizeKey(this.chapterIdAt(index), this.pageNoAt(index));
  }

  private prefetchAround(index: number): void {
    const n: number = this.pageCount();
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
      const u: string = this.urlAt(i);
      // 判重按页身份（与行内 load 同一个键）：按 url 判在哨兵地址图源上会把整章当成一条在途，
      // 预取整章静默全废。身份一律走 pageKeyAt —— 无缝转场后邻章的格子混在同一条流里，
      // 用 currentChapterId + i + 1 拼会把邻章第 3 页记成本章第 (追加起点+3) 页 = 键错位。
      const pk: string = this.pageKeyAt(i);
      if (u.length === 0 || ReaderDiag.isInFlight(pk)) {
        continue;
      }
      ReaderDiag.prefetchTotal += 1;
      ImageCache.getInstance().loadPage(u, this.sourceId, this.chapterIdAt(i), this.extAt(i))
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
    if (!this.isWebtoon() || this.pageCount() === 0) {
      return;
    }
    try {
      const p: ReadProgress | null = await MangaRepository.getInstance().getProgress(this.mangaId);
      if (p === null || p.chapterId !== this.currentChapterId) {
        return;
      }
      const target: number = p.page > 0 ? p.page - 1 : 0;
      if (target >= this.pageCount()) {
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
      // 五项轮：章节表常驻状态（TOC / 上下章 / 无缝转场三件事的共同数据前提）。
      // 原先它只是这里的局部变量，取完目标章就丢了。
      this.chapters = chapters;
      let idx: number = 0;
      if (this.chapterId.length > 0) {
        for (let i = 0; i < chapters.length; i++) {
          if (chapters[i].id === this.chapterId) {
            idx = i;
            break;
          }
        }
      }
      await this.loadChapterAt(idx, true);
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
   * 切到章节表第 idx 章并装载页表（五项轮新增 = 原 loadPages 的装载段抽出复用）。
   * 三个调用方：loadPages（首开，resume=true）、TOC 点选与上下章键（resume=false，新章从头读）、
   * 无缝转场的预取（不走这里，它只追加不重置）。
   * resume=true 才走 resumeOnOpen：首开要续读，阅读器内主动切章是「我要读这一章」的显式意图，
   * 从上一章带过来的进度页码套在新章上是错误的。
   */
  private async loadChapterAt(idx: number, resume: boolean): Promise<void> {
    if (this.chapters.length === 0) {
      return;
    }
    let i: number = idx;
    if (i < 0) {
      i = 0;
    }
    if (i > this.chapters.length - 1) {
      i = this.chapters.length - 1;
    }
    const target: ChapterInfo = this.chapters[i];
    this.chapterIndex = i;
    this.chapterName = target.title;
    this.currentChapterId = target.id;
    const src: MangaSource | null = SourceManager.getInstance().get(this.sourceId);
    if (src === null) {
      this.errorMsg = '图源未就绪';
      ReaderDiag.noteChapterError(this.errorMsg);
      return;
    }
    const pages: PageImage[] = await src.fetchPages(target.id);
    const list: string[] = [];
    // s18：extern 必须和 url 一起搬过来。上游插件把每页真正的取图入参放在页对象 extern 里
    // （e-hentai 整章 url 相同，只有这份 extern 区分页），宿主原先只 push url = 第二处丢失点。
    const exts: string[] = [];
    for (let k = 0; k < pages.length; k++) {
      list.push(pages[k].url);
      exts.push(pages[k].ext);
    }
    this.urls = list;
    this.pageExts = exts;
    // 换章节 = 换整个数据源实例（LazyForEach 不认「同实例换内容」，靠 @State urls 变化
    // 重跑 build，LazyForEach 重新按 key 取数）。页码同步归零，再按存档续读。
    // 五项轮：纵向档条目换成带章身份的 PageRef（无缝转场会在尾部追加邻章的格子）。
    this.cells = ReaderView.buildCells(pages, target.id, i);
    this.webtoonSource = new WebtoonPageSource(this.cells);
    this.pageIndex = 0;
    this.sliderPage = -1;
    // s31 第 2 条：换章 = 一条全新的无缝链条，上一串贴底追加的状态全部作废
    // （数据源、cells、pageIndex 上面已整体换新，这里补上本轮新加的那几枚）
    this.seamlessChainRounds = 0;
    this.bottomAnchorIndex = -1;
    this.lastBottomAppendAt = 0;
    this.clearTouchBottomRetry();
    // 五项轮原口径「切章即停」+ s31 第 2 条 C 改成先停、后按原样续：
    // 停是必须的（旧定时器还按旧章的页数与节奏在跑），停完若原先是开的就照当前设置
    // 重启（见函数末尾 F2-RESUME 处）—— 用户要求不该每章手动重开一次。
    // startAutoRead 头部自带 stopAutoRead 与间隔重算，重复调用安全，不新增参数。
    const wasAutoRead: boolean = this.autoReadOn;
    this.stopAutoRead();
    if (list.length === 0) {
      this.errorMsg = '本章节没有图片';
      // 同上：fetchPages 没抛但交了空页表，界面与失败一模一样，必须记账
      ReaderDiag.noteChapterError(this.errorMsg);
    } else {
      ReaderDiag.readerPagesLoaded += 1;
      // 必须在 finally 置 loading=false（列表真正开始布局）之前把 pageIndex 落好，
      // 否则首帧先画第一页、下一帧才跳走，看着像进章节抖一下
      if (resume) {
        await this.resumeOnOpen();
      }
      // 章节就绪 + 落点定好之后立刻按窗口预取一轮（首屏之后的几页在用户还没翻到时就进内存）
      this.prefetchAround(this.pageIndex);
      // s31 第 2 条 C：只有「切之前就是开的」才续开。空章、以及 fetchPages 抛异常的路径
      // 都到不了这一行 = 自动阅读自然停住，不会在没有页面的章上空转定时器。
      // 另外三个调用方（loadPages / switchChapter / advancePagerChapter）都在 await 之后
      // 才置 loading=false ⇒ 续开后的第一个 tick 若撞上 loading 会被 autoTick 自己让位，
      // 顶多少走一拍，不会读到半个数据源。
      if (wasAutoRead) {
        this.startAutoRead();
      }
    }
  }

  /**
   * 把一章的 PageImage[] 折成**带章身份**的格子（纯函数、无副作用，五项轮）。
   * 章内页码在这里一次性定死（1 起）并且把该章总页数一起塞进每格：顶栏页码与滑杆的分母
   * 必须是「本章第几页 / 本章共几页」，用整条渲染流的长度当分母会在这种时候打出 137/204
   * 这种用户看不懂的数（上游同理 = getDisplayPageNumber 只吃章内槽位）。
   */
  private static buildCells(pages: PageImage[], chapterId: string, chIdx: number): PageRef[] {
    const total: number = pages.length;
    const out: PageRef[] = [];
    for (let k = 0; k < total; k++) {
      out.push(new PageRef(pages[k].url, pages[k].ext, chapterId, k + 1, total, chIdx));
    }
    return out;
  }

  /**
   * 无缝转场（五项轮）：取 chapters[idx] 的页表并折成格子，**只取不改任何状态**。
   * 与 loadChapterAt 的区别是刻意的 —— 追加不能碰 pageIndex / 进度 / 自动阅读 / chapterName，
   * 否则用户正读着当前章，画面被邻章的装载过程打断（上游也是这个分法：预取与拼接走
   * reader_seamless_cubit，切章走 router.replace 整页重建，两条路互不干涉）。
   * 失败返回 null 并只记 console.warn：邻章取不到**不许**影响当前章，也不上屏报错
   * （上游语义 = 只把那一枚转场卡置 error，当前视图一字不动）。
   */
  private async fetchSeamlessChapter(idx: number): Promise<SeamlessChapter | null> {
    if (idx < 0 || idx >= this.chapters.length) {
      return null;
    }
    const src: MangaSource | null = SourceManager.getInstance().get(this.sourceId);
    if (src === null) {
      return null;
    }
    const ch: ChapterInfo = this.chapters[idx];
    try {
      const pages: PageImage[] = await src.fetchPages(ch.id);
      if (pages.length === 0) {
        return null;
      }
      const out: SeamlessChapter = new SeamlessChapter();
      out.chapterId = ch.id;
      out.title = ch.title;
      out.cells = ReaderView.buildCells(pages, ch.id, idx);
      return out;
    } catch (err) {
      const e = err as BusinessError;
      console.warn(`[Reader] seamless fetch chapter ${idx} failed: code=${e.code} msg=${e.message}`);
      return null;
    }
  }

  /**
   * 尾部追加下一章（五项轮无缝转场的唯一写入口）。四道闸，缺一都出事：
   * ① 只在纵向档做（横向档是一屏一页的 Swiper，追加进同一条流没有视觉意义，上游亦然）；
   * ② 阈值闸 = 距本章末尾不足 SEAMLESS_APPEND_AHEAD 页才动手（上游 _nextAutoResolveThreshold=1
   *    的等价，见常量注释）—— 没有这道闸就是"进第一章就把整本书拉完"；
   * ③ 在途去重闸 seamlessAppending：**没有它 = 同一章并发拉两次**（onScrollIndex 在阈值区内
   *    会连着回调好几帧，上游用两枚 Set 做这件事，这里同一时刻只可能追加紧邻的下一章，一枚布尔够用）；
   * ④ 已追加过闸 cells 末格的 chIdx 已经是下一章 ⇒ 直接返回（重复点/重复回调都不重发请求）。
   * 追加成功后**不改 pageIndex、不改进度、不停自动阅读**，只补一轮预取。
   */
  private tryAppendNextChapter(): void {
    if (!this.isWebtoon() || this.seamlessAppending) {
      return;
    }
    const n: number = this.cells.length;
    if (n === 0 || this.chapterIndex < 0) {
      return;
    }
    const nextIdx: number = this.chapterIndex + 1;
    if (nextIdx >= this.chapters.length) {
      return;
    }
    const cur: PageRef = this.cells[n - 1];
    if (cur.chIdx >= nextIdx) {
      return;
    }
    const lastOfCur: number = this.pageNoAt(n - 1);
    if (cur.chIdx !== this.chapterIndex || cur.pageTotal - lastOfCur >= ReaderView.SEAMLESS_APPEND_AHEAD) {
      return;
    }
    this.seamlessAppending = true;
    this.fetchSeamlessChapter(nextIdx).then((got: SeamlessChapter | null): void => {
      this.seamlessAppending = false;
      if (got === null || got.cells.length === 0) {
        return;
      }
      // 二次确认：异步回来的这一刻用户可能已经通过 TOC 切了章，那这批格子就是过期的
      if (this.chapterIndex !== cur.chIdx || this.cells.length !== n) {
        return;
      }
      this.webtoonSource.appendAndNotify(got.cells);
      // 追加完顺手按当前页补一轮预取：新进来的邻章头几页正好在窗口外，等下一帧的
      // onScrollIndex 才有机会被取，这里补一次让它更早进内存（幂等，isInFlight 会去重）
      this.prefetchAround(this.pageIndex);
    }).catch((): void => {
      this.seamlessAppending = false;
    });
  }

  /**
   * 落库进度，并把 sourceId / title 一起带上（bug④ 修法）。
   * manga 表只有「加入书架」才会写 ⇒ 从发现页直接读的书若不带上这两项，
   * 阅读记录页会因查不到元数据而整页空白。
   * 五项轮：章 id 与页码都改成**按当前页身份取**（chapterIdAt / pageNoAt）。无缝转场之后
   * 用户可能已经滚进追加进来的下一章，继续写 currentChapterId + pageIndex 会把进度记成
   * 「上一章第 137 页」= 下次续读直接落到不存在的页，且目录高亮也回错章。
   */
  private async saveProgress(): Promise<void> {
    try {
      await MangaRepository.getInstance()
        .saveProgress(this.mangaId, this.chapterIdAt(this.pageIndex), this.pageNoAt(this.pageIndex),
          this.sourceId, this.title);
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
    if (this.pageIndex < this.pageCount() - 1) {
      this.swiperController.showNext();
      return;
    }
    // s31 第 2 条 B：已在最后一页还往「继续」那一侧点 = 意图明确 ⇒ 真接下一章。
    // 横向档里**可观测**的入口只有这一条（左右热区经 tapSide 进来）与 autoTick 两条：
    // Swiper 在末页被 clamp 的那一下不回调 onChange（swiper.d.ts:1880；其文档 1861 行写明
    // 只有 index 变化才触发，1869 行写明动画引起的变化在动画结束时触发），
    // onGestureSwipe（2063）又只在「真的翻了一页」时给，本 SDK 里没有任何回调能观察到
    // 「末页又被推了一下」（onContentWillChange 在这份 d.ts 里根本不存在）⇒
    // 手指在末页硬滑那一下无法可靠接线，已如实报给 lead，不臆造 API。
    this.advancePagerChapter();
  }

  /**
   * 横向档「翻过本章最后一页」= 切到下一章并从第一页读起（resume=false，口径同 TOC 点选，
   * 不是续读）。形态照抄 switchChapter：带 loading + 失败上屏，绝不静默失败
   * （s15 那条「用户只看到五个字、真因在 console」的教训同款）。
   * 四道闸：① 不在加载中（切章是 await，重入会拿错数据源）② 无缝追加没在途
   * ③ 后面确实还有章 ④ 有页可翻。自动阅读的原样续开由 loadChapterAt 末尾负责
   * （见 F2-RESUME），这里一律不碰定时器，避免两处抢着重启。
   */
  private advancePagerChapter(): void {
    if (this.loading || this.seamlessAppending || this.pageCount() === 0) {
      return;
    }
    const nextIdx: number = this.chapterIndex + 1;
    if (this.chapterIndex < 0 || nextIdx >= this.chapters.length) {
      return;
    }
    this.loading = true;
    this.errorMsg = '';
    this.loadChapterAt(nextIdx, false).then((): void => {
      this.loading = false;
    }).catch((err: Object): void => {
      this.loading = false;
      const raw: string = typeof (err as Error).message === 'string' ? (err as Error).message : '';
      this.errorMsg = briefForScreen(raw, '章节加载失败，可点按重试');
      ReaderDiag.noteChapterError(this.errorMsg);
    });
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
  /**
   * 中心热区（s31 第 1 条改口径）。三段语义，按顺序判：
   * ① 当前页最后一次取图失败 → 这一按当手动重试且**什么都不弹**（沿用 s16 第 2 条丁，理由不变：
   *    用户点重试时菜单跳出来正好盖住他要看的那一页）。
   * ② 此刻是沉浸态（chrome 与两枚浮层全关）→ **只出顶栏 + 底栏**。
   * ③ 否则（任何一层开着）→ 全收，回到沉浸态。
   * ★ s30 那版是「点一下同时出 chrome + 设置面板」，真机反馈原话 =「点击中间后会自动打开阅读设置
   *   页面，我的意思是点击中央后跳出阅读器底栏」⇒ 设置面板交回底栏那枚「设置」键单独控制（它本就
   *   是幂等开合），中心点按只负责「进 / 出沉浸」这一件事。
   */
  private tapCenter(): void {
    const idx: number = this.pageIndex;
    // 与行内同一枚页键（失败表现在按页记，这里也按页问，两侧不会再因哨兵地址错开）。
    // 顺序刻意是先判下标合法再问表：越界页码可能凑出一枚「历史失败过」的键，
    // 那样一次无意义点按就会去推重试信号（虽然没人响应，但会把 retry 计数与顶栏语义带偏）。
    if (idx < 0 || idx >= this.pageCount()) {
      this.toggleChrome();
      return;
    }
    // ★ 页键走 pageKeyAt（= 该格自己的章 id + 章内页码），不再用 currentChapterId + idx + 1：
    // 无缝转场后正读邻章时，用当前章拼键会问错行 = 点重试推给一条不在屏幕上的行。
    const pk: string = this.pageKeyAt(idx);
    if (ReaderDiag.isFailed(pk)) {
      ReaderDiag.pushRetry(pk);
      return;
    }
    this.toggleChrome();
  }

  /**
   * 中心热区的开合（s31 第 1 条：改名 + 改口径 = 只碰 chrome，不再带设置面板）。
   * 全隐 → 出顶栏 + 底栏；有任何一层开着（含两枚浮层）→ 全收。目录也算「开着」⇒ 读目录时
   * 点中心直接回沉浸，不用先点遮罩再点中心（少一次操作）。要开设置面板请点底栏「设置」键。
   */
  private toggleChrome(): void {
    const anyOpen: boolean = this.chromeVisible || this.settingsVisible || this.tocVisible;
    if (anyOpen) {
      this.chromeVisible = false;
      this.settingsVisible = false;
      this.tocVisible = false;
      return;
    }
    this.chromeVisible = true;
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
   * - ★ key 五项轮改成 **章 id + # + 章内页码**（与尺寸表同一个 pageSizeKey）。原口径「'p' + 下标」
   *   在追加下一章之后必错：追加只往尾部加、已有格子下标不动看似安全，但**换章时数据源虽是
   *   新实例、key 串却与上一章完全相同**（'p0'…'pN' 两章一样），LazyForEach 按 key 比对会认为
   *   「这些行还在」= 行组件不重建 = 沿上一章的 url 与尺寸表渲染 = 串章（且切章必现，不是边缘情况）。
   *   为什么不按 url 当 key：e-hentai 这类图源整章共用同一 url（只有 extern 区分页，见 s18 那段），
   *   按 url 会把整章压成一行。章 id + 章内页码才同时满足「同章唯一、跨章不撞、换章必换」。
   */
  @Builder
  WebtoonArea() {
    List({ space: 0, scroller: this.webtoonScroller, initialIndex: this.webtoonStartIndex }) {
      LazyForEach(this.webtoonSource, (item: PageRef, index: number) => {
        ListItem() {
          // 热区必须挂在**行内**，不能整屏盖一层在 List 之上：ArkUI 的命中测试只沿「根到命中节点」
          // 这条链派发，List 是热区的兄弟而不是祖先时，起于热区的拖动永远进不了 List 的滚动手势
          // 识别器 = 滚不动。s27 再往下一层（黑区真根因）：热区原先挂在这枚行盒 Stack 上，而它
          // 只有 .width('100%') 没有确定高（ListItem 只约束宽）—— ArkUI 里 height('100%') 问的是
          // 父级给的**高度约束**，List 给 ListItem 的高约束 = 列表可视高（真机 vh=844），于是热区把
          // 每行撑成一整屏（真机 gap=676@p2、rowBox=844 与 vh=844 逐值相等），行内 Image 走 Contain
          // 就在上下各留 (844 - 行高)/2 的阅读区底色 = 用户报的黑区。现在热区进 ReaderPageImage 内部：
          // 那里的容器有 aspectRatio 或显式 height 定出的确定高，100% 只解析成本行自己的尺寸。
          Stack({ alignContent: Alignment.Center }) {
            ReaderPageImage({
              url: item.url,
              sourceId: this.sourceId,
              // ★ 三项身份取自 item 自己，不再用 currentChapterId / index + 1 / extAt(index)：
              // 无缝转场后一条渲染流里跨章，按「当前章」算会把邻章的格子套进本章的取图上下文
              // （尺寸表按章 id + 页码定键 = 行高串章；反混淆意图与 Referer 也会用错章）。
              chapterId: item.chapterId,
              fitHeight: true,
              pageNo: item.pageNo,
              pageExt: item.ext,
              viewportH: this.areaH,
              // s17：骨架铺满整行要用父宽复算行高（行高 = 宽 / 真比），与骨架高同源
              viewportW: this.areaW,
              // s27：热区下沉（原先这里是行内的行盒热区调用），三列行为照旧
              onTapPrev: (): void => {
                this.tapSide(false);
              },
              onTapCenter: (): void => {
                this.tapCenter();
              },
              onTapNext: (): void => {
                this.tapSide(true);
              }
            })          }
          .width('100%')
          // s17 A1（纯度量）：这枚 Stack 就是行盒本体（ListItem 只约束宽），它的高 = 这一行真占的高。
          // 与组件自报的 rowH 配对才能判 e2：单量组件会必然读到健康值。
          .onAreaChange((_o: Area, n: Area) => {
            ReaderDiag.noteRowBox(Number(n.height), pageSizeKey(item.chapterId, item.pageNo));
          })
        }
        .width('100%')
      }, (item: PageRef, index: number) => pageSizeKey(item.chapterId, item.pageNo))
    }
    .width('100%')
    .height('100%')
    .cachedCount(ReaderView.WEBTOON_CACHED_COUNT)
    .scrollBar(BarState.Off)
    .edgeEffect(EdgeEffect.None)
    .onAppear(() => {
      // 五项轮：告诉 jumpToIndex「这枚 List 已经活着」，此后滑杆/目录跳页立刻 scrollToIndex。
      // 老语义只在挂载这一刻消费待执行定位 = 已挂载时跳页静默失效（滑杆拖完画面不动）。
      this.webtoonReady = true;
      // 挂载后补一次待执行定位（见 consumePendingJump）
      this.consumePendingJump();
    })
    .onDisAppear((): void => {
      // 切档（纵向→横向）会拆掉这棵子树：不置回 false，切回来时 jumpToIndex 会走「立刻
      // scrollToIndex」那条腿，而此刻 Scroller 还没绑上新 List = 空操作静默不跳。
      this.webtoonReady = false;
    })
    .onScrollIndex((start: number, end: number, center: number): void => {
      this.onWebtoonScrollIndex(start, end, center);
    })
    // s31 第 2 条 A：补上「停在最后一屏」这条腿（list.d.ts:1661 onReachEnd，@since 7）。
    // 它两次白触发由闸门兜住：内容不满一屏时首帧触发一次（那一刻 isAtEnd 不可信 ⇒
    // 延后一拍复核），弹性回弹到末尾会再触发一次（在途闸 + 节流 + 封顶）。
    // 本 List 的 edgeEffect 已是 None，第二次那类回弹本来就不存在。
    .onReachEnd((): void => {
      this.onWebtoonReachEnd();
    })
    .onTouch((ev: TouchEvent): void => {
      // 自动阅读的让位判据（见 lastUserTouchAt / autoTick）：只记按下与拖动，Up 刻意不记 =
      // 抬手后推进立刻恢复，不必再多等一个窗口。
      const t: TouchType = ev.type;
      if (t === TouchType.Down || t === TouchType.Move) {
        this.lastUserTouchAt = Date.now();
      }
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

        Text(this.pageLabel())
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
    // s30 第 7 条：顶栏「从上边来、回上边去」（进/退用同一条 translate = ArkUI 里即来去同向）。
    // 挂这里 = @Builder 根节点的属性链尾，if 分支移除时退场动画才会播（挂外面那层 Stack 上不生效）。
    // 型制与仓内既有 12 处完全一致（OPACITY.combine(translate).animation(Anim Token)），不引入新范式。
    .transition(TransitionEffect.OPACITY
      .combine(TransitionEffect.translate({ y: -Dim.topBarH }))
      .animation({ duration: Anim.topBarFade, curve: Anim.curveBarCollapse() }))
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
                  pageExt: this.extAt(index),
                  // 横向档高度语义不动（仍是 height 100% 一屏一页），这里只是把视口高透下去，
                  // 让「万一某页没到位图」时的骨架也按同一个 1/4 屏封顶，两档不会一个矮一个高
                  viewportH: this.areaH,
                  viewportW: this.areaW,
                  // s27：热区下沉（原先这里是屏级热区调用），三列行为照旧
                  onTapPrev: (): void => {
                    this.tapSide(false);
                  },
                  onTapCenter: (): void => {
                    this.tapCenter();
                  },
                  onTapNext: (): void => {
                    this.tapSide(true);
                  }
                })              }
              .width('100%')
              .height('100%')
            }, (item: string, index: number) => 'p' + index)
          }
          .index(this.pageIndex)
          .loop(false)
          .vertical(false)
          .indicator(false)
          .duration(200)
          // s31 第 3 条：翻页动画进行中要同时有前一页 / 当前页 / 后一页在场，
          // 缓存不够时新页是边滑进来边解码 = 露出背景（自动阅读那帧黑的另一半原因）。
          // SDK 建议 1 到 2（swiper.d.ts:1612、1631），取上限 2。
          .cachedCount(ReaderView.PAGER_CACHED_COUNT)
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
          // s25 纯探针批次（2）：诊断行直接给视口实测宽高，别再拿截图反推 density
          ReaderDiag.viewportW = w;
          ReaderDiag.viewportH = h;
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


      // 顶栏：单击屏中热区切换显隐（隐藏即全屏沉浸；s31 第 1 条起中心点按不再带出设置面板）
      if (this.chromeVisible) {
        this.ReaderTopBar();
      }
      // 五项轮：底栏与顶栏同进同退（与上游 isMenuVisible 同时喂顶栏和底栏的语义一致）；
      // 两枚浮层排在底栏之后 = 后盖前，浮层打开时把底栏压在下层。
      if (this.chromeVisible) {
        this.ReaderBottomBar();
      }
      if (this.settingsVisible) {
        this.SettingsOverlay();
      }
      if (this.tocVisible) {
        this.TocOverlay();
      }
      // s30 第 7 条：这四层的进出场动画挂在**各 @Builder 自己根节点**的属性链尾（ReaderTopBar /
      // ReaderBottomBar / SettingsOverlay / TocOverlay 各一条 .transition），不挂在这段挂载点上 ——
      // transition 只在「被移除的那棵子树的根」上才播退场，挂外层兄弟位置等于挂在 if 容器上，不生效。
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.black)
  }
}