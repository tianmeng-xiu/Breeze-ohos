/**
 * 职责：T1「滑动时底栏自动下沉隐藏」的接线中枢 + **收起动作的执行者**。
 *      各一级页只把自己已有的 Scroller 登记进来，并在 onDidScroll 里把滚动事件报进来；
 *      底栏组件把控制器交进来。三方在这里汇合，收起/展开只由本类统一决策。
 * 依赖：ArkUI 的 Scroller / TabsController + @kit.UIDesignKit 的 HdsTabsController / HdsAnimationMode。
 * 调用方：view/common/BreezeBottomTab.ets（bindController）+ 三个可滚动一级页（attach / onScroll）。
 *
 * ===== s5i 重写原因（真机 s5h 反馈「底栏下沉无反应」的根因）=====
 * s5h 只调了 bindScroller / bindTabsToScrollable 然后**什么都不做**，押注「框架会自己收起」。
 * 取证后确认这个押注不成立：
 *  1) 原生 TabsController **根本没有隐藏 API** —— tabs.d.ts 全文搜 hide 只命中注释（:357 / :377），
 *     只有 setTabBarTranslate(:368) 与 setTabBarOpacity(:389) 两个 setter；
 *  2) 而这两个 setter 一旦被 bindTabsToScrollable / bindTabsToNestedScrollable 绑定就会被
 *     框架忽略或覆盖（同一份声明的 NOTE 原话，:352-359 / :374-379）⇒ s5h 原生悬浮档是
 *     「bind 掉了 setter」+「bind 本身不生效」两头空；
 *  3) 真正的收起 API 在 HDS：HdsTabsController.applyHideAnimation(mode) / applyShowAnimation(mode)
 *     （@hms.hds.hdsBaseComponent.d.ets:5845 / :5854，@since 6.1.0(23)，真机 API26 可用）。
 *     bindScroller(:5817) **不是收起的执行者**，只是「这个 scroller 属于这个页签」的联动登记。
 *  4) 同机参考实现 NextE（entry/pages/Index.ets:1738-1779）正是这么做的：自己监听滚动、
 *     自己判方向，然后调 applyShow/HideAnimation —— bindScroller 只是顺手做的登记。
 * ⇒ 本版按 NextE 的决策结构自研监听，收起动作显式调用，不再指望框架自动收起。
 *
 * ===== 两档行为 =====
 *  HDS 档（真机主力，s5g 起 useHds=true）：applyHideAnimation / applyShowAnimation(SCROLL_ANIMATION)。
 *  原生悬浮档（兜底）：**不 bind**（避免上面那条互斥红线），直接 setTabBarTranslate 位移 + 透明度。
 *  平铺档：不收起（贴边栏收起会露出导航条区域空白，视觉更差）⇒ unbindAll() 置 off。
 *
 * ===== 页索引只能有一处真相 =====
 *  IDX_* 必须与 BreezeBottomTab.TabMeta.titles 顺序一致（0 书架 / 1 发现 / 2 云收藏 / 3 更多）。
 *  云收藏 s10 第 11 条起有纵向 Scroll 容器 ⇒ 已登记 IDX_CLOUD=2。
 */

import { HdsTabsController, HdsAnimationMode } from '@kit.UIDesignKit';

export class TabAutoHide {
  /** 与 TabMeta.titles 对齐的页索引常量（改动底栏顺序时必须同步这里） */
  static readonly IDX_SHELF: number = 0;
  static readonly IDX_DISCOVER: number = 1;
  /** s10 第 11 条：云收藏页重设计后有纵向 Scroll 容器，纳入收起联动（原来是占位页无滚动容器） */
  static readonly IDX_CLOUD: number = 2;
  static readonly IDX_MINE: number = 3;

  /** 诊断键：写 'hds:shown' / 'hds:hidden' / 'native:…' / 'off' / 'pending'，供诊断面板 surface 行取证 */
  static readonly KEY: string = 'matAutoHide';

