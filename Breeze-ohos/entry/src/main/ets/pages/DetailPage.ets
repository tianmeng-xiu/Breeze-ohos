/**
 * 职责：作品详情页（需求 4，用户 m05810：「参考之前的两个项目制作书籍详情页……包括阅读按钮、
 *   查看评论区按钮、点赞按钮、书籍简介、相关推荐、添加到本地书架等功能，评论区之类的来源于插件」）。
 * 版式参照 NextE 的 GalleryDetailPage（**只学版式，一行源码都没搬**：它是 V2 状态管理，
 *   我方全仓 V1）与上游 Breeze 的 comic_info 页结构：
 *   封面+元信息 → 动作行 → 简介 → 章节 → 相关推荐 →（评论区是独立页 pages/CommentPage）。
 *
 * 入口：pages/DetailPage，参数 = view/detail/DetailParams。所有列表项点击都应先进这里，
 *   阅读器由本页的「阅读」按钮进入（SearchPage / DiscoverPage / 书架 / 阅读记录 同口径）。
 *
 * 能力缺口是常态（s6j 实测：jjmhw 无评论无点赞、MangaDex 两者都无、只有 man-hua-gui 有但那是
 *   demo 桩）⇒ 每个动作都要么可用、要么置灰并把插件给的 *Reason 当提示，绝不报错崩页面。
 *
 * s13 第 4 条（用户 11-12 22:12 report 第 4 条）：作者行加可点指示 = 与下方标签同款 chip。
 *   作者与标签的 chip 观感集中在本页唯一一份 SearchChip（@Builder）里，跳转通路仍走 searchBy
 *   （s11 第 6 条：SearchEntryParams(源 id, 词) 进 SearchPage，先选源后灌词再搜）⇒ 无新增路由参数。
 *   可点判据 searchable() 与 searchBy 的前置等价：显示判据走 authorName()（trim 后非空），
 *   源 id 缺失时作者行退回纯文本档，不留「看着能点、点了没反应」的死指示。
 * 依赖：data/source/SourceManager（取详情）、data/source/PluginDetail（统计/推荐/点赞）、
 *   data/db/MangaRepository（书架/章节缓存/进度）、view/common（顶栏主题状态视图）。
 * 依据系统 Kit：@kit.ArkUI（router）、@kit.ImageKit（封面 PixelMap）。
 */
import { promptAction, router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { Anim } from '../view/common/Anim';
import { LoadingView, ErrorView } from '../view/common/StateViews';
import { Logger } from '../util/Logger';
import { DetailParams } from '../view/detail/DetailParams';
import { CommentParams } from '../view/detail/CommentParams';
import { SearchEntryParams } from '../view/search/SearchEntryParams';
import { ReaderParams } from '../view/reader/ReaderParams';
import { SourceManager } from '../data/source/SourceManager';
import { MangaSource } from '../data/source/Source';
import { PluginDetail, ComicExtras, DetailStat } from '../data/source/PluginDetail';
import { MangaRepository } from '../data/db/MangaRepository';
import { ImageCache } from '../data/image/ImageCache';
import { MangaSummary, ChapterInfo, ReadProgress, SourceInfo } from '../data/model/Models';
import { TextConvert } from '../util/TextConvert';
import { errBriefForScreen, errLog, errTextOf } from '../util/ErrText';

/** 章节区一次显示多少条（其余靠「展开全部」）。 */
const CHAPTER_PREVIEW: number = 20;

/** 封面（详情页一张，独立组件避免和列表抢缓存引用）。 */
@Component
struct DetailCover {
  @Prop @Watch('onUrlChanged') url: string = '';
  /**
   * s30 第 7 条：共享元素转场 id。**默认空串 = 不参与转场**（SDK 原文：id 为空串则不施加共享转场），
   * 只有详情页头图那一处会传值；「相关推荐」那批不传 = 一页里同一本书的 id 至多两枚组件（列表页封面 +
   * 本页头图），不撞「一 id 两枚」上限。
   */
  @Prop heroId: string = '';
  @State pm: image.PixelMap | undefined = undefined;
  /**
   * s21 黑区修法：与 @State pm 分开的**持有账本**（同 view/reader/ReaderView.ets 的 held/setShown 口径）。
   * 「清理图片缓存」与 LRU 淘汰都不该 release 仍在显示的那一张：被 release 后 Image 画整幅纯黑，
   * 不抛异常也不留日志（阅读器上的同款缺陷就是那条黑区）。
   */
  private held: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.setShown(undefined);
  }

  onUrlChanged(): void {
    this.setShown(undefined);
    this.load();
  }

  /** 挂载/摘除唯一入口：retain 在前、unpin 在后，再把值喂给 @State。 */
  private setShown(next: image.PixelMap | undefined): void {
    const prev: image.PixelMap | undefined = this.held;
    if (next !== undefined) {
      ImageCache.getInstance().retain(next);
      this.held = next;
    } else {
      this.held = undefined;
    }
    this.pm = next;
    if (prev !== undefined && prev !== next) {
      ImageCache.getInstance().unpin(prev);
    }
  }

  async load(): Promise<void> {
    if (this.url.length === 0) {
      return;
    }
    try {
      const map: image.PixelMap = await ImageCache.getInstance().load(this.url);
      this.setShown(map);
    } catch (e) {
      this.setShown(undefined);
    }
  }

  build() {
    Stack() {
      if (this.pm !== undefined) {
        Image(this.pm)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Cover)
          .draggable(false)
      } else {
        Column() {
          Text('无封面')
            .fontSize(11)
            .fontColor(Theme.text3(this.isDark))
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(Theme.coverColor(this.isDark))
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.coverColor(this.isDark))
    .borderRadius(Dim.coverRadius)
    .clip(true)
    // s30 第 7 条：转场挂在**容器根**上而不是 Image(this.pm) 上 —— 详情封面是异步解码的 PixelMap，
    // 挂 Image 上时若那一帧还没解出来，飞过去的就是那格「无封面」占位（真机观感 = 灰块飞一下）。
    // 容器从进场起尺寸就稳定（外面 Column 定了 104×139），共享的是这块矩形而不是像素。
    // s31 第 6 条：与 view/bookshelf/BookshelfPage.ets 的 CoverCell 逐字同参（同 duration + 同 curve）。
    // type=Exchange 是 SDK 默认值（common.d.ts:3809 原文 Default = SharedTransitionEffectType.Exchange），
    // 这里显式写出来是因为第 7 条的「向四周展开」正是 Exchange 的语义：只插值几何（位置 + 尺寸），
    // 不做淡入淡出 ⇒ 飞过去的始终是这块不透明矩形，中途不会透出底色。写清默认值也防以后被人改动默认档。
    .sharedTransition(this.heroId, {
      duration: Anim.pageHero,
      curve: Anim.curveEaseOut(),
      type: SharedTransitionEffectType.Exchange,
      // s32 第 1 条：与书架 CoverCell、阅读器浮层**同值**的飞行层序（见 Anim.heroZ 注释）
      zIndex: Anim.heroZ
    })
  }

  @StorageProp('isDark') isDark: boolean = false;
}

/**
 * 动作按钮（阅读 / 书架 / 点赞 / 评论 通用外形）。
 * ★ 为什么是独立 @Component 而不是本页的 @Builder：
 *   @Builder 的形参是**值传递快照**，父组件状态变化时不会重渲染 ⇒ 点赞成功/加架成功
 *   之后按钮文案会定格在旧值。改成 @Prop 才随状态刷新（仓内既有同类：ReaderPageImage、
 *   DetailCover 都是这个原因抽出来的）。
 * ★ 字段名不能叫 enabled：所有组件都继承 CustomComponent 的 enabled(value) 属性方法，
 *   @Prop enabled 会报「not assignable to the same property in base type 'CustomComponent'」
 *   ⇒ 改名 usable。
 */
@Component
struct ActionBtn {
  @Prop label: string = '';
  @Prop sub: string = '';
  @Prop usable: boolean = true;
  @Prop primary: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  onGo: () => void = () => {};

  build() {
    Column() {
      Text(this.label)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(!this.usable ? Theme.text3(this.isDark)
          : (this.primary ? Theme.white : Theme.text1(this.isDark)))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.sub)
        .fontSize(11)
        .fontColor(!this.usable ? Theme.text3(this.isDark)
          : (this.primary ? Theme.white : Theme.text2(this.isDark)))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ top: 2 })
    }
    .layoutWeight(1)
    .height(52)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.primary ? Theme.brand : Theme.fillColor(this.isDark))
    .borderRadius(Dim.radius)
    .opacity(this.usable ? 1 : 0.55)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      if (!this.usable) {
        return;
      }
      this.onGo();
    })
  }
}

