/**
 * 职责（s37 需求 2，用户 m00774「修改图片报错信息为简短的面向用户的报错」）：
 *   把插件/网络底层的原始错误串洗成「一句人话」上屏，原始全文只进日志。
 *   判据 = pages/PluginLoginPage.ets s15/s16 那条链的**同源拷贝**（:89-152 briefForScreen +
 *   looksTechnical、:283-365 classifyLoginError 的词表与码段、:390-403 errText），
 *   在那套口径上只做四点适配，其余逐字照抄，别在两份之间漂移：
 *   1) 不带 credential 档（登录专用；401 落 refused = 「服务器明确拒绝了这个请求」，比兜底句准，
 *      又不会把断网误报成密码错）；
 *   2) 新增 load 档：宿主 ensureLoaded 抛「<action>：装载插件失败：<原错>」
 *      （data/source/PluginSourceAdapter.ets:218），这类错用户在业务页重试一万次也没用，
 *      必须指向插件管理页；★ s37 红队证伪了「unsupported 之后立刻判它」这条初版设计 ——
 *      装载失败被底层 'not implemented' 抢进 unsupported 档，屏上让用户去换图源，完全没用。
 *      现改为 load **最先**扫（详见下方顺序说明）；
 *   3) unsupported 文案改成面向图源（'该图源不支持此操作，请换一个图源'）；
 *   4) briefForScreen 增加「剥宿主动作壳」第 0 步（s37 补记）—— 适配器给错串套了一层
 *      「<动作>（<函数路径>）：」的壳，不先剥掉就会在括号处把**插件原文**整段砍掉、
 *      只剩内部动作名上屏（详见 briefForScreen 内注释）。★ 这份与 PluginLoginPage 的旧拷贝
 *      在此处**有意分叉**，别再对齐回去。
 * 判定顺序（s37 红队取证后调整）：load 最先 → unsupported → verify → 码段 → net 词 →
 * 状态码 → refused。★ 为什么 load 排在最前（原设计里它排在 unsupported 之后，被红队证伪）：
 * '装载插件失败' 是**宿主自撰的、极具体的**前缀（PluginSourceAdapter.ets:218 / PluginSettings.ets:333/:338），
 * 宿主一旦这么说，真因就是插件没装载 —— 哪怕底层原文里带着 'not implemented' 这类词。红队实跑反例：
 * `装载插件失败：该接口未实现` 旧顺序判成 unsupported（屏上「该图源不支持此操作，请换一个图源」），
 * 而用户换图源毫无用处。具体前缀应当压过泛用词表。
 * 其余顺序沿用登录页并同样承重：unsupported 在 verify/net 之前（函数路径不存在常被包在超时文案里，
 * 判成网络会让用户白查网络）→ verify 在 net 前（滑块取题失败常说「超时」）→ 码段 → net 词 →
 * 状态码 → refused（net 在 refused 前：「HTTP 403」与断网抛 0 码常同串）。
 * ★ 经本 util 上屏的任何一句都不得含全角左括号 —— briefForScreen 砍括号那一步会在该字符处截断，
 *   带括号的文案会被切成半句（PluginLoginPage.ets:97-100 的既有判据）。★ 注意先后：**先剥宿主动作壳、
 *   再砍括号**（第 0 步在砍之前）。措辞刻意收窄成「经本 util 上屏」：红队指出各页面还有若干**直写**
 *   的兜底句（不经本 util，例如 pages/DetailPage.ets:310），那些不归本文件管；本文件只保证自己这条链的输出。
 * 依据系统 Kit：@kit.BasicServicesKit（BusinessError，取 code 拼进分类文本）。
 */
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';

/** 全角左括号：插件/适配器的自撰中文把补充信息（含 id）装在这段里，判据里整段砍掉 */
const FULL_OPEN_PAREN: string = '（';

/**
 * 宿主动作壳的正则（s37 补记）：`<动作>（<函数路径>）：<插件原文>` —— 逐字对应
 * data/source/PluginSourceAdapter.ets:231 的拼装 `action + '（' + fnPath + '）：' + errText(e)`。
 * 锚定在串首、且要求三段俱全（动作 ≤40 字、括号内路径 ≤60 字、紧跟全角冒号），所以不会误伤
 * 插件自己写的、恰好含括号的正常文案（那种串里没有「）：」这个组合）。
 */