  /** 判定方向的最小位移阈值（vp）。小于它的抖动一律忽略，避免慢滑时反复收起展开。 */
  private static readonly DELTA_VP: number = 6;
  /** 动画保护窗（ms）：一次收起/展开后这么久内不再发第二个，等动画走完 */
  private static readonly GUARD_MS: number = 180;

  /** 先到先存：页面登记的 (页索引, Scroller) 对 */
  private static pairs: TabScrollPair[] = [];
  /** 已做过联动登记的 scroller（bindScroller 幂等性未知，去重更稳） */
  private static bound: TabScrollPair[] = [];
  /** 各页最近一次上报的累计偏移（判方向用；页索引作下标的小表，线性查即可） */
  private static lastOffsets: OffsetEntry[] = [];

  /** 控制器（底栏就绪后写入） */
  private static hds: HdsTabsController | null = null;
  private static native: TabsController | null = null;
  /** 原生兜底档的收起位移量（vp），由底栏按 Dim 算好传入 */
  private static hideVp: number = 0;
  /** 当前生效档：'hds' / 'native' / 'off' / 'pending' */
  private static mode: string = 'pending';
  /** 当前页签（由底栏 onTabChanged 写入；只有当前页的滚动才允许动底栏） */
  private static current: number = 0;
  /** 底栏当前是否可见（收起决策的幂等闸门，避免每帧重复触发动画） */
  private static visible: boolean = true;
  /** 动画保护窗计时器句柄，-1 = 无 */
  private static guardTimer: number = -1;

  /** 页面侧调用：登记自己的滚动容器（aboutToAppear 里调一次即可） */
  static attach(index: number, scroller: Scroller): void {
    for (let i = 0; i < TabAutoHide.pairs.length; i++) {
      if (TabAutoHide.pairs[i].scroller === scroller) {
        return;
      }
    }
    const p = new TabScrollPair();
    p.index = index;
    p.scroller = scroller;
    TabAutoHide.pairs.push(p);
    TabAutoHide.flush();
  }

  /**
   * 底栏侧调用：HdsTabs 分支只传 hds；原生悬浮分支传 native + hideVp；平铺档调 unbindAll()。
   * hideVp 是原生档的收起位移（vp），HDS 档用不到（动画由框架算）。
   */
  static bindController(
    hds: HdsTabsController | null,
    native: TabsController | null,
    hideVp: number
  ): void {
    TabAutoHide.hds = hds;
    TabAutoHide.native = native;
    TabAutoHide.hideVp = hideVp;
    // 换控制器 ⇒ 旧的联动登记作废（页签重建时可能重入）
    TabAutoHide.bound = [];
    TabAutoHide.visible = true;
    TabAutoHide.guardTimerOff();
    if (hds === null && native === null) {
      TabAutoHide.unbindAll();
      return;
    }
    TabAutoHide.mode = hds !== null ? 'hds' : 'native';
    TabAutoHide.flush();
  }

  /** 解绑全部（平铺档 / 底栏销毁时用） */
  static unbindAll(): void {
    for (let i = 0; i < TabAutoHide.bound.length; i++) {
      const scroller = TabAutoHide.bound[i].scroller;
      try {
        if (TabAutoHide.hds !== null) {
          TabAutoHide.hds.unbindScroller(scroller);
        }
      } catch (err) {
        // 解绑失败不影响功能（框架会在 Tabs 销毁时清理）
      }
    }
    TabAutoHide.bound = [];
    // 原生兜底档：把位移和透明度的痕迹清干净，别留个半隐形的底栏
    if (TabAutoHide.native !== null) {
      try {
        TabAutoHide.native.setTabBarTranslate({ y: 0, z: 0 });
        TabAutoHide.native.setTabBarOpacity(1);
      } catch (err) {
        // 同上
      }
    }
    TabAutoHide.mode = 'off';
    TabAutoHide.visible = true;
    TabAutoHide.guardTimerOff();
    AppStorage.setOrCreate<string>(TabAutoHide.KEY, 'off');
  }