@Entry
@Component
struct DetailPage {
  @StorageProp('isDark') isDark: boolean = false;
  /**
   * 简繁转换版本号（util/TextConvert.bumpRev 在词典就绪或切档后自增）：
   * 本页 manga / chapters 是异步 load 的，词典到货那一刻它们没变、只有这个数变 ⇒
   * 由本页观察它，build 重跑，下面各处 cvt(...) 才重新求值。
   * ⚠ 转换只在显示层：searchBy 的入参、屏蔽词匹配一律用原文（口径见 util/TextConvert 头注释）。
   */
  @StorageProp('textConvertRev') cvtRev: number = 0;

  /** 显示文案过一遍简繁转换（只改显示，不参与搜索匹配与屏蔽词匹配）。 */
  private cvtShow(raw: string): string {
    const rev: number = this.cvtRev;
    if (rev <= 0) {
      // 本进程还没就绪过词典也没切过档 = 首帧，原样给，连表都不查
      return raw;
    }
    return TextConvert.getInstance().cvt(raw);
  }

  @State mangaId: string = '';
  @State sourceId: string = '';
  @State title: string = '';

  @State loading: boolean = true;
  @State loadError: string = '';
  @State manga: MangaSummary | null = null;
  @State extras: ComicExtras = new ComicExtras();
  @State chapters: ChapterInfo[] = [];
  /** 进度（null = 没读过） */
  @State progress: ReadProgress | null = null;
  @State inShelf: boolean = false;
  @State coverPm: image.PixelMap | undefined = undefined;
  /** s21 黑区修法：封面持有账本（同 DetailCover.held 口径）。 */
  private heldCover: image.PixelMap | undefined = undefined;

  /** 简介是否展开 */
  @State descExpanded: boolean = false;
  /** 章节是否全展开 */
  @State chapterExpanded: boolean = false;
  /** 章节倒序显示（不少图源 eps 是最新在前） */
  @State chapterDesc: boolean = false;
  /**
   * 章节区**实际渲染源**。必须是 @State：ForEach 的数据源若写成 `this.chapterSlice()`
   * 这种普通方法调用，ArkUI 建立不了状态依赖 ⇒ 展开/倒序点了不刷新。
   * 三个开关（chapters / chapterExpanded / chapterDesc）都在 applyChapterView() 里统一算。
   */
  @State chapterView: ChapterInfo[] = [];
  /** 动作进行中标记（防连点重复提交） */
  @State busy: string = '';

