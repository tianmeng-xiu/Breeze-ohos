/**
 * 职责：S2 宿主回调实现 —— 用 ArkTS 路由替代上游 dart.* 的 5 个宿主路由。
 * 链路：JS bridge.call(name,...args) → Rust async handler → TSFN 投到主线程 → 本文件
 *      handleHostCall(name, inputJson, replyId) → qjs.resolveBridgeCallback / rejectBridgeCallback。
 * 口径：
 *  - inputJson = JSON.stringify([runtimeName, ...args])（上游 register_function 逐字语义）。
 *  - 回包是字符串；Rust 原样包成 Value::String，空串 ⇒ Null。
 *  - dart.getAppVersion → JSON.stringify(version)；dart.getLocaleInfo → 八字段 JSON；
 *    flutter.showToast → ""；save/load_plugin_config → '{"ok":true[,"value":<json>]}'。
 * 要求3（2026-11-11 真机回传）：登录态持久化通道 = 插件自己调 save_plugin_config 落盘、
 *    下次启动 load_plugin_config 读回。这两条按上游 plugin_config_bridge.dart 的
 *    onSavePluginConfig/onLoadPluginConfig 语义对齐（写入 _decodeMaybeJson、读出带类型、
 *    fallback 同样 _decodeMaybeJson），并把调用次数打进诊断，便于真机确认「插件真的调了」。
 *  - 二进制参数（__hostProtocol:"bridge-binary-v1"）：5 个路由都不收，save 直接报错，其余忽略当不透明对象。
 * 依赖：@kit.ArkData preferences（配置持久化 plugin_config）、@kit.AbilityKit bundleManager（版本号）、
 *      @kit.LocalizationKit i18n（locale/时区，ArkTS 无 Intl 需自行组装）、@kit.ArkUI promptAction。
 */
import { common, bundleManager } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { promptAction } from '@kit.ArkUI';
import { i18n } from '@kit.LocalizationKit';
import { jstr, jnum, jhas } from './JsonUtil';
import { Logger } from './Logger';
import { HostCallback } from './PluginRuntime';

/** 宿主回调注册所需的最小原生表面（registerAll 收适配器对象，回包也经它走；属性形态便于对象字面量实现）。 */
export interface HostRegistrar {
  registerHostCallback: (name: string, fn: HostCallback) => boolean;
  resolveBridgeCallback: (id: number, resultJson: string) => boolean;
  rejectBridgeCallback: (id: number, message: string) => boolean;
}

/** preferences 存储名（ABI §4-5：跨重启持久化用 preferences）。 */
const PREF_NAME: string = 'plugin_config';
/** bundleManager 取不到版本号时的兜底（与 AppScope/app.json5 一致）。 */
const FALLBACK_VERSION: string = '3.0.37';
/** ABI §2 的 5 个路由名（逐字对齐上游，一个都不能差）。 */
const HOST_ROUTES: string[] = [
  'dart.getAppVersion',
  'dart.getLocaleInfo',
  'flutter.showToast',
  'save_plugin_config',
  'load_plugin_config'
];

/** dart.getLocaleInfo 八字段（ABI §2 口径；除 timezoneOffsetMinutes 外全部字符串）。 */
class LocaleInfo {
  language: string = '';
  locale: string = '';
  systemLocale: string = '';
  timezoneOffset: string = '+00:00';
  timezoneOffsetMinutes: number = 0;
  timezoneName: string = '';
  timeZone: string = '';
  timeZoneIANA: string = '';
}

export class BreezeHost {
  private static context: common.Context | null = null;
  private static registrar: HostRegistrar | null = null;
  private static registered: boolean = false;
  private static prefsInstance: preferences.Preferences | null = null;
  private static prefsPromise: Promise<preferences.Preferences> | null = null;
  private static versionName: string = FALLBACK_VERSION;
  private static versionLoaded: boolean = false;
  /** 要求3 取证：save/load_plugin_config 各自被插件调过多少次（0 ⇒ 该插件根本没用持久化通道）。 */
  private static cfgSaveCalls: number = 0;
  private static cfgLoadCalls: number = 0;
  private static cfgLastError: string = '';

