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
}

/** 设置页展示用的运行时快照（不含敏感值，Cookie 只给条目数）。 */
export class UserSettingsSnapshot {
  userAgent: string = '';
  /** HttpClient 当前实际生效的 UA（未设置过 = 内置默认值） */
  effectiveUserAgent: string = '';
  readDirection: string = ReadDirection.LTR;
  tapToScroll: boolean = false;
  cookieHostCount: number = 0;
}

export class UserSettings {
  /** 阅读方向；非法值（老数据或手改库）一律回落默认 */
  static readDirection(): string {
    const v: string = PreferenceStore.getInstance().getString(PrefKeys.READ_DIRECTION, ReadDirection.LTR);
    return v === ReadDirection.RTL ? ReadDirection.RTL : ReadDirection.LTR;
  }

  static isRtl(): boolean {
    return UserSettings.readDirection() === ReadDirection.RTL;
  }

  static async setReadDirection(value: string): Promise<void> {
    await PreferenceStore.getInstance().putString(PrefKeys.READ_DIRECTION,
      value === ReadDirection.RTL ? ReadDirection.RTL : ReadDirection.LTR);
  }

  /** 纵向滚动模式下点按是否翻一屏；横向翻页模式不受此项影响（点按恒翻页） */
  static tapToScroll(): boolean {
    return PreferenceStore.getInstance().getBool(PrefKeys.READER_TAP_TO_SCROLL, false);
  }

  static async setTapToScroll(value: boolean): Promise<void> {
    await PreferenceStore.getInstance().putBool(PrefKeys.READER_TAP_TO_SCROLL, value);
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
    s.cookieHostCount = cookieHostCount;
    return s;
  }
}
