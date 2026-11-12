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
import { ReaderParams } from '../view/reader/ReaderParams';
import { SourceManager } from '../data/source/SourceManager';
import { MangaSource } from '../data/source/Source';
import { PluginDetail, ComicExtras, DetailStat } from '../data/source/PluginDetail';
import { MangaRepository } from '../data/db/MangaRepository';
import { ImageCache } from '../data/image/ImageCache';
import { MangaSummary, ChapterInfo, ReadProgress, SourceInfo } from '../data/model/Models';

/** 章节区一次显示多少条（其余靠「展开全部」）。 */
const CHAPTER_PREVIEW: number = 20;

/** 封面（详情页一张，独立组件避免和列表抢缓存引用）。 */
@Component
struct DetailCover {
  @Prop @Watch('onUrlChanged') url: string = '';
  @State pm: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.load();
  }

  onUrlChanged(): void {
    this.pm = undefined;
    this.load();
  }

  async load(): Promise<void> {
    if (this.url.length === 0) {
      return;
    }
    try {
      this.pm = await ImageCache.getInstance().load(this.url);
    } catch (e) {
      this.pm = undefined;
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
      this.loadError = '该图源已不可用（可能插件被停用或删除）';
      this.loading = false;
      return;
    }
    // 1. 详情主体（失败就是真失败 ⇒ 错误态）
    let m: MangaSummary | null = null;
    try {
      m = await src.fetchDetail(this.mangaId);
    } catch (e) {
      this.loadError = (e as Error).message;
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
      this.loadError = '该图源未返回作品信息';
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
      this.coverPm = undefined;
      return;
    }
    ImageCache.getInstance().load(m.coverUrl)
      .then((pm: image.PixelMap): void => {
        this.coverPm = pm;
      })
      .catch((_e: Object): void => {
        this.coverPm = undefined;
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
   * 与 MinePage 的 readHistoryCount（s8 二轮起 MinePage 已撤 searchHistoryCount 订阅，见 view/mine/MinePage.ets 头注释要求 6） 同口径。
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

  build() {
    Column() {
      BreezeTopBar({
        title: this.title.length > 0 ? this.title : '详情',
        showBack: true,
        onBack: () => {
          router.back();
        }
      })

      if (this.loading) {
        LoadingView({ text: '正在加载作品信息…' })
          .layoutWeight(1)
      } else if (this.loadError.length > 0 && this.manga === null) {
        ErrorView({ msg: this.loadError })
          .layoutWeight(1)
      } else {
        Scroll() {
          Column() {
            // ---- 头图 + 元信息 ----
            Row() {
              Column() {
                DetailCover({ url: this.manga !== null ? this.manga.coverUrl : '' })
              }
              .width(104)
              .height(139)

              Column() {
                Text(this.title)
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text1(this.isDark))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')

                if (this.manga !== null && this.manga.author.length > 0) {
                  Text(this.manga.author)
                    .fontSize(12)
                    .fontColor(Theme.text2(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 6 })
                    .width('100%')
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
                    ForEach(this.manga.tags.slice(0, 6), (t: string) => {
                      Text(t)
                        .fontSize(11)
                        .fontColor(Theme.text2(this.isDark))
                        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
                        .backgroundColor(Theme.fillColor(this.isDark))
                        .borderRadius(10)
                        .margin({ right: 6, bottom: 4 })
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
                Text(this.manga.description)
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
                      Text(c.title)
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

                      Text(r.title)
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
