/**
 * 职责：云收藏页体 —— 选一个插件源站，把它站端的云端收藏同步进本地书架。
 *       对应 report.txt 第 11 条（2026-11-12）：在插件内登录账号后，自动同步该源站云端收藏至本地。
 *       原先这页是 WebDAV 占位页（整页删掉重写，占位文案已无意义：上游鸿蒙端无 WebDAV 计划）。
 * 依赖：StateViews / Theme / Anim；data/cloud/CloudFavoriteSync（能力探测 + 同步）。
 *       s14 第 2 条起本页由 pages/CloudSyncPage.ets 承载（那是路由页，顶栏在那一层给）；
 *       旧的「一级 Tab 2 + 顶栏由 pages/Index.ets 统一提供」口径已被取代，用户要求云收藏不再单列页签。
 * 对应 Flutter：上游把云端收藏做成场景包直接渲染；鸿蒙端按用户口径改成「同步进本地书架」，
 *       因此本页只负责选源 + 触发 + 结果反馈，列表一律看书架（避免两份收藏两张皮）。
 * 约束：
 *  - 本页原本是 TabContent 子组件、现被 router 页 pages/CloudSyncPage 嵌入：两种宿主下 router.back 回来都不重跑
 *    aboutToAppear ⇒ 图源变化统一接 AppStorage 的 pluginSourceEpoch（bump 端 = view/plugins/PluginManagerView）。
 *  - **不接 shelfRevision 的 @Watch**（本页不是书架列表，收到版本号无事可做）；反过来同步成功后
 *    由本页推 shelfRevision，让书架页静默重查（推 = 只写 AppStorage 数字，本页不订阅 ⇒ 无回环）。
 *  - 能力探测要等数据层就绪（图源是 initDataLayer 里注册的），所以进页面先等 pluginSourceEpoch，
 *    没有就在下一次 epoch 变化时再探；绝不在 aboutToAppear 里同步阻塞式探测。
 *  - s11 第 2/3 条三条硬约束（都是真机回传逼出来的，勿改回）：
 *    ① 忙闲必须走 @State（status），**不得用私有 boolean 喂 .enabled()/.visibility()**：
 *       非状态变量的变化不触发重渲染 ⇒ 探测早就结束了，「开始同步」还停在 disabled 的旧渲染结果上
 *       = 用户看到的「同步始终为灰色，无法进行同步」。busy() 现在只读 status。
 *    ② 探测整批有上限（CloudFavoriteSync.PROBE_BATCH_MS），且探测路径零网络 ⇒ 「重新检查」不可能无限转。
 *    ③ chip 名优先插件自己 getInfo 报的名字（纯本地缓存，零网络），退清单名，再退文件名派生名
 *       = 用户看到的「bf99008d-0.0.7」是最后一档，不是插件设定的名字。
 */

import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { EmptyView } from '../common/StateViews';
import { TabAutoHide } from '../common/TabAutoHide';
import { common } from '@kit.AbilityKit';
import { CloudCapability, CloudFavoriteSync, CloudSyncResult } from '../../data/cloud/CloudFavoriteSync';
import { PLUGIN_SOURCE_PREFIX } from '../../data/source/PluginSourceAdapter';
import { PluginInfo, PluginSettings } from '../../data/source/PluginSettings';
import { Logger } from '../../util/Logger';

// 整批探测上限的权威值在 data/cloud/CloudFavoriteSync（PROBE_BATCH_MS=12000）。
// 旧版这里另有一份 40000 且全文没用到 = 「重新检查持续加载」没有上限的成因之一，s11 删掉。

// ==== 展示面脱敏与登录态指引（s12 第 3 条的界面面）begin ====
/**
 * 云收藏的失败文案直接来自插件回包，里面可能整段带上插件写进宿主持久化的账号数据
 * （真机截图实测：data 里 password 的值是明文，整段甩在页面上）。这一组只做展示面处理：
 *  - sanitizeErrText：命中凭据类键名就把它的**值**换成三个星号（键名保留，用户还要看得出
 *    是哪里出的错），其余文字一律不动；再把连续空白压成一个空格（原文是多行 JSON，逐行
 *    铺开占半屏且没有信息量），最后限长；
 *  - loginExpiredHint：原文含 unauthorized、登录过期、重新登录 时补一行可操作指引。
 * 根因（插件存进配置的标量被 JSON 字面量污染）在 util/BreezeHost.ets 侧修：本文件不判根因、
 * 不改数据，只在写进 this.message 的出口统一过一遍。
 */
