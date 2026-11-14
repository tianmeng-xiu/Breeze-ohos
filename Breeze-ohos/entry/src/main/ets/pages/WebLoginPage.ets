/**
 * 职责：插件自报「前往网页登录」时宿主开的内嵌登录页（s15 第 8 条，用户 11-13 拍板做全套）。
 * 契约来自插件自己：能力动作（如 eh 的 startEhentaiWebLogin）回 accepted / openUrl / setCookieFnPath /
 * cookiePollIntervalMs / ignoreCookieNames / action（type = openWeb，payload 带 title 与 url）/ message，
 * ⇒ 宿主负责「开页 → 摘 cookie → 回传插件 setter → 关页」，插件负责把 cookie 写进自己的存储。
 * 依赖：BreezeTopBar、Theme/Dim（../view/common）、util/PluginRuntime.bundleCall（与设置页能力动作同一条通道）、
 *   util/JsonUtil、@kit.ArkWeb（Web 组件 + WebCookieManager）、@kit.ArkUI（router）。
 *
 * ===== 四条设计裁定（为什么长这样，别再改回去）=====
 * 1) **能力动作只调一次，在设置页调**。本页不发能力动作：所有参数（url / 标题 / 回传目标 fnPath /
 *    节拍 / 名单）由调用方从那次唯一的返回里取好、经 WebLoginParams 传进来。理由 = 若本页再探一次，
 *    同一条动作会被调两遍；对「清理会话」这类有副作用的动作，重复调用就是重复执行（本插件恰好无副作用，
 *    但分发器不能按「这一家恰好安全」写）。⇒ 本页对插件只有一个调用 = 回传 setter。
 * 2) **整站 cookie 原样交回，不在这里过滤**：插件 setter 内部自己会剥 cf_clearance 与 igneous（它自带
 *    名单与 cookie 头解析），宿主重复过滤 = 两处名单要同步维护。本页的 ignoreCookieNames 名单
 *    只用于决定何时算就绪（必需键齐不齐），不用于裁剪回传内容。
 * 3) **节拍与终局**：插件给的 cookiePollIntervalMs = 500000（8 分 20 秒）不能照抄当唯一节拍（用户等不到）。
 *    本页 = onControllerAttached / onPageEnd / onTitleReceive / 用户点一次按钮 四种时机各摘一次 +
 *    5 秒固定节拍兜底 + 整页硬上限 5 分钟。插件给的间隔只在「比兜底节拍更密且不超过整页上限」时才采纳。
 *    到点只停自动检测并提示可手动摘取，**不判失败** —— s11 异步探测三原则第 3 条：「这次没等到」与
 *    「确实没有」必须分档，timeout 绝不写进任何结果缓存。
 * 4) **底色 flatBackground 统一**（lead 11-13 重申 s11 裁定）：本页是路由页 ⇒ 顶栏 flatBackground: true、
 *    根容器 Theme.background(isDark)，与全站九页同一个令牌；深色下不留系统默认底。
 *
 * ===== Cookie 是真实凭据：值只在三个局部变量里流动（§53.2 那次泄露就是从真机回传内容抄进注释起的）=====
 * collect 内 const raw（fetchCookieSync 的返回）→ pushCookie 入参 raw → 同函数内 const env.value →
 * JSON.stringify 成 const args 交给插件。四条硬约束：本页没有任何 cookie 成员字段、不进 @State、
 * 不进 Logger / toast / 状态文案 / 注释、不落盘（不落 preferences、不落文件、不进诊断面板）。
 * 状态文案只可能出现「几枚」与「还缺哪几个键名」—— 键名是协议常量（ipb_member_id 这类）可上屏，值不可。
 *
 * 唯一真实风险 = CF 盾在应用内 WebView 里不一定过得了（已向用户说明）。⇒ 页底常驻一行兜底指引
 * （不是错误条、不随状态消失），手动填写项在登录页与设置页都可达（带 fnPath 的字段刻意不隐藏）
 * ⇒ 过不了也不会白屏、不会走进死路。
 */

import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { GlassStyle } from '../view/common/GlassStyle';
import { bundleCall } from '../util/PluginRuntime';
import { jstr, jbool, jparse, jobj, jhas, jisEmpty } from '../util/JsonUtil';
import { WebLoginParams, readWebLoginParams } from '../data/source/WebLogin';

