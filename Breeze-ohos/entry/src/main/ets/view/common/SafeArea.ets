/**
 * 职责：沉浸式布局下的安全区测量（状态栏 / 导航条）与屏幕尺寸换算，写入 AppStorage 供各组件共享。
 * 依赖：@kit.ArkUI 的 window、display；@kit.AbilityKit 的 common。
 * 对应 Flutter：MediaQuery.padding.top / MediaQuery.padding.bottom 与 SafeArea 组件。
 * 说明：EntryAbility 会 setWindowLayoutFullScreen(true)，所以顶栏必须自己避让状态栏，不能写死 24vp。
 */

import { window, display } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppKeys, Dim } from './Theme';

export class ScreenUtil {
  /** 屏幕宽度（vp） */
  static widthVp(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      return d.width / density;
    } catch (err) {
      return 360;
    }
  }

  /** 屏幕高度（vp） */
  static heightVp(): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      return d.height / density;
    } catch (err) {
      return 780;
    }
  }

  /** px -> vp，避免在非 UI 线程使用 px2vp */
  static px2vpSafe(px: number): number {
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      const density: number = d.densityPixels > 0 ? d.densityPixels : 1;
      return px / density;
    } catch (err) {
      return 0;
    }
  }
}

export class SafeAreaUtil {
  /**
   * 读取窗口避让区并写入 AppStorage。可重复调用（幂等）。
   * top: TYPE_SYSTEM.topRect.height      -> 状态栏高度（沉浸式下顶栏自行追加）
   * bottom: TYPE_NAVIGATION_INDICATOR.bottomRect.height -> home indicator，但收敛到 20vp
   */
  static sync(ctx: common.UIAbilityContext): void {
    SafeAreaUtil.syncInner(ctx).catch((err: BusinessError) => {
      console.error(`[SafeArea] sync failed: code=${err.code} msg=${err.message}`);
    });
  }

  private static async syncInner(ctx: common.UIAbilityContext): Promise<void> {
    try {
      const win: window.Window = await window.getLastWindow(ctx);
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);

      const topVp: number = ScreenUtil.px2vpSafe(sys.topRect.height);
      const bottomRaw: number = ScreenUtil.px2vpSafe(nav.bottomRect.height);
      // 华为规范：导航条避让间距超过 20vp 属空间浪费，做上限收敛
      const bottomVp: number = Math.min(Math.max(bottomRaw, 0), Dim.navAvoidMax);

      SafeAreaUtil.setTop(topVp);
      SafeAreaUtil.setBottom(bottomVp);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[SafeArea] getWindowAvoidArea failed: code=${e.code} msg=${e.message}`);
    }
  }

  static setTop(vp: number): void {
    const v: number = Math.max(0, Math.round(vp));
    if (v !== AppStorage.get<number>(AppKeys.topSafe)) {
      AppStorage.setOrCreate<number>(AppKeys.topSafe, v);
    }
  }

  static setBottom(vp: number): void {
    const v: number = Math.min(Math.max(0, Math.round(vp)), Dim.navAvoidMax);
    if (v !== AppStorage.get<number>(AppKeys.bottomSafe)) {
      AppStorage.setOrCreate<number>(AppKeys.bottomSafe, v);
    }
  }

  /** 供 EntryAbility 在窗口变化（旋转 / 折叠 / 手势条切换）后重算 */
  static applyFromAvoidArea(sysTopPx: number, navBottomPx: number): void {
    SafeAreaUtil.setTop(ScreenUtil.px2vpSafe(sysTopPx));
    SafeAreaUtil.setBottom(ScreenUtil.px2vpSafe(navBottomPx));
  }
}