/** 命中即打码其值的键名（小写比对；account 与 username 不在列，口径由派工给定）。 */
const SECRET_KEYS: string[] = [
  'password', 'passwd', 'pwd', 'token', 'jwt', 'cookie', 'set-cookie',
  'authorization', 'secret', 'apikey', 'api_key', 'access_token',
  'refresh_token', '密码'
];
/** 展示上限：那段 scheme 加 data 的原文有几百字符，占满半屏。 */
const ERR_TEXT_MAX: number = 400;
/** 超限时保留的头/尾长度：原因常落在尾部（unauthorized 就在尾段），只留头部会把原因切掉。 */
const ERR_HEAD_MAX: number = 280;
const ERR_TAIL_MAX: number = 120;
/** 触发登录态指引的关键词（小写比对）。 */
const LOGIN_KEYS: string[] = ['unauthorized', '登录过期', '重新登录'];

/** 反斜杠：多处判定要用，集中一处免得每行写转义。 */
const BSL: string = '\\';

/** 待打码区间（原文下标，左闭右开）；必须是已声明类，严格模式不认裸对象字面量。 */
class MaskSpan {
  start: number = 0;
  end: number = 0;

  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
}

/**
 * 已转小写的原文里判「单词字符」：键名两侧紧贴字母或数字就不算命中，挡掉 passwordless、
 * tokens 这类单词变形；**下划线刻意不算单词字符** —— password_md5、access_token、user_pwd
 * 这种下划线键名正是真凭据的常见写法，宁可多打码也不能漏（漏一个就是把明文留在屏幕上）。
 */
function isWordCh(ch: string): boolean {
  if (ch.length === 0) {
    return false;
  }
  if (ch >= 'a' && ch <= 'z') {
    return true;
  }
  return ch >= '0' && ch <= '9';
}

function keyStandalone(s: string, at: number, keyLen: number): boolean {
  const before: string = at === 0 ? '' : s.charAt(at - 1);
  const after: string = at + keyLen >= s.length ? '' : s.charAt(at + keyLen);
  return !isWordCh(before) && !isWordCh(after);
}

function isBlankCh(ch: string): boolean {
  return ch === ' ' || ch === '\t' || ch === '\n' || ch === '\r';
}

/** 结构化终止符：JSON 的逗号分号括号、query 的与号、中文标点（中文文案里的天然断点）。 */
function isStructStop(ch: string): boolean {
  return ch === ',' || ch === ';' || ch === '&' || ch === '}' || ch === ']'
    || ch === '，' || ch === '。' || ch === '、';
}

/** 裸值的终止符：空白或结构化终止符。引号与反斜杠**刻意不算**（否则转义值一个字符都吃不掉）。 */
function isBareStop(ch: string): boolean {
  return isBlankCh(ch) || isStructStop(ch);
}

function skipBlank(s: string, i: number): number {
  let p: number = i;
  while (p < s.length && isBlankCh(s.charAt(p))) {
    p += 1;
  }
  return p;
}

/** 从 p 往回数紧贴 p 的连续反斜杠个数（判引号是被转义过的还是真收尾）。 */
function backRun(s: string, p: number): number {
  let k: number = 0;
  while (p - 1 - k >= 0 && s.charAt(p - 1 - k) === BSL) {
    k += 1;
  }
  return k;
}

/**
 * 结构化边界，只在引号形态当兜底：多层转义时按引号找不到闭合，会一路跑到文末，
 * 把后面整段可读信息吃掉 ⇒ 那种情况退到最近的结构化边界，宁可多打码一个字段，
 * 也不把半屏原文留在屏幕上。
 */
