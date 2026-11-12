// 职责：S5h 宿主**原生** bridge 路由（对齐上游 Breeze/rust/src/qjs/mod.rs:1704 init_rust_functions）。
//
// 为什么必须在 Rust 侧、不能由 ArkTS 注册（依据见下，勿再回退）：
//   宿主回调链 `host_bridge::resolve()`（host_bridge.rs:101-118）忠实照抄上游 register_function
//   语义（mod.rs:1691-1695）——回包字符串**原样**作为 Value::String，**不解析**。
//   而上游把 cache.get 注册成 sync handler，返回的是**真 Value**（对象/布尔/数字）。
//   ⇒ 若由 ArkTS 侧注册 cache 路由，插件拿到的是 JSON 字符串，`obj.apiBaseUrl` 取不到，
//     JM 类插件的 `runtime:endpoints` 主机发现链依然失败。只有 Rust 原生 handler 能返回真对象，
//     且省一次 TSFN 往返。
//
// 上游对照（逐条）：
//   cache.get / cache.get.sync      → mod.rs:1753/1757 → handle_cache_get（:366）
//   cache.set / cache.set.sync      → mod.rs:1761/1765 → handle_cache_set（:382）
//   cache.set_if_absent             → mod.rs:1769      → handle_cache_set_if_absent（:406）
//   cache.compare_and_set           → mod.rs:1773      → handle_cache_compare_and_set（:437）
//   cache.delete                    → mod.rs:1777      → 内联 remove
//   opencc.convert                  → mod.rs:1705 blocking handler（**我方为 passthrough，见下**）
//   runtime.gc                      → mod.rs:1787      （**我方 no-op 返回 false，见下**）
//   runtime.is_task_group_cancelled → mod.rs:1793      → 恒 false（我方无任务组取消语义）
//   image.crop_by_regions           → mod.rs:1714      （**未实现**：需要 image 解码 + WebP 编码，
//                                                        上游靠 rust/src/decode 那套；缺它只影响
//                                                        禁漫类拼图插件，不阻塞搜索/详情/章节）
//
// 有意偏差（都写死在这里，别默默改）：
//   1. `opencc.convert` 返回原文（passthrough）。理由：真 opencc 要带词典数据（我方 .rodata 已 5.1MB），
//      且上游 opencc 用在**显示层**繁简转换（Breeze/lib/util/text/chinese_convert.dart），不影响取数。
//      插件只需不再抛 [BRIDGE_CALL_FAILED]。真 opencc 记 TODO。
//   2. `runtime.gc` 返回 false（未回收）。上游会 run_gc；我们在 bridge handler 内调用 run_gc 有
//      自等风险（handler 就跑在 qjs worker 线程上），GC 是 advisory，返回 false 语义安全。
//   3. 缓存条目 TTL 与上游同值 30 分钟；但我们**没有后台 GC ticker**（上游 mod.rs:469
//      ensure_host_cache_gc_started 靠 tokio::spawn）⇒ 改为**读时惰性判过期**，语义等价且无线程成本。
//   4. 存储用 `std::sync::Mutex<HashMap>`，不引入 dashmap（我方 Cargo.toml 无该依赖，值大小 ≤500KB、
//      键数量 = 插件数×几十，锁竞争可忽略）。

use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, Once, OnceLock};
use std::time::{Duration, Instant};

use anyhow::anyhow;
use serde_json::{json, Value};

/// 与上游一致（mod.rs:86）。
const HOST_CACHE_VALUE_MAX_BYTES: usize = 500 * 1024;
/// 与上游 `new_host_cache_entry` 一致（mod.rs:362）：写入即 30 分钟过期。
const HOST_CACHE_TTL: Duration = Duration::from_secs(30 * 60);

struct HostCacheEntry {
    value: Value,
    expires_at: Instant,
}

fn cache_cell() -> &'static Mutex<HashMap<String, HostCacheEntry>> {
    static CACHE: OnceLock<Mutex<HashMap<String, HostCacheEntry>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

/// 与上游 `scoped_route_key` 逐字一致（mod.rs:337）：`{runtime}::{key}`。
fn scoped_key(runtime: &str, key: &str) -> String {
    format!("{runtime}::{key}")
}

fn oversized(value: &Value) -> bool {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len() > HOST_CACHE_VALUE_MAX_BYTES)
        .unwrap_or(true)
}

fn fresh(value: Value) -> HostCacheEntry {
    HostCacheEntry {
        value,
        expires_at: Instant::now() + HOST_CACHE_TTL,
    }
}