/** 固定兜底节拍：与插件给的间隔无关（详见文件头 3）。 */
const TICK_MS: number = 5000;
/** 整页硬上限：到点停自动检测、提示手动摘取，不判失败。 */
const DEADLINE_MS: number = 300000;
/** 成功后延时关页：让「已回传」那一帧看得见。 */
const CLOSE_DELAY_MS: number = 900;
/** 就绪必需键的兜底档：插件 setter 缺这两个键必然回「请填写 ipb_member_id 与 ipb_pass_hash」。 */
const REQUIRED: string[] = ['ipb_member_id', 'ipb_pass_hash'];
/** 会话类 cookie 默认名单（插件没给 ignoreCookieNames 时兜底）：CF 每次校验换一次的串，不是账号凭据。 */
const DEFAULT_IGNORE: string[] = ['cf_clearance'];
/** 状态机取值（唯一权威 = @State status）。 */
const ST_WORKING: string = 'working';
const ST_DONE: string = 'done';
const ST_LIMIT: string = 'limit';
const ST_FAILED: string = 'failed';
/** 摘取来源：事件驱动 / 固定节拍 / 用户手点，三档共用同一段取 cookie 逻辑（差别只在失败时说得多详细）。 */
const SRC_EVENT: string = 'event';
const SRC_TICK: string = 'tick';
const SRC_MANUAL: string = 'manual';
/** 回传用的键名：插件 setter 的 cookie 分支判据是 key 为 forumCookie / cookie / 空 三者之一。 */
const COOKIE_KEY: string = 'cookie';
/**
 * 路由参数类 WebLoginParams 与取回函数 readWebLoginParams 都在 data/source/WebLogin.ets（s16 第 3 条搬走）。
 * 原因：本类被 pages/PluginSettingsPage 反向 import，过去却声明在本文件（一枚 @Entry 页面）里
 * ⇒ 类身份不一致 ⇒ 落地页 instanceof 判假 ⇒ 整段参数赋值静默跳过（s16 根因，别再搬回来）。
 */

/**
 * 回传信封 {key, value, extern} —— 形状按插件 setter 的解析逐字对齐（它先取 key 与 value，再取 extern）。
 * 必须用类：ArkTS 严格模式 10605038 禁止用对象字面量当结构化值 ⇒ 声明类 + 逐字段赋值。
 * extern 带默认值 = 调用点自动符合入参契约（§24：插件永远收到恰好一个对象参数且必带 extern 键）。
 * ⚠ value 装真实 cookie：赋出去就转发走，不复制第二份、不落成员、不进日志。
 */
class CookieEnvelope {
  key: string = COOKIE_KEY;
  value: string = '';
  extern: ESObject = JSON.parse('{}');
}

@Entry
@Component
struct WebLoginPage {
  @StorageProp('isDark') isDark: boolean = false;
  /** 底部导航条避让（s17 第 4 条）：窗口 layout-full-screen ⇒ 底部操作区自己加，口径同 BreezeBottomTab。 */
  @StorageProp('bottomSafeHeight') bottomSafe: number = 0;
  /** 顶栏标题（动作返回的 payload.title，缺省「网页登录」）。 */
  @State title: string = '网页登录';
  /** 状态机：working / done / limit / failed。参与 UI 判定 ⇒ 必须 @State（s11 真机踩过：读私有字段不重渲染）。 */
  @State status: string = ST_WORKING;
  /** 状态副文案：只会含「几枚 / 还缺哪些键名」，永不含值。 */
  @State detail: string = '';
  /** 已取到的 cookie 枚数（去掉会话类之后），仅用于展示与自证。 */
  @State cookieCount: number = 0;
  /** 要加载的地址：入参给的就直接用（本页不再探动作）。 */
  @State webSrc: string = '';
  /** Web 控制器是否已挂上：挂上前取 cookie 无意义。参与按钮 enabled ⇒ @State。 */
  @State attached: boolean = false;
  /** 回传进行中标记：参与按钮文案与 enabled ⇒ @State。 */
  @State probing: boolean = false;

