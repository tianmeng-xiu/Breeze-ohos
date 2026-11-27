/**
 * 职责（P1b）：插件 bundle「真·新装载」后，把它导出的 init 跑一次。
 *       背景：JM 一类插件的端点选择逻辑唯一入口 = export init，宿主此前从不调用它
 *       ⇒ 端点池从未建立、全部请求恒打 bundle 里硬编码的回退域（诊断 21 行 VERDICT=never-init）。
 *       上游 Flutter 侧（runPluginInitIfNeeded）同样是装载后后台发一次、插件没导出 init 视作正常。
 * 三条硬约束：
 *  1. 绝不阻塞调用方：mark 是同步 void，内部泵异步跑；调用点不 await、不抛 ——
 *     init 内部可能自发网络请求（引擎侧单次调用上限 30s），把它接进启动链 = 拖垮启动。
 *  2. 每 bundle 每进程至多一次：done 集合先写后排队，重复 mark 直接 no-op；
 *     「已在内存」的重载路径不得调用（整体替换语义会洗掉插件内存态，见 PluginAutoLoader 硬约束 2）。
 *     例外 = rearm：整体替换语义的装载（同名 bundleLoadFromPath 重载会把插件内存态洗掉）之后，
 *     必须先撤 done 记账再 mark，让同一 bundle 在本进程再补跑一次 init（对齐上游云更新后重发 init）。
 *  3. 跨插件串行：running + queue 保证同一时刻只有一个 init 在飞，
 *     避免多插件 init 齐发请求挤占引擎双 worker 的配额。
 * 三态记账：ok = init 跑完；ni = 该插件没导出 init（引擎报 target is not function / function path
 * not found，判正常）；err = 其它异常（只留最后一条消息前 160 字符）。
 * hint() 只输出计数与 uuid 前 8 位的三态，绝不输出凭据、URL 查询参数、响应体。
 * s50 起新增「就绪信号」（真机定案 s49 双报告：pf 段 init=run ∧ age=-1 = 数据调用撞进
 * init 冷窗；章节空页 = 插件 30 min TTL 登录态过期无自愈）：
 *  - awaitInitReady(uuid)：仅当该 uuid 的 init 正在飞时有界等待，其余情形同步立即返回；
 *  - kickInit(uuid)：重挂一次 init 并有界等完（端点池走缓存是快路径，登录会重跑补 jwt）。
 *  两条都不改 mark/rearm/pump 的既有语义；mark 硬约束 1（调用方绝不 await）依旧成立，
 *  等待只发生在 awaitInitReady / kickInit 这两个显式入口里。
 * 依据系统 Kit：无（全部走 util/PluginRuntime 的宿主通道；定时器只用全局 setTimeout/clearTimeout）。
 */
import { bundleCall } from './PluginRuntime';
import { Logger } from './Logger';

function em(e: Object): string {
  const x = e as Error;
  const m = x.message;
  if (typeof m === 'string' && m.length > 0) {
    return m;
  }
  return String(e);
}

/** 错误消息截断（诊断行与日志都不允许长原文上屏）。 */
function cut160(s: string): string {
  return s.length > 160 ? s.slice(0, 160) : s;
}

/**
 * s50 修①：等一次 init 落地的上限。依据 = 插件冷路径（拉域名列表 + ≤6 探针 + ≤3 次登录），
 * 真机 s49 回传池建立 ≈1.2 s（探针 538/546/635 ms），12 s 留足余量；引擎侧单次调用上限 30 s，
 * 等待必须显著小于它，超时就放行、保留原有报错面（等待绝不制造新的错误面）。
 */
const INIT_WAIT_MS: number = 12000;

/** s50：就绪轮询间隔（与 BookshelfPage READY_RETRY_DELAYS 的退避同量级；单次开销 = 一次 Map 取值）。 */
const INIT_POLL_MS: number = 150;

/** s50：轮询次数上限 = 80 × 150 ms ≈ 12 s，与 INIT_WAIT_MS 同量级（deadline 是第一道，这一枚是兜底）。 */
const INIT_POLL_MAX: number = 80;

