/* Breeze-ohos S3 self-test payload. QuickJS-NG safe (ES2019 subset: no ?. / ??).
 * Entry shape mirrors Rspack output: api at module.exports.default (normalizeApi unwraps it).
 *
 * fnPath 契约（面板 Index.ets 调用的名字在左，真实插件契约名在右，两者都提供）：
 *   getInfo        —— 面板 bundle / realBundle 判定（name/version 必填）
 *   probeHost      = 宿主路由子集：dart.getLocaleInfo 八字段 + dart.getAppVersion + flutter.showToast
 *   probeConfig    = 配置往返：save_plugin_config → load_plugin_config
 *   fetchBytes     = fetchImageBytes（返回 Uint8Array ⇒ 走 nativeBufferId 二进制链路）
 *   probe          = 27 个宿主全局存在性 + 9 项行为（每个独立 try/catch）
 *   probeNet       = 【S3 第 8 行】真机 fetch/TLS 门：多站点逐个尝试；零网络时全红也是有效证据
 *   probeIndex     = 【S3 第 9 行】plugins_data.json 索引拉取 + semver 比对（installed 从宿主配置桶取）
 *   probeDownload  = 【S3 第 11 行】下载 → sha256 校验 → fs 落盘 → 回读 → 引擎装载 → getInfo
 *   probeUnload    = 【S3 第 12 行】bundleUnload + unlink，并复查 bundleList / readdir
 *   probeFiles     = 【S4 第 13 行】fs 落盘往返（write→stat→readText→readBytes+二次 sha），
 *                    落盘件 s4-probe-file.cjs 留给第 14 行 fileChain 装载，本函数不删
 * 面板只依赖 ok/status/bytes/ct/ms/url/err/tlsErr（第 8 行）与 ok/total/newer[].name/version/installedVersion（第 9 行）。
 * 11/12 两行需要宿主 init 传了 storageRoot（⇒ globalThis.__BREEZE_PLUGIN_ROOT）；没传则 err=no-storage-root。
 */