const WRAP_HEAD_RE: RegExp = new RegExp('^[^（]{1,40}（[^）]{1,60}）：');

/** 能上屏的短句上限（超长按兜底处理，屏上不铺长串） */
const BRIEF_MAX: number = 40;

/** 日志侧原文截断长度（屏上收短，取证要留够上下文；只按长度截，不做任何改写）。 */
const RAW_MAX: number = 200;

/**
 * 档位常量：取值是日志里的稳定英文码（探针断言目标），别改成中文。
 * 顺序 = errBucket 的判定顺序；load 为本 util 新增，credential 刻意不带（登录专用）。
 */
export const EB_UNSUPPORTED: string = 'unsupported';
export const EB_LOAD: string = 'load';
export const EB_VERIFY: string = 'verify';
export const EB_NET: string = 'net';
export const EB_REFUSED: string = 'refused';
export const EB_UNKNOWN: string = 'unknown';


/** 各档屏上文案：一句话、带中文、不拼任何原文片段、不含全角括号。 */
function errBucketText(bucket: string): string {
  if (bucket === EB_NET) {
    return '网络连接异常，请检查网络后重试';
  }
  if (bucket === EB_VERIFY) {
    return '需要先完成安全验证，请按提示操作后重试';
  }
  if (bucket === EB_REFUSED) {
    return '服务器拒绝了本次请求，请稍后重试';
  }
  if (bucket === EB_UNSUPPORTED) {
    return '该图源不支持此操作，请换一个图源';
  }
  if (bucket === EB_LOAD) {
    return '图源插件未能加载，请在插件管理页重新启用后重试';
  }
  return '';
}

/**
 * load 档指纹（小写比对）。'装载插件失败' = PluginSourceAdapter.ets:218 的宿主自撰前缀；
 * 其余两枚是 bundleLoadFromPath 装载失败在引擎侧的原始形态。刻意不加裸 'load' / '加载'：
 * 业务文案里太常见，命中会把普通失败报成插件没装载。
 */
const LOAD_WORDS: string[] = ['装载插件失败', 'bundleloadfrompath', 'native module not registered'];

/**
 * HTTP 模块错误码（出处 toolchain/cli-tools/command-line-tools/sdk/default/openharmony/ets/api/
 * @ohos.net.http.d.ts :1332-:1363，API26 实测；词表与登录页 :200-:201 同源）。
 * 只有两组不是「网络本身不通」，其余 2300xxx 一律落网络档。
 */
const HTTP_CODE_BAD_URL: number[] = [2300003, 2300061];
const HTTP_CODE_REFUSED: number[] = [2300009, 2300998, 2300997];

/**
 * 本 SDK 里**没有** 19700xxx 这批码（openharmony 与 hms 两档 *.d.ts grep 均 0 命中，
 * 本机无法证实其存在）⇒ 只作窄范围兜底：落在区间内才认网络档，区间外的 19xxxxxx 不认。
 */
const RCP_NET_MIN: number = 19700000;
const RCP_NET_MAX: number = 19701999;

/** 引擎/JS 层网络错误名（逐字 = PluginLoginPage.ets:213-220；三条刻意收窄的理由见那边 :221-225 注释，
 *  不收裸「解析」/裸 reset/裸「取消」，别改回宽口径）。 */
const NET_WORDS: string[] = [
  'timeout', 'timed out', 'etimedout', 'timeouterror', 'aborterror', 'abort', 'canceled', 'cancelled',
  'network', 'connection', 'connect', 'connectfailed', 'socket', 'dns', 'resolve', 'unreachable',
  'offline', 'connection reset', 'socket hang up', 'econnreset', 'refused to connect', 'eof',
  'broken pipe', 'proxy', 'ssl', 'tls', 'certificate', 'handshake', 'http2', 'too many redirects',
  '网络', '超时', '连接', '断网', '离线', '重定向', '代理', '证书', '域名解析', '解析域名',
  '请求已取消', '请求取消'
];

/** 需要安全验证（人机校验），排在网络之前：滑块挂时文案若说网络会误导用户去查路由器。 */
const VERIFY_WORDS: string[] = [
  'captcha', 'recaptcha', 'slider', 'vericode', 'verify code', 'verifycode',
  'human verification', 'security check', '安全验证', '滑块', '验证码', '人机'
];