/// 上游 handle_cache_get（mod.rs:366-380）：命中返原值，未命中返 args[1] 兜底（缺省 null）。
/// 偏差 3：命中前先判 TTL（上游靠 ticker，我们惰性清）。
fn cache_get(runtime: &str, args: &[Value]) -> Result<Value, anyhow::Error> {
    let key = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("cache.get 参数无效: 缺少 key"))?;
    let fallback = args.get(1).cloned().unwrap_or(Value::Null);
    let scoped = scoped_key(runtime, key);
    let mut guard = cache_cell()
        .lock()
        .map_err(|_| anyhow!("cache lock poisoned"))?;
    let now = Instant::now();
    match guard.get_mut(&scoped) {
        Some(entry) if entry.expires_at > now => Ok(entry.value.clone()),
        Some(_) => {
            // 已过期：清掉并走 fallback（与上游 ticker 收敛后的行为一致）
            guard.remove(&scoped);
            Ok(fallback)
        }
        None => Ok(fallback),
    }
}

/// 上游 handle_cache_set（mod.rs:382-404）：超限**静默 false**（只 warn，不抛）。
fn cache_set(runtime: &str, args: &[Value]) -> Result<Value, anyhow::Error> {
    let key = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("cache.set 参数无效: 缺少 key"))?;
    let value = args.get(1).cloned().unwrap_or(Value::Null);
    if oversized(&value) {
        crate::engine::note(&format!(
            "cache.set skipped oversized: {key} (>{} bytes)",
            HOST_CACHE_VALUE_MAX_BYTES
        ));
        return Ok(json!(false));
    }
    cache_cell()
        .lock()
        .map_err(|_| anyhow!("cache lock poisoned"))?
        .insert(scoped_key(runtime, key), fresh(value));
    Ok(json!(true))
}

/// 上游 handle_cache_set_if_absent（mod.rs:406-435）。
fn cache_set_if_absent(runtime: &str, args: &[Value]) -> Result<Value, anyhow::Error> {
    let key = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("cache.set_if_absent 参数无效: 缺少 key"))?;
    let value = args.get(1).cloned().unwrap_or(Value::Null);
    if oversized(&value) {
        return Ok(json!(false));
    }
    let scoped = scoped_key(runtime, key);
    let mut guard = cache_cell()
        .lock()
        .map_err(|_| anyhow!("cache lock poisoned"))?;
    let expired = guard
        .get(&scoped)
        .map(|e| e.expires_at <= Instant::now())
        .unwrap_or(false);
    if expired {
        guard.remove(&scoped);
    }
    let updated = match guard.entry(scoped) {
        std::collections::hash_map::Entry::Vacant(e) => {
            e.insert(fresh(value));
            true
        }
        std::collections::hash_map::Entry::Occupied(_) => false,
    };
    Ok(json!(updated))
}

/// 上游 handle_cache_compare_and_set（mod.rs:437-467）：值全等才替换。
fn cache_compare_and_set(runtime: &str, args: &[Value]) -> Result<Value, anyhow::Error> {
    let key = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("cache.compare_and_set 参数无效: 缺少 key"))?;
    let expected = args.get(1).cloned().unwrap_or(Value::Null);
    let next = args.get(2).cloned().unwrap_or(Value::Null);
    if oversized(&next) {
        return Ok(json!(false));
    }
    let scoped = scoped_key(runtime, key);
    let mut guard = cache_cell()
        .lock()
        .map_err(|_| anyhow!("cache lock poisoned"))?;
    let updated = match guard.get_mut(&scoped) {
        Some(entry) if entry.value == expected && entry.expires_at > Instant::now() => {
            *entry = fresh(next);
            true
        }
        _ => false,
    };
    Ok(json!(updated))
}

fn cache_delete(runtime: &str, args: &[Value]) -> Result<Value, anyhow::Error> {
    let key = args
        .first()
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("cache.delete 参数无效: 缺少 key"))?;
    let removed = cache_cell()
        .lock()
        .map_err(|_| anyhow!("cache lock poisoned"))?
        .remove(&scoped_key(runtime, key));
    Ok(json!(removed.is_some()))
}

