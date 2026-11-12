/**
 * 职责：搜索页工具区的「静态玻璃」取值器加流动玻璃按钮 GlassButton（唯一来源）。
 *      GlassStyle 本体是纯静态常量加纯函数：不引用组件、不做运行时能力探测、不读缓存
 *      （宽度类取值器由调用方算一次后自行缓存）；文件末尾的 GlassButton 是唯一的 @Component。
 * 依赖：仅 view/common/Theme 的 Dim（页面左右边距）与 Theme.brand（浅色态高光色）。
 *
 * 为什么不用 systemMaterial（view/common/Material.ets 已定案，别再试）：
 *  真机 SGT-AL10 加 OpenHarmony-7.0.0.111 加 API26 取证结论是 hdsImmersive() 与
 *  isImmersiveMaterialSupported() 都是 false，即该 ROM 未开放沉浸材质，
 *  .systemMaterial() 在用户机器上完全无效果。故退到通用属性：半透明底加 backdropBlur 轻微毛玻璃。
 *
 * 为什么也不用 HDS 的 HdsVisualComponent（「双边缘流动光效」的原厂件，已查证不可用）：
 *  它与 hdsMaterial 同一个 syscap（SystemCapability.UIDesign.HDSComponent.Core），而 s5e 真机取证
 *  getSystemMaterialTypes() 不含 IMMERSIVE ⇒ HDS 组件栈在用户机上大概率整体不可用；
 *  且 ArkUI 组件在 build() 里渲染时框架缺工厂是**硬崩不是抛异常**，try 包不住 ⇒ 本文件禁止 import 它。
 *  等效实现见下面的 GlassButton（rotate 驱动的旋转渐变环）。
 *
 * backdropBlur 签名已在本地 SDK 查证（sdk/default/openharmony/ets/component/common.d.ts:19596）：
 *  backdropBlur(value: number, options?: BlurOptions): T —— @since 7，入参是模糊半径，传 0 即不模糊。
 *  注意它模糊的是组件「背后」的内容：当前工具区下面是纯色页面背景，视觉差异很轻，
 *  收起动画进行中（工具区压在列表上滑走）以及 GlassButton 里糊化旋转光带时才会真正显现。
 *  半径全部集中在本文件，真机若觉得多余把 toolBlur() 改成 0 即整体关闭 blur，不用动页面。
 */
import { Dim, Theme } from './Theme';

/** 搜索工具区玻璃 Token（唯一来源：SearchPage 只引用取值器，不写死色值与半径）。 */
export class GlassStyle {
  /** 未选中 chip 底色（深色）：白 15%，叠在黑底上是浅灰玻璃 */
  static readonly chipBgDark: string = '#26FFFFFF';
  /** 未选中 chip 底色（浅色）：中性灰 25% */
  static readonly chipBgLight: string = '#40C8C8C8';
  /** 工具区底色（深色）：比 chip 低一档，避免输入框和条带糊成一片 */
  static readonly toolBgDark: string = '#1AFFFFFF';
  /** 工具区底色（浅色）：比 chip 低一档 */
  static readonly toolBgLight: string = '#26C8C8C8';
  /** 玻璃描边（深色）：白 20%，只用来勾出胶囊边缘 */
  static readonly strokeDark: string = '#33FFFFFF';
  /** 玻璃描边（浅色）：中性灰 10% */
  static readonly strokeLight: string = '#1AC8C8C8';

  /** chip 最大宽上限：宽屏与折叠屏展开态不再继续放大（长插件名靠省略号截断）。 */
  static readonly chipMaxCap: number = 180;
  /** chip 最大宽下限：再窄就几乎读不出字了 */
  static readonly chipMaxFloor: number = 96;
  /** chip 右外边距，必须与 SearchPage 里 chip 的 margin right 保持一致，否则算不出「三枚可见」 */
  static readonly chipGap: number = 8;
  /** 一屏内至少要求完整可见的 chip 枚数（需求：不少于 3） */
  static readonly chipVisibleMin: number = 3;
  /**
   * 来源条滚到最右时，最后一枚 chip 与视口右缘之间留出的可见留白（vp），喂 List 的
   * contentEndOffset（list.d.ts:1090，@since 11）。取 Dim.pagePadding 同量级 = 16：
   * 没有它最后一枚会贴死屏幕右缘，看着像被渲染裁掉了。
   */
  static readonly chipEndPad: number = 16;