/** 服务器拒绝或封禁（逐字 = PluginLoginPage.ets:234-238）。 */
const REFUSED_WORDS: string[] = [
  'forbidden', 'banned', 'blacklist', 'blocklist', 'blacklisted', 'not allowed', 'denied',
  'rate limit', 'ratelimited', 'too many requests', 'too many request',
  '禁止', '封禁', '封号', '拉黑', '拒绝', '频繁', '稍后再试'
];

/** 插件不支持或无响应（逐字 = PluginLoginPage.ets:241-245；刻意不含裸「不支持」，理由见 :246-248）。 */
const UNSUPPORTED_WORDS: string[] = [
  'getloginbundle', 'getinfobundle', 'function path not found', 'target is not function',
  'not implemented', 'not supported', 'no such function', 'is not callable', 'no response',
  '未实现', '无响应', '没有响应'
];

/** 状态码数字串：只在原文自带 HTTP 语境时用（裸三位数字太常见 = 章节号/重试次数）。 */
const STATUS_RE: RegExp = new RegExp('(?:^|[^0-9])(4[0-9]{2}|5[0-9]{2})(?:[^0-9]|$)');

/** 技术细节形态判定（逐字 = PluginLoginPage.ets:111-152，marks 含 'http','HTTP'；
 *  花括号按码位比，源码里不写字面花括号，配平判据不受影响）。 */
function looksTechnical(s: string): boolean {
  if (s.indexOf('://') >= 0) {
    return true;
  }
  if (s.indexOf(' at ') >= 0 || s.indexOf('Error:') >= 0 || s.indexOf('error:') >= 0) {
    return true;
  }
  if (s.indexOf('@ohos.') >= 0 || s.indexOf('@hms.') >= 0 || s.indexOf('@kit.') >= 0) {
    return true;
  }
  const marks: string[] = ['.ets', '.ts', '.js', '.dart', '.so', '.json', '/data/', '/storage/', 'http', 'HTTP'];
  for (let i = 0; i < marks.length; i++) {
    if (s.indexOf(marks[i]) >= 0) {
      return true;
    }
  }
  const BACKSLASH: number = 92;
  const SQ_OPEN: number = 91;
  const SQ_CLOSE: number = 93;
  const CU_OPEN: number = 123;
  const CU_CLOSE: number = 125;
  let cjk: number = 0;
  for (let i = 0; i < s.length; i++) {
    const c: number = s.charCodeAt(i);
    if (c === BACKSLASH || c === SQ_OPEN || c === SQ_CLOSE || c === CU_OPEN || c === CU_CLOSE) {
      return true;
    }
    if (c >= 0x4E00 && c <= 0x9FFF) {
      cjk += 1;
    }
  }
  if (cjk === 0) {
    return true;
  }
  if (s.indexOf('Exception') >= 0 || s.indexOf('Traceback') >= 0) {
    return true;
  }
  return false;
}

/** 兜底前的最后一道（逐字 = PluginLoginPage.ets:89-108）：剥宿主动作壳 → 砍全角括号段 → 限长 →
 *  去技术串，都不中才原样上屏。★ 第 0 步「剥壳」是 s37 新增（理由见函数内注释），
 *  PluginLoginPage 那份拷贝没有这一步，两份在此处分叉 = 有意为之。 */
