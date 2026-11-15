/**
 * 职责：宿主级用户设置门面（s7a）—— 把 PreferenceStore 里四个「有键无入口无消费点」的死配置键
 *      收敛成一处可读可写的类型化 API，并保证「保存即生效」：
 *      - USER_AGENT（'http_user_agent'）：写入后立即 HttpClient.setUserAgent，不用重启；
 *      - COOKIE_PREFIX（'cookie:'）：键名生成收敛到 PrefKeys.cookieKey()，CookieJar 与设置页共用；
 *      - READ_DIRECTION（'read_direction'）：ReaderView 读它决定横向翻页方向（rtl 为日漫反向）；
 *      - READER_TAP_TO_SCROLL（'reader_tap_to_scroll'）：放大后点按改为平移（滚动）画面，不再误翻页。
 * 依赖：data/kv/PreferenceStore（同步读 / 异步写）；data/net/HttpClient（UA 落地点）。
 * 入口：pages/SettingPage 读写全部字段；view/reader/ReaderView 与 pages/ReaderPage 读阅读偏好。
 * 依赖方向：本模块可依赖 data/net；data/net 反过来只能依赖 PrefKeys（叶子），别 import 本模块，
 *          否则 UserSettings → HttpClient → CookieJar → UserSettings 成环。
 *
 * 对应 Flutter：lib/config/global/global_setting.dart（上游 ReadSettingState）。
 * 差异说明：上游没有 UA 与 Cookie 设置项（lib/config 内 grep userAgent、cookie 零命中），
 *          这两项属我方自定范围；阅读方向对齐上游 reverseHorizontalPageTurn 的行为。
 *          上游 tapPageTurnInWebtoon 依赖纵向滚动模式（我方 T4 未落地），同一语义在横向模式下
 *          没有消费点；我方把它定成「放大后点按 = 平移一屏」：现在缩放最高 4 倍却没有平移手势，
 *          放大后只能看到中间一块，这个键顺手把那个缺陷补掉，且语义与键名字面一致。
 */
import { PreferenceStore, PrefKeys } from '../data/kv/PreferenceStore';
import { HttpClient, DEFAULT_UA } from '../data/net/HttpClient';

/**
 * 阅读模式取值（s13 第 6 条，存库用短码，同样「只能新增不能改既有语义」）：
 * PAGER = 横向翻页（现役档，一页一张，Swiper）；WEBTOON = 从上向下连续滚动（条漫档，List）。
 */
export class ReadScrollMode {
  /** 横向翻页（默认） */
  static readonly PAGER: string = 'pager';
  /** 从上向下连续滚动 */
  static readonly WEBTOON: string = 'webtoon';
}

/** 阅读方向取值（存库用短码，改值等于改已有数据：只能新增，不能改既有语义）。 */
export class ReadDirection {
  /** 从左到右（默认） */
  static readonly LTR: string = 'ltr';
  /** 从右到左（日漫） */
  static readonly RTL: string = 'rtl';
}

/** 设置项的可读标签（选择器与摘要行共用，避免两处文案漂移）。 */
export class SettingLabels {
  /** 与 ReadDirection 取值顺序一一对应 */
  static readonly READ_DIRECTION: string[] = ['从左到右', '从右到左'];
  /** 与 ReadScrollMode 取值顺序一一对应（s13 第 6 条：更多页「阅读模式」行与选项菜单共用） */
  static readonly READ_SCROLL_MODE: string[] = ['横向翻页', '从上向下滚动'];
}

/** 设置页展示用的运行时快照（不含敏感值，Cookie 只给条目数）。 */
export class UserSettingsSnapshot {
  userAgent: string = '';
  /** HttpClient 当前实际生效的 UA（未设置过 = 内置默认值） */
  effectiveUserAgent: string = '';
  readDirection: string = ReadDirection.LTR;
  tapToScroll: boolean = false;
  /** s13 第 6 条：阅读模式（pager / webtoon） */
  scrollMode: string = ReadScrollMode.PAGER;
  cookieHostCount: number = 0;
}