  /** 未选中 chip 底色（选中态由调用方走 Theme.brand 实底，不套玻璃）。 */
  static chipBg(isDark: boolean): string {
    return isDark ? GlassStyle.chipBgDark : GlassStyle.chipBgLight;
  }

  /**
   * 玻璃面板底色：现在只有 GlassButton 的外壳在用。搜索工具区已按真机反馈撤掉独立底色
   * （与页面底色之间的直角分界比玻璃感更扎眼），别再往页面级大块上套这个色。
   */
  static toolBg(isDark: boolean): string {
    return isDark ? GlassStyle.toolBgDark : GlassStyle.toolBgLight;
  }

  /** 玻璃描边色（chip 与工具区共用一档）。 */
  static stroke(isDark: boolean): string {
    return isDark ? GlassStyle.strokeDark : GlassStyle.strokeLight;
  }

  /** 玻璃描边宽度：0.5vp 细线，粗了就没玻璃感了。 */
  static strokeWidth(): number {
    return 0.5;
  }

  /**
   * 工具区档背景模糊半径（vp），返回 0 即完全关闭 blur。
   * 现状：SearchPage 工具区已撤掉 backdropBlur（见该处注释），本取值器暂留作备选，
   * 若真机想把工具区玻璃感加回来，在工具区上重新挂 backdropBlur(GlassStyle.toolBlur()) 即可。
   */
  static toolBlur(): number {
    return 12;
  }

  // ---------------- 搜索工具区尺寸 Token（BUG6 新增） ----------------
  // BUG6 的根因是「折叠动画吃的总高」与「工具区真实布局高」分处两地、各写各的：
  // 页面里折叠高度是手抄的注释值，而真实布局由上内边距、搜索框高、来源条间距与行高共同决定，
  // 任何一处改动（换字号、换 chip 行高、加内边距）都会让那个手抄值偏小，clip 就把 chip 底边切平。
  // 定案：这几项全部收进本文件供布局与折叠两侧共读，另加底部余量与实测余量两档。
  /** 工具区上内边距（vp） */
  static readonly toolPadTop: number = 10;
  /** 搜索框高（vp）：显式定高，不随深色态与主题漂移 */
  static readonly toolSearchH: number = 40;
  /** 搜索框与来源条之间的间距（vp） */
  static readonly toolRowGap: number = 6;
  /** 来源条行高（vp）：chip 32 上下各留 6 */
  static readonly toolChipRowH: number = 44;
  /** chip 胶囊高（vp） */
  static readonly toolChipH: number = 32;
  /**
   * 工具区底部余量（vp）：裁剪线与 chip 底边之间的留白。
   * 真机截图量出来 chip 的实际绘制底边比它所在行的算术位置低约 8vp（chip 底边正好压在折叠高度上，
   * 三枚 chip 同一 y 处齐平截断），故把这 8vp 直接写进布局，而不是留给折叠高度去猜。
   */
  static readonly toolBottomPad: number = 8;
  /**
   * 实测高度之上再加的安全余量（vp）：吸收亚像素与**行内落位偏移**，宁多勿切。
   * 取 8 的依据：截图逐像素量到 chip 的实际落位比「上内边距 10、搜索框 40、间距 6」这套算术
   * 低 8 到 11vp（chip 顶边实测约 67 至 70vp，算术给 62）。注意这段偏移发生在固定高的来源条
   * 行**内部**，内层 Column 量到的内容高（= 40 加 6 加 44）不体现它，所以这道余量不能只靠实测兜，
   * 必须自己留够：8 覆盖偏移下沿，行内再往下的部分由 toolBottomPad 8 一起接住。
   */
  static readonly toolClipSlack: number = 8;
  /** 来源条行高上限（vp）：字号放大撑开行高的封顶，防极端读数把结果区顶掉 */
  static readonly toolChipRowMax: number = 72;
  /** 实测高度下限（vp）：低于此值判为异常读数（收起态量到 0 之类），直接丢弃 */
  static readonly toolHeightFloor: number = 60;
  /** 实测高度上限相对布局Token的额外额度（vp）：防一次异常读数吃掉整个结果区 */
  static readonly toolHeightCapExtra: number = 40;