function valueBoundary(s: string, i: number): number {
  for (let p: number = i; p < s.length; p++) {
    if (isStructStop(s.charAt(p))) {
      return p;
    }
  }
  return s.length;
}

/**
 * 从开引号之后扫到闭引号之后（含闭引号）。判闭合看反斜杠条数的奇偶：
 * 普通串里偶数条（含 0 条）之后的引号才是闭引号；被转义过一层的值相反，奇数条才算。
 */
function valueSpanQuoted(s: string, from: number, escForm: boolean): number {
  const wantOdd: boolean = escForm;
  for (let p: number = from; p < s.length; p++) {
    if (s.charAt(p) === '"') {
      const odd: boolean = backRun(s, p) % 2 === 1;
      if (odd === wantOdd) {
        return p + 1;
      }
    }
  }
  return s.length;
}

/**
 * 从值的起始下标扫到结束（不含）；返回等于入参表示这里没有值，调用方跳过这一处。
 * 三种形态都要覆盖：普通双引号串、被转义过一层或多层的引号串（真机截图正是这种）、裸值。
 */
function valueSpan(s: string, i: number): number {
  const n: number = s.length;
  if (i >= n) {
    return i;
  }
  // 值开头可能是一串反斜杠再加引号：一层转义是 1 条，套两层是 3 条，都要认
  let run: number = 0;
  while (i + run < n && s.charAt(i + run) === BSL) {
    run += 1;
  }
  if (run > 0 && s.charAt(i + run) === '"') {
    // 两侧兜底：没扫到闭合引号（返回串尾）⇒ 退到结构化边界，别把后面整段可读信息吃掉；
    // 扫到了闭合引号 ⇒ 与结构化边界**取大**。取大是防「值被 stringify 套两层时奇偶判据反掉、
    // 找到的闭合点早于值的真实结束」⇒ 星号后面漏明文。代价 = 极端情况多打码一个字段，
    // 安全侧取舍（宁可多打码，不能漏明文）。
    const q: number = valueSpanQuoted(s, i + run + 1, run % 2 === 1);
    if (q >= n) {
      return valueBoundary(s, i);
    }
    const bd: number = valueBoundary(s, i);
    return q >= bd ? q : bd;
  }
  if (s.charAt(i) === '"') {
    const q2: number = valueSpanQuoted(s, i + 1, false);
    if (q2 >= n) {
      return valueBoundary(s, i);
    }
    const bd2: number = valueBoundary(s, i);
    return q2 >= bd2 ? q2 : bd2;
  }
  let p: number = i;
  while (p < n && !isBareStop(s.charAt(p))) {
    p += 1;
  }
  if (p === i) {
    return i;
  }
  // 认证头的值本身含空格（Bearer 加一段 token）：先只吃到空格，认出这一档再往后吃到结构边界
  const head: string = s.slice(i, p).toLowerCase();
  if (head === 'bearer' || head === 'basic' || head === 'digest') {
    while (p < n && !isStructStop(s.charAt(p))) {
      p += 1;
    }
  }
  return p;
}

/** 连续空白压成一个空格并去首尾：只并空白，不删任何词。 */
function collapseBlank(s: string): string {
  const out: string[] = [];
  let needSpace: boolean = false;
  for (let i = 0; i < s.length; i++) {
    const ch: string = s.charAt(i);
    if (isBlankCh(ch)) {
      if (out.length > 0) {
        needSpace = true;
      }
      continue;
    }
    if (needSpace) {
      out.push(' ');
      needSpace = false;
    }
    out.push(ch);
  }
  return out.join('');
}

/** 限长：超长时留头留尾（原因常落在尾部，只留头会把 unauthorized 切掉），中间标出省略字数。 */
function clampErrText(text: string): string {
  if (text.length <= ERR_TEXT_MAX) {
    return text;
  }
  const omitted: number = text.length - ERR_HEAD_MAX - ERR_TAIL_MAX;
  if (omitted <= 0) {
    return text.slice(0, ERR_TEXT_MAX);
  }
  return text.slice(0, ERR_HEAD_MAX) + ' …（中间省略 ' + omitted + ' 字）… ' +
    text.slice(text.length - ERR_TAIL_MAX);
}