function briefForScreen(msg: string, fallback: string): string {
  if (typeof msg !== 'string') {
    return fallback;
  }
  let s: string = msg.trim();
  if (s.length === 0) {
    return fallback;
  }
  // ★ s37 补记（lead 在红队复核后追加，附独立探针 probe_user_visible case ②）：
  //   先剥掉**宿主自己**打的动作壳「<动作>（<函数路径>）：<插件原文>」。壳由
  //   data/source/PluginSourceAdapter.ets:231 拼出（`action + '（' + fnPath + '）：' + errText(e)`），
  //   三段全是确定形态，所以这是「拆已知包装」而不是猜。
  //   为什么必须剥：<动作> 是内部动作名（如「加载详情失败」），而**用户要看的是冒号后那句**。
  //   不剥的后果 = 第②步按全角括号截断，恰好把插件原文整段砍掉、只留下内部动作名 ——
  //   方向正好反了（PluginLoginPage 那条链的约定是「中文在前、括号里是补充信息」，与这里相反）。
  //   实测：`加载详情失败（getComicDetail）：该作品不存在或已下架` 旧版上屏 = `加载详情失败`（6 字，
  //   用户分不清是「没这部作品」还是「网坏了」），剥壳后 = `该作品不存在或已下架`。
  const wrapped: RegExpMatchArray | null = s.match(WRAP_HEAD_RE);
  if (wrapped !== null) {
    s = s.substring(wrapped[0].length).trim();
    if (s.length === 0) {
      return fallback;
    }
  }
  const cut: number = s.indexOf(FULL_OPEN_PAREN);
  // ★ s37 红队取证后改 `> 0` → `>= 0`（原写法见 PluginLoginPage.ets:98 旧拷贝）：
  //   括号在**句首**时 indexOf 返回 0，`> 0` 不成立 ⇒ 整串原样放行，直接违反本文件 :16
  //   那条「经本 util 上屏的任何一句都不得含全角左括号」的红线。复现（红队实跑）：
  //   errBriefForScreen('（内部）章节不可用', 'FB') 旧版原样返回带括号串。
  //   改成 >= 0 后句首括号被砍成空串，由紧随的空判接住 → 回兜底句，红线成立。
  if (cut >= 0) {
    s = s.substring(0, cut).trim();
  }
  if (s.length === 0 || s.length > BRIEF_MAX) {
    return fallback;
  }
  if (looksTechnical(s)) {
    return fallback;
  }
  return s;
}

/**
 * 分类：返回 EB_* 之一，顺序即优先级（承重，理由见文件头）。入参 = errTextOf 的文本
 * （含 code= 前缀形态，否则 2300xxx 全丢）。与登录页 classifyLoginError 的差异仅两处：
 * **load 档插在 unsupported 之前**（初版写「之后」，被红队证伪后前移，见文件头顺序说明）；
 * 无 credential 档（401 并入 refused 组）。
 */
export function errBucket(raw: string): string {
  if (typeof raw !== 'string' || raw.length === 0) {
    return EB_UNKNOWN;
  }
  const low: string = raw.toLowerCase();
  // ★ load 必须先扫（s37 红队取证：宿主自撰的「装载插件失败」是具体前缀，应压过泛用词表 ——
  //   详见文件头顺序说明；红队反例 `装载插件失败：该接口未实现`）。
  for (let i = 0; i < LOAD_WORDS.length; i++) {
    if (low.indexOf(LOAD_WORDS[i]) >= 0) {
      return EB_LOAD;
    }
  }
  for (let i = 0; i < UNSUPPORTED_WORDS.length; i++) {
    if (low.indexOf(UNSUPPORTED_WORDS[i]) >= 0) {
      return EB_UNSUPPORTED;
    }
  }
  for (let i = 0; i < VERIFY_WORDS.length; i++) {
    if (low.indexOf(VERIFY_WORDS[i]) >= 0) {
      return EB_VERIFY;
    }
  }
  let code: number = 0;
  const cm: RegExpMatchArray | null = raw.match(/(?:code=|code : |ErrorCode: ?)([0-9]{3,8})/);
  if (cm !== null) {
    const parsed: number = parseInt(cm[1], 10);
    if (!isNaN(parsed)) {
      code = parsed;
    }
  }
  const inHttp: boolean = code >= 2300000 && code < 2400000;
  const inRcpNet: boolean = code >= RCP_NET_MIN && code <= RCP_NET_MAX;
  if (inHttp || inRcpNet) {
    for (let i = 0; i < HTTP_CODE_BAD_URL.length; i++) {
      if (code === HTTP_CODE_BAD_URL[i]) {
        return EB_UNSUPPORTED;
      }
    }
    for (let i = 0; i < HTTP_CODE_REFUSED.length; i++) {
      if (code === HTTP_CODE_REFUSED[i]) {
        return EB_REFUSED;
      }
    }
    if (code === 2300094) {
      return EB_REFUSED;
    }
    return EB_NET;
  }
  for (let i = 0; i < NET_WORDS.length; i++) {
    if (low.indexOf(NET_WORDS[i]) >= 0) {
      return EB_NET;
    }
  }
  let status: number = 0;
  const hasHttpHint: boolean = low.indexOf('http') >= 0 || low.indexOf('status') >= 0
    || low.indexOf('code') >= 0 || low.indexOf('状态码') >= 0;
  const sm: RegExpMatchArray | null = hasHttpHint ? raw.match(STATUS_RE) : null;
  if (sm !== null) {
    const parsed: number = parseInt(sm[1], 10);
    if (!isNaN(parsed)) {
      status = parsed;
    }
  }
  if (status >= 400 && status < 600) {
    // 401 与登录页不同：本 util 无 credential 档，落「服务器拒绝」；403/429 同档；
    // 408 与 5xx = 暂时不可用归网络；其余 4xx = 明确拒绝了这个请求。
    if (status === 408 || status >= 500) {
      return EB_NET;
    }
    return EB_REFUSED;
  }
  for (let i = 0; i < REFUSED_WORDS.length; i++) {
    if (low.indexOf(REFUSED_WORDS[i]) >= 0) {
      return EB_REFUSED;
    }
  }
  return EB_UNKNOWN;
}