  private uuid: string = '';
  /** 回传目标 fnPath；空 = 不知该回传给谁 ⇒ 不摘 cookie（摘了也没人收）。 */
  private target: string = '';
  /** 就绪必需键（入参优先，否则兜底档）。 */
  private required: string[] = REQUIRED;
  /** 会话类名单（入参优先，否则兜底档）。 */
  private ignored: string[] = DEFAULT_IGNORE;
  /** 取 cookie 的作用域：只取 origin（scheme + 主机名），带查询串会取不到。 */
  private watchOrigin: string = '';
  private ctrl: webview.WebviewController = new webview.WebviewController();
  /** 实际生效的检测周期：默认兜底节拍，插件给的值更密才换（adoptInterval）。 */
  private intervalMs: number = TICK_MS;
  private tickTimer: number = -1;
  private deadlineTimer: number = -1;
  private closeTimer: number = -1;
  /** 并发闸门（与 @State probing 两条各管一事：这条防重入，那条管渲染）。 */
  private inflight: boolean = false;
  /** 终局标记：成功回传过就不再摘。 */
  private finished: boolean = false;
  /** 上一次自动回传时的键名签名：签名不变不重复写插件存储（手动按钮不受限）。 */
  private lastSig: string = '';

  aboutToAppear(): void {
    try {
      const raw: Object = router.getParams();
      // s16 第 3 条：读回走 readWebLoginParams —— 实例原样返回；类身份对不上（过去那种情况）时按普通对象逐字段取
      const q: WebLoginParams = readWebLoginParams(raw);
      this.uuid = q.uuid;
      if (q.setTitle.length > 0) {
        this.title = q.setTitle;
      }
      this.webSrc = q.openUrl;
      this.target = q.setCookieFnPath;
      if (q.requiredNames.length > 0) {
        this.required = q.requiredNames;
      }
      if (q.ignoreCookieNames.length > 0) {
        this.ignored = q.ignoreCookieNames;
      }
      this.detail = q.message.length > 0 ? q.message : '请在上方页面完成登录，本页会自动检测登录结果。';
      this.adoptInterval(q.pollIntervalMs);
      if (this.webSrc.length === 0) {
        // 地址为空时只说「本次没拿到」：丢参数可能是宿主侧的事，说「插件没有给出」会错怪插件（lead 11-13 要求）
        this.detail = (q.message.length > 0 ? q.message + '。' : '')
          + '本次没拿到登录地址，可以直接返回设置页重试一次，或改用手动填写项。';
      }
    } catch (e) {
      // 参数拿不到也要能显示页面：底下兜底指引仍然指向手动填写项，不会白屏（文件头最后一段）
      this.detail = '本次没拿到登录地址（跳转参数读取失败）。可以返回设置页重试一次，或改用手动填写项。';
    }
    this.watchOrigin = this.originOf(this.webSrc);
    this.startTick();
  }

  aboutToDisappear(): void {
    // 生命周期红线：三个定时器必须在这里清干净。Web 是节点，随页面卸载销毁，不手工持有。
    this.finished = true;
    this.stopTimers();
  }
  /** 状态主文案（读 @State status ⇒ 状态变即重渲染）。 */
  private statusText(): string {
    if (this.status === ST_DONE) {
      return '登录凭据已回传插件';
    }
    if (this.status === ST_LIMIT) {
      return '等待超时，已停止自动检测';
    }
    if (this.status === ST_FAILED) {
      return '回传没有成功';
    }
    return '正在等待登录结果';
  }

  /** 状态点颜色：四档各一色，全部走 Theme 既有令牌（不新造色值）。 */
  private dotColor(): string {
    if (this.status === ST_DONE) {
      return Theme.success;
    }
    if (this.status === ST_FAILED) {
      return Theme.error;
    }
    if (this.status === ST_LIMIT) {
      return Theme.warning;
    }
    return Theme.brand;
  }

  /** 手动摘取可用 = 已知回传目标 + 控制器已挂上 + 未终局 + 当前没在回传。 */
  private canPick(): boolean {
    return this.target.length > 0 && this.attached && !this.probing && !this.finished;
  }

  /** 取 origin（scheme + 主机名）：cookie 作用域带查询串会取不到，所以先剥到主机名。 */
  private originOf(url: string): string {
    const i: number = url.indexOf('://');
    if (i <= 0) {
      return '';
    }
    let end: number = url.length;
    for (let k: number = i + 3; k < url.length; k = k + 1) {
      const c: string = url.charAt(k);
      if (c === '/' || c === '?' || c === '#') {
        end = k;
        break;
      }
    }
    return url.substring(0, end);
  }