/**
 * 写进页面之前统一过这里：凭据值打码 → 并空白 → 限长。
 * 保守口径：只替换值、不删其他文字，unauthorized 与 message 这类可读信息一律留下
 * （登录态指引还要靠这些词判定）。
 */
function sanitizeErrText(raw: string): string {
  if (raw.length === 0) {
    return '';
  }
  const low: string = raw.toLowerCase();
  // toLowerCase 对极少数字符会改变长度，长度一变下面这些下标就对不上原文：
  // 这种情况宁可整段不打码（照样并空白与限长），也不按错位的下标去切值
  if (low.length !== raw.length) {
    return clampErrText(collapseBlank(raw));
  }
  const spans: MaskSpan[] = [];
  for (let k = 0; k < SECRET_KEYS.length; k++) {
    const key: string = SECRET_KEYS[k];
    let from: number = 0;
    // 上界 = 原文长度：每轮 from 至少前进 key.length，这个 guard 只是防呆（不依赖它终止）
    let guard: number = 0;
    while (from < low.length && guard <= low.length) {
      guard += 1;
      const at: number = low.indexOf(key, from);
      if (at < 0) {
        break;
      }
      from = at + key.length;
      if (!keyStandalone(low, at, key.length)) {
        continue;
      }
      let p: number = at + key.length;
      // 键名尾巴（下划线续接的部分，如 password_md5 的 _md5）一起吃掉再判分隔符
      while (p < low.length && (low.charAt(p) === '_' || isWordCh(low.charAt(p)))) {
        p += 1;
      }
      // 再吃键名自己的收尾引号（转义形态是好几条反斜杠加引号），才认得到后面的冒号或等号
      if (low.charAt(p) === '"') {
        p += 1;
      } else if (low.charAt(p) === BSL) {
        const rb: number = backRun(low, p + 1);
        if (rb > 0 && p + rb < low.length && low.charAt(p + rb) === '"') {
          p += rb + 1;
        }
      }
      p = skipBlank(low, p);
      const sep: string = low.charAt(p);
      if (sep !== ':' && sep !== '=' && sep !== '：') {
        continue;
      }
      const vs: number = skipBlank(low, p + 1);
      const ve: number = valueSpan(low, vs);
      if (ve > vs) {
        spans.push(new MaskSpan(vs, ve));
      }
    }
  }
  spans.sort((a: MaskSpan, b: MaskSpan): number => a.start - b.start);
  const parts: string[] = [];
  let cursor: number = 0;
  for (let i = 0; i < spans.length; i++) {
    const sp: MaskSpan = spans[i];
    if (sp.start < cursor) {
      // 与上一段重叠（cookie 也会命中 set-cookie 的尾巴）：跳过，不重复打码
      continue;
    }
    if (sp.start > cursor) {
      parts.push(raw.slice(cursor, sp.start));
    }
    parts.push('***');
    cursor = sp.end;
  }
  if (cursor < raw.length) {
    parts.push(raw.slice(cursor));
  }
  return clampErrText(collapseBlank(parts.join('')));
}

/**
 * 登录态失效时补一行可操作指引。**只给文案**：不调登录、不加跳转（登录页路由参数不归本页）。
 * 文案不硬编码插件名；who 传当前选中源的展示名，拿不到就走通用路径描述。
 */
function loginExpiredHint(raw: string, who: string): string {
  if (raw.length === 0) {
    return '';
  }
  const low: string = raw.toLowerCase();
  let hit: boolean = false;
  for (let i = 0; i < LOGIN_KEYS.length; i++) {
    if (low.indexOf(LOGIN_KEYS[i]) >= 0) {
      hit = true;
      break;
    }
  }
  if (!hit) {
    return '';
  }
  const path: string = who.length > 0
    ? ('更多 - 插件管理 - ' + who + ' - 账号登录')
    : '更多 - 插件管理 - 对应插件 - 账号登录';
  return '这一步不用重试：该源站的登录态已失效，请到「' + path + '」重新登录，再回来同步。';
}
// ==== 展示面脱敏与登录态指引（s12 第 3 条的界面面）end ====

