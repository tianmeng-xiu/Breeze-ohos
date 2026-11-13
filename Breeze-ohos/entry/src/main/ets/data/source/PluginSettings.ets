/**
 * 职责：插件「设置 / 能力」的宿主侧读取与写回（需求①，用户 m05426 + 上游截图那一屏）。
 * 对应 Flutter：Breeze/lib/page/plugin_settings/cubit/plugin_settings_cubit.dart（契约权威）
 *              Breeze/lib/page/plugin_settings/widgets/plugin_settings_content.dart（版式权威）
 *              Breeze/lib/plugin/bridge/plugin_config_bridge.dart（配置桶读写权威）
 *
 * ---- 插件侧契约（★ 入参不是空数组：上游 payload = {...core, extern}，见下）----
 *  上游 unified_comic_plugin.dart:28 把 core 与 extern 合成**一个对象**，再经 Rust
 *  parse_args_array（Breeze/rust/src/qjs/mod.rs:865-873：非数组一律裹成单元素数组）
 *  ⇒ 插件永远收到**恰好一个对象参数且必带 extern 键**。所以本文件调 bundle 时传
 *  `[{extern:{}}]`（core 为空的那些）或 `[{key,value,extern:{}}]`（写值），绝不传 '[]'。
 *  getSettingsBundle      ⇒ scheme.sections = [{id,title,fields:[{key,kind,label,options:[{label,value}]}]}]
 *                           data.values     = { key: 值 }（插件侧的值一律是字符串，见下）
 *                           data.canShowUserInfo / canLogin / loginTitle / loginSubtitle / canShowDetail
 *  getCapabilitiesBundle  ⇒ scheme.actions  = [{title,fnPath}]（宿主过滤掉 fnPath==='dumpRuntimeInfo'）
 *  getUserInfoBundle      ⇒ data 整体 = 用户信息（键任意，常见 userName/name/vip/message）
 *  getLoginBundle         ⇒ 存在即视为「支持登录」（上游也是这么试探的）
 *
 * ---- 写回口径（照抄上游 _commitField，两处都要落，缺一不可）----
 *  1) field.fnPath 非空 ⇒ 先调插件自己的 setter（如 MangaDex 的 onSettingChanged({key,value})）；
 *  2) 再写宿主配置桶（等价上游 savePluginConfigValue = onSavePluginConfig(name, key, jsonEncode(value))）：
 *     与插件内部读写配置走的是同一个 preferences(plugin_config) 桶，插件下次 getSettingsBundle 的
 *     load_plugin_config 才读得到新值。
 *  ⚠ 值一律转成字符串再落桶：真机 MangaDex 的取值器是 String(v) 比 'true'/'false'，
 *    存成 boolean 会让下次读取判不相等 ⇒ 开关看着没生效。
 *
 * 本文件所有公开方法都不抛（页面直接 await，失败以返回值/错误串呈现）。
 * 依据系统 Kit：@kit.ArkData preferences（与 util/BreezeHost.ets 共用 PREF_NAME='plugin_config'）。
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { bundleCall, bundleLoadFromPath, bundleList } from '../../util/PluginRuntime';
import { jparse, jstr, jobj, jarr, jisEmpty, jhas } from '../../util/JsonUtil';
import { PluginStore } from '../../util/PluginStore';
import { Logger } from '../../util/Logger';

/**
 * 调用形态分三类，别一把梭（都有上游实证）：
 *  ① 插件契约面 ⇒ 上游 unified_comic_plugin.dart:28 把 core 与 extern 合成**一个对象**再经
 *     Rust parse_args_array（Breeze/rust/src/qjs/mod.rs:865-873：非数组裹成单元素数组），
 *     所以插件永远收到**恰好一个对象参数且必带 extern 键** ⇒ 本文件用 ARGS_EMPTY / 带 key,value 的对象。
 *  ② getInfo ⇒ plugin_registry_service.dart:269 走 qjsTaskCall 且 argsJson 恒 '{}'（**不拼 payload**）
 *     ⇒ 插件收到一个空对象、不带 extern ⇒ 调用点写 '[{}]'。
 *  ③ plugin_mgr 宿主自有载荷（fetchIndex/checkUpdates/installLatest）⇒ 签名是位置参数，
 *     rawfile 那份源码按 args[0] 取值，注入对象会喂成非法入参 ⇒ 保持原样，**不要**加 extern。
 */
