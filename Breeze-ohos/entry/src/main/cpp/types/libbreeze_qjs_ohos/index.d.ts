/**
 * libbreeze_qjs_ohos.so 的类型声明 —— 与 Rust 侧 breeze_qjs_ohos/src/lib.rs 的导出表逐字对齐。
 * 实现体是 Rust cdylib：scripts/build_rust_ohos.sh 产出，拷入 entry/libs/arm64-v8a/。
 *
 * ⚠ 装载三要件之一（S1 真机踩过）：必须用「interface + declare const + export default」形态。
 *   不能写 `export const eval`——eval 是严格模式保留字（ArkTS 错误码 10505001）。
 *   S2 起同步入口改名 evalScript（非保留字），S1 的 eval 不再暴露。
 *
 * 超时口径（ABI §1.3）：bundleCall* 30s / bundleLoad 10s / 宿主回调 15s，超时侧由 Rust 判定并 reject。
 */

/**
 * 宿主回调形态（ABI §1.1）：inputJson = JSON.stringify([runtimeName, ...args])，
 * 与上游 FRB register_function 逐字一致。回调必须自行调用
 * resolveBridgeCallback / rejectBridgeCallback 回包；返回值本身被 Rust 忽略。
 */
export type HostCallback = (inputJson: string, replyId: number) => void;

/**
 * 二进制返回值（ABI §1.2/§3）：插件返回二进制（图片链路）时 kind="bytes"，
 * bytes 是零拷贝 external ArrayBuffer；kind="json" 时 json 是 JSON 文本、
 * bytes 是其 UTF-8 字节（消费方应优先读 json 字段）。
 */
export interface BytesResult {
  /** data 是二进制 offload 还是普通 JSON */
  kind: 'bytes' | 'json';
  /** kind=json 时是 JSON 的 UTF-8 字节 */
  bytes: ArrayBuffer;
  /** HTTP 状态码，0 = 无 HTTP 元信息 */
  statusCode: number;
  /** 响应体原始长度（未知时 = bytes.byteLength） */
  bodyLength: number;
  /** kind=json 时为 JSON 文本；kind=bytes 时为 "" */
  json: string;
}

export interface BreezeQjsModule {
  // ---------------------------------------------------------- 同步函数（立即返回，不得阻塞 ArkTS 主线程）

  /** 幂等初始化运行时（fs 缺省 true ⇒ WebRuntimeOptions{fs:true}，15 个 polyfill 全量）。
   *  storageRoot（§12.5）= 插件目录根（传 context.filesDir）：Rust eval 注入
   *  globalThis.__BREEZE_PLUGIN_ROOT；host-fs 无 jail，路径边界完全靠这个根（§12.2）。
   *  返回 "ok"；失败抛异常。 */
  init(fs?: boolean, storageRoot?: string): string;

  /** JSON：{build,quickjs,module,hostCalls:string[],bundles:string[],storageRoot:string|null,storageReady:boolean} */
  diagnostics(): string;

  /** 建 TSFN 并 register_bridge_route_async_handler(name, ...)。重复注册同名 = 替换。 */
  registerHostCallback(name: string, fn: HostCallback): boolean;

  /** registerHostCallback 的反向操作。 */
  unregisterHostCallback(name: string): boolean;

  /** 宿主回调成功回包（ABI §2）：resultJson 是字符串，Rust 原样包成 Value::String；空串 ⇒ Null。 */
  resolveBridgeCallback(id: number, resultJson: string): boolean;

  /** 宿主回调失败回包：插件侧 bridge.call 抛 [BRIDGE_CALL_FAILED] <message>。 */
  rejectBridgeCallback(id: number, message: string): boolean;

  /** 尽力取消一个已提交任务。 */
  cancelTask(id: number): boolean;

  /** AsyncHostRuntime::stats() 的 JSON。 */
  stats(): string;

  // ---------------------------------------------------------- 异步函数（Promise；Rust 走 napi_async_work，永不占主线程）

  /** 求值结果的字符串形态（调试用；S1 的 eval 改名而来，规避保留字）。 */
  evalScript(code: string): Promise<string>;

  /** 装载 bundle。"ok"；JS 语法错/装载错 ⇒ reject(Error(msg+stack))。超时 10s。 */
  bundleLoad(name: string, source: string): Promise<string>;

  /** 返回值 JSON.stringify(data) 字符串，调用方自行 JSON.parse。超时 30s。argsJson 必须是 JSON 数组字符串。 */
  bundleCall(name: string, fnPath: string, argsJson: string): Promise<string>;

  /** 同 bundleCall，但保留二进制 offload（图片链路）。超时 30s。 */
  bundleCallBytes(name: string, fnPath: string, argsJson: string): Promise<BytesResult>;

  /** 一次性装载+调用（不常驻注册表）。 */
  bundleCallOnce(source: string, fnPath: string, argsJson: string): Promise<string>;

  /** 是否真的卸载掉。 */
  bundleUnload(name: string): Promise<boolean>;

  /** 当前已装载 bundle 名。 */
  bundleList(): Promise<string[]>;

  /** S1 的 6 项自检 JSON（S2 扩展项见 ABI §4）。 */
  selftest(): Promise<string>;

  // -------------------------------------- S4 插件文件（ABI v3，Rust 侧 jail_path 校验，全部限制在 init 的 storageRoot 之下）

  /** 从沙箱文件直接读源码并装载（免把全文当字符串过 NAPI）。absPath 必须是 init(storageRoot) 之下的
   *  绝对路径（拒绝相对路径、`..` 分量、前缀相似兄弟目录）；大小上限 8MB；非 UTF-8 报错。"ok"；超时 10s。 */
  bundleLoadFromPath(name: string, absPath: string): Promise<string>;

  /** 删除 jail 内一个文件。返回 "removed" / "absent"（不存在也算成功，幂等）；越界或权限错 ⇒ reject。 */
  pluginRemoveFile(absPath: string): Promise<string>;

  /** 扫描 jail 内目录（relDir 相对于 storageRoot，缺省 "plugins"），JSON 数组字符串：
   *  [{name:string, bytes:number, mtimeMs:number}]，只列 *.cjs / *.js 普通文件，按 name 升序；目录不存在 ⇒ "[]"。 */
  pluginScanDir(relDir?: string): Promise<string>;
}

declare const breezeQjs: BreezeQjsModule;
export default breezeQjs;
