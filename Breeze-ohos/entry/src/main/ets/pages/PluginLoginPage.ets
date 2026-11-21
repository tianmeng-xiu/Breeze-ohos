/**
 * 职责：插件「账号登录」页（第 10 路由）。用户回传缺陷③「插件的登录功能未实现」。
 * 流程对齐上游（权威两份，改逻辑前先读它们）：
 *   Breeze/lib/page/login/login_page.dart             :116 取方案 / :142-232 建表单 /
 *                                                     :236-276 验证码图 / :351-419 提交
 *   Breeze/lib/page/login/slider_captcha_dialog.dart   滑块取题 / 轨迹 / 验题（一次一题）
 * 业务调用全在 data/source/PluginLogin.ets（入参口径 + 会话保持真相写在那份文件头），
 * 本页只管状态机、表单与手势。
 *
 * 入口：pages/PluginSettingsPage「登录」分组 → router.pushUrl('pages/PluginLoginPage',
 *       data/source/PluginLogin.ets 导出的 PluginLoginParams)。
 * 状态机：loading（取方案）→ form（表单）/ error（不支持或取方案失败，给「重试」）。
 * 滑块：页内底部弹层（上游是独立 Dialog 路由；我方无登录路由栈 ⇒ 弹层等价，
 *       遮罩与卡片仍是 Stack 兄弟层：ClickEvent 没有 stopPropagation）。
 *       轨迹口径 = [elapsedMs, dx/scale 一位小数, y 取整]，首点 [0,0,0]，>500 点去掉第二个，
 *       <3 点不上报只归零；验题失败立刻换新题（旧 token 作废）。
 *
 * ⚠ 四条实现约束（都是本仓库已验证的坑，别顺手「优化」）：
 * 1) PixelMap 由页面持有，替换与 aboutToDisappear 都要 release（本页会反复进出）。
 * 2) 表单值表用**非 @State 的 Map** 持有：TextInput 的 text 只在重绘时回读，
 *    onChange 写 Map 不触发重绘 ⇒ 中文输入法不跳字。做成 @State 每敲一个字光标回开头。
 * 3) V1 @State 只观察**顶层属性赋值**：滑块的位移/错误/图都是一级 @State 字段，
 *    没有塞进某个 @State 对象的二级属性里（那样改了不重绘）。
 * 4) 值表变更后需要重绘的地方（验证码图）用「换整个 Map 引用」触发（同 PluginSettingsPage 口径）。
 *
 * s15 第 2 条（用户原话「插件设置中登录相关报错改为向用户展示的简单信息，不再显示完整报错全文」）：
 *      屏上一律是人能看懂的中文短句，底层原文只进日志（briefForScreen + noteRaw 两个 helper，
 *      判据与依据写在 helper 注释里）。
 *
 * s16 第 1 条（用户原话「登录相关报错改成简单信息并且区分网络错误 / 账号密码错误等多种」）：
 *      顺序 = **先分类再脱敏**，分类结果决定文案；口径写死在 classifyLoginError 一枚函数里（连同下面
 *      两张码段表与三张关键词表），加插件时只复核那几处。「分类命中」优先于「看不明白才给兜底句」
 *      的旧逻辑 —— 旧逻辑只在 unknown 档继续生效，looksTechnical 的放行判据原样保留、未被削弱；
 *      命中档位时屏上是宿主定死的句子，原文一律不上屏（定死的句子本身没有技术串，再过一遍
 *      looksTechnical 只是为了「将来有人往词表里塞话」也不会把技术串放出去）。
 *      档位（六档 + 未知）：网络 / 账号或密码错 / 需要安全验证 / 服务器拒绝或封禁 / 插件不支持或无响应 / 未知。
 *
 * s16 第 4 条（用户原话「A 插件登录后 B 插件的登录页把账号也带出来了」）：消费侧堵残留 ——
 *      登录页**不预填任何凭据类字段**（口令类看 kind，账号类与令牌类看键名表 CRED_KEY_HINTS），
 *      口径、根因与连带影响写在 CRED_KEY_HINTS 与 load 的注释里。
 */