/** 上游 callUnifiedComicPlugin 的空 core + 空 extern ⇒ 单对象 [{extern:{}}]。 */
const ARGS_EMPTY: string = '[{"extern":{}}]';

/** 与 util/BreezeHost.ets:30 逐字一致 —— 换名等于换桶，插件就读不到宿主写的值了。 */
const PREF_NAME: string = 'plugin_config';
// 原 s7a 的 HIDDEN_ACTION='clearPluginSession' 已放开（缺陷③登录页落地）。
// 「跑完这条 action 就跳登录页」的判定挪到 pages/PluginSettingsPage.ets 的 runAction（上游
// view/plugin_settings_page.dart:729 同口径），本文件不再过滤它。

/**
 * 登出用的 fnPath（要求6，2026-11-12）。**唯一权威常量**：页面侧（能力组跳登录页的判定 +
 * 用户信息卡那行「退出登录」）与本文件的 PluginSettings.logout 都引它，不再各写字面量。
 * 只有**自报了这个动作**的插件才谈得上登出 —— 它来自 getCapabilitiesBundle 的 actions，
 * 没实现登录的插件压根不会有这条，页面据此不显示登出入口（不硬编码支持某个插件）。
 */
export const LOGOUT_FN: string = 'clearPluginSession';

/**
 * getInfo 可能自发网络请求（真机上一半的插件 getInfo 会打自家站点），本地要有上限但不能太紧：
 *  s7b 的 3.5s 是照抄插件管理页 loadRow 的口径，那个场景在列表里、必须快；
 *  而设置页只有这一个插件在跑，等得起。真机「版本一直未知」的主因就是 3.5s 把慢网下的
 *  正常 getInfo 掐死（BUG4），这里放宽到 8s。超时**不等于失败终止**：
 *  插件版本() 的 catch 分支仍会去读持久化缓存，见该方法注释。
 */
const INFO_TIMEOUT_MS: number = 8000;

/** 选项（choice 字段的候选项）。 */
export class SettingOption {
  label: string = '';
  value: string = '';
}

/** 一个设置项。kind 取值（上游 content.dart:364-373）：switch / select|choice / multiChoice / text / password。 */
export class SettingField {
  key: string = '';
  kind: string = 'text';
  label: string = '';
  /** 上游契约：字段可自带 setter fnPath，非空 ⇒ 写值时先调它。 */
  fnPath: string = '';
  /** 上游 field.persist !== false 才落桶。 */
  persist: boolean = true;
  options: SettingOption[] = [];
}

/** 一个分组卡片。 */
export class SettingSection {
  id: string = '';
  title: string = '';
  fields: SettingField[] = [];
}

/** 能力动作（getCapabilitiesBundle）。 */
export class CapabilityAction {
  title: string = '';
  fnPath: string = '';
}

/**
 * 登出结果（要求6）。**必须带 ok**：runAction 返回的是 toast 文案串，失败也只是一句
 * 「执行失败：xxx」，调用方拿它无法判成败；而登出要「成功才刷新回登录态、失败给原因」，
 * 所以单独给一个真成败出口，文案仍复用它（msg 成功=插件回的 message，失败=带原因的串）。
 */
export class LogoutResult {
  ok: boolean = false;
  msg: string = '';
}

