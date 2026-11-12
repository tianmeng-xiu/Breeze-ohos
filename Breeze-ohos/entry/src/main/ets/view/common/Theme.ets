/**
 * 职责：Breeze 鸿蒙端全局设计 Token（颜色 / 尺寸 / 安全区键名），全项目唯一来源。
 * 依赖：无（纯常量与纯函数，禁止在此引用组件或数据层）。
 * 对应 Flutter：lib/config/theme/* 与各页面内的 ThemeData / MediaQuery 尺寸。
 * 规范：HarmonyOS 设计系统色板 —— 品牌蓝 #0A59F7、警告 #ED6F21、成功 #64BB5C、错误 #E84026。
 * 深色模式：组件声明 @StorageProp('isDark') isDark，再调用 Theme.xxx(isDark) 解析出具体色值。
 */

export class Theme {
  // ---------------- 品牌与语义色 ----------------
  /** 品牌蓝：选中态、主按钮、可点击文字 */
  static readonly brand: string = '#0A59F7';
  /** 品牌蓝按下态（约 -15% 亮度） */
  static readonly brandPressed: string = '#0846C4';
  /** 警告 */
  static readonly warning: string = '#ED6F21';
  /** 成功 */
  static readonly success: string = '#64BB5C';
  /** 错误 */
  static readonly error: string = '#E84026';

  // ---------------- 浅色模式 ----------------
  /** 页面背景 */
  static readonly bg: string = '#F1F3F5';
  /** 卡片 / 顶栏 / 底栏背景 */
  static readonly card: string = '#FFFFFF';
  /** 主文字 */
  static readonly textPrimary: string = '#182431';
  /** 次文字（主文字 40% 透明度） */
  static readonly textSecondary: string = '#66182431';
  /** 三级文字（主文字 30%） */
  static readonly textTertiary: string = '#4D182431';
  /** 分割线（主文字 10%） */
  static readonly divider: string = '#1A182431';
  /** 底栏未选中（主文字 60%） */
  static readonly tabUnselected: string = '#99182431';
  /** 输入框 / 占位块底色（主文字 5%） */
  static readonly fill: string = '#0D182431';
  /** 图片占位底色 */
  static readonly coverPlaceholder: string = '#E5E8EA';
  /** 阅读器 / 遮罩 */
  static readonly scrim: string = '#99000000';
  static readonly white: string = '#FFFFFF';
  static readonly black: string = '#000000';

  // ---------------- 深色模式 ----------------
  static readonly dBg: string = '#000000';
  static readonly dCard: string = '#1C1C1E';
  static readonly dTextPrimary: string = '#E5E5E5';
  static readonly dTextSecondary: string = '#99E5E5E5';
  static readonly dTextTertiary: string = '#66E5E5E5';
  static readonly dDivider: string = '#33FFFFFF';
  static readonly dTabUnselected: string = '#99E5E5E5';
  static readonly dFill: string = '#1AFFFFFF';
  static readonly dCoverPlaceholder: string = '#2C2C2E';

  // ---------------- 深 / 浅解析（组件里统一走这里） ----------------
  static background(isDark: boolean): string {
    return isDark ? Theme.dBg : Theme.bg;
  }

  static cardColor(isDark: boolean): string {
    return isDark ? Theme.dCard : Theme.card;
  }

  static text1(isDark: boolean): string {
    return isDark ? Theme.dTextPrimary : Theme.textPrimary;
  }

  static text2(isDark: boolean): string {
    return isDark ? Theme.dTextSecondary : Theme.textSecondary;
  }

  static text3(isDark: boolean): string {
    return isDark ? Theme.dTextTertiary : Theme.textTertiary;
  }

  static dividerColor(isDark: boolean): string {
    return isDark ? Theme.dDivider : Theme.divider;
  }

  static tabUnselectedColor(isDark: boolean): string {
    return isDark ? Theme.dTabUnselected : Theme.tabUnselected;
  }

  static fillColor(isDark: boolean): string {
    return isDark ? Theme.dFill : Theme.fill;
  }

  static coverColor(isDark: boolean): string {
    return isDark ? Theme.dCoverPlaceholder : Theme.coverPlaceholder;
  }

  // ---------------- 悬浮底栏 / 材质回退（三档降级链的坑3） ----------------
  /**
   * 无材质档（tier=0）与「材质未生效」时胶囊的**不透明等价底色**。
   * 规范 §8：材质不可用时绝不允许透明胶囊叠在列表上（不可读）。
   * 取 card 色 + 95% alpha（#F2），保证即使下方有内容也几乎不透出。
   */
  static capsuleFallback(isDark: boolean): string {
    return isDark ? '#F21C1C1E' : '#F2FFFFFF';
  }

  /**
   * 悬浮底栏上方渐变遮罩色（规范 §8「渐变层比内容顶边高 16vp」）。
   * ArkUI 会把它做成「透明 → maskColor」的渐变，故取页面背景色本身，
   * 这样列表滚入底栏下方时是淡出到背景，而不是淡出到白/黑块。
   */
  static maskColorFor(isDark: boolean): string {
    return isDark ? Theme.dBg : Theme.bg;
  }
}

