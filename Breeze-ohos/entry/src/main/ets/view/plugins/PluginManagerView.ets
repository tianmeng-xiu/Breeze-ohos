/**
 * 职责：S4 插件管理页主体 —— 列表 = pluginScanDir('plugins') ⊕ PluginStore('installed.json') join；
 *       操作 = 启用开关、更新、删除（bundleUnload → pluginRemoveFile → 清桶，顺序硬约束防内存挂已删文件）。
 * 第 7 条改造（2026-11-11 用户裁定）：**行内不再有「打开/装载」按钮**，装载全部自动：
 *       进本页 refresh 里自动登记未登记文件 + 自动装载「启用且可用」的插件（PluginAutoLoader）；
 *       开关打开即真装载（不是懒装载），开关状态由 PluginStore.setEnabled 落盘、重启保留。
 * 依赖：PluginRuntime(ABI v3 三导出)、PluginStore、JsonUtil、Theme。引擎 init(filesDir) 由
 *       EntryAbility/Index 已完成；本页所有引擎调用前判 rootGlobal 级前置 = try/catch 后原文 toast
 *       （no-storage-root 会直接可见）。面板（诊断弹层）不经此处，保持现状。
 * join 三态仍在模型里（state：文件有+清单有=ok；文件有+清单无=unregistered；清单有+文件无=missing）。
 *       s13 第 3 条起卡面不再渲染状态文案，三态只体现在 灰字（missing）与 有无启用开关（非 ok 没有开关）。
 * s13 第 2 条（2026-11-12 用户裁定）：**删除「造演示」按钮与 seedDemo** —— 那是引擎联调时造的演示数据入口，
 *       真机验收改走 商店下载 与 诊断面板自查；rawfile 下文件一律未动。
 * s14 第 3 条（2026-11-13 用户裁定）：**屏上不再出现任何目录/实现路径** —— 本应用要给别人用。
 *       工具条那行的「插件目录 filesDir/plugins」已撤；所有异常原文改经 errBrief() 洗掉沙箱路径后
 *       才上屏，完整原文一律进 hilog（Logger）。
 * s14 第 4 条：插件名前显示插件自带图标（商店索引 iconUrl），无图标 = 应用图标等比缩小占位。
 * s15 第 3 条（2026-11-13）：图标「只有下载之后才出现」的三条真因与对应改法 ——
 *       ① 索引字段层：载荷的 mapIndex 已把 manifest 摊平（顶层就带 iconUrl），ArkTS 侧再加一层
 *          manifest 兜底是死代码 ⇒ 不加（取证见 lead 裁定与 _tmp/s15）。
 *       ② 持久化层：已装列表的图标过去**只**认落盘的商店映射（按 localFile 查），老落盘行与
 *          没带图标的行恒空 ⇒ 现在拿到索引后按 indexUuid 现场关联（fillIconsFromIndex），并只给
 *          「已存在且图标为空」的条目回填落盘（绝不新建条目 ⇒ 预置件不会被写成商店件）。
 *       ③ 取图链路层：索引 24 条里 23 条有 iconUrl，但其中 14 条挂在 raw.githubusercontent.com 与
 *          cdn.jsdelivr.net 上，这两个域名的连接层 RST 在 rawfile/plugins/selftest.bundle.cjs:37-38
 *          有真机实测记录，而载荷自己取索引/取资产都走镜像、我方取图标过去只有直链 ——
 *          商店卡片（图标地址当场就在手里）同样是占位图，坐实挂在取图这一腿。
 *          ⇒ 直链失败后按包内同款镜像补一次（成功路径零改动，可整档关掉），
 *          并做成 PluginIconDiag 模块级计数交 lead 接诊断面板第 18 号行（本文件不自己占行号）。
 * s15 第 7 条：商店卡片标题 layoutWeight(1) + 角标 flexShrink(0) ⇒ 长名字不再把右侧下载按钮顶出屏。
 */
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { pluginScanDir, bundleUnload, bundleList, pluginRemoveFile, bundleCall, bundleLoad } from '../../util/PluginRuntime';
import { PluginStore, PluginRecord, ShopMapEntry } from '../../util/PluginStore';
import { PluginSourceRegistry } from '../../data/source/PluginSourceRegistry';
import { PluginAutoLoader, LoadOutcome } from '../../data/source/PluginAutoLoader';
import { deriveLocalUuid } from '../../util/PluginUuid';
import { jparse, jstr, jnum, jbool, jarr } from '../../util/JsonUtil';
import { util } from '@kit.ArkTS';
import { Theme, Dim } from '../common/Theme';
import { image } from '@kit.ImageKit';
import { Logger } from '../../util/Logger';
import { ImageCache } from '../../data/image/ImageCache';

/** scanDir 单项（ABI §7：[{name,bytes,mtimeMs}]）。 */
class ScanItem {
  name: string = '';
  bytes: number = 0;
  mtimeMs: number = 0;
}

/** join 后的行模型。state: ok / unregistered / missing。loaded 只在装载成功后短暂为 true（本页不做常驻追踪）。 */
export class PluginRow {
  uuid: string = '';
  title: string = '';
  version: string = '';
  localFile: string = '';
  bytes: number = 0;
  enabled: boolean = true;
  state: string = 'ok';
  loaded: boolean = false;
  indexUuid: string = '';
  /** 插件图标地址（s14 第 4 条，来自商店映射的 iconUrl）；手放的文件与老数据恒空 ⇒ 走占位图。 */
  iconUrl: string = '';
  /** 检查更新结果（瞬态，refresh 后清空）。 */
  latest: string = '';
  hasUpdate: boolean = false;
}

/** 商店索引行（plugin_mgr.bundle.cjs fetchIndex.items）。 */
export class ShopItem {
  uuid: string = '';
  name: string = '';
  version: string = '';
  describe: string = '';
  /** v1.1.0 起索引带仓库/主页（商店卡片按原版样式显示「仓库: …」用）。 */
  repo: string = '';
  home: string = '';
  /** s14 第 4 条：索引自带的插件图标地址（IndexItem.iconUrl）；空 = 用应用图标占位。 */
  iconUrl: string = '';
  downloading: boolean = false;
}

/** checkUpdates 入参条目（ArkTS 禁对象字面量 ⇒ 类）。 */
class ChkEntry {
  uuid: string = '';
  version: string = '';
}

/** 商店 bundle 在引擎 registry 里的固定名（bundleLoad('pluginMgr', src)）。 */
const MGR_NAME: string = 'pluginMgr';

/**
 * 第 4 条：行内图标的边长（正方形）。取值依据 —— 行内其余元素高 = 按钮 28vp、齿轮 20vp、
 * Toggle 约 30vp、标题 15fp 单行；32vp 取 lead 建议区间 28~36 的中值，叠加行上下 padding 10 后
 * 行高 52vp，仍低于 Dim.menuItemH(56)，即「加图标不把行撑高」。
 */
const PLUGIN_ICON_SIZE: number = 32;

/**
 * 第 6 条（增强）：进页静默检查更新的节流常量，全部写在这一处。
 * AUTO_CHECK_ENABLED 置 false 即完全回到旧行为（只有点按钮才检查）。
 * AUTO_CHECK_MIN_GAP_MS = 4h：一次自动检查 = fetchIndex（上游索引）+ N 次 release 探测，
 * 每次路由进出都跑一遍对「给别人用的应用」太吵；4 小时足够覆盖「打开应用时顺手看一眼有无更新」。
 * 失败只在**当天**封禁（跨天自动解禁）：断网/上游挂了不该在同一天里反复重试。
 * 三个状态都是模块级（进程内共享，重启自然复位）⇒ 不新增落盘键、不动 PluginStore 的桶。
 */
const AUTO_CHECK_ENABLED: boolean = true;
const AUTO_CHECK_MIN_GAP_MS: number = 4 * 60 * 60 * 1000;
let autoCheckLastOkAt: number = 0;
let autoCheckFailDay: number = -1;

/** 天序号（按 UTC 整日取模）：只在「同一天」内封禁失败重试。 */
function dayIndex(ms: number): number {
  return Math.floor(ms / 86400000);
}

/** 自动检查是否放行：失败当天不重试；刚成功过不到 MIN_GAP 也不重复。 */
function autoCheckAllowed(now: number): boolean {
  if (autoCheckFailDay === dayIndex(now)) {
    return false;
  }
  if (autoCheckLastOkAt > 0 && now - autoCheckLastOkAt < AUTO_CHECK_MIN_GAP_MS) {
    return false;
  }
  return true;
}

/** 记一次自动检查的结果（成功记时刻，失败记当天）。 */
function autoCheckMark(now: number, ok: boolean): void {
  if (ok) {
    autoCheckLastOkAt = now;
    autoCheckFailDay = -1;
  } else {
    autoCheckFailDay = dayIndex(now);
  }
}
/**
 * s15 第 3 条②：本次进程内从商店索引记下的 indexUuid 到 iconUrl 的即时档。
 * 为什么记在模块级：索引真正落到 ArkTS 手里只有 openShop 解析成功那一刻，而「已装列表」的图标
 * 之后每一次 refresh 都要查得到；上限 64 防无界增长（现役索引 24 条，留一倍余量）。
 * 落盘仍走 PluginStore 的商店映射（见 persistIconBackfill），这里只是进程内的即时档。
 */
const ICON_INDEX_MAX: number = 64;
const indexIconById: Map<string, string> = new Map<string, string>();

/** s15 第 3 条②：本次进程内是否已静默补拉过一次索引（闸门用，见 warmIconsFromIndex）。 */
let iconWarmTried: boolean = false;

