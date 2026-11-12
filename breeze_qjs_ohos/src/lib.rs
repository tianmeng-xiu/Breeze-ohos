// 职责：S2 —— libbreeze_qjs_ohos 的 NAPI 模块表面（插件引擎 + 宿主回调桥）。
//
// 接口口径唯一权威：本文件的导出表 + ArkTS 侧 cpp/types/libbreeze_qjs_ohos/index.d.ts（改签名必须两处同步）。
//
// 三条硬约束（S1 真机踩过 + 调研红线）：
// 1. 装载三要件：nm_modname 必须等于 so 文件名去掉 lib/.so（= "breeze_qjs_ohos"）；
//    必须链 libace_napi.z（见 .cargo/config.toml 的 link-arg）；ArkTS 侧要有 types 包。
// 2. 异步函数一律 napi_create_promise + napi_create_async_work：真正的阻塞发生在 libuv
//    线程池（engine::drive 的 blocking_recv），ArkTS 主线程只负责 create/queue/resolve。
// 3. 反向通道（qjs worker → ArkTS 主线程）只走 host_bridge 的 threadsafe function。
//    主线程绝不对 qjs worker 发同步往返调用 ⇒ 所以 diagnostics() 只读 Rust 侧镜像。

#![allow(clippy::too_many_arguments)]

use std::ffi::{c_char, c_void, CStr, CString};
use std::ptr;

use crate::napi::{NapiAsyncWork, NapiCallbackInfo, NapiDeferred, NapiEnv, NapiStatus, NapiValue, NAPI_OK};

mod engine;
mod host_bridge;
// S5h：宿主**原生** bridge 路由（cache.* / opencc.convert / runtime.*），对齐上游
// init_rust_functions。必须在 Rust 侧：宿主回调链把回包字符串原样当 Value::String 不解析，
// 由 ArkTS 注册 cache.* 会让插件拿到 JSON 字符串（详见 host_routes.rs 文件头裁决）。
mod host_routes;
mod napi;
// 宿主 cargo test 链接桩（napi_* 在 windows 宿主无实现；文件内 #![cfg(test)]，真机构建零影响）。
#[cfg(test)]
mod host_stubs;

// ---------------------------------------------------------------- 异步调用载体

type BoxedCall = Box<dyn FnOnce() -> Result<engine::Outcome, String> + Send>;

/// 一次异步调用的全部状态。`Box<AsyncCall>` 的裸指针作为 napi_async_work 的 data，
/// execute 在 libuv 线程写 result，complete 回主线程消费并回收。
struct AsyncCall {
    deferred: NapiDeferred,
    label: CString,
    exec: Option<BoxedCall>,
    result: Option<Result<engine::Outcome, String>>,
    work: NapiAsyncWork,
}

/// # Safety
/// 只由 napi 在 libuv 线程池调用；`data` 是 `Box::into_raw(Box::new(AsyncCall))`。
unsafe extern "C" fn execute_call(_env: NapiEnv, data: *mut c_void) {
    if data.is_null() {
        return;
    }
    let call = unsafe { &mut *(data as *mut AsyncCall) };
    if let Some(exec) = call.exec.take() {
        call.result = Some(exec());
    }
}

/// # Safety
/// 只由 napi 在 JS 主线程调用（env 可用于 resolve/reject）。
unsafe extern "C" fn complete_call(env: NapiEnv, status: NapiStatus, data: *mut c_void) {
    if data.is_null() {
        return;
    }
    let mut call = unsafe { Box::from_raw(data as *mut AsyncCall) };
    if !call.work.is_null() {
        unsafe { napi::napi_delete_async_work(env, call.work) };
        call.work = ptr::null_mut();
    }
    if call.deferred.is_null() {
        return;
    }
    // async work 自身被取消（napi_cancel_async_work ⇒ status != napi_ok）时 result 为 None。
    let outcome = match call.result.take() {
        Some(v) => v,
        None => Err(format!("async work cancelled: {:?}", call.label)),
    };
    if status != NAPI_OK {
        let msg = format!("async work failed (status {status}): {:?}", call.label);
        reject(env, call.deferred, &msg);
        return;
    }
    match outcome {
        Ok(value) => {
            let js = outcome_to_value(env, value);
            unsafe { napi::napi_resolve_deferred(env, call.deferred, js) };
        }
        Err(msg) => reject(env, call.deferred, &msg),
    }
}

