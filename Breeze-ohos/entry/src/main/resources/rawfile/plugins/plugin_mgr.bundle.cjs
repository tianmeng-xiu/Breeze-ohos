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
 * v1.1.0 -> v1.2.0 修的是真机「商店内下载部分插件报 HTTP 404」（用户 2026-11-12 report.txt 第 8 条，举例绅士漫画）：
 *   根因（已取证）：SEED 21 条里有 9 条的 GitHub 仓库压根没有 Release —— 2026-11-12 逐条实测
 *   GET api.github.com/repos/<repo>/releases/latest = 404 且 /tags 也是空数组：漫画柜 / 如漫画 /
 *   蛙漫3 / 包子漫画 / hitomi / JJ漫画 / nhentai / 绅士漫画 / WEBTOON。这 9 条在 npm 上都有包
 *   （registry.npmmirror.com 与 registry.npmjs.org 双 200），但 v1.1.0 的 installLatest 是
 *   「releaseLatest 一失败就直接 return」，连下面已经配好的 npm CDN 候选都没跑到 ⇒ 用户看到的就是
 *   release API 透传上来的 404（代理对无 Release 的仓库照样回 404，所以 attempts 里记到 HTTP 404）。
 *   v1.2.0 三条改动：一、release 取不到不再 return，改成「没有 release 也照走 npm 链」；
 *   二、新增 npmLatest() 解析 registry 拿 dist-tags.latest 与 tarball，并把 CDN 的 latest 别名加进
 *   候选（jsdelivr 系支持 latest 别名，9 条无 Release 的包本机实测全 200）；
 *   三、失败时把 release 状态码与逐源摘要拼进 err，商店 toast 上一眼能看出卡在哪个源。
 *   checkUpdates 同步受益：那 9 条不再一律记 err=no-release，改用 npm latest 比版本。
 *
 * 对 ArkTS 的契约（返回全部 JSON-safe；fnPath 不带 default 前缀；四个名字与 v1.0.0 完全一致）：
 *   getInfo()                       -> {name,version,uuid,src}
 *   fetchIndex()                    -> {ok,total,via,err,items:[IndexItem]}
 *       IndexItem = {uuid,name,version,describe,iconUrl,home,updateUrl,repo,npmName}
 *       数据源有序回退：windy 自建镜像 -> raw -> cnxiaobai 前缀 raw -> api contents(base64) -> 内嵌 SEED
 *       结果缓存在模块态；force 参数可强制重取：fetchIndex(["1"])
 *   checkUpdates(listJson)          -> {ok,results:[{uuid,local,latest,hasUpdate,assetUrl,err}],indexVia}
 *       listJson = JSON.stringify([{uuid,version},...])；只查清单里出现的 uuid。
 *   installLatest(uuid)             -> {ok,uuid,name,version,asset,bytes,sha256,savedTo,via,err,attempts,writeMode,sizeOnDisk,sizeOk,verWarn}
 *       verWarn = 'declared-X>got-Y'：实拿内容低于索引声明版本时非空（v1.3.0），ArkTS 侧拼进 toast 明示；
 *       version 一律 = 胜出字节自身版本（实际内容口径，绝不用清单值冒充）。
 *       下载有序回退（v1.2.0）：npm CDN（registry latest -> release tag -> latest 别名）-> npm tarball
 *       -> release 资产代理 -> release 资产直链 -> npm CDN(清单声明版本)；release 取不到（含 404 =
 *       该仓库压根没有 Release）不再截断链路，继续往 npm 系走；
 *       落盘 <root>/plugins/<uuid前段>-<tag>.bundle.cjs，只下载不装载（装载/登记归 ArkTS）。
 * 超时红线：Rust CALL_TIMEOUT 30s ⇒ 所有多源循环共用一个 26s 预算（DL_BUDGET_MS），
 * 预算耗尽立即停止换源并在 err 里标 'budget-exhausted'，绝不让 fnPath 超时被 Rust 掐死。
 *
 * v1.2.0 -> v1.3.0 修的是真机「商店卡片显示 0.1.1、点下去实际装到 0.0.7」（用户 2026-11-25 report 主诉）：
 *   根因（已取证）：v1.2.0 把 GitHub releases/latest 的 tag 当作「版本 + 下载 URL」的唯一权威 ——
 *   ① installLatest 候选首位 pushCdn(tag,'npm-rel') 用 GitHub tag 去拼 npm CDN 路径；② checkUpdates 的
 *   row.latest 也用 tag。可插件作者的真实发布渠道是 npm（线上索引 17 枚有 npmName 的里面，npm
 *   dist-tags.latest == 索引 version 的有 15 枚，唯一不等的是 e-hentai 且差值方向 = npm 更新），
 *   而 GitHub release 停在半年前 ⇒ tag=0.0.7 时打 npm 拿到 npm 上那个老 0.0.7，比 tag 新得多的 0.1.1
 *   反而永远不会被选中。全量审查 25 枚 = 6 枚被锁旧版 + 1 枚显示低估（详见
 *   _tmp/s41takeover/jmaudit/JM_VERSION_AUDIT.md；deretame/* 名下 15 枚 GitHub 与索引无一枚一致）。
 *   上游 Breeze 根本不是这个口径（本轮逐文件核过，判定 = 上游有更优且现成可对齐的口径）：
 *     · 装哪个版本  Breeze/lib/plugin/plugin_install_service.dart:46  cloudVersion = item.manifest.version.trim()
 *                   ⇒ 索引 version，不查任何 latest，链路里压根没有 GitHub tag 这个变量
 *     · 下载 URL    Breeze/lib/plugin/utils/plugin_cloud_download_utils.dart:155
 *                   'npm/$npmName@$cloudVersion/dist/$npmName.bundle$ext' ⇒ npm CDN 主渠道，
 *                   全挂才 fetchReleaseData(updateUrl) 读 asset 的 browser_download_url（从不自己拼 releases/download/<tag>/）
 *     · 有无新版本  Breeze/lib/plugin/utils/plugin_update_channel_utils.dart:126-134 ⇒ npmName 非空即
 *                   fetchNpmLatestVersion（npmmirror → data.jsdelivr → registry.npmjs 读 dist-tags.latest），
 *                   只有 npmName 为空才退 updateUrl 的 tag_name
 *   v1.3.0 四条改动：一、npmLatest 提到 releaseLatest 之前，版本权威 = maxsemver(npmTag, 索引 version, GitHub tag)；
 *   二、候选序改 npm 权威序（bestVer → npmTag → 索引 version → latest 别名 → release tag → tarball → release 资产），
 *   bestVer 在 npm 侧不可用时自然落回 GitHub tag ⇒ 无 npmName 的 8 枚行为逐字节不变；
 *   三、releaseLatest(repo, npmVer) 在已拿到 npm/索引版本时跳过 releases/latest 那次 API 往返（真机 gh-proxy
 *   不通时这 10s 正是「下载失败」本身），改为用胜出版本自拼 asset 兜底；
 *   四、checkUpdates 同口径（npmName 非空先查 npm，tag 仅在 npm 不可用时报出），新增 verWarn 出口字段。
 *   刻意保留：SEED 兜底路径照旧查 release（离线快照里压根没有 npmName 字段，:90-110）；
 *             pickAsset 只吃 .cjs 不吃 .cjs.br（运行时没有 brotli 解码能力，上游有）；sha256 自算保留（上游 lib/ 零命中，我方更严）。
 */
