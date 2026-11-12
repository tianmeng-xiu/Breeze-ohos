// 职责：手写 OHOS NAPI C ABI 声明 + 跨模块共用的取值/构造小工具。
// 不用 napi-rs：S1 已验证「extern "C" + .init_array 注册」在 OHOS 7 / API26 真机可用，
// 且避免多一层 proc-macro 依赖。签名逐条对齐 OpenHarmony native SDK 头文件
// <native SDK>/sysroot/usr/include/napi/native_api.h
// （napi_finalize / napi_async_*_callback / napi_threadsafe_function_call_js 见
//   js_native_api_types.h:108-112 与 node_api_types.h:8-35）。

use std::ffi::{c_char, c_void, CString};
use std::ptr;

pub type NapiEnv = *mut c_void;
pub type NapiValue = *mut c_void;
pub type NapiCallbackInfo = *mut c_void;
pub type NapiStatus = i32;
pub type NapiDeferred = *mut c_void;
pub type NapiAsyncWork = *mut c_void;
pub type NapiThreadsafeFunction = *mut c_void;

pub type NapiCallback = unsafe extern "C" fn(NapiEnv, NapiCallbackInfo) -> NapiValue;
pub type NapiAsyncExecuteCallback = unsafe extern "C" fn(NapiEnv, *mut c_void);
pub type NapiAsyncCompleteCallback = unsafe extern "C" fn(NapiEnv, NapiStatus, *mut c_void);
pub type NapiThreadsafeFunctionCallJs =
    unsafe extern "C" fn(NapiEnv, NapiValue, *mut c_void, *mut c_void);
/// `typedef void (*napi_finalize)(napi_env, void* finalize_data, void* finalize_hint)`
pub type NapiFinalize = unsafe extern "C" fn(NapiEnv, *mut c_void, *mut c_void);

#[repr(C)]
pub struct NapiModule {
    pub nm_version: i32,
    pub nm_flags: u32,
    pub nm_filename: *const c_char,
    pub nm_register_func: Option<unsafe extern "C" fn(NapiEnv, NapiValue) -> NapiValue>,
    pub nm_modname: *const c_char,
    pub nm_priv: *mut c_void,
    pub reserved: [*mut c_void; 4],
}

unsafe impl Sync for NapiModule {}

pub const NAPI_OK: NapiStatus = 0;
pub const NAPI_MODULE_VERSION: i32 = 1;
/// napi_tsfn_release / napi_tsfn_abort（node_api_types.h:14-17）
pub const NAPI_TSFN_RELEASE: i32 = 0;
/// napi_tsfn_nonblocking（node_api_types.h:19-22）
pub const NAPI_TSFN_NONBLOCKING: i32 = 0;
/// napi_valuetype::napi_boolean（js_native_api_types.h:45-57）
pub const NAPI_TYPE_BOOLEAN: i32 = 2;
/// napi_valuetype::napi_function
pub const NAPI_TYPE_FUNCTION: i32 = 7;