/** 记一次商店索引里的图标地址（openShop 解析成功后调用；空 uuid 与空图标一律不记）。 */
function rememberIndexIcons(items: ShopItem[]): void {
  for (let i = 0; i < items.length; i++) {
    const it: ShopItem = items[i];
    if (it.uuid.length === 0 || it.iconUrl.length === 0) {
      continue;
    }
    if (!indexIconById.has(it.uuid) && indexIconById.size >= ICON_INDEX_MAX) {
      continue;
    }
    indexIconById.set(it.uuid, it.iconUrl);
  }
}

/** 查 indexUuid 对应的图标地址；没记过给空串（调用方按「空 = 不覆盖」处理）。 */
function indexIconOf(uuid: string): string {
  if (uuid.length === 0) {
    return '';
  }
  const v: string | undefined = indexIconById.get(uuid);
  return v === undefined ? '' : v;
}

/**
 * s15 第 3 条③：本次进程内已经「直链 + 镜像全挂」的图标地址表。
 * 为什么必须有：List 复用节点 ⇒ 来回滚动会让同一个 PluginIcon 反复 onIconChanged 重取；而
 * ImageCache 内部**没有 in-flight 去重、也没有失败缓存**（全文件 grep pending/inFlight = 0），
 * 每张挂掉的图标 = 直链 1 次 + 镜像最多 3 次真请求、单次读超时 30s。商店 24 张卡片一起挂 = 上百个请求，
 * 滚动一次再翻一倍。记一档就把这笔账压成「每地址一次进程」；跨进程仍会重试（新一次打开应用 = 新机会）。
 * 上限 128：现役索引 24 条，留五倍余量；到顶就不再记（宁可多试也不能无界增长）。
 * 想撤：ICON_FAIL_MEM_MAX 置 0 即整档关掉（回到每次渲染都重试）。
 */
const ICON_FAIL_MEM_MAX: number = 128;
const iconDeadUrls: Map<string, number> = new Map<string, number>();

/** 这个地址是否已经在本进程里试过且全档落空（非 http(s) 一律答「没试过」⇒ 由 begin 记 badUrl）。 */
function iconKnownDead(url: string): boolean {
  if (ICON_FAIL_MEM_MAX === 0 || url.length === 0) {
    return false;
  }
  return iconDeadUrls.get(url) !== undefined;
}

/** 记一次全档落空（只记 http(s)，其它形态每次照常走 badUrl 口径）。 */
function iconMarkDead(url: string): void {
  if (ICON_FAIL_MEM_MAX === 0 || url.length === 0) {
    return;
  }
  if (url.indexOf('http://') !== 0 && url.indexOf('https://') !== 0) {
    return;
  }
  if (iconDeadUrls.size >= ICON_FAIL_MEM_MAX) {
    return;
  }
  iconDeadUrls.set(url, 1);
}

/**
 * s15 第 3 条③：图标直链失败后的镜像补档 —— 只在「直链已经抛错」之后才走，成功路径零改动。
 * 域名与前缀不是拍的：与 rawfile/plugins/plugin_mgr.bundle.cjs:59-73 里逐条 curl 实测 200 的
 * GH_FILE_MIRRORS 与 NPM_CDN 同源（那份载荷取索引、取资产用的就是这两组镜像，唯独图标没走）。
 * 代价我认：常量在包内载荷与这里各一份，而载荷在出包红线上（包内 sha 2708af62）动不得，
 * 所以抄到 ArkTS 侧 —— 改镜像名单必须两处一起改，这句就是留给以后的提醒。
 * 整档想撤：ICON_MIRROR_ENABLED 置 false（或删掉 load 里的镜像循环），直链行为逐字回到 s14。
 */
const ICON_MIRROR_ENABLED: boolean = true;
const ICON_GH_PREFIXES: string[] = ['https://v4.gh-proxy.org/', 'https://gh-proxy.org/', 'https://cdn.gh-proxy.org/'];
const ICON_JSD_HOSTS: string[] = ['cdn.jsdmirror.cn', 'jsd.onmicrosoft.cn'];
const ICON_ALT_MAX: number = 4;

/**
 * 直链的备选地址（路径一律原样保留）：GitHub 原始文件 = 前缀式加速（前缀 + 完整原始 URL）；
 * jsdelivr = 同一服务的镜像域名换 host（路径原样、不叠斜杠）。其余域名（各家站点 favicon 等）不给备选 ——
 * 那些挂了是上游或网络本身的问题，套 GitHub 代理只会把错因搅浑。
 */
function iconAlternates(url: string): string[] {
  const out: string[] = [];
  if (!ICON_MIRROR_ENABLED || url.indexOf('https://') !== 0) {
    return out;
  }
  const gh: string = 'https://raw.githubusercontent.com/';
  if (url.indexOf(gh) === 0) {
    for (let i = 0; i < ICON_GH_PREFIXES.length && out.length < ICON_ALT_MAX; i++) {
      out.push(ICON_GH_PREFIXES[i] + url);
    }
    return out;
  }
  const jsd: string = 'https://cdn.jsdelivr.net/';
  if (url.indexOf(jsd) === 0) {
    const tail: string = url.slice(jsd.length);
    for (let i = 0; i < ICON_JSD_HOSTS.length && out.length < ICON_ALT_MAX; i++) {
      out.push('https://' + ICON_JSD_HOSTS[i] + '/' + tail);
    }
  }
  return out;
}

/** 取 URL 的 host：只给诊断用，解析不出来就给短前缀，绝不抛。 */
function iconHostOf(url: string): string {
  const i: number = url.indexOf('//');
  const rest: string = i >= 0 ? url.slice(i + 2) : url;
  const j: number = rest.indexOf('/');
  const h: string = j >= 0 ? rest.slice(0, j) : rest;
  return h.length > 40 ? h.slice(0, 40) : h;
}

/**
 * 短错因标签。诊断行是上屏的 ⇒ 一律归一成 http404、net7010066 这类形态：
 * HttpClient 抛的 HttpStatusError.message 里带完整 URL，照抄会把图标地址整条印到屏上
 * （与 s14 第 3 条「屏上不再出现任何路径」同一口径，这里替诊断多挡一层 URL）。
 */
function iconErrTag(e: Object): string {
  const msg: string = e instanceof Error ? (e as Error).message : String(e);
  const first: string = msg.split('\n')[0];
  const atHttp: number = first.indexOf('请求失败 HTTP ');
  if (atHttp >= 0) {
    let s: string = first.slice(atHttp + 10);
    const colon: number = s.indexOf('：');
    if (colon > 0) {
      s = s.slice(0, colon);
    }
    const sp: number = s.indexOf(' ');
    if (sp > 0) {
      s = s.slice(0, sp);
    }
    return 'http' + (s.length > 5 ? s.slice(0, 5) : s);
  }
  const atNet: number = first.indexOf('网络请求失败(');
  if (atNet >= 0) {
    const tail: string = first.slice(atNet + 7);
    const close: number = tail.indexOf(')');
    return 'net' + (close > 0 ? tail.slice(0, close) : tail.slice(0, 6));
  }
  const colon2: number = first.indexOf('：');
  const cut: string = colon2 > 0 ? first.slice(0, colon2) : first;
  return cut.length > 24 ? cut.slice(0, 24) : cut;
}

/**
 * s15 第 3 条③：插件图标取图链的可观测性（模块级静态，与 ImageCache.imageChain 系同款口径）。
 * 刻意不自己往诊断面板加行：行号是证据链的引用锚点（16=imageChain、17=readerChain 已占），
 * 出包前由 lead 在 pages/Index.ets 接第 18 号行。这里只交静态口径 ——
 *   类名 PluginIconDiag；一行文案 PluginIconDiag.hint()；恒等式自查 PluginIconDiag.balanced()；
 *   建议行名 pluginIcons，截断档同 16、17 号行的 720。
 * 恒等式：calls = okDirect + okMirror + fail。calls 只数 iconUrl 非空且形如 http(s) 的取图；
 * 上游没给图记 noUrl、图标值不是 URL 记 badUrl，两者都不进 calls ⇒ 不会污染失败率。
 * per-host 直方图是这一行最有信息量的字段：现役索引 23 条图标里 14 条挂在上面那两个被 RST 的
 * 域名上，按域名一比 ok/tries 就把「图标不显示」落到具体 host，不必再靠猜。
 */
export class PluginIconDiag {
  /** 进入取图的次数（口径见类注释） */
  static calls: number = 0;
  /** 直链一次成功 */
  static okDirect: number = 0;
  /** 直链挂了、镜像档救回 */
  static okMirror: number = 0;
  /** 直链与镜像全挂 ⇒ 应用图标占位 */
  static fail: number = 0;
  /** iconUrl 为空（手放文件、s13 前的老落盘行、上游没填） */
  static noUrl: number = 0;
  /** iconUrl 非空但不是 http(s)（现役索引里真有一条值是 404 字面量） */
  static badUrl: number = 0;
  /** 进过镜像补档的次数（与 okMirror 一起看 = 补档救回率） */
  static mirrorTried: number = 0;
  /** 本进程内此前已全档落空、这次直接占位不再发请求的次数（不进 calls 口径） */
  static skipped: number = 0;
  private static hostTries: Map<string, number> = new Map<string, number>();
  private static hostOk: Map<string, number> = new Map<string, number>();
  private static hostOrder: string[] = [];
  private static lastErr: string = '';
  private static lastErrHost: string = '';
  private static readonly HOST_MAX: number = 8;

  /** 一次取图开始：返回该图的诊断 host 键；空串 = 这一张压根不发请求（noUrl 或 badUrl）。 */
  static begin(url: string): string {
    if (url.length === 0) {
      PluginIconDiag.noUrl++;
      return '';
    }
    if (url.indexOf('http://') !== 0 && url.indexOf('https://') !== 0) {
      PluginIconDiag.badUrl++;
      PluginIconDiag.lastErr = 'not-url';
      PluginIconDiag.lastErrHost = '-';
      return '';
    }
    const h: string = iconHostOf(url);
    PluginIconDiag.calls++;
    PluginIconDiag.bumpHost(h);
    return h;
  }

