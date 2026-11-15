/**
 * 职责：阅读器路由页（二级页，无底栏、无公共顶栏，顶栏由 ReaderView 自行控制显隐）。
 * 依赖：view/reader/ReaderView、view/reader/ReaderParams。
 * 第 4 条：本页面加 onPageHide 推 historyRevision。阅读进度落库点在 view/reader/ReaderView.ets 的 saveProgress
 *   （换页与返回键都调，很频繁）⇒ 不在那里查条数；退出阅读器的出口（返回键、手势返回、被新页压栈）只有本页的
 *   onPageHide 全覆盖，所以只推一个版本号，条数由 view/mine/MinePage.ets 自己重算。
 * 对应 Flutter：lib/page/comic_read/comic_read_page.dart。
 */
import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { ReaderParams } from '../view/reader/ReaderParams';
import { ReaderView } from '../view/reader/ReaderView';
import { Theme, Dim } from '../view/common/Theme';
import { Anim } from '../view/common/Anim';
import { ImageCache } from '../data/image/ImageCache';

/**
 * s31 第 7 条：封面浮层的两个 AppStorage 键名。写点 = pages/DetailPage.ets 的 openReader（pushUrl 之前），
 * 读点 = 本页 aboutToAppear（读一次，读完立刻写空串清空）。
 * ★ 两处字符串必须与 DetailPage 里那两枚**逐字一致**（对不上 = 浮层不出现，只剩淡入，不报错）；
 *   本应放进 view/common/Theme.ets 的 AppKeys（全站键名唯一真源），但那份文件不在本批写域内，
 *   已登记给 lead 择机上收，这里先就近写死并注明。
 */
const HERO_ID_KEY: string = 'heroCoverId';
const HERO_URL_KEY: string = 'heroCoverUrl';

@Entry
@Component
struct ReaderPage {
  @State params: ReaderParams = new ReaderParams();
  @StorageProp('isDark') isDark: boolean = false;
  /** s31 第 7 条：封面浮层总开关。false = 整块浮层**不进组件树**（首选降级：没有共享语义就不演）。 */
  @State heroOn: boolean = false;
  /** 浮层卡片的共享元素 id（与详情页头图那枚逐字相同；空串 = 不参与共享转场，SDK 原文）。 */
  @State heroId: string = '';
  /** 卡片内的封面位图：没解出来时留不透明占位底色，★ 绝不留纯黑（纯黑就是用户说的那次闪烁）。 */
  @State heroPm: image.PixelMap | undefined = undefined;
  /** 浮层整体透明度：1 = 完全盖住；退场动画把它插值到 0，再由尾 timer 把整层摘掉。 */
  @State heroOpacity: number = 1;
  /**
   * 持有账本（与 DetailCover.held / ReaderView.held 同一口径，s21 黑区那条）：
   * 正在显示的位图必须 retain，否则「清理图片缓存」或 LRU 淘汰会把它 release 掉 ⇒ Image 画整幅纯黑。
   */
  private heldHero: image.PixelMap | undefined = undefined;
  /** 两枚定时器：飞行段 → 起淡出；淡出 → 出树。-1 = 空（同 pages/WebLoginPage.ets 的 timer 约定）。 */
  private heroFadeTimer: number = -1;
  private heroGoneTimer: number = -1;

  aboutToAppear(): void {
    try {
      const raw: Object = router.getParams();
      if (raw instanceof ReaderParams) {
        this.params = raw;
      } else if (raw !== null && raw !== undefined) {
        // 兼容仅传 JSON 对象的场景：逐字段读取，避免 ArkTS 结构类型互赋
        const p: ReaderParams = new ReaderParams();
        const src: ESObject = raw;
        p.mangaId = src.mangaId !== undefined ? String(src.mangaId) : '';
        p.sourceId = src.sourceId !== undefined ? String(src.sourceId) : '';
        p.title = src.title !== undefined ? String(src.title) : '';
        p.chapterId = src.chapterId !== undefined ? String(src.chapterId) : '';
        this.params = p;
      }
    } catch (e) {
      // 参数缺失时保持空路由参数，ReaderView 内做空态处理
    }

    // s31 第 7 条：读共享元素入参。**必须在 aboutToAppear**（不是 onPageShow）：浮层节点要在
    // 本页第一帧就存在于组件树里，共享元素才有落点；晚一帧建就变成「封面突然消失」的半截动画。
    // 读到空串（首页「继续阅读」直连阅读器 / 详情页无封面 / 上一次没清干净）⇒ heroOn 保持 false，
    // 浮层整块不渲染，本页只剩第 6 条那一档淡入 = 不演半截动画。
    const hid: string = AppStorage.get<string>(HERO_ID_KEY) ?? '';
    const hurl: string = AppStorage.get<string>(HERO_URL_KEY) ?? '';
    if (hid.length > 0 && hurl.length > 0) {
      this.heroId = hid;
      this.heroOn = true;
      this.loadHero(hurl);
      const gap: number = Anim.pageHero + Anim.heroSlack;
      this.heroFadeTimer = setTimeout((): void => {
        this.startHeroOut();
      }, gap);
    }
    // 一次性消费：立刻把两个键写回空串（不用 AppStorage.delete，留空串与「读不到」同一形态，
    // 读侧只用 length 判据，少一种分支）。不清 = 下次从首页直连阅读器会把上次的封面再演一遍。
    AppStorage.setOrCreate<string>(HERO_ID_KEY, '');
    AppStorage.setOrCreate<string>(HERO_URL_KEY, '');
  }