  /** preferences 等需要 context 的 API 使用前必须先 init（可重复调用）。 */
  static init(context: common.Context): void {
    BreezeHost.context = context;
  }

  /** 注册全部 5 个路由；幂等：重复调用不会重复注册（同名注册在 Rust 侧是替换，双保险）。 */
  static registerAll(qjs: HostRegistrar): void {
    BreezeHost.registrar = qjs;
    if (BreezeHost.registered) {
      return;
    }
    for (let i = 0; i < HOST_ROUTES.length; i++) {
      const routeName: string = HOST_ROUTES[i];
      const cb: HostCallback = (inputJson: string, replyId: number): void => {
        BreezeHost.handleHostCall(routeName, inputJson, replyId);
      };
      qjs.registerHostCallback(routeName, cb);
    }
    BreezeHost.registered = true;
    Logger.i('BreezeHost: 5 个宿主路由已注册');
  }

  static isRegistered(): boolean {
    return BreezeHost.registered;
  }

  /**
   * 统一入口（TSFN 回调体，必须同步返回）：异步干活后 **必须** 回包 ——
   * 成功 resolveBridgeCallback(replyId, resultString)，异常 rejectBridgeCallback(replyId, msg)。
   * 不回包 ⇒ 插件侧 15s 超时抛 [BRIDGE_CALL_FAILED]。
   */
  static handleHostCall(name: string, inputJson: string, replyId: number): void {
    BreezeHost.dispatch(name, inputJson)
      .then((result: string): void => {
        const reg = BreezeHost.registrar;
        if (reg === null) {
          return;
        }
        const ok: boolean = reg.resolveBridgeCallback(replyId, result);
        if (!ok) {
          // 常见于 15s 超时后宿主才回包：Rust 侧 handle 已 drop，属可观测丢包，记录不抛。
          Logger.w('BreezeHost: resolve 丢包(可能已超时) route=' + name + ' id=' + replyId);
        }
      })
      .catch((e: Object): void => {
        const msg: string = (e as Error).message ?? String(e);
        Logger.e('BreezeHost: route=' + name + ' 失败: ' + msg);
        const reg = BreezeHost.registrar;
        if (reg !== null) {
          reg.rejectBridgeCallback(replyId, msg);
        }
      });
  }

  // ------------------------------------------------------------ 路由分发

  private static async dispatch(name: string, inputJson: string): Promise<string> {
    let parsed: ESObject;
    try {
      parsed = JSON.parse(inputJson);
    } catch (e) {
      throw new Error('host route "' + name + '" got invalid inputJson: ' + ((e as Error).message ?? String(e)));
    }
    if (!Array.isArray(parsed)) {
      throw new Error('host route "' + name + '": inputJson must be a JSON array');
    }
    const args: ESObject[] = parsed as ESObject[];

    if (name === 'dart.getAppVersion') {
      const v: string = await BreezeHost.appVersion();
      return JSON.stringify(v);
    }
    if (name === 'dart.getLocaleInfo') {
      return JSON.stringify(BreezeHost.localeInfo());
    }
    if (name === 'flutter.showToast') {
      BreezeHost.showToast(args);
      return '';
    }
    if (name === 'save_plugin_config') {
      await BreezeHost.saveConfig(args);
      return '{"ok":true}';
    }
    if (name === 'load_plugin_config') {
      return await BreezeHost.loadConfig(args);
    }
    throw new Error('no host route registered: ' + name);
  }

  // ------------------------------------------------------------ dart.getAppVersion

