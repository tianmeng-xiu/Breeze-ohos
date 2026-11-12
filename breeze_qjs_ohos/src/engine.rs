// 职责：S2 引擎层 —— 持有 AsyncHostRuntime 单例 + 一个「驱动」tokio 运行时，
// 把 vendored playground 的 async API 包装成 NAPI 层可直接调用的**同步**函数。
//
// 为什么需要 DRIVER：playground 的 bundle_* 全是 async fn（内部经 Channel 与 qjs worker
// 线程通信），而我们的调用点来自 napi_async_work 的 libuv 线程。上游 Flutter 是在自己的
// FRB tokio 运行时上驱动这些 Future 的，这里等价地建一个 2 线程 multi_thread 运行时：
//   libuv 线程 -> drive(fut) 投给 DRIVER -> oneshot 回包 -> libuv 线程 blocking_recv。
// 死锁红线：blocking_recv 只发生在 libuv 线程；ArkTS 主线程与
// qjs worker 线程都不会被我们阻塞。

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::runtime::{Builder, Runtime};
use tokio::sync::oneshot;

use rquickjs_playground::web_runtime::native_buffer_take_with_http_response;
use rquickjs_playground::{AsyncHostRuntime, AsyncHostRuntimeBuilder, WebRuntimeOptions};

/// bundle 调用默认超时（PLUGIN_ABI §1.3）。
pub const CALL_TIMEOUT: Duration = Duration::from_secs(30);
pub const LOAD_TIMEOUT: Duration = Duration::from_secs(10);

/// 单个插件文件大小上限（S4 §14.1）。实测最大真插件 baozimh-plus 367,534 B ⇒ 8 MB 有足够余量，
/// 同时挡住误投的大文件把 qjs worker 卡死（源文本会整份进 QuickJS 编译）。
pub const MAX_PLUGIN_FILE_BYTES: usize = 8 * 1024 * 1024;

// ---------------------------------------------------------------- 驱动运行时

pub struct Driver {
    runtime: Runtime,
}

static DRIVER: OnceLock<Driver> = OnceLock::new();

fn driver() -> &'static Driver {
    DRIVER.get_or_init(|| {
        let runtime = Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("breeze-driver")
            .enable_all()
            .build()
            .expect("failed to build breeze-driver tokio runtime");
        Driver { runtime }
    })
}

/// 在 DRIVER 上驱动一个 Future，当前线程阻塞等结果；超过 `timeout` ⇒ Err（不再无限等）。
/// 只能在**非** tokio 线程调用（napi_async_work 的 libuv 线程满足）。
/// 注：超时判定发生在 DRIVER 上（enable_all ⇒ time driver 可用），所以即使 qjs worker
/// 永不回包，libuv 线程也一定会拿到 Err 而返回，不会堆积。
pub fn drive<F>(fut: F, timeout: Duration) -> Result<F::Output, String>
where
    F: std::future::Future + Send + 'static,
    F::Output: Send + 'static,
{
    let handle = driver().runtime.handle().clone();
    let (tx, rx) = oneshot::channel::<Result<F::Output, String>>();
    let millis = timeout.as_millis();
    handle.spawn(async move {
        let out = match tokio::time::timeout(timeout, fut).await {
            Ok(v) => Ok(v),
            Err(_) => Err(format!("timeout after {millis}ms")),
        };
        let _ = tx.send(out);
    });
    match rx.blocking_recv() {
        Ok(v) => v,
        Err(_) => Err("driver runtime dropped the request".to_string()),
    }
}

// ---------------------------------------------------------------- 引擎单例

pub struct Engine {
    pub host: AsyncHostRuntime,
    started: Instant,
}

static ENGINE: OnceLock<Mutex<Option<Arc<Engine>>>> = OnceLock::new();
static FS_FLAG: OnceLock<Mutex<bool>> = OnceLock::new();

fn engine_slot() -> &'static Mutex<Option<Arc<Engine>>> {
    ENGINE.get_or_init(|| Mutex::new(None))
}

/// 已装载 bundle 名的 **Rust 侧镜像**（bundle_load/unload 时更新）。
/// diagnostics() 是给 ArkTS 主线程用的同步函数，绝不能在里面对 qjs worker 发起
/// 往返调用（一次在途的 bundleCall 会让主线程等到超时 ⇒ ANR），所以只读镜像。
static BUNDLES: OnceLock<Mutex<std::collections::BTreeSet<String>>> = OnceLock::new();