export class CloudPageStatus {
  static readonly IDLE: string = 'idle';
  static readonly PROBING: string = 'probing';
  static readonly SYNCING: string = 'syncing';
  static readonly DONE: string = 'done';
  static readonly FAILED: string = 'failed';
}

@Component
export struct CloudPage {
  onRequestTab: (index: number) => void = (index: number) => {};

  @StorageProp('isDark') isDark: boolean = false;
  /** 图源变化（安装/删除/开关/装载）⇒ 清探测缓存重探。 */
  @StorageProp('pluginSourceEpoch') @Watch('onSourceEpoch') pluginEpoch: number = 0;

  /** 支持云收藏的源站（探测结果，顺序 = 图源表顺序）。 */
  @State caps: CloudCapability[] = [];
  @State sourceIndex: number = 0;
  @State status: string = CloudPageStatus.IDLE;
  /** 结果/错因文案（失败也走它，页内常驻显示，不靠 toast 一闪而过）。 */
  @State message: string = '';
  /**
   * 失败时的可操作指引（只在命中登录态判据时非空）。**必须是 @State**：它直接喂 Text，
   * 非状态变量的变化不触发重渲染（s11 那个按钮永远灰 = 同族坑）。
   */
  @State failedHint: string = '';
  /** 同步中的实时条数。 */
  @State liveCount: number = 0;

  /** s10 第 11 条：纵向内容区绑 scroller —— Scroll.onDidScroll 只给每帧增量，判方向要读累计偏移。 */
  private bodyScroller: Scroller = new Scroller();

  /**
   * 在途闸门：**必须是普通字段**（防止 TabContent 反复进出时并发发起），
   * 但它绝不参与 UI 判定 —— UI 只看 @State status（见文件头约束①）。
   */
  private probing: boolean = false;
  /** 同上：同步在途闸门，不参与 UI 判定。 */
  private syncing: boolean = false;
  /** chip 展示名（key = sourceId）：插件 getInfo 的本地缓存名优先。 */
  private displayNames: Map<string, string> = new Map<string, string>();

  aboutToAppear(): void {
    // T1：登记本页滚动容器（页索引 2 = 云收藏）；纵向 Scroll 在 if 分支里可能晚于此处挂载，
    // 故挂载处再补一次 attach（attach 内部按 scroller 去重，重复调用无副作用）。
    TabAutoHide.attach(TabAutoHide.IDX_CLOUD, this.bodyScroller);
    this.detect();
  }

  private onSourceEpoch(): void {
    // 插件装卸 ⇒ 能力可能凭空出现或消失，缓存必须作废。
    CloudFavoriteSync.forgetProbes();
    this.detect();
  }

  /** 忙闲口径 = @State status（**不看私有 boolean**，理由见文件头约束①）。 */
  private busy(): boolean {
    return this.status === CloudPageStatus.PROBING || this.status === CloudPageStatus.SYNCING;
  }

  /** chip 展示名：本地缓存的 getInfo.name → 清单名 → 文件名派生名（第三档 = 真机截图那种）。 */
  private nameOf(cap: CloudCapability): string {
    const hit: string | undefined = this.displayNames.get(cap.sourceId);
    if (hit !== undefined && hit.length > 0) {
      return hit;
    }
    return cap.name;
  }

  private cur(): CloudCapability | null {
    if (this.sourceIndex < 0 || this.sourceIndex >= this.caps.length) {
      return null;
    }
    return this.caps[this.sourceIndex];
  }