  /** C13 起对外可用（我的页版本行显示/点按用）；内部 dart.getAppVersion 路由同用此方法。 */
  static async appVersion(): Promise<string> {
    if (BreezeHost.versionLoaded) {
      return BreezeHost.versionName;
    }
    try {
      const info: bundleManager.BundleInfo =
        await bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      const vn: string = info.versionName ?? '';
      BreezeHost.versionName = vn.length > 0 ? vn : FALLBACK_VERSION;
    } catch (e) {
      Logger.w('bundleManager 取版本号失败，用兜底 ' + FALLBACK_VERSION + ': ' + ((e as Error).message ?? String(e)));
      BreezeHost.versionName = FALLBACK_VERSION;
    }
    BreezeHost.versionLoaded = true;
    return BreezeHost.versionName;
  }

  // ------------------------------------------------------------ dart.getLocaleInfo

  /** 分钟偏移 → "+08:00"。注意 JS getTimezoneOffset 符号相反（东八区给 -480），这里已取反。 */
  private static formatOffset(minutes: number): string {
    const sign: string = minutes >= 0 ? '+' : '-';
    const abs: number = Math.abs(minutes);
    const hh: number = Math.floor(abs / 60);
    const mm: number = abs % 60;
    const h: string = hh < 10 ? '0' + hh.toString() : hh.toString();
    const m: string = mm < 10 ? '0' + mm.toString() : mm.toString();
    return sign + h + ':' + m;
  }

  private static localeInfo(): LocaleInfo {
    const info: LocaleInfo = new LocaleInfo();
    // getSystemLanguage 返回如 "zh-Hans-CN"/"zh-CN"，语言码取第一段。
    const rawLang: string = BreezeHost.safeCall((): string => i18n.System.getSystemLanguage(), '');
    const parts: string[] = rawLang.split(/[-_]/);
    info.language = parts.length > 0 ? parts[0] : '';
    const region: string = BreezeHost.safeCall((): string => i18n.System.getSystemRegion(), '');
    info.locale = region.length > 0 && info.language.length > 0 ? info.language + '-' + region : rawLang;
    info.systemLocale = BreezeHost.safeCall((): string => i18n.System.getSystemLocale(), rawLang);
    const tzId: string = BreezeHost.safeCall((): string => i18n.getTimeZone().getID(), '');
    info.timezoneName = tzId;
    info.timeZone = tzId;
    info.timeZoneIANA = tzId;
    info.timezoneOffsetMinutes = -new Date().getTimezoneOffset();
    info.timezoneOffset = BreezeHost.formatOffset(info.timezoneOffsetMinutes);
    return info;
  }

  /** i18n 单点兜底：任一 API 抛错不至于带崩整个八字段回包。 */
  private static safeCall(fn: () => string, def: string): string {
    try {
      const v: string = fn();
      return v ?? def;
    } catch (e) {
      Logger.w('i18n 调用失败: ' + ((e as Error).message ?? String(e)));
      return def;
    }
  }

  /**
   * 展示名探针（面板 hostBridge 行顺带显示）：验证 getDisplayLanguage/getDisplayCountry 可用。
   * 不进八字段 —— ABI §2 规定回包 keys 恰好 8 个，多一个都会破坏 bundle 侧 keys===8 断言。
   */
  static displayHint(): string {
    try {
      const rawLang: string = i18n.System.getSystemLanguage();
      const lang: string = rawLang.split(/[-_]/)[0];
      const sysLocale: string = i18n.System.getSystemLocale();
      const region: string = i18n.System.getSystemRegion();
      const dl: string = i18n.System.getDisplayLanguage(lang, sysLocale);
      const dc: string = region.length > 0 ? i18n.System.getDisplayCountry(region, sysLocale) : '';
      return dl + '/' + dc;
    } catch (e) {
      return '?';
    }
  }

  // ------------------------------------------------------------ flutter.showToast