/** getSettingsBundle + getCapabilitiesBundle + getUserInfoBundle 的聚合结果。 */
export class PluginSettingsBundle {
  sections: SettingSection[] = [];
  actions: CapabilityAction[] = [];
  /** key → 当前值（字符串；上游 UI 按 kind 各自解释）。 */
  values: Map<string, string> = new Map<string, string>();
  canShowUserInfo: boolean = false;
  canLogin: boolean = false;
  loginTitle: string = '';
  loginSubtitle: string = '';
  canShowDetail: boolean = false;
  userInfo: Map<string, string> = new Map<string, string>();
  /** 空串 = 没错误；非空 = 整页错误态文案（含可重试提示）。 */
  error: string = '';
  /** getSettingsBundle 是否可用（false ⇒ 该插件不提供设置，页面只渲染宿主管理区）。 */
  hasSettings: boolean = false;
}

/**
 * pages/PluginSettingsPage 的路由参数（与 view/reader/ReaderParams.ets 同一口径：
 * router.pushUrl 传实例，页面侧 instanceof 取回；故类必须导出给 PluginManagerView 复用）。
 */
export class PluginSettingsParams {
  /** 引擎内装载名（已装载行 = row.uuid；未装载行 = deriveLocalUuid(localFile)）。 */
  uuid: string = '';
  /** 显示名（清单/桶里的名字，插件 getInfo.name 到了页面再覆盖）。 */
  name: string = '';
  /** 相对 filesDir/plugins 的文件名（拼绝对路径 + 删除 + 重新装载都要它）。 */
  localFile: string = '';

  constructor(uuid: string = '', name: string = '', localFile: string = '') {
    this.uuid = uuid;
    this.name = name;
    this.localFile = localFile;
  }
}

/**
 * 一次 getInfo 的结果（BUG4）。
 * ArkTS 禁对象字面量 ⇒ 必须 new 已声明类再逐字段赋值，因此单独声明；
 * ok=false 表示「这次没调通」，此时 version/name 是上一次落盘缓存的值（可能为空）。
 */
export class PluginInfo {
  ok: boolean = false;
  version: string = '';
  name: string = '';
}

/** 跑一个 fnPath 的原始返回（含错误串），供 load / commit / runAction 共用。 */
class RawResult {
  ok: boolean = false;
  json: string = '';
  err: string = '';
}

/** 能力动作调用的内部结果：ok 才是真成败（runAction 的字符串返回不足以判成败）。 */
class ActionResult {
  ok: boolean = false;
  msg: string = '';
}

/** 从 unknown 异常提取 message 原文（同 Index.ets:86 已验证写法）。 */
function em(e: Object): string {
  const x = e as Error;
  const m = x.message;
  if (typeof m === 'string' && m.length > 0) {
    return m;
  }
  return String(e);
}

/** 超时包裹（三方 getInfo 会自己发请求，30s 的引擎超时对 UI 太久）。 */
function withTimeout<T>(p: Promise<T>, ms: number, tag: string): Promise<T> {
  return Promise.race([
    p,
    new Promise<T>((_resolve: (v: T) => void, reject: (err: Error) => void): void => {
      setTimeout((): void => {
        reject(new Error(tag + ' timeout ' + ms + 'ms'));
      }, ms);
    })
  ]);
}

/**
 * 值 → 字符串（落桶格式）。
 * 上游落的是 jsonEncode(value)，但**插件侧取值器一律 String(v)**（MangaDex 拿 'true'/'false' 比较），
 * 所以这里对字符串**不再加引号**，对象/数组才用 JSON 原文。
 */
function valueToString(v: ESObject): string {
  if (v === null || v === undefined) {
    return '';
  }
  if (typeof v === 'string') {
    return v as string;
  }
  if (typeof v === 'boolean' || typeof v === 'number') {
    return String(v);
  }
  try {
    return JSON.stringify(v);
  } catch (e) {
    return '';
  }
}

/** 读桶（一个 runtime 一个 {key:value} JSON，逐字对齐 BreezeHost.readBucket）。 */
async function readBucket(prefs: preferences.Preferences, runtime: string): Promise<ESObject> {
  const raw: string = String(prefs.getSync(runtime, '{}'));
  try {
    const obj: ESObject = JSON.parse(raw);
    if (obj !== null && obj !== undefined && typeof obj === 'object' && !Array.isArray(obj)) {
      return obj;
    }
  } catch (e) {
    Logger.w('plugin_config 桶 ' + runtime + ' 内容非法，按空桶处理');
  }
  return JSON.parse('{}');
}