fn bundles_mirror() -> &'static Mutex<std::collections::BTreeSet<String>> {
    BUNDLES.get_or_init(|| Mutex::new(std::collections::BTreeSet::new()))
}

fn mirror_add(name: &str) {
    if let Ok(mut g) = bundles_mirror().lock() {
        g.insert(name.to_string());
    }
}

fn mirror_remove(name: &str) -> bool {
    bundles_mirror()
        .lock()
        .map(|mut g| g.remove(name))
        .unwrap_or(false)
}

fn mirror_list() -> Vec<String> {
    bundles_mirror()
        .lock()
        .map(|g| g.iter().cloned().collect())
        .unwrap_or_default()
}

/// ring 只装一次（install_default 第二次会返回 Err，忽略即可）。
static TLS_INSTALLED: OnceLock<()> = OnceLock::new();

fn install_tls_provider() {
    if TLS_INSTALLED.set(()).is_err() {
        return;
    }
    // 本移植用 reqwest 的 rustls-no-provider（aws-lc-rs 需 cmake，本机没有），
    // playground 内也没有任何 install_default 调用 ⇒ 必须自己装，否则 fetch 全挂。
    match rustls::crypto::ring::default_provider().install_default() {
        Ok(_) => note("tls: rustls ring provider installed"),
        Err(e) => note(&format!("tls: install_default failed: {e:?}")),
    }
}

/// 宿主下发的插件目录根（ArkTS 传 `context.filesDir`）。
/// ⚠ vendored 的 host-fs **没有任何 jail**：`js/50_fs.js` 全文无路径前缀校验，
/// `web_runtime/fs_ops.rs` 每个 op 直接拿 JS 给的字符串跑 `std::fs::*`
/// （`fs_read_file:210` = `fs::read(&path)`）。所以路径边界只能由我们自己在 JS 侧建：
/// init 时把这个根注入成 `globalThis.__BREEZE_PLUGIN_ROOT`，bundle 只在它下面拼路径。
static STORAGE_ROOT: OnceLock<Mutex<Option<String>>> = OnceLock::new();

fn storage_root() -> Option<String> {
    STORAGE_ROOT
        .get_or_init(|| Mutex::new(None))
        .lock()
        .ok()
        .and_then(|g| g.clone())
}

/// 把根路径写进 Rust 侧镜像 + JS 全局。返回给日志用的描述。
fn apply_storage_root(root: Option<&str>) -> String {
    let Some(raw) = root.map(|s| s.trim()).filter(|s| !s.is_empty()) else {
        // 未传根 ⇒ **保留**既有根（幂等 re-init 传 None 不能把先前设好的根抹掉；
        // 早期版本在这里写 None，任一调用点漏传就把 11/12 行打回 no-storage-root）。
        return match storage_root() {
            Some(cur) => format!("storageRoot kept: {cur}"),
            None => "storageRoot: <none>".to_string(),
        };
    };
    // OHOS 的绝对路径必然以 / 开头；带盘符或相对路径的调用方是误用，直接拒绝而不是悄悄接受，
    // 否则 50_fs.js 会以进程 cwd 解析相对路径，插件就能写到应用沙箱外。
    if !raw.starts_with('/') {
        note(&format!("storageRoot rejected (not absolute): {raw}"));
        return format!("storageRoot rejected: {raw} (kept existing)");
    }
    let trimmed = raw.trim_end_matches('/');
    let trimmed = if trimmed.is_empty() { "/" } else { trimmed };
    if let Ok(mut g) = STORAGE_ROOT.get_or_init(|| Mutex::new(None)).lock() {
        *g = Some(trimmed.to_string());
    }
    // ⚠ 必须是**单个表达式**：eval_script 的 wrap_eval 把代码包进 `await (…) ` 括号里，
    // 语句型脚本（含顶层 `;`）会 SyntaxError ⇒ 注入静默失败（S3 真机 no-storage-root 根因，
    // Node 同构复现见 §13.6）。赋值表达式本身就是表达式，回读值直接拿来验证。
    let stmt = format!("globalThis.__BREEZE_PLUGIN_ROOT = {}", serde_json::json!(trimmed));
    match eval_script(stmt) {
        Ok(Outcome::Str(s)) if s == trimmed => format!("storageRoot set: {trimmed}"),
        Ok(_) => "storageRoot MISMATCH (readback not the root string)".to_string(),
        Err(e) => format!("storageRoot eval failed: {e}"),
    }
}

