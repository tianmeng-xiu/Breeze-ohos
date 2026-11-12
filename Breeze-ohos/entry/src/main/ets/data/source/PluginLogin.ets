/**
 * 职责：插件「账号登录」的宿主侧数据层 —— 取登录方案、取验证码图、提交登录、滑块取题/验题。
 * 对应 Flutter（契约权威，逐条对齐，不要凭感觉改）：
 *   Breeze/lib/page/login/login_page.dart              :116 getLoginBundle / :142-232 _applyLoginBundle
 *                                                      :236-276 取验证码图 / :351-419 _submit
 *   Breeze/lib/page/login/slider_captcha_dialog.dart   滑块取题、轨迹采集、验题（541 行整份）
 *   Breeze/lib/network/http/plugin/unified_comic_plugin.dart:32  payload 合并规则
 *
 * ---- 入参口径（★ 与 data/source/PluginSettings.ets 同一族，别混）----
 * 上游 callUnifiedComicPlugin:32 是 `final payload = {...core, 'extern': extern ?? const {}}`，
 * 再经 Rust parse_args_array（非数组裹成单元素数组）⇒ 插件永远收到**恰好一个对象参数且必带 extern**。
 * 本文件所有调用都传 `JSON.stringify(payload)` 外面再包 `[]`，即 '[{...,"extern":{}}]'。
 * （例外只有 getInfo 恒 '[{}]'，那是 PluginSettings.pluginVersion 的事，不在本文件。）
 *
 * ---- 会话保持的真相（UI 与文档都要如实说，别给用户错误预期）----
 * Breeze/rust/src 与 breeze_qjs_ohos/src 里 grep 'cookie' 是 0 命中 ⇒ Rust 侧不管 cookie；
 * 宿主 data/net/CookieJar.ets 只服务宿主 HttpClient。⇒ 插件登录后的会话凭据由**插件 JS 自己在
 * 引擎内存里保管**，杀进程/引擎重载后是否还在取决于插件自己实现（多数插件会掉登录）。
 *
 * ---- 现状（真机验收前必读）----
 * 本仓库自带的三个 rawfile 载荷与 playground fixture **都没有实现 getLoginBundle**
 * （getLoginBundle / captcha-image / slider-captcha / submitFnPath 命中数全 0）
 * ⇒ 真机只能拿用户自装的第三方插件验；没有实现登录的插件必须走「该插件不支持登录」优雅报错，
 *    不能白屏、不能崩。
 *
 * 本文件公开方法一律不抛（页面 await 后看 ok/err）。
 * 依据系统 Kit：@kit.ArkTS（util.Base64Helper）、@kit.ImageKit（image.createImageSource）。
 */
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { bundleCall } from '../../util/PluginRuntime';
import { jparse, jstr, jobj, jarr, jhas, jisEmpty } from '../../util/JsonUtil';
import { Logger } from '../../util/Logger';
import { cleanDisplayValue } from '../../util/DisplayValue';

/** 上游空 core + 空 extern ⇒ 单对象 [{extern:{}}]（与 PluginSettings.ARGS_EMPTY 同值同义）。 */
const ARGS_EMPTY: string = '[{"extern":{}}]';

/** 上游 _extractExceptionText 的三个特征串：命中即「这个插件没做登录」。 */
const UNSUPPORTED_HINTS: string[] = ['getLoginBundle', 'function path not found', 'target is not function'];

/**
 * pages/PluginLoginPage 的路由参数（与 PluginSettingsParams 同一口径：pushUrl 传实例，
 * 页面侧 instanceof 取回 ⇒ 类必须导出给 PluginSettingsPage 复用）。
 */
export class PluginLoginParams {
  uuid: string = '';
  /** 显示名（标题兜底用） */
  name: string = '';
  /** 相对 filesDir/plugins 的文件名（未装载时 ensureLoaded 要它） */
  localFile: string = '';

  constructor(uuid: string = '', name: string = '', localFile: string = '') {
    this.uuid = uuid;
    this.name = name;
    this.localFile = localFile;
  }
}

/** 一个登录表单字段的规约（login_page.dart:142-232 解析结果）。 */
export class LoginField {
  key: string = '';
  label: string = '';
  /** 'text' | 'password' | 'multiline' | 'captcha-image' | 'slider-captcha' | 其它按 text 处理 */
  kind: string = 'text';
  required: boolean = false;
  /** kind==='captcha-image' 时的取图 fnPath */
  captchaFetchFnPath: string = '';
  captchaRefreshText: string = '';
  /** kind==='slider-captcha' 时的两个 fnPath（都非空才算滑块字段） */
  sliderCreateFnPath: string = '';
  sliderVerifyFnPath: string = '';
  sliderRefreshText: string = '';

