/**
 * 职责：S2 —— ArkTS 侧对 libbreeze_qjs_ohos.so（rquickjs + 上游 playground）的薄封装。
 * 依据：Rust 侧 breeze_qjs_ohos/src/lib.rs 的导出表。types 权威声明见
 *      entry/src/main/cpp/types/libbreeze_qjs_ohos/index.d.ts（此处本地复刻一份同构接口：
 *      .d.ts 的具名类型 import 在部分 hvigor 版本不稳定，复刻可编译性最稳）。
 * 约定：全部方法 try/catch 后原样再抛（Error.message 不动）——面板要显示原文，绝不吞异常。
 *      异步方法 Promise reject 天然传播，无需包装。
 */
import qjsNative from 'libbreeze_qjs_ohos.so';
import { Logger } from './Logger';

/** 宿主回调形态（ABI §1.1）：inputJson = JSON.stringify([runtimeName, ...args])。 */
export type HostCallback = (inputJson: string, replyId: number) => void;

/** 二进制返回值（ABI §1.2/§3）。kind=json 时消费方优先读 json 字段。 */
export interface BytesResult {
  kind: 'bytes' | 'json';
  bytes: ArrayBuffer;
  statusCode: number;
  bodyLength: number;
  json: string;
}

/** 原生模块 16 个导出（与 index.d.ts 逐字一致；§12.5：init 二参 storageRoot）。 */
interface BreezeQjsModule {
  init(fs?: boolean, storageRoot?: string): string;
  diagnostics(): string;
  registerHostCallback(name: string, fn: HostCallback): boolean;
  unregisterHostCallback(name: string): boolean;
  resolveBridgeCallback(id: number, resultJson: string): boolean;
  rejectBridgeCallback(id: number, message: string): boolean;
  cancelTask(id: number): boolean;
  stats(): string;
  evalScript(code: string): Promise<string>;
  bundleLoad(name: string, source: string): Promise<string>;
  bundleCall(name: string, fnPath: string, argsJson: string): Promise<string>;
  bundleCallBytes(name: string, fnPath: string, argsJson: string): Promise<BytesResult>;
  bundleCallOnce(source: string, fnPath: string, argsJson: string): Promise<string>;
  bundleUnload(name: string): Promise<boolean>;
  bundleList(): Promise<string[]>;
  selftest(): Promise<string>;
  // ---- S4 插件文件（ABI v3；路径必须绝对且在 init(storageRoot) 之下，Rust jail_path 校验）
  bundleLoadFromPath(name: string, absPath: string): Promise<string>;
  pluginRemoveFile(absPath: string): Promise<string>;
  pluginScanDir(relDir?: string): Promise<string>;
}

const engine: BreezeQjsModule = qjsNative as BreezeQjsModule;

/** 记录并原样再抛：hilog 留一份，面板拿到的仍是原始 Error。 */
function rethrow(tag: string, e: Object): never {
  const err = e as Error;
  Logger.e('PluginRuntime.' + tag + ' 失败: ' + (err.message ?? String(e)));
  if (e instanceof Error) {
    throw e;
  }
  throw new Error(String(e));
}

/** 原生模块是否真的注册上了（undefined ⇒ nm_modname 与 so 文件名不匹配，见 ABI §0）。 */
export function engineLoaded(): boolean {
  const m: Object | undefined = qjsNative as Object | undefined;
  return m !== undefined && m !== null;
}

/**
 * 导出清单反射探针（真机取证用，S2 排障加）：不 import 任何具体函数名，直接对模块对象反射，
 * 所以「napi 注册循环在中途 return」这类半途失败也能拿到完整信息 ——
 *   ownKeys=[] ⇒ 注册函数压根没跑；ownKeys 只有 init ⇒ 循环在 diagnostics 处断。
 * 返回单行文本，调用方（面板 exports 行）原样显示，不参与判定。
 */
export function engineProbe(): string {
  const m: Record<string, Object> = qjsNative as Object as Record<string, Object>;
  if (m === undefined || m === null) {
    return 'MODULE=undefined';
  }
  const keys: string[] = Object.keys(m);
  const want: string[] = ['init', 'diagnostics', 'stats', 'registerHostCallback', 'unregisterHostCallback',
    'resolveBridgeCallback', 'rejectBridgeCallback', 'cancelTask', 'evalScript', 'bundleLoad', 'bundleCall',
    'bundleCallBytes', 'bundleCallOnce', 'bundleUnload', 'bundleList', 'selftest',
    'bundleLoadFromPath', 'pluginRemoveFile', 'pluginScanDir'];
  const present: string[] = [];
  const missing: string[] = [];
  for (let i = 0; i < want.length; i++) {
    const k: string = want[i];
    if (typeof m[k] === 'function') {
      present.push(k);
    } else {
      missing.push(k);
    }
  }
  return 'ownKeys=[' + keys.join(',') + '] present=' + present.length + '/19 [' + present.join(',')
    + '] missing=[' + missing.join(',') + ']';
}

/** 引擎可用时返回模块对象，否则抛明确错误（面板据此显示依据，而不是 undefined 崩点）。 */
function needEngine(): BreezeQjsModule {
  if (!engineLoaded()) {
    throw new Error('native module not registered (check nm_modname / -lace_napi.z / oh-package deps)');
  }
  return engine;
}