/// 幂等初始化。`fs=true` 时注入 50_fs.js（需要 cargo feature host-fs，vendored 已默认开）。
/// `storage_root` = 插件目录根（ArkTS `context.filesDir`）；缺省 ⇒ 不注入全局，
/// 依赖它的下载/卸载自测会自己报「未配置插件目录」。
pub fn init(fs: bool, storage_root: Option<String>) -> Result<String, String> {
    install_tls_provider();
    // S5h：注册宿主原生路由（Once 幂等）。必须在建运行时之前 —— 路由表是全局静态的，
    // 先注册可保证任何紧随其后的 bundle 首次 bridge.call 就能命中。
    crate::host_routes::install();
    {
        let mut slot = engine_slot().lock().map_err(|_| "engine lock poisoned".to_string())?;
        if slot.is_some() {
            drop(slot);
            // 已就绪也要重新下发根：ArkTS 侧getContext 可能变化（或首帧没传成功）。
            let msg = apply_storage_root(storage_root.as_deref());
            note(&msg);
            return Ok("ok".to_string());
        }
    }
    *FS_FLAG.get_or_init(|| Mutex::new(fs)).lock().map_err(|_| "lock".to_string())? = fs;

    let host = AsyncHostRuntimeBuilder::new("breeze-ohos")
        .with_options(WebRuntimeOptions { fs })
        .build()
        .map_err(|e| format!("AsyncHostRuntime::build failed: {e}"))?;
    let engine = Arc::new(Engine {
        host,
        started: Instant::now(),
    });
    let mut slot = engine_slot().lock().map_err(|_| "engine lock poisoned".to_string())?;
    *slot = Some(Arc::clone(&engine));
    drop(slot);
    let root_msg = apply_storage_root(storage_root.as_deref());
    note(&format!("engine init ok (fs={fs}) | {root_msg}"));
    Ok("ok".to_string())
}

pub fn engine() -> Result<Arc<Engine>, String> {
    engine_slot()
        .lock()
        .map_err(|_| "engine lock poisoned".to_string())?
        .clone()
        .ok_or_else(|| "engine not initialized: call init() first".to_string())
}

// ---------------------------------------------------------------- 诊断环形日志（面板可见）

static DIAG: OnceLock<Mutex<Vec<String>>> = OnceLock::new();
const DIAG_CAP: usize = 24;

pub fn note(msg: &str) {
    if let Ok(mut g) = DIAG.get_or_init(|| Mutex::new(Vec::new())).lock() {
        if g.len() >= DIAG_CAP {
            g.remove(0);
        }
        g.push(msg.to_string());
    }
}

fn diag_snapshot() -> Vec<String> {
    DIAG.get_or_init(|| Mutex::new(Vec::new()))
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default()
}

pub fn diagnostics() -> String {
    let (pending, running, done, dropped) = match engine() {
        Ok(e) => {
            let s = e.host.stats();
            (s.pending, s.running, s.done, s.dropped)
        }
        Err(_) => (0, 0, 0, 0),
    };
    let bundles = mirror_list();
    let uptime = engine().map(|e| e.started.elapsed().as_secs()).unwrap_or(0);
    json!({
        "build": env!("CARGO_PKG_VERSION"),
        "module": "breeze_qjs_ohos",
        "fs": FS_FLAG.get().and_then(|m| m.lock().ok().map(|v| *v)),
        "storageRoot": storage_root(),
        "storageReady": storage_root().is_some(),
        "engineReady": ENGINE.get().is_some() && engine().is_ok(),
        "uptimeSec": uptime,
        "tasks": { "pending": pending, "running": running, "done": done, "dropped": dropped },
        "bundles": bundles,
        "hostCalls": crate::host_bridge::diagnostics(),
        // S5h：宿主原生路由被调用次数（>0 才算「通到了」，不只是「注册了」）。
        "nativeRouteCalls": crate::host_routes::native_call_count(),
        "log": diag_snapshot(),
    })
    .to_string()
}