export class PluginSettings {
  private static prefsInstance: preferences.Preferences | null = null;
  private static prefsPromise: Promise<preferences.Preferences> | null = null;

  /** 与 BreezeHost 同一个 preferences 文件；单例共享，互不覆盖（读写都是整桶替换）。 */
  private static async prefs(context: common.Context): Promise<preferences.Preferences> {
    const existing = PluginSettings.prefsInstance;
    if (existing !== null) {
      return existing;
    }
    if (PluginSettings.prefsPromise === null) {
      const options: preferences.Options = { name: PREF_NAME };
      PluginSettings.prefsPromise = preferences.getPreferences(context, options);
    }
    const p: preferences.Preferences = await PluginSettings.prefsPromise;
    PluginSettings.prefsInstance = p;
    return p;
  }

  /**
   * 确保插件在引擎里（设置页可能从「已装载」入口进，也可能被重启后直接进 ⇒ 未装载就按路径装）。
   * 不抛：失败返回错误串给页面。
   */
  static async ensureLoaded(uuid: string, absPath: string): Promise<string> {
    if (uuid.length === 0) {
      return '缺少插件 uuid';
    }
    try {
      const lst: string[] = await bundleList();
      for (let i = 0; i < lst.length; i++) {
        if (lst[i] === uuid) {
          return '';
        }
      }
    } catch (e) {
      // bundleList 失败按未装载处理
    }
    try {
      const ret: string = await bundleLoadFromPath(uuid, absPath);
      if (ret !== 'ok') {
        return '装载插件失败：bundleLoadFromPath 返回 "' + ret + '"';
      }
      Logger.i('插件设置页装载：' + uuid);
      return '';
    } catch (e) {
      return '装载插件失败：' + em(e as Object);
    }
  }

  /**
   * 跑一个「无 core」的 bundle fnPath（getSettingsBundle / getCapabilitiesBundle /
   * getUserInfoBundle / getLoginBundle）。入参形态 = 上游空 core + 空 extern ⇒ [{extern:{}}]。
   * 失败不抛，返回 RawResult。
   */
  private static async raw(uuid: string, fnPath: string): Promise<RawResult> {
    const r = new RawResult();
    try {
      const s: string = await bundleCall(uuid, fnPath, ARGS_EMPTY);
      r.json = s;
      r.ok = true;
    } catch (e) {
      r.err = em(e as Object);
    }
    return r;
  }

  /**
   * 读值表：**宿主桶优先**，缺失的再用插件 getSettingsBundle 给的 values 补。
   * 桶是**平铺**的（`{key: value}`，见 util/BreezeHost.ets:328-343 saveConfig 与上游
   * plugin_config_bridge 的 onSavePluginConfig 都是顶层写键）⇒ 这里绝不能改成子桶，
   * 否则插件自己 load_plugin_config(key) 读不到宿主写的值，设置看着没生效。
   */
  private static async mergeValues(context: common.Context, uuid: string,
    pluginValues: ESObject): Promise<Map<string, string>> {
    const out: Map<string, string> = new Map<string, string>();
    if (pluginValues !== null && pluginValues !== undefined && typeof pluginValues === 'object') {
      const keys: string[] = Object.keys(pluginValues);
      for (let i = 0; i < keys.length; i++) {
        out.set(keys[i], valueToString(pluginValues[keys[i]]));
      }
    }
    try {
      const p: preferences.Preferences = await PluginSettings.prefs(context);
      const bucket: ESObject = await readBucket(p, uuid);
      const bk: string[] = Object.keys(bucket);
      for (let i = 0; i < bk.length; i++) {
        // 插件把整个桶（含 fallback 原样存的键）都写在这里；非字符串项交给 valueToString
        out.set(bk[i], valueToString(bucket[bk[i]]));
      }
    } catch (e) {
      Logger.w('读插件配置桶失败，仅用插件返回值：' + em(e as Object));
    }
    return out;
  }