  /**
   * flutter.showToast 兼容两种调用形态：
   *  A. 上游 ABI §2 形态：args[1] = {message,title?,level?,seconds?}（对象）。
   *  B. 我方 v0.0.2 载荷形态：args[1] = 字符串 message，args[2] = {duration|seconds?,level?}。
   * 真实上游 Flutter 桥两种都有先例，宿主侧宽容接，两种都弹真 toast（真机可见证据）。
   */
  private static showToast(args: ESObject[]): void {
    const a1: ESObject = args.length > 1 ? args[1] : null;
    const a2: ESObject = args.length > 2 ? args[2] : null;
    let message: string = '';
    let level: string = '';
    let seconds: number = 2;
    if (typeof a1 === 'string') {
      // 形态 B：字符串消息 + 可选第二参数选项。
      message = a1 as string;
      if (a2 !== null && a2 !== undefined && typeof a2 === 'object') {
        level = jstr(a2, 'level', '');
        seconds = jnum(a2, 'duration', jnum(a2, 'seconds', 2));
      }
    } else if (a1 !== null && a1 !== undefined && typeof a1 === 'object') {
      // 形态 A：ABI §2 options 对象。
      message = jstr(a1, 'message', '');
      if (message.length === 0) {
        message = jstr(a1, 'title', '');
      }
      level = jstr(a1, 'level', '');
      seconds = jnum(a1, 'seconds', 2);
    } else {
      throw new Error('flutter.showToast: args[1] must be options object or message string');
    }
    if (level === 'error') {
      message = '[ERROR] ' + message;
    }
    if (message.length === 0) {
      throw new Error('flutter.showToast: message/title both empty');
    }
    // seconds（上游 Flutter 语义，秒）→ duration 毫秒，钳到 [0.5s, 30s]。
    let dur: number = Math.round(seconds * 1000);
    if (dur < 500) {
      dur = 500;
    }
    if (dur > 30000) {
      dur = 30000;
    }
    const opts: promptAction.ShowToastOptions = { message: message, duration: dur };
    promptAction.showToast(opts);
  }

  // ------------------------------------------------------------ save/load_plugin_config

  /**
   * 上游 `_decodeMaybeJson`（plugin_config_bridge.dart:70-81）：能解析成 JSON 的字符串按 JSON 存，
   * 否则原样当字符串。插件把登录态（cookie/token/用户信息）整包 JSON.stringify 后写进来，
   * 就靠这一步落成**结构化对象**，下次 load 才能带类型读回。
   * ⚠ 有意偏差（真机实证，别放宽）：**只对 { 与 [ 开头的值试解析**。上游是无条件 jsonDecode，
   *   那会把开关项的 'true'/'false' 变成布尔；而 MangaDex 类插件的取值器写的是 String(v) 与
   *   'true'/'false' 比字符串（见 data/source/PluginSettings.ets:24 同一坑的记载）⇒ 放宽会退回
   *   「开关看着没生效」这个老缺陷。数字字符串（如超时秒数）同理保持原样。
   */
  private static decodeMaybeJson(v: ESObject): ESObject {
    if (typeof v !== 'string') {
      return v;
    }
    const s: string = (v as string).trim();
    if (s.length < 2) {
      return v;
    }
    const c0: string = s.charAt(0);
    const c1: string = s.charAt(s.length - 1);
    if (!((c0 === '{' && c1 === '}') || (c0 === '[' && c1 === ']'))) {
      // s12 第 1/3 条：**只额外放行「成对双引号且能 parse 成字符串」这一种形态**。
      // 真插件写标量凭据一律是 save_plugin_config(key, JSON.stringify(值))（jmComic bundle 偏移 54959、
      // bikaComic 偏移 74385 实测）⇒ 落盘形态正是带引号的 JSON 字符串字面量；上游 Dart 侧
      // plugin_config_bridge.dart:70-81 无条件 jsonDecode 会把引号还原掉，我方旧实现不还原 ⇒
      // 插件拿回的账号名与 token 都是带引号的字符串（引号是内容的一部分）：哔咔把它塞进请求头
      // （bundle 偏移 46721）⇒ 401 ⇒ getUserInfoBundle 抛 + 云收藏回 unauthorized。
      // 仍然**不放行**裸 true/false/数字（开关项按字符串比的老缺陷，见上面的 ⚠ 注释）。
      const un: string | null = BreezeHost.unwrapJsonStringLiteral(s);
      return un === null ? v : un;
    }
    try {
      const parsed: ESObject = JSON.parse(s) as ESObject;
      if (parsed !== null && parsed !== undefined && typeof parsed === 'object') {
        return parsed;
      }
    } catch (e) {
      // 形似 JSON 但解析失败 ⇒ 原样存字符串（上游同样是 catch 后返回原文）
    }
    return v;
  }