extern "C" {
    pub fn napi_module_register(module: *const NapiModule);

    pub fn napi_create_function(
        env: NapiEnv,
        utf8name: *const c_char,
        length: usize,
        cb: Option<NapiCallback>,
        data: *mut c_void,
        result: *mut NapiValue,
    ) -> NapiStatus;
    pub fn napi_set_named_property(
        env: NapiEnv,
        object: NapiValue,
        utf8name: *const c_char,
        value: NapiValue,
    ) -> NapiStatus;
    /// key 版（napi_value 作键）；`napi_set_named_property` 的键是 `const char*`，别混用。
    pub fn napi_set_property(
        env: NapiEnv,
        object: NapiValue,
        key: NapiValue,
        value: NapiValue,
    ) -> NapiStatus;
    /// 回读自检用（native_api.h:2540-2543）。键同样是 `const char*`（NUL 结尾）。
    pub fn napi_has_named_property(
        env: NapiEnv,
        object: NapiValue,
        utf8name: *const c_char,
        result: *mut bool,
    ) -> NapiStatus;
    pub fn napi_get_cb_info(
        env: NapiEnv,
        cbinfo: NapiCallbackInfo,
        argc: *mut usize,
        argv: *mut NapiValue,
        this_arg: *mut NapiValue,
        data: *mut *mut c_void,
    ) -> NapiStatus;
    pub fn napi_create_string_utf8(
        env: NapiEnv,
        s: *const c_char,
        length: usize,
        result: *mut NapiValue,
    ) -> NapiStatus;
    pub fn napi_get_value_string_utf8(
        env: NapiEnv,
        value: NapiValue,
        buf: *mut c_char,
        bufsize: usize,
        result: *mut usize,
    ) -> NapiStatus;
    pub fn napi_get_value_int64(env: NapiEnv, value: NapiValue, result: *mut i64) -> NapiStatus;
    pub fn napi_get_value_bool(env: NapiEnv, value: NapiValue, result: *mut bool) -> NapiStatus;
    pub fn napi_create_int64(env: NapiEnv, value: i64, result: *mut NapiValue) -> NapiStatus;
    pub fn napi_create_double(env: NapiEnv, value: f64, result: *mut NapiValue) -> NapiStatus;
    pub fn napi_get_boolean(env: NapiEnv, value: bool, result: *mut NapiValue) -> NapiStatus;
    /// `napi_valuetype`：napi_undefined=0, napi_null=1, napi_boolean=2, napi_number=3,
    /// napi_string=4, napi_symbol=5, napi_object=6, napi_function=7, napi_external=8, napi_bigint=9
    /// （js_native_api_types.h:45-57）
    pub fn napi_typeof(env: NapiEnv, value: NapiValue, result: *mut i32) -> NapiStatus;
    pub fn napi_create_object(env: NapiEnv, result: *mut NapiValue) -> NapiStatus;
    pub fn napi_create_array(env: NapiEnv, result: *mut NapiValue) -> NapiStatus;
    pub fn napi_set_element(
        env: NapiEnv,
        object: NapiValue,
        index: u32,
        value: NapiValue,
    ) -> NapiStatus;
    pub fn napi_get_undefined(env: NapiEnv, result: *mut NapiValue) -> NapiStatus;
    pub fn napi_throw_error(env: NapiEnv, code: *const c_char, msg: *const c_char) -> NapiStatus;

    // Promise
    pub fn napi_create_promise(
        env: NapiEnv,
        deferred: *mut NapiDeferred,
        promise: *mut NapiValue,
    ) -> NapiStatus;
    pub fn napi_resolve_deferred(
        env: NapiEnv,
        deferred: NapiDeferred,
        resolution: NapiValue,
    ) -> NapiStatus;
    pub fn napi_reject_deferred(
        env: NapiEnv,
        deferred: NapiDeferred,
        rejection: NapiValue,
    ) -> NapiStatus;
    pub fn napi_create_error(
        env: NapiEnv,
        code: NapiValue,
        msg: NapiValue,
        result: *mut NapiValue,
    ) -> NapiStatus;

    // async work（libuv 线程池）
    pub fn napi_create_async_work(
        env: NapiEnv,
        async_resource: NapiValue,
        async_resource_name: NapiValue,
        execute: Option<NapiAsyncExecuteCallback>,
        complete: Option<NapiAsyncCompleteCallback>,
        data: *mut c_void,
        result: *mut NapiAsyncWork,
    ) -> NapiStatus;
    pub fn napi_queue_async_work(env: NapiEnv, work: NapiAsyncWork) -> NapiStatus;
    pub fn napi_delete_async_work(env: NapiEnv, work: NapiAsyncWork) -> NapiStatus;

    // threadsafe function（qjs worker 线程 → ArkTS 主线程）
    pub fn napi_create_threadsafe_function(
        env: NapiEnv,
        func: NapiValue,
        async_resource: NapiValue,
        async_resource_name: NapiValue,
        max_queue_size: usize,
        initial_thread_count: usize,
        thread_finalize_data: *mut c_void,
        thread_finalize_cb: Option<NapiFinalize>,
        context: *mut c_void,
        call_js_cb: Option<NapiThreadsafeFunctionCallJs>,
        result: *mut NapiThreadsafeFunction,
    ) -> NapiStatus;
    pub fn napi_call_threadsafe_function(
        func: NapiThreadsafeFunction,
        data: *mut c_void,
        is_blocking: i32,
    ) -> NapiStatus;
    pub fn napi_release_threadsafe_function(func: NapiThreadsafeFunction, mode: i32) -> NapiStatus;

    pub fn napi_call_function(
        env: NapiEnv,
        this: NapiValue,
        func: NapiValue,
        argc: usize,
        argv: *const NapiValue,
        result: *mut NapiValue,
    ) -> NapiStatus;

    pub fn napi_create_external_arraybuffer(
        env: NapiEnv,
        external_data: *mut c_void,
        byte_length: usize,
        finalize_cb: Option<NapiFinalize>,
        finalize_hint: *mut c_void,
        result: *mut NapiValue,
    ) -> NapiStatus;
}