/** 幂等初始化运行时（fs 缺省 true ⇒ 15 个 polyfill 全量）。
 *  storageRoot（§12.5）= 插件目录根（context.filesDir）：注入 __BREEZE_PLUGIN_ROOT，
 *  host-fs 无 jail，边界全靠它 ⇒ 11/12 行（probeDownload/probeUnload）硬前提。
 *  返回 "ok"；失败抛异常。 */
export function engineInit(fs?: boolean, storageRoot?: string): string {
  try {
    return needEngine().init(fs, storageRoot);
  } catch (e) {
    return rethrow('init', e as Object);
  }
}

/** diagnostics JSON 字符串（build/quickjs/module/hostCalls/bundles）。 */
export function engineDiagnostics(): string {
  try {
    return needEngine().diagnostics();
  } catch (e) {
    return rethrow('diagnostics', e as Object);
  }
}

/** AsyncHostRuntime::stats() 的 JSON。 */
export function engineStats(): string {
  try {
    return needEngine().stats();
  } catch (e) {
    return rethrow('stats', e as Object);
  }
}

/** 求值一段脚本，返回结果字符串形态（调试用；异步，不占主线程）。 */
export function engineEval(code: string): Promise<string> {
  return needEngine().evalScript(code);
}

/** 装载 bundle（name 幂等替换）。超时 10s，语法错 reject(Error(msg+stack))。 */
export function bundleLoad(name: string, source: string): Promise<string> {
  return needEngine().bundleLoad(name, source);
}

/** 调用 bundle 方法，返回 JSON.stringify(data)，调用方自行 JSON.parse。argsJson 必须是 JSON 数组串。 */
export function bundleCall(name: string, fnPath: string, argsJson: string): Promise<string> {
  return needEngine().bundleCall(name, fnPath, argsJson);
}

/** 同 bundleCall 但保留二进制 offload（图片链路）。 */
export function bundleCallBytes(name: string, fnPath: string, argsJson: string): Promise<BytesResult> {
  return needEngine().bundleCallBytes(name, fnPath, argsJson);
}

/** 一次性装载+调用（不常驻注册表）。 */
export function bundleCallOnce(source: string, fnPath: string, argsJson: string): Promise<string> {
  return needEngine().bundleCallOnce(source, fnPath, argsJson);
}

/** 卸载 bundle，返回是否真的卸掉。 */
export function bundleUnload(name: string): Promise<boolean> {
  return needEngine().bundleUnload(name);
}

/** 当前已装载 bundle 名列表。 */
export function bundleList(): Promise<string[]> {
  return needEngine().bundleList();
}

/** 注册宿主回调路由（同名 = 替换）。失败（非 true）抛错。 */
export function registerHostCallback(name: string, fn: HostCallback): boolean {
  try {
    const ok: boolean = needEngine().registerHostCallback(name, fn);
    if (!ok) {
      throw new Error('registerHostCallback("' + name + '") returned false');
    }
    return ok;
  } catch (e) {
    return rethrow('registerHostCallback:' + name, e as Object);
  }
}

/** 注销宿主回调路由。 */
export function unregisterHostCallback(name: string): boolean {
  try {
    return needEngine().unregisterHostCallback(name);
  } catch (e) {
    return rethrow('unregisterHostCallback:' + name, e as Object);
  }
}

/** 宿主回调成功回包（resultJson 字符串原样透传，空串 ⇒ Null）。 */
export function resolveBridgeCallback(replyId: number, resultJson: string): boolean {
  try {
    return needEngine().resolveBridgeCallback(replyId, resultJson);
  } catch (e) {
    return rethrow('resolveBridgeCallback:' + replyId, e as Object);
  }
}

/** 宿主回调失败回包。 */
export function rejectBridgeCallback(replyId: number, message: string): boolean {
  try {
    return needEngine().rejectBridgeCallback(replyId, message);
  } catch (e) {
    return rethrow('rejectBridgeCallback:' + replyId, e as Object);
  }
}

/** 尽力取消一个已提交任务。 */
export function cancelTask(id: number): boolean {
  try {
    return needEngine().cancelTask(id);
  } catch (e) {
    return rethrow('cancelTask', e as Object);
  }
}

/** S1 的 6 项自检 JSON（S2 扩展项见 ABI §4），异步。 */
export function engineSelftest(): Promise<string> {
  return needEngine().selftest();
}

// ---------------------------------------------------------------- S4 插件文件（ABI v3）

/** 从沙箱文件直接装载 bundle（免把全文当字符串过 NAPI）。absPath 必须是绝对路径且在 init 传入的
 *  storageRoot 之下；上限 8MB；超时 10s。装载失败 reject(Error)（语法错含 stack）。 */
export function bundleLoadFromPath(name: string, absPath: string): Promise<string> {
  return needEngine().bundleLoadFromPath(name, absPath);
}

/** 删除 jail 内文件；返回 "removed" 或 "absent"（不存在也算成功，幂等）。 */
export function pluginRemoveFile(absPath: string): Promise<string> {
  return needEngine().pluginRemoveFile(absPath);
}

/** 扫描 jail 内目录（相对 storageRoot，缺省 "plugins"），返回 JSON 数组字符串
 *  [{name,bytes,mtimeMs}]（只列 *.cjs/*.js，按 name 升序；目录不存在 ⇒ "[]"）。 */
export function pluginScanDir(relDir?: string): Promise<string> {
  return needEngine().pluginScanDir(relDir);
}
