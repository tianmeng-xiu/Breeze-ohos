/**
 * 职责：底部标签栏（华为 BottomTab UX 规范·**悬浮胶囊形态**）+ 3 个一级页面的容器。
 * 依赖：Theme/Dim（../common/Theme）、SafeAreaUtil（../common/SafeArea）、Material（./Material）、
 *      Anim（./Anim）、3 个一级页面组件。
 * 对应 Flutter：lib/page/navigation_bar.dart（PersistentTabView，NavBarStyle.style3，5 个 tab）。
 * 实施依据：三档降级链（HDS 材质为主 / 自绘胶囊为退 / 平铺为兜底），运行时按能力探测选层，探测见 Material.ets。
 *
 * ===== 三档换层（SurfaceMaterial.tier() 一次算出，见 Material.ets）=====
 *  tier=2 HDS 悬浮：HdsTabs + .barFloatingStyle({barSideMargin, barBottomMargin,
 *                   systemMaterialEffect:{IMMERSIVE,ADAPTIVE}, thermoCtrl:true})
 *  tier=1 原生悬浮：Tabs + .barOverlap(true) + .barFloatingStyle({..., systemMaterial: ImmersiveMaterial(REGULAR)})
 *  tier=0 平铺兜底：Tabs + .barOverlap(true) + 透明 barBackgroundColor + .barBackgroundBlurStyle(COMPONENT_THICK)
 *                   （UX 规范 §8 原法，API 12 起可用；此档**仍保留**旧的导航条手工避让，因为它贴边不平铺悬浮）
 *
 * ===== D3 双重避让已修（tier>=1）=====
 *  华为 BottomTab 规范 §2：「控件默认避让导航条，悬浮式默认 56vp」。
 *  改造前是 `.barHeight(Dim.bottomBarH + this.bottomSafe)` + TabItem `.padding({bottom: bottomSafe})`
 *  两处叠加 ⇒ 底栏到屏幕底边出现「两倍导航条高度」的空隙。
 *  现在：tier>=1 只给 `.barHeight(Dim.floatingBarH)`（56vp，不含 bottomSafe），TabItem 不再补底部 padding，
 *        避让交给悬浮式自身 + barBottomMargin；tier=0 维持旧行为（平铺栏确实需要避让）。
 *
 * ===== 图标（S0 §1.5 已逐名实测，编译器会校验 sys.symbol 名）=====
 *  house / cloud / book_pages / discover / ellipsis_message（各带 _fill）。
 *  BounceSymbolEffect 构造默认 = EffectScope.LAYER + EffectDirection.DOWN，
 *  与 UX 规范 §5 推荐一致，故不传参（symbolglyph.d.ts:487-500 实证默认值）。
 *  老设备 HM Symbol 字体可能缺字形（编译期校验不了运行期）⇒ 保留 PNG 回退：
 *  把 USE_SYMBOL_ICON 改成 false 即整栏退回三态 PNG，其余改造不受影响。
 */

import { Theme, Dim } from '../common/Theme';
import { SafeAreaUtil } from '../common/SafeArea';
import { SurfaceMaterial, Tier, MatKeys } from './Material';
import { TabAutoHide } from './TabAutoHide';
import { Anim } from './Anim';
import { common } from '@kit.AbilityKit';
import {
  HdsTabs,
  HdsTabsController,
  HdsTabsFloatingStyle,
  HdsTabsBackgroundStyle
} from '@kit.UIDesignKit';
import { BookshelfPage } from '../bookshelf/BookshelfPage';
import { DiscoverPage } from '../discover/DiscoverPage';
import { MinePage } from '../mine/MinePage';

/** 页签元数据：供底栏与 Index 顶栏共用（标题顺序必须与 TabContent 顺序一致）
 *  s5g 收敛为 4 签：用户反馈「首页和书架重复，内容一致，留一个就行」⇒ 去掉首页签，
 *  书架升为第 0 签（与原版 Flutter 底栏首签=书架一致）。HomePage.ets 暂留不删（继续阅读区块将来并入书架）。
 *  s14 第 2 条起三签（用户 report.txt 第 2 条「云收藏不再单列一页，放进『更多』页作为一项，命名『从云端同步』」）
 *  ⇒ 0 书架 / 1 发现 / 2 更多；云收藏整条撤出底栏，功能不删，改由 router 页 pages/CloudSyncPage 承载，
 *  入口在 view/mine/MinePage 的「从云端同步」行。旧的 0 书架 / 1 发现 / 2 云收藏 / 3 更多 口径自本行起作废。
 */
