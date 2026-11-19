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
import { ReaderView, ReaderDiag } from '../view/reader/ReaderView';
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
  /**
   * s37 B2：heldHero 这张位图是**哪个 url** 解出来的。判据「已在手」必须连 url 一起判 ——
   * 只判 heldHero !== undefined 的话，将来若出现「浮层换封面」（本页现在不会，但 DetailCover 会）
   * 就会把上一本书的封面飞回详情页。
   */
  private heroReadyUrl: string = '';
  /** 两枚定时器：飞行段 → 起淡出；淡出 → 出树。-1 = 空（同 pages/WebLoginPage.ets 的 timer 约定）。 */
  private heroFadeTimer: number = -1;
  private heroGoneTimer: number = -1;
  /**
   * s37 B1：退场那一发 router.back() 是否已经发出（幂等闸）。
   * 出页改由浮层 .onAppear 驱动（见 onHeroLayerAppear），本标记保证 onAppear 与兜底 timer 只有一发生效。
   */
  private backDispatched: boolean = false;
  /** s37 B1：兜底出页定时器（-1 = 空）。命名它而不是留匿名 setTimeout 的唯一理由 = 能在 aboutToDisappear 里取消。 */
  private exitFallbackTimer: number = -1;
  /**
   * s32 第 2 条：**进场的两枚入参留一份**（上面那两枚 AppStorage 键是一次性消费、读完就清空，
   * 退场要再挂一次浮层就得自己留着）。刻意不做成 @State：它不参与任何渲染判定，
   * 只在退场那一刻被读出来喂给 heroId/浮层（判据仍是 heroOn）。
   */
  private heroIdHold: string = '';
  private heroUrlHold: string = '';
  /**
   * s32 第 2 条：浮层处于**退场档**。true = 卡片档渲染：去掉整屏不透明占位底（否则退场时满屏
   * 都是一块盖色，看不见底下的详情页在淡出），也不做淡出（卡片要在整段飞行里保持可见）。
   */
  @State heroExit: boolean = false;
  /** s32 第 2 条：退出已接管标记（连点返回键/返回键与手势并发时，第二次不再重排一遍动画） */
  private exiting: boolean = false;

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
      // s32 第 2 条：同一份入参留档给退场用（AppStorage 那两枚键下面就被清空了）
      this.heroIdHold = hid;
      this.heroUrlHold = hurl;
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
   *
   * s37 B2：加「已在手就不再发一条完整链路」的前置判定。
   * 为什么这一条对 3(b) 有直接关系：退场那一发 requestExitWithHero 里原本**无条件**再调一次
   * loadHero ⇒ 在「多图拥塞中侧滑返回」这个具体场景下，退场瞬间又往取图链上压一条新链路
   *（即便多半内存命中，也要走完 loadPage 的整条入口 + hashName 异步往返），而这一刻恰恰是
   * 事件循环最忙、最需要空出来的时刻。已在手时直接复用手里那张（不 retain 第二次 —— 同实例
   * 重复 retain 会让持有计数只增不减，位图永久进不了淘汰，所以走「同实例即返回」而不是重挂）。
   */
  private loadHero(url: string): void {
    if (url.length === 0) {
      return;
    }
    if (this.heldHero !== undefined && this.heroReadyUrl === url) {
      return;
    }
    ImageCache.getInstance().load(url)
      .then((pm: image.PixelMap): void => {
        this.setHero(pm, url);
      })
      .catch((_e: Object): void => {
        this.setHero(undefined, '');
      });
  }

  /** 挂载/摘除唯一入口：retain 在前、unpin 在后（pages/DetailPage.ets 的 DetailCover.setShown 同款式）。 */
  private setHero(next: image.PixelMap | undefined, url: string): void {
    const prev: image.PixelMap | undefined = this.heldHero;
    if (next !== undefined) {
      ImageCache.getInstance().retain(next);
      this.heldHero = next;
      // s37 B2：url 由调用方在发请求那一刻带进来（不在这里读 heroUrlHold）—— 将来若浮层支持
      // 换封面，"手里这张是哪个地址解出来的"仍然记不错。
      this.heroReadyUrl = url;
    } else {
      this.heldHero = undefined;
      this.heroReadyUrl = '';
    }
    this.heroPm = next;
    if (prev !== undefined && prev !== next) {
      ImageCache.getInstance().unpin(prev);
    }
  }

  /**
   * s32 第 2 条（用户原话「从书籍详情页进入书本和从书本退出到书籍详情页动画仍不统一，
   * 应当统一使用淡入淡出或飞入飞出」）：**退出时的封面飞回**，与进场那趟是同一条共享元素线、
   * 同一个 id、同一组参数 ⇒ 两向观感成对。
   * 三个必须：
   * ① 浮层必须**在 router.back() 之前**挂回树上 —— pageTransition 起转场的那一刻，
   *    共享元素两端节点得都已存在，晚一帧挂就是「封面突然消失」的半截动画（与进场那条同理）；
   *    所以排 Anim.heroExitBeat（一拍 = 32 ms）让节点先走完一次布局再出页。
   * ② 退场档**去掉整屏盖色**：进场时那层不透明盖色是必要的（它撑住「封面展开成阅读页」的背景），
   *    退场时留着它就等于满屏盖色、看不见详情页在淡出 ⇒ 卡片档只留卡片本身。
   * ③ 没有封面可飞（详情页没封面 / 从首页「继续阅读」直连阅读器）⇒ 返回 false，
   *    调用方照旧直接出页 = 只剩两页同参淡入淡出，仍是成对的（不做半截动画）。
   * @returns true = 本方法已接管退出（稍后自己 router.back），调用方不要再出页。
   */
  requestExitWithHero(): boolean {
    if (this.heroIdHold.length === 0 || this.heroUrlHold.length === 0) {
      return false;
    }
    if (this.exiting) {
      // 已经在演了：吞掉这一次，避免连点把 router.back 排两遍。
      // ★ 这里刻意**不**改成"已经发过页就 return false 让框架自己出页"：那种自逃生口在
      // "router.back 已生效、转场正在进行"的时刻会把第二次返回也放行 = 多弹一层（比慢一拍严重得多）。
      // 真正的失败处置放在 dispatchExit 的 catch 里（发页抛异常时把闸门交还给兜底计时器重发一次）。
      return true;
    }
    this.exiting = true;
    // 进场那两套 timer 可能还在飞（进页就立刻返回）：先停干净，否则淡出/摘层的 timer
    // 会在退场浮层上乱插手，把正在飞的卡片半路抹掉。
    if (this.heroFadeTimer >= 0) {
      clearTimeout(this.heroFadeTimer);
      this.heroFadeTimer = -1;
    }
    if (this.heroGoneTimer >= 0) {
      clearTimeout(this.heroGoneTimer);
      this.heroGoneTimer = -1;
    }
    this.heroExit = true;
    this.heroOn = true;
    this.heroId = this.heroIdHold;
    this.heroOpacity = 1;
    this.loadHero(this.heroUrlHold);
    // 出树 timer 照排一个：正常情况下本页随 router.back 销毁、aboutToDisappear 兜底清理，
    // 留着是为了「router.back 失败（路由栈异常）」那种边角不致留一层永久盖住的浮层。
    this.heroGoneTimer = setTimeout((): void => {
      this.heroGoneTimer = -1;
      this.dropHero();
      this.heroExit = false;
      this.exiting = false;
    }, Anim.pageHero + Anim.heroSlack);
    // s37 B1：出页那一发**改由浮层 .onAppear 驱动**（见 onHeroLayerAppear），这里只留兜底一拍。
    // 为什么原样保留这一发（它是本次改动的可放行理由）：3(b) 的现场形态是「拥塞中侧滑返回，
    // 退场动画卡顿/丢失」，而原本出页时机 = setTimeout(Anim.heroExitBeat=32) —— 一个纯时间约定。
    // 事件循环被十几条取图链（每条含同步整文件 IO + 解码往返）压住时，这一拍会被**任意延后**：
    // 延后本身让用户觉得「按了没反应」，更糟的是浮层节点其实早就建好了，却还在等一个迟到的计时器，
    // 于是「节点已就绪」这个真实信号被浪费，白等。
    // 现在把"就绪"这件事交还给框架（浮层落地即 onAppear → 立刻出页），计时器退化成兜底：
    // 最坏情形（本机 onAppear 不触发 / 浮层因 heroOn 原本就为 true 而没有新的挂载事件）= 32 ms 后照旧出页
    // = 与改造前逐字等价，**不会**出现"出不去"。刻意不给兜底加大时长：加大 = 让 onAppear 缺失时更慢。
    this.backDispatched = false;
    this.exitFallbackTimer = setTimeout((): void => {
      this.exitFallbackTimer = -1;
      this.dispatchExit(false);
    }, Anim.heroExitBeat);
    return true;
  }

  /**
   * s37 B1：浮层落地的挂载回调 —— 「两端节点都已在树上」这个信号的**权威来源**（框架告诉我们的），
   * 取代原先靠 32 ms 计时器猜。只在本页处于退场档时才发车，进场档（进页那一趟）什么都不做。
   * 挂在浮层外层 Column 上（不是卡片 Stack）：外层这枚节点才是「整屏浮层已进树」的粒度，
   * 且它在进场/退场两档都随 heroOn 一起挂载，onAppear 语义在两档一致。
   */
  onHeroLayerAppear(): void {
    if (!this.heroExit) {
      return;
    }
    this.dispatchExit(true);
  }

  /**
   * s37 B1：出页发车的唯一出口（幂等：onAppear 与兜底计时器只有一发能真正发出 router.back）。
   * @param byAppear true = 浮层 onAppear 驱动（正常档）；false = 兜底计时器到点（拥塞档）。
   *   两档各自记一笔，读数在 17 号行 ex=（ReaderDiag.exitAppear/exitTimer）：
   *   t 明显 > 0 = 浮层落地被拖过 32 ms，正是 3(b) 的直接证据；a 占绝大多数 = B1 生效。
   *
   * ★ onAppear 是在一次挂载回调里被调的，也就是"渲染/布局正在收尾"的时刻 —— 在这上面发 router.back()
   *   是本批唯一未在本机证实的框架行为（无真机、hdc 不可用）。因此这里对发页本身包了 catch：
   *   万一框架在挂载回调里拒绝切路由，就把闸门退回未发状态并重排兜底计时器 = 退化成改造前的行为，
   *   而不是"用户按了返回却永久留在阅读器里"。这条兜底路径本身也记在 t 档里，真机一眼能看出走到过。
   */
  private dispatchExit(byAppear: boolean): void {
    if (this.backDispatched) {
      return;
    }
    if (this.exitFallbackTimer >= 0) {
      clearTimeout(this.exitFallbackTimer);
      this.exitFallbackTimer = -1;
    }
    if (byAppear) {
      ReaderDiag.exitAppear += 1;
    } else {
      ReaderDiag.exitTimer += 1;
    }
    try {
      this.backDispatched = true;
      router.back();
    } catch (e) {
      // 发页失败：闸门交还，重排一拍兜底再试一次（只在 byAppear 失败时才会走到这里；
      // 兜底档自己失败就没有下一条腿了，此时留着 exiting=true 由用户再按一次返回走 onBackPress 的吞并分支）。
      this.backDispatched = false;
      ReaderDiag.exitFail += 1;
      if (byAppear) {
        this.exitFallbackTimer = setTimeout((): void => {
          this.exitFallbackTimer = -1;
          this.dispatchExit(false);
        }, Anim.heroExitBeat);
      }
    }
  }

  /**
   * s32 第 2 条：系统返回键 / 侧滑手势与顶栏返回箭头**同一条退场线**（否则按返回键就绕过飞行，
   * 又变成「一个方向有飞、另一个方向没飞」）。@Entry + router 页才有这个回调（common.d.ts:24694，
   * @since 7）；返回 true = 自处理、框架不再默认出页 —— 出页由 requestExitWithHero 里那一拍代发
   *（s37 B1 起那一拍变成兜底，正常由浮层 onAppear 提前代发，见 dispatchExit）。
   */
  onBackPress(): boolean {
    return this.requestExitWithHero();
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
    // s37 B1：闸门随浮层一起复位。不复位 = 第二次退出时 dispatchExit 首行直接吞掉，
    // 而兜底 timer 也在 backDispatched=true 下不再发页 = 返回键永久失灵（exiting 由
    // requestExitWithHero 自己管，这里不能顺手清它，否则 router.back 还没落地就被放行第二次接管）。
    this.backDispatched = false;
    this.setHero(undefined, '');
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
    // s37 B1：兜底出页定时器必须在这里取消 —— 它是唯一能在页面销毁后再碰状态的一发
    //（其余两枚原本就有清理）。不取消的后果 = 页面已出栈、回调仍跑一次 dispatchExit，
    // 在已销毁实例上再发一次 router.back()（会多弹一层，是最难查的那种缺陷）。
    if (this.exitFallbackTimer >= 0) {
      clearTimeout(this.exitFallbackTimer);
      this.exitFallbackTimer = -1;
    }
    // s32 第 2 条：退场档与接管标记一并复位（本页是 @Entry，正常随出页销毁；
    // 留这一手是给路由复用实例那种边角，别把 exiting=true 带到下一次进页 = 返回键永久失灵）
    this.heroExit = false;
    this.exiting = false;
    // s37 B1：出页闸门一并复位（同上理由：路由复用实例时带着 true 进页 = 返回键失灵）
    this.backDispatched = false;
    this.setHero(undefined, '');
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
          chapterId: this.params.chapterId,
          // s32 第 2 条：顶栏返回箭头先问本页要不要演封面飞回（不演就返回 false 让 ReaderView 自己出页）
          onExitReader: (): boolean => this.requestExitWithHero()
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
            type: SharedTransitionEffectType.Exchange,
            // s32 第 1 条：三处共享元素（书架 CoverCell / 详情头图 / 这里）同值飞行层序
            zIndex: Anim.heroZ
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        // s32 第 2 条：进场档 = 整屏不透明盖色（撑住「封面展开成阅读页」）；
        // 退场档 = **透明**，只留那枚正在飞回详情头图槽位的卡片。
        .backgroundColor(this.heroExit ? Color.Transparent : Theme.coverColor(this.isDark))
        .opacity(this.heroOpacity)
        // s32 第 2 条：退场档这层是透明的且页面马上就要出栈，刻意放行命中（None = 自身不响应
        // 也不挡下层，见 key 记忆里 hitTestBehavior 那条）；进场档维持默认 Default 阻断误触（理由见下）。
        .hitTestBehavior(this.heroExit ? HitTestMode.None : HitTestMode.Default)
        // s37 B1：退场发车的驱动点。浮层这枚节点挂上树（= 共享元素两端节点已齐）就叫 onHeroLayerAppear，
        // 页面随之出栈；进场档 heroExit 为 false，回调里第一行就 return，不产生任何新行为。
        // ★ 必须与 requestExitWithHero 里那发兜底 timer 配套（backDispatched 幂等），二者只有一发能出页。
        .onAppear((): void => {
          this.onHeroLayerAppear();
        })
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