  /** 探测所有插件源站的云收藏能力（结果只保留 supported 的）。 */
  private async detect(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    this.status = CloudPageStatus.PROBING;
    this.failedHint = '';
    this.message = '';
    try {
      const all: CloudCapability[] = await CloudFavoriteSync.listCapabilities();
      const ok: CloudCapability[] = [];
      let pending: number = 0;
      for (let i = 0; i < all.length; i++) {
        if (all[i].supported) {
          ok.push(all[i]);
        } else if (all[i].via === 'pending' || all[i].via === 'timeout') {
          // 两种「这次没答上」：整批到点仍是占位（pending）、单源声明读取超时（timeout）。
          // 都不等于「不支持」：本轮不显示，但文案要说清楚，否则用户以为插件装少了，
          // 而且这两类下次「重新检查」还会再探（timeout 不进缓存）。
          pending += 1;
        }
      }
      Anim.to((): void => {
        this.caps = ok;
        this.sourceIndex = 0;
        this.status = CloudPageStatus.IDLE;
        if (pending > 0) {
          this.message = '还有 ' + pending + ' 个插件没及时回应，可点「重新检查」再看一次。';
          this.failedHint = '';
        }
      }, Anim.contentIn, Anim.curveEaseOut());
      Logger.i('云收藏能力探测：支持 ' + ok.length + '/' + all.length + ' 个插件源，未回应 ' + pending + ' 个');
      // 名字解析排在状态落回之后：chip 先按清单名出现，本地缓存名到了再换（不发网络，基本同一帧）。
      await this.resolveNames(ok);
    } catch (err) {
      Logger.ex('云收藏能力探测异常', err as Object);
      this.status = CloudPageStatus.FAILED;
      // 探测异常的原文同样可能带插件配置（探测里要读插件设置）⇒ 同一口径先脱敏再上屏；
      // 探测阶段没有选中源，指引只能给通用路径
      this.message = sanitizeErrText((err as Error).message);
      this.failedHint = loginExpiredHint((err as Error).message, '');
    } finally {
      this.probing = false;
      // 兜底：status 仍停在 PROBING 说明上面两条路都没落回（极端：Anim.to 未执行）。
      // status 是唯一忙闲口径，卡在这里 = 同步按钮永久灰 = 真机回传的第三条。
      if (this.status === CloudPageStatus.PROBING) {
        this.status = CloudPageStatus.IDLE;
      }
    }
  }

  /**
   * 读每个源插件 getInfo 的**本地缓存**名字（PluginSettings.cachedInfo 纯读 preferences，零网络零装载）。
   * 缓存里没有就不写，chip 继续用清单名/文件名派生名 —— 绝不为了名字去现调 getInfo（那要走网络）。
   */
  private async resolveNames(caps: CloudCapability[]): Promise<void> {
    if (caps.length === 0) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    let changed: boolean = false;
    for (let i = 0; i < caps.length; i++) {
      const sid: string = caps[i].sourceId;
      if (sid.indexOf(PLUGIN_SOURCE_PREFIX) !== 0) {
        continue;
      }
      try {
        const info: PluginInfo = await PluginSettings.cachedInfo(ctx, sid.slice(PLUGIN_SOURCE_PREFIX.length));
        if (info.name.length > 0 && info.name !== caps[i].name) {
          this.displayNames.set(sid, info.name);
          changed = true;
        }
      } catch (e) {
        Logger.d('云收藏读插件缓存名失败 ' + sid);
      }
    }
    if (changed) {
      // Map 不是状态变量：靠重排 caps 触发 ForEach 重渲染（key 里带上名字，见 build）。
      this.caps = caps.slice();
    }
  }

  /** 上次同步情况（一句话；从未同步返回空串）。 */
  private lastLine(): string {
    const c: CloudCapability | null = this.cur();
    if (c === null) {
      return '';
    }
    const at: number = CloudFavoriteSync.lastSyncAt(c.sourceId);
    const n: number = CloudFavoriteSync.lastSyncCount(c.sourceId);
    if (at <= 0) {
      return '';
    }
    const d: Date = new Date(at);
    const mm: string = (d.getMonth() + 1) < 10 ? '0' + (d.getMonth() + 1) : String(d.getMonth() + 1);
    const dd: string = d.getDate() < 10 ? '0' + d.getDate() : String(d.getDate());
    const hh: string = d.getHours() < 10 ? '0' + d.getHours() : String(d.getHours());
    const mi: string = d.getMinutes() < 10 ? '0' + d.getMinutes() : String(d.getMinutes());
    return '上次同步 ' + mm + '-' + dd + ' ' + hh + ':' + mi + '，共 ' + (n < 0 ? '未知' : String(n)) + ' 条';
  }