// ---------------------------------------------------------------- 调用结果编码

/// 交给 NAPI 层的结果（决定 resolve 成 string/bool/ArrayBuffer 等）。
pub enum Outcome {
    Str(String),
    Bool(bool),
    Strings(Vec<String>),
    Bytes {
        kind: &'static str, // "bytes" | "json"
        bytes: Vec<u8>,
        status_code: i64,
        body_length: i64,
        json: String,
    },
}

// ---------------------------------------------------------------- 具体操作（NAPI 层直接调用）

fn envelope(raw: &str) -> Result<Value, String> {
    let v: Value = serde_json::from_str(raw)
        .map_err(|e| format!("bad envelope from js: {e}: {}", &raw[..raw.len().min(200)]))?;
    if v.get("ok").and_then(Value::as_bool) == Some(true) {
        Ok(v.get("data").cloned().unwrap_or(Value::Null))
    } else {
        let msg = v
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("执行失败")
            .to_string();
        let stack = v.get("stack").and_then(Value::as_str).unwrap_or("");
        let scope = v.get("debug_scope").and_then(Value::as_str).unwrap_or("");
        let mut out = msg;
        if !stack.is_empty() {
            out.push_str(" | ");
            out.push_str(stack);
        }
        if !scope.is_empty() {
            out.push_str(" | ");
            out.push_str(scope);
        }
        Err(out)
    }
}

fn wrap_eval(inner: &str) -> String {
    // 与 playground 的信封约定一致：{ok,data,error,stack}；await 兼容非 Promise 返回值。
    format!(
        r#"(async () => {{ try {{ const data = await ({inner}); return JSON.stringify({{ok:true,data:data===undefined?null:data}}); }} catch (err) {{ return JSON.stringify({{ok:false,error:Error.isError(err)?err.message:String(err||"执行失败"),stack:Error.isError(err)?(err.stack||""):""}}); }} }})()"#
    )
}

pub fn eval_script(code: String) -> Result<Outcome, String> {
    let e = engine()?;
    let script = wrap_eval(&code);
    let started = Instant::now();
    let out = drive(
        async move { e.host.spawn(script).map_err(|e| e.to_string())?.wait_async().await },
        CALL_TIMEOUT,
    )??;
    let data = envelope(&out)?;
    let s = match &data {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    };
    note(&format!("eval ok ({}ms)", started.elapsed().as_millis()));
    Ok(Outcome::Str(s))
}

pub fn bundle_load(name: String, source: String) -> Result<Outcome, String> {
    let e = engine()?;
    let started = Instant::now();
    let name_for_mirror = name.clone();
    let source_len = source.len();
    let res = drive(
        async move { e.host.bundle_load(&name, &source).await },
        LOAD_TIMEOUT,
    )?;
    match res {
        Ok(()) => {
            mirror_add(&name_for_mirror);
            note(&format!(
                "bundle_load ok ({}ms, {source_len}B source)",
                started.elapsed().as_millis()
            ));
            Ok(Outcome::Str("ok".to_string()))
        }
        Err(e2) => {
            note(&format!("bundle_load failed: {}", trunc(&e2, 160)));
            Err(e2)
        }
    }
}

pub fn bundle_call(name: String, fn_path: String, args_json: String) -> Result<Outcome, String> {
    let e = engine()?;
    let args = parse_args(&args_json)?;
    let started = Instant::now();
    let label = format!("{name}::{fn_path}");
    let raw = drive(
        async move {
            e.host
                .bundle_call_start(&name, &fn_path, &args)
                .await?
                .wait_async()
                .await
        },
        CALL_TIMEOUT,
    )??;
    let data = envelope(raw.trim())?;
    note(&format!(
        "bundle_call {label} ok ({}ms)",
        started.elapsed().as_millis()
    ));
    // data 若是二进制 offload 描述（bundle 返回 Uint8Array），bundleCall 也走 JSON 文本，
    // ArkTS 侧要字节请用 bundleCallBytes。
    Ok(Outcome::Str(data.to_string()))
}