  /**
   * 从 cookie 串里**只取键名**（会话类已剔除）。这是值离开局部变量的唯一中间站：
   * 返回值里只有名字 ⇒ 上屏与状态文案因此天然不可能带出凭据。
   */
  private cookieNames(raw: string): string[] {
    const out: string[] = [];
    if (raw.length === 0) {
      return out;
    }
    const parts: string[] = raw.split(';');
    for (let i: number = 0; i < parts.length; i = i + 1) {
      const one: string = parts[i].trim();
      const eq: number = one.indexOf('=');
      if (eq <= 0) {
        continue;
      }
      const name: string = one.substring(0, eq).trim();
      if (name.length === 0 || this.isIgnored(name)) {
        continue;
      }
      out.push(name);
    }
    return out;
  }

  /** 会话类名单命中（大小写不敏感）：这类每次人机校验换一次，不参与就绪判定。 */
  private isIgnored(name: string): boolean {
    const low: string = name.toLowerCase();
    for (let i: number = 0; i < this.ignored.length; i = i + 1) {
      if (this.ignored[i].toLowerCase() === low) {
        return true;
      }
    }
    return false;
  }

  /** 缺哪些必需键 ⇒ 顿号拼串（只有键名）。全齐返回空串。 */
  private missingOf(names: string[]): string {
    const miss: string[] = [];
    for (let i: number = 0; i < this.required.length; i = i + 1) {
      if (names.indexOf(this.required[i]) < 0) {
        miss.push(this.required[i]);
      }
    }
    return miss.join('、');
  }

  /**
   * 采纳插件给的间隔：只在「比兜底节拍更密」且「明显小于整页上限」时换掉兜底节拍。
   * 超大值（eh 给 500000）不换 = 等它等于永远不等；比 TICK_MS 更密也不换 = cookie 是敏感数据，
   * 取一次是一次同步 IO，没必要更密。
   */
  private adoptInterval(iv: number): void {
    if (iv > TICK_MS && iv < DEADLINE_MS) {
      this.intervalMs = iv;
    }
  }

  /** 起自动检测：节拍 + 终局闹钟，各只挂一次（幂等）。 */
  private startTick(): void {
    if (this.finished) {
      return;
    }
    if (this.tickTimer < 0) {
      this.tickTimer = setInterval((): void => {
        this.collect(SRC_TICK);
      }, this.intervalMs);
    }
    if (this.deadlineTimer < 0) {
      this.deadlineTimer = setTimeout((): void => {
        this.deadlineTimer = -1;
        this.onDeadline();
      }, DEADLINE_MS);
    }
  }

  /** 停自动检测：三个定时器一次收干净（页面卸载、成功、返回都走这里，可重复调用）。 */
  private stopTimers(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    if (this.deadlineTimer >= 0) {
      clearTimeout(this.deadlineTimer);
      this.deadlineTimer = -1;
    }
    if (this.closeTimer >= 0) {
      clearTimeout(this.closeTimer);
      this.closeTimer = -1;
    }
  }