  /** 记一次成功（host 一律记原始直链的域名，是否靠镜像救回看 okMirror 自己） */
  static ok(host: string, viaMirror: boolean): void {
    if (viaMirror) {
      PluginIconDiag.okMirror++;
    } else {
      PluginIconDiag.okDirect++;
    }
    if (host.length > 0) {
      const cur: number | undefined = PluginIconDiag.hostOk.get(host);
      PluginIconDiag.hostOk.set(host, cur === undefined ? 1 : cur + 1);
    }
  }

  /**
   * 记一次失败出口：每次 begin 之后**只准调一次**（load 里全部备选都试过仍拿不到图才调），
   * 传的 tag 是最后一次尝试的错因档。这样类注释里的恒等式 calls = okDirect + okMirror + fail
   * 才成立；中途某一条备选失败但后面救回来的，只走 ok(host, true)，不进这里。
   */
  static failTry(host: string, tag: string): void {
    PluginIconDiag.fail++;
    PluginIconDiag.lastErr = tag.length > 0 ? tag : 'unknown';
    PluginIconDiag.lastErrHost = host.length > 0 ? host : '-';
  }

  static noteMirrorTried(): void {
    PluginIconDiag.mirrorTried++;
  }

  private static bumpHost(host: string): void {
    const cur: number | undefined = PluginIconDiag.hostTries.get(host);
    if (cur === undefined) {
      if (PluginIconDiag.hostOrder.length >= PluginIconDiag.HOST_MAX) {
        return;
      }
      PluginIconDiag.hostOrder.push(host);
      PluginIconDiag.hostTries.set(host, 1);
      return;
    }
    PluginIconDiag.hostTries.set(host, cur + 1);
  }

  private static hostsText(): string {
    let s: string = '';
    for (let i = 0; i < PluginIconDiag.hostOrder.length; i++) {
      const h: string = PluginIconDiag.hostOrder[i];
      const t: number | undefined = PluginIconDiag.hostTries.get(h);
      const o: number | undefined = PluginIconDiag.hostOk.get(h);
      if (s.length > 0) {
        s += ',';
      }
      s += h + ':' + (o === undefined ? 0 : o) + '/' + (t === undefined ? 0 : t);
    }
    return s.length > 0 ? s : '-';
  }

  /** 一行看完整图标链（口径同 imageHint：全 0 属正常 = 还没进过插件管理页） */
  static hint(): string {
    const okAll: number = PluginIconDiag.okDirect + PluginIconDiag.okMirror;
    const hostTxt: string = PluginIconDiag.hostsText();
    const errHost: string = PluginIconDiag.lastErrHost.length > 0 ? PluginIconDiag.lastErrHost : '-';
    let s: string = 'calls=' + PluginIconDiag.calls
      + ' ok=' + okAll + '/' + PluginIconDiag.calls
      + ' direct=' + PluginIconDiag.okDirect
      + ' mirror=' + PluginIconDiag.okMirror + '/' + PluginIconDiag.mirrorTried
      + ' fail=' + PluginIconDiag.fail
      + ' noUrl=' + PluginIconDiag.noUrl
      + ' badUrl=' + PluginIconDiag.badUrl
      + ' skip=' + PluginIconDiag.skipped
      + ' hosts=' + (hostTxt.length > 0 ? hostTxt : '-');
    if (PluginIconDiag.lastErr.length > 0) {
      s += ' err=' + PluginIconDiag.lastErr + '@' + errHost;
    }
    return s;
  }

  /** 恒等式自查：三档互斥出口相加必须等于 calls（离线桩与面板都可用）。 */
  static balanced(): boolean {
    return PluginIconDiag.okDirect + PluginIconDiag.okMirror + PluginIconDiag.fail === PluginIconDiag.calls;
  }
}

/**
 * 跳插件设置页传参（契约：只传三字段，页内自调
 * getSettingsBundle / getCapabilitiesBundle / getUserInfoBundle）。
 * ArkTS 10605038 ⇒ 类承载，禁裸对象字面量。
 */
class PluginSettingsParams {
  uuid: string = '';
  name: string = '';
  localFile: string = '';
}

/**
 * 第 4 条（2026-11-13 用户裁定）：行内插件图标 —— 有 iconUrl 走 ImageCache，取不到/失败一律回落
 * 应用图标 app.media.ic_app（等比、不变形、不留破损图占位）。
 * 为什么是独立 @Component 而不是本页 @Builder：每个图标要各自异步取图（@State pm），
 * 而 @Builder 形参是按值快照、状态变了不重渲染 ⇒ 图标会永远停在首帧（本仓踩过三次，
 * 同因先例 = pages/DetailPage.ets 的 DetailCover 与 view/common/MangaGridCard.ets）。
 * 回落机制选「load 失败回调」而不是 Image 的 .alt()：alt 只覆盖「加载中」那一帧，
 * 而我方走 ImageCache 拿 PixelMap，失败是 Promise reject（离线/404/解码失败/缓存未就绪），
 * 只有 catch 分支能接住 ⇒ pm 留空 = 直接渲染占位图。
 */
@Component
struct PluginIcon {
  /** 图标地址；空串 = 直接占位（手放的文件与老落盘数据都是空）。 */
  @Prop @Watch('onIconChanged') iconUrl: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  @State pm: image.PixelMap | undefined = undefined;
  /**
   * s21 黑区修法：与 @State pm 分开的**持有账本**（同 view/reader/ReaderView.ets 的 held/setShown 口径）。
   * 「清理图片缓存」与 LRU 淘汰都不该 release 仍在显示的那一张：被 release 后 Image 画整幅纯黑，
   * 不抛异常也不留日志（阅读器上的同款缺陷就是那条黑区）。
   */
  private held: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.setShown(undefined);
  }

  /** 挂载/摘除唯一入口：retain 在前、unpin 在后，再把值喂给 @State。 */
  private setShown(next: image.PixelMap | undefined): void {
    const prev: image.PixelMap | undefined = this.held;
    if (next !== undefined) {
      ImageCache.getInstance().retain(next);
      this.held = next;
    } else {
      this.held = undefined;
    }
    this.pm = next;
    if (prev !== undefined && prev !== next) {
      ImageCache.getInstance().unpin(prev);
    }
  }

  /** List 可能复用节点：地址变了必须清旧图重取，否则串图标（同 MangaGridCard.onCoverChanged）。 */
  onIconChanged(): void {
    this.setShown(undefined);
    this.load();
  }

  async load(): Promise<void> {
    // s15 第 3 条③：本进程内已经全档落空过的地址不再重试（List 复用节点会反复重取，见 iconDeadUrls）
    if (iconKnownDead(this.iconUrl)) {
      PluginIconDiag.skipped++;
      this.setShown(undefined);
      return;
    }
    // s15 第 3 条③：先过诊断入口 —— 空地址（noUrl）与非 URL（badUrl）都不发请求，
    // 返回空 host 就等于这一张不进 calls 口径，直接占位。
    const host: string = PluginIconDiag.begin(this.iconUrl);
    if (host.length === 0) {
      this.setShown(undefined);
      return;
    }
    // s14 第 4 条 R1（search-fix 报的残留，lead 认可后补）：ImageCache.init 只排在 DataBootstrap 里，
    // 而 init 没跑完时 loadPage 直接抛「图片缓存尚未初始化」⇒ 首帧图标会常年停在应用图标且不再回填。
    // 同因先例 = pages/SettingPage.ets:124 与 view/mine/MinePage.ets:137 的「先补跑 init 再统计」，
    // 这里同一口径：补跑一次（幂等，已就绪就立刻 resolve），失败也不弹错、让下面的 catch 走占位图。
    try {
      await ImageCache.getInstance().init(getContext(this) as common.UIAbilityContext);
    } catch (e) {
      Logger.w('[PluginManager] 补跑 ImageCache.init 失败（继续取图，失败则用占位）');
    }
    let lastTag: string = '';
    try {
      // PixelMap 由 ImageCache 持有，调用方不得 release（同 MangaGridCard 口径）
      const direct: image.PixelMap = await ImageCache.getInstance().load(this.iconUrl);
      this.setShown(direct);
      PluginIconDiag.ok(host, false);
      return;
    } catch (e) {
      lastTag = iconErrTag(e as Object);
      Logger.w('[PluginManager] 图标直链取图失败（尝试镜像）: ' + this.errOf(e as Object));
    }
    // s15 第 3 条③：直链挂了才走备选（成功路径上面已经 return，一行没动）。备选表见 iconAlternates：
    // 现役索引 23 条图标里 14 条挂在 raw.githubusercontent.com / cdn.jsdelivr.net，而这两个域名的
    // 连接层 RST 是包内 selftest 早就实测过的事实（:37-38），载荷自己取索引都走镜像、唯独图标没有。
    const alts: string[] = iconAlternates(this.iconUrl);
    if (alts.length > 0) {
      PluginIconDiag.noteMirrorTried();
      for (let i = 0; i < alts.length; i++) {
        try {
          const via: image.PixelMap = await ImageCache.getInstance().load(alts[i]);
          this.setShown(via);
          PluginIconDiag.ok(host, true);
          Logger.i('[PluginManager] 图标经镜像档取回: ' + iconHostOf(alts[i]));
          return;
        } catch (e2) {
          lastTag = iconErrTag(e2 as Object);
        }
      }
    }
    // 全档落空：占位图 + 一次失败出口（恒等式要求每次 begin 只有一个出口，见 failTry 注释），
    // 并记进本进程的失败档 ⇒ 同一地址滚动重进不再重复烧请求
    PluginIconDiag.failTry(host, lastTag);
    iconMarkDead(this.iconUrl);
    this.setShown(undefined);
  }

  private errOf(e: Object): string {
    return e instanceof Error ? (e as Error).message : String(e);
  }

  build() {
    // 固定 32x32 方块：有图/无图占位完全同宽同高 ⇒ 标题不会因有无图标而错位
    Stack() {
      if (this.pm !== undefined) {
        Image(this.pm)
          .width(PLUGIN_ICON_SIZE)
          .height(PLUGIN_ICON_SIZE)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      } else {
        Image($r('app.media.ic_app'))
          .width(PLUGIN_ICON_SIZE)
          .height(PLUGIN_ICON_SIZE)
          .objectFit(ImageFit.Contain)
          .draggable(false)
      }
    }
    .width(PLUGIN_ICON_SIZE)
    .height(PLUGIN_ICON_SIZE)
    .borderRadius(6)
    .clip(true)
    .backgroundColor(Theme.coverColor(this.isDark))
    .margin({ right: 10 })
  }
}