unsafe fn reject(env: NapiEnv, deferred: NapiDeferred, msg: &str) {
    let code = napi::js_string(env, "BREEZE_QJS");
    let message = napi::js_string(env, msg);
    let mut err: NapiValue = ptr::null_mut();
    let status = unsafe { napi::napi_create_error(env, code, message, &mut err) };
    if status != NAPI_OK || err.is_null() {
        let fallback = napi::js_string(env, msg);
        unsafe { napi::napi_reject_deferred(env, deferred, fallback) };
        return;
    }
    unsafe { napi::napi_reject_deferred(env, deferred, err) };
}

/// 排队执行 `exec`，返回 Promise。`exec` 在 libuv 线程运行（可安全阻塞）。
/// # Safety
/// 见 spawn_promise 的条件。
unsafe fn spawn(env: NapiEnv, label: &str, exec: BoxedCall) -> NapiValue {
    let mut deferred: NapiDeferred = ptr::null_mut();
    let mut promise: NapiValue = ptr::null_mut();
    let status = unsafe { napi::napi_create_promise(env, &mut deferred, &mut promise) };
    if status != NAPI_OK || deferred.is_null() {
        napi::throw(env, &format!("napi_create_promise failed: status {status}"));
        return ptr::null_mut();
    }
    let resource_name = napi::js_string(env, label);
    let mut work: NapiAsyncWork = ptr::null_mut();
    let call = Box::new(AsyncCall {
        deferred,
        label: CString::new(label.replace('\0', " ")).unwrap_or_default(),
        exec: Some(exec),
        result: None,
        work: ptr::null_mut(),
    });
    let call_ptr = Box::into_raw(call);
    let status = unsafe {
        napi::napi_create_async_work(
            env,
            ptr::null_mut(),
            resource_name,
            Some(execute_call),
            Some(complete_call),
            call_ptr as *mut c_void,
            &mut work,
        )
    };
    if status != NAPI_OK || work.is_null() {
        // 建 work 失败：data 仍归我们所有 ⇒ 收回内存并同步 reject，避免泄漏 + 悬挂 Promise
        drop(unsafe { Box::from_raw(call_ptr) });
        reject(
            env,
            deferred,
            &format!("napi_create_async_work({label}) failed: status {status}"),
        );
        return promise;
    }
    unsafe { (*call_ptr).work = work };
    unsafe { napi::napi_queue_async_work(env, work) };
    promise
}

unsafe fn outcome_to_value(env: NapiEnv, outcome: engine::Outcome) -> NapiValue {
    match outcome {
        engine::Outcome::Str(s) => napi::js_string(env, &s),
        engine::Outcome::Bool(b) => napi::js_bool(env, b),
        engine::Outcome::Strings(items) => {
            let mut arr: NapiValue = ptr::null_mut();
            if unsafe { napi::napi_create_array(env, &mut arr) } != NAPI_OK {
                return napi::js_string(env, &serde_json::to_string(&items).unwrap_or_default());
            }
            for (idx, item) in items.iter().enumerate() {
                let value = napi::js_string(env, item);
                unsafe { napi::napi_set_element(env, arr, idx as u32, value) };
            }
            arr
        }
        engine::Outcome::Bytes {
            kind,
            bytes,
            status_code,
            body_length,
            json,
        } => {
            // PLUGIN_ABI §3：{kind, bytes:ArrayBuffer, statusCode, bodyLength, json}
            let mut obj: NapiValue = ptr::null_mut();
            if unsafe { napi::napi_create_object(env, &mut obj) } != NAPI_OK {
                return napi::js_string(env, &json);
            }
            set_str(env, obj, "kind", kind);
            set_str(env, obj, "json", &json);
            let (ab, _) = unsafe { napi::external_arraybuffer(env, bytes) };
            if !ab.is_null() {
                set(env, obj, "bytes", ab);
            }
            let mut status_value: NapiValue = ptr::null_mut();
            unsafe { napi::napi_create_int64(env, status_code, &mut status_value) };
            set(env, obj, "statusCode", status_value);
            let mut len_value: NapiValue = ptr::null_mut();
            unsafe { napi::napi_create_int64(env, body_length, &mut len_value) };
            set(env, obj, "bodyLength", len_value);
            obj
        }
    }
}

unsafe fn set(env: NapiEnv, obj: NapiValue, key: &str, value: NapiValue) {
    let name = napi::js_string(env, key);
    unsafe { napi::napi_set_property(env, obj, name, value) };
}

