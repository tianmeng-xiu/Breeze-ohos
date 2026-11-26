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
 * 依据系统 Kit：无（全部走 util/PluginRuntime 的宿主通道）。
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
      }
    } finally {
      PluginInit.running = false;
    }
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