@Component
export struct PluginManagerView {
  @StorageProp('isDark') isDark: boolean = false;
  /**
   * 状态栏高度（SafeArea.ets 写入）。bindContentCover 是全屏层、**不继承页面安全区**，
   * s5e 真机截图「插件商店」标题与状态栏图标叠在一起就是这个原因 ⇒ 自己加 top padding。
   */
  @StorageProp('topSafeHeight') topSafe: number = 0;
  @State rows: PluginRow[] = [];
  @State busy: boolean = false;
  @State lastError: string = '';
  /** 商店弹层状态。 */
  @State shopOpen: boolean = false;
  @State shopItems: ShopItem[] = [];
  @State shopVia: string = '';
  @State shopLoading: boolean = false;
  /** 检查更新进行中（判据 ③：行级 latest 先置空）。手动与自动共用这一枚 = 互斥闸门。 */
  @State checking: boolean = false;
  /** 第 6 条：checking 那一趟是不是「进页自动跑的」⇒ 静默档不显示「检查中…」，按钮文案保持原样。 */
  @State autoSilent: boolean = false;
  /** 第 7 条：本次自动装载汇总（空串 = 不显示）。自动装载无按钮，必须给一行可见证据。 */
  @State autoNote: string = '';

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /**
   * 任务 A①：图源注册表变更后 bump epoch ⇒ 发现页/搜索页 chip 条即时同步。
   * 只在装载/删除/更新/开关四个动作把注册表动作做完后各调一次；同值重复 bump 无副作用
   * （接收端 onSourceEpoch 自己比对 id 序列去抖）。
   */
  private bumpSourceEpoch(): void {
    const n: number = (AppStorage.get<number>('pluginSourceEpoch') ?? 0) + 1;
    AppStorage.setOrCreate<number>('pluginSourceEpoch', n);
  }

  /**
   * 行「设置」入口：只有 bundle 已在内存才能拉 getSettingsBundle。
   * 第 7 条改造：不再有「先装载」这一步 —— 不在内存就地补装（loadOne 幂等，已在内存是 no-op，
   * 不会重复 loadBundle 洗掉插件内存态），补装失败才提示。绝不 push 空参数。
   */
  async openSettings(row: PluginRow): Promise<void> {
    if (row.state === 'missing' || row.localFile.length === 0) {
      this.toast('该插件没有本地文件，请先重新下载');
      return;
    }
    const uuid: string = row.uuid.length > 0 ? row.uuid : deriveLocalUuid(row.localFile);
    if (!(await PluginAutoLoader.loadOne(this.ctx(), uuid, row.localFile, row.title))) {
      this.toast('插件装载失败，读不到设置项（hilog 有原因）');
      return;
    }
    row.loaded = true;
    const p: PluginSettingsParams = new PluginSettingsParams();
    p.uuid = uuid;
    p.name = row.title;
    p.localFile = row.localFile;
    router.pushUrl({ url: 'pages/PluginSettingsPage', params: p })
      .catch((err: Error): void => {
        this.toast('打开设置页失败: ' + this.errBrief(err));
      });
  }