  /** 已登记数（诊断用） */
  static attachedCount(): number {
    return TabAutoHide.pairs.length;
  }

  /** 当前是否收起（诊断用） */
  static isHidden(): boolean {
    return !TabAutoHide.visible;
  }

  /**
   * 页面侧在 onDidScroll 里调用。**offsetY 必须是累计偏移**（读 scroller.currentOffset().yOffset），
   * 不是回调给的那两个参数 —— 所有滚动容器的 onDidScroll 给的都是「每帧增量」（见 key 记忆）。
   * 决策表（NextE entry/pages/Index.ets:1755-1779 同构）：
   *   非当前页签 / 未启用      → 只记偏移
   *   偏移 ≤ 阈值（在顶部附近）→ 强制展开（否则用户在顶部看到底栏消失会以为坏了）
   *   Idle（惯性结束/停止）    → 只记偏移，不动画
   *   向上滑 ≥ 阈值            → 展开
   *   向下滑 ≥ 阈值            → 收起
   */
  static onScroll(index: number, offsetY: number, state: ScrollState): void {
    const last: number = TabAutoHide.getLastOffset(index);
    TabAutoHide.setLastOffset(index, offsetY);
    if (TabAutoHide.mode === 'off' || TabAutoHide.mode === 'pending') {
      return;
    }
    if (index !== TabAutoHide.current) {
      return;
    }
    if (offsetY <= TabAutoHide.DELTA_VP) {
      TabAutoHide.applyVisible(true);
      return;
    }
    if (state === ScrollState.Idle) {
      return;
    }
    const delta: number = offsetY - last;
    if (delta < -TabAutoHide.DELTA_VP) {
      TabAutoHide.applyVisible(true);
      return;
    }
    if (delta > TabAutoHide.DELTA_VP) {
      TabAutoHide.applyVisible(false);
    }
  }

  /**
   * 页签切换时调用：切过去的那一页可能本来就停在中间，底栏不该保持收起；
   * 同时把它的 lastOffset 重置为真实位置，防止「上次记录的偏移」是另一个页面的滚动量导致误判。
   */
  static onTabChanged(index: number): void {
    TabAutoHide.current = index;
    const p: TabScrollPair | null = TabAutoHide.pairOf(index);
    if (p !== null) {
      try {
        TabAutoHide.setLastOffset(index, p.scroller.currentOffset().yOffset);
      } catch (err) {
        // scroller 未绑定组件时 currentOffset 会抛 ⇒ 忽略，保持原值
      }
    }
    TabAutoHide.applyVisible(true);
  }

  /** 重试联动登记（页面内容切换后调：Grid/List 只在有数据时挂载，首登记可能落空） */
  static flush(): void {
    if (TabAutoHide.mode === 'off') {
      return;
    }
    if (TabAutoHide.pairs.length === 0) {
      return;
    }
    if (TabAutoHide.hds === null && TabAutoHide.native === null) {
      TabAutoHide.mode = 'pending';
      AppStorage.setOrCreate<string>(TabAutoHide.KEY, 'pending');
      return;
    }
    let ok = 0;
    // 只有 HDS 档需要联动登记（原生兜底档刻意不 bind：bind 会让 setTabBarTranslate 失效）
    if (TabAutoHide.hds !== null) {
      for (let i = 0; i < TabAutoHide.pairs.length; i++) {
        const p = TabAutoHide.pairs[i];
        if (TabAutoHide.isBound(p.scroller)) {
          ok++;
          continue;
        }
        try {
          TabAutoHide.hds.bindScroller(p.index, p.scroller);
          TabAutoHide.bound.push(p);
          ok++;
        } catch (err) {
          // 登记失败不影响收起（动画是自研驱动的），只是少了框架联动
        }
      }
    } else {
      ok = TabAutoHide.pairs.length;
    }
    const tag: string = TabAutoHide.visible ? 'shown' : 'hidden';
    AppStorage.setOrCreate<string>(TabAutoHide.KEY, `${TabAutoHide.mode}:${ok}/${TabAutoHide.pairs.length}:${tag}`);
  }