// ---------------------------------------------------------------- 共用小工具

pub unsafe fn js_string(env: NapiEnv, s: &str) -> NapiValue {
    let mut out: NapiValue = ptr::null_mut();
    unsafe {
        napi_create_string_utf8(env, s.as_ptr() as *const c_char, s.len(), &mut out);
    }
    out
}

pub unsafe fn js_bool(env: NapiEnv, v: bool) -> NapiValue {
    let mut out: NapiValue = ptr::null_mut();
    unsafe {
        napi_get_boolean(env, v, &mut out);
    }
    out
}

pub unsafe fn js_undefined(env: NapiEnv) -> NapiValue {
    let mut out: NapiValue = ptr::null_mut();
    unsafe {
        napi_get_undefined(env, &mut out);
    }
    out
}

/// 抛一个 JS Error 并返回 undefined（napi 回调的失败惯例）。
pub unsafe fn throw(env: NapiEnv, msg: &str) -> NapiValue {
    let c = CString::new(msg.replace('\0', " ")).unwrap_or_default();
    let mut undef: NapiValue = ptr::null_mut();
    unsafe {
        napi_throw_error(env, ptr::null(), c.as_ptr());
        napi_get_undefined(env, &mut undef);
    }
    undef
}

/// 读第 index 个参数（字符串）。缺参/非字符串 ⇒ None。
pub unsafe fn arg_string(env: NapiEnv, info: NapiCallbackInfo, index: usize) -> Option<String> {
    let mut argv: [NapiValue; 8] = [ptr::null_mut(); 8];
    let mut argc = argv.len();
    let status =
        unsafe { napi_get_cb_info(env, info, &mut argc, argv.as_mut_ptr(), ptr::null_mut(), ptr::null_mut()) };
    if status != NAPI_OK || argc <= index || argv[index].is_null() {
        return None;
    }
    let mut len: usize = 0;
    unsafe {
        napi_get_value_string_utf8(env, argv[index], ptr::null_mut(), 0, &mut len);
    }
    let mut buf: Vec<u8> = vec![0; len + 1];
    let status = unsafe {
        napi_get_value_string_utf8(env, argv[index], buf.as_mut_ptr() as *mut c_char, buf.len(), &mut len)
    };
    if status != NAPI_OK {
        return None;
    }
    buf.truncate(len);
    Some(String::from_utf8_lossy(&buf).into_owned())
}

/// 第 index 个参数若为 boolean 则取出，其它（含未传/undefined/null）⇒ None。
pub unsafe fn arg_bool_opt(env: NapiEnv, info: NapiCallbackInfo, index: usize) -> Option<bool> {
    let (argc, args) = match unsafe { argc_argv(env, info) } {
        Some(v) => v,
        None => return None,
    };
    if argc <= index || args[index].is_null() {
        return None;
    }
    let mut kind: i32 = -1;
    if unsafe { napi_typeof(env, args[index], &mut kind) } != NAPI_OK || kind != NAPI_TYPE_BOOLEAN {
        return None;
    }
    let mut out = false;
    if unsafe { napi_get_value_bool(env, args[index], &mut out) } != NAPI_OK {
        return None;
    }
    Some(out)
}