  /**
   * 全量载入（页面 aboutToAppear 调一次）。
   * 顺序与上游 cubit.load 一致：getSettingsBundle → (getCapabilitiesBundle 静默) → getUserInfoBundle 静默。
   */
  static async load(context: common.Context, uuid: string): Promise<PluginSettingsBundle> {
    const b = new PluginSettingsBundle();
    if (uuid.length === 0) {
      b.error = '缺少插件 uuid';
      return b;
    }
    const setRes: RawResult = await PluginSettings.raw(uuid, 'getSettingsBundle');
    if (!setRes.ok) {
      // 多数插件没实现 getSettingsBundle ⇒ 不是错误，页面只显示宿主管理区
      Logger.i('插件 ' + uuid + ' 无 getSettingsBundle：' + setRes.err);
      b.error = '';
      b.hasSettings = false;
      return b;
    }
    const root: ESObject = jparse(setRes.json);
    if (jisEmpty(root)) {
      b.error = '设置数据解析失败';
      return b;
    }
    b.hasSettings = true;
    const scheme: ESObject = jobj(root, 'scheme');
    const data: ESObject = jobj(root, 'data');

    // 1. sections
    const secs: ESObject[] = jarr(scheme, 'sections');
    for (let i = 0; i < secs.length; i++) {
      const s = new SettingSection();
      s.id = jstr(secs[i], 'id', '');
      s.title = jstr(secs[i], 'title', '');
      const fs: ESObject[] = jarr(secs[i], 'fields');
      for (let k = 0; k < fs.length; k++) {
        const f = new SettingField();
        f.key = jstr(fs[k], 'key', '');
        if (f.key.length === 0) {
          continue;
        }
        const kindRaw: string = jstr(fs[k], 'kind', 'text');
        f.kind = kindRaw.length > 0 ? kindRaw : 'text';
        f.label = jstr(fs[k], 'label', f.key);
        f.fnPath = jstr(fs[k], 'fnPath', '').trim();
        f.persist = true;
        const opts: ESObject[] = jarr(fs[k], 'options');
        for (let m = 0; m < opts.length; m++) {
          const o = new SettingOption();
          // 上游 _normalizeOptions：label 缺失回退 value
          o.label = jstr(opts[m], 'label', jstr(opts[m], 'value', ''));
          o.value = valueToString(opts[m]['value']);
          if (o.label.length === 0) {
            continue;
          }
          f.options.push(o);
        }
        s.fields.push(f);
      }
      if (s.fields.length > 0) {
        b.sections.push(s);
      }
    }

    // 2. data 能力位
    b.canShowUserInfo = String(data['canShowUserInfo']) === 'true';
    b.canLogin = String(data['canLogin']) === 'true';
    b.canShowDetail = String(data['canShowDetail']) === 'true';
    b.loginTitle = jstr(data, 'loginTitle', '');
    b.loginSubtitle = jstr(data, 'loginSubtitle', '');
    // 上游 cubit._resolveLoginSupported 三分支（plugin_settings_cubit.dart:151-173）：
    //   canLogin === true  ⇒ 支持
    //   有该键但非 true    ⇒ 明确不支持，**不再试探**
    //   完全没有该键       ⇒ 试探 getLoginBundle 能否调通
    // 我方 s7a 之前把「有键且为 false」也当成「无键」去试探 ⇒ 插件明确说不支持还会
    // 长出登录入口，点进去只能看「该插件不支持登录」。登录页已落地，这条要按上游收紧。
    if (!b.canLogin && !jhas(data, 'canLogin')) {
      const probe: RawResult = await PluginSettings.raw(uuid, 'getLoginBundle');
      b.canLogin = probe.ok && !jisEmpty(jparse(probe.json));
    }

    // 3. 能力动作（上游整段 try/catch 静默失败）
    const capRes: RawResult = await PluginSettings.raw(uuid, 'getCapabilitiesBundle');
    if (capRes.ok) {
      const cRoot: ESObject = jparse(capRes.json);
      const acts: ESObject[] = jarr(jobj(cRoot, 'scheme'), 'actions');
      for (let i = 0; i < acts.length; i++) {
        const fn: string = jstr(acts[i], 'fnPath', '');
        if (fn.length === 0 || fn === 'dumpRuntimeInfo') {
          continue;
        }
        const a = new CapabilityAction();
        a.title = jstr(acts[i], 'title', fn);
        a.fnPath = fn;
        b.actions.push(a);
      }
    }

    // 4. 用户信息（canShowUserInfo 才拉，失败置空由页面显示占位）
    if (b.canShowUserInfo) {
      const uiRes: RawResult = await PluginSettings.raw(uuid, 'getUserInfoBundle');
      if (uiRes.ok) {
        const ui: ESObject = jobj(jparse(uiRes.json), 'data');
        if (!jisEmpty(ui)) {
          const keys: string[] = Object.keys(ui);
          for (let i = 0; i < keys.length; i++) {
            const v: string = valueToString(ui[keys[i]]);
            if (v.length > 0 && v.length < 200) {
              b.userInfo.set(keys[i], v);
            }
          }
        }
      }
    }

    // 5. 值表：插件给的 values + 宿主桶覆盖
    b.values = await PluginSettings.mergeValues(context, uuid, jobj(data, 'values'));
    return b;
  }