  aboutToDisappear(): void {
    // s21 黑区修法：离开页面归还封面持有，否则 pinLive 只涨不落
    this.setCover(undefined);
  }

  /** 封面挂载/摘除唯一入口（同 setShown 口径，本类字段叫 coverPm）。 */
  private setCover(next: image.PixelMap | undefined): void {
    const prev: image.PixelMap | undefined = this.heldCover;
    if (next !== undefined) {
      ImageCache.getInstance().retain(next);
      this.heldCover = next;
    } else {
      this.heldCover = undefined;
    }
    this.coverPm = next;
    if (prev !== undefined && prev !== next) {
      ImageCache.getInstance().unpin(prev);
    }
  }

  aboutToAppear(): void {
    try {
      const raw: Object = router.getParams();
      if (raw instanceof DetailParams) {
        this.mangaId = raw.mangaId;
        this.sourceId = raw.sourceId;
        this.title = raw.title;
      } else if (raw !== null && raw !== undefined) {
        const src: ESObject = raw;
        this.mangaId = src.mangaId !== undefined ? String(src.mangaId) : '';
        this.sourceId = src.sourceId !== undefined ? String(src.sourceId) : '';
        this.title = src.title !== undefined ? String(src.title) : '';
      }
    } catch (e) {
      Logger.w('DetailPage 参数解析失败：' + (e as Error).message);
    }
    this.reload();
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2200 });
    } catch (e) {
      Logger.i('toast 失败：' + msg);
    }
  }

  async reload(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    if (this.mangaId.length === 0 || this.sourceId.length === 0) {
      this.loadError = '缺少作品参数';
      this.loading = false;
      return;
    }
    const src: MangaSource | null = SourceManager.getInstance().get(this.sourceId);
    if (src === null) {
      // s39：改成不带全角括号的短句，与 util 里各档定死文案同一形态（纪律 = 上屏短句不带括号，
      // 免得将来被哪一步「砍括号」逻辑截成半句；这条原本不经 util 所以不违规，只是形态不统一）。
      this.loadError = '该图源已不可用，可能插件被停用或已删除，请换一个图源';
      this.loading = false;
      return;
    }
    // 1. 详情主体（失败就是真失败 ⇒ 错误态）
    let m: MangaSummary | null = null;
    try {
      m = await src.fetchDetail(this.mangaId);
    } catch (e) {
      // s37 需求 2：原始串（含 stack-hook / bundle: / fn: / args:）只进日志，屏上给一句人话。
      const raw: string = errTextOf(e);
      errLog('[Detail] fetchDetail', raw);
      this.loadError = errBriefForScreen(raw, '作品详情加载失败，请稍后重试');
    }
    if (m !== null) {
      // 插件常不回填 sourceId ⇒ 以调用方传的为准（书架/进度都按它键控）
      m.sourceId = this.sourceId;
      if (m.id.length === 0) {
        m.id = this.mangaId;
      }
      this.title = m.title.length > 0 ? m.title : this.title;
    }
    this.manga = m;

    // 2. 增强信息（统计/推荐）与章节：并行但互不阻塞，失败各自吞
    const p1: Promise<ComicExtras> = PluginDetail.extras(this.sourceId, this.mangaId);
    const p2: Promise<ChapterInfo[]> = this.loadChapters(src);
    const p3: Promise<ReadProgress | null> = MangaRepository.getInstance().getProgress(this.mangaId);
    const p4: Promise<boolean> = MangaRepository.getInstance().isInBookshelf(this.mangaId);
    try {
      this.extras = await p1;
    } catch (e) {
      Logger.w('详情增强异常：' + (e as Error).message);
    }
    try {
      this.chapters = await p2;
      this.applyChapterView();
    } catch (e) {
      Logger.w('章节列表异常：' + (e as Error).message);
      this.chapters = [];
      this.chapterView = [];
    }
    try {
      this.progress = await p3;
    } catch (e) {
      this.progress = null;
    }
    try {
      this.inShelf = await p4;
    } catch (e) {
      this.inShelf = false;
    }

    // 3. 封面（异步补，不挡首屏）
    this.loadCover();

    if (m === null && this.loadError.length === 0) {
      this.loadError = '没有找到这部作品，该图源可能已下架';
    }
    this.loading = false;
  }

  /** 章节：先问源，源空则回退本地缓存（离线也能翻开上次缓存的章）。 */
  private async loadChapters(src: MangaSource): Promise<ChapterInfo[]> {
    let list: ChapterInfo[] = [];
    try {
      list = await src.fetchChapters(this.mangaId);
    } catch (e) {
      Logger.w('fetchChapters：' + (e as Error).message);
    }
    if (list.length > 0) {
      MangaRepository.getInstance().saveChapters(this.mangaId, list).catch((_e: Object): void => {});
      return list;
    }
    try {
      return await MangaRepository.getInstance().listChapters(this.mangaId);
    } catch (e) {
      return [];
    }
  }

  private loadCover(): void {
    const m: MangaSummary | null = this.manga;
    if (m === null || m.coverUrl.length === 0) {
      this.setCover(undefined);
      return;
    }
    ImageCache.getInstance().load(m.coverUrl)
      .then((pm: image.PixelMap): void => {
        this.setCover(pm);
      })
      .catch((_e: Object): void => {
        this.setCover(undefined);
      });
  }

  // ---------------- 动作 ----------------

  /** 阅读按钮的目标章节：有进度用进度章，否则第一章（源顺序）。 */
  private targetChapter(): ChapterInfo | null {
    if (this.chapters.length === 0) {
      return null;
    }
    const p: ReadProgress | null = this.progress;
    if (p !== null && p.chapterId.length > 0) {
      for (let i = 0; i < this.chapters.length; i++) {
        if (this.chapters[i].id === p.chapterId) {
          return this.chapters[i];
        }
      }
    }
    return this.chapters[0];
  }

  private readLabel(): string {
    const t: ChapterInfo | null = this.targetChapter();
    if (t === null) {
      return '暂无可读章节';
    }
    const p: ReadProgress | null = this.progress;
    if (p !== null && p.chapterId === t.id) {
      return '继续阅读 · ' + t.title;
    }
    return '开始阅读 · ' + t.title;
  }

  private openReader(c: ChapterInfo): void {
    // s31 第 7 条（用户原话「从详情到阅读器的动画不够顺畅，整体会发生黑色闪烁，可以改为封面飞向中间，
    // 向四周展开形成阅读页的形式」）：共享元素要两端各一枚同 id 组件，落地页 = pages/ReaderPage.ets。
    // ★ 为什么走 AppStorage 而不是加进 ReaderParams：路由参数类在 view/reader/ReaderParams.ets（本批写域外），
    //   且它的字段语义已被 README/阅读记录钉住；AppStorage 是仓内既有的跨页第二通道（isDark、
    //   shelfRevision、topBarProgress 同款），一次性消费完就清空，不留脏值。
    // ★ 必须在 pushUrl **之前**写：阅读器只在 aboutToAppear 里读一次（那时才建浮层节点，
    //   晚一帧就没有共享元素的落点 = 飞行直接不出现）。
    // ★ 无封面时两个键都写空串 ⇒ 阅读器整块浮层不进组件树，只剩页级淡入（不做半截动画）。
    // 键名就近写死：全站键名真源是 view/common/Theme.ets 的 AppKeys，但那份文件不在本批写域内，
    // 已在交卷正文登记给 lead 择机上收（两处字符串必须与 pages/ReaderPage.ets 的常量逐字一致）。
    const hid: string = 'cover_' + this.sourceId + '_' + this.mangaId;
    const m: MangaSummary | null = this.manga;
    const url: string = m !== null ? m.coverUrl : '';
    const heroOk: boolean = url.length > 0;
    AppStorage.setOrCreate<string>('heroCoverId', heroOk ? hid : '');
    AppStorage.setOrCreate<string>('heroCoverUrl', heroOk ? url : '');
    const p: ReaderParams = new ReaderParams(this.mangaId, this.sourceId, this.title, c.id);
    router.pushUrl({ url: 'pages/ReaderPage', params: p })
      .catch((e: Object): void => {
        this.toast('打开阅读器失败：' + (e as Error).message);
      });
  }

  private onRead(): void {
    const t: ChapterInfo | null = this.targetChapter();
    if (t === null) {
      this.toast('该作品没有可用章节');
      return;
    }
    this.openReader(t);
  }

  /**
   * s13 第 4 条：作者名的「显示」与「可点判据」都过这一道 trim。
   * 有的图源会回「一串空格」这类假作者名：旧判据 length 大于 0 会把它画出来，而 searchBy 里
   * trim 后为空直接 return ⇒ 正好是第 3 条禁止的「看着可点、点了没反应」。这里把两处判据合一。
   */
  private authorName(): string {
    return this.manga !== null ? this.manga.author.trim() : '';
  }

  /**
   * 这个词现在能不能真跳去搜：trim 后非空，且本页带着源 id（searchBy 依赖 this.sourceId，见其注释）。
   * 判据必须与 searchBy 的前置等价，否则 chip 画出来了却什么都不做。
   */
  private searchable(text: string): boolean {
    return text.trim().length > 0 && this.sourceId.length > 0;
  }

  /**
   * s11 第 6 条（用户 11-12 16:15 report 第 6 条）：作者名 / 标签点一下 = 到「本页这个源」搜「这个词」。
   * 源用 this.sourceId（详情页一直带着它，见 openReader / openComments 同一口径），
   * 所以点标签得到的是同源的同类作品，不是把全部源搅在一起的聚合结果。
   * 空词直接不响应（作者为空或标签是空串时点了没意义，也不弹「请输入搜索关键词」那种莫名提示）。
   * 指定源在这期间被卸载的情况由搜索页兜底：它会回落到「全部」聚合再搜（见 SearchPage aboutToAppear
   * 的 entry source gone 分支），这里不预判、也不做二次校验。
   */
  private searchBy(kw: string): void {
    const k: string = kw.trim();
    if (k.length === 0) {
      return;
    }
    const p: SearchEntryParams = new SearchEntryParams(this.sourceId, k);
    router.pushUrl({ url: 'pages/SearchPage', params: p })
      .catch((e: Object): void => {
        this.toast('打开搜索页失败：' + (e as Error).message);
      });
  }

  private openComments(): void {
    const p: CommentParams = new CommentParams(this.mangaId, this.sourceId, this.title);
    router.pushUrl({ url: 'pages/CommentPage', params: p })
      .catch((e: Object): void => {
        this.toast('打开评论区失败：' + (e as Error).message);
      });
  }

  /**
   * 书架数据变了就推版本号（AppStorage 'shelfRevision'）。
   * 书架页是 TabContent 里的子 @Component：切页签不销毁、router.back 回来也不重跑 aboutToAppear，
   * 所以只写库不通知 = 用户「加完书架看不到，重启才有」——必须走写入方 push，
   * 与 MinePage 的 readHistoryCount 同口径（该条 s10 第 4 条起多一个写点：pages/ReaderPage.onPageHide 推 historyRevision）。
   */
  private notifyShelfChanged(): void {
    const cur: number = AppStorage.get<number>('shelfRevision') ?? 0;
    AppStorage.setOrCreate<number>('shelfRevision', cur + 1);
  }

  /** 加/移出本地书架（走本地表，不依赖插件）。 */
  private async onShelf(): Promise<void> {
    if (this.busy === 'shelf') {
      return;
    }
    this.busy = 'shelf';
    try {
      const repo: MangaRepository = MangaRepository.getInstance();
      if (this.inShelf) {
        await repo.removeFromBookshelf(this.mangaId);
        this.inShelf = false;
        this.notifyShelfChanged();
        this.toast('已移出书架');
        return;
      }
      const m: MangaSummary | null = this.manga;
      if (m === null) {
        const f: MangaSummary = {
          id: this.mangaId,
          sourceId: this.sourceId,
          title: this.title,
          author: '',
          coverUrl: '',
          description: '',
          tags: []
        };
        await repo.addToBookshelf(f);
      } else {
        await repo.addToBookshelf(m);
      }
      this.inShelf = true;
      this.notifyShelfChanged();
      this.toast('已添加到本地书架');
    } catch (e) {
      this.toast('书架操作失败：' + (e as Error).message);
    } finally {
      this.busy = '';
    }
  }

  /** 点赞：插件给的 allowLike 决定可点，点击后按插件回包更新状态与计数。 */
  private async onLike(): Promise<void> {
    const st: DetailStat = this.extras.stat;
    if (st.likeAllowed === 0) {
      this.toast(st.likeReason.length > 0 ? st.likeReason : '该作品不支持点赞');
      return;
    }
    if (this.busy === 'like') {
      return;
    }
    this.busy = 'like';
    try {
      const r: string[] = await PluginDetail.toggleLike(this.sourceId, this.mangaId, st.isLiked);
      if (r[0] !== 'true') {
        this.toast(r[2].length > 0 ? r[2] : '点赞失败');
        return;
      }
      const now: boolean = r[1] === 'true';
      const e2: ComicExtras = this.extras;
      e2.stat.isLiked = now;
      if (e2.stat.likes >= 0) {
        e2.stat.likes = e2.stat.likes + (now ? 1 : -1);
      }
      // ComicExtras 是普通类，@State 只认引用变化 ⇒ 必须换引用才刷新
      const fresh: ComicExtras = new ComicExtras();
      fresh.stat = e2.stat;
      fresh.recommend = e2.recommend;
      fresh.chapterCount = e2.chapterCount;
      fresh.empty = e2.empty;
      Anim.to((): void => {
        this.extras = fresh;
      }, Anim.iconBounce, Anim.curveEaseOut());
      this.toast(now ? '已赞' : '已取消点赞');
    } finally {
      this.busy = '';
    }
  }

  // ---------------- 取值/文案 ----------------

  private statText(): string {
    const st: DetailStat = this.extras.stat;
    const parts: string[] = [];
    if (st.views >= 0) {
      parts.push('阅读 ' + st.views);
    }
    if (st.likes >= 0) {
      parts.push('点赞 ' + st.likes);
    }
    if (st.comments >= 0) {
      parts.push('评论 ' + st.comments);
    }
    if (this.extras.chapterCount > 0) {
      parts.push('共 ' + this.extras.chapterCount + ' 话');
    }
    return parts.join(' · ');
  }

  private hasChapters(): boolean {
    return this.chapters.length > 0;
  }

  /** 当前要显示的章节切片（展开/收起 + 正倒序都在这里算，build 里不做逻辑）。 */
  private computeChapterView(): ChapterInfo[] {
    const all: ChapterInfo[] = this.chapters;
    let view: ChapterInfo[] = all;
    if (this.chapterDesc) {
      const rev: ChapterInfo[] = [];
      for (let i = all.length - 1; i >= 0; i--) {
        rev.push(all[i]);
      }
      view = rev;
    }
    if (!this.chapterExpanded && view.length > CHAPTER_PREVIEW) {
      const cut: ChapterInfo[] = [];
      for (let i = 0; i < CHAPTER_PREVIEW; i++) {
        cut.push(view[i]);
      }
      return cut;
    }
    return view;
  }

  /** 三个开关任一变化后必须显式调用（见 chapterView 的注释）。 */
  private applyChapterView(): void {
    this.chapterView = this.computeChapterView();
  }

  private likeEnabled(): boolean {
    return this.extras.stat.likeAllowed !== 0;
  }

  /** 评论区是否可点（插件明确说不行才置灰；未知一律可点，进去再显示空态）。 */
  private commentEnabled(): boolean {
    return this.extras.stat.commentAllowed !== 0;
  }

  @Builder
  SectionCard(title: string) {
    Text(title)
      .fontSize(16)
      .fontWeight(FontWeight.Medium)
      .fontColor(Theme.text1(this.isDark))
      .width('100%')
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 18, bottom: 8 })
  }

  /**
   * s13 第 4 条（用户 11-12 22:12 report 第 4 条）：「点一下去搜这个词」的 chip，本页唯一样式源。
   * 作者行与下方标签行共用它：字号、内边距、底色、圆角、按下态只写这一处（改之前标签行是本页
   * 唯一一份 chip 样式、作者行是纯文本，grep 过没有第二份副本 ⇒ 这里抽取共用而不是新造第三份）。
   * 颜色逐字沿用标签行（text2 打底色 fillColor）：深色档那套对比度是真机验收过的，作者行直接继承。
   * 形参纪律（公共口径 1）：文案走取值函数 textOf 并在 Text 节点里调用 —— @Builder 形参是按值快照，
   *   直接传字符串会把文案定格在首帧；本页 manga 是异步 load、换源重载还要重算（同坑见 ActionBtn、
   *   SettingPage.ManageRow、AboutPage.InfoRow）。
   * singleLine：作者名可能是「组合 / 团体」式长串，必须单行省略（改 chip 前它就是 maxLines 1）；
   *   标签行保持原样可换行，非单行档给 99 = 事实上的不限行（给 INT32_MAX 没必要，留点余量）。
   * topGap、bottomGap：样式本身不管版面位置，外边距数值由调用点给（标签行 0 与 4、作者行 6 与 0），
   *   两行各自的既有间距一位不动。
   */
  @Builder
  SearchChip(textOf: () => string, singleLine: boolean, topGap: number, bottomGap: number,
             onTap: () => void) {
    Text(textOf())
      .fontSize(11)
      .fontColor(Theme.text2(this.isDark))
      .maxLines(singleLine ? 1 : 99)
      .textOverflow({ overflow: TextOverflow.Ellipsis })
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .backgroundColor(Theme.fillColor(this.isDark))
      .borderRadius(10)
      .margin({ top: topGap, right: 6, bottom: bottomGap })
      .clickEffect({ level: ClickEffectLevel.LIGHT })
      .onClick(() => {
        onTap();
      })
  }

  /**
   * s31 第 6 条（用户原话「从书架点开书本和关闭书本的时候动画应当统一，若是采用飞出则同时应该采用飞入
   * 并适当放缓动画速度，若采用右滑进入，则应统一为滑动退出」）：页级转场由「右侧推拉」改成
   * **同参数交叉淡入淡出**，并选用户给的第一个分支：飞出 = 封面从书架格子飞向头部（进入），
   * 飞入 = 同一条线倒放（返回），两边同 duration 同 curve，时长 220 → 360（「适当放缓」）。
   *
   * 为什么把页级位移一起换成淡入淡出（这是本批最需要交代的一次取舍）：
   *  ① 书架是 TabContent 的子组件、不是 router 页，**结构上无法**定义自己的 pageTransition
   *     （router 只驱动页面实例的转场，见 pages/Index.ets 里 BookshelfPage 挂在 Tabs 内）。
   *     推拉档下必然出现「进来的那层在滑、底下那层不动」= 用户描述的「一层滑走一层不动」，
   *     而这一半在写域内无解。淡入淡出**根本没有位移层**：底下那层原地不动正是交叉溶解应有的样子，
   *     缺陷形态从源头上不再存在，也不依赖上一级页面配合。
   *  ② 第 7 条要求详情页 → 阅读器不再是推拉（阅读器根底在深色下是纯黑，推拉 = 一整块黑色带硬边
   *     横扫 = 「整体黑色闪烁」）。如果详情页只对阅读器特殊处理，pageTransition 是页级、不区分去向,
   *     就得再加一个「我这次是去哪」的状态位并在合适的时机复位（时序不可证）⇒ 改成全平台一条规则
   *     比加状态位更小、更不容易错，也让五个入口（书架/发现/搜索/阅读记录/详情自跳）观感一致。
   *  ③ 进出用**同一个构造**（同 duration 同 curve 只换 opacity 端点）⇒ 方向对称是可证的：
   *     Enter 起点 0 → 1，Exit 1 → 0（SDK 原文 page_transition.d.ts:198-208「Sets the starting opacity
   *     value for entrance or the ending opacity value for exit」）。
   * 代价（真机要盯）：从书架/发现/搜索进详情页由「推」变「溶」，全站方向感改由封面共享元素承担；
   * 手势返回仍是同一档淡出，不会与侧滑手势抢位移。
   */
  pageTransition() {
    PageTransitionEnter({ duration: Anim.pageHero, curve: Anim.curveEaseOut() })
      .opacity(0);
    PageTransitionExit({ duration: Anim.pageHero, curve: Anim.curveEaseOut() })
      .opacity(0);
  }

  build() {
    Column() {
      BreezeTopBar({
        title: this.title.length > 0 ? this.title : '详情',
        showBack: true,
        // 新七条第 7 条（lead 裁定 11-12 17:00）：全站路由页统一打开 flatBackground —— 顶栏实底档与本页根容器
        // 同吃 Theme.background，消除「顶栏一块色、页面一块色」的两块皮。开关默认 false，一级页不受影响。
        flatBackground: true,
        onBack: () => {
          router.back();
        }
      })

      if (this.loading) {
        LoadingView({ text: '正在加载作品信息…' })
          .layoutWeight(1)
      } else if (this.loadError.length > 0 && this.manga === null) {
        // s37：StateViews.ErrorView 的 onRetry 默认是空函数而「重试」按钮恒画 ⇒ 必须显式传，
        // 否则用户点重试毫无反应（用户截图里那枚蓝按钮就是这个缺陷）。
        ErrorView({
          msg: this.loadError,
          onRetry: (): void => {
            this.reload();
          }
        })
          .layoutWeight(1)
      } else {
        Scroll() {
          Column() {
            // ---- 头图 + 元信息 ----
            Row() {
              Column() {
                // s30 第 7 条：头图传 heroId（与书架 CoverCell 的 id 规则逐字符一致）
                DetailCover({
                  url: this.manga !== null ? this.manga.coverUrl : '',
                  heroId: 'cover_' + this.sourceId + '_' + this.mangaId
                })
              }
              .width(104)
              .height(139)

              Column() {
                Text(this.cvtShow(this.title))
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text1(this.isDark))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')

                // s13 第 4 条（用户 11-12 22:12 report 第 4 条）：作者行加上与下方标签同款的 chip 外观。
                // s11 那版已经能点，但外观仍是纯文本（只有按下态），用户看不出可点 ⇒ 才有这条。
                // 样式与标签共用 SearchChip（本页唯一样式源），颜色沿用标签，不改成品牌蓝：
                // 标签本来也不蓝，染蓝反而让作者像唯一可点的东西（s11 那条理由仍然成立）。
                if (this.authorName().length > 0) {
                  if (this.searchable(this.authorName())) {
                    this.SearchChip((): string => {
                      // 显示走转换，搜索入参仍是原文（转换不参与匹配，硬口径）
                      return this.cvtShow(this.authorName());
                    }, true, 6, 0, (): void => {
                      this.searchBy(this.authorName());
                    })
                  } else {
                    // 点不动就绝不长得像能点（第 3 条硬要求）：本源 id 缺失时退回纯文本档 ——
                    // 与 chip 只差底色、圆角与点击，字号和单行省略保持一致，不留死指示。
                    Text(this.cvtShow(this.authorName()))
                      .fontSize(11)
                      .fontColor(Theme.text2(this.isDark))
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                      .margin({ top: 6 })
                  }
                }

                if (this.statText().length > 0) {
                  Text(this.statText())
                    .fontSize(12)
                    .fontColor(Theme.text3(this.isDark))
                    .margin({ top: 8 })
                    .width('100%')
                }

                if (this.manga !== null && this.manga.tags.length > 0) {
                  Flex({ wrap: FlexWrap.Wrap }) {
                    // s11 第 6 条：标签本来就是「同类」的语义，点一下跳「本源 + 该标签」的搜索。
                    // ForEach 的 itemBuilder 形参 t 是箭头函数形参（不是 @Builder 形参），
                    // 按值传进来就是当次数据，闭包里直接用没有「定格首帧」那个坑
                    // （那个坑只长在 @Builder 形参上，见本文件 ActionBtn 注释）。
                    ForEach(this.manga.tags.slice(0, 6), (t: string) => {
                      // s13 第 4 条：外观一位没动（字号、内边距、底色、圆角、右边距 6、下边距 4
                      // 全部原值、数据源与 key 都没改），只是改成调用与作者行共用的 SearchChip，
                      // 样式收敛成一处。判据与作者行同一个 searchable：插件偶尔回一串空白当标签
                      // （PluginSourceAdapter.mapItem 只过掉空串、没过空白），旧版会画出一颗点不动的
                      // 空 chip ⇒ 同一条「看着能点、点了没反应」；现在这种项退回纯文本、不给底色。
                      if (this.searchable(t)) {
                        this.SearchChip((): string => {
                          // 同上：只有显示文案转换，searchBy 传原文 t
                          return this.cvtShow(t);
                        }, false, 0, 4, (): void => {
                          this.searchBy(t);
                        })
                      } else {
                        Text(this.cvtShow(t))
                          .fontSize(11)
                          .fontColor(Theme.text2(this.isDark))
                          .maxLines(99)
                          .margin({ right: 6, bottom: 4 })
                      }
                    }, (t: string) => t)
                  }
                  .width('100%')
                  .margin({ top: 8 })
                }
              }
              .layoutWeight(1)
              .margin({ left: 14 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Top)
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12 })

            // ---- 动作行（阅读 / 书架 / 点赞 / 评论）----
            // 用 ActionBtn（@Component）而不是本页 @Builder：@Builder 形参按值传递，
            // 点赞成功 / 加架成功后文案会定格在旧值（见文件上方 ActionBtn 注释）。
            Row({ space: 10 }) {
              ActionBtn({
                label: '阅读',
                sub: this.readLabel(),
                usable: this.hasChapters(),
                primary: true,
                onGo: (): void => {
                  this.onRead();
                }
              })
            }
            .width('100%')
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 16 })

            Row({ space: 10 }) {
              ActionBtn({
                label: this.inShelf ? '在书架' : '加书架',
                sub: this.inShelf ? '点击移出' : '存入本地书架',
                usable: true,
                primary: false,
                onGo: (): void => {
                  this.onShelf();
                }
              })
              ActionBtn({
                label: this.extras.stat.isLiked ? '已赞' : '点赞',
                sub: this.extras.stat.likes >= 0 ? (this.extras.stat.likes + ' 人赞')
                  : (this.extras.stat.likeAllowed === 0
                    ? (this.extras.stat.likeReason.length > 0 ? this.extras.stat.likeReason : '不支持')
                    : '插件提供'),
                usable: this.likeEnabled(),
                primary: false,
                onGo: (): void => {
                  this.onLike();
                }
              })
              ActionBtn({
                label: '评论区',
                sub: this.extras.stat.comments >= 0 ? (this.extras.stat.comments + ' 条')
                  : (this.extras.stat.commentAllowed === 0
                    ? (this.extras.stat.commentReason.length > 0 ? this.extras.stat.commentReason : '不支持')
                    : '来自插件'),
                usable: this.commentEnabled(),
                primary: false,
                onGo: (): void => {
                  this.openComments();
                }
              })
            }
            .width('100%')
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10 })

            // ---- 简介 ----
            if (this.manga !== null && this.manga.description.length > 0) {
              this.SectionCard('简介')
              Column() {
                Text(this.cvtShow(this.manga.description))
                  .fontSize(14)
                  .fontColor(Theme.text2(this.isDark))
                  .lineHeight(22)
                  .maxLines(this.descExpanded ? 1000 : 4)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(this.descExpanded ? '收起' : '展开全部')
                  .fontSize(13)
                  .fontColor(Theme.brand)
                  .margin({ top: 8 })
                  .onClick(() => {
                    Anim.to((): void => {
                      this.descExpanded = !this.descExpanded;
                    }, Anim.contentIn, Anim.curveEaseOut());
                  })
              }
              .width('100%')
              .padding(Dim.pagePadding)
              .margin({ left: Dim.pagePadding, right: Dim.pagePadding })
              .backgroundColor(Theme.cardColor(this.isDark))
              .borderRadius(Dim.radius)
              .alignItems(HorizontalAlign.Start)
            }

            // ---- 章节 ----
            if (this.hasChapters()) {
              Row() {
                Text('章节' + (this.chapters.length > 0 ? ('（' + this.chapters.length + '）') : ''))
                  .fontSize(16)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text1(this.isDark))
                  .layoutWeight(1)
                Text(this.chapterDesc ? '正序' : '倒序')
                  .fontSize(13)
                  .fontColor(Theme.brand)
                  .onClick(() => {
                    Anim.to((): void => {
                      this.chapterDesc = !this.chapterDesc;
                      this.chapterExpanded = false;
                      this.applyChapterView();
                    }, Anim.contentIn, Anim.curveEaseOut());
                  })
              }
              .width('100%')
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 18, bottom: 8 })

              Column() {
                // ★ 数据源是 @State chapterView，不是 this.chapterSlice() 方法调用；
                //   且 ForEach 的 itemBuilder **只能有一个根组件** ⇒ Row + Divider 必须包进 Column。
                ForEach(this.chapterView, (c: ChapterInfo) => {
                  Column() {
                    Row() {
                      Text(this.cvtShow(c.title))
                        .fontSize(14)
                        .fontColor(Theme.text1(this.isDark))
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .layoutWeight(1)
                      if (this.progress !== null && this.progress.chapterId === c.id) {
                        Text('读至 ' + (this.progress.page + 1) + ' 页')
                          .fontSize(11)
                          .fontColor(Theme.brand)
                          .margin({ left: 8 })
                      }
                    }
                    .width('100%')
                    .height(44)
                    .padding({ left: 4, right: 4 })
                    .onClick(() => {
                      this.openReader(c);
                    })
                    // 第 5 条(1)：章节行间分隔线删除（List 已有行距与卡片层次）
                  }
                  .width('100%')
                }, (c: ChapterInfo) => c.id)

                if (this.chapters.length > CHAPTER_PREVIEW) {
                  Text(this.chapterExpanded ? '收起' : ('展开全部 ' + this.chapters.length + ' 章'))
                    .fontSize(13)
                    .fontColor(Theme.brand)
                    .width('100%')
                    .textAlign(TextAlign.Center)
                    .padding({ top: 12, bottom: 4 })
                    .onClick(() => {
                      Anim.to((): void => {
                        this.chapterExpanded = !this.chapterExpanded;
                        this.applyChapterView();
                      }, Anim.contentIn, Anim.curveEaseOut());
                    })
                }
              }
              .width('100%')
              .padding(Dim.pagePadding)
              .margin({ left: Dim.pagePadding, right: Dim.pagePadding })
              .backgroundColor(Theme.cardColor(this.isDark))
              .borderRadius(Dim.radius)
            }

            // ---- 相关推荐（插件 recommend，没有就整段不显示）----
            if (this.extras.recommend.length > 0) {
              this.SectionCard('相关推荐')
              Scroll() {
                Row() {
                  ForEach(this.extras.recommend, (r: MangaSummary) => {
                    Column() {
                      Column() {
                        DetailCover({ url: r.coverUrl })
                      }
                      .width(96)
                      .height(128)

                      Text(this.cvtShow(r.title))
                        .fontSize(12)
                        .fontColor(Theme.text1(this.isDark))
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                        .width(96)
                        .margin({ top: 6 })
                    }
                    .width(96)
                    .margin({ right: 12 })
                    .alignItems(HorizontalAlign.Start)
                    .onClick(() => {
                      this.jumpTo(r);
                    })
                  }, (r: MangaSummary) => r.sourceId + '_' + r.id)
                }
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
              }
              .scrollable(ScrollDirection.Horizontal)
              .scrollBar(BarState.Off)
              .width('100%')
            }

            Text('数据来源：' + this.sourceName())
              .fontSize(11)
              .fontColor(Theme.text3(this.isDark))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 20, bottom: 28 })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }

  /**
   * 图源显示名。不往 SourceManager 加 nameOf（那个文件已另派他人），
   * 就地从 list() 里找：详情页一次只看一个源，线性扫一次的成本可忽略。
   */
  private sourceName(): string {
    const list: SourceInfo[] = SourceManager.getInstance().list();
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === this.sourceId) {
        return list[i].name;
      }
    }
    return this.sourceId;
  }

  /** 相关推荐点击：同图源就地换页（避免路由栈越堆越深），异图源压新页。 */
  private jumpTo(r: MangaSummary): void {
    const sid: string = r.sourceId.length > 0 ? r.sourceId : this.sourceId;
    if (sid === this.sourceId) {
      this.mangaId = r.id;
      this.sourceId = sid;
      this.title = r.title;
      this.descExpanded = false;
      this.chapterExpanded = false;
      this.reload();
      return;
    }
    const p: DetailParams = new DetailParams(r.id, sid, r.title);
    router.pushUrl({ url: 'pages/DetailPage', params: p })
      .catch((e: Object): void => {
        this.toast('打开失败：' + (e as Error).message);
      });
  }
}
