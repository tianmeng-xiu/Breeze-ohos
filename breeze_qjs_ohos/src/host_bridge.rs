// 职责：S2 宿主回调桥 —— 把 vendored playground 的 bridge 路由转发给 ArkTS 侧回调。
//
// 链路：
//   JS `bridge.call(name,...)` → playground __host_call_route_mode → 本模块注册的 async handler
//   → 生成 replyId + oneshot → napi_call_threadsafe_function 投递到 ArkTS 主线程
//   → ArkTS 用户回调执行 → resolveBridgeCallback(replyId, json) → 本模块 resolve ⇒ handler 完成。
//
// 死锁红线：handler 闭包内**零阻塞**（只 await oneshot，带 15s timeout）。它运行在 qjs worker
// 线程的 current_thread tokio 上（host_runtime.rs:848 enable_all ⇒ time driver 可用），
// ArkTS 主线程不会等它，反向回包来自主线程自身 ⇒ 不存在互等。

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CString};
use std::ptr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use anyhow::anyhow;
use serde_json::{json, Value};
use tokio::sync::oneshot;

use crate::napi::{
    self, NapiEnv, NapiThreadsafeFunction, NapiValue, NAPI_OK, NAPI_TSFN_NONBLOCKING,
    NAPI_TSFN_RELEASE,
};

/// 与上游 `REGISTERED_DART_CALLBACK_TIMEOUT` 一致（Breeze/rust/src/qjs/mod.rs:74 附近）。
pub const HOST_CALLBACK_TIMEOUT: Duration = Duration::from_secs(15);

/// TSFN 队列上限：与 playground BRIDGE_MAX_PENDING(4096) 同量级但更小，
/// 超出时 napi_call_threadsafe_function 返回 queue_full ⇒ 立刻报错给插件而不是堆积。
const TSFN_MAX_QUEUE: usize = 512;

// ---------------------------------------------------------------- TSFN 句柄包装

/// `napi_threadsafe_function` 是裸指针；它本身就是为跨线程设计的，Send/Sync 语义由 NAPI 保证。
#[derive(Clone, Copy)]
pub struct TsfnHandle(NapiThreadsafeFunction);

unsafe impl Send for TsfnHandle {}
unsafe impl Sync for TsfnHandle {}

impl TsfnHandle {
    /// 通过方法调用捕获整个句柄（Rust 2021 的闭包是**逐字段**捕获，
    /// 闭包里直接写 `handle.0` 会把裸指针本身捕获进去 ⇒ Send/Sync 又没了）。
    /// # Safety
    /// 见 `napi_call_threadsafe_function`。
    unsafe fn call(&self, data: *mut c_void, mode: i32) -> napi::NapiStatus {
        unsafe { napi::napi_call_threadsafe_function(self.0, data, mode) }
    }
}

/// 投递给 ArkTS 主线程的负载（call_js_cb 里 Box::from_raw 回收）。
struct TsfnPayload {
    reply_id: u64,
    route: String,
    input_json: String,
}

struct RouteEntry {
    tsfn: TsfnHandle,
    /// 累计转发次数（诊断面板用）
    calls: Arc<std::sync::atomic::AtomicU64>,
}

static ROUTES: OnceLock<Mutex<HashMap<String, RouteEntry>>> = OnceLock::new();

fn routes() -> &'static Mutex<HashMap<String, RouteEntry>> {
    ROUTES.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn registered_routes() -> Vec<String> {
    routes()
        .lock()
        .map(|m| {
            let mut v: Vec<String> = m.keys().cloned().collect();
            v.sort();
            v
        })
        .unwrap_or_default()
}

// ---------------------------------------------------------------- pending 回包表

static PENDING: OnceLock<Mutex<HashMap<u64, PendingEntry>>> = OnceLock::new();
static NEXT_REPLY_ID: AtomicU64 = AtomicU64::new(1);

struct PendingEntry {
    tx: oneshot::Sender<Value>,
    route: String,
    at: Instant,
}

fn pending() -> &'static Mutex<HashMap<u64, PendingEntry>> {
    PENDING.get_or_init(|| Mutex::new(HashMap::new()))
}

/// ArkTS 侧 `resolveBridgeCallback(id, resultJson)`。
/// 上游语义（mod.rs:1666-1702）：回包字符串**原样**作为结果值（不解析）；空串 ⇒ null。
pub fn resolve(reply_id: u64, result_json: &str) -> bool {
    let entry = pending()
        .lock()
        .ok()
        .and_then(|mut m| m.remove(&reply_id));
    match entry {
        Some(PendingEntry { tx, .. }) => {
            let value = if result_json.is_empty() {
                Value::Null
            } else {
                Value::String(result_json.to_string())
            };
            // 接收端可能已因超时 drop ⇒ 忽略 SendError
            tx.send(value).is_ok()
        }
        None => false,
    }
}

