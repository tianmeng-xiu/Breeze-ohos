/**
 * 职责：应用唯一 UIAbility 入口。加载首页、开启沉浸式全屏、测量并下发安全区、跟随深浅色切换系统栏。
 * 依赖：@kit.AbilityKit / @kit.ArkUI / Theme.AppKeys。
 * 对应 Flutter：lib/main.dart + lib/page/navigation_bar.dart 里 SystemChrome 的初始化部分。
 * 说明：setWindowLayoutFullScreen(true) 后，状态栏区域会与内容重叠，顶栏（BreezeTopBar）通过
 *      AppStorage['topSafeHeight'] 自行追加避让高度；底栏对导航条避让收敛到 ≤20vp（Dim.navAvoidMax）。
 * 深浅色（缺陷④ + s8a 白屏）：色档三态由 util/ThemeStore 持有并落盘，分两步生效：
 *      onCreate 里 pushEarly 同步读落盘档并只推 AppStorage（界面首帧即定档，不等数据层），
 *      onWindowStageCreate 的 loadContent 回调里 applyNow 补系统侧 setColorMode（官方前置 = 已 loadContent）；
 *      onConfigurationUpdate 只 resync 界面色档、不再回手 setColorMode（免得自己触发自己）。
 *      窗口底色在 applySystemBar 里一并覆盖（setWindowBackgroundColor，@since 9，硬约束
 *      「必须 loadContent 之后」⇒ 用 contentLoaded 把关）：手选深色而系统仍浅色时窗口底
 *      不会自己变 ⇒ 不覆盖就露白边。
 * 启动窗（s8a）：resources/dark/element/color.json 已把 start_window_background 覆成 #000000，
 *      但资源限定词按**系统**色档挑 ⇒ 只有「跟随系统且系统=深」时启动窗才是黑底；
 *      「手选深 + 系统浅」这一档启动窗必然仍是白的（启动窗早于任何 JS，本文件的
 *      setWindowBackgroundColor 追不上），残余闪烁属已知未根治项。
 *      另：base/element/color.json 里的 start_window_background_dark 是历史遗留的零引用资源，
 *      保留不删；element 下的 json 由 restool 严格 JSON 解析、不接受注释，故该说明记在这里。
 */
import { AbilityConstant, UIAbility, Want, Configuration, ConfigurationConstant } from '@kit.AbilityKit';
import { window, display } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { AppKeys, Dim, Theme } from '../view/common/Theme';
import { initDataLayer } from '../data/DataBootstrap';
import { ThemeStore } from '../util/ThemeStore';
import { engineInit, engineSelftest } from '../util/PluginRuntime';

const DOMAIN: number = 0xB2E2;
const TAG: string = 'Breeze';