  /**
   * 写一个设置项（上游 _commitField 三步）。返回 '' 成功，否则错误文案。
   * @param value 字符串值（switch 传 'true'/'false'，choice 传选项 value，text 传原文）
   */
  static async commitField(context: common.Context, uuid: string, field: SettingField,
    value: string): Promise<string> {
    if (uuid.length === 0 || field.key.length === 0) {
      return '参数不足';
    }
    // 1) 字段自带 setter ⇒ 先调插件（MangaDex 的 onSettingChanged 就靠这步真正生效）
    //    上游 view/plugin_settings_page.dart:748 core:{key,value} + extern:{} ⇒ 三键同一对象
    if (field.fnPath.length > 0) {
      try {
        await bundleCall(uuid, field.fnPath, '[{"key":' + JSON.stringify(field.key) +
          ',"value":' + JSON.stringify(value) + ',"extern":{}}]');
      } catch (e) {
        Logger.w('插件 setter ' + field.fnPath + ' 失败（仍继续落桶）：' + em(e as Object));
      }
    }
    // 2) 落宿主桶（**平铺键**）。s16 更正：这句原先写「与插件自己 save_plugin_config 写的
    //    完全同一位置」= 错的，实测证伪（_tmp/s16/probe_bucket_key.cjs 逐字复刻两侧函数，
    //    同一份 preferences 桩跑出 keys = breeze-ohos 与 local-JmComic-v0.0.7 两枚并存）。
    //    真实情况 = preferences(plugin_config) 里并存两枚互不可见的桶键：插件自己
    //    save_plugin_config 走 runtime 名桶（util/BreezeHost.ets:479 取 args[0]，runtime 名恒为
    //    breeze_qjs_ohos/src/engine.rs:200 的 breeze-ohos，ENGINE 是 :82 OnceLock 单例），
    //    而这里读写的是 uuid 桶 ⇒ 双向坏：插件写的值设置页永远显示回包 fallback
    //    （mergeValues :316 读不到 runtime 桶），设置页改的值插件下次 load_plugin_config 也读不到
    //    （只有 fnPath / onSettingChanged 在内存里生效，重启回旧值）。并桶修法与「runtime 名是否
    //    拼 bundle 名」必须同批裁（后者破 .so 红线 + 存量登录态失效，待用户拍板）：
    //    先并桶会把跨插件凭据残留放大到设置页。见 _tmp/s16/DEFERRED.md 第 3 项。
    if (field.persist) {
      try {
        const p: preferences.Preferences = await PluginSettings.prefs(context);
        const bucket: ESObject = await readBucket(p, uuid);
        bucket[field.key] = value;
        await p.put(uuid, JSON.stringify(bucket));
        await p.flush();
      } catch (e) {
        return '保存失败：' + em(e as Object);
      }
    }
    // 3) 部分插件（MangaDex 等）的 setter 是 onSettingChanged，值已在桶里；无自带 fnPath 的字段
    //    在这里补一次通用通知，让插件内存态有机会同步（失败忽略，插件多无此导出）。
    if (field.fnPath.length === 0) {
      try {
        await bundleCall(uuid, 'onSettingChanged', '[{"key":' + JSON.stringify(field.key) +
          ',"value":' + JSON.stringify(value) + ',"extern":{}}]');
      } catch (e) {
        Logger.i('插件无 onSettingChanged（忽略）：' + em(e as Object));
      }
    }
    return '';
  }