/// ArkTS 侧 `rejectBridgeCallback(id, message)`（或回调抛异常时由 call_js_cb 自动调用）。
pub fn reject(reply_id: u64, message: &str) -> bool {
    let entry = pending()
        .lock()
        .ok()
        .and_then(|mut m| m.remove(&reply_id));
    match entry {
        // Err 分支在 handler 里转成 anyhow::Error ⇒ playground 包成 BRIDGE_CALL_FAILED 给 JS
        Some(PendingEntry { tx, .. }) => tx.send(json!({ "__hostBridgeError": message })).is_ok(),
        None => false,
    }
}

pub fn pending_count() -> usize {
    pending().lock().map(|m| m.len()).unwrap_or(0)
}

// ---------------------------------------------------------------- call_js_cb

/// TSFN 的 call_js_cb：**在 ArkTS 主线程被 napi 调用**。
/// `js_callback` 就是 create_threadsafe_function 时传入的那个 func（napi 原样带回），
/// argv = [inputJson:string, replyId:number]。
/// # Safety
/// napi 运行时调用；`data` 必须是 `Box::into_raw(Box::new(TsfnPayload))`。
pub unsafe extern "C" fn call_js_bridge(
    env: NapiEnv,
    js_callback: NapiValue,
    _context: *mut c_void,
    data: *mut c_void,
) {
    if data.is_null() {
        return;
    }
    let payload = unsafe { Box::from_raw(data as *mut TsfnPayload) };
    let reply_id = payload.reply_id;
    let route = payload.route.clone();
    if js_callback.is_null() {
        let _ = reject(reply_id, &format!("host callback for {route} is not a function"));
        return;
    }
    let input_value = unsafe { napi::js_string(env, &payload.input_json) };
    let mut id_value: NapiValue = ptr::null_mut();
    unsafe {
        napi::napi_create_int64(env, reply_id as i64, &mut id_value);
    }
    let argv = [input_value, id_value];
    let mut result: NapiValue = ptr::null_mut();
    let status = unsafe {
        napi::napi_call_function(
            env,
            napi::js_undefined(env),
            js_callback,
            2,
            argv.as_ptr(),
            &mut result,
        )
    };
    // 回调同步抛异常 ⇒ 立刻 reject，避免插件侧干等 15s
    if status != NAPI_OK {
        let _ = reject(
            reply_id,
            &format!("host callback threw for route {route} (napi status {status})"),
        );
    }
}

// ---------------------------------------------------------------- 注册 / 注销