import { promptAction, router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { common } from '@kit.AbilityKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { LoadingView, ErrorView } from '../view/common/StateViews';
import {
  PluginLogin,
  PluginLoginParams,
  LoginScheme,
  LoginField,
  SliderChallenge,
  CaptchaImage,
  LoginResult
} from '../data/source/PluginLogin';
import { PluginSettings } from '../data/source/PluginSettings';
import { Logger } from '../util/Logger';
import { BusinessError } from '@kit.BasicServicesKit';

/** 轨迹点上限（上游 >500 去掉第二个点）。 */
const TRACK_MAX: number = 500;

/** busy 的「正在提交」取值（提交期间禁用按钮并改文案）。 */
const BUSY_SUBMIT: string = '__submit__';

/** 全角左括号：插件/适配器的自撰中文把补充信息（含 id）装在这段里，判据里整段砍掉 */
const FULL_OPEN_PAREN: string = '（';

/** 能上屏的短句上限（超长按兜底处理，屏上不铺长串） */
const BRIEF_MAX: number = 40;

/** 日志侧原文截断长度（派工书给的口径：必要时截到 200 字符再记）。 */
const RAW_MAX: number = 200;

/**
 * s15 第 2 条判据：把底层错误洗成「能给用户看的一句中文」，判不上就回兜底短句。依据逐条：
 * 1) 空串 = 没有可用信息，直接兜底；
 * 2) 先砍掉全角左括号及其后面全部内容 —— 插件与适配器自撰的中文提示都把补充信息（章节 id、
 *    作品号这类用户浏览痕迹）塞在括号里，只留前半句既保住可读中文又不泄露痕迹；
 * 3) 剩下的串里只要出现堆栈、URL、包路径、JSON 花括号/方括号、英文异常名任一形态就整体兜底
 *    （判据见 looksTechnical），不把底层原文铺给用户 —— 这正是用户报的「显示完整报错全文」；
 * 4) 都不命中才原样展示：插件明确写给用户的中文提示（例如「用户名或密码错误」）对用户有用，
 *    换成兜底短句反而把有用信息抹掉了。
 *
 * 与 view/reader/ReaderView.ets 里的同名 helper 同一口径（两份各留一份实现：跨文件共享要新增导出面，
 * 而两边调用点都只在本文件用得着）；改判据请同时改两处。
 */
function briefForScreen(msg: string, fallback: string): string {
  if (typeof msg !== 'string') {
    return fallback;
  }
  let s: string = msg.trim();
  if (s.length === 0) {
    return fallback;
  }
  const cut: number = s.indexOf(FULL_OPEN_PAREN);
  // ★ s37 红队取证后改 `> 0` → `>= 0`（与 util/ErrText.ets:171、view/reader/ReaderView.ets:1064 同步）：
  //   括号在**句首**时 indexOf 返回 0，`> 0` 不成立 ⇒ 整串原样放行，屏上出现全角左括号。
  //   改后句首括号被砍成空串，由紧随的空判接住 → 回兜底句。
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

/** 技术细节形态判定：命中任一条就不该上屏（花括号按码位比，源码里不写字面花括号，配平判据不受影响）。 */
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
  // s16 第 1 条补一条 http（只加不减，放行判据未被削弱）：插件自撰文案「请求失败：HTTP 404 Not Found」
  // 这类短文本会走到 unknown 档，屏上不能出现 http 字样（验收判据）
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
  // 一个中日韩汉字都没有 = 英文异常名 / 裸 code / 纯英文堆栈行，一律不上屏
  if (cjk === 0) {
    return true;
  }
  if (s.indexOf('Exception') >= 0 || s.indexOf('Traceback') >= 0) {
    return true;
  }
  return false;
}

/** 日志侧留原文（派工书要求：屏上收短，取证要留全文），只按长度截，不做任何改写。 */
function noteRaw(tag: string, raw: string): void {
  const s: string = typeof raw === 'string' ? raw : String(raw);
  Logger.w(tag + ' raw=' + (s.length > RAW_MAX ? s.substring(0, RAW_MAX) : s));
}

/**
 * ==================== s16 第 1 条：登录报错分类（口径唯一写死处） ====================
 * 档位常量：取值 = 屏上文案前缀用的稳定英文码，同时是探针的断言目标，别改成中文。
 * 顺序 = classifyLoginError 的判定顺序（unsupported 最先、net 在 refused 之前，理由写在函数注释里）。
 */
const LE_UNSUPPORTED: string = 'unsupported';
const LE_VERIFY: string = 'verify';
const LE_NET: string = 'net';
const LE_REFUSED: string = 'refused';
const LE_CREDENTIAL: string = 'credential';
const LE_UNKNOWN: string = 'unknown';

/** 六档（不含未知）的屏上文案：一句话、带中文、不含技术串（不拼任何原文片段）。 */
function loginErrText(bucket: string): string {
  if (bucket === LE_NET) {
    return '网络连接异常，请检查网络后重试';
  }
  if (bucket === LE_CREDENTIAL) {
    return '账号或密码不正确，请核对后重试';
  }
  if (bucket === LE_VERIFY) {
    return '需要先完成安全验证，请按提示操作后重试';
  }
  if (bucket === LE_REFUSED) {
    return '服务器拒绝了本次请求，请稍后重试';
  }
  if (bucket === LE_UNSUPPORTED) {
    return '该插件不支持此操作，或插件没有响应';
  }
  return '登录失败，请稍后重试';
}

/**
 * HTTP 模块错误码（出处 toolchain/cli-tools/command-line-tools/sdk/default/openharmony/ets/api/
 * @ohos.net.http.d.ts，:1332-:1363 的 throws 清单，API26 实测逐条摘出 34 枚 2300xxx）。
 * 只有两组**不是**「网络本身不通」，单独列出来，其余 2300xxx 一律落网络档（末尾的兜底分支）：
 * - 2300003 / 2300061 = 地址格式或编码不合法 ⇒ 插件给的 URL 坏了，属插件侧，不是用户网络；
 * - 2300094 = HTTP 层认证失败（401/403 到不了这里，这枚是 curl 系 CURLOPT_HTTPAUTH 语义）；
 * - 2300005 解析代理名失败刻意**不**列：代理挂了也归「网络」，用户在代理环境下看到的就该是网络档。
 */
const HTTP_CODE_BAD_URL: number[] = [2300003, 2300061];
const HTTP_CODE_REFUSED: number[] = [2300009, 2300998, 2300997];

/**
 * 本 SDK 里**没有** 19700xxx / 19700123 这批码（全 SDK 两档实测：openharmony 与 hms 的 *.d.ts 里
 * grep 1970 与 19700123 均 0 命中；RemoteCommunicationKit 也不在本 SDK 的 kits 里，全仓 0 引用）。
 * 那批码属 rcp 模块（网络检索到的说法，本机无法证实 ⇒ 只作**窄范围**兜底，见下面的码段判定）：
 * 落在 [19700000,19701999] 一律网络档；区间外的 19xxxxxx 不认，避免把别的子系统码误判成网络。
 */
const RCP_NET_MIN: number = 19700000;
const RCP_NET_MAX: number = 19701999;

/** 引擎/JS 层错误名：取不到码时按这些名词判网络（形态来自本仓 fetch 与桥的抛出点）。 */
const NET_WORDS: string[] = [
  'timeout', 'timed out', 'etimedout', 'timeouterror', 'aborterror', 'abort', 'canceled', 'cancelled',
  'network', 'connection', 'connect', 'connectfailed', 'socket', 'dns', 'resolve', 'unreachable',
  'offline', 'connection reset', 'socket hang up', 'econnreset', 'refused to connect', 'eof',
  'broken pipe', 'proxy', 'ssl', 'tls', 'certificate', 'handshake', 'http2', 'too many redirects',
  '网络', '超时', '连接', '断网', '离线', '重定向', '代理', '证书', '域名解析', '解析域名',
  '请求已取消', '请求取消',
  // ★ s39 与 util/ErrText.ets 的 NET_WORDS 同步补（用户反馈「域名无法解析在同一报错界面上
  //   产生了多次」）：下面三条收窄纪律照旧成立，补的都是完整短语，不收裸词。
  '域名无法解析', '无法解析该域名', '无法解析地址', '地址解析失败',
  'no such host', 'name or service not known', 'nodename nor servname',
  'failed to lookup address', 'network is unreachable', 'no route to host'
];
// 三处刻意收窄（探针实测出来的假阳，别改回宽口径）：
// - 不收裸「解析」：插件自撰文案「解析响应失败 / 返回体解析失败」是解析坏数据，不是 DNS，
//   收裸词会把它们报成网络错（用户去查路由器）；只收「域名解析 / 解析域名」。
// - 不收裸 reset：会命中「reset your password」这类改密码文案；只收三种链路重置形态。
// - 不收裸「取消」：收藏/订阅类文案里「已取消」太常见；只收「请求已取消 / 请求取消」。

/** 需要安全验证（人机校验），排在网络之前：滑块/图形码挂时文案若说网络会误导用户去查路由器。 */
const VERIFY_WORDS: string[] = [
  'captcha', 'recaptcha', 'slider', 'vericode', 'verify code', 'verifycode',
  'human verification', 'security check', '安全验证', '滑块', '验证码', '人机'
];

/** 服务器拒绝或封禁。 */
const REFUSED_WORDS: string[] = [
  'forbidden', 'banned', 'blacklist', 'blocklist', 'blacklisted', 'not allowed', 'denied',
  'rate limit', 'ratelimited', 'too many requests', 'too many request',
  '禁止', '封禁', '封号', '拉黑', '拒绝', '频繁', '稍后再试'
];

/** 插件不支持或无响应（三枚特征词与 data/source/PluginLogin.ets:40 的 UNSUPPORTED_HINTS 同源）。 */
const UNSUPPORTED_WORDS: string[] = [
  'getloginbundle', 'getinfobundle', 'function path not found', 'target is not function',
  'not implemented', 'not supported', 'no such function', 'is not callable', 'no response',
  '未实现', '无响应', '没有响应'
];
// 刻意不含裸「不支持」：插件自撰业务文案里「格式不支持 / 该邮箱不支持注册」很常见，
// 命中会把普通失败报成「插件不支持」；「该插件不支持登录」这句由 data/source/PluginLogin.ets
// 已经判好，取方案出口单独放行（见 load 里的 indexOf 判定），不靠这里。

/** 账号或密码错（插件自撰文案中英关键词）。 */
const CREDENTIAL_WORDS: string[] = [
  'account or password', 'account or pin', 'password or account',
  'wrong password', 'incorrect password', 'invalid password', 'invalid account',
  'invalid credential', 'wrong credential', 'authentication failed', 'invalid username',
  'wrong username', 'login failed', 'sign in failed', 'unauthorized', 'invalid login',
  'email or password', 'password or email', 'account or email',
  '账号或密码', '账号密码', '账号或验证码', '用户名或密码', '密码错误', '密码不正确',
  '密码不对', '账号不存在', '账号错误', '账号不正确', '用户名或口令', '口令错误',
  '身份验证失败'
];
// 刻意不含裸「登录失败 / 未登录 / 登录失效」：适配器 normalizeSubmitError 给**每一条**提交失败
// 都拼「登录失败：」前缀（data/source/PluginLogin.ets:527），留着会把解析失败、404 之类一并
// 报成「账号或密码不正确」。这类含糊话落 unknown 档 = 让插件自己的短中文原样上屏，更准。

/**
 * 状态码数字串：只在原文自带 HTTP 语境时用（jm 的 axios 文案 = 「Request failed with status code 401」、
 * jjmhw = 「登录失败：HTTP 404 Not Found」，都是裸数字没码段）。收全部 4xx/5xx 再分档，
 * 别只收几枚 —— 只收 401/403/429/5xx 的话，404 会漏到兜底句「请检查账号密码」，那比现状更误导。
 */
const STATUS_RE: RegExp = new RegExp('(?:^|[^0-9])(4[0-9]{2}|5[0-9]{2})(?:[^0-9]|$)');

/**
 * 分类：返回档位常量之一。**顺序即优先级**，别随意挪动：
 * ① unsupported 最先 = 「函数路径不存在 / 目标不是函数」有时会**包在**超时或无响应的文案里，
 *    判成网络会让用户白查网络（本条是宿主自身最可修的信号）；
 * ② verify 在 net 之前 = 滑块/图形码取题失败时文案常说「超时」，但它要的是「重做人机校验」；
 * ③ net 在 refused 之前 = 插件文案「登录失败：HTTP 403」里 403 与失败同现，而真断网时插件也常
 *    抛 0 或空状态码；状态码只在**没命中网络词**时才生效（401/403 的分支互斥，不会互相遮蔽）；
 * ④ credential 垫底 = 插件自撰中文最爱带「登录失败」，而带状态码的文案几乎都另有网络/拒绝特征，
 *    垫底才不会把网络问题报成「密码错了」（派工书要的正是「别把 401 和断网混成一句」）。
 * 入参 = 原始错误文本（含 code= 前缀形态）；取码规则见 errText 注释。
 */
function classifyLoginError(raw: string): string {
  const low: string = raw.toLowerCase();
  for (let i = 0; i < UNSUPPORTED_WORDS.length; i++) {
    if (low.indexOf(UNSUPPORTED_WORDS[i]) >= 0) {
      return LE_UNSUPPORTED;
    }
  }
  for (let i = 0; i < VERIFY_WORDS.length; i++) {
    if (low.indexOf(VERIFY_WORDS[i]) >= 0) {
      return LE_VERIFY;
    }
  }
  // 码段判定：2300xxx = HTTP 模块码，[RCP_NET_MIN,RCP_NET_MAX] = rcp 系（本机 SDK 无，窄兜底）。
  // 入参恒是字符串（errText 已把 BusinessError.code 拼成 code=NNN），所以这里只做正则取码，
  // 不把 string 强转 BusinessError（两个类型无重叠，转译会报错）。
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
        return LE_UNSUPPORTED;
      }
    }
    for (let i = 0; i < HTTP_CODE_REFUSED.length; i++) {
      if (code === HTTP_CODE_REFUSED[i]) {
        return LE_REFUSED;
      }
    }
    // 2300094 认证错误 = 服务器不认这次身份，比「密码错」更准（密码错在 HTTP 层表现为 401 文案）
    if (code === 2300094) {
      return LE_REFUSED;
    }
    return LE_NET;
  }
  for (let i = 0; i < NET_WORDS.length; i++) {
    if (low.indexOf(NET_WORDS[i]) >= 0) {
      return LE_NET;
    }
  }
  let status: number = 0;
  // 只有原文自带 HTTP 语境时才按数字串认状态码：错误文本里出现裸三位数字太常见（章节号、重试次数）
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
    if (status === 401) {
      return LE_CREDENTIAL;
    }
    if (status === 403 || status === 429) {
      return LE_REFUSED;
    }
    // 408 与全部 5xx = 服务端/链路暂时不可用；其余 4xx（404/405/410…）= 服务器明确拒绝了这个请求
    if (status === 408 || status >= 500) {
      return LE_NET;
    }
    return LE_REFUSED;
  }
  for (let i = 0; i < REFUSED_WORDS.length; i++) {
    if (low.indexOf(REFUSED_WORDS[i]) >= 0) {
      return LE_REFUSED;
    }
  }
  for (let i = 0; i < CREDENTIAL_WORDS.length; i++) {
    if (low.indexOf(CREDENTIAL_WORDS[i]) >= 0) {
      return LE_CREDENTIAL;
    }
  }
  return LE_UNKNOWN;
}