  /**
   * 跑一个能力动作 fnPath 的**内部唯一实现**：返回真成败 + 可直接展示的文案。
   * 入参形态仍走 ARGS_EMPTY = '[{\"extern\":{}}]'（§24 契约：插件永远收到恰好一个对象且必带 extern）
   * ⇒ 登出与其余能力动作共用这一条，不另开第二条调用路径。
   */
  private static async callAction(uuid: string, fnPath: string,
    title: string): Promise<ActionResult> {
    const r = new ActionResult();
    if (fnPath.length === 0) {
      r.msg = '该操作缺少 fnPath';
      return r;
    }
    try {
      // 上游 _runAction（view/plugin_settings_page.dart:719-720）core:{} + extern:{}
      const raw: string = await bundleCall(uuid, fnPath, ARGS_EMPTY);
      const o: ESObject = jparse(raw);
      const msg: string = jisEmpty(o) ? '' : jstr(o, 'message', '');
      r.ok = true;
      r.msg = msg.length > 0 ? msg : ('已执行：' + title);
    } catch (e) {
      r.msg = '执行失败：' + em(e as Object);
    }
    return r;
  }

  /** 执行能力动作（上游 _runAction：成功优先显示插件回的 message 字段）。返回 toast 文案。 */
  static async runAction(uuid: string, action: CapabilityAction): Promise<string> {
    const r: ActionResult = await PluginSettings.callAction(uuid, action.fnPath, action.title);
    return r.msg;
  }

  /**
   * 登出（要求6）：调插件自报的 clearPluginSession，返回真成败 + 文案。不抛。
   *
   * 两条刻意的**不做**，都在此留档（免得后来人「顺手补全」把用户设置删了）：
   *  ① **不清宿主配置桶**（preferences plugin_config 的 uuid 桶）。桶是**平铺**的，凭据与普通
   *     设置（图源/线路/清晰度偏好）混在同一层（见 mergeValues 注释与 BreezeHost.saveConfig），
   *     宿主无从区分哪些键属于会话 ⇒ 清桶 = 把用户所有设置一起清掉。登出只通知插件，
   *     插件自己爱清哪条清哪条（它调 save_plugin_config 写的键它自己知道）。
   *  ② **不动诊断计数 cfg=save/load**（util/BreezeHost.ets:344-347）。那是**进程内**「插件调用
   *     持久化通道次数」的取证计数，语义是「这个插件有没有在用宿主持久化」，不是配置内容；
   *     登出把它清零等于抹掉取证现场。s8 真机 cfg=0/9 = 该插件 0 次调用宿主持久化通道 ⇒
   *     这类插件的会话根本不在宿主这边，登出对「杀进程后还要不要重登」无能为力，
   *     页面文案也据此**不承诺**「退出后不会自动登录」之类。
   */
  static async logout(uuid: string): Promise<LogoutResult> {
    const out = new LogoutResult();
    if (uuid.length === 0) {
      out.msg = '缺少插件参数';
      return out;
    }
    const r: ActionResult = await PluginSettings.callAction(uuid, LOGOUT_FN, '退出登录');
    out.ok = r.ok;
    out.msg = r.msg;
    return out;
  }