  /** 终局：只停自动检测并说清「还能手动摘」，**不判失败**（文件头 3）。 */
  private onDeadline(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
    if (this.finished || this.status === ST_DONE) {
      return;
    }
    this.status = ST_LIMIT;
    this.detail = '已停止自动检测。如果你已经在页面里登录完成，点下面的按钮手动摘取一次即可。';
  }
  /**
   * 摘一次 cookie。src 只用来分「事件 / 节拍 / 手点」三档，行为一致（差别只在失败时说得多详细）。
   *
   * Cookie 值流动（审计点 1/2）：下面 const raw 是本页第一个也是唯一持有值的变量。
   * 两个失败档必须分开（s11 三原则）：
   *  A 档 = 取不到（fetchCookieSync 抛 17100002 = 该作用域还没有 cookie）⇒ 正常中间态，继续等；
   *  B 档 = 取到了但必需键不齐 ⇒ 报缺哪些键名，继续等。
   * 两档都不写任何缓存：下一个事件或节拍会重新取，「这次没等到」不会被记成「不支持」。
   */
  private collect(src: string): void {
    if (this.finished || this.inflight) {
      return;
    }
    // 三前置：知道回传给谁、控制器已挂上、作用域算得出来 —— 少一个都不必取值
    if (this.target.length === 0 || !this.attached || this.watchOrigin.length === 0) {
      return;
    }
    this.inflight = true;
    let raw: string = '';
    try {
      // 用 fetchCookieSync：getCookie 自 API 11 起 deprecated（webview.d.ts:1089 → :1110）
      raw = webview.WebCookieManager.fetchCookieSync(this.watchOrigin);
    } catch (e) {
      // 17100002（该作用域无 cookie）走这条路：属正常中间态。只按来源档说话，不记值、不判失败
      this.inflight = false;
      this.cookieCount = 0;
      if (src === SRC_MANUAL) {
        this.status = ST_FAILED;
        this.detail = '这个页面作用域里还没有 cookie。请先在上方页面完成登录（登录成功后站点才会下发凭据），再点一次。';
      }
      return;
    }
    const names: string[] = this.cookieNames(raw);
    this.cookieCount = names.length;
    const miss: string = this.missingOf(names);
    if (miss.length === 0) {
      const sig: string = names.join('|');
      if (sig === this.lastSig && src !== SRC_MANUAL) {
        // 同一批键名已经回传过一次且没成功（例如插件拒了）：不每 5 秒重复写插件存储，
        // 等键名集合变化（新凭据下发）或用户手点再试
        return;
      }
      this.lastSig = sig;
      // Cookie 值流动（审计点 2/2）：raw 作为实参交给 pushCookie，此后本页不再持有它
      this.pushCookie(raw);
      return;
    }
    this.inflight = false;
    if (names.length === 0) {
      if (src === SRC_MANUAL) {
        this.status = ST_FAILED;
        this.detail = '只取到会话类 cookie，没有账号凭据。若确认已登录成功，说明凭据下发在别的域名下，请改用手动填写项。';
      }
      return;
    }
    // B 档：有 cookie 但必需键不齐 ⇒ 明确说缺什么（键名可上屏），继续等下一个事件/节拍
    if (this.status !== ST_LIMIT) {
      this.status = ST_WORKING;
    }
    this.detail = '已检测到 ' + String(names.length) + ' 项 cookie，还缺：' + miss;
  }

  /**
   * 回传给插件 setter（如 setEhentaiForumCookie）。
   * Cookie 值流动收尾：入参 raw → 局部 env.value → JSON.stringify 成局部 args → 递 bundleCall。
   * 四个变量全是局部，函数返回即不可达；中途没有任何一次赋给成员字段或写进文本。
   */
  private pushCookie(raw: string): void {
    this.inflight = true;
    this.probing = true;
    const env: CookieEnvelope = new CookieEnvelope();
    env.value = raw;
    const args: string = JSON.stringify([env]);
    bundleCall(this.uuid, this.target, args).then((raw2: string): void => {
      this.probing = false;
      this.inflight = false;
      const r: ESObject = jparse(raw2);
      if (jisEmpty(r)) {
        this.status = ST_FAILED;
        this.detail = '插件没有响应，可再点一次按钮重试。';
        return;
      }
      // 插件普遍把结果嵌在 data 之下（{source, data:{ok, message}}），少数直接平铺 ⇒ 两处都读，谁先用谁
      const payload: ESObject = jobj(r, 'data');
      const box: ESObject = jisEmpty(payload) ? r : payload;
      const msg: string = jstr(box, 'message', '');
      // ★ 成功不能只看 ok：eh 的 setEhentaiForumCookie **恒回 ok:true**，即使一个凭据都没验出来
      //   （实测 eh.cjs@1406230，那种情况 message = '未检测到有效的论坛 cookie（已过滤 …）'）。
      //   只看 ok 会把「没拿到」当成功 ⇒ 关页 + 停表 + 用户以为登进去了。判据改成看它到底存了什么：
      //   valuesPatch 里只要有任一键的值非空 ⇒ 真写进去了 = 成功；有 valuesPatch 但全空 ⇒ 失败继续等；
      //   完全没有 valuesPatch（别家的形状）才退回看 ok。
      const patch: ESObject = jobj(box, 'valuesPatch');
      let wrote: number = -1;
      if (!jisEmpty(patch)) {
        wrote = 0;
        const keys: string[] = Object.keys(patch);
        for (let i: number = 0; i < keys.length; i = i + 1) {
          const v: ESObject = patch[keys[i]];
          if (typeof v === 'string' && (v as string).length > 0) {
            wrote = wrote + 1;
          }
        }
      }
      const okAll: boolean = wrote >= 0 ? wrote > 0 : (jhas(box, 'ok') ? jbool(box, 'ok', false) : true);
      if (!okAll) {
        // 插件原话（如「未检测到有效的论坛 cookie」）不含凭据 ⇒ 可上屏；但它不给出路 ⇒ 宿主补一句
        this.status = ST_FAILED;
        this.detail = (msg.length > 0 ? msg + '。' : '插件没能从这份 cookie 里取出凭据。')
          + '请在页面里确认已登录成功后，再点一次下面的按钮。';
        // 没写进去 ⇒ 这批键名不算回传过，放开签名闸门让下一次事件/节拍/手点还能试
        this.lastSig = '';
        return;
      }
      // 成功：终局 + 停表 + 让「已回传」那一帧看得见再关页。
      // 设置页 onPageShow 会重跑 PluginSettings.load ⇒ 返回后登录态自然刷新，这里不用额外通知
      this.finished = true;
      this.stopTimers();
      this.status = ST_DONE;
      this.detail = msg.length > 0 ? msg : '已回传插件，正在返回设置页。';
      this.closeTimer = setTimeout((): void => {
        this.closeTimer = -1;
        router.back();
      }, CLOSE_DELAY_MS);
    }).catch((e: Error): void => {
      this.probing = false;
      this.inflight = false;
      this.status = ST_FAILED;
      this.detail = '回传失败，可再点一次重试。';
      // 抛断是宿主链路抖动、不是插件对这份 cookie 的判决 ⇒ 一并放开签名闸门，
      // 否则引擎抖一次之后 5 秒节拍会被自己挡死，只剩手点一条路
      this.lastSig = '';
    });
  }