  /**
   * s31 第 7 条：浮层内封面的取图走 ImageCache（详情页刚显示过同一张，基本命中内存，
   * 与 DetailCover 用的是同一份缓存实例），失败只留占位底色 —— 浮层的可见性不依赖这张图。
   */
  private loadHero(url: string): void {
    ImageCache.getInstance().load(url)
      .then((pm: image.PixelMap): void => {
        this.setHero(pm);
      })
      .catch((_e: Object): void => {
        this.setHero(undefined);
      });
  }

  /** 挂载/摘除唯一入口：retain 在前、unpin 在后（pages/DetailPage.ets 的 DetailCover.setShown 同款式）。 */
  private setHero(next: image.PixelMap | undefined): void {
    const prev: image.PixelMap | undefined = this.heldHero;
    if (next !== undefined) {
      ImageCache.getInstance().retain(next);
      this.heldHero = next;
    } else {
      this.heldHero = undefined;
    }
    this.heroPm = next;
    if (prev !== undefined && prev !== next) {
      ImageCache.getInstance().unpin(prev);
    }
  }

  /** 飞行段（含余量）走完：淡出浮层，再排尾 timer 把整层摘掉。 */
  private startHeroOut(): void {
    this.heroFadeTimer = -1;
    const out: number = Anim.heroFadeOut;
    Anim.to((): void => {
      this.heroOpacity = 0;
    }, out, Anim.curveEaseOut());
    const tail: number = out + Anim.heroSlack;
    this.heroGoneTimer = setTimeout((): void => {
      this.dropHero();
    }, tail);
  }

  /**
   * 收尾：整层出树 + id 归零 + 解持有。
   * ★ heroId 必须清：残留的同 id 组件会在下一次进阅读器时被共享元素当成另一端（一 id 至多两枚），
   *   残留 = 转场挑错目标（书架 CoverCell 那行注释写的就是这个坑）。
   * ★ heroOpacity 复位到 1 是给下一次进页用的：浮层重进时应当是「盖住」状态，不能停在 0 的淡出末值。
   */
  private dropHero(): void {
    this.heroGoneTimer = -1;
    this.heroOn = false;
    this.heroId = '';
    this.heroOpacity = 1;
    this.setHero(undefined);
  }

  /**
   * s31 第 7 条：退出路径上的兜底清理。用户在飞行途中按返回 → 两枚定时器都还在，
   * 不清就会在页面销毁后回调状态写入；位图也必须在这里解持有（否则这一张永久进不了淘汰）。
   */
  aboutToDisappear(): void {
    if (this.heroFadeTimer >= 0) {
      clearTimeout(this.heroFadeTimer);
      this.heroFadeTimer = -1;
    }
    if (this.heroGoneTimer >= 0) {
      clearTimeout(this.heroGoneTimer);
      this.heroGoneTimer = -1;
    }
    this.setHero(undefined);
  }

  /**
   * 第 4 条：@Entry 页被 router 弹出或被新页盖住都会回调 onPageHide ⇒ 这是退出阅读器的全覆盖出口。
   * 这里只推版本号、不查库（查库与口径判断都在 MinePage.recountHistory，与 HistoryPage 同一条 SELECT）。
   */
  onPageHide(): void {
    AppStorage.setOrCreate<number>('historyRevision', (AppStorage.get<number>('historyRevision') ?? 0) + 1);
  }

