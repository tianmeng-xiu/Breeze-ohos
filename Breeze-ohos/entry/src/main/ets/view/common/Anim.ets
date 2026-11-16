/**
 * 职责：动效基线 —— 动效时长/曲线 Token 的唯一来源 + 统一动效入口 Anim.to()。
 * 依赖：@kit.ArkUI curves（springMotion / cubicBezierCurve 已由 spike SPIKE-04/06 实证可编译）。
 * 规范：
 *  - Anim.disabled 恒 false：settings.ANIMATOR_DURATION_SCALE 自 API21 废弃、API26 d.ts 已不导出，
 *    全 SDK 无 reduce-motion 替代 API（spike SPIKE-09b 实证），要关动效走应用内偏好开关（本期不做）。
 *  - Anim.to() 内部走 UIContext.animateTo（禁全局 animateTo，§3）。UIContext 需在组件树里绑定：
 *    BreezeBottomTab.aboutToAppear 里 Anim.bind(this.getUIContext())（Index 禁段不动，故不在那里绑）。
 *    未绑定 / disabled / dur<=0 时直接执行 op（不动画），行为退化为改造前。
 */
import { curves } from '@kit.ArkUI';

/** §3 动效 Token */
export class Anim {
  // ---------------- 时长（ms） ----------------
  /** 页签切换（spring） */
  static readonly tabSwitch: number = 260;
  /** SymbolGlyph 弹跳动效 */
  static readonly iconBounce: number = 220;
  /** 顶栏收起 / 展开 */
  static readonly barCollapse: number = 280;
  /** 内容进场（透明度 + 上移 12vp） */
  static readonly contentIn: number = 220;
  /** 顶栏标题淡切 */
  static readonly topBarFade: number = 180;

  // ---------------- 第 6 条 / 第 7 条：跨页转场统一档（s31） ----------------
  /**
   * 页级转场 + 封面共享元素的**统一时长**。第 6 条用户要「适当放缓」，而这三处原先各吃
   * Anim.contentIn（220）：书架封面、详情页头图、详情页页级推拉 —— 三处同值但各自手抄，
   * 一改就漏 ⇒ 收敛成这一枚 Token，两页四写点共读（书架 CoverCell、DetailCover 头图、
   * DetailPage.pageTransition、ReaderPage.pageTransition）。
   * 取 360 = 淡入淡出 + 封面跨越两级页面（104×139 → 整屏卡片）的位移量需要比列表进场更长的
   * 落地时间；再长（400+）在返回连点上会拖手感的下限由真机复验决定。
   */
  static readonly pageHero: number = 360;
  /** 封面浮层的退场时长（浮层淡出、阅读页显影；不属于第 6 条要求的对称段，故单独一档且更短）。 */
  static readonly heroFadeOut: number = 200;
  /**
   * s32 第 1 条：共享元素飞行段的**层序**。SDK sharedTransitionOptions 的 zIndex 默认 0
   * （common.d.ts:3797），而飞行途中目标页已经铺好**不透明**根底（书架根容器有实底背景），
   * 层序为 0 时那枚正在飞的封面会被压在目标页底下 ⇒ 用户看到的是「进入有飞、返回只剩淡出」
   * = 本轮第 1 条「从详情页退出到书架动画仍不统一」的头号成因。三处同给同一个大值，
   * 让封面全程在最上层飞（NOTE common.d.ts:3715-3721：Exchange 只插值位置与尺寸，
   * 内容在动画结束时 snap 成目标页的值 ⇒ 提到高层不会带出内容错位）。
   */
  static readonly heroZ: number = 1000;
  /**
   * s32 第 2 条：退场「补一拍」的时长（ms）。共享元素要求两端节点在转场开始时**都已存在**，
   * 而退出时封面浮层早已被摘掉；重新挂回浮层后必须让它先走完一次布局，router.back() 才
   * 能在「浮层已在树上」的状态下起转场，否则退场仍是半截动画。一拍 = 32 ms（两帧），
   * 肉眼不可见，但足够把节点建出来。
   */
  static readonly heroExitBeat: number = 32;
  /**
   * 定时器安全垫：动画名义结束到收尾动作之间留的余量（掉帧 + 调度抖动）。
   * ★ 浮层的清理**只由定时器驱动**，不挂 onTransitionEnd（共享元素的 End 属组件级、跨页时不可靠），
   *   所以余量必须给足，宁多勿少 —— 早一步摘浮层 = 封面在半空被抹掉。
   */
  static readonly heroSlack: number = 90;

  // ---------------- 曲线 ----------------
  /** 页签切换曲线：springMotion(response=0.34, damping=0.85)（§3，与 spike 一致） */
  static curveTabSwitch(): curves.ICurve {
    return curves.springMotion(0.34, 0.85);
  }

  /** 顶栏收起/展开曲线：EaseInOut（cubicBezier 0.4,0,0.2,1） */
  static curveBarCollapse(): curves.ICurve {
    return curves.cubicBezierCurve(0.4, 0, 0.2, 1);
  }

  /** 内容进场 / 标题淡切曲线：EaseOut（cubicBezier 0.33,1,0.68,1） */
  static curveEaseOut(): curves.ICurve {
    return curves.cubicBezierCurve(0.33, 1, 0.68, 1);
  }

  // ---------------- 闸门与入口 ----------------
  /** 动效总闸：恒 false（见文件头说明 —— 系统缩放 API 已废弃不可读，无替代） */
  static readonly disabled: boolean = false;

  /** UIContext 绑定（组件 aboutToAppear 里调；未绑定时 to() 直接执行） */
  private static ctx: UIContext | null = null;

  static bind(ctx: UIContext): void {
    Anim.ctx = ctx;
  }

  /**
   * 统一动效入口：dur<=0 / disabled / 未绑定 UIContext ⇒ 直接执行 op（等价旧行为）。
   * curve 不传默认 EaseOut。
   */
  static to(op: () => void, dur: number, curve?: curves.ICurve): void {
    const c: UIContext | null = Anim.ctx;
    if (Anim.disabled || c === null || dur <= 0) {
      op();
      return;
    }
    c.animateTo({ duration: dur, curve: curve ?? Anim.curveEaseOut() }, () => {
      op();
    });
  }

  // ---------------- 顶栏滚动进度（C6-① → C5 消费） ----------------
  /** 斜坡高度：内容从 0 滚到 80vp，顶栏由全透明渐变到全实底（§7 A5） */
  static readonly topBarRampVp: number = 80;

  /**
   * 把滚动偏移折算成 0–1 进度写入 AppStorage 'topBarProgress'（AppKeys.topBarProgress）。
   * 各页滚动容器的 onDidScroll 直接调它，禁在页面里写斜坡常量。
   */
  static reportTopBar(offsetVp: number): void {
    let p: number = 0;
    if (offsetVp >= Anim.topBarRampVp) {
      p = 1;
    } else if (offsetVp > 0) {
      p = offsetVp / Anim.topBarRampVp;
    }
    AppStorage.setOrCreate<number>('topBarProgress', p);
  }
}