/** 让出若干毫秒：与 view/bookshelf/BookshelfPage.ets:32 sleepMs、data/image/ImageCache.ets:76 yieldFrame 同型写法（Promise 包 setTimeout）。 */
function sleepInit(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

export class PluginInit {
  /** 已 mark 过的 uuid（每 bundle 每进程至多一次 init 的唯一权威）。 */
  private static readonly done: Set<string> = new Set<string>();
  /** 每 uuid 三态（ok/ni/err），按完成顺序进 hint() 的逐插件明细。 */
  private static readonly states: Map<string, string> = new Map<string, string>();
  /** 等待队列（泵未运行时 mark 只入队，保证串行）。 */
  private static readonly queue: string[] = [];
  /** 泵在飞标志（并发闸门：true 时再 mark 只入队）。 */
  private static running: boolean = false;
  private static okCount: number = 0;
  private static niCount: number = 0;
  private static errCount: number = 0;
  /** 最后一条真失败消息（截 160），诊断 22 行 last= 段。 */
  private static lastErr: string = '';
  /**
   * 每 uuid 的 init 落地时刻（s49 取证用：s24 号行要知道「事件距 init 完成多久」，
   * 因为插件侧端点池与 jwt 都是 30 min TTL）。只加记账，不参与任何判定。
   */
  private static readonly finishedAt: Map<string, number> = new Map<string, number>();

  /**
   * 「该插件没导出 init」的引擎原文形态（vendored host_runtime.rs 的两条报错前缀），
   * 命中 = ni（正常态，真机 26 枚里 7 枚本就没导出）。
   */
  static notFunctionMsg(msg: string): boolean {
    return msg.includes('target is not function: init')
      || msg.includes('function path not found: init');
  }

  /**
   * 真·新装载成功后发一次 init：同步入队立即返回，调用点不 await。
   * 空 uuid / 重复 uuid 都 no-op。
   */
  static mark(uuid: string): void {
    if (uuid.length === 0 || PluginInit.done.has(uuid)) {
      return;
    }
    PluginInit.done.add(uuid);
    PluginInit.queue.push(uuid);
    if (!PluginInit.running) {
      PluginInit.running = true;
      PluginInit.pump();
    }
  }

  /**
   * 整体替换语义的装载（bundleLoadFromPath 同名重载 = 洗掉插件内存态）后用：先撤 done 记账再 mark，
   * 让新版本 bundle 在本进程也能补跑一次 init（对齐上游云更新后重发 init 的那条通路）。
   */
  static rearm(uuid: string): void {
    if (uuid.length === 0) {
      return;
    }
    PluginInit.done.delete(uuid);
    PluginInit.mark(uuid);
  }

  /** 泵：逐个跑 init，全量自捕获；finally 保证 running 必回位，队列永不卡死。 */
  private static async pump(): Promise<void> {
    try {
      while (PluginInit.queue.length > 0) {
        const uuid: string = PluginInit.queue.shift() as string;
        let note: string = 'ok';
        try {
          await bundleCall(uuid, 'init', '[{}]');
          PluginInit.okCount += 1;
          Logger.i('plugin init ok ' + uuid.slice(0, 8));
        } catch (e) {
          const msg: string = em(e as Object);
          if (PluginInit.notFunctionMsg(msg)) {
            PluginInit.niCount += 1;
            note = 'ni';
            Logger.i('plugin init skipped (未导出) ' + uuid.slice(0, 8));
          } else {
            PluginInit.errCount += 1;
            note = 'err';
            PluginInit.lastErr = cut160(msg);
            Logger.w('plugin init failed ' + uuid.slice(0, 8) + ': ' + PluginInit.lastErr);
          }
        }
        PluginInit.states.set(uuid, note);
        PluginInit.finishedAt.set(uuid, Date.now());
      }
    } finally {
      PluginInit.running = false;
    }
  }

  /**
   * s50 修①（治「排行榜首次点击必失败」）：该插件的 init 正在飞时**有界等完**，其余情形立即返回。
   * 返回 true = init 已落地且成功（或本就没导出 init / 从未 mark —— 那两种没有可等的东西）；
   * false = 仍在飞（已超时放行）或落地但失败。调用方**只记不拦**：超时也照常发请求，
   * 保留原报错面（真机 s49 的 pf 段 init=run ∧ age=-1 就是这么来的）。
   * 有界性靠 deadline + 轮询上限双保险，绝不无界挂起。
   */
  static async awaitInitReady(uuid: string): Promise<boolean> {
    if (uuid.length === 0) {
      return false;
    }
    if (PluginInit.stateOf(uuid) !== 'run') {
      return true;
    }
    const deadline: number = Date.now() + INIT_WAIT_MS;
    for (let i = 0; i < INIT_POLL_MAX; i++) {
      await sleepInit(INIT_POLL_MS);
      const st: string = PluginInit.stateOf(uuid);
      if (st !== 'run') {
        return st === 'ok';
      }
      if (Date.now() >= deadline) {
        break;
      }
    }
    return false;
  }

  /**
   * s50 修②（治「章节页表为空」）：重挂一次 init 并有界等完。
   * 为什么这样能治：插件侧登录态 jwt 只活在进程内缓存（30 min TTL），且只有 /login 响应里的
   * jwttoken 会写它 ⇒ 用户挂机超 30 min 后取章节必然空页表，而插件自己不会自愈。
   * 重跑 init = 端点池走缓存（rf() 命中即 return，快路径）+ 登录重发（把 jwt 补回来）。
   * 与 rearm 的区别 = rearm 发完不管（fire-and-forget，硬约束 1），kickInit 会等它落地再返回。
   * 真失败照实写日志与 last=（不吞），只是不把异常抛给取数链路 —— 由调用方重试那一次请求裁决。
   * 返回 true = 本次重挂跑成功；false = 没等完 / 未导出 init / 失败。
   */
  static async kickInit(uuid: string): Promise<boolean> {
    if (uuid.length === 0) {
      return false;
    }
    // 已有一次在飞（别的装载路径刚 mark）：不再重复入队，直接等那一枚落地。
    if (PluginInit.stateOf(uuid) === 'run') {
      return PluginInit.awaitInitReady(uuid);
    }
    // 判「这一次新落地」的锚 = finishedAt 是否换了值。不能只看 stateOf：rearm 之后 states 里
    // 还是上一轮的 'ok'，据此判就绪会立刻返回真值而根本没等到新 init 跑完。
    // （-1 哨兵：本进程从未落地过的 uuid，get 是 undefined，两帧比较必须先归成同一数值。）
    const prevRaw: number | undefined = PluginInit.finishedAt.get(uuid);
    const prev: number = prevRaw === undefined ? -1 : prevRaw;
    PluginInit.rearm(uuid);
    const deadline: number = Date.now() + INIT_WAIT_MS;
    for (let i = 0; i < INIT_POLL_MAX; i++) {
      await sleepInit(INIT_POLL_MS);
      const curRaw: number | undefined = PluginInit.finishedAt.get(uuid);
      const cur: number = curRaw === undefined ? -1 : curRaw;
      if (cur !== prev) {
        return PluginInit.stateOf(uuid) === 'ok';
      }
      if (Date.now() >= deadline) {
        break;
      }
    }
    Logger.w('plugin init kick 超时未落地 ' + uuid.slice(0, 8) + ' state=' + PluginInit.stateOf(uuid));
    return false;
  }

  /**
   * s49 取证出口：某 uuid 的 init 态三档（ok/ni/err 已落地；run = 已 mark 未落地；
   * none = 本进程从未 mark）。**只读**，不改任何行为。
   */
  static stateOf(uuid: string): string {
    const v: string | undefined = PluginInit.states.get(uuid);
    if (v !== undefined) {
      return v;
    }
    return PluginInit.done.has(uuid) ? 'run' : 'none';
  }

  /** s49 取证出口：距该 uuid init 完成的毫秒；未完成/未 mark = -1。 */
  static doneAgeMs(uuid: string): number {
    const t: number | undefined = PluginInit.finishedAt.get(uuid);
    if (t === undefined) {
      return -1;
    }
    return Date.now() - t;
  }

  /**
   * 诊断 22 行 pluginInit：`mark=总数 ok=… ni=… err=… running=… q=… <uuid8>:ok …(+N) last=…`。
   * 明细最多 8 枚插件（超出折叠 +N）；整行超 700 字符截断。
   */
  static hint(): string {
    const parts: string[] = [];
    PluginInit.states.forEach((v: string, k: string): void => {
      if (parts.length < 8) {
        parts.push(k.slice(0, 8) + ':' + v);
      }
    });
    let s: string = 'mark=' + PluginInit.done.size
      + ' ok=' + PluginInit.okCount
      + ' ni=' + PluginInit.niCount
      + ' err=' + PluginInit.errCount
      + ' running=' + (PluginInit.running ? 1 : 0)
      + ' q=' + PluginInit.queue.length;
    if (parts.length > 0) {
      s += ' ' + parts.join(' ');
    }
    const extra: number = PluginInit.states.size - parts.length;
    if (extra > 0) {
      s += '(+' + extra + ')';
    }
    if (PluginInit.lastErr.length > 0) {
      s += ' last=' + PluginInit.lastErr;
    }
    if (s.length > 700) {
      return s.slice(0, 699) + '…';
    }
    return s;
  }
}
