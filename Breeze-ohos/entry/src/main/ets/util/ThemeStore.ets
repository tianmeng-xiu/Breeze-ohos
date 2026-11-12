/**
 * 职责：深浅色「三态」偏好（跟随系统 / 浅色 / 深色）的持久化与生效门面。
 *      补 s7a 遗留：深色开关此前只翻 AppStorage['isDark']，既不落盘（重启回系统档），
 *      也不通知系统（系统仍在原档 ⇒ 系统侧渲染的东西不跟着变，真机回传缺陷④
 *      「手动切换亮色模式后底栏下半部分仍是黑色」正是这个撕裂）。
 * 依赖：@kit.AbilityKit（ConfigurationConstant / common）、@kit.ArkData（preferences 同步读）、
 *      data/kv/PreferenceStore、view/common/Theme.AppKeys（AppStorage 'isDark' 是全页 @StorageProp 的唯一真源）。
 * 入口：EntryAbility.onCreate（首帧推界面色档）、
 *      EntryAbility.onWindowStageCreate 的 loadContent 回调（补系统侧 setColorMode）、
 *      EntryAbility.onConfigurationUpdate（系统配置变化时刷新，不再重发 setColorMode）、
 *      view/mine/MinePage「深色模式」行 与 pages/SettingPage「外观」分组（用户切换）。
 *
 * ---- 生效路径（SDK 实证，别改顺序）----
 *  UIAbilityContext.setColorMode(colorMode) —— UIAbilityContext.d.ts:1253，@since 17。
 *    官方注释三条硬约束：色档优先级「UIAbility 档 > ApplicationContext.setColorMode（:326）>
 *    系统档」；「必须在 loadContent 之后、主线程调用」⇒ setColorMode 只允许在
 *    onWindowStageCreate 的 loadContent 成功回调之后调用（onCreate 里调静默无效）；
 *    「After this API is called, a new resource manager object is created」⇒ 工程内不得缓存
 *    resourceManager 跨色档复用（实测各页都是就地取用，无缓存点），且重复下发要尽量避免。
 *  色档字面量：COLOR_MODE_NOT_SET = -1（跟随系统）/ COLOR_MODE_DARK = 0 / COLOR_MODE_LIGHT = 1
 *    —— ConfigurationConstant.d.ts:48/57/66。
 *
 * ---- s8a 白屏修复（两条硬事实，别回退）----
 *  ① 旧时序把色档生效排在数据闸门（DataBootstrap.initDataLayer，实测约 200 至 400ms）之后
 *     ⇒ 手选「深色」+ 系统浅色时，首帧按浅色画完再翻深色 = 用户报的「冷启动短时间浅色」。
 *  ② preferences.getPreferences 是异步的，preferences.getPreferencesSync（@since 10）是同步的
 *     ⇒ 色档读取走同步版（preferredNow），onCreate 里就能拿到已存档位，不必等 PreferenceStore.init()。
 *     同步版与 PreferenceStore 的异步版 name 相同（breeze_prefs）⇒ 系统缓存同一个实例
 *     （@ohos.data.preferences.d.ts 原文「the obtained Preferences instance is cached」），
 *     两条读路径不会看到两份数据。
 *  分工：界面色档（AppStorage）首帧就推；系统侧 setColorMode 仍守「loadContent 之后」这条红线，
 *     由 applyNow 一处收口，并用 appliedCode 做幂等（同档不重发）。
 */