(function () {
  "use strict";
  var SRC = "s4-selftest-0006";
  var VERSION = "0.0.6";
  // ---- S4 第 15 行（fileChain）常量：probeFiles 写一个"可装载的最小 bundle"到 plugins/ 下，
  // 之后由 ArkTS 侧走 pluginScanDir → bundleLoadFromPath → bundleCall(getInfo) → bundleUnload
  // → pluginRemoveFile → 再 scanDir 的完整生产链。固定文件名（无时间戳）：内容静态 ⇒ sha 恒定，
  // 链尾删掉后重跑不堆积。
  var S4_FILE = "s4-probe-file.cjs";
  var S4_INFO_NAME = "S4 ProbeFile";
  var S4_BUNDLE_SRC = "(function(){\"use strict\";var api={getInfo:async function(){return {name:\"S4 ProbeFile\",version:\"1.0.0\",uuid:\"s4-probe-file\"};},searchComic:async function(){return {items:[]};}};module.exports=api;module.exports.default=api;})();";
  // 第 11/12 行的下载夹具（S3 第二批）：固定插件 + 固定版本 + 固定 sha256，免 api.github.com 限流。
  // 三个常量必须同步：直链、digest、装载后 getInfo 期望的 name/version。重出夹具时一并改。
  var DL_URL = "https://github.com/deretame/Breeze-plugin-JmComic/releases/download/v0.0.7/jm-comic.bundle.cjs";
  var DL_SHA256 = "bad91c2f9fd50ce229723203cd597731d3168d5c435d41f42751f21203b8d8d1";
  var DL_REG = "s3dl-jmcomic"; // 注册进引擎的 bundle 名（我们自己起，不是插件 manifest.name）
  var DL_FILE = "jm-comic-0.0.7.bundle.cjs";
  var DL_INFO_TIMEOUT = 3500; // 第三方插件 getInfo 可能做网络/重活，自测不能因它拖满 CALL_TIMEOUT
  // 真机实测（2026-11-09 SGT-AL10，S3 netgate 包第 8 行）：raw.githubusercontent.com 与
  // cdn.jsdelivr.net 被连接层 RST（os error 104），api.github.com / api.mangadex.org 200 ⇒
  // TLS/根证书无恙，是大陆网络对个别域名的干扰。下载与索引一律多源回退（S4 生产下载同构）。
  var DL_URLS = [
    { label: "gh", url: DL_URL },
    { label: "gh-proxy", url: "https://gh-proxy.com/" + DL_URL },
    { label: "ghproxy.net", url: "https://ghproxy.net/" + DL_URL }
  ];
  var DL_SOURCE_MS = 7500; // 3 源全超时 22.5s + 校验/落盘/装载 + getInfo(3.5s) < Rust CALL_TIMEOUT 30s
  var INDEX_URL = "https://raw.githubusercontent.com/breeze-project-org/Breeze-plugin-list/main/plugins_data.json";
  var INDEX_API_URL = "https://api.github.com/repos/breeze-project-org/Breeze-plugin-list/contents/plugins_data.json?ref=main";
  var INSTALLED_KEY = "***";
  // 离线播种的"已装"清单 = 我们随包带的两个插件（面板 bundle 行装 selftest、realBundle 行装 MangaDex）。
  var SEED_INSTALLED = [
    { name: "S2 SelfTest", version: VERSION },
    { name: "MangaDex", version: "1.3.1" }
  ];
  // 1x1 transparent PNG, inlined so fetchBytes needs no fetch/atob.
  var PNG = new Uint8Array([
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196,
    137, 0, 0, 0, 11, 73, 68, 65, 84, 120, 218, 99, 96, 0, 2, 0, 0, 5, 0, 1, 233, 250, 220, 216, 0, 0, 0, 0, 73, 69,
    78, 68, 174, 66, 96, 130
  ]);
  var HTML =
    "<html><head><title>SELFTEST</title></head><body>" +
    '<div class="item" data-id="a1"><span class="title">测试漫画 甲</span><img src="https://example.com/a.jpg"></div>' +
    '<div class="item" data-id="b2"><span class="title">测试漫画 乙</span><img src="https://example.com/b.jpg"></div>' +
    "</body></html>";

  function has(n) {
    return typeof globalThis[n] !== "undefined";
  }
  // 宿主回包一律是字符串（ABI §2：Rust 原样包成 Value::String，不解析）⇒ 自己 JSON.parse。
  function parseMaybe(raw) {
    if (typeof raw !== "string") return raw;
    if (raw.length === 0) return null;
    return JSON.parse(raw);
  }
  function item(id, title) {
    var cover = { id: id, url: "https://example.com/cover.jpg", name: title, path: "https://example.com/cover.jpg", extern: {} };
    return {
      source: SRC, id: id, title: title, subtitle: "", finished: false, likesCount: 0, viewsCount: 0,
      updatedAt: "", cover: cover, metadata: [], raw: {}, extern: {}
    };
  }
  function errText(e) {
    try { return String(e && e.message ? e.message : e); } catch (_e) { return "unknown error"; }
  }
  function clip(s, n) {
    s = String(s === undefined || s === null ? "" : s);
    return s.length > n ? s.slice(0, n) : s;
  }

  // ---------------------------------------------------------------- 网络工具
  // 每请求都带 AbortSignal.timeout + Request.timeout 双保险（js/30_fetch.js 两个都支持：
  // timeout 字段会走 __http_request_cancel，signal 走 aborted）。总预算 ~20s < Rust CALL_TIMEOUT 30s。
  function signalFor(ms) {
    try {
      if (typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function") {
        return AbortSignal.timeout(ms);
      }
    } catch (_e) {}
    return undefined;
  }
  // TLS 归因（S3 门的真正目的）：rustls / rustls-platform-verifier / rustls-native-certs 在
  // OHOS 上取不到系统根证书时报法不止一种 ⇒ 全部粗分类，原文另存 err。
  function classifyTls(msg) {
    var m = String(msg || "");
    if (!m) return "";
    if (/unable to load ca|ca roots|no root certificate|failed to load.*cert|native[- ]?certs|load.*root|no certificates/i.test(m)) {
      return "no-root-certs";
    }
    if (/unknown issuer|unknown_authority|ExpiredCert|CertNotValidYet|BadSignature|RevokedCert|UnknownCert|invalid peer certificate|certificate verify|self[- ]?signed|not valid for name|CertNotValidForName/i.test(m)) {
      return "verify-fail";
    }
    if (/alert|handshake|\btls\b|\bssl\b|wrong version|peer mis|illegal message/i.test(m)) {
      return "handshake";
    }
    if (/dns|resolve|getaddrinfo|name.?not.?resolv|network is unreachable|no route/i.test(m)) {
      return "dns";
    }
    if (/timed?.?out|timeout|abort/i.test(m)) {
      return "timeout";
    }
    if (/connection|reset|refused|eof|closed|broken pipe/i.test(m)) {
      return "conn";
    }
    return "other";
  }
  // 单次 GET。返回 {ok,url,status,ct,bytes,ms,err,text}，永不抛。
  async function tryGet(url, ms, asText) {
    var t0 = Date.now();
    var out = { url: url, ok: false, status: 0, ct: "", bytes: 0, ms: 0, err: "", text: "" };
    if (typeof fetch !== "function") {
      out.err = "fetch is not a function";
      return out;
    }
    var sig = signalFor(ms);
    var opt = { method: "GET", headers: { "User-Agent": "BreezeOHOS/" + VERSION, Accept: "*/*" } };
    if (sig) opt.signal = sig;
    opt.timeout = ms;
    try {
      var res = await fetch(url, opt);
      out.status = res && typeof res.status === "number" ? res.status : 0;
      try {
        out.ct = (res && res.headers && typeof res.headers.get === "function") ? String(res.headers.get("content-type") || "") : "";
      } catch (_h) {}
      if (asText) {
        var body = await res.text();
        out.text = String(body === undefined || body === null ? "" : body);
        // §11.7-1：bytes 必须是 UTF-8 字节数不是字符数（含中文的响应旧版会虚报）
        out.bytes = new TextEncoder().encode(out.text).length;
      } else {
        var ab = await res.arrayBuffer();
        out.bytes = ab && ab.byteLength ? ab.byteLength : 0;
      }
      out.ok = out.status >= 200 && out.status < 400;
      if (!out.ok) out.err = "HTTP " + out.status;
    } catch (e) {
      out.err = errText(e);
    }
    out.ms = Date.now() - t0;
    return out;
  }

  // ------------------------------------------------------------ semver-lite
  function cmpVer(a, b) {
    var pa = String(a || "0").split("-")[0].split("+")[0].split(".");
    var pb = String(b || "0").split("-")[0].split("+")[0].split(".");
    var n = Math.max(pa.length, pb.length), i, x, y;
    for (i = 0; i < n; i++) {
      x = parseInt(pa[i], 10); if (isNaN(x)) x = 0;
      y = parseInt(pb[i], 10); if (isNaN(y)) y = 0;
      if (x !== y) return x > y ? 1 : -1;
    }
    return 0;
  }
  async function cfgLoad(key) {
    try {
      var env = parseMaybe(await bridge.call("load_plugin_config", key, ""));
      if (env && typeof env === "object" && env.ok === true) {
        return typeof env.value === "string" ? env.value : JSON.stringify(env.value);
      }
      return typeof env === "string" ? env : "";
    } catch (_e) { return ""; }
  }
  async function cfgSave(key, value) {
    try { await bridge.call("save_plugin_config", key, value); return true; } catch (_e) { return false; }
  }

  // ---- S3 第二批用的三个小工具（只服务 probeDownload / probeUnload）--------
  function pluginRoot() {
    var r = globalThis.__BREEZE_PLUGIN_ROOT;
    if (typeof r !== "string" || !r) return "";
    return r.replace(/\/+$/, "");
  }
  function bundleNames() {
    try {
      var host = globalThis.__host_bundle_runtime;
      if (host && typeof host.listBundles === "function") {
        var l = host.listBundles();
        return Array.isArray(l) ? l.map(String) : [];
      }
    } catch (_e) {}
    return [];
  }
  function withTimeout(p, ms) {
    return Promise.race([
      Promise.resolve(p),
      new Promise(function (_res, rej) {
        setTimeout(function () { rej(new Error("timeout after " + ms + "ms")); }, ms);
      })
    ]);
  }

  var api = {
    init: async function () { return { source: SRC, data: { ok: true } }; },

    getInfo: async function () {
      return {
        name: "S2 SelfTest", uuid: SRC, iconUrl: "https://example.com/icon.png",
        describe: "零网络自测 + S3 fetch/TLS 门（probeNet）+ 插件索引版本比对（probeIndex）。",
        version: VERSION, updateUrl: "", function: []
      };
    },

    searchComic: async function (p) {
      p = p || {};
      var kw = String(p.keyword || "");
      var items = [item("a1", "测试漫画 甲 " + kw), item("b2", "测试漫画 乙 " + kw)];
      var paging = { page: 1, pages: 1, total: 2, hasReachedMax: true };
      return {
        source: SRC, extern: p.extern || null,
        scheme: { version: "1.0.0", type: "searchResult", source: SRC, list: "grid" },
        data: { paging: paging, items: items }, paging: paging, items: items
      };
    },

    // ---- 宿主五路由往返（面板 hostBridge 项）--------------------------------
    probeHost: async function () {
      var out = { source: SRC, iana: "", keys: 0, appVersion: "", errors: {} };
      try {
        var raw = await bridge.call("dart.getLocaleInfo");
        var o = parseMaybe(raw);
        if (!o || typeof o !== "object") {
          out.errors.localeInfo = "not an object: " + String(raw).slice(0, 80);
        } else {
          var ks = Object.keys(o);
          out.keys = ks.length;
          out.iana = String(o.timeZoneIANA || o.timezoneName || o.timeZone || "");
          out.fields = ks.join(",");
          out.offset = o.timezoneOffsetMinutes;
        }
      } catch (e) { out.errors.localeInfo = errText(e); }
      try {
        var v = parseMaybe(await bridge.call("dart.getAppVersion"));
        out.appVersion = typeof v === "string" ? v : JSON.stringify(v);
      } catch (e2) { out.errors.appVersion = errText(e2); }
      try {
        // flutter.showToast 的 args[1] 放宽版（对象或裸串）；返回值 ABI 规定空串 ⇒ Null
        out.toast = await bridge.call("flutter.showToast", "S3 selftest toast", { duration: 1.0 });
      } catch (e3) { out.errors.showToast = errText(e3); }
      return out;
    },

    // ---- 配置往返（面板 config 项）----------------------------------------
    probeConfig: async function () {
      var out = { source: SRC, ok: false, expect: "", got: "", errors: {} };
      var key = "probe_key";
      var stamp = "ts-" + Date.now();
      try {
        await bridge.call("save_plugin_config", key, stamp);
      } catch (e) { out.errors.save = errText(e); return out; }
      try {
        out.got = await cfgLoad(key);
      } catch (e2) { out.errors.load = errText(e2); return out; }
      out.expect = stamp;
      out.ok = out.got === stamp;
      return out;
    },

    fetchBytes: async function () { return PNG; },
    fetchImageBytes: async function () { return PNG; },

    // ---- 【S3 第 8 行】真机 fetch / TLS 门 ---------------------------------
    // 语义：任一候选走通 ⇒ ok=true 并把该候选抄到顶层字段（面板判据 ok && 2xx/3xx && bytes>0）。
    // 全红时 tlsErr 给第一个非空分类 ⇒ 直接读出"是没根证书还是 DNS 还是超时"。
    probeNet: async function () {
      var CAND = [
        { label: "raw-gh", url: INDEX_URL, text: true },
        { label: "api-gh", url: "https://api.github.com/repos/breeze-project-org/Breeze-plugin-list", text: true },
        { label: "mangadex", url: "https://api.mangadex.org/manga?limit=1", text: true },
        { label: "cdn-jsd", url: "https://cdn.jsdelivr.net/gh/k623615746/Breeze-plugin-mangadex@main/package.json", text: true }
      ];
      var out = {
        source: SRC, ok: false, url: "", status: 0, ct: "", bytes: 0, ms: 0,
        err: "", tlsErr: "", tlsOk: 0, attempts: [], totalMs: 0
      };
      var t0 = Date.now();
      var i, g;
      for (i = 0; i < CAND.length; i++) {
        g = await tryGet(CAND[i].url, 2500, CAND[i].text);
        // 拿到 HTTP 状态码 ⇒ TLS 握手与 DNS 都是好的（HTTP 4xx/5xx 不是证书问题），
        // 这类失败**不**计入 tlsErr，只累加 tlsOk 作为"传输层通"的正面证据。
        var isHttpStatus = /^HTTP \d{3}$/.test(g.err);
        out.attempts.push({
          label: CAND[i].label, ok: g.ok, status: g.status, bytes: g.bytes, ms: g.ms,
          ct: clip(g.ct, 40), err: clip(g.err, 200),
          tlsErr: (g.ok || isHttpStatus) ? "" : classifyTls(g.err)
        });
        if (isHttpStatus) out.tlsOk++;
        if (g.ok && !out.ok) {
          out.ok = true;
          out.url = CAND[i].url;
          out.status = g.status;
          out.ct = g.ct;
          out.bytes = g.bytes;
          out.ms = g.ms;
        }
        if (!out.tlsErr && !g.ok && !isHttpStatus) {
          var c = classifyTls(g.err);
          if (c) { out.tlsErr = c; out.err = clip(g.err, 300); }
        }
      }
      out.totalMs = Date.now() - t0;
      // 顶层 err 兜底：没有任何传输层错误时（全是 HTTP 状态码），用第一个失败的原文。
      if (!out.ok && !out.err && out.attempts.length) out.err = out.attempts[0].err;
      return out;
    },

    // ---- 【S3 第 9 行】插件索引 + 版本比对（INFO，不参与 verdict）----------
    probeIndex: async function () {
      var out = {
        source: SRC, ok: false, url: INDEX_URL, total: 0, listed: 0, installedCount: 0,
        newer: [], sample: [], status: 0, ms: 0, bytes: 0, err: "", tlsErr: "", seeded: false, saved: false,
        via: "", rawErr: "", rawTlsErr: ""
      };
      var g = await tryGet(INDEX_URL, 2500, true);
      out.via = "raw";
      if (!g.ok) {
        out.rawErr = clip(g.err, 160);
        out.rawTlsErr = classifyTls(g.err);
        // 回退：api.github.com contents 端点（真机实测 api.github.com 通、raw 被 RST）
        var env = await tryGet(INDEX_API_URL, 8000, true);
        if (env.ok) {
          try {
            var j = JSON.parse(env.text);
            var b64 = String(j.content || "").replace(/\s+/g, "");
            var raw = atob(b64);
            var u8 = new Uint8Array(raw.length);
            for (var bi = 0; bi < raw.length; bi++) u8[bi] = raw.charCodeAt(bi) & 0xff;
            g = { ok: true, status: env.status, ct: "application/json", ms: g.ms + env.ms,
                  bytes: env.bytes, text: new TextDecoder("utf-8").decode(u8) };
            out.via = "api-contents";
          } catch (je) {
            g = env; // 保持失败形态，下面统一走 !g.ok 出参
            g.ok = false;
            if (!g.err) g.err = "contents decode: " + errText(je);
          }
        }
      }
      out.status = g.status; out.ms = g.ms; out.bytes = g.bytes;
      if (!g.ok) {
        out.err = clip(g.err, 300);
        out.tlsErr = classifyTls(g.err);
        return out;
      }
      var arr;
      try { arr = JSON.parse(g.text); } catch (e) { out.err = "json parse: " + errText(e); return out; }
      if (!arr || typeof arr.length !== "number") { out.err = "not an array"; return out; }
      out.ok = true;
      out.total = arr.length;

      // 已装清单：配置桶优先（key=installedPlugins，值是 JSON 数组 [{name,version}]）；
      // 桶为空 ⇒ 用随包带的两个插件播种一次，顺带证明"配置写 → 索引比对"闭环。
      var installed = null;
      var raw = await cfgLoad(INSTALLED_KEY);
      if (raw) {
        try {
          var parsed = JSON.parse(raw);
          if (parsed && typeof parsed.length === "number") installed = parsed;
        } catch (_e) { installed = null; }
      }
      if (!installed) {
        installed = SEED_INSTALLED;
        out.seeded = true;
        out.saved = await cfgSave(INSTALLED_KEY, JSON.stringify(SEED_INSTALLED));
      }
      out.installedCount = installed.length;
      // 比对器自检（面板 newer 为空时也能看出 semver 逻辑本身在工作）
      out.semverCheck = {
        gt: cmpVer("1.3.1", "1.2.0") > 0,
        eq: cmpVer("1.3.1", "1.3.1") === 0,
        lt: cmpVer("0.0.3", "1.3.1") < 0,
        short: cmpVer("1.2", "1.2.0") === 0
      };
      var byName = {};
      var k;
      for (k = 0; k < installed.length; k++) {
        if (installed[k] && installed[k].name) byName[String(installed[k].name)] = String(installed[k].version || "0");
      }
      for (k = 0; k < arr.length; k++) {
        var m = (arr[k] && arr[k].manifest) || null;
        if (!m || !m.name) continue;
        if (out.listed < 8) {
          out.sample.push({ name: String(m.name), version: String(m.version || ""), uuid: String(m.uuid || "").slice(0, 13) });
        }
        out.listed++;
        var have = byName[String(m.name)];
        if (have !== undefined && cmpVer(m.version, have) > 0) {
          out.newer.push({ name: String(m.name), version: String(m.version), installedVersion: have });
        }
      }
      return out;
    },

    // ---- 【S3 第 11 行】下载 → sha256 → 落盘 → 回读 → 装载 → getInfo --------
    // 关键约束：本函数跑在 qjs worker 线程**内部**，绝不能反过来调宿主的 bundleLoad
    // （那会让 worker 等自己 ⇒ 死锁）。所以直接用同 realm 的 __host_bundle_runtime。
    probeDownload: async function () {
      var out = {
        ok: false, url: DL_URL, sourceLabel: "", attempts: [], bytes: 0, want: DL_SHA256, got: "", match: false,
        savedTo: "", readback: false, readbackBytes: 0, loaded: false,
        name: "", version: "", getInfoErr: "", err: "", tlsErr: "", ms: 0, status: 0,
        stages: { fetch: false, hash: false, write: false, readback: false, load: false, info: false }
      };
      var t0 = Date.now();
      var root = pluginRoot();
      if (!root) { out.err = "no-storage-root"; out.ms = Date.now() - t0; return out; }
      var dir = root + "/plugins";
      var path = dir + "/" + DL_FILE;
      // 1) 下载（90 KB 级，二进制取回，不经 base64）。多源回退：直链 → gh-proxy.com → ghproxy.net。
      var bytes = null;
      var attempts = [];
      out.attempts = attempts;
      for (var si = 0; si < DL_URLS.length; si++) {
        var src = DL_URLS[si];
        var a = { label: src.label, ok: false, status: 0, bytes: 0, ms: 0, err: "", tlsErr: "" };
        var t1 = Date.now();
        try {
          var sig = signalFor(DL_SOURCE_MS);
          var opt = { method: "GET", headers: { "User-Agent": "BreezeOHOS/" + VERSION, Accept: "*/*" } };
          if (sig) opt.signal = sig;
          opt.timeout = DL_SOURCE_MS;
          var res = await fetch(src.url, opt);
          a.status = res && typeof res.status === "number" ? res.status : 0;
          a.ok = a.status >= 200 && a.status < 300;
          if (a.ok) {
            var ab = await res.arrayBuffer();
            bytes = ab instanceof Uint8Array ? ab : new Uint8Array(ab);
            a.bytes = bytes.byteLength;
            if (!(a.bytes > 0)) a.ok = false;
          }
          if (!a.ok) a.err = "HTTP " + a.status;
        } catch (e) {
          a.err = clip(errText(e), 200);
          a.tlsErr = classifyTls(a.err);
        }
        a.ms = Date.now() - t1;
        attempts.push(a);
        if (a.ok) { out.url = src.url; out.sourceLabel = src.label; break; }
      }
      out.status = attempts.length ? attempts[attempts.length - 1].status : 0;
      if (!bytes || !(bytes.byteLength > 0)) {
        var lastA = attempts[attempts.length - 1] || { err: "no attempt", tlsErr: "" };
        out.err = clip(lastA.err || "download failed", 300);
        out.tlsErr = lastA.tlsErr || classifyTls(out.err);
        out.ms = Date.now() - t0;
        return out;
      }
      out.bytes = bytes.byteLength;
      out.stages.fetch = true;
      // 2) sha256 与 GitHub asset digest 比对（权威来源，不由我们维护）
      var text = "";
      try {
        var got = await crypto.sha256(bytes);
        out.got = String(got || "").toLowerCase();
        out.match = out.got === DL_SHA256;
        out.stages.hash = out.got.length === 64;
        text = new TextDecoder("utf-8").decode(bytes);
      } catch (e) { out.err = "sha256: " + clip(errText(e), 200); }
      if (!out.stages.hash) { out.ms = Date.now() - t0; return out; }
      if (!out.match) { out.err = "sha256-mismatch"; out.ms = Date.now() - t0; return out; }
      // 3) 落盘（只写进 storageRoot/plugins 之下 —— host-fs 无 jail，边界靠我们）
      try {
        await fs.promises.mkdir(dir, { recursive: true });
        await fs.promises.writeFile(path, text);
        out.savedTo = path;
        out.stages.write = true;
      } catch (e) { out.err = "write: " + clip(errText(e), 240); out.ms = Date.now() - t0; return out; }
      // 4) 回读 + 二次哈希（长度相等不够，内容哈希相等才算落盘无损）
      var text2 = "";
      try {
        text2 = await fs.promises.readFile(path, "utf8");
        out.readbackBytes = new TextEncoder().encode(String(text2)).length;
        var got2 = String(await crypto.sha256(text2) || "").toLowerCase();
        out.readback = got2 === out.got;
        out.stages.readback = out.readback;
      } catch (e) { out.err = "readback: " + clip(errText(e), 240); out.ms = Date.now() - t0; return out; }
      // 5) 装载进引擎（同 realm 直接调，注册名是我们起的 DL_REG）
      try {
        globalThis.__host_bundle_runtime.loadBundle(DL_REG, text2);
        out.loaded = bundleNames().indexOf(DL_REG) >= 0;
        out.stages.load = out.loaded;
        if (!out.loaded) out.err = "load: not in registry";
      } catch (e) { out.err = "load: " + clip(errText(e), 300); out.ms = Date.now() - t0; return out; }
      // 6) 第三方插件的 getInfo（可能做网络 ⇒ 单独限时，失败只记 getInfoErr 不判红）
      try {
        var info = await withTimeout(
          globalThis.__host_bundle_runtime.invoke({ name: DL_REG, fnPath: "getInfo", args: [] }),
          DL_INFO_TIMEOUT
        );
        if (info && typeof info === "object") {
          out.name = String(info.name || "");
          out.version = String(info.version || "");
        }
        out.stages.info = out.name.length > 0;
      } catch (e) { out.getInfoErr = clip(errText(e), 200); }
      out.ok = out.stages.fetch && out.stages.hash && out.match && out.stages.write && out.stages.readback && out.stages.load;
      out.ms = Date.now() - t0;
      return out;
    },

    // ---- 【S3 第 12 行】卸载 + 删文件，并复查 registry / 目录 ----------------
    probeUnload: async function () {
      var out = {
        ok: false, name: DL_REG, unloaded: false, stillInList: true, removed: false,
        stillExists: true, dirEntries: -1, err: ""
      };
      var root = pluginRoot();
      if (!root) { out.err = "no-storage-root"; return out; }
      var dir = root + "/plugins";
      var path = dir + "/" + DL_FILE;
      try {
        out.unloaded = !!globalThis.__host_bundle_runtime.unloadBundle(DL_REG);
        out.stillInList = bundleNames().indexOf(DL_REG) >= 0;
      } catch (e) { out.err = "unload: " + clip(errText(e), 200); return out; }
      try {
        await fs.promises.unlink(path);
        out.removed = true;
      } catch (e) {
        var m = errText(e);
        // 文件本来就不在（11 没跑成/已删过）不算引擎问题，但仍不算通过
        out.err = "unlink: " + clip(m, 200);
      }
      try {
        var list = await fs.promises.readdir(dir);
        var names = [];
        for (var i = 0; i < list.length; i++) names.push(String(list[i] && list[i].name ? list[i].name : list[i]));
        out.dirEntries = names.length;
        out.stillExists = names.indexOf(DL_FILE) >= 0;
      } catch (e) { out.err = (out.err ? out.err + " | " : "") + "readdir: " + clip(errText(e), 160); }
      out.ok = out.unloaded && !out.stillInList && out.removed && !out.stillExists;
      return out;
    },

    // ---- 【S4 第 15 行】文件半程：把可装载的最小 bundle 写到 plugins/ 下并自查。----
    // 后半程（scanDir → bundleLoadFromPath → getInfo → unload → removeFile → 复扫）在 ArkTS 面板
    // 第 16 行 fileChain 里跑（只有那里能调 Rust 的三个文件导出）。这里**不删文件**、不 unload：
    // 链尾清理归 ArkTS；固定文件名保证重跑幂等不堆积。
    probeFiles: async function () {
      var out = {
        ok: false, path: "", bytes: 0, sha: "", statBytes: -1, readText: false,
        readBytes: false, shaMatch: false, err: ""
      };
      var root = pluginRoot();
      if (!root) { out.err = "no-storage-root"; return out; }
      var dir = root + "/plugins";
      var path = dir + "/" + S4_FILE;
      out.path = path;
      try {
        out.bytes = new TextEncoder().encode(S4_BUNDLE_SRC).length;
        out.sha = String(await crypto.sha256(S4_BUNDLE_SRC) || "").toLowerCase();
      } catch (e) { out.err = "prep: " + clip(errText(e), 160); return out; }
      try {
        await fs.promises.mkdir(dir, { recursive: true });
        await fs.promises.writeFile(path, S4_BUNDLE_SRC);
      } catch (e) { out.err = "write: " + clip(errText(e), 240); return out; }
      try {
        var st = await fs.promises.stat(path);
        out.statBytes = Number(st && st.size !== undefined ? st.size : -1);
      } catch (e) { out.err = "stat: " + clip(errText(e), 160); }
      try {
        var t = await fs.promises.readFile(path, "utf8");
        out.readText = String(t) === S4_BUNDLE_SRC;
      } catch (e) { out.err = "readText: " + clip(errText(e), 200); }
      try {
        var b = await fs.promises.readFile(path);
        var u8 = b instanceof Uint8Array ? b : new Uint8Array(b);
        var sha2 = String(await crypto.sha256(u8) || "").toLowerCase();
        out.readBytes = u8.byteLength === out.bytes;
        out.shaMatch = sha2 === out.sha;
      } catch (e) { out.err = "readBytes: " + clip(errText(e), 200); }
      out.ok = out.readText && out.readBytes && out.shaMatch && out.statBytes === out.bytes;
      return out;
    },

    // ---- 能力缺口表（面板 selftest 行 / 手工排查用）-----------------------
    probe: async function () {
      var out = { source: SRC, present: {}, results: {}, errors: {} };
      var names = ["fetch", "Headers", "URL", "URLSearchParams", "FormData", "AbortController", "AbortSignal",
        "Temporal", "Intl", "BreezeHtml", "bridge", "crypto", "native", "console", "Buffer", "TextEncoder",
        "TextDecoder", "structuredClone", "uuidv4", "bytesToBase64", "bytesFromBase64", "setTimeout", "Blob",
        "Request", "Response", "atob", "btoa"];
      var i, n;
      for (i = 0; i < names.length; i++) { n = names[i]; out.present[n] = has(n); }
      try { out.results.temporal = Temporal.PlainDate.from("2024-03-15").add({ days: 7 }).toString(); } catch (e) { out.errors.temporal = errText(e); }
      try {
        var u = new URL("https://api.example.com/search?q=x&page=2");
        u.searchParams.set("page", "3");
        out.results.url = u.toString();
      } catch (e) { out.errors.url = errText(e); }
      try {
        var h = new Headers({ "x-rquickjs-host-offload-binary-v1": "1", Accept: "image/*" });
        h.set("X-Probe", "on");
        out.results.headers = [h.get("x-rquickjs-host-offload-binary-v1"), h.get("Accept"), h.get("X-Probe")].join("|");
      } catch (e) { out.errors.headers = errText(e); }
      try {
        var b = Buffer.from("hello-buffer");
        out.results.buffer = b.length + ":" + String(b);
      } catch (e) { out.errors.buffer = errText(e); }
      try {
        var $ = BreezeHtml.load(HTML);
        out.results.breezeHtml = {
          title: $("title").text(),
          itemCount: $(".item").length,
          firstId: $(".item").first().attr("data-id"),
          firstTitle: $(".title").first().text(),
          firstImg: $("img").first().attr("src")
        };
      } catch (e) { out.errors.breezeHtml = errText(e); }
      try {
        var packed = await bridge.gzipCompress(new TextEncoder().encode("gzip-probe-gzip-probe"));
        out.results.gzip = { packedBytes: packed.byteLength, back: new TextDecoder().decode(await bridge.gzipDecompress(packed)) };
      } catch (e) { out.errors.gzip = errText(e); }
      try {
        out.results.cryptoMd5 = typeof crypto !== "undefined" && typeof crypto.md5 === "function"
          ? await crypto.md5("probe") : null;
      } catch (e) { out.errors.cryptoMd5 = errText(e); }
      try { out.results.abortTimeout = typeof AbortSignal !== "undefined" && typeof AbortSignal.timeout === "function"; } catch (e) { out.errors.abortTimeout = errText(e); }
      try { out.results.uuid = typeof uuidv4 === "function" ? uuidv4() : null; } catch (e) { out.errors.uuid = errText(e); }
      return out;
    }
  };

  module.exports = api;
  module.exports.default = api; // Rspack-compatible: host normalizeApi reads module.exports.default
})();
