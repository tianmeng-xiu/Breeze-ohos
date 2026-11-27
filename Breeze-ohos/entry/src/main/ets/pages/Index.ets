/**
 * 职责：应用主页面宿主 —— S2 插件引擎诊断面板（验收证据） + 公共顶栏 + 五页签底栏容器。
 * 依赖：view/common/BreezeTopBar、view/common/BreezeBottomTab、view/common/Theme、
 *      util/PluginRuntime（原生引擎薄封装）、util/BreezeHost（宿主回调 5 路由）。
 * 说明：面板是唯一的真机调试通道（一项一行判据，一张截图 = 全部证据）：
 *      顶部设备信息行（无 hdc 时唯一环境证据）→ 7 项 PASS/FAIL/SKIP + 一行依据（每项独立
 *      try/catch，单项失败不连坐）→ 总判定；「重跑」重执行，「复制诊断」把整份 JSON 写剪贴板。
 *      全部重活走 Promise（Rust napi_async_work），不阻塞 UI 线程；书架等原有 UI 原样保留在面板下方。
 */
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { BreezeBottomTab, TabMeta } from '../view/common/BreezeBottomTab';
import { Theme, Dim } from '../view/common/Theme';
import { SurfaceMaterial } from '../view/common/Material';
import { Anim } from '../view/common/Anim';
import {
  engineLoaded, engineInit, engineDiagnostics, engineEval, engineSelftest, engineProbe,
  bundleLoad, bundleCall, bundleCallBytes, bundleList, bundleUnload, BytesResult, HostCallback,
  pluginScanDir, bundleLoadFromPath, pluginRemoveFile
} from '../util/PluginRuntime';
import { BreezeHost, HostRegistrar } from '../util/BreezeHost';
import { Logger } from '../util/Logger';
import { jparse, jstr, jint, jnum, jbool, jhas, jobj, jarr, jstrArr, jisEmpty } from '../util/JsonUtil';
import qjs from 'libbreeze_qjs_ohos.so';
import deviceInfo from '@ohos.deviceInfo';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { pasteboard, BusinessError } from '@kit.BasicServicesKit';
import { promptAction, display, router } from '@kit.ArkUI';
import { SearchEntryParams } from '../view/search/SearchEntryParams';
import { ImageCache } from '../data/image/ImageCache';
import { ReaderDiag } from '../view/reader/ReaderView';
import { PluginIconDiag } from '../view/plugins/PluginManagerView';
import { TextConvert } from '../util/TextConvert';
import { FeatureDiag } from '../util/FeatureDiag';
import { UpdateChecker } from '../util/UpdateChecker';
import { UserSettings } from '../util/UserSettings';
import { PluginStore, PluginRecord } from '../util/PluginStore';
import { deriveLocalUuid } from '../util/PluginUuid';
import { PluginInit } from '../util/PluginInit';
import { JmRaceDiag } from '../util/JmRaceDiag';

/** rawfile 路径（不带 rawfile/ 前缀）。real.bundle.cjs 可选：缺则面板第 7 项 SKIP。 */
const RAW_SELFTEST: string = 'plugins/selftest.bundle.cjs';
const RAW_REAL: string = 'plugins/real.bundle.cjs';

/** polyfill 检查表达式（在 QuickJS 里跑）：返回 "found/total" 或 "found/total miss:a,b"。 */
const POLY_EXPR: string = '(() => { const list=["Temporal","URL","URLSearchParams","Headers","Request","Response","fetch","Blob","File","FormData","native","bridge","crypto","uuidv4","TextEncoder","structuredClone"]; const miss=[]; let n=0; for (const k of list) { if (typeof globalThis[k] !== "undefined") { n++; } else { miss.push(k); } } return n + "/" + list.length + (miss.length ? " miss:" + miss.join(",") : ""); })()';

/** 面板一行：`n. name [STATUS] detail`。 */
class DiagLine {
  idx: number;
  name: string;
  status: string;
  detail: string;

  constructor(idx: number, name: string, status: string, detail: string) {
    this.idx = idx;
    this.name = name;
    this.status = status;
    this.detail = detail;
  }

  key(): string {
    return this.idx + '|' + this.name + '|' + this.status + '|' + this.detail;
  }
}

/** 诊断 JSON 的一条（有声明类型才能进对象字面量 —— ArkTS arkts-no-untyped-obj-literals）。 */
class DiagItem {
  name: string = '';
  status: string = '';
  detail: string = '';
}

/** 复制诊断用的整份报告结构。 */
class DiagReport {
  dev: string = '';
  exports: string = '';
  net: string = '';
  pluginIndex: string = '';
  download: string = '';
  unload: string = '';
  fileChain: string = '';
  jailEscape: string = '';
  /** s13 第 5 条：取图链取证行原文（插件档 / 宿主兜底档 / 两侧最后一次错因）。 */
  imageChain: string = '';
  /** s15 第 1 条：阅读器侧取证行原文（页记账 + 章级失败落点）。 */
  readerChain: string = '';
  /** s15 第 3 条：插件图标取图链取证行原文（直链/镜像/失败按域名分布）。 */
  pluginIcons: string = '';
  /** 19 pluginConfig（s16 第 4 条取证：持久化桶名集合，跨插件账号互串判据）。 */
  pluginConfig: string = '';
  featChain: string = '';
  /** 21 jmRuntime（s44 P1 探针）：JM dumpRuntimeInfo 摘要，判「端点池是否从未建立」。 */
  jmRuntime: string = '';
  /** 22 pluginInit（s46 P1b）：新装载后补发 init 的三态计数行原文。 */
  pluginInit: string = '';
  /** 23 pluginCfgKeys（s46 P2）：持久化桶键名清单（只有键名与长度，无值）。 */
  pluginCfgKeys: string = '';
  /** 24 jmRace（s49 取证探针）：章节空页表 B1/B2 判别 + 排行榜 init 冷窗口读数（纯观测）。 */
  jmRace: string = '';
  storageRoot: string = '';
  verdict: string = '';
  items: DiagItem[] = [];
}

/** 依据文本截断（Error.message 原文优先，超长截 160 字符）。 */
function cut(s: string, n: number): string {
  if (s === null || s === undefined) {
    return '';
  }
  return s.length <= n ? s : s.slice(0, n) + '…';
}

/**
 * s44 P1 探针（纯观测，不参与 verdict）：JM 插件的持久文件名前缀 = 索引 uuid 前 8 位。
 * 装机实测 = `bf99008d-0.1.1.bundle.cjs`（装载名 `local-bf99008d-0-1-1`）。
 */
const JM_FILE_PREFIX: string = 'bf99008d';
/** JM bundle 内硬编码常量 JM_FALLBACK_API_BASE 的域名（未建立端点池时恒打这枚）。 */
const JM_FALLBACK_API: string = 'www.cdnhjk.net';

/** `https://host/path` -> `host`（诊断行只放域名，放全 URL 会吃满预算）。 */
function shortHost(u: string): string {
  let s: string = u;
  if (s.startsWith('https://')) {
    s = s.slice(8);
  } else if (s.startsWith('http://')) {
    s = s.slice(7);
  }
  const slash: number = s.indexOf('/');
  return slash >= 0 ? s.slice(0, slash) : s;
}

/** 探针数组按 status 分档计数（`ok` 是插件侧 `status` 字段的三档之一，其余归 other）。 */
function probeTally(arr: ESObject[]): string {
  let okN: number = 0;
  let degN: number = 0;
  let deadN: number = 0;
  let otherN: number = 0;
  for (let i = 0; i < arr.length; i++) {
    const st: string = jstr(arr[i], 'status', '?');
    if (st === 'ok') {
      okN++;
    } else if (st === 'degraded') {
      degN++;
    } else if (st === 'dead') {
      deadN++;
    } else {
      otherN++;
    }
  }
  return 'ok' + okN + '/deg' + degN + '/dead' + deadN + (otherN > 0 ? '/other' + otherN : '');
}

/** 探针数组取前 n 枚摘要：`域名#状态[/httpStatus][@延迟ms]`。 */
function probeSample(arr: ESObject[], n: number): string {
  const parts: string[] = [];
  for (let i = 0; i < arr.length && parts.length < n; i++) {
    const one: string = shortHost(jstr(arr[i], 'baseUrl', '?')) + '#' + jstr(arr[i], 'status', '?');
    const hs: string = jstr(arr[i], 'httpStatus', '');
    const lat: string = jstr(arr[i], 'latencyMs', '');
    parts.push(one + (hs.length > 0 ? '/' + hs : '') + (lat.length > 0 ? '@' + lat + 'ms' : ''));
  }
  return parts.join(',');
}

/**
 * dumpRuntimeInfo 原文 -> 一行摘要。**判读四条件：**
 * `apiPool=0` ∧ `probes=0` ∧ `imgProbes=0` ∧ `api=www.cdnhjk.net` 同成立 ⇒ 插件 `init`
 * 从未被调用（JM 端点缓存的唯一写点在 init 引导链内，与网络通不通无关）。
 * 0.0.7 的 dumpRuntimeInfo 是 stub（只回 pluginName/now）⇒ 单列 `stub=1`，不与上面混判。
 */