  // ---------------- 内部 ----------------

  /** 显式收起/展开（幂等：状态没变、或保护窗未到期都不发指令） */
  private static applyVisible(visible: boolean): void {
    if (TabAutoHide.guardTimer >= 0) {
      return;
    }
    if (TabAutoHide.visible === visible) {
      return;
    }
    TabAutoHide.visible = visible;
    try {
      if (TabAutoHide.hds !== null) {
        if (visible) {
          TabAutoHide.hds.applyShowAnimation(HdsAnimationMode.SCROLL_ANIMATION);
        } else {
          TabAutoHide.hds.applyHideAnimation(HdsAnimationMode.SCROLL_ANIMATION);
        }
      } else if (TabAutoHide.native !== null) {
        const y: number = visible ? 0 : TabAutoHide.hideVp;
        TabAutoHide.native.setTabBarTranslate({ y: y, z: 0 });
        TabAutoHide.native.setTabBarOpacity(visible ? 1 : 0);
      } else {
        return;
      }
    } catch (err) {
      // 指令失败 ⇒ 保持常驻底栏（功能退化可用，不能出现不可用）
      return;
    }
    TabAutoHide.startGuardTimer();
    const tag: string = TabAutoHide.visible ? 'shown' : 'hidden';
    AppStorage.setOrCreate<string>(TabAutoHide.KEY, `${TabAutoHide.mode}:guard:${tag}`);
  }

  private static startGuardTimer(): void {
    TabAutoHide.guardTimerOff();
    TabAutoHide.guardTimer = setTimeout((): void => {
      TabAutoHide.guardTimer = -1;
    }, TabAutoHide.GUARD_MS);
  }

  private static guardTimerOff(): void {
    if (TabAutoHide.guardTimer >= 0) {
      clearTimeout(TabAutoHide.guardTimer);
      TabAutoHide.guardTimer = -1;
    }
  }

  private static pairOf(index: number): TabScrollPair | null {
    for (let i = 0; i < TabAutoHide.pairs.length; i++) {
      if (TabAutoHide.pairs[i].index === index) {
        return TabAutoHide.pairs[i];
      }
    }
    return null;
  }

  private static getLastOffset(index: number): number {
    for (let i = 0; i < TabAutoHide.lastOffsets.length; i++) {
      if (TabAutoHide.lastOffsets[i].index === index) {
        return TabAutoHide.lastOffsets[i].offset;
      }
    }
    return 0;
  }

  private static setLastOffset(index: number, offset: number): void {
    for (let i = 0; i < TabAutoHide.lastOffsets.length; i++) {
      if (TabAutoHide.lastOffsets[i].index === index) {
        TabAutoHide.lastOffsets[i].offset = offset;
        return;
      }
    }
    const e = new OffsetEntry();
    e.index = index;
    e.offset = offset;
    TabAutoHide.lastOffsets.push(e);
  }

  private static isBound(scroller: Scroller): boolean {
    for (let i = 0; i < TabAutoHide.bound.length; i++) {
      if (TabAutoHide.bound[i].scroller === scroller) {
        return true;
      }
    }
    return false;
  }
}

/** ArkTS 严格模式：对象字面量必须 new 已声明类（10605038）⇒ 成对结构显式声明 */
class TabScrollPair {
  index: number = 0;
  scroller: Scroller = new Scroller();
}

/** 页索引 → 累计偏移（判方向用） */
class OffsetEntry {
  index: number = 0;
  offset: number = 0;
}