/**
 * 上屏唯一入口（替换 s15 的 briefForScreen 调用点）：
 * 命中档位 → 定死文案；未知档 → 交回 s15 的 briefForScreen（原文短且干净才放行，否则兜底句）。
 * 兜底句仍由各调用点按语境给（装载 / 取方案 / 验证码 / 滑块 / 提交各不相同）。
 */
function loginErrBrief(raw: string, fallback: string): string {
  const bucket: string = classifyLoginError(raw);
  if (bucket !== LE_UNKNOWN) {
    return loginErrText(bucket);
  }
  return briefForScreen(raw, fallback);
}

/** 日志用：档位 + 原文（原文截断交给 noteRaw）。屏上绝不出现这里的任何内容。 */
function loginErrLogTag(tag: string, raw: string): string {
  return tag + '[' + classifyLoginError(raw) + ']';
}

/**
 * catch 里的异常 → 可分类文本。刻意不直接喂 Logger.ex 那套（那份只给日志）：
 * BusinessError 的 code 必须一起进文本，否则 2300xxx 全丢；普通 Error 只有 message。
 * 形态同 data/image/ImageCache.ets:97 errBrief（带 code 就写 code，没有就只写 message）。
 */
function errText(err: Object): string {
  // s37 红队取证：空值前置，防 `throw undefined/null` 在 catch 内二次抛 TypeError
  //（同病四份，见 data/source/PluginSourceAdapter.ets:101 errText 注释）。
  if (err === null || err === undefined) {
    return String(err);
  }
  const be: BusinessError = err as BusinessError;
  let msg: string = '';
  if (typeof be.message === 'string') {
    msg = be.message;
  }
  if (msg.length === 0) {
    msg = String(err);
  }
  if (typeof be.code === 'number') {
    return 'code=' + be.code + ' ' + msg;
  }
  return msg;
}