  /**
   * s31 第 7 条（黑色闪烁的直接处置，取代 s30 那条「与详情页同一条推拉线」）：
   * 本页根容器在深色下是 Theme.dBg = #000000，ReaderView 的阅读区根底也恒 Theme.black（key 记忆：
   * 黑区那条口径）。推拉档等于把**一整块带硬边的黑色矩形横扫过屏幕**，用户回传的「整体会发生黑色
   * 闪烁」就是这个硬边，不是黑位图、也不是布局间隙。
   * 改成同参数交叉淡入淡出：下层页面一直在底，只是上层逐渐显影 ⇒ 全程没有硬边可扫；
   * 再叠上封面浮层（飞行途中的背景是 Theme.coverColor 的**不透明**占位色，浅色 #E5E8EA / 深色 #2C2C2E，
   * 两个都不是纯黑），观感即第 7 条要的「封面飞向中间、向四周展开形成阅读页」。
   * s30 那条「刻意不挂共享元素」的理由（阅读中的大图不该被当封面延续）仍然成立并保留：
   * 挂共享元素的是浮层里那枚**封面卡片**，不是 ReaderView 的页图。
   * 与详情页同 duration 同 curve ⇒ 进/退对称（第 6 条口径同样适用于详情页↔阅读器）。
   */
  pageTransition() {
    PageTransitionEnter({ duration: Anim.pageHero, curve: Anim.curveEaseOut() })
      .opacity(0);
    PageTransitionExit({ duration: Anim.pageHero, curve: Anim.curveEaseOut() })
      .opacity(0);
  }

  build() {
    // s31 第 7 条：根容器由 Column 换成 Stack —— 浮层要叠在 ReaderView 之上（Stack 后置子节点在上），
    // 底下那枚 Column 的宽高与底色一字未动（阅读底色仍由 isDark 决定）。
    Stack() {
      Column() {
        ReaderView({
          mangaId: this.params.mangaId,
          sourceId: this.params.sourceId,
          title: this.params.title,
          chapterId: this.params.chapterId
        })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.isDark ? '#000000' : Theme.bg)

      if (this.heroOn) {
        // 封面浮层：一整屏不透明占位底 + 居中一枚等比卡片。用户要的是「封面飞向中间，向四周展开形成
        // 阅读页」⇒ 卡片落点取**屏幕中央、宽 72%、3:4 等比**（由小变大 = 向四周展开），
        // 展开到位后再把整层淡掉，底下已经加载好的阅读页显影 = 「形成阅读页」。
        // ★ 为什么不把落点做成 100% 整屏：封面是 3:4 竖图，铺满整屏要么按 Cover 裁掉上下（飞进来的
        //   过程中封面变形很凶），要么按 Contain 在整屏里留上下黑边（又把黑色请回来了）。
        Column() {
          // 共享元素挂在**容器**上而不是内部 Image —— 与 pages/DetailPage.ets:127-129 同一取证理由：
          // 封面是异步解码的 PixelMap，挂 Image 上时那一帧若还没解出来，飞过去的就是一块空块/黑块。
          // 容器自带不透明占位底色，飞行途中用户看到的永远是一张不透明卡片从小变大。
          // ★ 刻意不写 constraintSize：SDK common.d.ts:20538-20540 明写 constraintSize 优先级高于
          //   aspectRatio，写上去会把等比落高静默夹掉，容器比 != 位图比就又开始留黑边。
          Stack() {
            if (this.heroPm !== undefined) {
              Image(this.heroPm)
                .width('100%')
                .height('100%')
                .objectFit(ImageFit.Cover)
                .draggable(false)
            }
          }
          .width('72%')
          .aspectRatio(Dim.coverRatio)
          .borderRadius(Dim.coverRadius)
          .clip(true)
          .backgroundColor(Theme.coverColor(this.isDark))
          .sharedTransition(this.heroId, {
            duration: Anim.pageHero,
            curve: Anim.curveEaseOut(),
            type: SharedTransitionEffectType.Exchange
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(Theme.coverColor(this.isDark))
        .opacity(this.heroOpacity)
        // 命中测试说明（真机要盯的一条）：浮层是不透明节点且默认 HitTestMode.Default
        // （enums.d.ts:3292/:3294：自身响应命中并**阻断**下层），所以飞行 + 淡出的约 0.65 秒里
        // 落在浮层上的点击不会漏给下面的阅读器。刻意不给 hitTestBehavior(None)：那会把这段时间
        // 变成「点得到底下阅读器」，比吞掉一次误触更糟。
      }
    }
    .width('100%')
    .height('100%')
  }
}