  /** 工具区布局总高（vp）= 上内边距、搜索框、间距、来源条行高、底部余量之和。 */
  static toolBarLayoutH(): number {
    return GlassStyle.toolPadTop + GlassStyle.toolSearchH +
      GlassStyle.toolRowGap + GlassStyle.toolChipRowH + GlassStyle.toolBottomPad;
  }

  // ---------------- GlassButton 的 Token ----------------
  /** 流动光效一圈周期（ms）。2400 是「看得见在转、又不抢注意力」的一档。 */
  static flowPeriod(): number {
    return 2400;
  }

  /**
   * 流动层自身的模糊半径（vp）：把旋转的高光带糊成「隔着毛玻璃的光」，而不是一条硬亮条。
   * 4 是实测定下的数（rotate 驱动视觉上偏硬时的柔化量级），别再往上加动画。
   */
  static flowBlur(): number {
    return 4;
  }

  /** 玻璃面板的 backdropBlur 半径（vp）：糊化面板背后的光带与页面内容。 */
  static panelBlur(): number {
    return 20;
  }

  /**
   * 发光环宽度（vp）：面板比外壳每边内缩这么多，露出来的一圈就是流动光带。
   * 1.5 是「看得见但不刺眼」的一档；调到 0 面板就完全盖住光带（等于只剩静态玻璃）。
   */
  static flowRing(): number {
    return 1.5;
  }

  /** 玻璃按钮文案字号（fp）。 */
  static flowLabelSize(): number {
    return 13;
  }

  /**
   * chip 最大宽（vp）：按可用宽反解，保证「3 枚 chip 加 3 份右间距」能塞进去，
   * 再夹到 [chipMaxFloor, chipMaxCap]。真机插件名很长（例：禁漫天堂括号后缀），
   * 不给上限的话一枚 chip 就能顶满屏宽，后面的源全看不见。
   * 入参 barW 是**工具区实测宽**（SearchPage 用 onAreaChange 取，含左右 pagePadding），
   * 减去外层两份 pagePadding 才是 chip 真正可用的宽；来源条 List 自身不再叠加内边距（旧写法
   * 外层 Column 一份加内层 Row 一份，共 64vp 白白吃掉，是三枚短中文名就顶到右缘的直接原因）。
   * 不要用 display 的物理屏宽：分屏与折叠屏下物理屏宽大于可用宽，反解值会偏大 ⇒ 短中文名
   * 也不截断，等于约束没生效。gap 按 chipVisibleMin 份计（横向 List 的 space 每对相邻项一份）。
   */
  static chipMaxWidth(barW: number): number {
    const available: number = barW - Dim.pagePadding * 2;
    const raw: number = (available - GlassStyle.chipGap * GlassStyle.chipVisibleMin) / GlassStyle.chipVisibleMin;
    let v: number = Math.floor(raw);
    if (v > GlassStyle.chipMaxCap) {
      v = GlassStyle.chipMaxCap;
    }
    if (v < GlassStyle.chipMaxFloor) {
      v = GlassStyle.chipMaxFloor;
    }
    return v;
  }
}

/**
 * 流动光效的渐变端点与高光色。两端必须完全透明（alpha 00），中间一段是高光，
 * 否则整圈都是实色，转起来看不出「流动」。深色走白色高光，浅色高光色由调用方用 accent 传入（默认品牌蓝）。
 */
class FlowLightTokens {
  /** 渐变两端：全透明白（两种模式通用，透明端不需要分深浅） */
  static readonly edge: string = '#00FFFFFF';
  /** 深色态高光：白 30% */
  static readonly darkHi: string = '#4DFFFFFF';
}