/**
 * ==================== s16 第 4 条：凭据类字段判定（消费侧，口径唯一写死处） ====================
 * 根因（lead 已取证，本批不动根治）：宿主持久化桶键 = runtime 名，而 Rust 侧 runtime **全局唯一**
 *   = breeze-ohos（breeze_qjs_ohos/src/engine.rs:200 AsyncHostRuntimeBuilder::new 与
 *   host_bridge.rs:314 encode_input 把 runtime 名前置；util/BreezeHost.ets 取 args 首元当桶名，
 *   preferences 的 plugin_config 以它为 key）⇒ 所有插件的 auth.account / auth.password / auth.jwt
 *   落进同一个桶，键名还跨插件同名（禁漫与哎咔实测同形）。上游是每插件一 runtime，天然隔离。
 * 消费侧口径：**先按 kind 挡（LoginField.isPassword() = kind === 'password'，见
 *   data/source/PluginLogin.ets:75-77；它不含 captcha-image 与 slider-captcha，那两种靠下面的键名
 *   表命中 —— 插件给这两类字段用的键名都带 captcha/verify），其余字段再按键名过 CRED_KEY_HINTS**
 *   （小写子串比较 ⇒ 裸 account 与点分 auth.account 一起命中，插件实际用的正是后一种）。
 * ⚠ 只在**本页登录表单**的初值循环里生效（s15 定过的 R5 口径：不得据键名去锁插件设置页的普通项）；
 *   线路、画质、代理这类非凭据字段继续允许预填。
 * ⚠ 刻意不含裸 uid —— 它会连 guide、uuid 这类普通键一起命中（本仓已实测该子串关系）。
 * ⚠ 连带影响：createSlider 的入参就是这张值表（见 loadSlider），所以凭据被挡下后
 *   「先拖滑块再输账号」这条路径拿不到账号初值 —— 故意的：宁可多输一次，
 *   也不把 A 插件的凭据喂进 B 插件的验证接口。
 */
const CRED_KEY_HINTS: string[] = [
  'account', 'email', 'mail', 'username', 'user', 'nickname', 'login', 'phone', 'mobile',
  'password', 'passwd', 'pwd', 'token', 'jwt', 'secret', 'cookie', 'session', 'auth',
  'credential', 'otp', 'captcha', 'verify'
];