'use strict';
(function () {
  var SRC = 'plugin-mgr-0004';
  var VERSION = '1.3.0';

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
  // 两者都支持 latest 别名（v1.2.0 实测 = 无 Release 的那批全 200）⇒ 别名是通用兜底。
  var NPM_CDN = ['https://cdn.jsdmirror.cn/', 'https://jsd.onmicrosoft.cn/'];
  // npm registry（v1.2.0 新增，只用于拿 dist-tags.latest 与 tarball；npmmirror 国内实测 100ms 级）
  var NPM_REGISTRY = ['https://registry.npmmirror.com/', 'https://registry.npmjs.org/'];
  var UA = 'Breeze/3.0';

  var INDEX_MS = 2500;     // 单个索引源超时
  var RELEASE_MS = 2500;   // 单个 release API 源超时
  var DL_SOURCE_MS = 5000; // 单个下载源超时
  var DL_BUDGET_MS = 26000;
  var NPM_RESOLVE_MS = 2500; // 单个 npm registry 源超时（v1.2.0）
  var CHECK_CONCURRENCY = 3;
  var CHECK_MAX = 12;

  // —— 内嵌索引快照：2026-11-09 抓自 Breeze-plugin-list/plugins_data.json（权威 21 条逐字）——
  // 注意 manifest.version 是「清单声明版本」，可能比 release tag 新（例 JmComic 清单 0.1.1 / 实际 release v0.0.7，
  // 而 npm dist-tags.latest = 0.1.1 = 清单值 ⇒ 作者真实发布渠道是 npm，GitHub release 才是掉队的那一个）
  // ⇒ v1.3.0 起口径反转：安装与「有无更新」以 maxsemver(npm latest, 清单 version, release tag) 为准，
  //   release tag 退居兜底（无 npmName 的条目照旧只能靠它）；SEED 仍只当离线兜底与仓库映射表用。
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
  // 多路版本号取最大（v1.3.0）：npm dist-tags.latest / 索引 version / GitHub release tag 三路对拍。
  // 上游同款自研实现见 Breeze/lib/plugin/utils/plugin_version_utils.dart（剥 v 前缀 + 分段比较，不用 pub_semver）。
  function semverMax(list) {
    var best = '';
    for (var i = 0; i < list.length; i++) {
      var v = stripV(list[i]);
      if (!v) continue;
      if (!best || semverLt(best, v)) best = v;
    }
    return best;
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
      // v1.2.0：候选可带 ver（下载候选用它标版本），命中时原样带出去 ⇒ out.version 与实际内容同源
      tries.push({ label: c.label, ok: g.ok, status: g.status, bytes: g.bytes, ms: g.ms, ver: c.ver || '', err: g.err ? g.err.slice(0, 90) : '' });
      if (g.ok) { g.via = c.label; g.ver = c.ver || ''; g.tries = tries; return g; }
    }
    var bad = tries.length ? tries[tries.length - 1] : null;
    var fail = {
      ok: false, status: bad ? bad.status : 0, bytes: 0, ms: 0,
      err: bad ? (bad.err || ('HTTP ' + bad.status)) : 'no-candidate', tlsErr: bad ? 'conn' : 'other'
    };
    fail.via = ''; fail.tries = tries;
    return fail;
  }

  /** 逐源尝试摘要拼一行（v1.2.0）：失败时并进 err，商店 toast 上直接能看出卡在哪个源。 */
  function lastSummary(tries) {
    var a = tries || [];
    var s = [];
    for (var i = 0; i < a.length && i < 6; i++) {
      var one = a[i] || {};
      var why = one.ok ? 'ok' : (one.status ? 'HTTP ' + one.status : String(one.err || 'fail').replace(/[\r\n\t]+/g, ' ').slice(0, 24));
      s.push(one.label + ':' + why);
    }
    if (a.length > 6) s.push('+' + (a.length - 6) + ' more');
    return s.join(' | ');
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

  /**
   * release 资产通路：API 类 ⇒ 走 GH_API_MIRRORS（v1.0.0 漏的就是这一步）。
   * v1.3.0：第二参 npmVer 非空 ⇒ 版本已由 npm/索引侧定下，releases/latest 那次 API 往返对结果毫无贡献，
   * 直接返回 skipped 并用它自拼 asset 兜底 —— 真机 gh-proxy.org 家族不通时（v1.0.0 那次 HTTP 403 即此域），
   * 这次往返要吃掉 3×2.5s + 直连 ≈ 10s，而 installLatest 总预算只有 DL_BUDGET_MS=26s。
   * 自拼 URL 的格式与真实 asset 实测一致（v0.0.7 的 asset 名 = 插件 npm 包名去掉 "breeze-plugin-" 前缀）。
   * tag 权威仍是本函数默认行为：SEED 兜底路径没有 npmName，只能靠它。
   */
  async function releaseLatest(repo, npmVer) {
    var nv = stripV(npmVer || '');
    if (nv) {
      var sn = String(repo).split('/');
      var rn = String(sn[sn.length - 1] || '').toLowerCase();
      if (rn.indexOf('breeze-plugin-') === 0) rn = rn.slice('breeze-plugin-'.length);
      var guessed = rn ? ('https://github.com/' + repo + '/releases/download/v' + nv + '/' + rn + '.bundle.cjs') : '';
      return {
        ok: !!guessed, skipped: 'npm-authoritative', tag: nv,
        assets: guessed ? [{ name: rn + '.bundle.cjs', url: guessed }] : [],
        via: '', tries: [], status: 0
      };
    }
    var api = 'https://api.github.com/repos/' + repo + '/releases/latest';
    var cands = [];
    for (var i = 0; i < GH_API_MIRRORS.length; i++) cands.push({ label: 'rel-api' + (i + 1), url: GH_API_MIRRORS[i] + api });
    cands.push({ label: 'rel-api-direct', url: api });
    var g = await tryEach(cands, RELEASE_MS, true, 0);
    // v1.2.0：状态码与逐源结果带出去 —— 调用方要区分「这个仓库没有 Release(404)」与「网络不通」
    if (!g.ok) return { ok: false, err: g.err || 'release-fetch-fail', via: '', status: g.status || 0, tries: g.tries || [] };
    try {
      var o = JSON.parse(g.text);
      var assets = [];
      var la = o.assets || [];
      for (var k = 0; k < la.length; k++) assets.push({ name: String(la[k].name || ''), url: String(la[k].browser_download_url || '') });
      return { ok: true, tag: stripV(o.tag_name || o.tag || ''), assets: assets, via: g.via, tries: g.tries, status: 200 };
    } catch (e) { return { ok: false, err: 'release-parse:' + String(e && e.message).slice(0, 80), via: g.via, status: g.status || 0, tries: g.tries }; }
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

  /**
   * npm registry 解析（v1.2.0 新增）：只用来定版本号 + 多一条 tarball 候选。
   * 失败返回 ok=false 不算错（CDN 的 latest 别名不依赖它）。maxSources=1 给 checkUpdates 省预算。
   * scoped 包名里那个斜杠不能转义（registry 按原始名取），故把 encodeURIComponent 产生的 %2F 换回斜杠。
   */
  async function npmLatest(pkg, maxSources) {
    var lim = maxSources > 0 ? Math.min(maxSources, NPM_REGISTRY.length) : NPM_REGISTRY.length;
    var cands = [];
    for (var i = 0; i < lim; i++) {
      cands.push({ label: 'registry' + (i + 1), url: NPM_REGISTRY[i] + encodeURIComponent(pkg).replace(/%2F/g, '/') });
    }
    var g = await tryEach(cands, NPM_RESOLVE_MS, true, 0);
    if (!g.ok) return { ok: false, err: g.err || 'registry-fail', tries: g.tries || [] };
    try {
      var o = JSON.parse(g.text);
      var tag = String(((o['dist-tags'] || {})['latest']) || '');
      var tar = '';
      var vs = o.versions || {};
      if (tag && vs[tag] && vs[tag].dist) tar = String(vs[tag].dist.tarball || '');
      return { ok: true, tag: tag, tarball: tar, via: g.via, tries: g.tries || [] };
    } catch (e) {
      return { ok: false, err: 'registry-parse:' + String((e && e.message) || e).slice(0, 60), tries: g.tries || [] };
    }
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
        // v1.3.0：npm 优先（对齐上游 plugin_update_channel_utils.dart:126-134 —— npmName 非空就不碰 release）。
        // v1.2.0 及以前是 release tag 优先，而 tag 常落后作者真实渠道半年 ⇒ row.latest 报旧版，
        // 「可更新」角标对那 6 枚受害者永远不亮（例：索引/npm 都是 0.1.1，tag 还是 0.0.7）。
        // assetUrl 仍只在 release 通路上有值，且不再为它单独花一次 API —— 它是第 4 位兜底，
        // 真用到时 installLatest 自己会重查。
        if (ent.npmName) {
          var np = await npmLatest(ent.npmName, 1);
          if (np.ok && np.tag) {
            row.latest = semverMax([np.tag, ent.version]);
            row.hasUpdate = !row.local || semverLt(row.local, row.latest);
            results.push(row);
            continue;
          }
          row.err = 'npm:' + (np.err || 'npm-fail');
        }
        // 传 '' 而非 ent.version：这条腿必打真查询 ⇒ row.assetUrl 保持 v1.2.0 的「来自真查询的真资产名」语义。
        // （v1.3.0 初稿在这里传了索引版本 ⇒ assetUrl 变成按索引拼的猜测值，可能指向不存在的资产；
        //   它虽零消费方，但把未证实的 URL 放进载荷是净退化 ⇒ 恢复真查。装版本链不受此影响。）
        var r = await releaseLatest(repoOf(ent), '');
        var as = r.ok ? pickAsset(r.assets) : null;
        if (as) row.assetUrl = as.url;
        if (r.ok && r.tag) {
          row.latest = r.tag;
          row.hasUpdate = !row.local || semverLt(row.local, r.tag);
          results.push(row);
          continue;
        }
        row.err = (row.err ? row.err + '&' : '') + (r.err || (r.status === 404 ? 'no-release-404' : 'no-release'));
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
      savedTo: '', via: '', err: '', attempts: [], writeMode: '', sizeOnDisk: 0, sizeOk: false, verWarn: ''
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

    // npm 侧解析先跑（v1.3.0：顺序反转）。先拿版本号，release 那条路才有可能被整段跳过。
    var npmTag = '';
    var npmTarball = '';
    var npmTries = [];
    if (ent.npmName) {
      var np = await npmLatest(ent.npmName, 0);
      npmTries = np.tries || [];
      if (np.ok) { npmTag = np.tag; npmTarball = np.tarball; }
    }
    // 权威版本 = max(npm dist-tags.latest, 索引声明版本, GitHub release tag)。
    // 上游用「索引 version」这一个值就够（plugin_install_service.dart:46），我方额外把 npm latest 与
    // release tag 也拉进来对拍，是为了兼容索引自身滞后的那枚（线上 25 枚实测：e-hentai 索引 0.1.8 < npm 0.1.9）。
    var bestVer = semverMax([npmTag, ent.version]);
    // v1.2.0：release 只是「拿 tag + 资产」的一条路，失败不再 return（SEED 里 9 条压根没有 Release）。
    var relStatus = 0;
    var tag = '';
    var asset = null;
    // 有 npmName ⇒ bestVer 已经拿得出来，release API 对版本毫无贡献 ⇒ 传 bestVer 走 skipped（省 10s 预算）。
    // 无 npmName ⇒ 照旧查 releases/latest，GitHub tag 是这类插件唯一的版本来源，行为与 v1.2.0 逐字节一致。
    var r = await releaseLatest(repo, ent.npmName ? bestVer : '');
    if (r.ok && r.tag) {
      tag = r.tag;
      asset = pickAsset(r.assets);
    } else {
      relStatus = r.status || 0;
    }
    if (!bestVer) bestVer = stripV(tag || '');
    out.asset = asset ? asset.name : '';

    // 候选顺序（v1.3.0 反转为 npm 权威序）：bestVer -> npm registry latest -> 索引声明版本 -> latest 别名
    //   -> release tag 版本（兜住 npm 上只有旧版号的仓库）-> npm tarball -> release 资产代理 -> 直链。
    // 与上游同构：plugin_cloud_download_utils.dart:155 就是 npm CDN 主渠道、GitHub release 只兜底。
    // v1.2.0 把 pushCdn(tag) 放首位，等于拿半年前的 tag 去 npm 取包 ⇒ 装到旧版（本次缺陷的病灶）。
    // 同一版本多源重复是故意的：jsdelivr 系两个镜像互为备份（v1.0.0 的教训 = 单源不通就整体失败）。
    // bestVer == tag 时（线上 8 枚无 npmName 的插件即如此）去重后候选集与顺序与 v1.2.0 逐字节一致。
    var cands = [];
    var seen = {};
    var push = function (label, url, ver) {
      if (!url || seen[url]) return; // 去重：npm latest 与 release tag 常是同一个版本号
      seen[url] = 1;
      cands.push({ label: label, url: url, ver: ver || '' });
    };
    var pushCdn = function (ver, label) {
      if (!ent.npmName || !ver) return;
      var ap = 'npm/' + ent.npmName + '@' + ver + '/dist/' + ent.npmName + '.bundle.cjs';
      // 'latest' 别名命中时无法从 URL 知道版本，而它的内容恒等于 npm dist-tags.latest ⇒ registry 已知时
      // 用 npmTag 标注最准（v1.2.0 那里塞的是 GitHub tag，会把半年前的 tag 冒充成实际内容版本）；
      // registry 失败（npmTag 空）才退回 bestVer，最后才 tag —— 都是推测，但已无更优信息。
      for (var c = 0; c < NPM_CDN.length; c++) push(label + (c + 1), NPM_CDN[c] + ap, ver === 'latest' ? (npmTag || bestVer || tag) : ver);
    };
    pushCdn(bestVer, 'npm-best');
    pushCdn(npmTag, 'npm-latest-tag');
    pushCdn(stripV(ent.version || ''), 'npm-indexver');
    pushCdn('latest', 'npm-alias');
    pushCdn(tag, 'npm-rel');
    if (npmTarball) push('npm-tarball', npmTarball, npmTag || bestVer);
    if (asset && asset.url) {
      for (var p = 0; p < GH_FILE_MIRRORS.length; p++) push('rel-mirror' + (p + 1), GH_FILE_MIRRORS[p] + asset.url, tag);
      push('rel-direct', asset.url, tag);
    }
    if (!cands.length) {
      out.err = 'no-candidate(relStatus=' + relStatus + '; npm=' + (ent.npmName ? 'yes' : 'none') + ')';
      out.attempts = npmTries;
      return out;
    }

    // v1.3.0 补刀：本轮为省 10s 跳过过 releases/latest ⇒ 手里那个 tag 是「猜的」，不是 GitHub 的真 tag。
    // 两种情况下必须去捞真 tag + 真资产再试一轮：
    //   ① 首轮全挂 —— 否则连 v1.2.0 能救回的仓库也不再能救（自拼 asset 名可能猜不中）；
    //   ② 首轮拿到的版本低于 bestVer（降级）—— 对齐上游 plugin_cloud_download_utils.dart:176-190 的兜底方向：
    //      npm 供不出声明的版本时上游就去 GitHub 的真实资产；我方若不补就会被 npm 上的旧版号锁住（IT 用例 4 实测到）。
    // 快路径（bestVer 一次命中且不低于 bestVer）不触发 ⇒ 常见路径零额外请求；r.skipped 置空保证最多补查一次。
    async function relRescue(why) {
      if (!r.skipped || Date.now() > deadline - 4000) return null;
      var rr = await releaseLatest(repo, '');
      r.skipped = '';
      out.attempts = out.attempts.concat(rr.tries || []);
      if (!rr.ok || !rr.tag) {
        relStatus = rr.status || relStatus;
        return null;
      }
      var a2 = pickAsset(rr.assets);
      var cs = [];
      var sn = {};
      var pu = function (label, url, ver) {
        if (!url || sn[url] || seen[url]) return; // 首轮试过的 URL 不重试
        sn[url] = 1;
        cs.push({ label: why + '-' + label, url: url, ver: ver || '' });
      };
      if (ent.npmName) {
        var apx = 'npm/' + ent.npmName + '@' + rr.tag + '/dist/' + ent.npmName + '.bundle.cjs';
        for (var cx = 0; cx < NPM_CDN.length; cx++) pu('npm-tag' + (cx + 1), NPM_CDN[cx] + apx, rr.tag);
      }
      if (a2 && a2.url) {
        for (var px = 0; px < GH_FILE_MIRRORS.length; px++) pu('mirror' + (px + 1), GH_FILE_MIRRORS[px] + a2.url, rr.tag);
        pu('direct', a2.url, rr.tag);
      }
      if (!cs.length) return null;
      return { cs: cs, tag: rr.tag, asset: a2 };
    }
    function takeRescue(res, gr) {
      out.attempts = out.attempts.concat(gr.tries || []);
      if (!(gr.ok && gr.buf)) return;
      g = gr;
      tag = res.tag;
      asset = res.asset;
      if (res.asset && res.asset.name) out.asset = res.asset.name;
      relStatus = 200;
    }
    var g = await tryEach(cands, DL_SOURCE_MS, false, deadline);
    out.attempts = npmTries.concat(g.tries || []);
    if (!g.ok || !g.buf) {
      var res1 = await relRescue('rel-recover');
      if (res1) takeRescue(res1, await tryEach(res1.cs, DL_SOURCE_MS, false, deadline));
    }
    // 拿到了但低于 bestVer ⇒ 用真 tag 再试一轮，能拿更高就拿更高
    var gotVer = g.ok ? (g.ver || '') : '';
    if (g.ok && g.buf && bestVer && gotVer && semverLt(gotVer, bestVer)) {
      var res2 = await relRescue('rel-up');
      if (res2) {
        var gd = await tryEach(res2.cs, DL_SOURCE_MS, false, deadline);
        out.attempts = out.attempts.concat(gd.tries || []);
        if (gd.ok && gd.buf && gd.ver && semverLt(gotVer, gd.ver)) {
          g = gd; tag = res2.tag; asset = res2.asset;
          if (res2.asset && res2.asset.name) out.asset = res2.asset.name;
        }
      }
    }
    if (!g.ok || !g.buf) {
      var why = g.err === 'budget-exhausted' ? 'all-sources-timeout' : (g.err || 'all-sources-failed');
      out.err = why + '(relStatus=' + relStatus + '; ' + lastSummary(g.tries) + ')';
      return out;
    }
    var buf = g.buf;
    out.via = g.via;
    // 版本口径与实际下载内容同源：命中候选自带的 ver 优先，其次 registry tag，最后清单声明版本
    if (g.ver) tag = g.ver;
    if (!tag && npmTag) tag = npmTag;
    if (!tag) tag = stripV(ent.version || '');
    out.version = tag; // 实际内容口径（绝不用 bestVer 冒充）：落盘名 / PluginRecord.version / 后续 hasUpdate 比较全用它
    // v1.3.0：实际内容低于索引声明版本 ⇒ 留一行可诊断告警（索引滞后于 GitHub 时 bestVer 高于索引声明 ⇒ 不误报）
    var declaredVer = stripV(ent.version || '');
    if (declaredVer && semverLt(tag, declaredVer)) out.verWarn = 'declared-' + declaredVer + '>got-' + tag;
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