export class Dim {
  // ---------------- 顶栏 ----------------
  /**
   * 顶栏行高 56vp（不含状态栏避让）。
   * 依据：华为 titlebar 规范 / OpenHarmony Navigation 小标题模式——
   * "从 API version 12 开始，该模式下标题栏高度为 56vp"
   * 来源：https://gitee.com/openharmony/docs/blob/master/zh-cn/application-dev/reference/apis-arkui/arkui-ts/ts-basic-components-navigation.md
   */
  static readonly topBarH: number = 56;
  /** 顶栏主标题 20fp / Medium（华为 titlebar 主标题规范） */
  static readonly topBarTitle: number = 20;
  /** 返回图标 24vp */
  static readonly backIcon: number = 24;
  /** 返回按钮点击热区 40x40vp */
  static readonly backHit: number = 40;

  // ---------------- 底栏（华为 BottomTab 规范） ----------------
  /** 底栏内容高度（不含导航条避让） */
  static readonly bottomBarH: number = 56;
  /** 页签图标 24vp */
  static readonly tabIcon: number = 24;
  /** 页签文字 10fp */
  static readonly tabText: number = 10;
  /** 图标与文字间距 2vp */
  static readonly tabGap: number = 2;
  /** 页签点击热区下限 48vp */
  static readonly tabHitMin: number = 48;
  /** 页签数下限 / 上限（华为规范：2~5，通用建议 3~5） */
  static readonly minTabs: number = 3;
  static readonly maxTabs: number = 5;
  /**
   * 底部安全区追加上限 20vp。
   * 华为元服务 UX 上架标准：系统导航条已预留安全边距，页签栏与导航条直接贴合对齐即可；
   * 避让间距超过 20vp 属空间浪费，因此对 getWindowAvoidArea 的 bottomRect 做上限收敛。
   */
  static readonly navAvoidMax: number = 20;

  // ---------------- 悬浮胶囊底栏（换层不变的 Token） ----------------
  /**
   * 胶囊高度 56vp。
   * 依据：华为 BottomTab UX 规范 §2/§7「悬浮式默认 56vp」（平铺式才是 48vp），
   * 且 §2 明确「控件默认避让导航条」⇒ 本值**不再**手工追加 bottomSafe（修 D3）。
   */
  static readonly floatingBarH: number = 56;
  /** 胶囊距屏幕底边 16vp（barBottomMargin，不含导航条避让——控件自动避让） */
  static readonly floatingBarBottom: number = 16;
  /** 胶囊距左右边 16vp（barSideMargin） */
  static readonly floatingBarSide: number = 16;
  /** 5 页签时的胶囊最大宽 360vp（规范 §7：≥5 页签上限 360vp） */
  static readonly floatingBarMaxWidth5: number = 360;
  /** 内容区底部预留 = 胶囊距底 + 胶囊高（C6-④ 各页 Scroll/Grid 用它补 padding，V15） */
  static readonly contentBottomReserve: number = 16 + 56;
  /** 渐变遮罩比内容顶边高出 16vp（规范 §8） */
  static readonly floatingMaskExtra: number = 16;

  // ---------------- 通用 ----------------
  static readonly pagePadding: number = 16;
  static readonly radius: number = 12;
  static readonly coverRadius: number = 8;
  /** 列表行高（发现 / 榜单 / 搜索结果） */
  static readonly listItemH: number = 72;
  /** 菜单行高（我的 / 更多） */
  static readonly menuItemH: number = 56;
  static readonly icon: number = 24;
  static readonly iconSm: number = 16;
  static readonly gridGap: number = 12;
  /** 页内工具条高 */
  static readonly toolbarH: number = 48;
  /** 书架封面宽高比 3:4 */
  static readonly coverRatio: number = 3 / 4;
  /** 书架网格列数（手机竖屏） */
  static readonly shelfColumns: number = 3;
}

/**
 * AppStorage 键名（跨组件共享，EntryAbility 与各页面都按此写入/读取）：
 *  - 'topSafeHeight'    状态栏避让高度（vp），来自 AvoidAreaType.TYPE_SYSTEM 的 topRect
 *  - 'bottomSafeHeight' 导航条避让高度（vp），来自 AvoidAreaType.TYPE_NAVIGATION_INDICATOR 的 bottomRect（已收敛到 20vp）
 *  - 'isDark'           深色模式开关
 */
export class AppKeys {
  static readonly topSafe: string = 'topSafeHeight';
  static readonly bottomSafe: string = 'bottomSafeHeight';
  static readonly isDark: string = 'isDark';
  /**
   * 顶栏滚动响应进度（0–1），由五个内容页的滚动容器写入、BreezeTopBar 消费（C5/C6-①）。
   * 0 = 顶栏完全透明无分隔线；1 = 实底 + 0.5 分隔线。
   */
  static readonly topBarProgress: string = 'topBarProgress';
}