/// 二进制版：复刻上游 qjs_fetch_image 的语义（字节 + HTTP 状态码），但不套 CBOR。
pub fn bundle_call_bytes(
    name: String,
    fn_path: String,
    args_json: String,
) -> Result<Outcome, String> {
    let e = engine()?;
    let args = parse_args(&args_json)?;
    let started = Instant::now();
    let label = format!("{name}::{fn_path}");
    let raw = drive(
        async move {
            e.host
                .bundle_call_start(&name, &fn_path, &args)
                .await?
                .wait_async()
                .await
        },
        CALL_TIMEOUT,
    )??;
    let data = envelope(raw.trim())?;
    let buffer_id = data.get("nativeBufferId").and_then(Value::as_u64);
    let is_bytes = data.get("__hostReturnKind").and_then(Value::as_str) == Some("bytes")
        || buffer_id.is_some();
    if is_bytes {
        let id = buffer_id.ok_or_else(|| "bytes return without nativeBufferId".to_string())?;
        let (bytes, http) = native_buffer_take_with_http_response(id)
            .ok_or_else(|| format!("native buffer {id} already taken or expired"))?;
        let status = data
            .get("httpStatusCode")
            .or_else(|| data.get("statusCode"))
            .and_then(Value::as_i64)
            .or_else(|| http.as_ref().map(|h| h.status_code as i64))
            .unwrap_or(0);
        let body_len = data
            .get("httpResponseBodyLength")
            .or_else(|| data.get("bodyLength"))
            .and_then(Value::as_i64)
            .or_else(|| http.as_ref().map(|h| h.body_length as i64))
            .unwrap_or(bytes.len() as i64);
        note(&format!(
            "bundle_call_bytes {label} -> {len}B status={status} ({}ms)",
            started.elapsed().as_millis(),
            len = bytes.len()
        ));
        return Ok(Outcome::Bytes {
            kind: "bytes",
            bytes,
            status_code: status,
            body_length: body_len,
            json: String::new(),
        });
    }
    let json = data.to_string();
    note(&format!(
        "bundle_call_bytes {label} -> json ({}ms)",
        started.elapsed().as_millis()
    ));
    Ok(Outcome::Bytes {
        kind: "json",
        bytes: json.clone().into_bytes(),
        status_code: 0,
        body_length: json.len() as i64,
        json,
    })
}

pub fn bundle_call_once(source: String, fn_path: String, args_json: String) -> Result<Outcome, String> {
    let e = engine()?;
    let args = parse_args(&args_json)?;
    let started = Instant::now();
    let label = fn_path.clone();
    let raw = drive(
        async move {
            e.host
                .bundle_call_once_start(&source, &fn_path, &args)
                .await?
                .wait_async()
                .await
        },
        CALL_TIMEOUT,
    )??;
    let data = envelope(raw.trim())?;
    note(&format!(
        "bundle_call_once::{label} ok ({}ms)",
        started.elapsed().as_millis()
    ));
    Ok(Outcome::Str(data.to_string()))
}

pub fn bundle_unload(name: String) -> Result<Outcome, String> {
    let e = engine()?;
    let label = name.clone();
    let removed = drive(async move { e.host.bundle_unload(&name).await }, CALL_TIMEOUT)??;
    let mirrored = mirror_remove(&label);
    note(&format!("bundle_unload {label} -> {removed}"));
    Ok(Outcome::Bool(removed || mirrored))
}

pub fn bundle_list() -> Result<Outcome, String> {
    let e = engine()?;
    let names = drive(async move { e.host.bundle_list().await }, CALL_TIMEOUT)??;
    Ok(Outcome::Strings(names))
}

// ---------------------------------------------------------------- 插件文件（S4 §14.1）
//
// 这三个导出**直接吃路径**，而 vendored 的 host-fs 没有任何 jail（§12.2），
// 所以 jail 必须在 Rust 侧自己做，不能信 ArkTS 传来的路径。