/**
 * 上屏唯一入口：命中档位 → 定死文案；unknown → briefForScreen（原文短且干净才放行，否则兜底句）。
 * 返回值**在 fallback 非空时**恒非空、恒不含全角括号（调用点只判 .length，语义不变）。
 * ★ 「恒非空」是有条件的（s37 红队指出）：fallback 传空串时本函数照样返回空串。
 *   现有四个调用点传的都是非空兜底句（DetailPage / PluginDetail / SearchPage 两处），
 *   所以现场成立；新增调用点时**必须给非空 fallback**，否则空白错误态没有任何提示。
 * 红队复核范围外但需知道：本函数在**句首**全角括号那条红线上曾漏判（cut > 0），
 * 已修为 >= 0（见 briefForScreen 内注释）。
 *
 * ★ 本函数**不写日志**，是纯函数（可被探针无副作用地断言）。「原文只进日志」这条承诺由
 *   调用点负责：每个 catch 里必须 `errLog(tag, raw)` **再**调它 —— 必须先记后洗。
 *   尤其 unknown + 干净短中文这条路径会把原文**原样放行上屏**，漏记就等于那句上了屏的话
 *   再无任何原始记录。新增调用点时照抄现有四处的「errTextOf → errLog → errBriefForScreen」三行。
 */
export function errBriefForScreen(raw: string, fallback: string): string {
  const bucket: string = errBucket(raw);
  if (bucket !== EB_UNKNOWN) {
    return errBucketText(bucket);
  }
  return briefForScreen(raw, fallback);
}

/**
 * 日志侧留原文（屏上收短、取证留全）：档位进 tag，原文只按长度截不改写。
 * 屏上绝不出现这里的任何内容。
 */
export function errLog(tag: string, raw: string): void {
  const s: string = typeof raw === 'string' ? raw : String(raw);
  Logger.e(tag + '[' + errBucket(s) + '] raw=' + (s.length > RAW_MAX ? s.substring(0, RAW_MAX) : s));
}

/**
 * catch 里的异常 → 可分类文本（= PluginLoginPage.ets:390-403 errText 同口径）：
 * BusinessError 的 code 必须一起进文本，否则 2300xxx 码段全丢；普通 Error 只有 message。
 * 派发书给的是 PluginSourceAdapter.ets:101-108（只取 message），这里取更宽的一份 = 带 code，
 * 差异已在交卷报告「与派工书不符之处」单列。
 */
export function errTextOf(e: Object): string {
  // ★ s37 红队取证后补空值前置：`throw undefined` / `throw null` 时 `e as BusinessError`
  //   仍是 undefined/null，下面读 `.message` 会**在 catch 里二次抛** TypeError
  //   （红队实跑：TypeError: Cannot read properties of undefined (reading 'message')），
  //   原错误被新错误顶掉、屏上还可能露出框架串。换成空对象后落到 `String(e)` = 'undefined'/'null'，
  //   恒非空、可分类（unknown）→ 走调用点兜底句。
  if (e === null || e === undefined) {
    return String(e);
  }
  const be: BusinessError = e as BusinessError;
  let msg: string = '';
  if (typeof be.message === 'string') {
    msg = be.message;
  }
  if (msg.length === 0) {
    msg = String(e);
  }
  if (typeof be.code === 'number') {
    return 'code=' + be.code + ' ' + msg;
  }
  return msg;
}