unsafe fn set_str(env: NapiEnv, obj: NapiValue, key: &str, value: &str) {
    let v = napi::js_string(env, value);
    set(env, obj, key, v);
}

// ---------------------------------------------------------------- 同步导出

/// `init(fs?: boolean): string` —— 幂等，失败抛异常。
unsafe extern "C" fn js_init(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let fs = unsafe { napi::arg_bool_opt(env, info, 0) }.unwrap_or(true);
    // 第二参：插件目录根（ArkTS 传 getContext(this).filesDir）。缺省只影响下载/卸载自测。
    let root = unsafe { napi::arg_string(env, info, 1) }.filter(|s| !s.trim().is_empty());
    match engine::init(fs, root) {
        Ok(v) => napi::js_string(env, &v),
        Err(msg) => napi::throw(env, &msg),
    }
}

unsafe extern "C" fn js_diagnostics(env: NapiEnv, _info: NapiCallbackInfo) -> NapiValue {
    napi::js_string(env, &engine::diagnostics())
}

unsafe extern "C" fn js_stats(env: NapiEnv, _info: NapiCallbackInfo) -> NapiValue {
    napi::js_string(env, &engine::stats())
}

unsafe extern "C" fn js_register_host_callback(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(name) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "registerHostCallback(name, fn): name must be a string");
    };
    let Some(cb) = (unsafe { napi::arg_value(env, info, 1) }) else {
        return napi::throw(env, &format!("registerHostCallback({name}): callback missing"));
    };
    let mut kind: i32 = -1;
    let ok_kind = unsafe { napi::napi_typeof(env, cb, &mut kind) } == NAPI_OK
        && kind == napi::NAPI_TYPE_FUNCTION;
    if !ok_kind {
        return napi::throw(env, &format!("registerHostCallback({name}): second arg must be a function"));
    }
    match unsafe { host_bridge::register(env, &name, cb) } {
        Ok(v) => napi::js_bool(env, v),
        Err(msg) => napi::throw(env, &msg),
    }
}

unsafe extern "C" fn js_unregister_host_callback(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(name) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "unregisterHostCallback(name): name must be a string");
    };
    match host_bridge::unregister(&name) {
        Ok(v) => napi::js_bool(env, v),
        Err(msg) => napi::throw(env, &msg),
    }
}

unsafe extern "C" fn js_resolve_bridge_callback(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(id) = (unsafe { napi::arg_i64(env, info, 0) }) else {
        return napi::throw(env, "resolveBridgeCallback(id, resultJson): id must be a number");
    };
    let result_json = unsafe { napi::arg_string(env, info, 1) }.unwrap_or_default();
    napi::js_bool(env, host_bridge::resolve(id as u64, &result_json))
}

unsafe extern "C" fn js_reject_bridge_callback(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(id) = (unsafe { napi::arg_i64(env, info, 0) }) else {
        return napi::throw(env, "rejectBridgeCallback(id, message): id must be a number");
    };
    let message = unsafe { napi::arg_string(env, info, 1) }.unwrap_or_else(|| "rejected".to_string());
    napi::js_bool(env, host_bridge::reject(id as u64, &message))
}

unsafe extern "C" fn js_cancel_task(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(id) = (unsafe { napi::arg_i64(env, info, 0) }) else {
        return napi::throw(env, "cancelTask(id): id must be a number");
    };
    napi::js_bool(env, engine::cancel_task(id))
}

// ---------------------------------------------------------------- 异步导出

unsafe extern "C" fn js_eval_script(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(code) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "evalScript(code): code must be a string");
    };
    unsafe {
        spawn(env, "evalScript", Box::new(move || engine::eval_script(code)))
    }
}

unsafe extern "C" fn js_bundle_load(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(name) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "bundleLoad(name, source): name must be a string");
    };
    let Some(source) = (unsafe { napi::arg_string(env, info, 1) }) else {
        return napi::throw(env, &format!("bundleLoad({name}): source must be a string"));
    };
    let bytes = source.len();
    unsafe {
        spawn(env, "bundleLoad", Box::new(move || -> Result<engine::Outcome, String> {
            let out = engine::bundle_load(name, source)?;
            engine::note(&format!("bundleLoad done ({bytes}B source)"));
            Ok(out)
        }))
    }
}