  /** 顶栏返回：直接出页。定时器在 aboutToDisappear 里统一清（系统返回键也走那里，不必另挂 onBackPress）。 */
  private leave(): void {
    router.back();
  }

  build() {
    Column() {
      BreezeTopBar({
        title: this.title,
        showBack: true,
        scrollProgress: 1,
        // s11 裁定（lead 11-13 重申）：全站路由页统一 flatBackground 实底档 —— 顶栏与本页根容器同吃
        // Theme.background ⇒ 一块皮，深色下不留系统默认底
        flatBackground: true,
        onBack: (): void => {
          this.leave();
        }
      })

      // ---- 状态卡（s17 第 4 条）：原来是一条通栏裸行 + 下面一段裸文案，与底部卡片风格不统一。
      // 现在收进一张卡：卡壳与全站卡片同一个令牌（Theme.cardColor + Dim.radius + Dim.pagePadding），
      // 状态点四档色沿用 dotColor()（Theme.brand/success/warning/error），本页零新硬编码色值。 ----
      Column() {
        Row({ space: 8 }) {
          Circle({ width: 8, height: 8 })
            .fill(this.dotColor())
          Text(this.statusText())
            .fontSize(14)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text1(this.isDark))
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.cookieCount > 0) {
            // 枚数胶囊：右侧状态位。fillColor 是既有填充令牌（深色 #1AFFFFFF / 浅色 #0D182431），
            // 两档都在卡片色上有足够对比，不新造色。文案只有枚数，永不含 cookie 名与值。
            Text(String(this.cookieCount) + ' 项 cookie')
              .fontSize(12)
              .fontColor(Theme.text2(this.isDark))
              .backgroundColor(Theme.fillColor(this.isDark))
              .borderRadius(Dim.coverRadius)
              .padding({ left: 8, right: 8, top: 3, bottom: 3 })
              .flexShrink(0)
          }
        }
        .width('100%')
        .alignItems(VerticalAlign.Center)

        // 副文案：插件原话 / 还缺哪几个键名 / 失败原因（键名是协议常量，值永不进这里）。
        // 放宽到三行：缺键名那条（「还缺 ipb_member_id、ipb_pass_hash」）压两行会截掉尾巴。
        if (this.detail.length > 0) {
          Text(this.detail)
            .fontSize(12)
            .fontColor(Theme.text2(this.isDark))
            .lineHeight(18)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: 6 })
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding(12)
      .backgroundColor(Theme.cardColor(this.isDark))
      .borderRadius(Dim.radius)
      .margin({ left: Dim.pagePadding, right: Dim.pagePadding, top: 8 })