function jmProbeHint(raw: string): string {
  const root: ESObject = jparse(raw);
  let d: ESObject = jobj(root, 'data');
  if (jisEmpty(d) && jhas(root, 'apiBaseUrl')) {
    d = root;
  }
  if (!jhas(d, 'apiBaseUrl')) {
    return 'stub=1 api=none（装机代次是 0.0.7 stub，dumpRuntimeInfo 无字段可判） raw=' + cut(raw, 90);
  }
  const api: string = jstr(d, 'apiBaseUrl', '');
  const img: string = jstr(d, 'imageBaseUrl', '');
  const apiPool: string[] = jstrArr(d, 'apiPool');
  const imgPool: string[] = jstrArr(d, 'imagePool');
  const probes: ESObject[] = jarr(d, 'probes');
  const imgProbes: ESObject[] = jarr(d, 'imageProbes');
  const neverInit: boolean = apiPool.length === 0 && probes.length === 0
    && imgProbes.length === 0 && api.indexOf(JM_FALLBACK_API) >= 0;
  const poolHosts: string[] = [];
  for (let i = 0; i < apiPool.length; i++) {
    poolHosts.push(shortHost(apiPool[i]));
  }
  let s: string = 'api=' + shortHost(api) + ' img=' + shortHost(img)
    + ' apiPool=' + apiPool.length + (poolHosts.length > 0 ? '(' + cut(poolHosts.join(','), 60) + ')' : '')
    + ' imgPool=' + imgPool.length
    + ' probes=' + probes.length + (probes.length > 0 ? '[' + probeTally(probes) + ' ' + cut(probeSample(probes, 3), 120) + ']' : '')
    + ' imgProbes=' + imgProbes.length + (imgProbes.length > 0 ? '[' + probeTally(imgProbes) + ']' : '')
    + ' tmo=' + jstr(d, 'probeTimeoutMs', '?');
  s += ' | VERDICT=' + (neverInit ? 'never-init（端点池从未建立，恒打回退域）' : 'init-ran（池/探针有读数，改判 reason）');
  return s;
}

/** 从 unknown 异常提取 message 原文（面板要显示原文，不加工）。typeof 判定规避 ArkTS 严格模式对 string===undefined 比较的告警。 */
function em(e: Object): string {
  const x = e as Error;
  const m = x.message;
  if (typeof m === 'string' && m.length > 0) {
    return m;
  }
  return String(e);
}

@Entry
@Component
struct Index {
  /** 当前页签下标（与 BreezeBottomTab.TabMeta.titles 同序）：s14 第 2 条起三签 = 0 书架 / 1 发现 / 2 更多
   *   （旧序 0 书架 / 1 发现 / 2 云收藏 / 3 更多 作废；云收藏改走 router 页 pages/CloudSyncPage）。
   *   初值 0 = 书架，与三签口径一致，不改。 */
  @State currentIndex: number = 0;
  @StorageProp('isDark') isDark: boolean = false;
  /** C5/C6-①：内容页滚动进度（0–1），由三个内容页写入，驱动顶栏透明↔实底 */
  @StorageProp('topBarProgress') topBarProgress: number = 0;

  /** S2 诊断面板状态（真机无 hilog：一张截图 = 全部验收证据）。 */
  @State diagLines: DiagLine[] = [];
  @State diagVerdict: string = '';
  @State diagRunning: boolean = false;
  private diagJson: string = '';
  private diagHeader: string = '';
  /** S3 取证：net / pluginIndex / download / unload 各行原始 JSON（全量进复制报告，屏幕只截 160）。 */
  private diagNet: string = '';
  private diagIndex: string = '';
  private diagDownload: string = '';
  private diagUnload: string = '';
  /** §12.5 取证：diagnostics.storageRoot 原文（§3，复制 JSON 直接可见）。 */
  private diagStorageRoot: string = '';
  /** exports 反射探针的完整原文（屏幕行截 240，复制 JSON 里放全量）。 */
  private diagExports: string = '';
  /** S4 取证：13 fileChain 三步 scan/probe 原文 + 14 jailEscape 三类拒绝文案。 */
  private diagFileChain: string = '';
  private diagJail: string = '';
  /** 16 imageChain 行原文（runDiag 时现算，不落盘）。 */
  private diagImage: string = '';
  /** 17 readerChain 行原文（同上，现算不落盘）。 */
  private diagReader: string = '';
  /** 18 pluginIcons 行原文（同上，现算不落盘）。 */
  private diagIcons: string = '';
  /** 19 pluginConfig 行原文（同上，现算不落盘）。 */
  private diagCfg: string = '';
  /** 20 featChain 行原文（同上，现算不落盘）：本轮四项新功能的读数口。 */
  private diagFeat: string = '';
  /** 21 jmRuntime 行原文（s44 P1 探针）：dumpRuntimeInfo 摘要，现算不落盘。 */
  private diagJm: string = '';
  /** 22 pluginInit 行原文（s46 P1b）：PluginInit.hint() 摘要，现算不落盘。 */
  private diagInit: string = '';
  /** 23 pluginCfgKeys 行原文（s46 P2）：BreezeHost.configBucketKeysHint()，现算不落盘。 */
  private diagKeys: string = '';
  /** 24 jmRace 行原文（s49 取证探针）：JmRaceDiag.hint()，现算不落盘。 */
  private diagJmRace: string = '';

  /** 诊断面板显隐（用户 m02396 硬约束：不许压屏幕顶部 ⇒ 改底部弹层 + 可收起）。 */
  @State diagOpen: boolean = true;
  /**
   * C13（task-2）：诊断入口隐藏门控，仿 Android 开发者选项。默认 false ⇒ 正常启动零诊断 UI
   * （悬浮球与弹层都不出现）；「我的→版本」连点 5 次开启。刻意**不落盘**：
   * 仅本次会话有效，杀进程重开恢复隐藏（task-2 验收条款）。首开时自动跑一轮 runDiag。
   */
  @StorageProp('diagGate') @Watch('onDiagGate') diagGate: boolean = false;
  private diagRanOnce: boolean = false;

  onDiagGate(changedProperty: string): void {
    if (this.diagGate && !this.diagRanOnce) {
      this.diagRanOnce = true;
      this.diagOpen = true;
      this.runDiag();
    }
  }
  /** C3 底栏档位（0 平铺 / 1 原生材质悬浮 / 2 HDS 悬浮）——诊断面板 0 行要显示它。 */
  /**
   * ⚠ s5g 起本字段只作**副作用保留**：字段初始化器在 Index 构造期就触发 SurfaceMaterial.tier()，
   * 把 matTier/matHds/... 五键写进 AppStorage，早于 BreezeBottomTab.aboutToAppear ⇒ 诊断面板
   * 在 aboutToAppear 里跑 runDiag 时一定能读到值。删掉它会让第 15 行 surface 偶发全默认值。
   * 真正的渲染分支判据请看 AppStorage 'matBarMode'（由 BreezeBottomTab 写入）。
   */
  private readonly barTier: number = SurfaceMaterial.tier();
  /**
   * 底栏是否悬浮（s5e 真机修正）：底部避让只看这个，**不要看 barTier**。
   * 真机可以是「tier=0 但 floatBar=true」（API26 可悬浮、ROM 无沉浸材质），
   * 用 tier 判避让会退化成平铺间距 58 ⇒ 弹层/球与胶囊重叠。
   */
  private readonly floatBar: boolean = SurfaceMaterial.floating();

  /**
   * 诊断弹层底部间距。悬浮档底栏只有 56vp 高且离底 16vp，
   * 旧写死的 58 会让弹层与胶囊重叠约 14vp（胶囊上部点不动 ⇒ 污染真机验收判据），
   * 故悬浮档整条让开；平铺档底栏仍含安全区，沿用旧值不退化。
   */
  private diagBottomMargin(): number {
    if (!this.floatBar) {
      return 58;
    }
    return Dim.floatingBarBottom + Dim.floatingBarH + 8;
  }

  /** 悬浮球位置（vp）。窗口尺寸在 aboutToAppear 里取，取不到用默认值。 */
  @State ballX: number = 300;
  @State ballY: number = 620;
  private dragBaseX: number = 300;
  private dragBaseY: number = 620;
  private winW: number = 360;
  private winH: number = 780;

  /** 悬浮球可拖范围（留出 12vp 边距，球径 44 ⇒ 不会被挤出屏幕）。 */
  private clampBallX(x: number): number {
    const lo: number = 12;
    const hi: number = this.winW - 56;
    if (x < lo) {
      return lo;
    }
    return x > hi ? hi : x;
  }

  private clampBallY(y: number): number {
    const lo: number = 96;
    // V21：悬浮档球不得拖进胶囊带（底部 16+56vp 再加 8vp 余量 + 球径 44），
    // 否则球会压在悬浮胶囊上做不了事；平铺档沿用旧下限不退化。
    const reserve: number = this.floatBar ? Dim.contentBottomReserve + 44 + 8 : 110;
    const hi: number = this.winH - reserve;
    if (y < lo) {
      return lo;
    }
    return y > hi ? hi : y;
  }