unsafe extern "C" fn js_bundle_call(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some((name, fn_path, args_json)) = (unsafe { three_strings(env, info, "bundleCall") }) else {
        return ptr::null_mut();
    };
    unsafe {
        spawn(env, "bundleCall", Box::new(move || {
            engine::bundle_call(name, fn_path, args_json)
        }))
    }
}

unsafe extern "C" fn js_bundle_call_bytes(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some((name, fn_path, args_json)) = (unsafe { three_strings(env, info, "bundleCallBytes") }) else {
        return ptr::null_mut();
    };
    unsafe {
        spawn(env, "bundleCallBytes", Box::new(move || {
            engine::bundle_call_bytes(name, fn_path, args_json)
        }))
    }
}

unsafe extern "C" fn js_bundle_call_once(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(source) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "bundleCallOnce(source, fnPath, argsJson): source must be a string");
    };
    let Some(fn_path) = (unsafe { napi::arg_string(env, info, 1) }) else {
        return napi::throw(env, "bundleCallOnce(source, fnPath, argsJson): fnPath must be a string");
    };
    let args_json = unsafe { napi::arg_string(env, info, 2) }.unwrap_or_else(|| "[]".to_string());
    unsafe {
        spawn(env, "bundleCallOnce", Box::new(move || {
            engine::bundle_call_once(source, fn_path, args_json)
        }))
    }
}

unsafe extern "C" fn js_bundle_unload(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(name) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "bundleUnload(name): name must be a string");
    };
    unsafe { spawn(env, "bundleUnload", Box::new(move || engine::bundle_unload(name))) }
}

unsafe extern "C" fn js_bundle_list(env: NapiEnv, _info: NapiCallbackInfo) -> NapiValue {
    unsafe { spawn(env, "bundleList", Box::new(|| engine::bundle_list())) }
}

/// `bundleLoadFromPath(name, absPath): Promise<string>` —— S4 §14.1，Rust 直读文件省一次大字符串过桥。
unsafe extern "C" fn js_bundle_load_from_path(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(name) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "bundleLoadFromPath(name, absPath): name must be a string");
    };
    let Some(abs_path) = (unsafe { napi::arg_string(env, info, 1) }) else {
        return napi::throw(env, &format!("bundleLoadFromPath({name}): absPath must be a string"));
    };
    unsafe {
        spawn(env, "bundleLoadFromPath", Box::new(move || {
            engine::bundle_load_from_path(name, abs_path)
        }))
    }
}

/// `pluginRemoveFile(absPath): Promise<string>` —— "removed" | "absent"（幂等）。
unsafe extern "C" fn js_plugin_remove_file(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let Some(abs_path) = (unsafe { napi::arg_string(env, info, 0) }) else {
        return napi::throw(env, "pluginRemoveFile(absPath): absPath must be a string");
    };
    unsafe {
        spawn(env, "pluginRemoveFile", Box::new(move || engine::plugin_remove_file(abs_path)))
    }
}

/// `pluginScanDir(relDir): Promise<string>` —— JSON 数组（name/bytes/mtimeMs）。
unsafe extern "C" fn js_plugin_scan_dir(env: NapiEnv, info: NapiCallbackInfo) -> NapiValue {
    let rel_dir = unsafe { napi::arg_string(env, info, 0) }.unwrap_or_else(|| "plugins".to_string());
    unsafe {
        spawn(env, "pluginScanDir", Box::new(move || engine::plugin_scan_dir(rel_dir)))
    }
}

/// `selftest(): Promise<string>` —— 只依赖引擎自身（零网络），供真机面板一次性取证。
unsafe extern "C" fn js_selftest(env: NapiEnv, _info: NapiCallbackInfo) -> NapiValue {
    let script = SELFTEST_JS.to_string();
    unsafe { spawn(env, "selftest", Box::new(move || engine::eval_script(script))) }
}

unsafe fn three_strings(
    env: NapiEnv,
    info: NapiCallbackInfo,
    who: &str,
) -> Option<(String, String, String)> {
    let Some(name) = (unsafe { napi::arg_string(env, info, 0) }) else {
        napi::throw(env, &format!("{who}(name, fnPath, argsJson): name must be a string"));
        return None;
    };
    let Some(fn_path) = (unsafe { napi::arg_string(env, info, 1) }) else {
        napi::throw(env, &format!("{who}: fnPath must be a string"));
        return None;
    };
    let args_json = unsafe { napi::arg_string(env, info, 2) }.unwrap_or_else(|| "[]".to_string());
    Some((name, fn_path, args_json))
}