/** 键名是否属凭据类（小写子串）。空键不算。 */
function isCredentialKeyName(key: string): boolean {
  const k: string = key.toLowerCase();
  if (k.length === 0) {
    return false;
  }
  for (let i = 0; i < CRED_KEY_HINTS.length; i++) {
    if (k.indexOf(CRED_KEY_HINTS[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/** 登录页该不该挡下这个字段的初值：kind 优先（口令/验证码类），其次键名表。 */
function isCredentialField(f: LoginField, key: string): boolean {
  if (f.isPassword()) {
    return true;
  }
  return isCredentialKeyName(key);
}

@Entry
@Component
struct PluginLoginPage {
  @StorageProp('isDark') isDark: boolean = false;

  // ---------------- 路由参数与页面阶段 ----------------
  @State uuid: string = '';
  @State pluginName: string = '';
  @State localFile: string = '';
  @State loading: boolean = true;
  @State loadError: string = '';
  @State scheme: LoginScheme | null = null;

  // ---------------- 表单 ----------------
  /** 值表：非 @State（见文件头约束 2）。键 = field.key（含滑块 pass 与验证码文本）。 */
  private values: Map<string, string> = new Map<string, string>();
  /** 验证码图：@State + 每次整体换引用（约束 4）。 */
  @State captchaImages: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  /** 正在取验证码的字段 key（空串 = 没有）。 */
  @State captchaBusyKey: string = '';
  /** 取失败过的字段 key（行内给「点击重试」提示）。 */
  @State captchaFailedKeys: string[] = [];
  @State busy: string = '';

  // ---------------- 滑块弹层（全部一级 @State，约束 3）----------------
  @State sliderOpen: boolean = false;
  @State sliderLoading: boolean = false;
  @State sliderErr: string = '';
  @State sliderBg: image.PixelMap | undefined = undefined;
  @State sliderPiece: image.PixelMap | undefined = undefined;
  @State sliderImageW: number = 320;
  @State sliderImageH: number = 180;
  @State sliderPieceY: number = 0;
  @State sliderPieceSize: number = 52;
  @State sliderBgW: number = 0;
  @State sliderKnob: number = 0;
  /** 当前滑块字段（弹层归属，不需要重绘 ⇒ 普通字段） */
  private sliderField: LoginField | null = null;
  private sliderToken: string = '';
  private sliderCreateFn: string = '';
  private sliderVerifyFn: string = '';
  private dragBaseDx: number = 0;
  private dragStartT: number = 0;
  private track: number[][] = [];

  aboutToAppear(): void {
    // 参数取法与 pages/PluginSettingsPage.ets:91-107 同范式（pushUrl 传实例 ⇒ instanceof；
    // 兜底 ESObject 分支应对外部直接 router.pushUrl 传字面量）
    try {
      const raw: Object = router.getParams();
      if (raw instanceof PluginLoginParams) {
        this.uuid = raw.uuid;
        this.pluginName = raw.name;
        this.localFile = raw.localFile;
      } else if (raw !== null && raw !== undefined) {
        const src: ESObject = raw;
        this.uuid = src.uuid !== undefined ? String(src.uuid) : '';
        this.pluginName = src.name !== undefined ? String(src.name) : '';
        this.localFile = src.localFile !== undefined ? String(src.localFile) : '';
      }
    } catch (err) {
      Logger.w('PluginLoginPage 参数解析失败：' + (err as Error).message);
    }
    this.load();
  }

  aboutToDisappear(): void {
    // 页面销毁时释放所有 PixelMap（验证码图 + 滑块底图/拼图）
    this.captchaImages.forEach((pm: image.PixelMap, k: string): void => {
      this.releasePm(pm, 'captcha:' + k);
    });
    this.captchaImages = new Map<string, image.PixelMap>();
    this.releasePm(this.sliderBg, 'sliderBg');
    this.releasePm(this.sliderPiece, 'sliderPiece');
    this.sliderBg = undefined;
    this.sliderPiece = undefined;
  }

  /** scheme 的窄化取用（build 里不能写局部变量，if 分支的窄化在 ArkTS 里不可依赖）。 */
  private sch(): LoginScheme {
    const s: LoginScheme | null = this.scheme;
    return s === null ? new LoginScheme() : s;
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  private releasePm(pm: image.PixelMap | null | undefined, tag: string): void {
    if (pm === null || pm === undefined) {
      return;
    }
    pm.release().catch((e: Object): void => {
      Logger.ex('PixelMap 释放失败 ' + tag, e);
    });
  }

  // ---------------- 取方案 ----------------

  private load(): void {
    this.loading = true;
    this.loadError = '';
    // 先确保在引擎里（重启后直接进登录页时未装载）
    PluginSettings.ensureLoaded(this.uuid, this.absPath()).then((err: string): Promise<void> => {
      if (err.length > 0) {
        noteRaw(loginErrLogTag('登录页装载插件失败', err), err);
        this.loadError = loginErrBrief(err, '插件装载失败，请稍后重试');
        this.loading = false;
        return Promise.resolve();
      }
      return PluginLogin.fetchScheme(this.uuid).then((r: LoginResult<LoginScheme>): void => {
        if (!r.ok || r.data === null) {
          if (r.err.length > 0) {
            noteRaw(loginErrLogTag('登录页取方案失败', r.err), r.err);
          }
          // 「该插件不支持登录」这句是 data/source/PluginLogin.ets 已经判好的（fetchScheme 把三枚
          // 特征词换成中文），这里不重复分类；其余按分类结果给文案。
          this.loadError = r.err.indexOf('不支持登录') >= 0
            ? '该插件不支持登录'
            : loginErrBrief(r.err, '该插件不支持登录');
          this.loading = false;
          return;
        }
        const s: LoginScheme = r.data;
        this.scheme = s;
        // 初值：scheme.initial（上游 values = {...data, ...data.values}）
        // s15 第 5 条起不预填口令类；s16 第 4 条扩到**一切凭据类字段**（用户原话「A 插件登录后
        // B 插件登录页把账号也带出来了」）：判定走 isCredentialField —— kind 是口令/验证码类按 kind 挡，
        // 其余按键名表 CRED_KEY_HINTS 挡（那张表旁边写着根因：桶键 = 全局唯一 runtime 名，
        // 所有插件的 auth.account / auth.password / auth.jwt 其实同桶，键名还同名）。
        // 非凭据字段（线路、画质、代理等）继续预填；插件设置页的普通项不受这里影响（R5 口径）。
        const m: Map<string, string> = new Map<string, string>();
        s.initial.forEach((v: string, k: string): void => {
          if (isCredentialField(this.fieldOf(k), k)) {
            return;
          }
          m.set(k, v);
        });
        this.values = m;
        this.loading = false;
        // 有验证码图字段的，逐个预取一次（上游 _refreshAllCaptchas 的等价）
        for (let i = 0; i < s.fields.length; i++) {
          if (s.fields[i].isCaptchaImage()) {
            this.fetchCaptcha(s.fields[i]);
          }
        }
      });
    }).catch((e: Object): void => {
      // s15 第 2 条：屏上不拼 message；s16 第 1 条：原文（含 code）先分类再定文案，Logger.ex 留全文
      const raw: string = errText(e);
      noteRaw(loginErrLogTag('登录页初始化异常', raw), raw);
      this.loadError = loginErrBrief(raw, '打开登录页失败，请稍后重试');
      this.loading = false;
      Logger.ex('登录页初始化失败', e);
    });
  }

  private absPath(): string {
    if (this.localFile.length === 0) {
      return '';
    }
    return this.ctx().filesDir + '/plugins/' + this.localFile;
  }

  // ---------------- 值表读写 ----------------

  /**
   * 按 key 取字段。@Builder 一律传 key（string）而不是 LoginField 对象：
   * V1 的 @Builder 按值传对象是拷贝，子结构不随状态更新（本仓库已踩过，同 PluginSettingsPage 口径）。
   */
  private fieldOf(key: string): LoginField {
    const s: LoginScheme = this.sch();
    for (let i = 0; i < s.fields.length; i++) {
      if (s.fields[i].key === key) {
        return s.fields[i];
      }
    }
    return new LoginField();
  }

  private valOf(key: string): string {
    const v: string | undefined = this.values.get(key);
    return v === undefined ? '' : v;
  }

  private putVal(key: string, v: string): void {
    this.values.set(key, v);
  }

  // ---------------- 验证码图 ----------------

  private fetchCaptcha(f: LoginField): void {
    if (f.captchaFetchFnPath.length === 0 || this.captchaBusyKey.length > 0) {
      return;
    }
    this.captchaBusyKey = f.key;
    PluginLogin.fetchCaptcha(this.uuid, f.captchaFetchFnPath).then((r: LoginResult<CaptchaImage>): void => {
      this.captchaBusyKey = '';
      if (!r.ok) {
        this.captchaFailedKeys = this.captchaFailedKeys.concat([f.key]);
        noteRaw(loginErrLogTag('验证码获取失败', r.err), r.err);
        this.toast(loginErrBrief(r.err, '验证码获取失败，请重试'));
        return;
      }
      const pm: image.PixelMap | undefined =
        (r.data === null || r.data.pixelMap === null) ? undefined : r.data.pixelMap;
      if (pm === undefined) {
        this.captchaFailedKeys = this.captchaFailedKeys.concat([f.key]);
        this.toast('验证码图片为空');
        return;
      }
      // 换引用才会重绘；旧图释放
      const next: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
      this.captchaImages.forEach((old: image.PixelMap, k: string): void => {
        next.set(k, old);
      });
      const prev: image.PixelMap | undefined = next.get(f.key);
      if (prev !== undefined) {
        this.releasePm(prev, 'captcha:' + f.key);
      }
      next.set(f.key, pm);
      this.captchaImages = next;
      // 上游取到新图就清空该字段输入（旧码对新图无意义）
      this.putVal(f.key, '');
    }).catch((e: Object): void => {
      this.captchaBusyKey = '';
      this.captchaFailedKeys = this.captchaFailedKeys.concat([f.key]);
      const raw: string = errText(e);
      noteRaw(loginErrLogTag('验证码获取异常', raw), raw);
      this.toast(loginErrBrief(raw, '验证码获取失败，请检查网络后重试'));
      Logger.ex('验证码获取异常', e);
    });
  }

  private captchaOf(key: string): image.PixelMap | undefined {
    return this.captchaImages.get(key);
  }

  private captchaFailed(key: string): boolean {
    return this.captchaFailedKeys.indexOf(key) >= 0;
  }

  // ---------------- 滑块 ----------------

  private openSlider(f: LoginField): void {
    this.sliderField = f;
    this.sliderCreateFn = f.sliderCreateFnPath;
    this.sliderVerifyFn = f.sliderVerifyFnPath;
    this.sliderOpen = true;
    this.loadSlider();
  }

  private closeSlider(): void {
    this.sliderOpen = false;
    this.sliderErr = '';
    this.sliderKnob = 0;
    this.track = [];
    this.dragBaseDx = 0;
    this.releasePm(this.sliderBg, 'sliderBg');
    this.releasePm(this.sliderPiece, 'sliderPiece');
    this.sliderBg = undefined;
    this.sliderPiece = undefined;
  }

  private loadSlider(): void {
    this.sliderLoading = true;
    this.sliderErr = '';
    this.sliderKnob = 0;
    this.track = [];
    this.dragBaseDx = 0;
    PluginLogin.createSlider(this.uuid, this.sliderCreateFn, this.values)
      .then((r: LoginResult<SliderChallenge>): void => {
        this.sliderLoading = false;
        if (!r.ok || r.data === null) {
          noteRaw(loginErrLogTag('滑块取题失败', r.err), r.err);
          this.sliderErr = loginErrBrief(r.err, '滑块验证暂不可用，请稍后重试');
          return;
        }
        const c: SliderChallenge = r.data;
        this.releasePm(this.sliderBg, 'sliderBg-old');
        this.releasePm(this.sliderPiece, 'sliderPiece-old');
        this.sliderToken = c.token;
        this.sliderBg = c.bg === null ? undefined : c.bg;
        this.sliderPiece = c.piece === null ? undefined : c.piece;
        this.sliderImageW = c.imageWidth;
        this.sliderImageH = c.imageHeight;
        this.sliderPieceY = c.pieceY;
        this.sliderPieceSize = c.pieceSize;
      })
      .catch((e: Object): void => {
        this.sliderLoading = false;
        const raw: string = errText(e);
        noteRaw(loginErrLogTag('滑块取题异常', raw), raw);
        this.sliderErr = loginErrBrief(raw, '滑块验证暂不可用，请稍后重试');
        Logger.ex('滑块取题异常', e);
      });
  }

  /** scale = 显示宽 / 原图宽（底图未测到宽先按 1，避免首帧抖动，同上游回退口径）。 */
  private sliderScale(): number {
    if (this.sliderBgW <= 0 || this.sliderImageW <= 0) {
      return 1;
    }
    return this.sliderBgW / this.sliderImageW;
  }

  private sliderMaxMove(): number {
    const s: number = this.sliderScale();
    const m: number = this.sliderBgW - this.sliderPieceSize * s;
    return m > 0 ? m : 0;
  }

  private round1(v: number): number {
    return Math.round(v * 10) / 10;
  }

  private onSliderDragStart(): void {
    this.dragBaseDx = 0;
    this.dragStartT = Date.now();
    this.track = [];
    this.track.push([0, 0, 0]);
  }

  private onSliderDragUpdate(ev: GestureEvent): void {
    if (this.sliderBg === undefined || this.dragStartT === 0) {
      return;
    }
    const raw: number = this.dragBaseDx + ev.offsetX;
    let dx: number = raw < 0 ? 0 : raw;
    const max: number = this.sliderMaxMove();
    if (max > 0 && dx > max) {
      dx = max;
    }
    this.sliderKnob = dx;
    const s: number = this.sliderScale();
    const imgX: number = this.round1(dx / s);
    // FingerInfo 没有 x/y（gesture.d.ts:592 起只有 localX/localY/globalX/globalY/displayX/displayY）
    // ⇒ 取 globalY（应用窗口内绝对 Y，语义最接近上游的 clientY）
    let y: number = 0;
    if (ev.fingerList.length > 0) {
      y = Math.round(ev.fingerList[0].globalY);
    }
    this.track.push([Date.now() - this.dragStartT, imgX, y]);
    if (this.track.length > TRACK_MAX) {
      this.track.splice(1, 1);
    }
  }

  private onSliderDragEnd(): void {
    if (this.sliderBg === undefined || this.sliderVerifyFn.length === 0) {
      return;
    }
    const s: number = this.sliderScale();
    const x: number = this.round1(this.sliderKnob / s);
    if (this.track.length < 3) {
      // 上游：轨迹点太少不上报，把手归零重来
      this.sliderKnob = 0;
      this.track = [];
      return;
    }
    const snapshot: number[][] = this.track.slice();
    this.busy = 'slider';
    PluginLogin.verifySlider(this.uuid, this.sliderVerifyFn, this.sliderToken, x, snapshot)
      .then((r: LoginResult<string>): void => {
        this.busy = '';
        const f: LoginField | null = this.sliderField;
        if (r.ok && f !== null) {
          // 上游 values[key] = pass 原文（不写死 'true'）
          this.putVal(f.key, r.data === null ? 'true' : r.data);
          this.toast('滑块验证通过');
          this.closeSlider();
          return;
        }
        noteRaw(loginErrLogTag('滑块校验未通过', r.err), r.err);
        this.sliderErr = loginErrBrief(r.err, '滑块验证未通过，请重试');
        this.sliderKnob = 0;
        this.track = [];
        // 一次一题：旧 token 作废，立刻换新题
        this.loadSlider();
      })
      .catch((e: Object): void => {
        this.busy = '';
        const raw: string = errText(e);
        noteRaw(loginErrLogTag('滑块校验异常', raw), raw);
        this.sliderErr = loginErrBrief(raw, '滑块验证未通过，请重试');
        Logger.ex('滑块校验异常', e);
        this.sliderKnob = 0;
        this.loadSlider();
      });
  }

  // ---------------- 提交 ----------------

  private onSubmit(): void {
    const s: LoginScheme | null = this.scheme;
    if (s === null || this.busy.length > 0) {
      return;
    }
    for (let i = 0; i < s.fields.length; i++) {
      const f: LoginField = s.fields[i];
      if (f.isSlider()) {
        if (this.valOf(f.key).length === 0) {
          this.toast('请先完成「' + f.label + '」验证');
          return;
        }
        continue;
      }
      if (f.required && this.valOf(f.key).trim().length === 0) {
        this.toast(f.label + ' 不能为空');
        return;
      }
    }
    this.busy = BUSY_SUBMIT;
    PluginLogin.submit(this.uuid, s.submitFnPath, this.values)
      .then((r: LoginResult<string>): void => {
        this.busy = '';
        if (r.ok) {
          this.toast(r.data === null || r.data.length === 0 ? '登录成功' : r.data);
          setTimeout((): void => {
            router.back();
          }, 900);
          return;
        }
        noteRaw(loginErrLogTag('登录提交未通过', r.err), r.err);
        this.toast(loginErrBrief(r.err, '登录失败，请检查账号或密码后重试'));
        // 上游：失败后若有验证码字段，全部刷新（旧码已作废）
        this.refreshAllCaptchas(s);
      })
      .catch((e: Object): void => {
        this.busy = '';
        const raw: string = errText(e);
        noteRaw(loginErrLogTag('登录提交异常', raw), raw);
        this.toast(loginErrBrief(raw, '登录失败，请稍后重试'));
        Logger.ex('登录提交异常', e);
        this.refreshAllCaptchas(s);
      });
  }

  private refreshAllCaptchas(s: LoginScheme): void {
    for (let i = 0; i < s.fields.length; i++) {
      const f: LoginField = s.fields[i];
      if (f.isCaptchaImage()) {
        this.fetchCaptcha(f);
      }
    }
  }

  // ---------------- 视图 ----------------

  @Builder
  SectionCard(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Theme.text2(this.isDark))
      .width('100%')
      .padding({ left: Dim.pagePadding, top: 16, bottom: 6 })
      .textAlign(TextAlign.Start)
  }

  @Builder
  FieldRow(key: string) {
    // 条件渲染只依赖 scheme（取方案后字段集合不再变）；随状态变的部分全走 @State
    if (this.fieldOf(key).isSlider()) {
      Column() {
        Text(this.fieldOf(key).label + (this.fieldOf(key).required ? ' *' : ''))
          .fontSize(13)
          .fontColor(Theme.text2(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        Row() {
          Text(this.valOf(key).length > 0 ? '已通过，点击可重新验证' : '拖动滑块完成人机验证')
            .fontSize(14)
            .fontColor(Theme.text1(this.isDark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(this.valOf(key).length > 0 ? '已验证' : '去验证 ›')
            .fontSize(13)
            .fontColor(this.valOf(key).length > 0 ? Theme.success : Theme.brand)
            .margin({ left: 8 })
        }
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .margin({ top: 6 })
        .padding({ left: 12, right: 12 })
        .backgroundColor(Theme.fillColor(this.isDark))
        .borderRadius(8)
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick(() => {
          this.openSlider(this.fieldOf(key));
        })
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .alignItems(HorizontalAlign.Start)
    }

    if (this.fieldOf(key).showsInput()) {
      Column() {
        Text(this.fieldOf(key).label + (this.fieldOf(key).required ? ' *' : ''))
          .fontSize(13)
          .fontColor(Theme.text2(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)

        if (this.fieldOf(key).isCaptchaImage()) {
          // 验证码图：点图换一张（上游 refreshText 的等价入口）
          Row() {
            if (this.captchaOf(key) !== undefined) {
              Image(this.captchaOf(key))
                .width(104)
                .height(38)
                .borderRadius(6)
                .objectFit(ImageFit.Contain)
                .onClick(() => {
                  this.fetchCaptcha(this.fieldOf(key));
                })
            } else {
              Text(this.captchaBusyKey === key ? '加载中…'
                : (this.captchaFailed(key) ? '点击重试' : '获取验证码'))
                .fontSize(13)
                .fontColor(Theme.text2(this.isDark))
                .width(104)
                .height(38)
                .textAlign(TextAlign.Center)
                .backgroundColor(Theme.fillColor(this.isDark))
                .borderRadius(6)
                .onClick(() => {
                  this.fetchCaptcha(this.fieldOf(key));
                })
            }
            Text(this.fieldOf(key).captchaRefreshText.length > 0 ? this.fieldOf(key).captchaRefreshText : '看不清？换一张')
              .fontSize(12)
              .fontColor(Theme.text3(this.isDark))
              .margin({ left: 10 })
          }
          .width('100%')
          .margin({ top: 8 })
        }

        if (this.fieldOf(key).isMultiline()) {
          TextArea({ text: this.valOf(key), placeholder: this.fieldOf(key).label })
            .fontSize(15)
            .height(88)
            .margin({ top: 6 })
            .backgroundColor(Theme.fillColor(this.isDark))
            .borderRadius(8)
            .onChange((v: string): void => {
              this.putVal(key, v);
            })
        } else {
          TextInput({ text: this.valOf(key), placeholder: this.fieldOf(key).label })
            .type(this.fieldOf(key).isPassword() ? InputType.Password : InputType.Normal)
            .fontSize(15)
            .height(44)
            .margin({ top: 6 })
            .backgroundColor(Theme.fillColor(this.isDark))
            .borderRadius(8)
            .onChange((v: string): void => {
              this.putVal(key, v);
            })
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .alignItems(HorizontalAlign.Start)
    }
  }
  /** 滑块浮层（与 pages/SettingPage.ets:313 UaOverlay 同构：一个 Stack 里遮罩与卡片是兄弟层） */
  @Builder
  SliderPanelView() {
    Stack() {
      // 遮罩层
      Column()
      .width('100%')
      .height('100%')
      .backgroundColor('rgba(0,0,0,0.45)')
      .onClick(() => {
        this.closeSlider();
      })

    Column() {
      Text('安全验证')
        .fontSize(16)
        .fontColor(Theme.text1(this.isDark))
        .width('100%')
        .textAlign(TextAlign.Start)
      if (this.sliderErr.length > 0) {
        Text(this.sliderErr)
          .fontSize(12)
          .fontColor(Theme.error)
          .margin({ top: 6 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }

      // 底图区：宽随屏、高按原图比例；拼图绝对定位在 pieceY
      Stack({ alignContent: Alignment.TopStart }) {
        if (this.sliderBg !== undefined) {
          Image(this.sliderBg)
            .width('100%')
            .aspectRatio(this.sliderImageW / (this.sliderImageH > 0 ? this.sliderImageH : 180))
            .objectFit(ImageFit.Fill)
            .onAreaChange((_o: Area, n: Area): void => {
              const w: number = Number(n.width);
              if (w > 0 && w !== this.sliderBgW) {
                this.sliderBgW = w;
              }
            })
        }
        if (this.sliderPiece !== undefined) {
          Image(this.sliderPiece)
            .width(this.sliderPieceSize * this.sliderScale())
            .height(this.sliderPieceSize * this.sliderScale())
            .objectFit(ImageFit.Contain)
            .position({ x: this.sliderKnob, y: this.sliderPieceY * this.sliderScale() })
        }
        if (this.sliderLoading) {
          Column() {
            LoadingView()
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor(Theme.maskColorFor(this.isDark))
        }
      }
      .width('100%')
      .margin({ top: 10 })

      // 把手轨道
      Stack({ alignContent: Alignment.TopStart }) {
        Row()
          .width('100%')
          .height(40)
          .backgroundColor(Theme.fillColor(this.isDark))
          .borderRadius(20)
        Text(this.sliderKnob > 0 ? this.round1(this.sliderKnob / this.sliderScale()).toFixed(0) : '')
          .fontSize(12)
          .fontColor(Theme.text3(this.isDark))
          .margin({ left: 14, top: 10 })
        Row()
          .width(40)
          .height(40)
          .backgroundColor(Theme.brand)
          .borderRadius(20)
          .position({ x: this.sliderKnob, y: 0 })
          .gesture(
            PanGesture({ direction: PanDirection.Horizontal, distance: 1 })
              .onActionStart(() => {
                this.onSliderDragStart();
              })
              .onActionUpdate((ev: GestureEvent): void => {
                this.onSliderDragUpdate(ev);
              })
              .onActionCancel((): void => {
                this.sliderKnob = 0;
              })
              .onActionEnd((): void => {
                this.onSliderDragEnd();
              })
          )
      }
      .width('100%')
      .margin({ top: 12 })

      Row() {
        Text('换一张')
          .fontSize(15)
          .fontColor(Theme.text2(this.isDark))
          .padding(10)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.loadSlider();
          })
        Blank()
        Text('取消')
          .fontSize(15)
          .fontColor(Theme.text2(this.isDark))
          .padding(10)
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick(() => {
            this.closeSlider();
          })
      }
      .width('100%')
      .margin({ top: 6 })
    }
        .width('92%')
        .padding(20)
        .backgroundColor(Theme.cardColor(this.isDark))
        .borderRadius(Dim.radius)
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }

  build() {
    Stack() {
      Column() {
        BreezeTopBar({
          title: (this.scheme !== null && this.sch().title.length > 0)
            ? this.sch().title
            : (this.pluginName.length > 0 ? this.pluginName : '账号登录'),
          showBack: true,
          scrollProgress: 1,
          // 新七条第 7 条（lead 裁定 11-12 17:00）：全站路由页统一打开 flatBackground —— 顶栏实底档与本页根容器
          // 同吃 Theme.background，消除「顶栏一块色、页面一块色」的两块皮。开关默认 false，一级页不受影响。
          flatBackground: true
        })

        if (this.loading) {
          LoadingView()
            .layoutWeight(1)
        } else if (this.loadError.length > 0 || this.scheme === null) {
          ErrorView({
            msg: this.loadError.length > 0 ? this.loadError : '该插件不支持登录',
            onRetry: (): void => {
              this.load();
            }
          })
            .layoutWeight(1)
        } else {
          Scroll() {
            Column() {
              this.SectionCard('登录信息')
              Column() {
                ForEach(this.sch().fields, (f: LoginField) => {
                  this.FieldRow(f.key)
                }, (f: LoginField) => f.key)
              }
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
              .backgroundColor(Theme.cardColor(this.isDark))
              .borderRadius(Dim.radius)
              .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

              // 会话保持的实话（PluginLogin.sessionNote 同源）
              Text(PluginLogin.sessionNote())
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
                .width('100%')
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12 })
                .textAlign(TextAlign.Start)

              Button(this.busy === BUSY_SUBMIT ? '登录中…' : this.sch().submitLabel)
                .type(ButtonType.Normal)
                .fontSize(16)
                .fontColor(Theme.white)
                .backgroundColor(this.busy === BUSY_SUBMIT ? Theme.brandPressed : Theme.brand)
                .borderRadius(Dim.radius)
                .width('100%')
                .height(48)
                .enabled(this.busy.length === 0)
                .margin({ top: 20, left: Dim.pagePadding, right: Dim.pagePadding })
                .clickEffect({ level: ClickEffectLevel.LIGHT })
                .onClick(() => {
                  this.onSubmit();
                })
            }
            .width('100%')
            .padding({ bottom: 24 })
          }
          .scrollBar(BarState.Off)
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.background(this.isDark))

      if (this.sliderOpen) {
        this.SliderPanelView()
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}