export class UserSettings {
  /**
   * 阅读模式的配置键（s13 第 6 条）。
   * 为什么不放进 data/kv/PreferenceStore 的 PrefKeys：本轮写域只有三个文件，PrefKeys 在写域外，
   * 越界改它会与并行的改动撞车。键名按 PrefKeys 的口径取（短码、下划线、语义唯一），
   * 消费点只有本模块（读写）⇒ 与 PrefKeys 里那些「一处定义多处引用」的键等价。
   * 后续整理时可原样搬进 PrefKeys 并改成引用，值不得改（改值 = 作废老用户已存的档位）。
   */
  private static readonly KEY_SCROLL_MODE: string = 'reader_scroll_mode';
  /**
   * 自动阅读三项（五项轮新增，口径照抄上游 ReadSettingState：竖向间隔 / 横向间隔 / 竖向距离%）。
   * 存实际值不存档位下标 ⇒ 以后调界不作废老数据。非法值（0/负数）一律返 0 由消费方回落默认。
   */
  private static readonly KEY_AUTO_COL_MS: string = 'reader_auto_col_ms';
  private static readonly KEY_AUTO_PAGE_MS: string = 'reader_auto_page_ms';
  private static readonly KEY_AUTO_DIST_PCT: string = 'reader_auto_dist_pct';
  /** 阅读方向；非法值（老数据或手改库）一律回落默认 */
  static readDirection(): string {
    const v: string = PreferenceStore.getInstance().getString(PrefKeys.READ_DIRECTION, ReadDirection.LTR);
    return v === ReadDirection.RTL ? ReadDirection.RTL : ReadDirection.LTR;
  }

  static isRtl(): boolean {
    return UserSettings.readDirection() === ReadDirection.RTL;
  }

  /**
   * 方向的响应式副本键（AppStorage）：五项轮起阅读器内设置面板可直接改向，
   * 口径与 STORAGE_SCROLL_MODE 完全一致（键名与写入口只在本类一处，消费方别各自 setOrCreate）。
   */
  static readonly STORAGE_DIRECTION: string = 'readerDirection';

  /** 同步推方向副本（不落库） */
  static pushDirection(value: string): string {
    const v: string = value === ReadDirection.RTL ? ReadDirection.RTL : ReadDirection.LTR;
    AppStorage.setOrCreate<string>(UserSettings.STORAGE_DIRECTION, v);
    return v;
  }

  static async setReadDirection(value: string): Promise<void> {
    const v: string = UserSettings.pushDirection(value);
    await PreferenceStore.getInstance().putString(PrefKeys.READ_DIRECTION, v);
  }

  /**
   * 阅读模式（s13 第 6 条）：非法值（老数据、手改库、以后新增档位的旧版本）一律回落 pager，
   * 与 readDirection 同一套兜底口径 —— 兜底方向选「现役行为」，不让一次脏数据改变所有人的阅读方式。
   */
  static readScrollMode(): string {
    const v: string = PreferenceStore.getInstance().getString(UserSettings.KEY_SCROLL_MODE, ReadScrollMode.PAGER);
    return v === ReadScrollMode.WEBTOON ? ReadScrollMode.WEBTOON : ReadScrollMode.PAGER;
  }

  static isWebtoon(): boolean {
    return UserSettings.readScrollMode() === ReadScrollMode.WEBTOON;
  }

  /**
   * 档位的响应式副本键（AppStorage）：阅读器（view/reader/ReaderView）用 @StorageProp 加 @Watch
   * 订阅它 ⇒ 阅读器还在路由栈里时从「更多」页改档也能立刻翻档（TabContent 子组件不重跑
   * aboutToAppear 这条老口径在这里同样成立，靠版本号 push 是同一个套路）。
   * 键名与写入口只在本类一处，两个消费方都调 pushScrollMode，别各自 setOrCreate。
   */
  static readonly STORAGE_SCROLL_MODE: string = 'readerScrollMode';

  /** 同步推档位副本（不落库）：落库见 setScrollMode，两者顺序 = 先推再落，见 setScrollMode 注释 */
  static pushScrollMode(value: string): string {
    const v: string = value === ReadScrollMode.WEBTOON ? ReadScrollMode.WEBTOON : ReadScrollMode.PAGER;
    AppStorage.setOrCreate<string>(UserSettings.STORAGE_SCROLL_MODE, v);
    return v;
  }

  /**
   * 写档：先同步推 AppStorage 副本（界面立刻响应），再异步落库（重启才需要）。
   * 顺序反过来的话，库卡住的那几百毫秒里界面停在旧档 = 用户以为没点上会再点一次。
   * 落库失败不回滚界面：档位是纯展示偏好，「界面跟手、重启回落」比「界面卡住」好，
   * 失败由调用方 toast 或打日志（ReaderView 里打日志，更多页里 toast）。
   */
  static async setScrollMode(value: string): Promise<void> {
    const v: string = UserSettings.pushScrollMode(value);
    await PreferenceStore.getInstance().putString(UserSettings.KEY_SCROLL_MODE, v);
  }

  /** 纵向滚动模式下点按是否翻一屏；横向翻页模式不受此项影响（点按恒翻页） */
  static tapToScroll(): boolean {
    return PreferenceStore.getInstance().getBool(PrefKeys.READER_TAP_TO_SCROLL, false);
  }