  /**
   * 拆「JSON 字符串字面量」：首尾成对双引号且 JSON.parse 出的是**字符串** ⇒ 返回内容，否则 null。
   * 只认这一种形态是有意的（s12 定案）：上游无条件 jsonDecode 连 'true'/'12' 也会洗掉类型，
   *  MangaDex 类插件的取值器写 String(v) 与 'true' 比字符串 ⇒ 放宽会退回「开关看着没生效」；
   *  而凭据/账号名这条真链路落盘形态恰好只有「带引号的字符串字面量」这一种，放行它就够。
   */
  private static unwrapJsonStringLiteral(s: string): string | null {
    const t: string = s.trim();
    if (t.length < 2 || t.charAt(0) !== '"' || t.charAt(t.length - 1) !== '"') {
      return null;
    }
    try {
      const p: ESObject = JSON.parse(t) as ESObject;
      if (typeof p === 'string') {
        return p as string;
      }
    } catch (e) {
      // 首尾是引号但不是合法字面量（值里本来就带引号）⇒ 原样，绝不猜
    }
    return null;
  }

  /**
   * 读桶时**幂等归一**存量脏值（s12 第 1/3 条的第二半，缺它则真机升级后仍坏）：
   * 脏值是上一版 decodeMaybeJson 不收引号时写进去的（bucket 里存着带引号的字符串），
   * 只修写入侧 = 老用户必须重登一次才好。这里在**读**的出口按同一条判据还原 ⇒
   * 老库无需迁移立刻可鉴权；下一次 saveConfig 会把归一后的桶整体写回，自然就干净了。
   * 只做一层、只动字符串值：对象/数组/数字/布尔一律原样（对象是当年 {} 分支正常解出来的）。
   */
  private static healBucket(obj: ESObject): ESObject {
    const keys: string[] = Object.keys(obj);
    for (let i = 0; i < keys.length; i++) {
      const v: ESObject = obj[keys[i]];
      if (typeof v === 'string') {
        const un: string | null = BreezeHost.unwrapJsonStringLiteral(v as string);
        if (un !== null) {
          obj[keys[i]] = un;
        }
      }
    }
    return obj;
  }

  /**
   * 上游 onSavePluginConfig 的 value 是 Dart dynamic（任意类型都收）；我方旧实现只收字符串，
   * 插件直接递对象会被 reject ⇒ 登录态根本没落盘。这里统一成「字符串原样、其它类型 JSON 化」，
   * 再交给 decodeMaybeJson 还原结构，效果与上游一致且不会丢内容。
   */
  private static normalizeConfigValue(v: ESObject): string {
    if (typeof v === 'string') {
      return v as string;
    }
    if (v === null || v === undefined) {
      return '';
    }
    try {
      return JSON.stringify(v) ?? String(v);
    } catch (e) {
      return String(v);
    }
  }

  /** 诊断面板用短串：cfg=存/读次数（+最近一次失败原因），能一眼区分「插件没调」与「宿主存失败」。 */
  static configHint(): string {
    const tail: string = BreezeHost.cfgLastError.length > 0 ? (' err=' + BreezeHost.cfgLastError) : '';
    return 'cfg=' + BreezeHost.cfgSaveCalls + '/' + BreezeHost.cfgLoadCalls + tail;
  }

  /** preferences(plugin_config) 单例：getPreferences 只跑一次，并发共享 Promise。 */
  private static async prefs(): Promise<preferences.Preferences> {
    const existing = BreezeHost.prefsInstance;
    if (existing !== null) {
      return existing;
    }
    if (BreezeHost.prefsPromise === null) {
      const ctx = BreezeHost.context;
      if (ctx === null) {
        throw new Error('BreezeHost.init(context) must be called before config routes');
      }
      const options: preferences.Options = { name: PREF_NAME };
      BreezeHost.prefsPromise = preferences.getPreferences(ctx, options);
    }
    const p: preferences.Preferences = await BreezeHost.prefsPromise;
    BreezeHost.prefsInstance = p;
    return p;
  }