export default class EntryAbility extends UIAbility {
  private mainWindow: window.Window | null = null;
  /** loadContent 是否已成功（setColorMode 的官方前置条件）。 */
  private contentLoaded: boolean = false;
  /** 数据层（含 PreferenceStore）是否就绪（色档落盘值可读的前置条件）。 */
  private dataReady: boolean = false;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'EntryAbility onCreate');
    AppStorage.setOrCreate(AppKeys.topSafe, 0);
    AppStorage.setOrCreate(AppKeys.bottomSafe, 0);
    // s8a 白屏修复：这里就按「已存色档」推 AppStorage（ThemeStore 内部走 preferences 同步读，
    // 不依赖 initDataLayer 里那个异步的 PreferenceStore.init）。旧写法先塞系统色档、把落盘档等到
    // 数据闸门（实测 200 至 400ms）之后再推 ⇒ 手选深色 + 系统浅色时首帧浅色闪一下。
    // setColorMode 仍然只在 loadContent 之后调（官方硬约束），本行只动 AppStorage。
    ThemeStore.pushEarly(this.context, this.isDarkMode());
    // C13：诊断入口门控键初始化（刻意不落盘：仅本次会话，杀进程恢复隐藏）。
    AppStorage.setOrCreate('diagGate', false);

    // 数据层初始化（偏好库 -> CookieJar -> RDB -> Repository -> 图片缓存 -> 内置图源）。
    // 不阻塞首帧：失败只记日志，页面侧各自有兜底空态。
    initDataLayer(this.context).then(() => {
      hilog.info(DOMAIN, TAG, 'data layer ready');
      this.dataReady = true;
      // 兜底收敛：偏好库就绪后再对一次账（正常路径下首帧已经按同步读的结果定档，
      // 同档时 applyNow 不会再调 setColorMode，只重推 AppStorage 与窗口底色）。
      if (this.contentLoaded) {
        ThemeStore.applyNow(this.context, this.isDarkMode());
        if (this.mainWindow !== null) {
          this.applySystemBar(this.mainWindow);
        }
      }
    }).catch((e: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'data layer init failed: %{public}s', e.message);
    });

    // S1 spike 探针：装载 libbreeze_qjs_ohos.so（rquickjs + 上游 playground），跑一次内置自检。
    // 真机日志里出现 `[qjs] selftest ok {json}` 即证明「NDK 交叉编译 -> NAPI 装载 -> QuickJS 求值」闭环。
    // 失败不抛到 UI 线程外：只记日志，避免影响首帧。
    this.probePluginEngine();
  }

  /** S2：原生插件引擎的一次性自检（S2 起 selftest 是 Promise，只能异步取结果）。 */
  private probePluginEngine(): void {
    try {
      // §12.5：init 第二参 = 插件目录根（host-fs 无 jail，边界全靠它 ⇒ 面板 11/12 行硬前提）。
      // onCreate 里 this.context 一定可用；万一取不到退回 getContext(this)。
      const root: string = this.context?.filesDir ?? getContext(this).filesDir;
      const initResult: string = engineInit(true, root);
      hilog.info(DOMAIN, TAG, '[qjs] init=%{public}s', initResult);
      engineSelftest()
        .then((selftest: string) => {
          hilog.info(DOMAIN, TAG, '[qjs] selftest=%{public}s', selftest);
          if (selftest.length === 0) {
            hilog.warn(DOMAIN, TAG, '[qjs] selftest returned empty');
          }
        })
        .catch((e: Error) => {
          hilog.error(DOMAIN, TAG, '[qjs] selftest rejected: %{public}s', e.message ?? 'unknown');
        });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, '[qjs] native engine probe failed: %{public}s', err.message ?? 'unknown');
    }
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err && err.code) {
        hilog.error(DOMAIN, TAG, 'loadContent failed: %{public}d %{public}s', err.code, err.message);
        return;
      }
      hilog.info(DOMAIN, TAG, 'loadContent succeeded');
      // 缺陷④：页面已加载 ⇒ 这是 setColorMode 的第一个合法时机（官方注释硬约束）。
      // applyNow 同时落 AppStorage['isDark'] 与窗口底色，各页 @StorageProp 与系统侧一次对齐。
      // 偏好库若尚未就绪，这里读的是首帧那次同步读记下的档位，上面的 dataReady 分支会再补一次。
      this.contentLoaded = true;
      ThemeStore.applyNow(this.context, this.isDarkMode());
      if (this.mainWindow !== null) {
        this.applySystemBar(this.mainWindow);
      }
    });

    try {
      this.mainWindow = windowStage.getMainWindowSync();
      const win: window.Window = this.mainWindow;
      // 沉浸式：内容铺满整屏，安全区由 View 层自行避让
      win.setWindowLayoutFullScreen(true);
      this.applySystemBar(win);
      this.syncAvoidArea(win);

      win.on('avoidAreaChange', (data: window.AvoidAreaOptions) => {
        hilog.info(DOMAIN, TAG, 'avoidAreaChange type=%{public}d', data.type as number);
        this.syncAvoidArea(win);
      });

      win.on('windowSizeChange', () => {
        this.syncAvoidArea(win);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.error(DOMAIN, TAG, 'window init failed: %{public}s', err.message);
    }
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    const sysDark: boolean = newConfig.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    // 手选过浅色/深色 ⇒ 系统配置变化（用户去系统设置切深色、定时深浅色）不得覆盖界面；
    // 跟随系统 ⇒ 原样跟随。两种情况都由 resync 重推 AppStorage['isDark'] 与 themeMode。
    // 这里刻意不再调 setColorMode：本回调很可能就是上一次 setColorMode 自己触发的回环，
    // 回手再设一次既白建一个 resourceManager（官方注释：setColorMode 会新建 resourceManager），
    // 又多触发一次本回调 ⇒ 手选档下的稳定态靠 applied 保证，不靠重发。
    ThemeStore.resync(sysDark);
    if (this.mainWindow !== null) {
      this.applySystemBar(this.mainWindow);
    }
  }

  onWindowStageDestroy(): void {
    this.mainWindow = null;
  }

  onForeground(): void {
    if (this.mainWindow !== null) {
      this.syncAvoidArea(this.mainWindow);
    }
  }

  /**
   * 系统栏图标颜色 + 窗口底色跟随深浅色，避免深色模式下状态栏图标看不清、窗口底留白。
   * 取色读 AppStorage['isDark']（手选档的唯一真源），不再读 context.config —— 后者在
   * setColorMode 生效前后会短暂与界面不一致，图标色会闪。
   */
  private applySystemBar(win: window.Window): void {
    const dark: boolean = AppStorage.get<boolean>(AppKeys.isDark) === true;
    const contentColor: string = dark ? '#FFFFFF' : '#000000';
    this.syncWindowBackground(win, dark);
    try {
      win.setWindowSystemBarProperties({
        statusBarColor: '#00000000',
        statusBarContentColor: contentColor,
        navigationBarColor: '#00000000',
        navigationBarContentColor: contentColor
      }).catch((e: BusinessError) => {
        hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties failed: %{public}s', e.message);
      });
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setWindowSystemBarProperties threw: %{public}s', err.message);
    }
  }

  /**
   * 缺陷②（白条）：把窗口底色跟住界面色档。
   * 窗口底不由 $r 资源决定 —— module.json5 的 startWindowBackground 是 base 目录下的静态白、
   * 没有 dark 限定词目录，setColorMode 只切本 Ability 的资源与配置，窗口创建时那个底不会自己变；
   * 于是手选深色而系统仍浅色时，内容没铺满的边缘（圆角、键盘避让、动效空档）露出白边。
   * 正规入口 = window.Window.setWindowBackgroundColor（@ohos.window.d.ts:6427，@since 9，
   * 非 Promise，抛 1300002 的条件 = 窗口未就绪），官方硬约束「必须 loadContent 之后」
   * ⇒ 用 contentLoaded 把关：onWindowStageCreate 里那次 applySystemBar 早于 loadContent 完成，
   * 那一趟跳过，由 loadContent 成功回调里的那次覆盖生效。
   */
  private syncWindowBackground(win: window.Window, dark: boolean): void {
    if (!this.contentLoaded) {
      return;
    }
    try {
      // 与页面根容器同一个令牌（Theme.background = bg #F1F3F5 / dBg #000000），
      // 保证「窗口底 = 页面底」，不会在页面之外再露出一层异色。
      win.setWindowBackgroundColor(Theme.background(dark));
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'setWindowBackgroundColor failed: %{public}s', err.message ?? 'unknown');
    }
  }

  /** 读取避让区并换算为 vp 写入 AppStorage（幂等，可反复调用） */
  private syncAvoidArea(win: window.Window): void {
    try {
      const density: number = display.getDefaultDisplaySync().densityPixels;
      const sys: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM);
      const nav: window.AvoidArea = win.getWindowAvoidArea(window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR);
      const topVp: number = density > 0 ? sys.topRect.height / density : 0;
      // 华为规范：导航条已预留安全边距，底栏避让上限 20vp
      const rawBottom: number = density > 0 ? nav.bottomRect.height / density : 0;
      const bottomVp: number = rawBottom > Dim.navAvoidMax ? Dim.navAvoidMax : rawBottom;
      AppStorage.setOrCreate(AppKeys.topSafe, topVp);
      AppStorage.setOrCreate(AppKeys.bottomSafe, bottomVp);
    } catch (e) {
      const err = e as BusinessError;
      hilog.warn(DOMAIN, TAG, 'syncAvoidArea failed: %{public}s', err.message);
    }
  }

  /**
   * 系统档是否深色。注意这条读数只在「我方还没覆盖过 colorMode」时才是系统真值：
   * setColorMode 之后 config.colorMode 变成我方设的档（优先级 UIAbility 档 > 系统档）。
   * 因此跟随系统档下顺手把它记进 ThemeStore 缓存，手选档下不记（免得把自设值当系统值存下来）。
   */
  private isDarkMode(): boolean {
    let dark: boolean = false;
    try {
      dark = this.context.config.colorMode === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    } catch (e) {
      return false;
    }
    if (!ThemeStore.isManual()) {
      ThemeStore.noteSystemDark(dark);
    }
    return dark;
  }
}