export class TabMeta {
  static readonly titles: string[] = ['书架', '发现', '更多'];
  static readonly count: number = 3;

  /** 未选中图标名（S0 §1.5 逐名核实存在；未核实的一律不用） */
  static readonly symbols: string[] = [
    'sys.symbol.book_pages',
    'sys.symbol.discover',
    'sys.symbol.ellipsis_message'
  ];
  /** 选中图标名 */
  static readonly symbolsFill: string[] = [
    'sys.symbol.book_pages_fill',
    'sys.symbol.discover_fill',
    'sys.symbol.ellipsis_message_fill'
  ];

  static titleOf(index: number): string {
    if (index < 0 || index >= TabMeta.titles.length) {
      return TabMeta.titles[0];
    }
    return TabMeta.titles[index];
  }

  /** 资源 id 查表必须走 $r() 的字面量，动态拼字符串编译不过 ⇒ 只能逐名下标 */
  static iconRes(index: number, selected: boolean): Resource {
    const names: string[] = selected ? TabMeta.symbolsFill : TabMeta.symbols;
    if (index === 0) {
      return $r(names[0]);
    }
    if (index === 1) {
      return $r(names[1]);
    }
    // s14 第 2 条起三签：第 2 名 = 更多（ellipsis_message），故兜底档也回到 names[2]
    return $r(names[2]);
  }
}

@Component
export struct BreezeBottomTab {
  /** 当前页签下标（与 Index 共享，父组件用 $currentIndex 传入） */
  @Link currentIndex: number;
  /** 页签切换回调 */
  onChange: (index: number) => void = (index: number) => {};
  /**
   * 再次点击「当前已选中」页签的回调（华为 BottomTab 规范：已选中页签再点 → 回到顶部 / 刷新当前页）。
   * 由 Index 选择接入（默认空实现），扩展点不改变现有 5 个页签的行为。
   */
  onReselect: (index: number) => void = (index: number) => {};

  @StorageProp('bottomSafeHeight') bottomSafe: number = 0;
  @StorageProp('isDark') isDark: boolean = false;

  /** Symbol 图标总开关：真机若出现空图标（老设备字体缺字形）改 false 即整栏回退 PNG（UI 计划 R2 兜底） */
  private readonly USE_SYMBOL_ICON: boolean = true;

  /** 页签切换控制器（官方文档推荐：跨页签跳转用 changeIndex，比只改 index 更可靠） */
  private controller: TabsController = new TabsController();
  /** tier=2 用 HDS 控制器（继承 TabsController ⇒ changeIndex 同源；额外有 applyHide/ShowAnimation 供阅读页） */
  private hdsController: HdsTabsController = new HdsTabsController();

  /** 运行时档位（aboutToAppear 里算一次，禁每帧算 —— Material.ets 内部亦缓存） */
  @State private tier: number = Tier.FLAT;
  /**
   * 悬浮胶囊开关（s5e 真机修正）：与材质能力解耦。真机无沉浸材质（tier=0）但 API26 满足
   * Tabs.barFloatingStyle（@since 26.0.0，FloatingTabBarStyle 全字段 optional）⇒ 仍走悬浮档，
   * 只是胶囊底色用不透明等价色兜底（Theme.capsuleFallback）而非材质。
   * ⚠ s5g 真机二次证伪：本档（原生 Tabs + barFloatingStyle 不带 systemMaterial）在 SGT-AL10 上
   * 仍渲染成**平铺全宽栏**（用户反馈「底栏未成胶囊」）⇒ 悬浮主力改走 HdsTabs（见 useHds）。
   */
  @State private floatMode: boolean = false;
  /**
   * s5g 悬浮主力闸门：NextE（erosTeam/NextE, entry/pages/Index.ets:2724-2815）在同类华为机上
   * **无条件**使用 HdsTabs + barFloatingStyle{systemMaterialEffect}，材质不支持时只是把参数
   * 换成 ADAPTIVE/ADAPTIVE（ImmersiveMaterialSettings.effect():127-131），从不因此退回平铺。
   * 本文件 s5f 之前把「无 IMMERSIVE 材质」当成「不能悬浮」，是连续两版底栏不浮的根因。
   * @kit.UIDesignKit 是静态 import 且 s5f 已在该 ROM 正常加载 ⇒ HdsTabs 可无条件使用；
   * 这里只在 hdsParamsAuto() 真的抛错（极端 ROM 缺库）时才退到原生/平铺分支。
   */
  @State private useHds: boolean = true;
  /**
   * 一行回退开关（s5g）：若某 ROM 上 HdsTabs 整个不渲染（非华为 OpenHarmony 设备），
   * 把它改成 true 即强制走原生 Tabs 分支（tier1 材质档 / 平铺档），不需要动其它代码。
   */
  private readonly FORCE_NATIVE_TABS: boolean = false;