  /** 触发同步。 */
  private async doSync(): Promise<void> {
    if (this.syncing) {
      return;
    }
    const c: CloudCapability | null = this.cur();
    if (c === null) {
      return;
    }
    this.syncing = true;
    this.status = CloudPageStatus.SYNCING;
    this.liveCount = 0;
    this.failedHint = '';
    this.message = '';
    try {
      const res: CloudSyncResult = await CloudFavoriteSync.sync(c.sourceId,
        (done: number, pages: number): void => {
          this.liveCount = done;
        });
      if (res.ok) {
        const tail: string = res.reachedEnd ? '' : '（已达本次上限，可再点一次继续）';
        this.status = CloudPageStatus.DONE;
        this.message = '已同步 ' + res.synced + ' 条到书架，其中新增 ' + res.added + ' 条' + tail;
        this.failedHint = '';
        // 书架页靠 AppStorage 'shelfRevision' 静默重查（同 DetailPage 加/移书架的口径）：真新增了才推。
        if (res.added > 0) {
          const cur: number = AppStorage.get<number>('shelfRevision') ?? 0;
          AppStorage.setOrCreate<number>('shelfRevision', cur + 1);
        }
      } else {
        this.status = CloudPageStatus.FAILED;
        // 未登录等插件自抛的中文提示原样透出，不加前缀（用户要看到插件自己的话）；
        const why: string = res.err.length > 0 ? res.err : '同步失败';
        // 原文里可能整段带插件账号与明文密码（真机截图实测）⇒ 必须先过 sanitizeErrText
        this.message = sanitizeErrText(why);
        this.failedHint = loginExpiredHint(why, this.nameOf(c));
      }
    } catch (err) {
      this.status = CloudPageStatus.FAILED;
      // 原文同样可能是插件自抛的整段回包 ⇒ 与失败出口同一口径：先脱敏再上屏
      this.message = sanitizeErrText((err as Error).message);
      this.failedHint = loginExpiredHint((err as Error).message, this.nameOf(c));
      Logger.ex('云收藏同步按钮异常', err as Object);
    } finally {
      this.syncing = false;
    }
  }

  private statusText(): string {
    if (this.status === CloudPageStatus.PROBING) {
      return '正在检查各插件是否支持云端收藏…';
    }
    if (this.status === CloudPageStatus.SYNCING) {
      return this.liveCount > 0 ? ('正在同步…已写入 ' + this.liveCount + ' 条') : '正在从站端拉取收藏…';
    }
    return this.message;
  }

  @Builder
  SourceChip(i: number) {
    Text(this.nameOf(this.caps[i]))
      .fontSize(13)
      .fontColor(this.sourceIndex === i ? Theme.white : Theme.text1(this.isDark))
      .backgroundColor(this.sourceIndex === i ? Theme.brand : Theme.fillColor(this.isDark))
      .borderRadius(Dim.radius)
      .height(32)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .maxLines(1)
      .textAlign(TextAlign.Center)
      .onClick((): void => {
        if (this.sourceIndex !== i) {
          Anim.to((): void => {
            this.sourceIndex = i;
            this.message = '';
            this.failedHint = '';
            this.status = CloudPageStatus.IDLE;
          }, Anim.contentIn, Anim.curveEaseOut());
        }
      })
  }