/// opencc.convert：args[0] 必须是 `{text, config}`（上游 opencc_convert_with_json_arg，mod.rs:138）。
/// **有意偏差 1**：校验形状后原样返回 text（不做繁简转换）。形状校验必须保留 —— 插件传错形状时
/// 应该像上游一样报错，否则我们掩盖的是插件 bug 而不是我们的缺口。
fn opencc_passthrough(_runtime: &str, args: &[Value]) -> Result<Value, anyhow::Error> {
    let arg = args
        .first()
        .ok_or_else(|| anyhow!("opencc 需要一个 JSON 参数"))?;
    let obj = arg
        .as_object()
        .ok_or_else(|| anyhow!("opencc.convert 参数必须是 JSON 对象"))?;
    let text = obj
        .get("text")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("opencc.convert 缺少 text 字段"))?;
    obj.get("config")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("opencc.convert 缺少 config 字段（如 t2s.json）"))?;
    Ok(json!(text))
}

static ROUTES_INSTALLED: Once = Once::new();
static NATIVE_CALLS: AtomicUsize = AtomicUsize::new(0);

/// 已注册的原生路由名（诊断面板可读，装包后一眼确认这批改动的确进了 .so）。
pub const NATIVE_ROUTE_NAMES: [&str; 10] = [
    "cache.get",
    "cache.get.sync",
    "cache.set",
    "cache.set.sync",
    "cache.set_if_absent",
    "cache.compare_and_set",
    "cache.delete",
    "opencc.convert",
    "runtime.gc",
    "runtime.is_task_group_cancelled",
];

/// 由 `engine::init()` 首次建运行时时调用（幂等：Once）。
/// 注意顺序：必须在 AsyncHostRuntime 建好之前或之后都安全 —— 这三族路由只碰本模块的
/// HashMap 与 engine::note，不碰运行时句柄，因此不存在初始化环。
pub fn install() {
    ROUTES_INSTALLED.call_once(|| {
        let mut failed: Vec<String> = Vec::new();

        let mut sync: Vec<(&str, fn(&str, &[Value]) -> Result<Value, anyhow::Error>)> = Vec::new();
        sync.push(("cache.get", cache_get));
        sync.push(("cache.get.sync", cache_get));
        sync.push(("cache.set", cache_set));
        sync.push(("cache.set.sync", cache_set));
        sync.push(("cache.set_if_absent", cache_set_if_absent));
        sync.push(("cache.compare_and_set", cache_compare_and_set));
        sync.push(("cache.delete", cache_delete));
        sync.push(("opencc.convert", opencc_passthrough));

        for (name, f) in sync {
            let handler: fn(&str, &[Value]) -> Result<Value, anyhow::Error> = f;
            let result = rquickjs_playground::register_bridge_route_sync_handler(
                name.to_string(),
                move |runtime, args| {
                    NATIVE_CALLS.fetch_add(1, Ordering::Relaxed);
                    handler(&runtime, &args)
                },
            );
            if let Err(e) = result {
                failed.push(format!("{name}: {e}"));
            }
        }

        // runtime.gc ⇒ 有意偏差 2：no-op 返回 false（未回收），不冒自等风险。
        if let Err(e) = rquickjs_playground::register_bridge_route_sync_handler(
            "runtime.gc",
            move |_, _| {
                NATIVE_CALLS.fetch_add(1, Ordering::Relaxed);
                Ok(json!(false))
            },
        ) {
            failed.push(format!("runtime.gc: {e}"));
        }

        // runtime.is_task_group_cancelled ⇒ 恒 false：我方没有任务组取消语义（上游靠
        // CANCELLED_TASK_GROUPS + 120s TTL，取消源是 Dart 侧下拉刷新打断，我们没有）。
        if let Err(e) = rquickjs_playground::register_bridge_route_sync_handler(
            "runtime.is_task_group_cancelled",
            move |_, _| {
                NATIVE_CALLS.fetch_add(1, Ordering::Relaxed);
                Ok(json!(false))
            },
        ) {
            failed.push(format!("runtime.is_task_group_cancelled: {e}"));
        }

        let msg = if failed.is_empty() {
            format!("host_routes installed: {}/10", NATIVE_ROUTE_NAMES.len())
        } else {
            format!(
                "host_routes PARTIAL ({}/10) 失败: {}",
                NATIVE_ROUTE_NAMES.len() - failed.len(),
                failed.join(" | ")
            )
        };
        crate::engine::note(&msg);
    });
}

/// 诊断用：已注册的原生路由被调用过多少次（证明「通到了」而不只是「注册了」）。
pub fn native_call_count() -> usize {
    NATIVE_CALLS.load(Ordering::Relaxed)
}