/// 自检脚本：全局存在性 + 九项行为，输出 JSON（面板直接显示）。
/// ⚠ 输出形态必须匹配面板 `Index.ets` 第 10 行的解析：
///   `globals` = `{名字: 布尔}`（面板判 `g[k] !== true` ⇒ 缺键也算红，必须是**布尔 true**）
///   `probes`  = `{名字: {ok:true,value} | {ok:false,value:null,err}}`（面板双形态兼容，取
///               `v.ok !== true` 判坏、`err ?? value` 显示）
/// 历史坑：S2 版返回的是 `present`(typeof 字符串映射) + 把探针结果平铺在顶层 ⇒ 面板读不到
/// `globals`/`probes` 两个键，第 10 行永远显示 "globals 0/0 probes 0/0"（看着像全挂）。
const SELFTEST_JS: &str = r#"(() => {
  const names = ['fetch','Headers','Request','Response','URL','URLSearchParams','AbortController',
    'AbortSignal','Blob','File','FormData','TextEncoder','TextDecoder','structuredClone','setTimeout',
    'Buffer','crypto','uuidv4','native','bridge','BreezeHtml','atob','btoa','console','fs'];
  const globals = {};
  names.forEach(n => { globals[n] = typeof globalThis[n] !== 'undefined'; });
  const missing = names.filter(n => !globals[n]);
  const probes = {};
  const probe = (name, fn) => {
    try { probes[name] = { ok: true, value: fn() }; }
    catch (e) { probes[name] = { ok: false, value: null, err: (e && e.message ? e.message : String(e)) }; }
  };
  probe('url', () => { const u = new URL('https://a.b/c?x=1#f'); return u.origin + u.pathname + u.search + u.hash; });
  probe('headers', () => { const h = new Headers({'A':'1'}); h.append('b','2'); return h.get('a') + '/' + h.get('B'); });
  probe('buffer', () => { const b = Buffer.from('abc'); return b.length + ':' + b.toString('hex'); });
  probe('cryptoMd5', () => typeof crypto.md5 === 'function' ? 'async-fn' : 'missing');
  probe('gzip', () => typeof (bridge && bridge.gzipDecompress === 'function') ? 'fn' : 'missing');
  probe('breezeHtml', () => typeof BreezeHtml.load('<ul><li>x</li></ul>')('li').text());
  probe('temporal', () => typeof Temporal.Instant);
  probe('abortTimeout', () => typeof AbortSignal.timeout);
  probe('uuid', () => String(uuidv4()).length);
  const failed = Object.keys(probes).filter(k => probes[k].ok !== true);
  return { engine: 'quickjs-ng', globalsTotal: names.length, globalsMissing: missing,
           probesTotal: Object.keys(probes).length, probesFailed: failed, globals, probes };
})()"#;

// ---------------------------------------------------------------- 模块注册

/// ⚠ 导出名**必须**是 NUL 结尾的 C 字符串（`c"…"` 字面量），不能用 `&'static str`。
/// 理由（S2 真机踩过，7 项全 FAIL）：`napi_set_named_property` 的键是 `const char*`
/// （native_api.h:2502-2507，**没有 length 参数**），而 Rust 的 `&'static str` 字面量在
/// .rodata 里会被链接器合并成公共字符串池、**不以 NUL 结尾** ⇒ 第 2 个之后的名字读过去
/// 连成一串垃圾键（实测池子片段 `…lock poisonedokbreeze_qjs_ohosengine…`），只有 `init`
/// 后面凑巧跟了 NUL 才侥幸挂上。`napi_create_function` 虽然收 length，但键仍由
/// set_named_property 决定 ⇒ 必须从源头保证 NUL。
struct ExportSpec {
    name: &'static CStr,
    cb: napi::NapiCallback,
}