  build() {
    Column() {
      if (this.probing && this.caps.length === 0) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(Theme.brand)
          Text('正在检查各插件是否支持云端收藏…')
            .fontSize(14)
            .fontColor(Theme.text2(this.isDark))
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.caps.length === 0) {
        Column() {
          EmptyView({
            text: '还没有插件支持云端收藏',
            hint: '去「更多 - 插件管理」安装或启用带云端收藏的图源插件（如绅士漫画、拷贝漫画、哔咔漫画），并在插件设置里登录账号后回到本页。已安装但不支持的插件不会出现在这里。'
          })
            .layoutWeight(1)
          Button('重新检查')
            .fontSize(14)
            .fontColor(Theme.brand)
            .backgroundColor(Theme.fillColor(this.isDark))
            .height(40)
            .borderRadius(20)
            .padding({ left: 20, right: 20 })
            .margin({ bottom: Dim.contentBottomReserve })
            .onClick((): void => {
              CloudFavoriteSync.forgetProbes();
              this.detect();
            })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        // 源站选择条（与发现页图源条同款 chip，横向滚动）
        Scroll() {
          Row() {
            ForEach(this.caps, (item: CloudCapability, index: number) => {
              this.SourceChip(index);
            }, (item: CloudCapability) => item.sourceId + '|' + this.nameOf(item))
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(44)

        Scroll(this.bodyScroller) {
          Column() {
            Text('把所选源站账号里的云端收藏同步进本地书架')
              .fontSize(14)
              .fontColor(Theme.text1(this.isDark))
              .width('100%')
              .textAlign(TextAlign.Start)
            Text('同步只做单向（站端 → 本地）；已在书架的保持原加入时间，不会打乱书架排序。')
              .fontSize(12)
              .fontColor(Theme.text3(this.isDark))
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: 6 })

            if (this.lastLine().length > 0) {
              Text(this.lastLine())
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
                .width('100%')
                .textAlign(TextAlign.Start)
                .margin({ top: 10 })
            }

            Button(this.status === CloudPageStatus.SYNCING ? '同步中…' : '开始同步')
              .fontSize(15)
              .fontColor(Theme.white)
              .backgroundColor(this.busy() ? Theme.text3(this.isDark) : Theme.brand)
              .height(44)
              .borderRadius(22)
              .width('100%')
              .margin({ top: 18 })
              .enabled(!this.busy())
              .onClick((): void => {
                this.doSync();
              })

            if (this.statusText().length > 0) {
              Text(this.statusText())
                .fontSize(13)
                .fontColor(this.status === CloudPageStatus.FAILED ? Theme.warning : Theme.text2(this.isDark))
                .width('100%')
                .textAlign(TextAlign.Start)
                .margin({ top: 12 })
            }

            // 登录态失效另起一行可操作指引：原文只有 unauthorized 这类词，用户不知道下一步做什么
            if (this.failedHint.length > 0) {
              Text(this.failedHint)
                .fontSize(13)
                .fontColor(Theme.brand)
                .width('100%')
                .textAlign(TextAlign.Start)
                .margin({ top: 8 })
            }

            if (this.status === CloudPageStatus.DONE) {
              Button('去书架查看')
                .fontSize(14)
                .fontColor(Theme.brand)
                .backgroundColor(Theme.fillColor(this.isDark))
                .height(40)
                .borderRadius(20)
                .margin({ top: 12 })
                .onClick((): void => {
                  this.onRequestTab(0);
                })
            }

            if (this.status === CloudPageStatus.FAILED) {
              Button('重试')
                .fontSize(14)
                .fontColor(Theme.brand)
                .backgroundColor(Theme.fillColor(this.isDark))
                .height(40)
                .borderRadius(20)
                .margin({ top: 12 })
                .onClick((): void => {
                  this.doSync();
                })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12 })
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .layoutWeight(1)
        .contentEndOffset(Dim.contentBottomReserve)
        // T1：Scroll.onDidScroll 只给每帧增量（scroll.d.ts:1400）⇒ 读 scroller 累计偏移喂给 TabAutoHide 判方向
        .onDidScroll((_offset: number, state: ScrollState) => {
          TabAutoHide.onScroll(TabAutoHide.IDX_CLOUD, this.bodyScroller.currentOffset().yOffset, state);
        })
        // T1：本页 Scroll 在 if 分支里，可能晚于 aboutToAppear 那次 attach ⇒ 挂载后补一次联动登记
        .onAppear(() => {
          TabAutoHide.flush();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