/// 把调用方给的路径约束在 `<storage_root>/` 之下。返回规范化后的绝对路径。
/// 拒绝：无根 / 非绝对 / 含 `..` 分量 / 不在根之下（含 `/…/filesX` 这类等长前缀兄弟目录）。
pub fn jail_path(abs: &str) -> Result<String, String> {
    let root = storage_root().ok_or_else(|| "no-storage-root (init 未传 filesDir)".to_string())?;
    let raw = abs.trim();
    if !raw.starts_with('/') {
        return Err(format!("path must be absolute: {raw}"));
    }
    if raw.split('/').any(|seg| seg == "..") {
        return Err(format!("path must not contain '..': {raw}"));
    }
    // 归一化重复斜杠与结尾斜杠，避免 `/a//b` 之类绕过前缀比较
    let segs: Vec<&str> = raw.split('/').filter(|s| !s.is_empty() && *s != ".").collect();
    let norm = format!("/{}", segs.join("/"));
    if !(norm.as_str() == root.as_str()
        || (norm.len() > root.len() && norm.starts_with(root.as_str())
            && norm.as_bytes()[root.len()] == b'/'))
    {
        return Err(format!("path escapes plugin root {root}: {norm}"));
    }
    Ok(norm)
}

/// `bundleLoadFromPath(name, absPath)` —— Rust 直接读文件再装载，省掉源文本二次过 NAPI 桥。
pub fn bundle_load_from_path(name: String, abs_path: String) -> Result<Outcome, String> {
    let path = jail_path(&abs_path)?;
    let bytes = std::fs::read(&path).map_err(|e| format!("read {path} failed: {e}"))?;
    if bytes.is_empty() {
        return Err(format!("{path} is empty"));
    }
    if bytes.len() > MAX_PLUGIN_FILE_BYTES {
        return Err(format!("{path} too large: {}B > {}B", bytes.len(), MAX_PLUGIN_FILE_BYTES));
    }
    let source = String::from_utf8(bytes)
        .map_err(|e| format!("{path} is not valid UTF-8: {e}"))?;
    let len = source.len();
    note(&format!("bundleLoadFromPath {name} <- {} ({len}B)", trunc(&path, 120)));
    bundle_load(name, source).map_err(|e| {
        note(&format!("bundleLoadFromPath failed: {}", trunc(&e, 160)));
        e
    })
}

/// `pluginRemoveFile(absPath)` —— 幂等删除；返回 "removed" / "absent"。
pub fn plugin_remove_file(abs_path: String) -> Result<Outcome, String> {
    let path = jail_path(&abs_path)?;
    match std::fs::remove_file(&path) {
        Ok(()) => {
            note(&format!("pluginRemoveFile removed {}", trunc(&path, 120)));
            Ok(Outcome::Str("removed".to_string()))
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Outcome::Str("absent".to_string())),
        Err(e) => Err(format!("remove {path} failed: {e}")),
    }
}

/// `pluginScanDir(relDir)` —— 列根下子目录里的 *.cjs/*.js（name/bytes/mtimeMs，按 name 升序）。
/// `relDir` 是**相对** STORAGE_ROOT 的路径（如 "plugins"），不接受绝对写法。
pub fn plugin_scan_dir(rel_dir: String) -> Result<Outcome, String> {
    let root = storage_root().ok_or_else(|| "no-storage-root (init 未传 filesDir)".to_string())?;
    let rel = rel_dir.trim().trim_matches('/');
    if rel.starts_with('/') || rel.split('/').any(|s| s == "..") {
        return Err(format!("relDir must be relative and contain no '..': {rel_dir}"));
    }
    let dir = if rel.is_empty() { root.clone() } else { format!("{root}/{rel}") };
    let entries = match std::fs::read_dir(&dir) {
        Ok(it) => it,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Outcome::Str("[]".to_string())),
        Err(e) => return Err(format!("read_dir {dir} failed: {e}")),
    };
    let mut out: Vec<Value> = Vec::new();
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !(name.ends_with(".cjs") || name.ends_with(".js")) {
            continue;
        }
        let meta = match entry.metadata() {
            Ok(m) if m.is_file() => m,
            _ => continue,
        };
        let mtime = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_millis() as i64)
            .unwrap_or(0);
        out.push(json!({ "name": name, "bytes": meta.len(), "mtimeMs": mtime }));
    }
    out.sort_by(|a, b| a["name"].as_str().unwrap_or("").cmp(b["name"].as_str().unwrap_or("")));
    Ok(Outcome::Str(Value::Array(out).to_string()))
}

pub fn stats() -> String {
    match engine() {
        Ok(e) => {
            let s = e.host.stats();
            json!({"pending":s.pending,"running":s.running,"done":s.done,"dropped":s.dropped})
                .to_string()
        }
        Err(_) => json!({"error":"engine not initialized"}).to_string(),
    }
}