  aboutToAppear(): void {
    SafeAreaUtil.sync(getContext(this) as common.UIAbilityContext);
    this.tier = SurfaceMaterial.tier();
    this.floatMode = SurfaceMaterial.floating();
    if (this.FORCE_NATIVE_TABS) {
      this.useHds = false;
    } else {
      try {
        SurfaceMaterial.hdsParamsAuto();
      } catch (err) {
        this.useHds = false;
      }
    }
    // Anim.to() 需要 UIContext 才能走 animateTo（Anim.ets 文件头约定在此绑定）
    Anim.bind(this.getUIContext());
    // 诊断取证：写「实际渲染分支」而非探测档位（s5g，见 MatKeys.barMode 注释）
    const mode: string = this.useHds
      ? 'hds'
      : (this.tier === Tier.NATIVE ? 'native-material' : (this.floatMode ? 'native-float' : 'native-flat'));
    AppStorage.setOrCreate<string>(MatKeys.barMode, mode);
  }

  /** 页签图标：选中 / 未选中、浅色 / 深色 分别对应一张 PNG（PNG 无法用 fillColor 着色，故预生成三套）
   *  s14 第 2 条起顺序 = TabMeta.titles（0 书架 / 1 发现 / 2 更多）；首页签与云收藏签都已移出底栏，
   *  故 ic_tab_home_* 与 ic_tab_cloud_* 两组 PNG 不再被引用（文件按出包红线原地保留，不删）。
   */
  private tabIcon(index: number, selected: boolean): Resource {
    const dark: boolean = this.isDark;
    if (index === 0) {
      return selected ? $r('app.media.ic_tab_shelf_sel') : (dark ? $r('app.media.ic_tab_shelf_d') : $r('app.media.ic_tab_shelf'));
    }
    if (index === 1) {
      return selected ? $r('app.media.ic_tab_discover_sel') : (dark ? $r('app.media.ic_tab_discover_d') : $r('app.media.ic_tab_discover'));
    }
    // s14 第 2 条起三签：第 2 名 = 更多 ⇒ 云收藏那一对 ic_tab_cloud_* 退出查表（PNG 原地保留）
    return selected ? $r('app.media.ic_tab_more_sel') : (dark ? $r('app.media.ic_tab_more_d') : $r('app.media.ic_tab_more'));
  }

  /** 页内跳转到其它一级页签（如首页「去发现」、书架空态「去发现」） */
  private jumpTo(index: number): void {
    if (index < 0 || index >= TabMeta.count || index === this.currentIndex) {
      return;
    }
    this.currentIndex = index;
    this.onChange(index);
    if (this.useHds) {
      this.hdsController.changeIndex(index);
    } else {
      this.controller.changeIndex(index);
    }
  }

  /** 对外签名不变：Index / 其它页仍可通过它跨页签跳转 */
  getController(): TabsController {
    return this.useHds ? this.hdsController : this.controller;
  }