  /**
   * 已安装行的本地文件名（商店卡片「已安装」角标 + 按钮文案「重新下载」用，找不到返回空串）。
   * 判据：任一行的 indexUuid === 该行 uuid 且状态不是 missing ⇒ 本地有可用文件。
   */
  private localFileOf(uuid: string): string {
    for (let i = 0; i < this.rows.length; i++) {
      if (this.rows[i].indexUuid === uuid && this.rows[i].state !== 'missing') {
        return this.rows[i].localFile;
      }
    }
    return '';
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg.length > 80 ? msg.slice(0, 80) : msg });
  }

  /**
   * 第 3 条（2026-11-13 用户裁定）：任何异常原文上屏前都过这里。
   * 引擎/Kit 的消息常带沙箱绝对路径（/data/storage/el2/base/... 与 context.filesDir 原串），
   * 这应用要给别人用 ⇒ 屏上只留「首行 + 去掉路径」的形态，完整原文写 hilog（Logger.e）。
   */
  private errBrief(e: Object): string {
    const full: string = e instanceof Error ? (e as Error).message : String(e);
    Logger.e('[PluginManager] ' + full);
    return this.maskPaths(full.split('\n')[0]);
  }

  /**
   * 去掉消息里的绝对路径段（第 3 条的第二道闸，errBrief 与 bundle 回包的 err 都过这里）。
   * 空格切词后逐词判三种形态：词首（剥掉引号、括号、等号之后）是斜杠；词里含本机 filesDir；
   * 词里含沙箱根前缀。第三种是兜底 —— 引擎有时把路径粘在 key 后面或夹在引号里，只按词首斜杠判会漏。
   */
  private maskPaths(msg: string): string {
    let root: string = '';
    try {
      root = this.ctx().filesDir;
    } catch (e) {
      // 取不到 context 就只做「斜杠开头」与「沙箱根前缀」这两档过滤
    }
    const parts: string[] = msg.split(' ');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p: string = parts[i];
      if (this.looksLikePathWord(p, root)) {
        out.push('…');
        continue;
      }
      out.push(p);
    }
    return out.join(' ');
  }

  /** 单个词是否需要打码：粘在 key 后面、被引号包住、带盘符的形态都算。 */
  private looksLikePathWord(p: string, root: string): boolean {
    if (p.length === 0) {
      return false;
    }
    if (root.length > 0 && p.indexOf(root) >= 0) {
      return true;
    }
    if (p.indexOf('/data/storage/') >= 0 || p.indexOf('/data/app/') >= 0) {
      return true;
    }
    let i: number = 0;
    while (i < p.length) {
      const c: string = p.charAt(i);
      // 花括号用 charCode 比，避免在本文件里多出一枚字面左花括号（自检判据含花括号配平）
      if (c === '\'' || c === '"' || c === '(' || c === '[' || c === '=' || c === ':' || p.charCodeAt(i) === 123) {
        i++;
        continue;
      }
      break;
    }
    const t: string = p.slice(i);
    if (t.length > 1 && t.charAt(0) === '/') {
      return true;
    }
    // 调试期日志里偶发的带盘符路径（宿主侧报错），一并挡掉
    return t.length > 2 && t.charAt(1) === ':' && (t.charAt(2) === '\\' || t.charAt(2) === '/');
  }

  aboutToAppear(): void {
    // 第 6 条（增强）：refresh 之后再决定要不要静默补一次检查更新 —— rows 是 refresh 里 join 出来的，
    // 没 join 完就查等于拿空表白跑一趟（还会把节流时钟白白推进）。
    this.refresh()
      .then((): void => {
        // s15 第 3 条②：先静默补老数据的图标（闸门在方法内），再决定要不要静默检查更新
        this.warmIconsFromIndex()
          .catch((e2: Object): void => {
            Logger.w('[PluginManager] 静默补图标未完成: ' + this.errBrief(e2));
          });
        this.autoCheckOnEnter();
      })
      .catch((e: Object): void => {
        Logger.w('[PluginManager] 进页刷新未完成: ' + (e instanceof Error ? (e as Error).message : String(e)));
      });
    this.ensureMgr();
  }

  /**
   * 第 6 条（增强）：进页静默检查 —— 名单本身是运行时联网取上游的（五档回退，内嵌 SEED 只断网兜底），
   * 「跟随上游」早就成立，只是原先必须进商店页或点按钮才拉；这一档补的就是「什么都不点也会跟随」。
   * 三道约束：节流（AUTO_CHECK_*）+ 互斥（复用 checking 闸门）+ 静默（silent=true 不写任何 toast）。
   */
  private autoCheckOnEnter(): void {
    if (!AUTO_CHECK_ENABLED) {
      return;
    }
    const now: number = Date.now();
    if (!autoCheckAllowed(now)) {
      Logger.d('[PluginManager] 静默检查跳过（节流中）');
      return;
    }
    this.checkUpdatesAll(true);
  }

  /** scanDir ⊕ 清单 join。scanDir 失败（含 no-storage-root）⇒ 只显清单态并挂 lastError。 */
  async refresh(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    this.lastError = '';
    let files: ScanItem[] = [];
    try {
      const raw: string = await pluginScanDir('plugins');
      const root: ESObject = jparse(raw);
      if (Array.isArray(root)) {
        const arr: ESObject[] = root as ESObject[];
        for (let i = 0; i < arr.length; i++) {
          const it: ScanItem = new ScanItem();
          it.name = jstr(arr[i], 'name', '');
          it.bytes = jnum(arr[i], 'bytes', 0);
          it.mtimeMs = jnum(arr[i], 'mtimeMs', 0);
          if (it.name.length > 0) {
            files.push(it);
          }
        }
      }
    } catch (e) {
      // 第 3 条：这里就洗掉路径 ⇒ 后面 toast 与页面上那行提示都只会拿到无路径形态
      this.lastError = this.errBrief(e as Object);
    }
    let recs: PluginRecord[] = await PluginStore.loadAll(this.ctx());
    const shopMap: ShopMapEntry[] = await PluginStore.loadShopMap(this.ctx());
    const mapEntry: (f: string) => ShopMapEntry | null = (f: string): ShopMapEntry | null => {
      for (let m = 0; m < shopMap.length; m++) {
        if (shopMap[m].file === f) {
          return shopMap[m];
        }
      }
      return null;
    };
    const mapIdx: (f: string) => string = (f: string): string => {
      const e: ShopMapEntry | null = mapEntry(f);
      return e === null ? '' : e.indexUuid;
    };
    // s13 第 1 条：商店索引自带的中文名（getInfo 超时时的唯一名字来源）
    const mapName: (f: string) => string = (f: string): string => {
      const e: ShopMapEntry | null = mapEntry(f);
      return e === null ? '' : e.name;
    };
    const mapVer: (f: string) => string = (f: string): string => {
      const e: ShopMapEntry | null = mapEntry(f);
      return e === null ? '' : e.version;
    };
    // s14 第 4 条：图标地址同样只有商店映射里有（手放的文件恒空 ⇒ 走占位图）。
    // s15 第 3 条②：这一档**是老数据兼容**（按落盘文件名查）—— s13 之前落盘的行没有 iconUrl 列，
    // 光靠它图标只能等到下次更新或重装才回来。新数据走下面按 indexUuid 的现场关联，两档互补。
    const mapIcon: (f: string) => string = (f: string): string => {
      const e: ShopMapEntry | null = mapEntry(f);
      return e === null ? '' : e.iconUrl;
    };
    // ── 第 7 条自动装载（旧「打开」按钮的全部职责搬到这里，用户不再需要点任何东西）──
    // ① 目录里有文件但清单没有 ⇒ 自动登记 + 自动装载（商店下载完、或用户自己丢文件进来）。
    //    采纳成功就重读清单，行才能以「已登记」态出现；unregistered 退化成「采纳失败」的兜底态。
    let adopted: number = 0;
    for (let k = 0; k < files.length; k++) {
      let claimed: boolean = false;
      for (let i = 0; i < recs.length; i++) {
        if (recs[i].localFile === files[k].name) {
          claimed = true;
          break;
        }
      }
      if (claimed) {
        continue;
      }
      const uid: string = await PluginAutoLoader.adoptAndLoad(this.ctx(), files[k].name, mapIdx(files[k].name),
        mapName(files[k].name), mapVer(files[k].name));
      if (uid.length > 0) {
        adopted++;
      }
    }
    if (adopted > 0) {
      recs = await PluginStore.loadAll(this.ctx());
    }
    // ② 清单里「启用 + 文件在 + 不在内存」的全部补装（冷启动、以及上次装载失败的那些）。
    const outcome: LoadOutcome = await PluginAutoLoader.autoLoadAll(this.ctx());
    this.autoNote = outcome.expected > 0
      ? ('已自动装载 ' + outcome.loaded + '/' + outcome.expected + (outcome.failed > 0 ? ' · 失败 ' + outcome.failed : ''))
      : '';
    // loaded 用 bundleList 实填（历史实现里 refresh 从不填 loaded，只有点过「打开」才 true ⇒ 灰态误导）。
    const inMem: string[] = await PluginAutoLoader.memoryNames();
    const memHit: (u: string) => boolean = (u: string): boolean => inMem.indexOf(u) >= 0;
    const out: PluginRow[] = [];
    for (let i = 0; i < recs.length; i++) {
      const r: PluginRecord = recs[i];
      const row: PluginRow = new PluginRow();
      row.uuid = r.uuid;
      // 标题三级：清单名 → 商店索引名（getInfo 超时/老数据没名字时救场）→ uuid
      const shopName: string = mapName(r.localFile);
      row.title = r.name.length > 0 ? r.name : (shopName.length > 0 ? shopName : r.uuid);
      row.version = r.version;
      row.localFile = r.localFile;
      row.enabled = r.enabled;
      let found: boolean = false;
      for (let k = 0; k < files.length; k++) {
        if (files[k].name === r.localFile) {
          row.bytes = files[k].bytes;
          found = true;
          break;
        }
      }
      row.state = found ? 'ok' : 'missing';
      row.indexUuid = r.indexUuid.length > 0 ? r.indexUuid
        : (found ? mapIdx(r.localFile) : '');
      row.iconUrl = mapIcon(r.localFile);
      row.loaded = r.uuid.length > 0 && memHit(r.uuid);
      out.push(row);
    }
    for (let k = 0; k < files.length; k++) {
      let claimed: boolean = false;
      for (let i = 0; i < recs.length; i++) {
        if (recs[i].localFile === files[k].name) {
          claimed = true;
          break;
        }
      }
      if (!claimed) {
        const row: PluginRow = new PluginRow();
        row.uuid = '';
        // 第 3 条：这里**不再**拿落盘文件名顶上屏（手放的文件登记失败 / 非插件文件时商店名也是空）。
        // 中性文案只在显示层给（见 rowTitle()），不写进 title —— 否则「更新」流程会把它当插件名
        // 存进商店映射，反过来污染以后所有行的标题。文件名逐条进 hilog 供排障对号。
        row.title = mapName(files[k].name);
        row.localFile = files[k].name;
        row.bytes = files[k].bytes;
        row.state = 'unregistered';
        row.indexUuid = mapIdx(files[k].name);
        row.iconUrl = mapIcon(files[k].name);
        // 文件名只进 hilog（排障要能对上号），屏上给中性文案
        Logger.i('[PluginManager] 未登记文件: ' + files[k].name + ' bytes=' + files[k].bytes);
        out.push(row);
      }
    }
    // s15 第 3 条②：图标改按 indexUuid 现场关联商店索引（进程内即时档 indexIconById），
    // 上面按 localFile 查的那一档退化成老数据兼容。只填「行上为空而索引里有」的情形 ⇒ 已有的值
    // 不会被索引一次抖动洗掉；indexUuid 为空的行（手放的文件、自动登记出来的行）压根不查
    // ⇒ 预置插件不会被误关联成商店件（lead 约束）。
    const iconPatched: PluginRow[] = [];
    for (let i = 0; i < out.length; i++) {
      const pr: PluginRow = out[i];
      if (pr.iconUrl.length === 0) {
        const fromIndex: string = indexIconOf(pr.indexUuid);
        if (fromIndex.length > 0) {
          pr.iconUrl = fromIndex;
          iconPatched.push(pr);
        }
      }
    }
    this.rows = out;
    this.busy = false;
    if (iconPatched.length > 0) {
      await this.persistIconBackfill(iconPatched);
    }
    // s39 需求 1：这里原来还弹一枚 toast（'插件目录读取失败：' + lastError），与 build 里
    // :1442 那行常驻红字是**同一句话在同一屏上出现两次**（一次飘一次常驻）。常驻那行是更该留的
    // 形态（不转瞬即逝、可逐字读），所以删 toast，只留常驻行。lastError 本身照旧写、照旧清。
  }

  /**
   * s15 第 3 条②：把即时档（indexUuid → iconUrl）里已有的图标补到当前行上，只填空格。
   * rows 是 @State 数组、元素属性改动不触发重渲染 ⇒ 改过就整表重新赋值（同 checkUpdatesAll 口径）。
   */
  private async applyIndexIconsToRows(): Promise<void> {
    const patched: PluginRow[] = [];
    for (let i = 0; i < this.rows.length; i++) {
      const r: PluginRow = this.rows[i];
      if (r.iconUrl.length === 0) {
        const u: string = indexIconOf(r.indexUuid);
        if (u.length > 0) {
          r.iconUrl = u;
          patched.push(r);
        }
      }
    }
    if (patched.length === 0) {
      return;
    }
    this.rows = this.rows.slice();
    await this.persistIconBackfill(patched);
  }

  /**
   * s15 第 3 条②：把当场关联到的图标回填进落盘的商店映射 ⇒ 下次冷启动（没打开过商店、即时档是空的）
   * 也能直接显示图标。三条硬约束：
   * ① 只改**映射里已存在**且 iconUrl 为空的条目，绝不新建条目（否则预置/手放的插件会被写成商店件，
   *    lead 定的约束）；② name、version 一律沿用条目原值 ⇒ 整次写入只填 iconUrl 一列；
   * ③ 写之前**逐行重读一次**映射，不复用 refresh 开头那份快照 —— saveShopMap 是「整表读出来改完再整体
   *    写回」，拿旧快照写会把同一时刻别处（下载/更新）刚落的 name、version 洗回旧值。重读把这条窗口
   *    压到一次 await 之内；回填只对「老数据且缺图标」的行触发、每进程一次，多读几次代价可忽略。
   *    另加一道避让：每写一条前先看 busy —— 下载/更新正拿着这条映射时直接收手（它们写进去的 name、
   *    version、iconUrl 才是权威值，我这档只是补老数据，让路没有任何损失）。
   */
  private async persistIconBackfill(patched: PluginRow[]): Promise<void> {
    let n: number = 0;
    for (let i = 0; i < patched.length; i++) {
      const row: PluginRow = patched[i];
      if (row.indexUuid.length === 0 || row.iconUrl.length === 0) {
        continue;
      }
      if (this.busy) {
        Logger.i('[PluginManager] 图标回填让路（有下载或更新在写映射），本次收手');
        return;
      }
      let fresh: ShopMapEntry[] = [];
      try {
        fresh = await PluginStore.loadShopMap(this.ctx());
      } catch (err) {
        Logger.w('[PluginManager] 图标回填前重读映射失败（放弃回填）: ' + this.errBrief(err as Object));
        return;
      }
      for (let m = 0; m < fresh.length; m++) {
        const e: ShopMapEntry = fresh[m];
        if (e.indexUuid !== row.indexUuid || e.iconUrl.length > 0) {
          continue;
        }
        try {
          await PluginStore.saveShopMap(this.ctx(), e.file, e.indexUuid, e.name, e.version, row.iconUrl);
          n++;
        } catch (err) {
          // 落盘失败不影响本次显示（行上已经有图标了），只留一条 hilog
          Logger.w('[PluginManager] 图标回填落盘失败（不影响本次显示）: ' + this.errBrief(err as Object));
          return;
        }
        break;
      }
    }
    if (n > 0) {
      Logger.i('[PluginManager] 图标回填落盘 ' + n + ' 条（下次冷启动可直接显示）');
    }
  }

  /**
   * 索引 items → ShopItem（openShop 与静默补图标共用一份解析；uuid 为空的条目直接丢，
   * 与 s14 之前的逐字段写法逐字同形，只是抽出来避免两处漂移）。
   */
  private parseShopItems(items: ESObject[]): ShopItem[] {
    const out: ShopItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const it: ShopItem = new ShopItem();
      it.uuid = jstr(items[i], 'uuid', '');
      it.name = jstr(items[i], 'name', '');
      it.version = jstr(items[i], 'version', '');
      it.describe = jstr(items[i], 'describe', '');
      it.repo = jstr(items[i], 'repo', '');
      it.home = jstr(items[i], 'home', '');
      it.iconUrl = jstr(items[i], 'iconUrl', '');
      if (it.uuid.length > 0) {
        out.push(it);
      }
    }
    return out;
  }

  /**
   * s15 第 3 条②：s13 之前落盘的老行没有 iconUrl 列，而进程内即时档冷启动时是空的 ⇒ 老数据要等
   * 用户点开商店才认得回图标。这里在进页刷新之后**静默**补一次 fetchIndex（不开弹层、不碰 shopItems）,
   * 把索引里的图标关联到行上并回填落盘，一次之后永久好。三道闸：
   * ① 本次进程只跑一次（iconWarmTried）⇒ 手放文件那种「永远关联不上」的形态不会反复发请求；
   * ② 只有确实有「带 indexUuid 且缺图标」的行才跑 ⇒ 新数据一次都不花；
   * ③ 载荷内部有 indexCache 模块态（同一次进页的静默检查更新已经 fetchIndex 过 ⇒ 常态是内存命中、零网络）。
   */
  private async warmIconsFromIndex(): Promise<void> {
    if (iconWarmTried) {
      return;
    }
    let need: boolean = false;
    for (let i = 0; i < this.rows.length; i++) {
      const r: PluginRow = this.rows[i];
      if (r.iconUrl.length === 0 && r.indexUuid.length > 0) {
        need = true;
        break;
      }
    }
    if (!need) {
      return;
    }
    iconWarmTried = true;
    if (!(await this.ensureMgr())) {
      return;
    }
    try {
      const raw: string = await bundleCall(MGR_NAME, 'fetchIndex', '[]');
      rememberIndexIcons(this.parseShopItems(jarr(jparse(raw), 'items')));
      await this.applyIndexIconsToRows();
    } catch (e) {
      // 静默档：只进 hilog，不打扰（下一次进页还会再试，索引恢复后老数据自己就好了）
      iconWarmTried = false;
      Logger.w('[PluginManager] 静默补图标索引失败: ' + this.errBrief(e as Object));
    }
  }

  private absOf(localFile: string): string {
    return this.ctx().filesDir + '/plugins/' + localFile;
  }

  /** 删除：先卸内存 → 再删文件 → 最后清桶（顺序硬约束；missing 态文件本就没有，跳过删文件）。 */
  async deleteRow(row: PluginRow): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      if (row.uuid.length > 0) {
        try {
          await bundleUnload(row.uuid);
        } catch (e) {
          // 未装载时 unload 返回 false/抛错都可接受，继续删
        }
      }
      if (row.state !== 'missing') {
        const r: string = await pluginRemoveFile(this.absOf(row.localFile));
        if (r !== 'removed' && r !== 'absent') {
          throw new Error('pluginRemoveFile returned "' + r + '"');
        }
      }
      if (row.uuid.length > 0) {
        await PluginStore.remove(this.ctx(), row.uuid);
      }
      // G1 联动②：删除即注销图源（uuid 空则 no-op；引擎 bundle 上面已 unload）。
      PluginSourceRegistry.unregisterOne(row.uuid);
      this.bumpSourceEpoch();
      this.rows = [];
      this.busy = false;
      await this.refresh();
      // 第 3 条：原来弹的是落盘文件名（含 uuid 前段）⇒ 改成显示名
      this.toast('已删除 ' + (row.title.length > 0 ? row.title : '插件'));
    } catch (e) {
      this.busy = false;
      this.toast('删除失败: ' + this.errBrief(e as Object));
    }
  }

  /**
   * lazy 装载商店 bundle：rawfile 读出源码 → bundleLoad('pluginMgr', src)。
   * bundleList 已含则跳过 —— 重复 loadBundle 是整体替换语义，会洗掉 bundle 内 indexCache
   * 模块态（同 loadRow 防洗态规则）。失败 toast 原文，不阻塞原三态列表。
   */
  async ensureMgr(): Promise<boolean> {
    try {
      const lst: string[] = await bundleList();
      for (let i = 0; i < lst.length; i++) {
        if (lst[i] === MGR_NAME) {
          return true;
        }
      }
    } catch (e) {
      // bundleList 失败 ⇒ 按未装载处理，继续尝试装载
    }
    try {
      const rm = getContext(this).resourceManager;
      const u8: Uint8Array = await rm.getRawFileContent('plugins/plugin_mgr.bundle.cjs');
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = dec.decodeToString(u8);
      if (text.length === 0) {
        // 第 3 条：原文案带着包内资源路径，属实现细节 ⇒ 改成中文描述
        throw new Error('内置的商店模块内容为空');
      }
      const ret: string = await bundleLoad(MGR_NAME, text);
      if (ret !== 'ok') {
        throw new Error('bundleLoad returned "' + ret + '"');
      }
      return true;
    } catch (e) {
      this.toast('商店模块装载失败: ' + this.errBrief(e as Object));
      return false;
    }
  }

  /** 商店弹层：fetchIndex（bundle 模块态缓存 ⇒ 重开秒回；force=["1"] 强刷绕缓存）。 */
  async openShop(force: boolean): Promise<void> {
    this.shopOpen = true;
    if (this.shopLoading) {
      return;
    }
    if (!(await this.ensureMgr())) {
      return;
    }
    this.shopLoading = true;
    try {
      const raw: string = await bundleCall(MGR_NAME, 'fetchIndex', force ? '["1"]' : '[]');
      const o: ESObject = jparse(raw);
      this.shopVia = jstr(o, 'via', '');
      this.shopItems = this.parseShopItems(jarr(o, 'items'));
      // s15 第 3 条②：索引是图标地址的唯一来源 ⇒ 解析成功就立刻记进进程内即时档，并顺手把已装列表
      // 里缺图标的行补上（用户不必退出再进商店页才看得到图标），能落盘的一并回填。
      rememberIndexIcons(this.shopItems);
      await this.applyIndexIconsToRows();
      const ie: string = jstr(o, 'err', '');
      if (ie.length > 0) {
        this.toast('索引走降级(' + this.shopVia + '): ' + this.maskPaths(ie));
      }
    } catch (e) {
      this.toast('索引读取失败: ' + this.errBrief(e as Object));
    }
    this.shopLoading = false;
  }

  /**
   * 商店下载（判据②）：installLatest 只下载+落盘；refresh 里自动登记 + 自动装载（第 7 条：
   * 用户点「下载」之后不需要再点任何按钮）。
   */
  async installShopItem(it: ShopItem): Promise<void> {
    if (this.busy || it.downloading) {
      return;
    }
    if (!(await this.ensureMgr())) {
      return;
    }
    it.downloading = true;
    this.shopItems = this.shopItems.slice();
    try {
      const raw: string = await bundleCall(MGR_NAME, 'installLatest', JSON.stringify([it.uuid]));
      const o: ESObject = jparse(raw);
      if (jbool(o, 'ok', false)) {
        const fname: string = this.baseName(jstr(o, 'savedTo', ''));
        if (fname.length > 0) {
          // s14 第 4 条：图标地址只有此刻在手里（索引条目），不落盘以后就没了
          await PluginStore.saveShopMap(this.ctx(), fname, it.uuid,
            jstr(o, 'name', it.name), jstr(o, 'version', it.version), it.iconUrl);
        }
        this.rows = [];
        await this.refresh();
        this.toast('已下载 ' + jstr(o, 'name', it.name) + ' v' + jstr(o, 'version', '')
          + '（' + Math.round(jnum(o, 'bytes', 0) / 1024) + 'KB via ' + jstr(o, 'via', '') + '），已自动装载');
      } else {
        this.toast('下载失败: ' + this.maskPaths(jstr(o, 'err', 'unknown')));
      }
    } catch (e) {
      this.toast('下载失败: ' + this.errBrief(e as Object));
    }
    it.downloading = false;
    this.shopItems = this.shopItems.slice();
  }

  /**
   * 检查更新（判据③）：只送有 indexUuid 的行；args 双层 JSON（数组里放一个字符串）。
   * s14 第 6 条：silent=true 是「进页自动跑」那一档 = 同一条链路、同一道闸门、同一套行级更新逻辑，
   * 差别只有三处：不写 toast（只进 hilog）、不显示「检查中…」、给节流记账（成功推进时刻、失败封当天）。
   * 收尾统一放 finally：中途任一处 return 都不能把 checking 闸门留在 true（否则按钮永久灰）。
   */
  async checkUpdatesAll(silent: boolean = false): Promise<void> {
    if (this.busy || this.checking) {
      return;
    }
    this.autoSilent = silent;
    this.checking = true;
    let ok: boolean = false;
    try {
      if (!(await this.ensureMgr())) {
        // ensureMgr 失败时它自己已经弹过原因，这里只补一条 hilog，不再重复 toast
        Logger.w('[PluginManager] 检查更新中止：商店模块未装载（silent=' + silent + '）');
        return;
      }
      const entries: ChkEntry[] = [];
      for (let i = 0; i < this.rows.length; i++) {
        const r: PluginRow = this.rows[i];
        if (r.indexUuid.length > 0 && r.state !== 'missing') {
          const ce: ChkEntry = new ChkEntry();
          ce.uuid = r.indexUuid;
          ce.version = r.version;
          entries.push(ce);
        }
      }
      if (entries.length === 0) {
        // 没有要查的对象 = 这一趟压根不需要网络，算成功（否则同一天里每次进页都会再白跑一遍）
        ok = true;
        this.notify(silent, '没有可检查的商店插件（先经商店下载并打开登记）');
        return;
      }
      const raw: string = await bundleCall(MGR_NAME, 'checkUpdates',
        JSON.stringify([JSON.stringify(entries)]));
      const o: ESObject = jparse(raw);
      const results: ESObject[] = jarr(o, 'results');
      let upd: number = 0;
      for (let k = 0; k < results.length; k++) {
        const uu: string = jstr(results[k], 'uuid', '');
        for (let i = 0; i < this.rows.length; i++) {
          if (this.rows[i].indexUuid === uu) {
            this.rows[i].latest = jstr(results[k], 'latest', '');
            this.rows[i].hasUpdate = jbool(results[k], 'hasUpdate', false);
            if (this.rows[i].hasUpdate) {
              upd++;
            }
          }
        }
      }
      this.rows = this.rows.slice();
      ok = true;
      this.notify(silent, upd > 0 ? ('发现 ' + upd + ' 个可更新') : ('无可用更新（共查 ' + results.length + ' 项）'));
    } catch (e) {
      if (silent) {
        // 只留一条 hilog（errBrief 自己会 Logger.e，这里不能再叠一层）
        Logger.w('[PluginManager] 静默检查更新失败: ' + this.maskPaths((e instanceof Error ? (e as Error).message : String(e)).split('\n')[0]));
      } else {
        this.toast('检查更新失败: ' + this.errBrief(e as Object));
      }
    } finally {
      this.checking = false;
      this.autoSilent = false;
      // 手动档同样给节流记账：用户刚点过检查，4 小时内进页就不必再自动跑一遍
      autoCheckMark(Date.now(), ok);
    }
  }

  /** 第 3 条：行标题的显示档（数据里可能为空，屏上给中性文案，绝不回落到文件名）。 */
  private rowTitle(row: PluginRow): string {
    return row.title.length > 0 ? row.title : '未识别的插件文件（自动登记失败）';
  }

  /** 第 6 条：同一句话的两档出口 —— 手动档上屏，静默档只进 hilog。 */
  private notify(silent: boolean, msg: string): void {
    if (silent) {
      Logger.i('[PluginManager] 静默检查: ' + msg);
      return;
    }
    this.toast(msg);
  }

  /** 更新（判据③）：installLatest 落盘不自动装载；桶行存在则 upsert version/sha256/localFile/indexUuid。 */
  async updateRow(row: PluginRow): Promise<void> {
    if (this.busy || row.indexUuid.length === 0) {
      return;
    }
    if (!(await this.ensureMgr())) {
      return;
    }
    this.busy = true;
    try {
      const raw: string = await bundleCall(MGR_NAME, 'installLatest', JSON.stringify([row.indexUuid]));
      const o: ESObject = jparse(raw);
      if (!jbool(o, 'ok', false)) {
        throw new Error(jstr(o, 'err', 'unknown'));
      }
      const fname: string = this.baseName(jstr(o, 'savedTo', ''));
      if (fname.length > 0) {
        // s14 第 4 条：更新走的不是索引对象而是行数据 ⇒ 图标沿用行上那份（老数据为空则维持占位）
        await PluginStore.saveShopMap(this.ctx(), fname, row.indexUuid,
          row.title, jstr(o, 'version', ''), row.iconUrl);
      }
      if (row.uuid.length > 0 && fname.length > 0) {
        const rec: PluginRecord = new PluginRecord();
        rec.uuid = row.uuid;
        rec.name = row.title;
        rec.localFile = fname;
        rec.version = jstr(o, 'version', '');
        rec.sourceUrl = 'github-release:' + jstr(o, 'asset', '');
        rec.sha256 = jstr(o, 'sha256', '');
        rec.enabled = row.enabled;
        rec.indexUuid = row.indexUuid;
        await PluginStore.save(this.ctx(), rec);
      }
      let inMem: boolean = false;
      if (row.uuid.length > 0) {
        try {
          const lst: string[] = await bundleList();
          for (let i = 0; i < lst.length; i++) {
            if (lst[i] === row.uuid) {
              inMem = true;
            }
          }
        } catch (e) {
          // bundleList 失败按未装载处理
        }
      }
      // G1 联动③：更新落盘后重载图源（内存里有 bundle ⇒ bundleLoadFromPath 覆盖装新文件；
      // 不在内存 ⇒ 懒装载下次自然取新文件）。失败仅提示，不影响"已落盘"事实。
      let reloaded: boolean = false;
      if (inMem) {
        reloaded = await PluginSourceRegistry.reloadOne(this.ctx(), row.uuid);
      }
      // 任务 A①：更新/重载完成后同样 bump（四回调各调一次；
      // 接收端按 id 序列去抖，集合没变时 bump 不会引发多余刷新）。
      this.bumpSourceEpoch();
      this.rows = [];
      this.busy = false;
      await this.refresh();
      if (!inMem) {
        this.toast('已更新到 v' + jstr(o, 'version', '') + '（refresh 里自动装载）');
      } else if (reloaded) {
        this.toast('更新完成并已重载图源');
      } else {
        this.toast('更新已落盘，图源重载失败，下次自动装载生效');
      }
    } catch (e) {
      this.busy = false;
      this.toast('更新失败: ' + this.errBrief(e as Object));
    }
  }

  private baseName(p: string): string {
    const parts: string[] = p.split('/');
    return parts.length > 0 ? parts[parts.length - 1] : '';
  }

  /**
   * 启用/停用开关（第 7 条：这是行内唯一的装载控制）。启用 = 立刻真装载 + 注册图源；
   * 停用 = 注销图源 + 顺手卸载。开关值先落盘（PluginStore.setEnabled）⇒ 重启后保留上次状态。
   */
  async toggleRow(row: PluginRow): Promise<void> {
    if (this.busy || row.state !== 'ok' || row.uuid.length === 0) {
      return;
    }
    const next: boolean = !row.enabled;
    try {
      // 先落盘再改视图：写失败时 UI 保持原状，不出现"显示已停用但清单还是启用"。
      await PluginStore.setEnabled(this.ctx(), row.uuid, next);
      row.enabled = next;
      // G1 联动④ + 第 7 条：启用 = 立刻真装载（loadOne 内含 registerOne，chip 即时出现；
      // 不再是「懒装载」—— 懒装载下开关打开但图源第一次取数才装载，第一次搜索会明显卡一下）。
      // 停用 = 注销图源（chip 消失）+ 顺手卸载省内存，见下面 bundleUnload。
      if (next) {
        if (await PluginAutoLoader.loadOne(this.ctx(), row.uuid, row.localFile, row.title)) {
          row.loaded = true;
        } else {
          this.toast('已启用，但自动装载失败（hilog 有原因）');
        }
      } else {
        PluginSourceRegistry.unregisterOne(row.uuid);
      }
      this.bumpSourceEpoch();
      if (!next && row.loaded) {
        try {
          await bundleUnload(row.uuid);
        } catch (e) {
          // 未装载时 unload 抛错可接受
        }
        row.loaded = false;
      }
      this.rows = this.rows.slice();
    } catch (e) {
      this.toast('开关写入失败: ' + this.errBrief(e as Object));
    }
  }

  build() {
    Column() {
      Row() {
        // 第 3 条：原来这行是「插件目录 filesDir/plugins（清单 N 项）」= 直接把沙箱目录打在屏上
        Text('插件清单 ' + this.rows.length + ' 项')
          .fontSize(12)
          .fontColor(Theme.text2(this.isDark))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Button(this.busy ? '处理中…' : '刷新')
          .fontSize(12)
          .height(28)
          .backgroundColor(Theme.brand)
          .enabled(!this.busy)
          .onClick((): void => {
            this.refresh();
          })
        Button('商店')
          .fontSize(12)
          .height(28)
          .backgroundColor(Theme.brand)
          .enabled(!this.busy)
          .margin({ left: 6 })
          .onClick((): void => {
            this.openShop(false);
          })
        // 第 6 条：静默档（进页自动跑）不改文案，只有用户自己点的才显示「检查中…」；
        // 灰态照旧 = 有一趟在飞就是灰的，这是互斥闸门的真实状态，不给「点了没反应」的死按钮。
        Button(this.checking && !this.autoSilent ? '检查中…' : '检查更新')
          .fontSize(12)
          .height(28)
          .backgroundColor(Theme.fill)
          .enabled(!this.busy && !this.checking)
          .margin({ left: 6 })
          .onClick((): void => {
            this.checkUpdatesAll();
          })
      }
      .width('100%')
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 8, bottom: 8 })

      if (this.lastError.length > 0) {
        Text('插件目录读取失败：' + this.lastError)
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(Theme.error)
          .width('100%')
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding, bottom: 6 })
      }

      if (this.autoNote.length > 0 && this.rows.length > 0) {
        Text(this.autoNote)
          .fontSize(11)
          .fontColor(Theme.text3(this.isDark))
          .width('100%')
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding, bottom: 4 })
      }

      if (this.rows.length === 0 && !this.busy) {
        Text('暂无插件文件。\n点「商店」下载插件，下载完会自动登记并装载。')
          .fontSize(13)
          .fontColor(Theme.text3(this.isDark))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 48 })
      }

      List() {
        ForEach(this.rows, (row: PluginRow) => {
          ListItem() {
            Column() {
              Row() {
                // s14 第 4 条：插件名前的图标（无 iconUrl = 应用图标等比占位，占位与有图同尺寸）
                PluginIcon({ iconUrl: row.iconUrl })
                Column() {
                  // s13 第 3 条（2026-11-12 用户裁定）：卡面「文件名 + 体积 KB」那一整行已删除，
                  // 只留居中的插件名（带版本号）。状态文案随那一行一并撤下，三态改由
                  // 灰字（missing）与 有无启用开关（非 ok 无开关）表达。
                  Text(this.rowTitle(row) + (row.version.length > 0 ? '  v' + row.version : ''))
                    .fontSize(15)
                    .fontColor(row.state === 'missing' ? Theme.text3(this.isDark) : Theme.text1(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .width('100%')
                    .textAlign(TextAlign.Center)
                }
                .alignItems(HorizontalAlign.Center)
                .layoutWeight(1)

                if (row.state === 'ok') {
                  Toggle({ type: ToggleType.Switch, isOn: row.enabled })
                    .onChange((on: boolean) => {
                      if (on !== row.enabled) {
                        this.toggleRow(row);
                      }
                    })
                }
                // 第 7 条：这里原来是一枚「打开/已装载/缺失」装载按钮，已按用户裁定删除 ——
                // 装载全自动（refresh 批量 + 开关打开即装 + 进设置页补装），行内只留 开关 / 更新 / 设置 / 删除。
                if (row.hasUpdate) {
                  Button('更新')
                    .fontSize(12)
                    .height(28)
                    .backgroundColor(Theme.warning)
                    .enabled(!this.busy)
                    .margin({ left: 6 })
                    .onClick((): void => {
                      this.updateRow(row);
                    })
                }
                // 注：行「设置」入口 ⇒ pages/PluginSettingsPage。用齿轮图标而不是文字按钮
                // （行内已有 开关+(更新)+设置+删除，文字按钮会挤爆一行）。
                // 可点性判定在 openSettings 里做（不在内存就地补装），不用瞬态 row.loaded 以免误灰。
                SymbolGlyph($r('sys.symbol.gearshape'))
                  .fontSize(Dim.iconSm + 4)
                  .fontColor([row.state === 'missing' ? Theme.text3(this.isDark) : Theme.text2(this.isDark)])
                  .margin({ left: 10 })
                  .onClick((): void => {
                    this.openSettings(row);
                  })
                Button('删除')
                  .fontSize(12)
                  .height(28)
                  .backgroundColor(Theme.error)
                  .enabled(!this.busy)
                  .margin({ left: 6 })
                  .onClick((): void => {
                    this.deleteRow(row);
                  })
              }
              .width('100%')
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10, bottom: 10 })

              // 第 5 条(1)：行分隔线删除 —— 卡片底色（cardColor）与页面底色（background）已有层次，
              // 再画一条线就是用户说的「明显分割线」。间距由上下 padding 提供。
            }
            .width('100%')
            .backgroundColor(Theme.cardColor(this.isDark))
          }
        }, (row: PluginRow) => row.localFile + '|' + row.state + '|' + row.loaded + '|' + row.enabled + '|' + row.latest)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // V20/C6-④：列表底部预留 = 悬浮胶囊底距 16 + 高 56 ⇒ 末行不被悬浮底栏遮挡
      .contentEndOffset(Dim.contentBottomReserve)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
    .bindContentCover($$this.shopOpen, this.shopSheet(), ModalTransition.DEFAULT)
  }

  /** 商店弹层（判据②）：全屏覆盖层；每行「下载」= installLatest（成功只落盘 ⇒ 回列表 unregistered）。 */
  @Builder
  shopSheet() {
    Column() {
      Row() {
        Text('插件商店')
          .fontSize(16)
          .fontColor(Theme.text1(true))
        Text(' v' + this.shopItems.length + ' 项 · ' + (this.shopVia.indexOf('seed') === 0 ? '离线快照' : this.shopVia))
          .fontSize(11)
          .fontFamily('monospace')
          .fontColor(this.shopVia.indexOf('seed') === 0 ? Theme.warning : Theme.text2(true))
          .margin({ left: 8 })
        Blank()
        Button(this.shopLoading ? '加载中…' : '强刷')
          .fontSize(12)
          .height(28)
          .backgroundColor(Theme.brand)
          .enabled(!this.shopLoading && !this.busy)
          .onClick((): void => {
            this.openShop(true);
          })
        Button('关闭')
          .fontSize(12)
          .height(28)
          .backgroundColor(Theme.fill)
          .margin({ left: 6 })
          .onClick((): void => {
            this.shopOpen = false;
          })
      }
      .width('100%')
      // 全屏覆盖层不继承页面安全区 ⇒ 标题必须自己让开状态栏（s5e 真机：标题与状态栏图标叠字）
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: this.topSafe + 10, bottom: 8 })

      if (this.shopItems.length === 0 && !this.shopLoading) {
        Text('插件商店索引为空（索引源全部不可达时才会出现），点右上角「强刷」重试。')
          .fontSize(13)
          .fontColor(Theme.text3(true))
          .textAlign(TextAlign.Center)
          .width('100%')
          .margin({ top: 48 })
      }

      // 卡片式列表（对标原版插件商店：标题 + 云端版本角标 + 简介 + 仓库行 + 右侧下载/已安装）
      List({ space: 10 }) {
        ForEach(this.shopItems, (it: ShopItem) => {
          ListItem() {
            Column() {
              Row() {
                // s14 第 4 条：商店卡片同名处也上图标（用户原话「插件管理中插件名前」含商店弹层）；
                // 与列表行共用同一个 PluginIcon ⇒ 尺寸、圆角、占位回落完全一致。
                PluginIcon({ iconUrl: it.iconUrl })
                // s15 第 7 条：真机现场 = 长名字的卡片把右侧「下载」按钮整个顶出屏幕右缘（按钮被切一刀）。
                // 根因 = Row 的子项默认 flexShrink 为 0（component/common.d.ts:20135 的属性注释写明），
                // 于是名字 Text 按内容全宽参与测量、把后面的角标与按钮挤出可用宽度，Ellipsis 永远轮不到。
                // 正解取「名字 + 角标」整组 layoutWeight(1)：按钮与图标保持内容宽、钉在右缘，角标紧贴名字
                // （比只给 Text 加 layoutWeight 更接近原排版 —— 后者会把角标推到按钮前面）。组内名字
                // flexShrink(1) 才允许被压缩、Ellipsis 生效；角标 flexShrink(0) 保证版本号不被压扁。
                // 原来那个 Blank() 一起撤掉：Blank 与 layoutWeight 都是「吃满剩余空间」的机制，两者并存
                // 谁先认领剩空间没有定论（本仓空白只在别的行单独用过），而 layoutWeight 是本页与已装列表
                // 行、仓库行都在用的既有做法 ⇒ 留确定性更强的那一个，别把名字挤成 0 宽。
                Row() {
                  Text(it.name)
                    .fontSize(15)
                    .fontWeight(FontWeight.Medium)
                    .fontColor(Theme.text1(true))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .flexShrink(1)
                  if (it.version.length > 0) {
                    Text('云端 ' + it.version)
                      .fontSize(10)
                      .fontColor(Theme.brand)
                      .backgroundColor('#1A0A59F7')
                      .borderRadius(6)
                      .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                      .margin({ left: 8 })
                      .flexShrink(0)
                  }
                }
                .layoutWeight(1)
                .alignItems(VerticalAlign.Center)
                Button(it.downloading ? '下载中…' : (this.localFileOf(it.uuid).length > 0 ? '重新下载' : '下载'))
                  .fontSize(12)
                  .height(28)
                  .backgroundColor(this.localFileOf(it.uuid).length > 0 ? Theme.fill : Theme.brand)
                  .enabled(!it.downloading && !this.busy && !this.shopLoading)
                  .onClick((): void => {
                    this.installShopItem(it);
                  })
              }
              .width('100%')

              if (it.describe.length > 0) {
                Text(it.describe)
                  .fontSize(12)
                  .fontColor(Theme.text2(true))
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                  .margin({ top: 6 })
              }

              Row() {
                Text(it.repo.length > 0 ? ('仓库: ' + it.repo) : it.uuid)
                  .fontSize(10)
                  .fontFamily('monospace')
                  .fontColor(Theme.text3(true))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)
                if (this.localFileOf(it.uuid).length > 0) {
                  Text('已安装')
                    .fontSize(10)
                    .fontColor(Theme.success)
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              .margin({ top: 6 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12, bottom: 12 })
            .backgroundColor('#14FFFFFF')
            .borderRadius(Dim.radius)
          }
          .margin({ left: Dim.pagePadding, right: Dim.pagePadding })
          // 索引到达后 rows 可能已变（下载完回列表）⇒ key 带 rows.length 保证角标刷新
        }, (it: ShopItem) => it.uuid + '|' + it.downloading + '|' + it.version + '|' + this.rows.length)
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      // 全屏弹层同样避让导航条（与主列表同一 Token，别自己写数）
      .contentEndOffset(Dim.contentBottomReserve)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5101010')
  }
}