      if (this.webSrc.length > 0) {
        // ---- 网页卡（用户明确允许圆角）----
        // Web 本体不裁子树：只给 Web 自己设 borderRadius 不生效（页面内容仍按矩形画到角上），
        // 必须外层容器 borderRadius + clip(true) 配套（仓内同法先例 7 处，如 SearchPage 工具区）。
        // 外层底色给成卡片色：加载/回弹时露出的那层不是系统白，深色下不再是一块白洞。
        Column() {
          Web({ src: this.webSrc, controller: this.ctrl })
            .width('100%')
            .height('100%')
            .javaScriptAccess(true)
            .domStorageAccess(true)
            .fileAccess(false)
            .zoomAccess(true)
            .verticalScrollBarAccess(true)
            .backgroundColor(Theme.cardColor(this.isDark))
            .onControllerAttached((): void => {
              // 控制器挂上才取得到 cookie；挂上即摘一次（通常早于首个 onPageEnd）
              this.attached = true;
              this.collect(SRC_EVENT);
            })
            .onPageEnd((): void => {
              this.collect(SRC_EVENT);
            })
            .onLoadIntercept((ev: OnLoadInterceptEvent): boolean => {
              // 只借它当探测时机，**一律返回 false 不拦**：拦下任何请求都可能把登录跳转打断。
              // 只认主框架 —— 子资源请求几十上百条，逐条做同步取 cookie 没意义
              if (ev.data !== undefined && ev.data.isMainFrame()) {
                this.collect(SRC_EVENT);
              }
              return false;
            })
            .onErrorReceive((ev: OnErrorReceiveEvent): void => {
              // 只认**主框架**失败 = 页面根本打不开。子资源失败（人机校验时很常见）刻意不报：
              // 报出来会把还能用的页面说得像坏了，反而误导用户去点手动按钮（那时确实还没 cookie）
              if (this.finished || this.status === ST_DONE) {
                return;
              }
              if (ev.request === undefined || !ev.request.isMainFrame()) {
                return;
              }
              this.status = ST_LIMIT;
              this.detail = '页面没能加载出来（可能被拦截或需要人机验证）。可以直接重试，或返回用设置页的手动填写项。';
            })
        }
        .width('100%')
        .layoutWeight(1)
        .clip(true)
        .borderRadius(Dim.radius)
        .backgroundColor(Theme.cardColor(this.isDark))
        .borderWidth(GlassStyle.strokeWidth())
        .borderColor(GlassStyle.stroke(this.isDark))
        .margin({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10 })
      } else {
        // 没拿到地址（插件没回 openUrl 或参数在跳转中丢了）也要有话说：不白屏，且指向手动填写项。
        // 措辞只说「本次没拿到」不说「插件没有给出」：参数丢失是宿主侧的事，别把锅甩给插件（s16 第 3 条）
        Column() {
          Text('本次没拿到登录地址，无法开启网页登录。可以返回设置页重试一次，或改用设置页的手动填写项。')
            .fontSize(14)
            .fontColor(Theme.text2(this.isDark))
            .lineHeight(21)
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .padding({ left: Dim.pagePadding + 8, right: Dim.pagePadding + 8 })
        .backgroundColor(Theme.fillColor(this.isDark))
        .borderRadius(Dim.radius)
        .margin({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10 })
      }

      // 底部操作区。手动按钮 = 事件/节拍都没等到时的出口（用户明确说「已经登录完了」的那一刻）
      Column({ space: 8 }) {
        Button(this.probing ? '正在回传…' : '手动摘取并回传')
          .type(ButtonType.Normal)
          .fontSize(16)
          .fontColor(Theme.white)
          .backgroundColor(this.probing ? Theme.brandPressed : Theme.brand)
          .borderRadius(Dim.radius)
          .width('100%')
          .height(48)
          .enabled(this.canPick())
          .clickEffect({ level: ClickEffectLevel.LIGHT })
          .onClick((): void => {
            this.status = ST_WORKING;
            this.detail = '正在从这个页面摘取 cookie…';
            this.collect(SRC_MANUAL);
          })
        // 常驻兜底指引：**不随状态消失**（CF 盾过不了是这条链路唯一真实风险，不能让页面走进死路）。
        // s17 第 4 条观感修正：原先是无底无框的通栏居中文本，折两行后左右参差像没排完；
        // 现在装进填充底卡片 + 左对齐 + lineHeight，折行有固定的左边缘。
        Text('页面打不开或验证不通过？返回后用设置页的手动填写项同样可以登录。')
          .fontSize(12)
          .fontColor(Theme.text2(this.isDark))
          .lineHeight(18)
          .textAlign(TextAlign.Start)
          .width('100%')
          .padding(10)
          .backgroundColor(Theme.fillColor(this.isDark))
          .borderRadius(Dim.coverRadius)
      }
      .width('100%')
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10, bottom: 12 + this.bottomSafe })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