pub fn cancel_task(id: i64) -> bool {
    match engine() {
        Ok(e) => e.host.cancel(id as u64),
        Err(_) => false,
    }
}

// ---------------------------------------------------------------- 工具

fn parse_args(args_json: &str) -> Result<Value, String> {
    let trimmed = args_json.trim();
    if trimmed.is_empty() || trimmed == "null" || trimmed == "undefined" {
        return Ok(json!([]));
    }
    let v: Value = serde_json::from_str(trimmed)
        .map_err(|e| format!("argsJson must be a JSON array string: {e}"))?;
    if !v.is_array() {
        return Err(format!("argsJson must decode to a JSON array, got {v}"));
    }
    Ok(v)
}

pub(crate) fn trunc(s: &str, n: usize) -> String {
    if s.len() <= n {
        s.to_string()
    } else {
        let cut = s
            .char_indices()
            .take_while(|(i, _)| *i < n)
            .last()
            .map(|(i, c)| i + c.len_utf8())
            .unwrap_or(n);
        format!("{}…", &s[..cut])
    }
}

pub(crate) fn next_id() -> u64 {
    static SEQ: AtomicU64 = AtomicU64::new(1);
    SEQ.fetch_add(1, Ordering::SeqCst)
}

// ---------------------------------------------------------------- 单元测试（宿主 `cargo test --lib`）

#[cfg(test)]
mod tests {
    use super::*;

    fn set_root(root: &str) {
        *STORAGE_ROOT.get_or_init(|| Mutex::new(None)).lock().unwrap() = Some(root.to_string());
    }

    #[test]
    fn jail_accepts_only_children_of_root() {
        set_root("/data/storage/el2/base/haps/entry/files");
        let ok = [
            "/data/storage/el2/base/haps/entry/files/plugins/a.cjs",
            "/data/storage/el2/base/haps/entry/files/a.cjs",
            "/data/storage/el2/base/haps/entry/files/plugins//a.cjs",
            "/data/storage/el2/base/haps/entry/files",
        ];
        for p in ok {
            assert!(jail_path(p).is_ok(), "should accept {p}, got {:?}", jail_path(p));
        }
        assert_eq!(
            jail_path("/data/storage/el2/base/haps/entry/files//plugins//a.cjs").unwrap(),
            "/data/storage/el2/base/haps/entry/files/plugins/a.cjs"
        );
    }

    #[test]
    fn jail_rejects_escapes_and_lookalikes() {
        set_root("/data/storage/el2/base/haps/entry/files");
        let bad = [
            "plugins/a.cjs",                                              // 相对路径
            "E:/x/a.cjs",                                                 // 盘符
            "/data/storage/el2/base/haps/entry/filesX/a.cjs",             // 等长前缀兄弟目录
            "/data/storage/el2/base/haps/entry/fi/a.cjs",                 // 更短前缀
            "/data/storage/el2/base/haps/entry/files/../filesX/a.cjs",    // .. 分量
            "/data/storage/el2/base/haps/entry/files/../../etc/passwd",   // .. 逃逸
            "/etc/passwd",                                                // 完全无关
        ];
        for p in bad {
            assert!(jail_path(p).is_err(), "should reject {p}");
        }
    }

    #[test]
    fn jail_requires_root() {
        *STORAGE_ROOT.get_or_init(|| Mutex::new(None)).lock().unwrap() = None;
        assert!(jail_path("/data/storage/el2/base/haps/entry/files/a.cjs").is_err());
    }

    #[test]
    fn wrap_eval_only_takes_expressions() {
        // §13.6 红线：语句序列会被 await( … ) 括号吃成语法错 ⇒ 注入必须写成表达式。
        // 这条测试钉住"表达式形态"这一约定本身（真机 no-storage-root 的根因）。
        let stmt = format!("globalThis.__BREEZE_PLUGIN_ROOT = {}", serde_json::json!("/root"));
        let wrapped = wrap_eval(&stmt);
        assert!(wrapped.contains(&format!("await ({stmt})")), "wrap shape changed: {wrapped}");
        // 旧写法（语句 + 顶层分号）不应该再出现在任何注入点
        let legacy = "globalThis.__BREEZE_PLUGIN_ROOT = \"/root\"; 'set'";
        assert!(legacy.contains(';'));
    }
}