  isPassword(): boolean {
    return this.kind === 'password';
  }

  isMultiline(): boolean {
    return this.kind === 'multiline';
  }

  isCaptchaImage(): boolean {
    return this.kind === 'captcha-image' && this.captchaFetchFnPath.length > 0;
  }

  isSlider(): boolean {
    return this.kind === 'slider-captcha'
      && this.sliderCreateFnPath.length > 0 && this.sliderVerifyFnPath.length > 0;
  }

  /** 滑块字段不给输入框（上游同口径）；验证码图字段也不给普通输入框以外的额外处理。 */
  showsInput(): boolean {
    return !this.isSlider();
  }
}

/** getLoginBundle 的解析结果。 */
export class LoginScheme {
  title: string = '';
  submitFnPath: string = '';
  submitLabel: string = '';
  fields: LoginField[] = [];
  /** 初值表（上游 values = {...data, ...data.values}），页面按它预填输入框 */
  initial: Map<string, string> = new Map<string, string>();
}

/** 通用结果包：ok=false 时 err 是可直接展示的中文串。 */
export class LoginResult<T> {
  ok: boolean = false;
  err: string = '';
  data: T | null = null;
}

/** 验证码图（解码完成可直接喂 Image 组件）。 */
export class CaptchaImage {
  pixelMap: image.PixelMap | null = null;
}

/** 滑块题目（slider_captcha_dialog.dart 的 SliderChallenge）。 */
export class SliderChallenge {
  token: string = '';
  bg: image.PixelMap | null = null;
  piece: image.PixelMap | null = null;
  /** 原图尺寸（算 scale 用） */
  imageWidth: number = 320;
  imageHeight: number = 180;
  /** 拼图块初始 y 与边长（vp 由页面按 scale 换算） */
  pieceY: number = 0;
  pieceSize: number = 52;
}

function em(e: Object): string {
  if (e instanceof Error) {
    return (e as Error).message;
  }
  if (typeof e === 'string') {
    return e as string;
  }
  try {
    return JSON.stringify(e);
  } catch (x) {
    return 'unknown error';
  }
}

/** 上游 json 取值：字符串才用，且 trim（登录侧插件经常回带空白）。 */
function tstr(o: ESObject, key: string): string {
  const v: string = jstr(o, key, '');
  return v.trim();
}

/**
 * 初值清洗（真机 BUG3：用户名/密码框一进来就带着两个引号字符，要手删才能输）。
 *
 * 规则实现已上移到 util/DisplayValue.ets::cleanDisplayValue —— 同一根因在设置页还有第二现场
 * （pages/PluginSettingsPage.ets 的 valOf：未登录时 auth.account 存的是引号字面量，判不空就
 * 原样上屏显示成两个引号）。两边必须共用一份规则，不许各写一份、更不许谁比谁宽。
 * 这里保留同名薄封装：本文件两处初值循环的调用点、以及「清洗后为空就不写进 initial、
 * 让页面显示 placeholder」的行为完全不变。今后新调用方请直接 import 那个函数。
 */
function cleanInitialValue(raw: string): string {
  return cleanDisplayValue(raw);
}

function numOr(v: ESObject, def: number): number {
  if (typeof v === 'number') {
    return v as number;
  }
  if (typeof v === 'string') {
    const n: number = Number.parseFloat(v as string);
    return Number.isNaN(n) ? def : n;
  }
  return def;
}

/** 上游 callUnifiedComicPlugin 的 payload ⇒ argsJson（必带 extern）。 */
function argsWith(core: ESObject): string {
  const payload: Record<string, ESObject> = {};
  if (core !== null && core !== undefined && typeof core === 'object') {
    const keys: string[] = Object.keys(core);
    for (let i = 0; i < keys.length; i++) {
      payload[keys[i]] = core[keys[i]];
    }
  }
  payload['extern'] = {};
  return '[' + JSON.stringify(payload) + ']';
}

/** 跑一个 fnPath，失败不抛：返回 {ok,json,err}。 */
class RawCall {
  ok: boolean = false;
  json: string = '';
  err: string = '';
}

