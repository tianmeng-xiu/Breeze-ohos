/*
 * Breeze 宿主自有载荷：插件管理器（plugin_mgr.bundle.cjs）
 * v1.1.0  SRC=plugin-mgr-0002  (2026-11-09)
 *
 * v1.0.0 -> v1.1.0 修的是真机「下载全部 HTTP 403」（用户 s5e 反馈）：
 *   根因（已取证）：installLatest 第一步打 https://api.github.com/repos/<repo>/releases/latest，
 *   真机该域名直连返回 403（上游 Flutter 同处注释原话：「GitHub API 强制要求 User-Agent，
 *   缺失会直接 403」Breeze/lib/network/utils/github_proxy.dart:55），而 v1.0.0 既没带 UA
 *   也没给 release API 配代理 ⇒ attempts 全空、err='HTTP 403'，下载根本没走到资产这一步。
 *   v1.0.0 的代理域名还配错了（gh-proxy.com / ghproxy.net 对 release 资产实测 404/超时），
 *   上游真正在用的是 gh-proxy.org 家族，见下 GH_API_MIRRORS（逐条 curl 实测 200）。
 *   同时补：全部请求带 User-Agent、索引优先上游自建镜像 api.windy-78.site/plugin-list、
 *   下载优先 npm CDN（上游顺序）、SEED 换成权威 21 条快照（含 npmName/describe/home）。
 *
 * 定位：索引/检查更新/下载校验等「数据面」逻辑
 * 从诊断自测（selftest.bundle.cjs）毕业为正式宿主 JS 载荷；ArkTS 只 bundleLoad + bundleCall，
 * 清单落盘/装载/删除仍由 ArkTS（PluginStore + bundleLoadFromPath）执行。
 *
 * 对 ArkTS 的契约（返回全部 JSON-safe；fnPath 不带 default 前缀；四个名字与 v1.0.0 完全一致）：
 *   getInfo()                       -> {name,version,uuid,src}
 *   fetchIndex()                    -> {ok,total,via,err,items:[IndexItem]}
 *       IndexItem = {uuid,name,version,describe,iconUrl,home,updateUrl,repo,npmName}
 *       数据源有序回退：windy 自建镜像 -> raw -> cnxiaobai 前缀 raw -> api contents(base64) -> 内嵌 SEED
 *       结果缓存在模块态；force 参数可强制重取：fetchIndex(["1"])
 *   checkUpdates(listJson)          -> {ok,results:[{uuid,local,latest,hasUpdate,assetUrl,err}],indexVia}
 *       listJson = JSON.stringify([{uuid,version},...])；只查清单里出现的 uuid。
 *   installLatest(uuid)             -> {ok,uuid,name,version,asset,bytes,sha256,savedTo,via,err,attempts,writeMode,sizeOnDisk,sizeOk}
 *       下载有序回退：npm CDN（有 npmName 时）-> release 资产代理 -> release 资产直链；
 *       落盘 <root>/plugins/<uuid前段>-<tag>.bundle.cjs，只下载不装载（装载/登记归 ArkTS）。
 * 超时红线：Rust CALL_TIMEOUT 30s ⇒ 所有多源循环共用一个 26s 预算（DL_BUDGET_MS），
 * 预算耗尽立即停止换源并在 err 里标 'budget-exhausted'，绝不让 fnPath 超时被 Rust 掐死。
 */