/**
 * 职责：带「双边缘流动光效」的玻璃按钮（ArkUI 原生等效实现，不依赖 HDS）。
 *
 * 等效做法（三层 Stack，自下而上）：
 *  1) 流动层：一个边长 = 对角线的正方形，静态 linearGradient（两端透明、中间高光），
 *     对它做 .rotate({ angle: this.spin })，spin 由无限线性动画从 0 推到 360 ⇒ 高光带持续扫过四条边。
 *     **为什么驱动量是 rotate 而不是 linearGradient 的 angle**：ArkUI 的属性动画只对「可动画属性表」
 *     内的属性插值，rotate 在表内，渐变参数不在表内（本地 SDK 里也找不到任何 @animatable 标注可作
 *     正面证据：common.d.ts 全文 0 处），用 angle 驱动大概率硬跳 ⇒ 定案走 rotate。
 *  2) 玻璃面板：backdropBlur 加半透明底加玻璃细描边，把 1) 糊成「隔着毛玻璃看到的光」。
 *     环形边不是靠 border 画的：1) 铺满整块、2) 盖住中心，四周露出的 1.5vp 就是发光环。
 *  3) 文案。
 *
 * 三个必踩坑（都已按此实现）：
 *  - **宽高必须显式传**：Stack 的尺寸由最大子组件决定，而 1) 是对角线尺寸的超大正方形；
 *    外层把宽高写死加 .clip(true)，超大层才会被裁成按钮形状（否则按钮被撑大约 1.5 倍）。
 *  - **无限动画不需要手工停**：animateTo 的 iterations: -1 是一条动画跑无限遍，不是定时器，
 *    组件卸载时动画随节点一起销毁；alive 只是防御性闸门（卸载后外部再调 restartFlow 会被吞掉），
 *    本组件不持有任何全局计时器。
 *  - 组件字段名避开保留名 enabled、valueOf、toString、hasOwnProperty（撞 CustomComponent 同名方法，
 *    本项目真机踩过）⇒ 回调字段叫 onTap 而不是 onClick。
 *
 * 用法（调用方必须给死宽高）：
 *   GlassButton({ label: '清空', w: 72, h: 28, radiusV: 14, onTap: (): void => { this.clearHistory(); } })
 */
@Component
export struct GlassButton {
  /** 按钮文案 */
  @Prop label: string = '';
  /** 宽（vp）：必须显式传，见类注释「宽高必须显式传」 */
  @Prop w: number = 120;
  /** 高（vp） */
  @Prop h: number = 40;
  /** 圆角（vp）：默认与 Dim.radius 同值；@Prop 默认值按项目写法一律写字面量（view/ 下现有 @Prop 无一处引外部常量） */
  @Prop radiusV: number = 12;
  /** 浅色态高光色（深色态固定用 FlowLightTokens.darkHi）：默认品牌蓝，与 Theme.brand 同值 */
  @Prop accent: string = '#0A59F7';
  /** 是否开流动光效：关掉即纯静态玻璃（列表内批量复用、或真机觉得晃眼时传 false） */
  @Prop flow: boolean = true;
  /** 深色模式：子组件必须 @Prop 或 @StorageProp，不许裸字段接父级 @StorageProp（项目铁律） */
  @StorageProp('isDark') isDark: boolean = false;
  /** 点击回调（字段名避开保留名，不能叫 onClick） */
  onTap: () => void = () => {};

  /** 旋转角：无限线性动画的唯一驱动量，0 推到 360 */
  @State private spin: number = 0;
  /** 存活闸门：不代表任何计时器，只拦卸载后的外部动画触发 */
  private alive: boolean = false;
  /** 动画只起一次（onAppear 在复用场景可能被多次回调） */
  private flowStarted: boolean = false;

  aboutToAppear(): void {
    this.alive = true;
    // 注意：这里**不**起动画。animateTo 是对「已创建组件节点的可动画属性」做插值，
    // aboutToAppear 时节点还没建出来，此时调用会空转（表现是永远停在静态玻璃）。
    // 真正的起点在下面 build 根节点的 onAppear。
  }

  aboutToDisappear(): void {
    // 无限动画随组件节点销毁，这里只关闸门
    this.alive = false;
  }