import { ConfigurationConstant, common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { PreferenceStore } from '../data/kv/PreferenceStore';
import { AppKeys } from '../view/common/Theme';
import { Logger } from './Logger';

/**
 * 偏好桶名：必须与 data/kv/PreferenceStore.ets:12 的 PREF_NAME 逐字相同（那个常量没有 export，
 * 这里同步一份，改一边必须改另一边）。同步版与异步版走同一个 name ⇒ 系统缓存同一个实例。
 */
const PREF_NAME: string = 'breeze_prefs';

/** 幂等标记的「还没下发过 / 上次下发失败」哨兵（不是任何合法 colorMode 取值 -1/0/1）。 */
const CODE_UNKNOWN: number = -99;

/** 三态取值（落盘就是这三个字面量，别存数字：换序会静默改语义）。 */
export class ThemeMode {
  static readonly SYSTEM: string = 'system';
  static readonly LIGHT: string = 'light';
  static readonly DARK: string = 'dark';
}

/** 三态文案（MinePage 与 SettingPage 共用一份，避免两处漂移）。 */
export class ThemeModeLabels {
  static readonly ALL: string[] = ['跟随系统', '浅色', '深色'];

  static of(mode: string): string {
    if (mode === ThemeMode.LIGHT) {
      return ThemeModeLabels.ALL[1];
    }
    if (mode === ThemeMode.DARK) {
      return ThemeModeLabels.ALL[2];
    }
    return ThemeModeLabels.ALL[0];
  }

  /** 三态循环：跟随系统 -> 浅色 -> 深色 -> 跟随系统（MinePage 那一行点击用）。 */
  static next(mode: string): string {
    if (mode === ThemeMode.SYSTEM) {
      return ThemeMode.LIGHT;
    }
    if (mode === ThemeMode.LIGHT) {
      return ThemeMode.DARK;
    }
    return ThemeMode.SYSTEM;
  }
}

export class ThemeStore {
  static readonly PREF_KEY: string = 'theme_mode';
  /** AppStorage 里的色档镜像键：三态文案要随切换重绘（@StorageProp 只能观察 AppStorage）。 */
  static readonly STORAGE_KEY: string = 'themeMode';

  /** 本会话最后一次生效的色档（onConfigurationUpdate 用它决定该不该让系统配置覆盖 isDark）。 */
  private static applied: string = ThemeMode.SYSTEM;

  /** 本会话最后一次向系统下发的 colorMode 数值（只做幂等比较，不参与业务判断）。 */
  private static appliedCode: number = CODE_UNKNOWN;

  /** 本会话最后一次同步读到的档位（PreferenceStore 未就绪时 current() 的兜底源）。 */
  private static bootMode: string = ThemeMode.SYSTEM;

  /** 系统真实色档是否深色（只在「未被我方覆盖」时采样，见 noteSystemDark / sysDark）。 */
  private static sysDarkCached: boolean = false;

  /** sysDarkCached 是否采到过样（没采到过就退回读 config）。 */
  private static sysDarkKnown: boolean = false;

  /** 字面量归一：只有 light/dark 是手选档，其余（含脏值、类型不符）一律按跟随系统。 */
  private static normalize(v: string): string {
    if (v === ThemeMode.LIGHT || v === ThemeMode.DARK) {
      return v;
    }
    return ThemeMode.SYSTEM;
  }

  /**
   * 同步读已存色档（首帧专用）：不依赖 PreferenceStore 的异步 init，onCreate 里就能拿到。
   * 任何异常都不抛，退回本会话上一次档位 ⇒ 冷启动永远有档可用。结果顺手记进 bootMode。
   */
  static preferredNow(ctx: common.BaseContext | undefined): string {
    if (ctx === undefined || ctx === null) {
      return ThemeStore.bootMode;
    }
    try {
      const options: preferences.Options = { name: PREF_NAME };
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, options);
      const raw: preferences.ValueType = store.getSync(ThemeStore.PREF_KEY, ThemeMode.SYSTEM);
      const mode: string = ThemeStore.normalize(typeof raw === 'string' ? raw as string : ThemeMode.SYSTEM);
      ThemeStore.bootMode = mode;
    } catch (e) {
      Logger.ex('同步读色档失败，暂按 ' + ThemeStore.bootMode, e as Object);
    }
    return ThemeStore.bootMode;
  }

  /**
   * 首帧推送：只写 AppStorage，绝不碰 setColorMode（那条 API 必须等 loadContent 之后）。
   * 冷启动两步走 = onCreate 先推界面色档 → loadContent 回调 applyNow 补系统侧色档。
   * 返回推送后的 isDark。
   */
  static pushEarly(ctx: common.BaseContext | undefined, sysDark: boolean): boolean {
    const mode: string = ThemeStore.preferredNow(ctx);
    const dark: boolean = ThemeStore.isDarkOf(mode, sysDark);
    ThemeStore.applied = mode;
    ThemeStore.publish(mode, dark);
    Logger.i('首帧色档 ' + mode + ' => isDark=' + dark);
    return dark;
  }

  /**
   * 当前生效档位（落盘值优先）：PreferenceStore 未就绪时用同步读到的 bootMode 兜底，
   * 这样 UI 侧（SettingPage / MinePage）不会在首帧把「深色」显示成「跟随系统」。
   */
  static current(): string {
    const store: PreferenceStore = PreferenceStore.getInstance();
    if (!store.isReady()) {
      return ThemeStore.bootMode;
    }
    return ThemeStore.normalize(store.getString(ThemeStore.PREF_KEY, ThemeStore.bootMode));
  }

  /**
   * 记录「系统真实色档」样本 —— 调用方只能在**我方没有覆盖过 colorMode** 的时刻递进来
   * （onCreate 里 setColorMode 还没跑、以及跟随系统档下的 onConfigurationUpdate）。
   * 必要性：setColorMode 会把本 Ability 的 config.colorMode 改成我方设的档（官方口径
   * 「UIAbility 档 > ApplicationContext 档 > 系统档」），此后 context.config 拿到的
   * 是「自己设的值」而不是系统真值 ⇒ 手选深色里再切「跟随系统」会读到脏的 sysDark。
   */
  static noteSystemDark(sysDark: boolean): void {
    ThemeStore.sysDarkCached = sysDark;
    ThemeStore.sysDarkKnown = true;
  }

  /**
   * 系统档是否深色（供页面侧算 isDarkOf 用）。
   * 页面拿到的 getContext(this) 类型是 BaseContext，config 在 UIAbilityContext 上
   * （UIAbilityContext.d.ts:82 config: Configuration），这里做一次窄化转型 + 容错：
   * 非 UIAbility 环境（表单/测试桩）拿不到 config ⇒ 退回 AppStorage['isDark'] 现值。
   * 手选档生效期间 config 是被我方覆盖的 ⇒ 改递缓存的系统真值（SettingPage / MinePage
   * 直接调本方法取第三参，这样切回「跟随系统」当场就能落到正确的深浅色）。
   */
  static sysDark(ctx: common.BaseContext | undefined): boolean {
    const fallback: boolean = AppStorage.get<boolean>(AppKeys.isDark) === true;
    let v: boolean = fallback;
    try {
      const src: ESObject = ctx as ESObject;
      if (src !== undefined && src !== null) {
        const cm: number = src.config.colorMode as number;
        v = cm === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
      }
    } catch (e) {
      v = fallback;
    }
    if (!ThemeStore.isManual()) {
      // 跟随系统 ⇒ config 没被覆盖，这就是系统真值，顺手刷新缓存
      ThemeStore.noteSystemDark(v);
      return v;
    }
    return ThemeStore.sysDarkKnown ? ThemeStore.sysDarkCached : v;
  }

  /**
   * 该档下界面实际是不是深色。sysDark = 系统档是否深色
   * （EntryAbility.isDarkMode() 读 context.config.colorMode）。
   */
  static isDarkOf(mode: string, sysDark: boolean): boolean {
    if (mode === ThemeMode.DARK) {
      return true;
    }
    if (mode === ThemeMode.LIGHT) {
      return false;
    }
    return sysDark;
  }

  /** 档位 → 系统 colorMode 枚举（给 setColorMode 用，全程不做强转）。 */
  private static sysModeOf(mode: string): ConfigurationConstant.ColorMode {
    if (mode === ThemeMode.DARK) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    }
    if (mode === ThemeMode.LIGHT) {
      return ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
    }
    return ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET;
  }

  /** 档位 → colorMode 的数值码（NOT_SET -1 / DARK 0 / LIGHT 1），仅用于幂等比较与日志。 */
  private static codeOf(mode: string): number {
    if (mode === ThemeMode.DARK) {
      return 0;
    }
    if (mode === ThemeMode.LIGHT) {
      return 1;
    }
    return -1;
  }

  /** 把档位写进 AppStorage（两处真源：isDark 决定取色，themeMode 决定文案）。 */
  private static publish(mode: string, dark: boolean): void {
    AppStorage.setOrCreate<boolean>(AppKeys.isDark, dark);
    AppStorage.setOrCreate<string>(ThemeStore.STORAGE_KEY, mode);
  }

  /**
   * 色档生效（唯一收口）：先推 AppStorage，再向系统下发 colorMode。
   * setColorMode 失败不抛（界面仍按 AppStorage 走）。返回生效后的 isDark。
   * 幂等：同一档不重发 ⇒ 省一次 resourceManager 重建，也少触发一次 onConfigurationUpdate 回环。
   */
  static applyNow(ctx: common.UIAbilityContext | undefined, sysDark: boolean): boolean {
    return ThemeStore.applyNowWith(ThemeStore.current(), ctx, sysDark);
  }

  /** applyNow 的显式档位版：setMode 落盘后直接拿目标档生效，省一次读盘。 */
  static applyNowWith(mode: string, ctx: common.UIAbilityContext | undefined, sysDark: boolean): boolean {
    const m: string = ThemeStore.normalize(mode);
    const dark: boolean = ThemeStore.isDarkOf(m, sysDark);
    ThemeStore.applied = m;
    ThemeStore.bootMode = m;
    ThemeStore.publish(m, dark);
    const code: number = ThemeStore.codeOf(m);
    if (ctx === undefined || ctx === null) {
      Logger.w('应用色档缺 context，仅改 AppStorage（mode=' + m + '）');
      return dark;
    }
    if (code === ThemeStore.appliedCode) {
      return dark;
    }
    // 冷启动 + 跟随系统：本会话从没下发过，而「跟随系统」就是 Ability 的默认态 ⇒ 不必下发。
    // 省掉这一趟就省掉首屏最敏感的一次 resourceManager 重建与一次 onConfigurationUpdate 回环。
    if (code === -1 && ThemeStore.appliedCode === CODE_UNKNOWN) {
      ThemeStore.appliedCode = code;
      Logger.i('应用色档 system => isDark=' + dark + '（默认态，未下发 setColorMode）');
      return dark;
    }
    ThemeStore.appliedCode = code;
    try {
      ctx.setColorMode(ThemeStore.sysModeOf(m));
      Logger.i('应用色档 ' + m + ' => isDark=' + dark + ' colorMode=' + code);
    } catch (e) {
      // 下发失败 ⇒ 幂等标记打回哨兵，下次 applyNow 允许重试
      ThemeStore.appliedCode = CODE_UNKNOWN;
      Logger.ex('setColorMode 失败（mode=' + m + '）', e as Object);
    }
    return dark;
  }

  /**
   * 系统配置变化时刷新界面色档（只发 AppStorage，不再调 setColorMode）：
   * applied 是手选档 ⇒ 界面保持手选档（这次系统变化多半是 setColorMode 自己触发的回环），
   * applied 是跟随系统 ⇒ 直接用系统这次给的 sysDark。
   */
  static resync(sysDark: boolean): boolean {
    const m: string = ThemeStore.applied;
    if (m === ThemeMode.SYSTEM) {
      // 跟随系统 ⇒ 这次系统给的色档就是真值，缓存下来（之后手选档再切回来时有底）
      ThemeStore.noteSystemDark(sysDark);
    }
    const dark: boolean = ThemeStore.isDarkOf(m, sysDark);
    ThemeStore.publish(m, dark);
    return dark;
  }

  /** 用户切换：先落盘（异步，失败也当场生效，下次启动回退旧值可接受），再生效。 */
  static async setMode(ctx: common.UIAbilityContext | undefined, mode: string,
    sysDark: boolean): Promise<void> {
    const v: string = (mode === ThemeMode.LIGHT || mode === ThemeMode.DARK) ? mode : ThemeMode.SYSTEM;
    try {
      await PreferenceStore.getInstance().putString(ThemeStore.PREF_KEY, v);
    } catch (e) {
      Logger.ex('色档落盘失败（' + v + '）', e as Object);
    }
    ThemeStore.applyNowWith(v, ctx, sysDark);
  }

  /** 本会话生效的色档（跟随系统时页面文案该显示「跟随系统」而不是「已关闭」）。 */
  static lastApplied(): string {
    return ThemeStore.applied;
  }

  /** 手选过档（light/dark）⇒ 系统配置变化不能覆盖界面色档。 */
  static isManual(): boolean {
    const m: string = ThemeStore.current();
    return m === ThemeMode.LIGHT || m === ThemeMode.DARK;
  }
}