  /**
   * T1（s5i 重写）：把当前生效的控制器交给 TabAutoHide。**收起动作由 TabAutoHide 显式调用**，
   * 不再指望框架自动收起 —— 真机 s5h 反馈「底栏下沉无反应」的根因就是 s5h 只 bind 不执行
   * （原生 TabsController 压根没有隐藏 API，HDS 才有 applyHideAnimation；详见 TabAutoHide 文件头）。
   * 三个分支的差别：
   *   HdsTabs（真机主力）→ applyHide/ShowAnimation + bindScroller 联动登记
   *   原生悬浮档         → setTabBarTranslate/Opacity，**刻意不 bind**（bind 会让这两个 setter 失效）
   *   平铺档             → 不收起（贴边栏收起会露出导航条区域空白）⇒ unbindAll() 置 off
   */
  private bindAutoHide(): void {
    if (this.useHds) {
      TabAutoHide.bindController(this.hdsController, null, 0);
    } else if (this.floatMode) {
      // 收起位移 = 胶囊高 + 底距（整颗胶囊沉到屏幕下沿之外）
      TabAutoHide.bindController(null, this.controller, Dim.floatingBarH + Dim.floatingBarBottom);
    } else {
      TabAutoHide.unbindAll();
    }
  }

  /**
   * 图标节点：Symbol（带选中弹跳）或 PNG 回退。
   * 两支都用 24vp（Dim.tabIcon），Symbol 用 fontColor 数组着色 ⇒ 不再需要三套 PNG。
   */
  @Builder
  TabIcon(index: number) {
    if (this.USE_SYMBOL_ICON) {
      SymbolGlyph(TabMeta.iconRes(index, this.currentIndex === index))
        .fontSize(Dim.tabIcon)
        .fontColor([this.currentIndex === index ? Theme.brand : Theme.tabUnselectedColor(this.isDark)])
        // 选中瞬间弹跳：BounceSymbolEffect 默认 LAYER + DOWN（与 UX 规范 §5 推荐一致）
        .symbolEffect(new BounceSymbolEffect(), this.currentIndex === index)
    } else {
      Image(this.tabIcon(index, this.currentIndex === index))
        .width(Dim.tabIcon)
        .height(Dim.tabIcon)
        .objectFit(ImageFit.Contain)
        .draggable(false)
    }
  }

  @Builder
  TabItem(index: number) {
    Column() {
      this.TabIcon(index)

      Text(TabMeta.titleOf(index))
        .fontSize(Dim.tabText)
        .maxLines(1)
        .fontWeight(this.currentIndex === index ? FontWeight.Medium : FontWeight.Normal)
        .fontColor(this.currentIndex === index ? Theme.brand : Theme.tabUnselectedColor(this.isDark))
        .margin({ top: Dim.tabGap })
    }
    .width('100%')
    .height('100%')
    // 悬浮档（含「无材质但可悬浮」）由控件自身避让导航条；只有平铺贴边档需手工避让（D3 说明）
    .padding({ bottom: this.floatMode ? 0 : this.bottomSafe })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
  }

  /**
   * HDS 悬浮样式。
   * s5g 起对齐 NextE entry/pages/Index.ets:2807-2815 的**最小参数集**：只给
   * barBottomMargin + adaptToHandedness + systemMaterialEffect，**不设 barWidth / gradientMask /
   * barOpacity**（NextE 主底栏就没设这些；参数越少越靠系统默认，胶囊形态由 HdsTabs 自己决定）。
   * 材质参数走 hdsParamsAuto()：无 IMMERSIVE 时是 ADAPTIVE/ADAPTIVE，不是降级组件。
   */
  private hdsFloatingStyle(): HdsTabsFloatingStyle {
    const style: HdsTabsFloatingStyle = {
      barBottomMargin: Dim.floatingBarBottom,
      adaptToHandedness: true,
      systemMaterialEffect: SurfaceMaterial.hdsParamsAuto(),
      gradientMask: this.hdsMaskStyle()
    };
    return style;
  }