'use strict';
(function () {
  var SRC = 'plugin-mgr-0002';
  var VERSION = '1.1.0';

  // —— 端点（全部照抄上游 Flutter 在用的、且本机 curl 逐条实测过的那批）——
  var INDEX_URL = 'https://raw.githubusercontent.com/breeze-project-org/Breeze-plugin-list/main/plugins_data.json';
  var INDEX_API_URL = 'https://api.github.com/repos/breeze-project-org/Breeze-plugin-list/contents/plugins_data.json?ref=main';
  var WINDY_INDEX = 'https://api.windy-78.site/plugin-list';       // 上游自建镜像（实测 200，结构与 raw 一致）
  // GitHub 加速前缀（前缀式：前缀 + 完整原始 URL）。上游 mirrorBaseUrls = gh-proxy.org 家族，
  // 见 Breeze/lib/network/utils/github_proxy.dart:5-10 与 plugin_cloud_download_utils.dart:121-146。
  var GH_API_MIRRORS = [
    'https://v4.gh-proxy.org/',
    'https://gh-proxy.org/',
    'https://cdn.gh-proxy.org/'
  ];
  // release 资产可用前缀：gh-proxy.org 家族实测 200；cnxiaobai 实测只加速文件/归档，不代理 API。
  var GH_FILE_MIRRORS = [
    'https://v4.gh-proxy.org/',
    'https://gh-proxy.org/',
    'https://cdn.gh-proxy.org/',
    'https://github.cnxiaobai.com/'
  ];
  // jsdelivr 系 npm CDN（上游 _cdnMirrors 子集，本机实测 cdn.jsdmirror.cn / jsd.onmicrosoft.cn = 200）
  var NPM_CDN = ['https://cdn.jsdmirror.cn/', 'https://jsd.onmicrosoft.cn/'];
  var UA = 'Breeze/3.0';

  var INDEX_MS = 2500;     // 单个索引源超时
  var RELEASE_MS = 2500;   // 单个 release API 源超时
  var DL_SOURCE_MS = 5000; // 单个下载源超时
  var DL_BUDGET_MS = 26000;
  var CHECK_CONCURRENCY = 3;
  var CHECK_MAX = 12;

  // —— 内嵌索引快照：2026-11-09 抓自 Breeze-plugin-list/plugins_data.json（权威 21 条逐字）——
  // 注意 manifest.version 是「清单声明版本」，可能比 release tag 新（例 JmComic 清单 0.1.0 / 实际 release v0.0.7）
  // ⇒ 安装与「有无更新」一律以 releases/latest 的 tag 为准，SEED 只当离线兜底与仓库映射表用。
  var SEED = [
    { repo: "deretame/Breeze-plugin-JmComic", name: "禁漫天堂", uuid: "bf99008d-010b-4f17-ac7c-61a9b57dc3d9", version: "0.1.0", npmName: "breeze-plugin-jm-comic", describe: "禁漫天堂插件", home: "https://github.com/deretame/Breeze-plugin-JmComic" },
    { repo: "deretame/Breeze-plugin-ManHuaGui", name: "漫画柜", uuid: "1f03ebc7-997d-494a-abb5-a06d60094f44", version: "0.1.0", npmName: "breeze-plugin-man-hua-gui", describe: "漫画柜（看漫画）繁体版源站插件", home: "https://github.com/deretame/Breeze-plugin-ManHuaGui" },
    { repo: "deretame/Breeze-plugin-NoyAcg", name: "NoyAcg", uuid: "babe7021-2df8-4abc-bba8-00bbfd7a0f75", version: "0.1.0", npmName: "breeze-plugin-noy-acg", describe: "NoyAcg 插件", home: "https://github.com/deretame/Breeze-plugin-NoyAcg" },
    { repo: "deretame/Breeze-plugin-RuManHua", name: "如漫画", uuid: "4c2f8df0-3916-4924-b4cd-4e6b8d340a73", version: "0.1.0", npmName: "breeze-plugin-ru-man-hua", describe: "如漫画源插件", home: "https://github.com/deretame/Breeze-plugin-RuManHua" },
    { repo: "deretame/Breeze-plugin-WaMan3", name: "蛙漫3", uuid: "4471434f-c73a-4dd3-b414-a6a53777d8e0", version: "0.1.0", npmName: "breeze-plugin-waman3", describe: "蛙漫插件", home: "https://github.com/deretame/Breeze-plugin-WaMan3" },
    { repo: "deretame/Breeze-plugin-baozimh", name: "包子漫画", uuid: "1b3c1e94-d9a0-4649-b75f-acd1f18d75e8", version: "0.1.0", npmName: "breeze-plugin-baozimh", describe: "包子漫画插件", home: "https://github.com/deretame/Breeze-plugin-baozimh" },
    { repo: "deretame/Breeze-plugin-bikaComic", name: "哔咔漫画", uuid: "0a0e5858-a467-4702-994a-79e608a4589d", version: "0.1.2", npmName: "breeze-plugin-bika-comic", describe: "哔咔漫画插件", home: "https://github.com/deretame/Breeze-plugin-bikaComic" },
    { repo: "deretame/Breeze-plugin-copyComic", name: "拷贝漫画", uuid: "b28da416-f2d4-4208-a85e-8b4c7c648e48", version: "0.1.1", npmName: "breeze-plugin-copy-comic", describe: "拷贝漫画插件", home: "https://github.com/deretame/Breeze-plugin-copyComic" },
    { repo: "deretame/Breeze-plugin-ehentai", name: "e-hentai", uuid: "dba2a6cf-c495-4416-accf-c29263ab4016", version: "0.1.2", npmName: "breeze-plugin-ehentai", describe: "e-hentai minimal reader plugin", home: "https://github.com/deretame/Breeze-plugin-ehentai" },
    { repo: "deretame/Breeze-plugin-hitomi", name: "hitomi", uuid: "c8f3a1e2-7b4d-4e9a-8f2c-1d5a7b9e3f6a8", version: "0.2.0", npmName: "breeze-plugin-hitomi", describe: "hitomi.la 漫画源插件", home: "https://github.com/deretame/Breeze-plugin-hitomi" },
    { repo: "deretame/Breeze-plugin-jjmhw", name: "JJ漫画", uuid: "d6f2f13a-b4d0-4f6c-9c6d-8a9f1a2b7c31", version: "0.4.0", npmName: "breeze-plugin-jjmhw", describe: "JJ漫画源插件", home: "https://github.com/deretame/Breeze-plugin-jjmhw" },
    { repo: "deretame/Breeze-plugin-komiic", name: "Komiic", uuid: "cafbf766-0231-4f99-ace4-0a26631fff12", version: "0.1.0", npmName: "breeze-plugin-komiic", describe: "Komiic 漫画源插件", home: "https://github.com/deretame/Breeze-plugin-komiic" },
    { repo: "deretame/Breeze-plugin-nhentai", name: "nhentai", uuid: "416598d0-84d0-4de9-8ec5-e74816e768f2", version: "0.1.2", npmName: "breeze-plugin-nhentai", describe: "nhentai 插件", home: "https://github.com/deretame/Breeze-plugin-nhentai" },
    { repo: "deretame/Breeze-plugin-shenShiManHua", name: "绅士漫画", uuid: "7166a5fc-b66c-4146-8c40-0f999b592a0a", version: "0.1.5", npmName: "breeze-plugin-shen-shi-man-hua", describe: "绅士漫画插件", home: "https://github.com/deretame/Breeze-plugin-shenShiManHua" },
    { repo: "deretame/Breeze-plugin-webtoon", name: "WEBTOON", uuid: "7efa2a7c-da0f-4db1-9167-98045ae37fdb", version: "0.1.0", npmName: "breeze-plugin-webtoon", describe: "WEBTOON 插件", home: "https://github.com/deretame/Breeze-plugin-webtoon" },
    { repo: "deretame/Breeze-plugin-zaiManHuan", name: "再漫画", uuid: "65c18db5-eb13-40d0-9ab4-31f473536aa1", version: "0.1.0", npmName: "breeze-plugin-zai-man-hua", describe: "再漫画插件", home: "https://github.com/deretame/Breeze-plugin-zaiManHuan" },
    { repo: "k623615746/Breeze-plugin-korsite", name: "코사이트", uuid: "7d1e0b4f-9c2a-4e8f-a3b6-5f2d8c1e9a47", version: "1.2.5", npmName: "", describe: "코사이트 插件", home: "https://github.com/k623615746/Breeze-plugin-korsite" },
    { repo: "k623615746/Breeze-plugin-mangadex", name: "MangaDex", uuid: "3f8a2c71-5d94-4e6b-b0a3-7c1e9d4f2a68", version: "1.3.1", npmName: "", describe: "MangaDex 插件", home: "https://github.com/k623615746/Breeze-plugin-mangadex" },
    { repo: "k623615746/Breeze-plugin-zerobyw", name: "zero搬运网", uuid: "b7d1e0c4-3a52-4f8b-9c61-0e2a5f7d8b90", version: "1.4.2", npmName: "", describe: "zero搬运网插件", home: "https://github.com/k623615746/Breeze-plugin-zerobyw" },
    { repo: "mumushu0501-boop/Breeze-plugin-JmComic-change", name: "禁漫天堂(mumushu0501-boop)", uuid: "6886291b-f524-441c-844b-c2efae9899a9", version: "0.2.1", npmName: "", describe: "禁漫天堂改版", home: "https://github.com/mumushu0501-boop/Breeze-plugin-JmComic-change" },
    { repo: "wuuduf/Breeze-plugin-toomics", name: "Toomics", uuid: "7c3f9a2e-5b1d-4e8a-9c4f-1d2e3f4a5b6c", version: "0.3.6", npmName: "", describe: "Toomics 插件", home: "https://github.com/wuuduf/Breeze-plugin-toomics" }
  ];

  var indexCache = null; // {via, items:[...]}

  function pluginRoot() {
    var r = globalThis.__BREEZE_PLUGIN_ROOT;
    return typeof r === 'string' && r.length > 0 ? r.replace(/\/+$/, '') : '';
  }
  function stripV(s) { s = String(s || ''); return s.replace(/^v/i, ''); }
  function semverParts(s) {
    var m = stripV(s).split('.');
    return [parseInt(m[0], 10) || 0, parseInt(m[1], 10) || 0, parseInt(m[2], 10) || 0];
  }
  function semverLt(a, b) {
    var pa = semverParts(a), pb = semverParts(b);
    for (var i = 0; i < 3; i++) { if (pa[i] < pb[i]) return true; if (pa[i] > pb[i]) return false; }
    return false;
  }
  function safeName(s) {
    return String(s || '').toLowerCase()
      .replace(/[^a-z0-9._-]+/g, '-').replace(/-+/g, '-').replace(/^[-.]+|[-.]+$/g, '').slice(0, 64);
  }
  async function sha256Hex(buf) {
    var c = globalThis.crypto;
    if (!c || typeof c.sha256 !== 'function') throw new Error('no crypto.sha256');
    if (typeof buf === 'string') { var te = new TextEncoder(); buf = te.encode(buf); }
    var h = await c.sha256(buf);
    return String(h || '').toLowerCase();
  }
  function repoOf(ent) {
    var r = String(ent.repo || '');
    if (r) return r.replace(/^\/+/, '').replace(/\/+$/, '');
    return String(ent.home || '').replace(/^https?:\/\/github\.com\//, '').replace(/\/+$/, '');
  }

  /**
   * 单发 GET。**每次都带 User-Agent**（GitHub/代理无 UA 会 403 或断连，v1.0.0 的头号教训）。
   * asText=true -> {ok,text,bytes,status,ms,err,tlsErr}；false -> {ok,buf:ArrayBuffer,...}
   */
  async function tryGet(url, ms, asText) {
    var t0 = Date.now();
    var out = { ok: false, status: 0, bytes: 0, ms: 0, err: '', tlsErr: '' };
    try {
      var ctrl = new AbortController();
      var res = await fetch(url, {
        signal: ctrl.signal,
        timeout: ms,
        headers: { 'User-Agent': UA, 'Accept': '*/*' }
      });
      out.status = res.status || 0;
      if (!res.ok) { out.err = 'HTTP ' + res.status; out.ms = Date.now() - t0; return out; }
      if (asText) {
        var t = await res.text();
        out.bytes = new TextEncoder().encode(t).length;
        out.text = t;
      } else {
        var ab = await res.arrayBuffer();
        out.bytes = ab.byteLength;
        out.buf = ab;
      }
      out.ok = true;
    } catch (e) {
      var msg = String((e && e.message) || e || 'fetch-error');
      out.err = msg.slice(0, 300);
      var low = msg.toLowerCase();
      out.tlsErr = /reset|connect|send|connection|tcp/i.test(low) ? 'conn'
        : /timeout|timed out|abort/i.test(low) ? 'timeout'
        : /dns|resolve/i.test(low) ? 'dns' : 'other';
    }
    out.ms = Date.now() - t0;
    return out;
  }

  /**
   * 有序多源尝试（带共享预算）。cands=[{label,url}]；返回命中的 tryGet 结果并补 via/tries。
   * 预算 deadlineMs 之后不再换源（防 fnPath 撞上 Rust 30s CALL_TIMEOUT 被掐死）。
   */
  async function tryEach(cands, ms, asText, deadlineMs) {
    var tries = [];
    for (var i = 0; i < cands.length; i++) {
      if (deadlineMs && Date.now() > deadlineMs) {
        var stop = { ok: false, status: 0, bytes: 0, ms: 0, err: 'budget-exhausted', tlsErr: 'timeout' };
        stop.via = ''; stop.tries = tries; return stop;
      }
      var c = cands[i];
      var g = await tryGet(c.url, ms, asText);
      g.label = c.label;
      tries.push({ label: c.label, ok: g.ok, status: g.status, bytes: g.bytes, ms: g.ms, err: g.err ? g.err.slice(0, 90) : '' });
      if (g.ok) { g.via = c.label; g.tries = tries; return g; }
    }
    var bad = tries.length ? tries[tries.length - 1] : null;
    var fail = {
      ok: false, status: bad ? bad.status : 0, bytes: 0, ms: 0,
      err: bad ? (bad.err || ('HTTP ' + bad.status)) : 'no-candidate', tlsErr: bad ? 'conn' : 'other'
    };
    fail.via = ''; fail.tries = tries;
    return fail;
  }

  /** 归一化两种索引形状：线上是 `{repo, manifest:{…}}` 嵌套，内嵌 SEED 是扁平 ⇒ 先取 manifest，没有就当自身。 */
  function mapIndex(arr) {
    var items = [];
    for (var i = 0; i < arr.length; i++) {
      var e = arr[i] || {}; var m = e.manifest || e;
      if (!m.uuid) continue;
      items.push({
        uuid: String(m.uuid), name: String(m.name || m.uuid), version: String(m.version || ''),
        describe: String(m.describe || ''), iconUrl: String(m.iconUrl || ''), home: String(m.home || ''),
        updateUrl: String(m.updateUrl || ''), repo: String(e.repo || m['breeze-plugin-github-repository'] || ''),
        npmName: String(m.npmName || '')
      });
    }
    return items;
  }

  function decodeB64Json(text) {
    var o = JSON.parse(text);
    var raw = atob(String(o.content || '').replace(/\s/g, ''));
    var u8 = new Uint8Array(raw.length);
    for (var i = 0; i < raw.length; i++) u8[i] = raw.charCodeAt(i);
    return new TextDecoder('utf-8').decode(u8);
  }

  async function fetchIndex(force) {
    if (indexCache && force !== '1' && force !== 1 && force !== true) {
      return { ok: true, total: indexCache.items.length, via: indexCache.via + '(cached)', err: '', items: indexCache.items };
    }
    var deadline = Date.now() + 12000; // 索引最多花 12s，给后续下载留预算
    var via = '', err = '', items = null;

    // ① 上游自建镜像（最快、不受 GitHub 干扰）
    var w = await tryGet(WINDY_INDEX, INDEX_MS, true);
    if (w.ok) {
      try { items = mapIndex(JSON.parse(w.text)); via = 'windy'; } catch (e) { err = 'windy-parse:' + String(e && e.message).slice(0, 60); }
    } else { err = 'windy:' + (w.tlsErr || w.err); }

    // ② raw 直链
    if (!items) {
      var g = await tryGet(INDEX_URL, INDEX_MS, true);
      if (g.ok) {
        try { items = mapIndex(JSON.parse(g.text)); via = 'raw'; } catch (e2) { err += ' | raw-parse:' + String(e2 && e2.message).slice(0, 60); }
      } else { err += ' | raw:' + (g.tlsErr || g.err); }
    }

    // ③ 加速前缀 raw（文件类，GH_FILE_MIRRORS 实测可用）
    if (!items) {
      var cands = [];
      for (var i = 0; i < GH_FILE_MIRRORS.length; i++) cands.push({ label: 'raw-mirror' + (i + 1), url: GH_FILE_MIRRORS[i] + INDEX_URL });
      var m = await tryEach(cands, INDEX_MS, true, deadline);
      if (m.ok) {
        try { items = mapIndex(JSON.parse(m.text)); via = m.via; } catch (e3) { err += ' | rawmirror-parse:' + String(e3 && e3.message).slice(0, 60); }
      } else { err += ' | rawmirror:' + (m.err || ''); }
    }

    // ④ GitHub contents API（base64），API 走 gh-proxy.org 家族
    if (!items) {
      var ac = [];
      for (var k = 0; k < GH_API_MIRRORS.length; k++) ac.push({ label: 'api-mirror' + (k + 1), url: GH_API_MIRRORS[k] + INDEX_API_URL });
      ac.push({ label: 'api-direct', url: INDEX_API_URL });
      var a = await tryEach(ac, INDEX_MS, true, deadline);
      if (a.ok) {
        try { items = mapIndex(JSON.parse(decodeB64Json(a.text))); via = 'api-contents'; }
        catch (e4) { err += ' | api-parse:' + String(e4 && e4.message).slice(0, 60); }
      } else { err += ' | api:' + (a.err || ''); }
    }

    // ⑤ 内嵌快照兜底
    if (!items) { items = mapIndex(SEED); via = 'seed'; }
    indexCache = { via: via, items: items };
    return { ok: true, total: items.length, via: via, err: via === 'seed' ? err : '', items: items };
  }

  /** releases/latest：API 类 ⇒ 走 GH_API_MIRRORS（v1.0.0 漏的就是这一步）。 */
  async function releaseLatest(repo) {
    var api = 'https://api.github.com/repos/' + repo + '/releases/latest';
    var cands = [];
    for (var i = 0; i < GH_API_MIRRORS.length; i++) cands.push({ label: 'rel-api' + (i + 1), url: GH_API_MIRRORS[i] + api });
    cands.push({ label: 'rel-api-direct', url: api });
    var g = await tryEach(cands, RELEASE_MS, true, 0);
    if (!g.ok) return { ok: false, err: g.err || 'release-fetch-fail', via: '' };
    try {
      var o = JSON.parse(g.text);
      var assets = [];
      var la = o.assets || [];
      for (var k = 0; k < la.length; k++) assets.push({ name: String(la[k].name || ''), url: String(la[k].browser_download_url || '') });
      return { ok: true, tag: stripV(o.tag_name || o.tag || ''), assets: assets, via: g.via, tries: g.tries };
    } catch (e) { return { ok: false, err: 'release-parse:' + String(e && e.message).slice(0, 80), via: g.via }; }
  }

  /** 只吃 .cjs（不吃 .cjs.br —— 运行时没有 brotli 解码能力，上游 Flutter 有） */
  function pickAsset(assets) {
    var best = null;
    for (var i = 0; i < assets.length; i++) {
      var n = assets[i].name;
      if (!/\.cjs$/i.test(n) || /\.br$/i.test(n)) continue;
      if (/\.bundle\.cjs$/i.test(n)) return assets[i];
      if (!best) best = assets[i];
    }
    return best;
  }

  async function checkUpdates(listJson) {
    var list = Array.isArray(listJson) ? listJson : null;
    if (!list) {
      try { list = JSON.parse(String(listJson || '[]')); } catch (e) { return { ok: false, err: 'bad-list-json', results: [] }; }
    }
    if (!Array.isArray(list)) return { ok: false, err: 'list-not-array', results: [] };
    var idx = await fetchIndex();
    var byUuid = {};
    for (var i = 0; i < idx.items.length; i++) byUuid[idx.items[i].uuid] = idx.items[i];
    var results = [];
    var queue = list.slice(0, CHECK_MAX);
    var cursor = 0;
    var deadline = Date.now() + 22000;
    async function worker() {
      for (;;) {
        var j = cursor++;
        if (j >= queue.length) return;
        var it = queue[j] || {};
        var uuid = String(it.uuid || '');
        var row = { uuid: uuid, local: String(it.version || ''), latest: '', hasUpdate: false, assetUrl: '', err: '' };
        var ent = byUuid[uuid];
        if (!ent) { row.err = 'not-in-index'; results.push(row); continue; }
        if (Date.now() > deadline) { row.err = 'budget-exhausted'; results.push(row); continue; }
        var r = await releaseLatest(repoOf(ent));
        if (!r.ok || !r.tag) { row.err = r.err || 'no-release'; results.push(row); continue; }
        row.latest = r.tag;
        row.hasUpdate = !row.local || semverLt(row.local, r.tag);
        var as = pickAsset(r.assets);
        if (as) row.assetUrl = as.url;
        results.push(row);
      }
    }
    var ws = [];
    for (var w = 0; w < Math.min(CHECK_CONCURRENCY, queue.length); w++) ws.push(worker());
    await Promise.all(ws);
    return { ok: true, results: results, indexVia: idx.via, err: '' };
  }

  async function installLatest(uuid) {
    uuid = String(uuid || '');
    var out = {
      ok: false, uuid: uuid, name: '', version: '', asset: '', bytes: 0, sha256: '',
      savedTo: '', via: '', err: '', attempts: [], writeMode: '', sizeOnDisk: 0, sizeOk: false
    };
    var root = pluginRoot();
    if (!root) { out.err = 'no-storage-root'; return out; }
    var deadline = Date.now() + DL_BUDGET_MS;
    var idx = await fetchIndex();
    var ent = null;
    for (var i = 0; i < idx.items.length; i++) if (idx.items[i].uuid === uuid) { ent = idx.items[i]; break; }
    if (!ent) { out.err = 'uuid-not-in-index'; return out; }
    out.name = ent.name;
    var repo = repoOf(ent);
    if (!repo) { out.err = 'no-repo'; return out; }

    var r = await releaseLatest(repo);
    if (!r.ok || !r.tag) { out.err = r.err || 'no-release'; return out; }
    var tag = r.tag;
    var asset = pickAsset(r.assets);
    out.version = tag;
    out.asset = asset ? asset.name : '';

    // 候选顺序照抄上游：有 npmName 先试 npm CDN（jsdelivr 系），再 release 资产代理，最后直链
    var cands = [];
    if (ent.npmName) {
      var assetPath = 'npm/' + ent.npmName + '@' + tag + '/dist/' + ent.npmName + '.bundle.cjs';
      for (var c = 0; c < NPM_CDN.length; c++) cands.push({ label: 'npm-cdn' + (c + 1), url: NPM_CDN[c] + assetPath });
    }
    if (asset && asset.url) {
      for (var p = 0; p < GH_FILE_MIRRORS.length; p++) cands.push({ label: 'rel-mirror' + (p + 1), url: GH_FILE_MIRRORS[p] + asset.url });
      cands.push({ label: 'rel-direct', url: asset.url });
    }
    if (!cands.length) { out.err = 'no-cjs-asset'; return out; }

    var g = await tryEach(cands, DL_SOURCE_MS, false, deadline);
    out.attempts = g.tries || [];
    if (!g.ok || !g.buf) {
      out.err = g.err === 'budget-exhausted' ? 'all-sources-timeout' : (g.err || 'all-sources-failed');
      return out;
    }
    var buf = g.buf;
    out.via = g.via;
    try {
      // crypto.sha256 真机验证过的入参形态是 Uint8Array/string（bridge_crypto.rs 只吃原始二进制）
      // ⇒ 裸 ArrayBuffer 先包成视图。
      out.sha256 = await sha256Hex(new Uint8Array(buf));
      var fs = globalThis.fs;
      if (!fs || !fs.promises) { out.err = 'no-fs'; return out; }
      var dir = root + '/plugins';
      try { await fs.promises.mkdir(dir, { recursive: true }); } catch (e) { if (!e || e.code !== 'EEXIST') throw e; }
      var fname = safeName(uuid.split('-')[0]) + '-' + safeName(tag) + '.bundle.cjs';
      var path = dir + '/' + fname;
      // 二进制写路径尚未真机验证；文本写路径 S4 probeFiles 已验证 ⇒ 先按字节写，失败按 UTF-8 回退，
      // 并把走了哪条路记进 writeMode，真机日志一眼可见。
      out.writeMode = 'bytes';
      try {
        await fs.promises.writeFile(path, new Uint8Array(buf));
      } catch (eWrite) {
        out.writeMode = 'text-fallback:' + String((eWrite && eWrite.message) || eWrite).slice(0, 80);
        var txt = new TextDecoder('utf-8').decode(new Uint8Array(buf));
        await fs.promises.writeFile(path, txt);
      }
      out.bytes = buf.byteLength; out.savedTo = path;
      var st = await fs.promises.stat(path);
      out.sizeOnDisk = (st && st.size) || 0;
      out.sizeOk = out.sizeOnDisk === out.bytes || (out.writeMode !== 'bytes' && out.sizeOnDisk > 0);
      if (!out.sizeOk) { out.err = 'size-mismatch:' + out.sizeOnDisk + '!=' + out.bytes; return out; }
      out.ok = true;
    } catch (e2) { out.err = 'save:' + String((e2 && e2.message) || e2).slice(0, 150); }
    return out;
  }

  var api = {
    getInfo: async function () { return { name: 'Breeze Plugin Manager', version: VERSION, uuid: 'plugin-mgr', src: SRC }; },
    fetchIndex: async function (args) { return await fetchIndex(Array.isArray(args) ? args[0] : args); },
    checkUpdates: async function (listJson) { return await checkUpdates(listJson); },
    installLatest: async function (uuid) { return await installLatest(uuid); }
  };
  module.exports = api;
  module.exports.default = api;
})();
