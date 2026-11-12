/**
 * 职责：全应用公共顶栏（沉浸式自适应 + **滚动响应**）。左返回 + 单行标题 + 可选右侧文字动作。
 * 依赖：Theme/Dim（./Theme）、SafeAreaUtil（./SafeArea）、Material（./Material）、@kit.AbilityKit。
 * 对应 Flutter：各页面 Scaffold(appBar: AppBar(...))，如 lib/page/bookshelf/view/bookshelf_page.dart、
 *              lib/page/discover/view/discover_page.dart 的 AppBar。
 * 关键：EntryAbility 已 setWindowLayoutFullScreen(true)，顶栏自行追加状态栏高度（AppStorage 'topSafeHeight'），
 *      不写死 24vp；页面挂载时兜底重测一次避让区（EntryAbility 未写入时也能正确避让）。
 * 尺寸依据（华为 titlebar 规范）：行高 56vp、主标题 20fp Medium、返回图标 24vp、返回热区 40x40vp。
 * 来源（OpenHarmony 官方组件文档 titleMode=Mini）："从 API version 12 开始，该模式下标题栏高度为 56vp"
 *   https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md
 *   （华为 doccenter UX 设计页为 SPA，抓不到正文；数值按上述规范与实机走查确定。）
 *
 * ===== 滚动响应 =====
 * 新增 @Prop scrollProgress（0–1，由五个内容页的滚动容器写入 AppStorage 'topBarProgress' 后传入）：
 *   0 → 完全透明、无分隔线（页面内容与顶栏融合，玻璃档此时生效）
 *   1 → 实底 cardColor + 0.5 分隔线
 * ⚠ 风险 R6（SDK 声明原话）：systemMaterial 与 backgroundColor、border、shadow 系列互斥 ⇒
 *   只在「非玻璃档」给实底色，玻璃档一律传 Color.Transparent，两者不同时出现真实取值。
 * 进度是连续量（跟手），故不套 animateTo；仅标题文字用 .transition 做淡切（A5 180ms）。
 */

import { common } from '@kit.AbilityKit';
import { Theme, Dim } from './Theme';
import { SafeAreaUtil } from './SafeArea';
import { SurfaceMaterial } from './Material';

@Component
export struct BreezeTopBar {
  /** 标题（单行，超长省略） */
  @Prop title: string = '';
  /** 是否显示返回箭头 */
  @Prop showBack: boolean = false;
  /** 右侧文字动作；空串表示不显示 */
  @Prop actionText: string = '';
  /**
   * 右侧是否显示搜索图标（需求 1，用户 m05810：「收敛发现页搜索栏，收到右上方与发现齐平，
   * 缩为一个单独的搜索图标，点击进入搜索页」）。五个一级页的顶栏由 pages/Index.ets 统一提供，
   * 所以这个开关只能长在顶栏组件上，由各页通过 Index 传。
   */
  @Prop showSearch: boolean = false;
  /** 滚动进度 0–1：0=透明无分隔线，1=实底+分隔线（介于中间按比例给分隔线不透明度） */
  @Prop scrollProgress: number = 1;
  /**
   * s11 第 7 条（用户 11-12 16:15 report 第 7 条「统一搜索页上下配色」）：
   * 打开后实底档底色从 cardColor 换成页面底色 Theme.background，与页面根容器同一个令牌
   * ⇒ 顶栏与下方不再「一白一灰」两块皮。
   * 默认 false = 其余页面行为逐字节不变（本轮口径 = 只统一搜索页，不动全局顶栏）。
   * 影响面：只有显式传 true 的调用点会变；本仓现九个 BreezeTopBar 调用点里只有 SearchPage 传。
   * 与 R6 无冲突：只替换实底档的取值，玻璃档仍走 systemMaterial 那条路。
   */
  @Prop flatBackground: boolean = false;
  /** 返回回调（默认 router.back 由调用方决定） */
  onBack: () => void = () => {};
  /** 右侧动作回调 */
  onAction: () => void = () => {};
  /** 搜索图标回调 */
  onSearch: () => void = () => {};