static EXPORTS: &[ExportSpec] = &[
    ExportSpec { name: c"init", cb: js_init },
    ExportSpec { name: c"diagnostics", cb: js_diagnostics },
    ExportSpec { name: c"stats", cb: js_stats },
    ExportSpec { name: c"registerHostCallback", cb: js_register_host_callback },
    ExportSpec { name: c"unregisterHostCallback", cb: js_unregister_host_callback },
    ExportSpec { name: c"resolveBridgeCallback", cb: js_resolve_bridge_callback },
    ExportSpec { name: c"rejectBridgeCallback", cb: js_reject_bridge_callback },
    ExportSpec { name: c"cancelTask", cb: js_cancel_task },
    ExportSpec { name: c"evalScript", cb: js_eval_script },
    ExportSpec { name: c"bundleLoad", cb: js_bundle_load },
    ExportSpec { name: c"bundleCall", cb: js_bundle_call },
    ExportSpec { name: c"bundleCallBytes", cb: js_bundle_call_bytes },
    ExportSpec { name: c"bundleCallOnce", cb: js_bundle_call_once },
    ExportSpec { name: c"bundleUnload", cb: js_bundle_unload },
    ExportSpec { name: c"bundleList", cb: js_bundle_list },
    ExportSpec { name: c"selftest", cb: js_selftest },
    // S4 §14.1：三个直接吃路径的导出**必须追加在表尾**（前 16 项顺序是探针/面板的编号基准，不动）。
    ExportSpec { name: c"bundleLoadFromPath", cb: js_bundle_load_from_path },
    ExportSpec { name: c"pluginRemoveFile", cb: js_plugin_remove_file },
    ExportSpec { name: c"pluginScanDir", cb: js_plugin_scan_dir },
];

/// 注册表面。**单项失败不再中断整张表**（S1 版是首个失败即 return ⇒ 一个失败连坐后面全部），
/// 而是继续挂后面的项，最后统一抛错；每项都做一次 `napi_has_named_property` 回读自检，
/// 结果写进 engine 镜像日志 ⇒ `diagnostics()` 的 `log` 字段里能看到
/// `register_module: attached=k/N failures=[…]`（真机无 hilog 时的第二证据链；N=EXPORTS.len()，S4 起为 19）。
unsafe extern "C" fn register_module(env: NapiEnv, exports: NapiValue) -> NapiValue {
    let mut attached: usize = 0;
    let mut failures: Vec<String> = Vec::new();
    for spec in EXPORTS {
        let label = spec.name.to_string_lossy().into_owned();
        let mut func: NapiValue = ptr::null_mut();
        let status = unsafe {
            napi::napi_create_function(
                env,
                spec.name.as_ptr(),
                spec.name.count_bytes(),
                Some(spec.cb),
                ptr::null_mut(),
                &mut func,
            )
        };
        if status != NAPI_OK || func.is_null() {
            failures.push(format!("{label}:create={status}"));
            continue;
        }
        let status = unsafe { napi::napi_set_named_property(env, exports, spec.name.as_ptr(), func) };
        if status != NAPI_OK {
            failures.push(format!("{label}:set={status}"));
            continue;
        }
        let mut has = false;
        let verified =
            unsafe { napi::napi_has_named_property(env, exports, spec.name.as_ptr(), &mut has) } == NAPI_OK
                && has;
        if verified {
            attached += 1;
        } else {
            failures.push(format!("{label}:verify"));
        }
    }
    engine::note(&format!(
        "register_module: attached={attached}/{} failures={failures:?}",
        EXPORTS.len()
    ));
    if !failures.is_empty() {
        napi::throw(env, &format!("breeze_qjs_ohos export failed: {}", failures.join(", ")));
    }
    exports
}

static MODULE: napi::NapiModule = napi::NapiModule {
    nm_version: napi::NAPI_MODULE_VERSION,
    nm_flags: 0,
    nm_filename: b"libbreeze_qjs_ohos.so\0".as_ptr() as *const c_char,
    nm_register_func: Some(register_module),
    // 装载三要件之一：必须等于 so 文件名去掉 lib 前缀与 .so 后缀。
    nm_modname: b"breeze_qjs_ohos\0".as_ptr() as *const c_char,
    nm_priv: ptr::null_mut(),
    reserved: [ptr::null_mut(); 4],
};

#[used]
#[link_section = ".init_array"]
static REGISTER_MODULE: extern "C" fn() = {
    extern "C" fn init() {
        unsafe { napi::napi_module_register(&MODULE) };
    }
    init
};

/// 供 hilog/外部探针确认模块活着（不参与 S2 表面）。ABI 2 = S2/S3 十六导出；ABI 3 = S4 加 bundleLoadFromPath/pluginRemoveFile/pluginScanDir（共 19）。
#[no_mangle]
pub extern "C" fn breeze_qjs_abi_version() -> i32 {
    3
}