async function callRaw(uuid: string, fnPath: string, argsJson: string): Promise<RawCall> {
  const r: RawCall = new RawCall();
  if (fnPath.length === 0) {
    r.err = '缺少调用路径';
    return r;
  }
  try {
    const s: string = await bundleCall(uuid, fnPath, argsJson);
    r.json = s;
    r.ok = true;
  } catch (e) {
    r.err = em(e as Object);
  }
  return r;
}

/** 去掉 data:image/…;base64, 前缀 + 去掉所有空白（上游 _decodeImage 同口径）。 */
function stripBase64(src: string): string {
  let s: string = src.trim();
  if (s.startsWith('data:')) {
    const comma: number = s.indexOf(',');
    if (comma > 0 && s.substring(0, comma).indexOf('base64') >= 0) {
      s = s.substring(comma + 1);
    }
  }
  return s.replace(/\s/g, '');
}

/** base64 → PixelMap；失败返回 null（调用方给文案）。 */
async function decodeBase64ToPixelMap(b64: string): Promise<image.PixelMap | null> {
  const clean: string = stripBase64(b64);
  if (clean.length === 0) {
    return null;
  }
  let bytes: Uint8Array;
  try {
    const helper: util.Base64Helper = new util.Base64Helper();
    bytes = helper.decodeSync(clean);
  } catch (e) {
    Logger.ex('base64 解码失败', e as Object);
    return null;
  }
  if (bytes.length === 0) {
    return null;
  }
  // decodeSync 返回的 Uint8Array 可能带 byteOffset ⇒ 用 slice() 拿独立 buffer 再取 ArrayBuffer，
  // 否则 createImageSource 拿到的区间可能不是完整图片字节（同 ImageCache.ets:314-334 的坑位）。
  const copy: Uint8Array = new Uint8Array(bytes);
  let pm: image.PixelMap | null = null;
  let source: image.ImageSource | null = null;
  try {
    source = image.createImageSource(copy.buffer as ArrayBuffer);
    pm = await source.createPixelMap({
      desiredPixelFormat: image.PixelMapFormat.RGBA_8888,
      editable: false
    });
    return pm;
  } catch (e) {
    Logger.ex('验证码图解码失败', e as Object);
    if (pm !== null) {
      try {
        await pm.release();
      } catch (x) {
        // 释放失败无所谓
      }
    }
    return null;
  } finally {
    if (source !== null) {
      try {
        await source.release();
      } catch (x) {
        // 忽略
      }
    }
  }
}