  /** 状态栏避让高度（vp），由 EntryAbility / SafeAreaUtil 写入 */
  @StorageProp('topSafeHeight') topSafe: number = 0;
  @StorageProp('isDark') isDark: boolean = false;

  aboutToAppear(): void {
    // 兜底：若 EntryAbility 还没写入，这里补测一次（幂等，不会覆盖已有正确值）
    SafeAreaUtil.sync(getContext(this) as common.UIAbilityContext);
  }

  /** 归一化进度，防外部传越界 */
  private p(): number {
    const v: number = this.scrollProgress;
    if (v <= 0) {
      return 0;
    }
    if (v >= 1) {
      return 1;
    }
    return v;
  }

  /**
   * 是否走玻璃档：运行时支持材质（tier>=1）且还没滚起来（进度 < 0.5）。
   * 滚起来后切实底，保证长列表在顶栏下的文字可读。
   */
  private useGlass(): boolean {
    return SurfaceMaterial.hasMaterial() && this.p() < 0.5;
  }

  /** 实底档底色：默认卡片色（浮在内容之上的传统顶栏）；flatBackground 打开后与页面底色同令牌 */
  private solidBg(): string {
    return this.flatBackground ? Theme.background(this.isDark) : Theme.cardColor(this.isDark);
  }

  build() {
    Column() {
      Row() {
        if (this.showBack) {
          // 返回：24vp 图标 / 40x40vp 热区
          Stack() {
            Path({
              width: Dim.backIcon,
              height: Dim.backIcon,
              commands: 'M15.5 5 L7.5 12 L15.5 19'
            })
              .stroke(Theme.text1(this.isDark))
              .strokeWidth(2)
              .strokeLineCap(LineCapStyle.Round)
              .strokeLineJoin(LineJoinStyle.Round)
              .fill(Color.Transparent)
          }
          .width(Dim.backHit)
          .height(Dim.backHit)
          .borderRadius(Dim.backHit / 2)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.onBack();
          })
        }

        Text(this.title)
          .fontSize(Dim.topBarTitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Theme.text1(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: this.showBack ? 4 : 0 })
          // 标题淡切（A5）：切页签换标题时 180ms 淡入 + 上移 6vp
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 6 }))
            .animation({ duration: 180, curve: Curve.EaseOut }))

        if (this.actionText.length > 0) {
          Text(this.actionText)
            .fontSize(14)
            .fontColor(Theme.brand)
            .maxLines(1)
            .textAlign(TextAlign.End)
            .height(Dim.backHit)
            .padding({ left: 12, right: 4 })
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.onAction();
            })
        }

        if (this.showSearch) {
          // 搜索图标：与返回箭头同热区（40x40vp）与同色（text1）。图形用系统符号
          // sys.symbol.magnifyingglass（DiscoverPage 的假搜索条同款，真机已验证可用），
          // 不自绘 Path ⇒ 明暗两套主题与线宽都由系统保证。
          Stack() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(21)
              .fontColor([Theme.text1(this.isDark)])
          }
          .width(Dim.backHit)
          .height(Dim.backHit)
          .borderRadius(Dim.backHit / 2)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.onSearch();
          })
        }
      }
      .width('100%')
      .height(Dim.topBarH + this.topSafe)
      .padding({
        top: this.topSafe,
        left: this.showBack ? 8 : Dim.pagePadding,
        right: Dim.pagePadding
      })
      .alignItems(VerticalAlign.Center)

      // 第 5 条(1)：顶栏渐显分隔线删除 —— 滚起来后顶栏切实底（cardColor），
      // 与页面底色（background）本身有色差已足够分离；再画一条线就是用户说的「明显分割线」。
    }
    .width('100%')
    // R6：玻璃档与实底档二选一。玻璃档 backgroundColor 传 Transparent（不给真实填充），
    // 实底档 systemMaterial 传 undefined（SDK 声明允许 undefined ⇒ 属性不生效）
    .systemMaterial(this.useGlass() ? SurfaceMaterial.topBarMaterial(this.isDark) : undefined)
    .backgroundColor(this.useGlass() ? Color.Transparent : this.solidBg())
  }
}