  /**
   * 底栏下方那条渐隐遮罩的取色（缺陷④「亮色模式下胶囊以下仍是黑色」的直接修法）。
   * s7a 取证：真机主力走 HdsTabs 分支，而该分支**一个背景/遮罩色都没给** ⇒ 遮罩用组件
   * 自带的默认深色，亮色下就在胶囊与屏幕底边之间留一条黑带（原生分支 :399 早就给了
   * maskColor，所以只有 HDS 档复现）。这里只给 maskColor / maskHeight，**刻意不给
   * barBackgroundColor** —— 胶囊本体由 barFloatingStyle.systemMaterialEffect 负责，
   * 材质与 backgroundColor 互斥（R6，common.d.ts 声明原话），给了会把材质打死。
   * 高度口径与原生分支一致：胶囊高 + 底部外边距 + 渐隐余量。
   * SDK：HdsTabsBackgroundStyle（@hms.hds.hdsBaseComponent.d.ets:5015，maskColor :5024 /
   *      maskHeight :5035，不设 = 组件高 + 32vp）；HdsTabsFloatingStyle.gradientMask :5416（@since 6.1.0(23)）。
   */
  private hdsMaskStyle(): HdsTabsBackgroundStyle {
    const style: HdsTabsBackgroundStyle = {
      maskColor: Theme.maskColorFor(this.isDark),
      maskHeight: Dim.floatingBarH + Dim.floatingBarBottom + Dim.floatingMaskExtra
    };
    return style;
  }

  /** 3 个 TabContent（各档组件共用同一 builder，避免整段复制）
   *  顺序 = TabMeta.titles：0 书架 / 1 发现 / 2 更多（s5g 去首页签；s14 第 2 条去云收藏签）。
   *  云收藏的 TabContent 整块删除，页面本体零改动搬到 router 页 pages/CloudSyncPage（入口在更多页）。
   */
  @Builder
  TabContents() {
    TabContent() {
      BookshelfPage({
        onRequestTab: (index: number) => {
          this.jumpTo(index);
        }
      })
    }
    .tabBar(this.TabItem(0))

    TabContent() {
      DiscoverPage({
        onRequestTab: (index: number) => {
          this.jumpTo(index);
        }
      })
    }
    .tabBar(this.TabItem(1))

    TabContent() {
      MinePage({
        onRequestTab: (index: number) => {
          this.jumpTo(index);
        }
      })
    }
    .tabBar(this.TabItem(2))
  }