/// 统一取 cb_info 的 (argc, argv)。
unsafe fn argc_argv(env: NapiEnv, info: NapiCallbackInfo) -> Option<(usize, [NapiValue; 8])> {
    let mut argv: [NapiValue; 8] = [ptr::null_mut(); 8];
    let mut argc = argv.len();
    let status =
        unsafe { napi_get_cb_info(env, info, &mut argc, argv.as_mut_ptr(), ptr::null_mut(), ptr::null_mut()) };
    if status != NAPI_OK {
        return None;
    }
    Some((argc, argv))
}

pub unsafe fn arg_i64(env: NapiEnv, info: NapiCallbackInfo, index: usize) -> Option<i64> {    let mut argv: [NapiValue; 8] = [ptr::null_mut(); 8];
    let mut argc = argv.len();
    let status =
        unsafe { napi_get_cb_info(env, info, &mut argc, argv.as_mut_ptr(), ptr::null_mut(), ptr::null_mut()) };
    if status != NAPI_OK || argc <= index || argv[index].is_null() {
        return None;
    }
    let mut out: i64 = 0;
    if unsafe { napi_get_value_int64(env, argv[index], &mut out) } != NAPI_OK {
        return None;
    }
    Some(out)
}

/// 第 index 个参数是否为「未传」（argc 不够或 undefined/null ⇒ 用默认值语义）。
pub unsafe fn arg_present(env: NapiEnv, info: NapiCallbackInfo, index: usize) -> bool {
    let mut argv: [NapiValue; 8] = [ptr::null_mut(); 8];
    let mut argc = argv.len();
    let status =
        unsafe { napi_get_cb_info(env, info, &mut argc, argv.as_mut_ptr(), ptr::null_mut(), ptr::null_mut()) };
    status == NAPI_OK && argc > index && !argv[index].is_null()
}

pub unsafe fn arg_value(env: NapiEnv, info: NapiCallbackInfo, index: usize) -> Option<NapiValue> {
    let mut argv: [NapiValue; 8] = [ptr::null_mut(); 8];
    let mut argc = argv.len();
    let status =
        unsafe { napi_get_cb_info(env, info, &mut argc, argv.as_mut_ptr(), ptr::null_mut(), ptr::null_mut()) };
    if status != NAPI_OK || argc <= index || argv[index].is_null() {
        return None;
    }
    Some(argv[index])
}

/// 外部 ArrayBuffer 的 finalize：把 create 时 leak 出去的 Vec 收回（len 存在 hint 里）。
pub unsafe extern "C" fn free_byte_vec(_env: NapiEnv, data: *mut c_void, hint: *mut c_void) {
    if data.is_null() {
        return;
    }
    let len = hint as usize;
    unsafe {
        drop(Vec::from_raw_parts(data as *mut u8, len, len));
    }
}

/// Vec<u8> ⇒ external ArrayBuffer（零拷贝；上游实测逐字节转 5MB 要 ~5s）。
/// 成功返回 napi_value，失败返回 null 并把 Vec 原样还回来。
pub unsafe fn external_arraybuffer(
    env: NapiEnv,
    bytes: Vec<u8>,
) -> (NapiValue, Option<Vec<u8>>) {
    let len = bytes.len();
    let mut vec = bytes.into_boxed_slice();
    let data = vec.as_mut_ptr() as *mut c_void;
    std::mem::forget(vec);
    let mut out: NapiValue = ptr::null_mut();
    let status = unsafe {
        napi_create_external_arraybuffer(
            env,
            data,
            len,
            Some(free_byte_vec),
            len as *mut c_void,
            &mut out,
        )
    };
    if status != NAPI_OK {
        // 没建成功 ⇒ 自己收回内存，避免泄漏（此时 data 仍是我们独占的 Box<[u8]>）
        unsafe {
            drop(Vec::from_raw_parts(data as *mut u8, len, len));
        }
        return (ptr::null_mut(), None);
    }
    (out, None)
}