  /** 放大后点按平移的响应式副本键（五项轮，口径同 STORAGE_SCROLL_MODE / STORAGE_DIRECTION） */
  static readonly STORAGE_TAP_PAN: string = 'readerTapPan';

  /** 同步推平移档副本（不落库） */
  static pushTapPan(value: boolean): boolean {
    AppStorage.setOrCreate<boolean>(UserSettings.STORAGE_TAP_PAN, value);
    return value;
  }

  static async setTapToScroll(value: boolean): Promise<void> {
    const v: boolean = UserSettings.pushTapPan(value);
    await PreferenceStore.getInstance().putBool(PrefKeys.READER_TAP_TO_SCROLL, v);
  }

  /** 自动阅读：竖向滚动间隔 ms；0 = 未设置，消费方回落默认（上游默认 1600，界 300–5000） */
  static autoColIntervalMs(): number {
    const v: number = PreferenceStore.getInstance().getInt(UserSettings.KEY_AUTO_COL_MS, 0);
    return v > 0 ? v : 0;
  }

  /** 自动阅读：横向翻页间隔 ms；0 = 未设置（上游默认 3000，界 800–10000） */
  static autoPageIntervalMs(): number {
    const v: number = PreferenceStore.getInstance().getInt(UserSettings.KEY_AUTO_PAGE_MS, 0);
    return v > 0 ? v : 0;
  }

  /** 自动阅读：竖向每次滚动距离（视口高百分比）；0 = 未设置（上游默认 72，界 10–100） */
  static autoDistancePct(): number {
    const v: number = PreferenceStore.getInstance().getInt(UserSettings.KEY_AUTO_DIST_PCT, 0);
    return v > 0 ? v : 0;
  }

  static async setAutoColIntervalMs(ms: number): Promise<void> {
    await PreferenceStore.getInstance().putInt(UserSettings.KEY_AUTO_COL_MS, ms);
  }

  static async setAutoPageIntervalMs(ms: number): Promise<void> {
    await PreferenceStore.getInstance().putInt(UserSettings.KEY_AUTO_PAGE_MS, ms);
  }

  static async setAutoDistancePct(pct: number): Promise<void> {
    await PreferenceStore.getInstance().putInt(UserSettings.KEY_AUTO_DIST_PCT, pct);
  }

  /**
   * 数值偏好的通用钳位（五项轮）：脏数据（手改库 / 老版本越界值 / NaN）一律回落 def，
   * 落在界内才放行。消费方是阅读器读自动阅读三项的地方 —— 间隔被打成 0 会让自动阅读
   * 变成死循环，所以宁可用默认值也不能原样放行。
   */
  static clampInt(value: number, min: number, max: number, def: number): number {
    if (!Number.isFinite(value)) {
      return def;
    }
    const v: number = Math.round(value);
    if (v < min || v > max) {
      return def;
    }
    return v;
  }

  /** 已存的 UA 原文；空串 = 从未设置过，走 HttpClient 内置默认 */
  static userAgent(): string {
    return PreferenceStore.getInstance().getString(PrefKeys.USER_AGENT, '');
  }

  /**
   * 写 UA：trim 后空串 = 删除键（恢复内置默认 UA），非空 = 立即生效。
   * 先落库再改内存：反过来会出现「本次生效、重启又变回去」的漂移，比不生效更难查。
   * 注意 HttpClient.setUserAgent 对空串是不覆盖，所以清空必须走 PreferenceStore.remove。
   */
  static async setUserAgent(value: string): Promise<void> {
    const v: string = value.trim();
    if (v.length === 0) {
      await PreferenceStore.getInstance().remove(PrefKeys.USER_AGENT);
      HttpClient.getInstance().setUserAgent(DEFAULT_UA);
      return;
    }
    await PreferenceStore.getInstance().putString(PrefKeys.USER_AGENT, v);
    HttpClient.getInstance().setUserAgent(v);
  }

  /** 设置页一次性读取（偏好层没初始化时自然回落默认值，不外抛） */
  static snapshot(cookieHostCount: number): UserSettingsSnapshot {
    const s: UserSettingsSnapshot = new UserSettingsSnapshot();
    s.userAgent = UserSettings.userAgent();
    s.effectiveUserAgent = HttpClient.getInstance().getUserAgent();
    s.readDirection = UserSettings.readDirection();
    s.tapToScroll = UserSettings.tapToScroll();
    s.scrollMode = UserSettings.readScrollMode();
    s.cookieHostCount = cookieHostCount;
    return s;
  }
}