export class PluginLogin {
  /**
   * 取登录方案（getLoginBundle）。三条出口：
   *  ① ok=true ⇒ scheme 可用（fields 至少一项且 submitFnPath 非空）
   *  ② ok=false + err='该插件不支持登录' ⇒ 异常串命中三个特征词，或 fields/submitFnPath 不足
   *  ③ ok=false + 其它 err ⇒ 「读取登录配置失败：…」
   */
  static async fetchScheme(uuid: string): Promise<LoginResult<LoginScheme>> {
    const out: LoginResult<LoginScheme> = new LoginResult<LoginScheme>();
    const raw: RawCall = await callRaw(uuid, 'getLoginBundle', ARGS_EMPTY);
    if (!raw.ok) {
      const hint: string = raw.err;
      for (let i = 0; i < UNSUPPORTED_HINTS.length; i++) {
        if (hint.indexOf(UNSUPPORTED_HINTS[i]) >= 0) {
          out.err = '该插件不支持登录';
          return out;
        }
      }
      out.err = '读取登录配置失败：' + hint;
      return out;
    }
    const root: ESObject = jparse(raw.json);
    if (jisEmpty(root)) {
      out.err = '该插件不支持登录';
      return out;
    }
    const scheme: ESObject = jobj(root, 'scheme');
    const data: ESObject = jobj(root, 'data');

    const s: LoginScheme = new LoginScheme();
    // submitFnPath = scheme.action.fnPath ?? scheme.submitFnPath ?? scheme.fnPath（上游 :150 附近）
    const action: ESObject = jobj(scheme, 'action');
    let submit: string = tstr(action, 'fnPath');
    if (submit.length === 0) {
      submit = tstr(scheme, 'submitFnPath');
    }
    if (submit.length === 0) {
      submit = tstr(scheme, 'fnPath');
    }
    s.submitFnPath = submit;
    let label: string = tstr(action, 'submitText');
    if (label.length === 0) {
      label = tstr(action, 'label');
    }
    if (label.length === 0) {
      label = tstr(scheme, 'submitText');
    }
    s.submitLabel = label.length > 0 ? label : '登录';
    s.title = tstr(scheme, 'title');

    const list: ESObject[] = jarr(scheme, 'fields');
    for (let i = 0; i < list.length; i++) {
      const f: ESObject = list[i];
      const key: string = tstr(f, 'key');
      if (key.length === 0) {
        continue;
      }
      const fd: LoginField = new LoginField();
      fd.key = key;
      const kindRaw: string = tstr(f, 'kind');
      fd.kind = kindRaw.length > 0 ? kindRaw : 'text';
      const lb: string = tstr(f, 'label');
      fd.label = lb.length > 0 ? lb : key;
      fd.required = jhas(f, 'required') ? (f['required'] === true) : false;
      const cap: ESObject = jobj(f, 'captcha');
      fd.captchaFetchFnPath = tstr(cap, 'fetchFnPath');
      fd.captchaRefreshText = tstr(cap, 'refreshText');
      const sl: ESObject = jobj(f, 'slider');
      fd.sliderCreateFnPath = tstr(sl, 'createFnPath');
      fd.sliderVerifyFnPath = tstr(sl, 'verifyFnPath');
      fd.sliderRefreshText = tstr(sl, 'refreshText');
      s.fields.push(fd);
    }
    // 上游同款校验：specs 空或 submitFnPath 空 ⇒ 「字段不足」⇒ 按「不支持登录」呈现
    if (s.fields.length === 0 || s.submitFnPath.length === 0) {
      out.err = '该插件不支持登录';
      return out;
    }
    // 初值：values = {...data, ...data.values}（上游 :210 附近，两层都合并且 data.values 优先）。
    // 每个值都过 cleanInitialValue（BUG3 清洗）：清洗后为空的一律**不写进 initial** ⇒ 页面
    // 拿不到该键、valOf 返回空串 ⇒ 输入框显示 placeholder 而不是引号或空白占位。
    const keys1: string[] = Object.keys(data);
    for (let i = 0; i < keys1.length; i++) {
      const v: ESObject = data[keys1[i]];
      if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
        const cleaned: string = cleanInitialValue(String(v));
        if (cleaned.length > 0) {
          s.initial.set(keys1[i], cleaned);
        }
      }
    }
    const inner: ESObject = jobj(data, 'values');
    const keys2: string[] = Object.keys(inner);
    for (let i = 0; i < keys2.length; i++) {
      const v: ESObject = inner[keys2[i]];
      if (typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean') {
        const cleaned: string = cleanInitialValue(String(v));
        if (cleaned.length > 0) {
          s.initial.set(keys2[i], cleaned);
        }
      }
    }
    out.ok = true;
    out.data = s;
    return out;
  }

  /** 取验证码图（captcha.fetchFnPath，core/extern 都空）。raw = imageBase64 ?? image ?? ''。 */
  static async fetchCaptcha(uuid: string, fetchFnPath: string): Promise<LoginResult<CaptchaImage>> {
    const out: LoginResult<CaptchaImage> = new LoginResult<CaptchaImage>();
    const raw: RawCall = await callRaw(uuid, fetchFnPath, ARGS_EMPTY);
    if (!raw.ok) {
      out.err = '验证码获取失败：' + raw.err;
      return out;
    }
    const o: ESObject = jparse(raw.json);
    let b64: string = tstr(o, 'imageBase64');
    if (b64.length === 0) {
      b64 = tstr(o, 'image');
    }
    const pm: image.PixelMap | null = await decodeBase64ToPixelMap(b64);
    if (pm === null) {
      out.err = '验证码图片为空或格式不支持';
      return out;
    }
    const c: CaptchaImage = new CaptchaImage();
    c.pixelMap = pm;
    out.ok = true;
    out.data = c;
    return out;
  }

  /**
   * 滑块取题（slider.createFnPath）。上游 core = {...values, values}（把整张表单也铺平一层）。
   * 失败文案与上游一一对应：missing slider token / empty slider image / bad slider size。
   */
  static async createSlider(uuid: string, createFnPath: string,
    values: Map<string, string>): Promise<LoginResult<SliderChallenge>> {
    const out: LoginResult<SliderChallenge> = new LoginResult<SliderChallenge>();
    const core: Record<string, ESObject> = {};
    values.forEach((v: string, k: string): void => {
      core[k] = v;
    });
    core['values'] = valuesToRecord(values);
    const raw: RawCall = await callRaw(uuid, createFnPath, argsWith(core));
    if (!raw.ok) {
      out.err = '滑块获取失败：' + raw.err;
      return out;
    }
    const o: ESObject = jparse(raw.json);
    const token: string = tstr(o, 'token');
    if (token.length === 0) {
      out.err = '缺少滑块 token';
      return out;
    }
    const w: number = numOr(o['w'], 320);
    const h: number = numOr(o['h'], 180);
    if (w <= 0 || h <= 0) {
      out.err = '滑块图片尺寸非法';
      return out;
    }
    const bg: image.PixelMap | null = await decodeBase64ToPixelMap(tstr(o, 'bg'));
    if (bg === null) {
      out.err = '滑块底图为空';
      return out;
    }
    const piece: image.PixelMap | null = await decodeBase64ToPixelMap(tstr(o, 'piece'));
    if (piece === null) {
      try {
        await bg.release();
      } catch (x) {
        // 忽略
      }
      out.err = '滑块拼图为空';
      return out;
    }
    const ch: SliderChallenge = new SliderChallenge();
    ch.token = token;
    ch.bg = bg;
    ch.piece = piece;
    ch.imageWidth = w;
    ch.imageHeight = h;
    ch.pieceY = numOr(o['y'], 0);
    ch.pieceSize = numOr(o['s'], 52);
    out.ok = true;
    out.data = ch;
    return out;
  }

  /**
   * 滑块验题（slider.verifyFnPath，core = {token, x, track}）。
   * ok=true 时 data = pass 原文（上游 values[key] = pass，不写死 'true'）；
   * pass 为空串按失败处理（上游同口径），**失败后调用方必须重新取题**（旧 token 已作废）。
   */
  static async verifySlider(uuid: string, verifyFnPath: string, token: string,
    x: number, track: number[][]): Promise<LoginResult<string>> {
    const out: LoginResult<string> = new LoginResult<string>();
    const core: Record<string, ESObject> = {};
    core['token'] = token;
    core['x'] = x;
    core['track'] = track;
    const raw: RawCall = await callRaw(uuid, verifyFnPath, argsWith(core));
    if (!raw.ok) {
      out.err = '滑块校验失败：' + raw.err;
      return out;
    }
    const o: ESObject = jparse(raw.json);
    const pass: string = tstr(o, 'pass');
    // pass 原样带回：上游是 values[key] = pass（不写死 true），插件可能要求回传凭据串
    out.ok = pass.length > 0;
    out.data = pass;
    if (pass.length === 0) {
      out.err = '滑块验证未通过';
    }
    return out;
  }

  /**
   * 提交登录（submitFnPath，core = {...values, values, extern:{}}）。
   * 成功文案 = result.message ?? data.message ?? 「登录成功」（上游 :390 附近）。
   */
  static async submit(uuid: string, submitFnPath: string,
    values: Map<string, string>): Promise<LoginResult<string>> {
    const out: LoginResult<string> = new LoginResult<string>();
    const core: Record<string, ESObject> = {};
    values.forEach((v: string, k: string): void => {
      core[k] = v;
    });
    core['values'] = valuesToRecord(values);
    const raw: RawCall = await callRaw(uuid, submitFnPath, argsWith(core));
    if (!raw.ok) {
      out.err = PluginLogin.normalizeSubmitError(raw.err);
      return out;
    }
    const o: ESObject = jparse(raw.json);
    let msg: string = tstr(o, 'message');
    if (msg.length === 0) {
      msg = tstr(jobj(o, 'data'), 'message');
    }
    if (msg.length === 0) {
      msg = '登录成功';
    }
    out.ok = true;
    out.data = msg;
    return out;
  }

  /** 上游把后端的 'invalid email or password' 归一成中文，其余原样展示。 */
  static normalizeSubmitError(err: string): string {
    if (err.indexOf('invalid email or password') >= 0) {
      return '账号或密码错误';
    }
    return '登录失败：' + err;
  }

  /** 会话保持的实话（登录页底部说明 + 文档同源）。 */
  static sessionNote(): string {
    return '登录态由插件自行保存在引擎内存中，杀进程或引擎重载后可能失效，需要重新登录。';
  }
}

function valuesToRecord(values: Map<string, string>): Record<string, ESObject> {
  const rec: Record<string, ESObject> = {};
  values.forEach((v: string, k: string): void => {
    rec[k] = v;
  });
  return rec;
}