  /**
   * 插件自报版本（getInfo.version，8s 超时）。
   * BUG4 的两条修法都在这里（对齐上游 plugin_registry_service.dart 的两段语义）：
   *  ① 成功 ⇒ PluginStore.saveGetInfo 落一份原文（= 上游 :284 persistGetInfoJson）；
   *  ② 失败/超时 ⇒ 读落盘原文取 version（= 上游 :90-105 getCachedPluginInfo 的 DB 兜底），
   *     不再直接返空串把页面推到「未知」。空串仍可能返回（首次装、从没成功过 getInfo），
   *     那时页面还有清单版本、文件名派生两级兜底（见 PluginSettingsPage.resolveVersionFallback）。
   * 注：只在成功时写缓存 —— 失败绝不能拿空串覆盖上一次的好值。
   */
  static async pluginVersion(context: common.Context, uuid: string): Promise<string> {
    const info: PluginInfo = await PluginSettings.info(context, uuid);
    return info.version;
  }

  /**
   * 读上次落盘的 getInfo 里的 version（不触发调用，纯本地 ⇒ 可秒显）。没有 ⇒ 空串。
   * 冷启动/重进时先用它顶一下 UI，后台 info() 回来再刷新。
   */
  static async cachedVersion(context: common.Context, uuid: string): Promise<string> {
    const info: PluginInfo = await PluginSettings.cachedInfo(context, uuid);
    return info.version;
  }

  /** 同上但把 name 一起给页面（同一份原文，省一次调用）。 */
  static async cachedInfo(context: common.Context, uuid: string): Promise<PluginInfo> {
    return PluginSettings.parseInfo(await PluginStore.readGetInfo(context, uuid));
  }

  /**
   * 调一次 getInfo，成功落盘、失败回退落盘原文（BUG4 唯一的取数入口）。
   * ok=false 表示这次没拿到（超时/抛错），此时 version/name 是**上一次缓存**的值（可能为空）。
   */
  static async info(context: common.Context, uuid: string): Promise<PluginInfo> {
    const out = new PluginInfo();
    if (uuid.length === 0) {
      return out;
    }
    try {
      // getInfo 上游 argsJson 恒 '{}'（plugin_registry_service.dart:269，**不经** payload 拼装）
      // ⇒ Rust parse_args_array 把裸对象裹成 `[{}]`：插件收到一个空对象、不带 extern。
      const raw: string = await withTimeout<string>(bundleCall(uuid, 'getInfo', '[{}]'),
        INFO_TIMEOUT_MS, 'getInfo');
      const parsed: PluginInfo = PluginSettings.parseInfo(raw);
      // 拿到才算成功：jparse 对非法 JSON 回空对象，version/name 全空时不值得落盘
      if (parsed.version.length > 0 || parsed.name.length > 0) {
        out.ok = true;
        out.version = parsed.version;
        out.name = parsed.name;
        await PluginStore.saveGetInfo(context, uuid, raw);
        return out;
      }
      Logger.i('getInfo 回了空内容（视为未取到，用落盘原文）');
    } catch (e) {
      Logger.i('getInfo 取版本失败（用落盘原文）：' + em(e as Object));
    }
    const cached: PluginInfo = await PluginSettings.cachedInfo(context, uuid);
    out.version = cached.version;
    out.name = cached.name;
    return out;
  }

  /** getInfo 原文 → {version,name}；非法 JSON 与缺字段一律空串。 */
  private static parseInfo(raw: string): PluginInfo {
    const out = new PluginInfo();
    if (raw.length === 0) {
      return out;
    }
    const o: ESObject = jparse(raw);
    if (jisEmpty(o)) {
      return out;
    }
    out.version = jstr(o, 'version', '');
    out.name = jstr(o, 'name', '');
    return out;
  }
}