/// # Safety
/// `env` 必须是 ArkTS 主线程的有效 napi_env（registerHostCallback 从 ArkTS 调用 ⇒ 满足）。
pub unsafe fn register(env: NapiEnv, name: &str, js_callback: NapiValue) -> Result<bool, String> {
    if name.is_empty() {
        return Err("route name must not be empty".to_string());
    }
    if js_callback.is_null() {
        return Err(format!("host callback for {name} is not a function"));
    }

    let label = format!("breeze-host-{}", name);
    let mut resource_name: NapiValue = ptr::null_mut();
    unsafe {
        napi::napi_create_string_utf8(
            env,
            label.as_ptr() as *const c_char,
            label.len(),
            &mut resource_name,
        );
    }
    let mut tsfn: NapiThreadsafeFunction = ptr::null_mut();
    let status = unsafe {
        napi::napi_create_threadsafe_function(
            env,
            js_callback,
            ptr::null_mut(),
            resource_name,
            TSFN_MAX_QUEUE,
            1,
            ptr::null_mut(),
            None,
            ptr::null_mut(),
            Some(call_js_bridge),
            &mut tsfn,
        )
    };
    if status != NAPI_OK || tsfn.is_null() {
        return Err(format!("napi_create_threadsafe_function failed: status {status}"));
    }
    let handle = TsfnHandle(tsfn);
    let counter = Arc::new(std::sync::atomic::AtomicU64::new(0));

    let route_name = name.to_string();
    let counted = Arc::clone(&counter);
    let handler = move |runtime_name: String, args: Vec<Value>| {
        let name_for_msg = route_name.clone();
        let counted = Arc::clone(&counted);
        async move {
            counted.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            let reply_id = NEXT_REPLY_ID.fetch_add(1, Ordering::SeqCst);
            let (tx, rx) = oneshot::channel::<Value>();
            pending()
                .lock()
                .map_err(|_| anyhow!("pending table poisoned"))?
                .insert(
                    reply_id,
                    PendingEntry {
                        tx,
                        route: name_for_msg.clone(),
                        at: Instant::now(),
                    },
                );
            // 与上游 register_function 逐字一致：入参 = JSON.stringify([runtimeName, ...args])
            let input_json = encode_input(&runtime_name, &args);

            let payload = Box::new(TsfnPayload {
                reply_id,
                route: name_for_msg.clone(),
                input_json,
            });
            let call_status = unsafe { handle.call(Box::into_raw(payload) as *mut c_void, NAPI_TSFN_NONBLOCKING) };
            if call_status != NAPI_OK {
                let _ = pending().lock().map(|mut m| m.remove(&reply_id));
                return Err(anyhow!(
                    "napi_call_threadsafe_function({name_for_msg}) failed: status {call_status}"
                ));
            }
            match tokio::time::timeout(HOST_CALLBACK_TIMEOUT, rx).await {
                Ok(Ok(Value::Object(obj))) if obj.get("__hostBridgeError").is_some() => {
                    let msg = obj
                        .get("__hostBridgeError")
                        .and_then(Value::as_str)
                        .unwrap_or("host callback rejected")
                        .to_string();
                    Err(anyhow!("host callback failed: {msg}"))
                }
                Ok(Ok(value)) => Ok(value),
                Ok(Err(_)) => {
                    let _ = pending().lock().map(|mut m| m.remove(&reply_id));
                    Err(anyhow!("host callback channel closed: {name_for_msg}"))
                }
                Err(_) => {
                    let _ = pending().lock().map(|mut m| m.remove(&reply_id));
                    Err(anyhow!(
                        "host callback timeout after {}ms: {name_for_msg}",
                        HOST_CALLBACK_TIMEOUT.as_millis()
                    ))
                }
            }
        }
    };

    rquickjs_playground::register_bridge_route_async_handler(name, handler)
        .map_err(|e| format!("register_bridge_route_async_handler({name}) failed: {e}"))?;

    let old = routes()
        .lock()
        .map_err(|_| "routes table poisoned".to_string())?
        .insert(
            name.to_string(),
            RouteEntry {
                tsfn: handle,
                calls: counter,
            },
        );
    if let Some(old) = old {
        // 同名替换：释放旧 TSFN（在途 replyId 靠 timeout 自净）
        unsafe {
            napi::napi_release_threadsafe_function(old.tsfn.0, NAPI_TSFN_RELEASE);
        }
    }
    crate::engine::note(&format!("registerHostCallback {name}"));
    Ok(true)
}

/// `JSON.stringify([runtimeName, ...args])` 的等价拼接（避免再解析一次）。
fn encode_input(runtime_name: &str, args: &[Value]) -> String {
    let mut out = String::with_capacity(64 + args.len() * 32);
    out.push('[');
    out.push_str(&Value::String(runtime_name.to_string()).to_string());
    for v in args {
        out.push(',');
        out.push_str(&v.to_string());
    }
    out.push(']');
    out
}

pub fn unregister(name: &str) -> Result<bool, String> {
    let removed_playground = rquickjs_playground::unregister_bridge_route_handler(name)
        .map_err(|e| format!("unregister_bridge_route_handler({name}) failed: {e}"))?;
    let removed_entry = routes()
        .lock()
        .map_err(|_| "routes table poisoned".to_string())?
        .remove(name);
    let had_entry = removed_entry.is_some();
    if let Some(entry) = removed_entry {
        unsafe {
            napi::napi_release_threadsafe_function(entry.tsfn.0, NAPI_TSFN_RELEASE);
        }
    }
    crate::engine::note(&format!("unregisterHostCallback {name}"));
    Ok(removed_playground || had_entry)
}

/// 诊断（并入 engine::diagnostics 的 hostCalls 字段）。
pub fn diagnostics() -> Value {
    let routes: Vec<Value> = routes()
        .lock()
        .map(|m| {
            let mut items: Vec<(&String, &RouteEntry)> = m.iter().collect();
            items.sort_by_key(|(k, _)| k.as_str());
            items
                .into_iter()
                .map(|(name, e)| {
                    json!({
                        "name": name,
                        "calls": e.calls.load(std::sync::atomic::Ordering::Relaxed),
                    })
                })
                .collect()
        })
        .unwrap_or_default();
    let oldest = pending()
        .lock()
        .map(|m| {
            m.values()
                .map(|p| p.at.elapsed().as_millis() as u64)
                .max()
                .unwrap_or(0)
        })
        .unwrap_or(0);
    json!({
        "routes": routes,
        "pendingCallbacks": pending_count(),
        "oldestPendingMs": oldest,
        "timeoutMs": HOST_CALLBACK_TIMEOUT.as_millis(),
    })
}

/// 错误消息可能带 NUL，转 CString 前清掉。
pub fn safe_cstring(s: &str) -> CString {
    CString::new(s.replace('\0', " ")).unwrap_or_default()
}