// ---------------------------------------------------------------- 单元测试（宿主 cargo test --lib）

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cache_get_returns_real_object_not_string() {
        // 这条测试钉住「必须在 Rust 侧注册」的**根因**：handler 返回的必须是 Value::Object。
        let v = cache_set(
            "rt1",
            &[
                json!("runtime:endpoints"),
                json!({"apiBaseUrl": "https://jm.test", "updatedAt": 1}),
            ],
        )
        .unwrap();
        assert_eq!(v, json!(true));
        let got = cache_get("rt1", &[json!("runtime:endpoints"), json!(null)]).unwrap();
        assert!(
            got.is_object(),
            "cache.get 必须返回真对象；返回字符串 ⇒ 插件 obj.apiBaseUrl 取不到（got {got:?}）"
        );
        assert_eq!(got["apiBaseUrl"].as_str(), Some("https://jm.test"));
    }

    #[test]
    fn cache_get_scopes_by_runtime_and_falls_back() {
        cache_set("rtA", &[json!("k"), json!("va")]).unwrap();
        assert_eq!(
            cache_get("rtB", &[json!("k"), json!("fb")]).unwrap(),
            json!("fb"),
            "键必须按 runtime 作用域隔离（上游 scoped_route_key）"
        );
        assert_eq!(
            cache_get("rtA", &[json!("k")]).unwrap(),
            json!("va"),
            "兜底参数缺省时不得影响命中"
        );
        assert_eq!(
            cache_get("rtA", &[json!("nope"), json!(null)]).unwrap(),
            Value::Null
        );
    }

    #[test]
    fn cache_if_absent_and_cas_semantics() {
        cache_set("rt2", &[json!("n"), json!(1)]).unwrap();
        assert_eq!(
            cache_set_if_absent("rt2", &[json!("n"), json!(2)]).unwrap(),
            json!(false),
            "已存在时 set_if_absent 必须 false 且不覆盖"
        );
        assert_eq!(cache_get("rt2", &[json!("n")]).unwrap(), json!(1));
        assert_eq!(
            cache_compare_and_set("rt2", &[json!("n"), json!(9), json!(3)]).unwrap(),
            json!(false),
            "expected 不符必须拒绝"
        );
        assert_eq!(
            cache_compare_and_set("rt2", &[json!("n"), json!(1), json!(3)]).unwrap(),
            json!(true)
        );
        assert_eq!(cache_get("rt2", &[json!("n")]).unwrap(), json!(3));
        assert_eq!(cache_delete("rt2", &[json!("n")]).unwrap(), json!(true));
        assert_eq!(cache_delete("rt2", &[json!("n")]).unwrap(), json!(false));
    }

    #[test]
    fn cache_set_rejects_oversized_silently() {
        let big = json!("x".repeat(HOST_CACHE_VALUE_MAX_BYTES + 8));
        assert_eq!(cache_set("rt3", &[json!("big"), big]).unwrap(), json!(false));
        assert_eq!(
            cache_get("rt3", &[json!("big"), json!("none")]).unwrap(),
            json!("none")
        );
    }

    #[test]
    fn cache_requires_key_argument() {
        assert!(cache_get("rt4", &[]).is_err());
        assert!(cache_set("rt4", &[json!(123)]).is_err());
        assert!(cache_delete("rt4", &[]).is_err());
    }

    #[test]
    fn opencc_passthrough_validates_shape_but_skips_conversion() {
        let out = opencc_passthrough("rt5", &[json!({"text": "問答", "config": "t2s.json"})]).unwrap();
        assert_eq!(out, json!("問答"), "有意偏差 1：passthrough，不改字");
        assert!(opencc_passthrough("rt5", &[]).is_err(), "缺参数必须像上游一样报错");
        assert!(opencc_passthrough("rt5", &[json!("問答")]).is_err(), "非对象必须报错");
        assert!(
            opencc_passthrough("rt5", &[json!({"text": "x"})]).is_err(),
            "缺 config 必须报错（上游同样拒）"
        );
    }

    #[test]
    fn route_names_match_upstream_literals_exactly() {
        // 上游常量原文抄自 Breeze/rust/src/qjs/mod.rs:75-85；一个字符都不能差。
        let expect = [
            "cache.get",
            "cache.get.sync",
            "cache.set",
            "cache.set.sync",
            "cache.set_if_absent",
            "cache.compare_and_set",
            "cache.delete",
            "opencc.convert",
            "runtime.gc",
            "runtime.is_task_group_cancelled",
        ];
        assert_eq!(NATIVE_ROUTE_NAMES, expect);
    }
}