  aboutToAppear(): void {
    // 宿主路由需要 context（preferences/bundleManager）；面板全部异步逻辑由 runDiag 驱动。
    BreezeHost.init(getContext(this) as common.UIAbilityContext);
    // 简繁转换冷启动预热：读档（off 时不读词典，直接返回）+ 就绪后 bumpRev 让各显示处重绘。
    // 刻意不 await：首帧不等 IO；catch 只打日志（引擎内部已吞错并留未就绪态）。
    TextConvert.getInstance().setMode(UserSettings.readChineseConvert(), getContext(this).resourceManager)
      .catch((e: Object): void => {
        Logger.ex('简繁转换预热失败', e);
      });
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      this.winW = px2vp(d.width);
      this.winH = px2vp(d.height);
    } catch (e) {
      // 拿不到就留默认 360x780，clamp 仍会把球限制在可见范围
    }
    this.ballX = this.clampBallX(this.winW - 56);
    this.ballY = this.clampBallY(this.winH - 170);
    // C13：runDiag 不再无条件跑（省启动耗时），改由 onDiagGate 在首次开启入口时触发。
    // ⚠ 但宿主 5 路由注册必须无条件跑（原只在 runDiag 第 4 项里，runDiag 隐藏后
    // 插件管理页的 bridge.call 会 no route）⇒ 提前到这里；runDiag 内原调用幂等无害，保留。
    const reg: HostRegistrar = {
      registerHostCallback: (n: string, cb: HostCallback): boolean => qjs.registerHostCallback(n, cb),
      resolveBridgeCallback: (id: number, r: string): boolean => qjs.resolveBridgeCallback(id, r),
      rejectBridgeCallback: (id: number, msg: string): boolean => qjs.rejectBridgeCallback(id, msg)
    };
    BreezeHost.registerAll(reg);
  }

  // ------------------------------------------------------------ 诊断执行

  /** 读 rawfile 为 UTF-8 字符串（整文件一次返回，decodeToString 整缓冲不截尾）。 */
  private async readRaw(path: string): Promise<string> {
    const rm = getContext(this).resourceManager;
    const u8: Uint8Array = await rm.getRawFileContent(path);
    const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
    return dec.decodeToString(u8);
  }

  /** ABI §4 的 7 项判据，逐项独立 try/catch；push 即整组替换 @State 触发重绘。 */
  private async runDiag(): Promise<void> {
    if (this.diagRunning) {
      return;
    }
    this.diagRunning = true;
    this.diagLines = [];
    this.diagNet = '';
    this.diagIndex = '';
    this.diagDownload = '';
    this.diagUnload = '';
    this.diagStorageRoot = '';
    this.diagFileChain = '';
    this.diagJail = '';
    this.diagVerdict = 'RUNNING …';
    const lines: DiagLine[] = [];
    const header: string = 'dev ' + deviceInfo.productModel + ' / ' + deviceInfo.osFullName
      + ' / API' + deviceInfo.sdkApiVersion + '  ' + new Date().toISOString();
    this.diagHeader = header;

    let itemNo: number = 0;
    const push = (name: string, status: string, detail: string, maxLen: number = 160): void => {
      itemNo++;
      lines.push(new DiagLine(itemNo, name, status, cut(detail, maxLen)));
      this.diagLines = lines.slice();
    };

    let passes: number = 0;
    let fails: number = 0;
    let skips: number = 0;
    const record = (status: string): void => {
      if (status === 'PASS') {
        passes++;
      } else if (status === 'FAIL') {
        fails++;
      } else if (status === 'SKIP') {
        skips++;
      }
    };

    /** 固定编号行（S3 追加行不许挤动 1..7 —— 证据链按行号引用）。 */
    const pushFixed = (idx: number, name: string, status: string, detail: string,
      maxLen: number = 160): void => {
      lines.push(new DiagLine(idx, name, status, cut(detail, maxLen)));
      this.diagLines = lines.slice();
    };

    // ---- 0. exports（纯反射探针，不参与 verdict）：钉死「napi 注册到第几个断了」。
    //      ownKeys=[] ⇒ 注册函数没跑；只有 init ⇒ 循环在 diagnostics 处断。
    //      固定编号 0，让 7 项验收仍是 1..7（证据链按 1..7 引用行号）。
    try {
      const probe: string = engineProbe();
      this.diagExports = probe;
      lines.push(new DiagLine(0, 'exports', 'INFO', cut(probe, 240)));
    } catch (e) {
      this.diagExports = 'probe failed: ' + em(e as Object);
      lines.push(new DiagLine(0, 'exports', 'INFO', cut(this.diagExports, 240)));
    }
    this.diagLines = lines.slice();

    // ---- 0b. surface（C3 底栏形态取证，不参与 verdict）：s5e 真机「底栏未悬浮」的根因是
    //      没有任何地方显示「材质探测 false 但悬浮 true」这种组合，只能靠截图猜。
    //      tier=0 + float=true 是**合法形态**（API26 可悬浮、ROM 未开放沉浸材质）。
    try {
      const mt: number = AppStorage.get<number>('matTier') ?? -1;
      const mh: boolean = AppStorage.get<boolean>('matHds') ?? false;
      const mn: boolean = AppStorage.get<boolean>('matNative') ?? false;
      const mf: boolean = AppStorage.get<boolean>('matFloating') ?? false;
      const ma: number = AppStorage.get<number>('matApiLevel') ?? 0;
      const bm: string = AppStorage.get<string>('matBarMode') ?? 'unknown';
      // T1 取证：autoHide = 底栏收起绑定状态（hds:n/N / native:n/N / pending / off）。
      // 装机后「上滑底栏不收起」只需看这一项：n=0 说明一个 scroller 都没绑上。
      const ah: string = AppStorage.get<string>('matAutoHide') ?? 'unset';
      pushFixed(15, 'surface', 'INFO',
        'barMode=' + bm + ' tier=' + mt + ' hds=' + mh + ' nativeMat=' + mn + ' float=' + mf + ' api=' + ma +
          ' autoHide=' + ah,
        200);
    } catch (e) {
      pushFixed(15, 'surface', 'INFO', 'probe failed: ' + em(e as Object), 160);
    }

    // ---- 1. engine：init 返回 ok + diagnostics 可读（前 80 字符上屏）。
    let engineOk: boolean = false;
    /** 第 11/12 行前置门禁（§2）：引擎里读回的 __BREEZE_PLUGIN_ROOT 必须等于传入根。 */
    let rootGlobalOk: boolean = false;
    try {
      if (!engineLoaded()) {
        throw new Error('native module not registered (nm_modname / -lace_napi.z / oh-package deps)');
      }
      // §12.5：必须传插件目录根（filesDir）——11/12 行 probeDownload/probeUnload 硬前提，
      // 不传根 bundle 会报 no-storage-root。init 幂等，与 EntryAbility.onCreate 的先行调用不冲突。
      const root: string = getContext(this).filesDir;
      const initRet: string = engineInit(true, root);
      if (initRet !== 'ok') {
        throw new Error('init returned "' + initRet + '" (expect "ok")');
      }
      const diag: string = engineDiagnostics();
      // 第四版日志教训：cut(diag,80) 把 storageRoot/storageReady 吞了 ⇒ Rust
      // 注入静默失败拖到 11 行才暴露。这里显式 parse 存储字段 + 引擎回读全局，二条件不齐
      // 第 1 行就红，不再拖。JSON.parse 失败退回旧形态（不整行崩、不误判 MISSING）。
      let parsed: boolean = false;
      let ready: boolean = false;
      let detail: string = '';
      try {
        const dj: ESObject = jparse(diag);
        parsed = true;
        ready = jbool(dj, 'storageReady', false);
        const sr: ESObject = dj.storageRoot;
        const srStr: string = (sr === null || sr === undefined) ? '' : String(sr);
        this.diagStorageRoot = cut(srStr.length > 0 ? srStr : 'NONE', 200);
        const logs: ESObject[] = jarr(dj, 'log');
        const lp: string[] = [];
        for (let li = (logs.length > 2 ? logs.length - 2 : 0); li < logs.length; li++) {
          lp.push(cut(String(logs[li]), 48));
        }
        detail = 'init=ok root=' + cut(srStr.length > 0 ? srStr : 'NONE', 56)
          + ' fs=' + (dj.fs === true ? 'true' : 'false')
          + (lp.length > 0 ? ' logTail=' + lp.join(' | ') : '');
      } catch (pe) {
        this.diagStorageRoot = 'unparsed';
        detail = 'init=ok diag=' + cut(diag, 80);
      }
      // rootGlobal：让引擎自己回读注入的全局（回读 ≠ 传入 ⇒ Rust 注入 bug，第 1 行即 FAIL）。
      const gVal: string = await engineEval('String(globalThis.__BREEZE_PLUGIN_ROOT||"")');
      rootGlobalOk = gVal === root;
      detail += ' rootGlobal=' + (rootGlobalOk ? 'ok' : 'MISSING(' + cut(gVal, 40) + ')');
      if (!rootGlobalOk || (parsed && !ready)) {
        throw new Error(detail);
      }
      engineOk = true;
      push('engine', 'PASS', detail, 220);
    } catch (e) {
      push('engine', 'FAIL', em(e as Object), 220);
    }
    record(lines[lines.length - 1].status);

    // ---- 2. polyfill：16 个注入全局的存在数（fs 另列由 diagnostics 体现）。
    try {
      const r: string = await engineEval(POLY_EXPR);
      const m: RegExpMatchArray | null = r.match(/^(\d+)\/(\d+)/);
      if (m === null) {
        throw new Error('bad eval result: ' + r);
      }
      const found: number = parseInt(m[1], 10);
      const total: number = parseInt(m[2], 10);
      if (found !== total) {
        throw new Error(r);
      }
      push('polyfill', 'PASS', r + ' globals');
    } catch (e) {
      push('polyfill', 'FAIL', em(e as Object));
    }
    record(lines[lines.length - 1].status);

    // ---- 3. bundle：rawfile 读取 → bundleLoad → getInfo 含 name/version。
    let bundleOk: boolean = false;
    try {
      const src: string = await this.readRaw(RAW_SELFTEST);
      const loadRet: string = await bundleLoad('selftest', src);
      const infoJson: string = await bundleCall('selftest', 'getInfo', '[]');
      const o: ESObject = jparse(infoJson);
      const name: string = jstr(o, 'name', '');
      const version: string = jstr(o, 'version', '');
      if (name.length === 0 || version.length === 0) {
        throw new Error('getInfo missing name/version: ' + infoJson);
      }
      const list: string[] = await bundleList();
      bundleOk = true;
      push('bundle', 'PASS', 'src=' + src.length + 'ch load=' + loadRet + ' name=' + name
        + ' v=' + version + ' list=[' + list.join(',') + ']');
    } catch (e) {
      push('bundle', 'FAIL', em(e as Object));
    }
    record(lines[lines.length - 1].status);

    // ---- 4. hostBridge：bundle 内 bridge.call("dart.getLocaleInfo") 八字段且 IANA 非空。
    try {
      // 注册即幂等注册 5 路由；放本项 try 内 ⇒ 注册失败只红 hostBridge 一行。
      // 显式适配器对象（而非 `qjs as HostRegistrar` 结构转型）：对 ArkTS 严格模式最稳。
      const reg: HostRegistrar = {
        registerHostCallback: (n: string, cb: HostCallback): boolean => qjs.registerHostCallback(n, cb),
        resolveBridgeCallback: (id: number, r: string): boolean => qjs.resolveBridgeCallback(id, r),
        rejectBridgeCallback: (id: number, msg: string): boolean => qjs.rejectBridgeCallback(id, msg)
      };
      BreezeHost.registerAll(reg);
      if (!bundleOk) {
        throw new Error('skipped: selftest bundle not loaded');
      }
      const r: string = await bundleCall('selftest', 'probeHost', '[]');
      const o: ESObject = jparse(r);
      const iana: string = jstr(o, 'iana', '');
      const keys: number = jint(o, 'keys', 0);
      if (iana.length === 0 || keys !== 8) {
        throw new Error('iana="' + iana + '" keys=' + keys + ' raw=' + r);
      }
      // toast 证据取 errors.showToast 缺席（成功回包是空串 ⇒ Rust Null ⇒ JSON 里是 null，jhas 不可用）。
      const herr: ESObject = jobj(o, 'errors');
      push('hostBridge', 'PASS', 'iana=' + iana + ' keys=8 v=' + jstr(o, 'appVersion', '?')
        + ' toast=' + (jhas(herr, 'showToast') ? 'FAIL:' + cut(String(herr.showToast), 40) : 'ok')
        + ' disp=' + BreezeHost.displayHint() + ' ' + BreezeHost.configHint());
    } catch (e) {
      push('hostBridge', 'FAIL', em(e as Object));
    }
    record(lines[lines.length - 1].status);

    // ---- 5. config：save 写 probe=<时间戳> + load 读回同值（preferences 持久化）。
    try {
      if (!bundleOk) {
        throw new Error('skipped: selftest bundle not loaded');
      }
      const r: string = await bundleCall('selftest', 'probeConfig', '[]');
      const o: ESObject = jparse(r);
      const ok: boolean = jbool(o, 'ok', false);
      const expect: string = jstr(o, 'expect', '');
      const got: string = jstr(o, 'got', '');
      if (!ok || got.length === 0 || got !== expect) {
        throw new Error('expect=' + expect + ' got=' + got + ' ok=' + ok + ' errs=' + JSON.stringify(jobj(o, 'errors')));
      }
      push('config', 'PASS', 'roundtrip ' + got + ' (preferences)');
    } catch (e) {
      push('config', 'FAIL', em(e as Object));
    }
    record(lines[lines.length - 1].status);

    // ---- 6. binary：bundleCallBytes 取 Uint8Array ⇒ kind=bytes 且 byteLength>0。
    try {
      if (!bundleOk) {
        throw new Error('skipped: selftest bundle not loaded');
      }
      const res: BytesResult = await bundleCallBytes('selftest', 'fetchBytes', '[]');
      const u8: Uint8Array = new Uint8Array(res.bytes);
      if (res.kind !== 'bytes' || u8.byteLength === 0) {
        throw new Error('kind=' + res.kind + ' byteLength=' + u8.byteLength + ' json=' + cut(res.json, 40));
      }
      const h0: string = u8[0].toString(16).padStart(2, '0');
      const h1: string = u8[1].toString(16).padStart(2, '0');
      push('binary', 'PASS', 'kind=bytes len=' + u8.byteLength + ' body=' + res.bodyLength
        + ' status=' + res.statusCode + ' head=0x' + h0 + h1);
    } catch (e) {
      push('binary', 'FAIL', em(e as Object));
    }
    record(lines[lines.length - 1].status);

    // ---- 7. realBundle：rawfile 里有 plugins/real.bundle.cjs 才跑，缺 ⇒ SKIP。
    try {
      let realSrc: string;
      try {
        realSrc = await this.readRaw(RAW_REAL);
      } catch (e) {
        push('realBundle', 'SKIP', 'rawfile plugins/real.bundle.cjs not present');
        record('SKIP');
        realSrc = '';
      }
      if (realSrc.length > 0) {
        await bundleLoad('real', realSrc);
        const infoJson: string = await bundleCall('real', 'getInfo', '[]');
        const o: ESObject = jparse(infoJson);
        const name: string = jstr(o, 'name', '');
        const version: string = jstr(o, 'version', '');
        if (name.length === 0 || version.length === 0) {
          throw new Error('real getInfo missing name/version: ' + infoJson);
        }
        push('realBundle', 'PASS', 'name=' + name + ' v=' + version + ' src=' + realSrc.length + 'ch');
        record(lines[lines.length - 1].status);
      }
    } catch (e) {
      push('realBundle', 'FAIL', em(e as Object));
      record(lines[lines.length - 1].status);
    }

    // ---- 附 A：net（S3 第一批）：真机 fetch/TLS 取证，**参与 verdict**。
    //      固定编号 8：证据链按 1..7 引用旧行号 ⇒ 绝不动它们，新行只追加。
    //      这行的目的不是「通不通才红」这么简单：err/tlsErr 原文才是 S3 走 reqwest
    //      还是改 @ohos.net.http 回桥（+5 人日）的判据 ⇒ 两者有值就原样截 60 字符上屏。
    // SKIP 连坐信号（§4）：net 挂且 tlsErr ∈ {dns,timeout,conn}（域名级 RST/无网/
    // DNS 挂 ⇒ 下载必挂，跑了没信息量）⇒ 11/12 SKIP。no-root-certs/verify-fail 不算（下载
    // 失败本身是证据，真跑）。本轮真机 net=PASS ⇒ 11/12 必跑。
    let netTlsDead: boolean = false;
    try {
      if (!bundleOk) {
        throw new Error('skipped: selftest bundle not loaded');
      }
      const r: string = await bundleCall('selftest', 'probeNet', '[]');
      const o: ESObject = jparse(r);
      const ok: boolean = jbool(o, 'ok', false);
      const status: number = jint(o, 'status', 0);
      const bytes: number = jint(o, 'bytes', 0);
      const err: string = jstr(o, 'err', '');
      const tlsErr: string = jstr(o, 'tlsErr', '');
      this.diagNet = cut(r, 900);
      if (!(ok === true && status >= 200 && status < 400 && bytes > 0)) {
        if (tlsErr === 'dns' || tlsErr === 'timeout' || tlsErr === 'conn') {
          netTlsDead = true;
        }
        throw new Error('ok=' + ok + ' status=' + status + ' bytes=' + bytes
          + (err.length > 0 ? ' err=' + cut(err, 60) : '')
          + (tlsErr.length > 0 ? ' tlsErr=' + cut(tlsErr, 60) : ''));
      }
      let d: string = 'status=' + status + ' bytes=' + bytes + ' ms=' + jint(o, 'ms', -1)
        + ' ct=' + cut(jstr(o, 'ct', '?'), 24) + ' url=' + cut(jstr(o, 'url', '?'), 40);
      // PASS 也带 err 字段状态（空串=没有），全量在复制 JSON 的 evidence 里。
      if (err.length > 0 || tlsErr.length > 0) {
        d += ' (err=' + cut(err, 60) + ' tlsErr=' + cut(tlsErr, 60) + ')';
      }
      pushFixed(8, 'net', 'PASS', d);
    } catch (e) {
      // 判定失败时 diagNet 已含全量原始 JSON（不能覆盖）；只有没拿到回包才记异常。
      if (this.diagNet.length === 0) {
        this.diagNet = 'throw: ' + em(e as Object);
      }
      pushFixed(8, 'net', 'FAIL', em(e as Object), 200);
    }
    record(lines[lines.length - 1].status);

    // ---- 附 B：pluginIndex（S3 第一批）：plugins_data.json 索引拉取 + 版本比对取证。
    //      **INFO 不参与 verdict**（无管理页 UI，仅取证）；同样固定编号 9。
    try {
      if (!bundleOk) {
        throw new Error('skipped: selftest bundle not loaded');
      }
      const r: string = await bundleCall('selftest', 'probeIndex', '[]');
      const o: ESObject = jparse(r);
      const ok: boolean = jbool(o, 'ok', false);
      const total: number = jint(o, 'total', 0);
      const newer: ESObject[] = jarr(o, 'newer');
      const parts: string[] = [];
      for (let i = 0; i < newer.length && i < 4; i++) {
        const it: ESObject = newer[i];
        parts.push(jstr(it, 'name', '?') + ' ' + jstr(it, 'version', '?')
          + '→' + jstr(it, 'installedVersion', '?'));
      }
      this.diagIndex = cut(r, 900);
      pushFixed(9, 'pluginIndex', 'INFO', 'ok=' + ok + ' total=' + total
        + ' newer=' + newer.length + (parts.length > 0 ? ' [' + parts.join('; ') + ']' : ''));
    } catch (e) {
      if (this.diagIndex.length === 0) {
        this.diagIndex = 'throw: ' + em(e as Object);
      }
      pushFixed(9, 'pluginIndex', 'INFO', 'unavailable: ' + em(e as Object));
    }

    // ---- 11. download（S3 第二批）：三源回退下载 90KB bundle → sha256 比对
    //      (match) → 落盘 filesDir/plugins → 回读哈希 → bundleLoadFromPath 装载。
    //      **只判 ok===true**：载荷侧 out.ok = fetch&&hash&&match&&write&&readback&&load
    //      （line 506，**不含 stages.info**）——三方插件 jmcomic 的 getInfo 会自己发网络
    //      请求，真机无网会超时，但五段全绿仍算本行 PASS ⇒ stages.info/getInfoErr/name/version
    //      只进 detail 不参与判定。probeDownload 最长 ~26s（3×7.5s）< CALL_TIMEOUT=30s，
    //      await 走 napi_async_work 不挂 UI 线程。FAIL 附 stages/attempts 定位卡在哪一段。
    try {
      if (!rootGlobalOk) {
        this.diagDownload = '(BLOCKED) root global missing (line 1)';
        pushFixed(11, 'download', 'FAIL', 'root global missing (see line 1)');
      } else if (netTlsDead) {
        this.diagDownload = '(SKIP) net FAIL with tlsErr in {dns,timeout,conn}';
        pushFixed(11, 'download', 'SKIP', 'skipped: network unavailable (net FAIL)');
      } else if (!bundleOk) {
        throw new Error('skipped: selftest bundle not loaded');
      } else {
        const r: string = await bundleCall('selftest', 'probeDownload', '[]');
        const o: ESObject = jparse(r);
        this.diagDownload = cut(r, 1600);
        const st: ESObject = jobj(o, 'stages');
        if (jbool(o, 'ok', false) !== true) {
          const att: ESObject[] = jarr(o, 'attempts');
          const ap: string[] = [];
          for (let i = 0; i < att.length && i < 3; i++) {
            ap.push(jstr(att[i], 'label', '?') + ':' + (jbool(att[i], 'ok', false) ? 'ok'
              : cut(jstr(att[i], 'err', ''), 30)));
          }
          throw new Error('stages=' + JSON.stringify(st)
            + ' err=' + cut(jstr(o, 'err', ''), 60)
            + ' tlsErr=' + cut(jstr(o, 'tlsErr', ''), 40)
            + (ap.length > 0 ? ' attempts=[' + ap.join('; ') + ']' : ''));
        }
        pushFixed(11, 'download', 'PASS',
          'via=' + cut(jstr(o, 'sourceLabel', '?'), 16) + ' bytes=' + jint(o, 'bytes', 0)
            + ' match=' + jbool(o, 'match', false) + ' readback=' + jbool(o, 'readback', false)
            + ' loaded=' + jbool(o, 'loaded', false) + ' info=' + jbool(st, 'info', false)
            + ' ms=' + jint(o, 'ms', -1)
            + ' name=' + cut(jstr(o, 'name', '?'), 20) + ' v=' + cut(jstr(o, 'version', '?'), 12)
            + ' to=' + cut(jstr(o, 'savedTo', '?'), 44)
            + ' rb=' + jint(o, 'readbackBytes', 0), 200);
      }
    } catch (e) {
      if (this.diagDownload.length === 0) {
        this.diagDownload = 'throw: ' + em(e as Object);
      }
      pushFixed(11, 'download', 'FAIL', em(e as Object), 220);
    }
    record(lines[lines.length - 1].status);

    // ---- 12. unload（S3 第二批）：卸载第 11 行刚装载的下载插件并删文件（**必须在 11 之后跑**，
    //      删的就是 11 落的文件；11 失败时这里 unlink ENOENT 跟着红 = 预期行为，不做特殊处理）。
    //      载荷侧 out.ok = unloaded && !stillInList && removed && !stillExists（line 540），
    //      面板只判 ok===true。纯 fs 操作很快。
    try {
      if (!rootGlobalOk) {
        this.diagUnload = '(BLOCKED) root global missing (line 1)';
        pushFixed(12, 'unload', 'FAIL', 'root global missing (see line 1)');
      } else if (netTlsDead) {
        this.diagUnload = '(SKIP) net FAIL with tlsErr in {dns,timeout,conn}';
        pushFixed(12, 'unload', 'SKIP', 'skipped: network unavailable (net FAIL)');
      } else if (!bundleOk) {
        throw new Error('skipped: selftest bundle not loaded');
      } else {
        const r: string = await bundleCall('selftest', 'probeUnload', '[]');
        const o: ESObject = jparse(r);
        this.diagUnload = cut(r, 900);
        if (jbool(o, 'ok', false) !== true) {
          throw new Error('unloaded=' + jbool(o, 'unloaded', false)
            + ' inList=' + jbool(o, 'stillInList', true)
            + ' removed=' + jbool(o, 'removed', false)
            + ' exists=' + jbool(o, 'stillExists', true)
            + ' dir=' + jint(o, 'dirEntries', -1)
            + ' err=' + cut(jstr(o, 'err', ''), 80));
        }
        pushFixed(12, 'unload', 'PASS',
          'unloaded=true removed=true dir=' + jint(o, 'dirEntries', -1)
            + ' name=' + cut(jstr(o, 'name', '?'), 20));
      }
    } catch (e) {
      if (this.diagUnload.length === 0) {
        this.diagUnload = 'throw: ' + em(e as Object);
      }
      pushFixed(12, 'unload', 'FAIL', em(e as Object), 200);
    }
    record(lines[lines.length - 1].status);

    // ---- 13. fileChain（S4）：probeFiles 写一个 228B 可装载 bundle 到
    //      files/plugins/s4-probe-file.cjs（它自己不删 ⇒ 清理是本链尾步），随后走
    //      scan→loadFromPath→getInfo→unload→removeFile→rescan→幂等 七步。
    //      **纯 fs，不连坐 net**（12 行的 jm-comic 与 net 有关，13/14 纯本地）⇒ 门禁只有
    //      rootGlobalOk + bundleOk。任何一步不达预期 ⇒ FAIL 带 step=N；步骤 3-5 的 reject
    //      原文必须全量上屏（首次真机走 bundleLoadFromPath：readFile / UTF-8 校验 / jail
    //      三类文案各不相同，原文就是定位依据）。
    const chain: string[] = [];
    try {
      if (!rootGlobalOk) {
        this.diagFileChain = '(BLOCKED) root global missing (line 1)';
        throw new Error('step=0 root global missing (see line 1)');
      }
      if (!bundleOk) {
        this.diagFileChain = '(BLOCKED) selftest bundle not loaded';
        throw new Error('step=0 selftest bundle not loaded');
      }
      // step 1：probeFiles ⇒ ok===true，取 path/bytes（bytes 期望 228，sha 前缀 b0ee1566）。
      const pr: string = await bundleCall('selftest', 'probeFiles', '[]');
      chain.push('probe=' + cut(pr, 600));
      const po: ESObject = jparse(pr);
      if (jbool(po, 'ok', false) !== true) {
        throw new Error('step=1 probeFiles ok=false err=' + cut(jstr(po, 'err', ''), 80));
      }
      const fpath: string = jstr(po, 'path', '');
      const fbytes: number = jnum(po, 'bytes', -1);
      // step 2：pluginScanDir 必须含该文件且 bytes 与 fs 侧一致、mtimeMs>0（两条路数不一致
      //         本身就是有效发现 ⇒ 直接 FAIL 暴露）。
      const scan1: string = await pluginScanDir('plugins');
      chain.push('scan1=' + cut(scan1, 300));
      const s1root: ESObject = jparse(scan1);
      const s1: ESObject[] = Array.isArray(s1root) ? (s1root as ESObject[]) : [];
      let hitBytes: number = -1;
      let hitMtime: number = 0;
      const brief: string[] = [];
      for (let i = 0; i < s1.length; i++) {
        const nm: string = jstr(s1[i], 'name', '?');
        if (i < 3) {
          brief.push(nm + '/' + jnum(s1[i], 'bytes', 0));
        }
        if (nm === 's4-probe-file.cjs') {
          hitBytes = jnum(s1[i], 'bytes', -1);
          hitMtime = jnum(s1[i], 'mtimeMs', 0);
        }
      }
      if (hitBytes !== fbytes || hitMtime <= 0) {
        throw new Error('step=2 scan name=s4-probe-file.cjs bytes=' + hitBytes + ' want=' + fbytes
          + ' mtimeMs=' + hitMtime + ' path=' + cut(fpath, 44) + ' first3=[' + brief.join(',') + ']');
      }
      // step 3：bundleLoadFromPath（首次真机调用，reject 原文含 stack ⇒ 截 200 上屏）。
      let lr: string = '';
      try {
        lr = await bundleLoadFromPath('s4probe', fpath);
      } catch (e) {
        throw new Error('step=3 bundleLoadFromPath: ' + cut(em(e as Object), 200));
      }
      if (lr !== 'ok') {
        throw new Error('step=3 returned "' + cut(lr, 40) + '" (want ok)');
      }
      // step 4：装载后 name = 第一参数（ABI §7），getInfo 必须是载荷自述的 S4 ProbeFile/1.0.0。
      let infoS: string = '';
      try {
        infoS = await bundleCall('s4probe', 'getInfo', '[]');
      } catch (e) {
        throw new Error('step=4 getInfo: ' + cut(em(e as Object), 200));
      }
      chain.push('info=' + cut(infoS, 200));
      const io: ESObject = jparse(infoS);
      const iname: string = jstr(io, 'name', '');
      const iver: string = jstr(io, 'version', '');
      if (iname !== 'S4 ProbeFile' || iver !== '1.0.0') {
        throw new Error('step=4 name="' + iname + '" version="' + iver + '" raw=' + cut(infoS, 120));
      }
      // step 5：unload ⇒ true 且 bundleList 不再含 s4probe。
      let un: boolean = false;
      try {
        un = await bundleUnload('s4probe');
      } catch (e) {
        throw new Error('step=5 bundleUnload: ' + cut(em(e as Object), 200));
      }
      const lst: string[] = await bundleList();
      let inList: boolean = false;
      for (let i = 0; i < lst.length; i++) {
        if (lst[i] === 's4probe') {
          inList = true;
        }
      }
      if (!un || inList) {
        throw new Error('step=5 unloaded=' + un + ' stillInList=' + inList + ' list=' + cut(lst.join(','), 80));
      }
      // step 6：删文件 ⇒ 'removed'。
      let rm: string = '';
      try {
        rm = await pluginRemoveFile(fpath);
      } catch (e) {
        throw new Error('step=6 pluginRemoveFile: ' + cut(em(e as Object), 200));
      }
      if (rm !== 'removed') {
        throw new Error('step=6 returned "' + cut(rm, 40) + '" (want removed)');
      }
      // step 7：rescan 不再含该文件；幂等复查再删一次 ⇒ 期望 'absent'（只进 detail，不判 FAIL）。
      const scan2: string = await pluginScanDir('plugins');
      chain.push('scan2=' + cut(scan2, 300));
      const s2root: ESObject = jparse(scan2);
      const s2: ESObject[] = Array.isArray(s2root) ? (s2root as ESObject[]) : [];
      let still: boolean = false;
      for (let i = 0; i < s2.length; i++) {
        if (jstr(s2[i], 'name', '') === 's4-probe-file.cjs') {
          still = true;
        }
      }
      if (still) {
        throw new Error('step=7 s4-probe-file.cjs still listed after remove');
      }
      let idem: string = '';
      try {
        idem = await pluginRemoveFile(fpath);
      } catch (e) {
        idem = 'throw:' + cut(em(e as Object), 40);
      }
      chain.push('idem=' + idem);
      this.diagFileChain = cut(chain.join(' | '), 1600);
      pushFixed(13, 'fileChain', 'PASS',
        'chain=7/7 bytes=' + fbytes + ' scan=ok load=ok info=' + iname
          + ' unload=ok removed=absent-ok'
          + ' idem=' + idem + ' first3=[' + brief.join(',') + ']', 260);
    } catch (e) {
      if (this.diagFileChain.length === 0) {
        this.diagFileChain = 'throw: ' + em(e as Object);
      }
      pushFixed(13, 'fileChain', 'FAIL', em(e as Object), 280);
    }
    record(lines[lines.length - 1].status);

    // ---- 14. jailEscape（S4 安全判据）：三发越界调用 **必须全部 reject**；
    //      任何一发成功返回 = 逃逸成功 = 安全 FAIL（detail 记 LEAKED call-N）。
    //      门禁只有 rootGlobalOk（net/bundle 都不连坐）。reject 的 Error.message 原文照打，
    //      用于与 Rust jail_path 三类文案对照：path escapes storage root / path must be
    //      absolute / .. not allowed。
    try {
      if (!rootGlobalOk) {
        this.diagJail = '(BLOCKED) root global missing (line 1)';
        throw new Error('root global missing (see line 1)');
      }
      const filesRoot: string = getContext(this).filesDir;
      const jmsgs: string[] = [];
      let leak: string = '';
      // call 1：越界删除（../etc/passwd）
      let m1: string = '';
      try {
        const r1: string = await pluginRemoveFile(filesRoot + '/../etc/passwd');
        leak = 'LEAKED call-1 pluginRemoveFile ret="' + cut(r1, 20) + '"';
      } catch (e) {
        m1 = em(e as Object);
      }
      if (leak.length > 0) {
        throw new Error(leak);
      }
      jmsgs.push('1:' + cut(m1, 40));
      // call 2：越界装载（../../etc/hosts）
      let m2: string = '';
      try {
        const r2: string = await bundleLoadFromPath('evil', filesRoot + '/../../etc/hosts');
        leak = 'LEAKED call-2 bundleLoadFromPath ret="' + cut(r2, 20) + '"';
      } catch (e) {
        m2 = em(e as Object);
      }
      if (leak.length > 0) {
        throw new Error(leak);
      }
      jmsgs.push('2:' + cut(m2, 40));
      // call 3：relDir 带 ..
      let m3: string = '';
      try {
        const r3: string = await pluginScanDir('../');
        leak = 'LEAKED call-3 pluginScanDir ret="' + cut(r3, 20) + '"';
      } catch (e) {
        m3 = em(e as Object);
      }
      if (leak.length > 0) {
        throw new Error(leak);
      }
      jmsgs.push('3:' + cut(m3, 40));
      this.diagJail = cut(jmsgs.join(' | '), 600);
      pushFixed(14, 'jailEscape', 'PASS', 'blocked=3/3 ' + jmsgs.join(' '), 260);
    } catch (e) {
      if (this.diagJail.length === 0) {
        this.diagJail = 'throw: ' + em(e as Object);
      }
      pushFixed(14, 'jailEscape', 'FAIL', em(e as Object), 240);
    }
    record(lines[lines.length - 1].status);

    // ---- 附：引擎自检（S2 结构 {globals:{name:bool}, probes:{name:"值"|"ERR: msg"}}）——
    //      整包 JSON 截 160 会看不到重点，按验收口径只报缺的全局与失败的探针。
    try {
      const st: string = await engineSelftest();
      const o: ESObject = jparse(st);
      const g: ESObject = jobj(o, 'globals');
      const gKeys: string[] = Object.keys(g);
      const missing: string[] = [];
      for (let i = 0; i < gKeys.length; i++) {
        if (g[gKeys[i]] !== true) {
          missing.push(gKeys[i]);
        }
      }
      const pr: ESObject = jobj(o, 'probes');
      const pKeys: string[] = Object.keys(pr);
      const bad: string[] = [];
      for (let i = 0; i < pKeys.length; i++) {
        const v: ESObject = pr[pKeys[i]];
        // 双形态兼容：旧 S2 probes:{name:"值"|"ERR: msg"}；改 {name:{ok,value}}。
        if (v !== null && typeof v === 'object') {
          if (v.ok !== true) {
            bad.push(pKeys[i] + '(' + cut(String(v.err !== undefined ? v.err : v.value), 24) + ')');
          }
        } else {
          const vs: string = String(v);
          if (vs.startsWith('ERR:')) {
            bad.push(pKeys[i] + '(' + cut(vs.slice(4), 24) + ')');
          }
        }
      }
      pushFixed(10, 'selftest', 'INFO', 'globals ' + (gKeys.length - missing.length) + '/' + gKeys.length
        + (missing.length > 0 ? ' miss:' + missing.join(',') : '')
        + ' probes ' + (pKeys.length - bad.length) + '/' + pKeys.length
        + (bad.length > 0 ? ' bad:' + bad.join(';') : ' all ok'));
    } catch (e) {
      pushFixed(10, 'selftest', 'INFO', 'unavailable: ' + em(e as Object));
    }

    // ---- 16. imageChain（INFO，不计入 verdict）：s13 第 5 条「某图源任何情况下都显示拿不到图」的取证口。
    //      s15 判读法更新（cache-fix 离线桩 80 项实测，取代上面旧三行；旧写法会把人带偏）：
    //        plugin=tries 单独看无意义 —— 它只在「未命中磁盘且是插件图源且通道在」那条分支自增；
    //        先看 pf/hf/df/mf/pfail 五档：五档相加必须等于 pc，对不上就是出现了第七条出口；
    //        hf 或 df 等于 pc 且 pf=0 ⇒ 阅读器根本没翻页，这些是封面类非插件调用（npSrc 可佐证），属合法组合；
    //        blk=黑/取样/未知 三位：未知数 == 取样总数时整条黑图判据作废，不得据 blk=0 排除黑图；
    //        pErr 与 hErr 同时非空 ⇒ 两侧都失败，pErr 优先当根因。
    //      计数是本次进程累计：请先翻几页漫画再开面板，否则全 0 只说明还没取过图。
    try {
      const hint: string = ImageCache.imageHint();
      this.diagImage = cut(hint, 720);
      pushFixed(16, 'imageChain', 'INFO', hint, 720);
    } catch (e) {
      this.diagImage = 'throw: ' + em(e as Object);
      pushFixed(16, 'imageChain', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }

    // ---- 总判定 + 可复制 JSON。S3 起前缀 S3（第二批起判定 10 项：S2 七项 + net + download +
    //      unload；pluginIndex/selftest/exports 为 INFO 不计入），如需保留 S2 字样可回退。
    // ---- 17. readerChain（INFO，不计入 verdict）：s15 第 1 条「进漫画点阅读直接无法加载」的取证口。
    //      判读法：errCount 是章级五档合计（含「暂无章节」「本章节没有图片」两档非异常），
    //      pagesOk 与它互斥 —— pagesOk>0 说明章级链路是通的，问题在取图（看 16 行）；
    //      pagesOk=0 且 errCount>0 ⇒ 整章没起来，last= 就是屏上那句（catch 档已带插件真错因）；
    //      两档全 0 = 本次进程根本没进过阅读器，此时 16 行 pc=0 属同因，不是取图链坏了。
    try {
      const rhint: string = ReaderDiag.chapterHint() + ' | ' + ReaderDiag.pageHint();
      this.diagReader = cut(rhint, 720);
      pushFixed(17, 'readerChain', 'INFO', rhint, 720);
    } catch (e) {
      this.diagReader = 'throw: ' + em(e as Object);
      pushFixed(17, 'readerChain', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }

    // ---- 18. pluginIcons（INFO，不计入 verdict）：s15 第 3 条「插件管理里图标不显示」的取证口。
    //      判读法：恒等式 ok + okMirror + fail == calls（balanced() 就是判这个）；
    //      noUrl=上游索引本身没填（e-hentai 那条）与 badUrl=值不是 URL，两者都不进 calls，不污染失败率；
    //      hosts=域名:成功/尝试 是这行最有信息量的字段 —— 14 条图标挂在 raw.githubusercontent 与
    //      cdn.jsdelivr 上（真机对这两域被 RST，见 selftest 载荷记录），按域名一比就把「不显示」落到具体 host；
    //      mirror=救回/尝试 全 0 且 fail 高 ⇒ 镜像档也没救活 = 真网络不可达，不是代码坏了；
    //      skip=此前已全档落空直接占位的次数（List 复用节点反复重触发才会涨，属预期省流）。
    try {
      const ihint: string = PluginIconDiag.hint();
      this.diagIcons = cut(ihint, 720);
      pushFixed(18, 'pluginIcons', 'INFO', ihint, 720);
    } catch (e) {
      this.diagIcons = 'throw: ' + em(e as Object);
      pushFixed(18, 'pluginIcons', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }

    // ---- 19. pluginConfig（INFO，不计入 verdict）：s16 第 4 条「一个插件登录后另一个插件残留帐号」的取证口。
    //      判读法：runtimes= 是本进程见过的 runtime 桶名(次数)。只有 breeze-ohos 一枚（当前实现）
    //      = 全部插件共用一个持久化桶，名为 auth.account / auth.password 的键在插件间互换值，
    //      这就是跨插件账号互串的根因（上游是每插件一 runtime，天然隔离）；出现多枚（plugin_xxx 形态）
    //      = Rust 侧分桶已生效（那一步会改 .so 且存量登录态一次性失效，需用户拍板）。
    //      keys= 是最近一次读到的桶内键数（多插件共用时会明显大于单个插件的设置项数）。
    try {
      const chint: string = BreezeHost.configHint();
      this.diagCfg = cut(chint, 720);
      pushFixed(19, 'pluginConfig', 'INFO', chint, 720);
    } catch (e) {
      this.diagCfg = 'throw: ' + em(e as Object);
      pushFixed(19, 'pluginConfig', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }
    // ---- 20. featChain（INFO，不计入 verdict）：本轮四项新功能（搜索触底翻页 / 发评论 / 图片画质 / 检查更新）
    //      的读数口。s32 那轮「竖向到底不切章」全靠手感判，最后才发现是保底接手 ⇒ 这次每项留读数。
    //      判读法：
    //        sp=a/b/c/d/e/f = 触底请求/成功追加/某源失败/判定到底/换代丢弃/被闸门挡下（s34 起第六档）。
    //          翻到底应看到 a>0 且 d>0；**a=0 而 f>0 = 触底事件有进来、但那一刻 moreState 已经不是 more**
    //          （到底判定或首屏状态把它闸住了 —— s33 那轮 jm 就是这个形态，当时 f 还没有、读不出来）；
    //          a=0 且 f=0 才是「onReachEnd 压根没触发」；a>0 而 b=0 且 c>0 = 下一页请求全失败；
    //          e 涨 = 用户在翻页途中改了词（正常，属丢弃不是故障）。
    //        cm=a/b/c/d/e = 提交/成功/失败/其中「插件未实现」/其中整页重拉。真机 most 图源预期是 c==d>0
    //          （图源没这功能，属正常）；b>0 且 e=0 = 本地落位成功；b>0 且 e>0 = 插件没回 created 走了重拉（也正常，代价是丢滚动位置）。
    //        iq=写次数/最近值 = 插件设置页「图片画质」写入。写完后翻下一页看 16 号行的图床域名有没有换。
    //        tc= 简繁引擎状态（mode/ready/loadMs/rev/cache/四表条数）：rev=0 = 从未就绪也从没切档 ⇒ 各处显示原样，
    //          切了档却 rev 不涨 = bumpRev 没跑（显示不会变）；loadMs 就是切繁体的那一下卡多久（>300 就该考虑异步分片）；
    //          转简档下 stP/stC 应为 0（另一档已释放），两边都非 0 = releaseUnused 没生效。
    //        up= 最近一次检查更新（via/latest/self/log/asset）：没点过 = none。
    try {
      const fhint: string = FeatureDiag.hint() + ' | tc=' + TextConvert.getInstance().stats()
        + ' | up=' + UpdateChecker.lastHintOf();
      this.diagFeat = fhint;
      pushFixed(20, 'featChain', 'INFO', fhint, 720);
    } catch (e) {
      this.diagFeat = 'throw: ' + em(e as Object);
      pushFixed(20, 'featChain', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }

    // ---- 21. jmRuntime（s44 P1 探针，INFO 不计入 verdict）：直调 JM 插件自己导出的
    //      dumpRuntimeInfo，读它进程里的端点池状态。为什么需要这一行：JM 的 API 域名不是常量，
    //      端点缓存 `runtime:endpoints` 的**唯一写点**在插件 `init` 的引导链里（bundle 内普查 =
    //      定义 + 唯一调用两处），而我方宿主装载链只调 getInfo、从不调 init ⇒ 冷启动缓存必空 ⇒
    //      业务恒退回硬编码 JM_FALLBACK_API_BASE = www.cdnhjk.net，且 hostPool=[] 让 failover
    //      的 `length<=1` 闸门永不放行 ⇒ 登录与排行榜同时死（两者共用同一个 base）。
    //      判读四条件：apiPool=0 ∧ probes=0 ∧ imgProbes=0 ∧ api=www.cdnhjk.net 同成立 ⇒ 坐实
    //      「init 从未被调用」，与网络通不通无关；probes 非空 ⇒ 该结论翻转，改看 probes 的 reason。
    //      纯观测：不发请求（dumpRuntimeInfo 只投影已缓存的探针结果）、不改任何插件状态。
    try {
      const ctx21: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const recs21: PluginRecord[] = await PluginStore.loadAll(ctx21);
      let jmFile: string = '';
      let jmUuid: string = '';
      let jmName: string = '';
      for (let i = 0; i < recs21.length; i++) {
        if (recs21[i].localFile.startsWith(JM_FILE_PREFIX)) {
          jmFile = recs21[i].localFile;
          // 装载名必须用清单里的 uuid（启动链 autoLoadAll 用的就是它，:223）；
          // 清单缺件才退回 deriveLocalUuid —— 两者规则同源，但已装载件以清单为准。
          jmUuid = recs21[i].uuid;
          jmName = recs21[i].name;
        }
      }
      if (jmFile.length === 0) {
        // 清单没有 ⇒ 目录里可能有手放的件，装载名走 deriveLocalUuid 同一套规则。
        const scanRoot: ESObject = jparse(await pluginScanDir('plugins'));
        const scanArr: ESObject[] = Array.isArray(scanRoot) ? (scanRoot as ESObject[]) : [];
        for (let i = 0; i < scanArr.length; i++) {
          const nm: string = jstr(scanArr[i], 'name', '');
          if (nm.startsWith(JM_FILE_PREFIX)) {
            jmFile = nm;
            jmUuid = deriveLocalUuid(nm);
          }
        }
      }
      if (jmFile.length === 0) {
        this.diagJm = 'not installed（清单与 plugins 目录都没有 ' + JM_FILE_PREFIX + ' 前缀的件）';
        pushFixed(21, 'jmRuntime', 'SKIP', this.diagJm, 200);
      } else if (!bundleOk) {
        this.diagJm = 'skipped: engine not ready file=' + jmFile;
        pushFixed(21, 'jmRuntime', 'SKIP', this.diagJm, 200);
      } else {
        // 装载刻意**不走 PluginAutoLoader.loadOne**：那函数无条件调 registerOne，传空 name 会把
        // 图源显示名覆盖成文件名（「禁漫天堂」→「bf99008d-0.1.1」）直到下次重启 ⇒ 探针不能有这
        // 种副作用。这里只做引擎侧装载（启动链本来就会做同一件事），不碰图源注册表。
        this.diagJm = 'file=' + jmFile + ' name=' + jmUuid + (jmName.length > 0 ? '(' + jmName + ')' : '') + ' ';
        let inMem: boolean = false;
        try {
          const lst21: string[] = await bundleList();
          for (let i = 0; i < lst21.length; i++) {
            if (lst21[i] === jmUuid) {
              inMem = true;
            }
          }
        } catch (e) {
          inMem = false;
        }
        if (!inMem) {
          const ret21: string = await bundleLoadFromPath(jmUuid, ctx21.filesDir + '/plugins/' + jmFile);
          if (ret21 !== 'ok') {
            throw new Error('bundleLoadFromPath returned ' + cut(ret21, 60));
          }
        }
        const raw21: string = await bundleCall(jmUuid, 'dumpRuntimeInfo', '[{"extern":{}}]');
        this.diagJm += 'load=' + (inMem ? 'cached' : 'ok') + ' raw=' + cut(raw21, 300);
        pushFixed(21, 'jmRuntime', 'INFO', jmProbeHint(raw21), 720);
      }
    } catch (e) {
      // 已有部分读数时保留它（file= 段就是证据），只在完全没拿到时记异常。
      if (this.diagJm.length === 0) {
        this.diagJm = 'throw: ' + em(e as Object);
      }
      pushFixed(21, 'jmRuntime', 'FAIL', this.diagJm, 720);
    }

    // ---- 22 pluginInit（s46 P1b）：新装载插件补发 init 的三态读数（INFO 不计入判定）。
    // 判读：ok≥1 且 21 行 VERDICT 由 never-init 改判 init-ran ⇒ P1b 生效（init 真跑了、端点池建立了）；
    // ni = 该插件本来就没导出 init（真机 26 枚里 7 枚属正常态，不算失败）；
    // err>0 看行尾 last= 段（只留最后一条消息前 160 字符）；mark= 是发起总数，q=/running= 是队列态。
    try {
      const ihint: string = PluginInit.hint();
      this.diagInit = ihint;
      pushFixed(22, 'pluginInit', 'INFO', ihint, 720);
    } catch (e) {
      this.diagInit = 'throw: ' + em(e as Object);
      pushFixed(22, 'pluginInit', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }

    // ---- 23 pluginCfgKeys（s46 P2）：持久化桶只列键名与长度（INFO 不计入判定，值绝不上屏）。
    // 判读：JM 桶出现 auth.jwt 加星 = 登录态已落盘、只剩端点选择；
    // auth.account/auth.password（带星）在而 auth.jwt 无 = 与 21 行 never-init 互证
    // （凭据写了但 init 没跑，会话没换成 jwt）；no-ctx = 面板早于宿主 init 打开，重开面板即可。
    try {
      const khint: string = BreezeHost.configBucketKeysHint();
      this.diagKeys = khint;
      pushFixed(23, 'pluginCfgKeys', 'INFO', khint, 720);
    } catch (e) {
      this.diagKeys = 'throw: ' + em(e as Object);
      pushFixed(23, 'pluginCfgKeys', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }

    // ---- 24 jmRace（s49 取证探针）：JM 章节空页表的 B1/B2 判别 + 排行榜 init 冷窗口（INFO 不计入判定）。
    // 判读：pc 段 same=1 且 fake=1 ⇒ B1（插件把作品 id 当章节 id 伪造单章，宿主侧无需改链路）；
    // init=none/run 或 age=-1 ⇒ B2（事件早于登录/init 生效）；age>1800000 = 已过插件 30 min TTL；
    // img= 四档 0 无 images 键、1 非数组、2 空数组、3 非空数组；pf 段是排行榜首次点击的失败现场。
    try {
      const rhint24: string = JmRaceDiag.hint();
      this.diagJmRace = rhint24;
      pushFixed(24, 'jmRace', 'INFO', rhint24, 720);
    } catch (e) {
      this.diagJmRace = 'throw: ' + em(e as Object);
      pushFixed(24, 'jmRace', 'INFO', 'unavailable: ' + em(e as Object), 200);
    }

    // ---- 总判定 + 可复制 JSON。S4 起前缀 S4（判定 12 项：S2 七项 + net + download + unload +
    //      fileChain + jailEscape；pluginIndex/selftest/exports 为 INFO 不计入），如需回退字样可改。
    const verdict: string = fails === 0
      ? 'S4 VERDICT: PASS (pass=' + passes + ' skip=' + skips + ')'
      : 'S4 VERDICT: FAIL (fail=' + fails + ' pass=' + passes + ' skip=' + skips + ')';
    this.diagVerdict = verdict;
    const items: DiagItem[] = [];
    for (let i = 0; i < lines.length; i++) {
      const item = new DiagItem();
      item.name = lines[i].name;
      item.status = lines[i].status;
      item.detail = lines[i].detail;
      items.push(item);
    }
    const report = new DiagReport();
    report.dev = header;
    report.exports = this.diagExports;
    report.net = this.diagNet;
    report.pluginIndex = this.diagIndex;
    report.download = this.diagDownload;
    report.unload = this.diagUnload;
    report.fileChain = this.diagFileChain;
    report.jailEscape = this.diagJail;
    report.imageChain = this.diagImage;
    report.readerChain = this.diagReader;
    report.pluginIcons = this.diagIcons;
    report.pluginConfig = this.diagCfg;
    report.featChain = this.diagFeat;
    report.jmRuntime = this.diagJm;
    report.pluginInit = this.diagInit;
    report.pluginCfgKeys = this.diagKeys;
    report.jmRace = this.diagJmRace;
    report.storageRoot = this.diagStorageRoot;
    report.verdict = verdict;
    report.items = items;
    this.diagJson = JSON.stringify(report, null, 1);
    this.diagRunning = false;
  }

  // ------------------------------------------------------------ 复制诊断

  /** 整份 JSON 写系统剪贴板（用户贴文字给协作者，无需截图 OCR）。 */
  private copyReport(): void {
    try {
      if (this.diagJson.length === 0) {
        promptAction.showToast({ message: '诊断尚未完成' });
        return;
      }
      const data: pasteboard.PasteData = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.diagJson);
      pasteboard.getSystemPasteboard().setData(data).then((): void => {
        promptAction.showToast({ message: '诊断 JSON 已复制到剪贴板' });
      }).catch((e: BusinessError): void => {
        promptAction.showToast({ message: '复制失败: ' + e.message });
      });
    } catch (e) {
      promptAction.showToast({ message: '复制失败: ' + em(e as Object) });
    }
  }

  /**
   * 顶栏搜索图标（需求 1，用户 m05810）。不传 sourceId ⇒ 搜索页自己回落到「全部来源」，
   * 因为顶栏是全局的，此刻用户可能在任何一个页签上，指定图源反而不直观。
   */
  private openSearch(): void {
    try {
      router.pushUrl({ url: 'pages/SearchPage', params: new SearchEntryParams('') });
    } catch (e) {
      Logger.w('打开搜索页失败：' + (e as Error).message);
    }
  }

  private statusColor(status: string): string {    if (status === 'PASS') {
      return '#9CFFB4';
    }
    if (status === 'FAIL') {
      return '#FF8A80';
    }
    if (status === 'SKIP') {
      return '#FFD166';
    }
    return '#9EC9FF';
  }

  /**
   * s32 第 1 条（用户原话「从书架进入书籍详情页和从书籍详情页退出到书架动画仍不统一，
   * 应当全部统一为封面飞入飞出的效果」）：本页此前**全文件零 pageTransition**，
   * 于是详情页那侧是 360 ms 淡入淡出（pages/DetailPage.ets:701）而书架这侧吃 router 默认转场
   * （位移推拉）⇒ 进入 = 详情页淡入 + 封面飞；返回 = 详情页淡出 + 书架整页滑入，
   * 两套方向感叠在一起就是「不统一」。补上与详情页**同 duration 同 curve 同构造**的一档淡入淡出：
   * 两页四写点（本页 Enter/Exit + 详情页 Enter/Exit）全同 ⇒ 任意方向的页级观感只剩淡入淡出，
   * 方向感统一交给封面共享元素（第 1 条要的「飞入飞出」）。
   * ★ 书架是 TabContent 子组件，结构上没有独立的 pageTransition 入口 ⇒ 只能挂在宿主 @Entry 页上，
   *   这也是刻意**不给 DetailPage 单独设位移**的原因（详情在滑、书架不动 = 又是两套观感）。
   * 已知副作用（真机要盯）：pageTransition 是页级、不区分去向 ⇒ 冷启动第一帧的主页可能也走一次
   * 360 ms 淡入。若真机确认难看，回退方案 = 只留 PageTransitionExit（返回侧不再依赖本页）。
   */
  pageTransition() {
    PageTransitionEnter({ duration: Anim.pageHero, curve: Anim.curveEaseOut() })
      .opacity(0);
    PageTransitionExit({ duration: Anim.pageHero, curve: Anim.curveEaseOut() })
      .opacity(0);
  }

  build() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // ---- 正常页面（诊断面板绝不再压在顶部：用户真机反馈顶部与状态栏冲突、按钮点不到）
      Column() {
        BreezeTopBar({
          title: TabMeta.titleOf(this.currentIndex),
          showBack: false,
          actionText: '',
          // 需求 1（用户 m05810）：发现页那条搜索栏收进顶栏右上角，缩成一个图标。
          // 三个一级页都放（搜索本就是全局能力），点谁都是同一个搜索页。
          showSearch: true,
          // C5：顶栏随内容页滚动响应（0=透明 1=实底），由各页写入 AppStorage 'topBarProgress'
          scrollProgress: this.topBarProgress,
          onBack: () => {},
          onAction: () => {},
          onSearch: () => {
            this.openSearch();
          }
        })

        BreezeBottomTab({
          currentIndex: $currentIndex,
          onChange: (index: number) => {
            // C4：标题切换走 Anim.to（未绑定 UIContext 时自动退化为直接赋值）
            Anim.to((): void => {
              this.currentIndex = index;
            }, Anim.topBarFade, Anim.curveEaseOut());
            // C6-①：换页签时顶栏进度归零（否则从滚动过的页切到无滚动页会停在实底态）
            AppStorage.setOrCreate<number>('topBarProgress', 0);
          }
        })
          .layoutWeight(1)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.background(this.isDark))

      // ---- 诊断面板：底部弹层（贴 tab 栏上方），可收起 ⇒ 所有按钮都在可点区域
      // C13：外层加 diagGate 门控，未开启入口时整个诊断 UI 不构建。
      if (this.diagGate && this.diagOpen && (this.diagLines.length > 0 || this.diagRunning)) {
        Column() {
          Row() {
            Text('S2 插件引擎诊断')
              .fontSize(12)
              .fontColor('#FFFFFF')
              .fontWeight(FontWeight.Medium)
              .layoutWeight(1)
            Button(this.diagRunning ? '运行中…' : '重跑')
              .fontSize(11)
              .height(26)
              .backgroundColor('#2E7CB8')
              .margin({ right: 6 })
              .onClick((): void => {
                this.runDiag();
              })
            Button('复制诊断')
              .fontSize(11)
              .height(26)
              .backgroundColor('#2E7CB8')
              .margin({ right: 6 })
              .onClick((): void => {
                this.copyReport();
              })
            Button('收起')
              .fontSize(11)
              .height(26)
              .backgroundColor('#5A6472')
              .onClick((): void => {
                this.diagOpen = false;
              })
          }
          .width('100%')
          .margin({ bottom: 4 })

          Scroll() {
            Column() {
              Text(this.diagHeader)
                .fontSize(11)
                .fontFamily('monospace')
                .fontColor('#CFE6FF')
                .width('100%')
              ForEach(this.diagLines, (item: DiagLine) => {
                Text(item.idx + '. ' + item.name + ' [' + item.status + '] ' + item.detail)
                  .fontSize(11)
                  .fontFamily('monospace')
                  .fontColor(this.statusColor(item.status))
                  .width('100%')
              }, (item: DiagLine) => item.key())
              Text(this.diagVerdict)
                .fontSize(11)
                .fontFamily('monospace')
                .fontWeight(FontWeight.Bold)
                .fontColor(this.diagVerdict.indexOf('FAIL') >= 0 ? '#FF8A80' : '#9CFFB4')
                .width('100%')
                .margin({ top: 2 })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
          .scrollable(ScrollDirection.Vertical)
          .scrollBar(BarState.Auto)
          .height(216)
          .align(Alignment.TopStart)
        }
        .width('94%')
        .padding(10)
        .backgroundColor('#14324B')
        .borderRadius(10)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: '3%', bottom: this.diagBottomMargin() })
      }

      // ---- 悬浮球：C13 起仅入口开启后出现；可拖到任意位置，点一下开/收面板
      if (this.diagGate) {
        Stack() {
          Text('S2')
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
        }
        .width(44)
        .height(44)
        .borderRadius(22)
        .backgroundColor(this.diagOpen ? '#2E7CB8' : '#1C6FA8')
        .opacity(0.9)
        .position({ x: this.ballX, y: this.ballY })
        .onClick((): void => {
          this.diagOpen = !this.diagOpen;
        })
        .gesture(
          PanGesture({ direction: PanDirection.All, distance: 4 })
            .onActionStart((): void => {
              this.dragBaseX = this.ballX;
              this.dragBaseY = this.ballY;
            })
            .onActionUpdate((event: GestureEvent): void => {
              this.ballX = this.clampBallX(this.dragBaseX + event.offsetX);
              this.ballY = this.clampBallY(this.dragBaseY + event.offsetY);
            })
        )
      }
    }
    .width('100%')
    .height('100%')
  }
}