  build() {
    if (this.useHds) {
      // ------- s5g 主力档：HdsTabs 悬浮胶囊（NextE 同法，无条件使用）-------
      // 材质有无只影响 systemMaterialEffect 的参数（IMMERSIVE vs ADAPTIVE），不影响是否悬浮。
      // 关键差异（对比 s5f 失败路线）：HdsTabs 的 barFloatingStyle 走 systemMaterialEffect 字段，
      // 原生 Tabs 的 barFloatingStyle(@since 26) 走 systemMaterial 字段 —— 真机上只有前者真的浮起来。
      HdsTabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.hdsController }) {
        this.TabContents()
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barOverlap(true)
      .scrollable(false)
      .animationDuration(Anim.tabSwitch)
      .barFloatingStyle(this.hdsFloatingStyle())
      // 缺陷④：显式声明遮罩取色（与 gradientMask 同一份口径，双保险：某些 ROM 只吃
      // barBackgroundStyle 这一条）。同样是 mask-only，不碰 barBackgroundColor。
      .barBackgroundStyle(this.hdsMaskStyle())
      // T1：底栏就绪后才把控制器交给注册表（NextE 同法在 onAppear 里 applyHomeTabAutoHide，
      // 见其 entry/pages/Index.ets:2817）。各页的 scroller 可能已先到（TabContent 先建），
      // 由 TabAutoHide 内部「先到先存、后到即绑」兜住顺序不确定。
      .onAppear(() => {
        this.bindAutoHide();
      })
      .onTabBarClick((index: number) => {
        this.onTabBarClick(index);
      })
      .onChange((index: number) => {
        this.onChanged(index);
      })
      .width('100%')
      .height('100%')
    } else if (this.tier === Tier.NATIVE) {
      // ---------------- tier 1：原生悬浮胶囊 + 沉浸材质 ----------------
      Tabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.controller }) {
        this.TabContents()
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barHeight(Dim.floatingBarH)
      // 悬浮：内容需要延伸到胶囊之下（规范 §8）
      .barOverlap(true)
      // ⚠ R6：材质与 backgroundColor/shadow/border* 互斥（common.d.ts 声明原话）⇒ 用材质就**不设** barBackgroundColor
      .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .scrollable(false)
      .animationDuration(Anim.tabSwitch)
      .animationCurve(Anim.curveTabSwitch())
      .barFloatingStyle({
        barSideMargin: Dim.floatingBarSide,
        barBottomMargin: Dim.floatingBarBottom,
        maskColor: Theme.maskColorFor(this.isDark),
        maskHeight: Dim.floatingBarH + Dim.floatingBarBottom + Dim.floatingMaskExtra,
        adaptToHandedness: false,
        systemMaterial: SurfaceMaterial.barMaterial(this.isDark)
      })
      .onAppear(() => {
        this.bindAutoHide();
      })
      .onTabBarClick((index: number) => {
        this.onTabBarClick(index);
      })
      .onChange((index: number) => {
        this.onChanged(index);
      })
      .width('100%')
      .height('100%')
    } else if (this.floatMode) {
      // -------- tier 0 + 可悬浮（s5e 真机形态：API26 但 ROM 未开放沉浸材质）--------
      // 同一套悬浮布局，只是胶囊底色换成不透明等价色（§6 坑3：无材质必须有等价底色，不能只靠模糊）。
      // 刻意不传 systemMaterial ⇒ 与 barBackgroundColor 不冲突（R6 互斥只在两者同时设置时触发）。
      Tabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.controller }) {
        this.TabContents()
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      .barHeight(Dim.floatingBarH)
      .barOverlap(true)
      .barBackgroundColor(Theme.capsuleFallback(this.isDark))
      .scrollable(false)
      .animationDuration(Anim.tabSwitch)
      .animationCurve(Anim.curveTabSwitch())
      .barFloatingStyle({
        barSideMargin: Dim.floatingBarSide,
        barBottomMargin: Dim.floatingBarBottom,
        maskColor: Theme.maskColorFor(this.isDark),
        maskHeight: Dim.floatingBarH + Dim.floatingBarBottom + Dim.floatingMaskExtra,
        adaptToHandedness: false
      })
      .onAppear(() => {
        this.bindAutoHide();
      })
      .onTabBarClick((index: number) => {
        this.onTabBarClick(index);
      })
      .onChange((index: number) => {
        this.onChanged(index);
      })
      .width('100%')
      .height('100%')
    } else {
      // ---------------- tier 0：平铺模糊兜底（API 12 起可用，规范 §8 原法） ----------------
      Tabs({ barPosition: BarPosition.End, index: this.currentIndex, controller: this.controller }) {
        this.TabContents()
      }
      .vertical(false)
      .barMode(BarMode.Fixed)
      // 平铺栏贴边，确实需要自己避让导航条（沿用改造前行为，不退化）
      .barHeight(Dim.bottomBarH + this.bottomSafe)
      .barOverlap(true)
      .barBackgroundColor(Theme.capsuleFallback(this.isDark))
      .barBackgroundBlurStyle(BlurStyle.COMPONENT_THICK)
      .scrollable(false)
      .animationDuration(Anim.tabSwitch)
      .animationCurve(Anim.curveTabSwitch())
      .divider({ strokeWidth: 0.5, color: Theme.dividerColor(this.isDark) })
      .onTabBarClick((index: number) => {
        this.onTabBarClick(index);
      })
      .onChange((index: number) => {
        this.onChanged(index);
      })
      .width('100%')
      .height('100%')
    }
  }

  /** 曲线参数集中一处，三档共用（animateTo 之外的 Tabs 原生动画只吃 duration/curve） */
  private onTabBarClick(index: number): void {
    // 再次点击已选中页签：不切页，交给业务「回到顶部 / 刷新」（华为规范要求的行为）
    if (index === this.currentIndex) {
      this.onReselect(index);
      return;
    }
    // 点击立即同步高亮，避免等 onChange 造成的一帧延迟
    this.currentIndex = index;
    this.onChange(index);
  }

  private onChanged(index: number): void {
    // 手势 / 程序化切换时同步共享下标（不重复触发 onChange，避免回调风暴）
    if (this.currentIndex !== index) {
      this.currentIndex = index;
    }
    // T1：换页签 ⇒ 记住当前页 + 把收起态复位（切过去一页可能停在中间，底栏不该继续隐身）
    TabAutoHide.onTabChanged(index);
  }
}