  private static strOr(v: ESObject, def: string): string {
    if (v === null || v === undefined) {
      return def;
    }
    if (typeof v === 'string') {
      return v as string;
    }
    return def;
  }

  /** 读 runtime 桶（args[0]=runtime 名 ⇒ 一个桶一个 {key:value} JSON）。 */
  private static async readBucket(p: preferences.Preferences, runtime: string): Promise<ESObject> {
    const raw: string = String(p.getSync(runtime, '{}'));
    try {
      const obj: ESObject = JSON.parse(raw);
      if (obj !== null && obj !== undefined && typeof obj === 'object' && !Array.isArray(obj)) {
        return BreezeHost.healBucket(obj);
      }
    } catch (e) {
      Logger.w('plugin_config 桶 ' + runtime + ' 内容非法，重建空桶');
    }
    return JSON.parse('{}');
  }

  /**
   * save_plugin_config [runtime, key, value]：value 任意类型都收（上游 Dart dynamic 语义），
   * JSON 形状的值解码后落盘 ⇒ 与 onLoadPluginConfig 的带类型读回成对。
   */
  private static async saveConfig(args: ESObject[]): Promise<void> {
    BreezeHost.cfgSaveCalls++;
    const runtime: string = BreezeHost.strOr(args.length > 0 ? args[0] : null, '_unknown');
    const key: string = BreezeHost.strOr(args.length > 1 ? args[1] : null, '');
    if (key.length === 0) {
      BreezeHost.cfgLastError = 'empty-key';
      throw new Error('save_plugin_config: key must be a non-empty string');
    }
    const value: ESObject = args.length > 2 ? args[2] : null;
    const raw: string = BreezeHost.normalizeConfigValue(value);
    const p: preferences.Preferences = await BreezeHost.prefs();
    const bucket: ESObject = await BreezeHost.readBucket(p, runtime);
    bucket[key] = BreezeHost.decodeMaybeJson(raw);
    await p.put(runtime, JSON.stringify(bucket));
    await p.flush();
    Logger.i('save_plugin_config 落盘 runtime=' + runtime + ' key=' + key + ' len=' + raw.length);
  }

  /**
   * load_plugin_config [runtime, key, fallback]：
   * key 空 ⇒ 返回整个 config 桶；否则返回该项，缺失回 fallback。
   * 回包 '{"ok":true,"value":<json>}'，value 是 JSON 原文（字符串带引号、null 就是 null）。
   */
  private static async loadConfig(args: ESObject[]): Promise<string> {
    const runtime: string = BreezeHost.strOr(args.length > 0 ? args[0] : null, '_unknown');
    const key: string = BreezeHost.strOr(args.length > 1 ? args[1] : null, '');
    const fallback: ESObject = args.length > 2 ? args[2] : null;
    const p: preferences.Preferences = await BreezeHost.prefs();
    const bucket: ESObject = await BreezeHost.readBucket(p, runtime);

    BreezeHost.cfgLoadCalls++;
    let valueJson: string;
    if (key.length === 0) {
      // 上游 key 为空 ⇒ 整个 config map（信封里就是 JSON 对象，与旧实现同形）
      valueJson = JSON.stringify(bucket);
    } else if (jhas(bucket, key)) {
      valueJson = JSON.stringify(bucket[key]);
    } else {
      // 上游 onLoadPluginConfig:47 的兜底也走 _decodeMaybeJson ⇒ 插件传 {} 兜底时不该拿到 null
      const fb: ESObject = (fallback === null || fallback === undefined) ? null : BreezeHost.decodeMaybeJson(fallback);
      valueJson = JSON.stringify(fb);
    }
    return '{"ok":true,"value":' + valueJson + '}';
  }
}