  /**
   * 流动层边长（vp）：对角线 √(w²+h²) 向上取整再加 2vp 余量，
   * 保证旋转到任意角度都不露角（露角就是按钮四角突然黑一块）。
   */
  private sideLen(): number {
    const ww: number = this.w > 0 ? this.w : 1;
    const hh: number = this.h > 0 ? this.h : 1;
    return Math.ceil(Math.sqrt(ww * ww + hh * hh)) + 2;
  }

  /** 起无限线性旋转（iterations: -1）。未开流动或拿不到 UIContext 就静默退回静态玻璃。 */
  private startFlow(): void {
    if (!this.alive || !this.flow || this.flowStarted) {
      return;
    }
    this.flowStarted = true;
    try {
      const ui: UIContext = this.getUIContext();
      ui.animateTo(
        {
          duration: GlassStyle.flowPeriod(),
          iterations: -1,
          curve: Curve.Linear,
          playMode: PlayMode.Normal
        },
        (): void => {
          this.spin = 360;
        }
      );
    } catch (err) {
      // 无 UIContext 或不支持无限动画：静态玻璃照样可用，不抛错打扰页面
      this.spin = 0;
    }
  }

  /** 外部重启动画用（先清标志，否则被「只起一次」闸门拦住）；已卸载或未开流动则无操作。 */
  restartFlow(): void {
    this.spin = 0;
    this.flowStarted = false;
    this.startFlow();
  }

  /** 面板边长：外壳每边内缩一个环宽（负值兜底到 1，避免小尺寸下传 0 触发参数异常）。 */
  private panelLen(len: number): number {
    const v: number = len - GlassStyle.flowRing() * 2;
    return v > 1 ? v : 1;
  }

  /** 面板圆角：比外壳小一个环宽，同心圆弧才不露骨。 */
  private panelRadius(): number {
    const v: number = this.radiusV - GlassStyle.flowRing();
    return v > 0 ? v : 0;
  }

  /** 高光色：深色白 30%，浅色用调用方传入的主色（默认品牌蓝）。 */
  private hiColor(): string {
    return this.isDark ? FlowLightTokens.darkHi : this.accent;
  }

  /**
   * 渐变三段（显式标注元组数组类型，避开 ArkTS 严格模式把嵌套数组字面量推断成联合类型二维数组）：
   * 两端透明、中间高光 —— 接缝同色是旋转一圈不跳色的前提。
   */
  private gradColors(): Array<[ResourceColor, number]> {
    const hi: string = this.hiColor();
    const edge: string = FlowLightTokens.edge;
    const stops: Array<[ResourceColor, number]> = [[edge, 0], [hi, 0.5], [edge, 1]];
    return stops;
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // 1) 流动层：超大正方形渐变加旋转，被外层 clip 裁成按钮形状
      Column()
        .width(this.sideLen())
        .height(this.sideLen())
        .linearGradient({
          angle: 0,
          colors: this.gradColors()
        })
        .rotate({ angle: this.spin })
        .blur(GlassStyle.flowBlur())

      // 2) 玻璃面板：**每边内缩 flowRing()**，露出来的一圈才是发光环
      // （宽高压成 '100%' 的话面板会把流动层整个盖死，等于没有光效 —— 这是最容易写错的一处）
      Column()
        .width(this.panelLen(this.w))
        .height(this.panelLen(this.h))
        .borderRadius(this.panelRadius())
        .backgroundColor(GlassStyle.toolBg(this.isDark))
        .backdropBlur(GlassStyle.panelBlur())
        .borderWidth(GlassStyle.strokeWidth())
        .borderColor(GlassStyle.stroke(this.isDark))

      // 3) 文案
      Text(this.label)
        .fontSize(GlassStyle.flowLabelSize())
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text1(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .constraintSize({ maxWidth: this.w > 24 ? this.w - 24 : 0 })
        .textAlign(TextAlign.Center)
    }
    .width(this.w)
    .height(this.h)
    // clip 按组件自身的 borderRadius 裁形，所以圆角必须写在外层 Stack 上（写在面板上裁不出圆角）
    .borderRadius(this.radiusV)
    .clip(true)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onAppear((): void => {
      // 节点建好了才起无限旋转（理由见 aboutToAppear 注释）
      this.startFlow();
    })
    .onClick((): void => {
      this.onTap();
    })
  }
}
