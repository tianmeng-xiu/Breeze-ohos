/**
 * 职责：S4 插件管理页主体 —— 列表 = pluginScanDir('plugins') ⊕ PluginStore('installed.json') join；
 *       操作 = 启用开关、更新、删除（bundleUnload → pluginRemoveFile → 清桶，顺序硬约束防内存挂已删文件）。
 * 第 7 条改造（2026-11-11 用户裁定）：**行内不再有「打开/装载」按钮**，装载全部自动：
 *       进本页 refresh 里自动登记未登记文件 + 自动装载「启用且可用」的插件（PluginAutoLoader）；
 *       开关打开即真装载（不是懒装载），开关状态由 PluginStore.setEnabled 落盘、重启保留。
 * 依赖：PluginRuntime(ABI v3 三导出)、PluginStore、JsonUtil、Theme。引擎 init(filesDir) 由
 *       EntryAbility/Index 已完成；本页所有引擎调用前判 rootGlobal 级前置 = try/catch 后原文 toast
 *       （no-storage-root 会直接可见）。面板（诊断弹层）不经此处，保持现状。
 * join 三态：文件有+清单有=ok；文件有+清单无=unregistered（"文件存在但未登记"）；
 *           清单有+文件无=missing（"需重新下载"，灰态）。
 */
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { pluginScanDir, bundleUnload, bundleList, pluginRemoveFile, bundleCall, bundleLoad } from '../../util/PluginRuntime';
import { PluginStore, PluginRecord, ShopMapEntry } from '../../util/PluginStore';
import { PluginSourceRegistry } from '../../data/source/PluginSourceRegistry';
import { PluginAutoLoader, LoadOutcome } from '../../data/source/PluginAutoLoader';
import { deriveLocalUuid } from '../../util/PluginUuid';
import { jparse, jstr, jnum, jbool, jarr } from '../../util/JsonUtil';
import { util } from '@kit.ArkTS';
import { Theme, Dim } from '../common/Theme';

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
  /** 检查更新结果（瞬态，refresh 后清空）。 */
  latest: string = '';
  hasUpdate: boolean = false;

  statusLabel(): string {
    if (this.state === 'missing') {
      return '需重新下载';
    }
    if (this.state === 'unregistered') {
      return '文件存在但未登记';
    }
    // 第 7 条改造：装载由系统自动完成，loaded 现在由 bundleList 实填（不再是「点过打开」的瞬态），
    // 所以文案可以直接说状态，不必再带「清单」二字免责。
    return this.loaded ? '已装载' : (this.enabled ? '已启用（装载中或装载失败）' : '已停用');
  }
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
 * 跳插件设置页传参（契约：只传三字段，页内自调
 * getSettingsBundle / getCapabilitiesBundle / getUserInfoBundle）。
 * ArkTS 10605038 ⇒ 类承载，禁裸对象字面量。
 */
class PluginSettingsParams {
  uuid: string = '';
  name: string = '';
  localFile: string = '';
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
  /** 检查更新进行中（判据 ③：行级 latest 先置空）。 */
  @State checking: boolean = false;
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
      .catch((err: Error) => {
        this.toast('打开设置页失败: ' + err.message);
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

  aboutToAppear(): void {
    this.refresh();
    this.ensureMgr();
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
      this.lastError = (e as Error).message ?? String(e);
    }
    let recs: PluginRecord[] = await PluginStore.loadAll(this.ctx());
    const shopMap: ShopMapEntry[] = await PluginStore.loadShopMap(this.ctx());
    const mapIdx: (f: string) => string = (f: string): string => {
      for (let m = 0; m < shopMap.length; m++) {
        if (shopMap[m].file === f) {
          return shopMap[m].indexUuid;
        }
      }
      return '';
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
      const uid: string = await PluginAutoLoader.adoptAndLoad(this.ctx(), files[k].name, mapIdx(files[k].name));
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
      row.title = r.name.length > 0 ? r.name : r.uuid;
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
        row.title = files[k].name;
        row.localFile = files[k].name;
        row.bytes = files[k].bytes;
        row.state = 'unregistered';
        row.indexUuid = mapIdx(files[k].name);
        out.push(row);
      }
    }
    this.rows = out;
    this.busy = false;
    if (this.lastError.length > 0) {
      this.toast('scanDir: ' + this.lastError);
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
      this.toast('已删除 ' + row.localFile);
    } catch (e) {
      this.busy = false;
      this.toast('删除失败: ' + ((e as Error).message ?? String(e)));
    }
  }

  /**
   * 造演示数据（真机无 hdc 传不了文件）：把 rawfile 里的 real.bundle.cjs
   * 拷成 filesDir/plugins/mangadex.bundle.cjs ⇒ scanDir 出 unregistered 行，
   * 即可真机走通 打开→登记→删除 闭环。网络零依赖（rawfile 随包），uuid 将是
   * local-mangadex（deriveLocalUuid），与面板 selftest/real 装载名不冲突。
   */
  async seedDemo(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    try {
      const rm = getContext(this).resourceManager;
      const u8: Uint8Array = await rm.getRawFileContent('plugins/real.bundle.cjs');
      const dec: util.TextDecoder = util.TextDecoder.create('utf-8');
      const text: string = dec.decodeToString(u8);
      if (text.length === 0) {
        throw new Error('rawfile plugins/real.bundle.cjs 为空');
      }
      const dir: string = this.ctx().filesDir + '/plugins';
      try {
        fs.mkdirSync(dir);
      } catch (e) {
        // 已存在：mkdirSync 抛 EEXIST，忽略
      }
      const file: fs.File = fs.openSync(dir + '/mangadex.bundle.cjs',
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, text);
      fs.closeSync(file);
      this.rows = [];
      this.busy = false;
      await this.refresh();
      this.toast('演示文件已放入（未登记态）');
    } catch (e) {
      this.busy = false;
      this.toast('造演示失败: ' + ((e as Error).message ?? String(e)));
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
        throw new Error('rawfile plugins/plugin_mgr.bundle.cjs 为空');
      }
      const ret: string = await bundleLoad(MGR_NAME, text);
      if (ret !== 'ok') {
        throw new Error('bundleLoad returned "' + ret + '"');
      }
      return true;
    } catch (e) {
      this.toast('商店模块装载失败: ' + ((e as Error).message ?? String(e)));
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
      const items: ESObject[] = jarr(o, 'items');
      const out: ShopItem[] = [];
      for (let i = 0; i < items.length; i++) {
        const it: ShopItem = new ShopItem();
        it.uuid = jstr(items[i], 'uuid', '');
        it.name = jstr(items[i], 'name', '');
        it.version = jstr(items[i], 'version', '');
        it.describe = jstr(items[i], 'describe', '');
        it.repo = jstr(items[i], 'repo', '');
        it.home = jstr(items[i], 'home', '');
        if (it.uuid.length > 0) {
          out.push(it);
        }
      }
      this.shopItems = out;
      const ie: string = jstr(o, 'err', '');
      if (ie.length > 0) {
        this.toast('索引走降级(' + this.shopVia + '): ' + ie);
      }
    } catch (e) {
      this.toast('fetchIndex 失败: ' + ((e as Error).message ?? String(e)));
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
          await PluginStore.saveShopMap(this.ctx(), fname, it.uuid);
        }
        this.rows = [];
        await this.refresh();
        this.toast('已下载 ' + jstr(o, 'name', it.name) + ' v' + jstr(o, 'version', '')
          + '（' + Math.round(jnum(o, 'bytes', 0) / 1024) + 'KB via ' + jstr(o, 'via', '') + '），已自动装载');
      } else {
        this.toast('下载失败: ' + jstr(o, 'err', 'unknown'));
      }
    } catch (e) {
      this.toast('下载失败: ' + ((e as Error).message ?? String(e)));
    }
    it.downloading = false;
    this.shopItems = this.shopItems.slice();
  }

  /** 检查更新（判据③）：只送有 indexUuid 的行；args 双层 JSON（数组里放一个字符串）。 */
  async checkUpdatesAll(): Promise<void> {
    if (this.busy || this.checking) {
      return;
    }
    if (!(await this.ensureMgr())) {
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
      this.toast('没有可检查的商店插件（先经商店下载并打开登记）');
      return;
    }
    this.checking = true;
    try {
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
      this.toast(upd > 0 ? ('发现 ' + upd + ' 个可更新') : ('无可用更新（共查 ' + results.length + ' 项）'));
    } catch (e) {
      this.toast('检查更新失败: ' + ((e as Error).message ?? String(e)));
    }
    this.checking = false;
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
        await PluginStore.saveShopMap(this.ctx(), fname, row.indexUuid);
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
      this.toast('更新失败: ' + ((e as Error).message ?? String(e)));
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
      this.toast('开关写入失败: ' + ((e as Error).message ?? String(e)));
    }
  }

  build() {
    Column() {
      Row() {
        Text('插件目录 filesDir/plugins（清单 ' + this.rows.length + ' 项）')
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
        Button(this.checking ? '检查中…' : '检查更新')
          .fontSize(12)
          .height(28)
          .backgroundColor(Theme.fill)
          .enabled(!this.busy && !this.checking)
          .margin({ left: 6 })
          .onClick((): void => {
            this.checkUpdatesAll();
          })
        Button('造演示')
          .fontSize(12)
          .height(28)
          .backgroundColor(Theme.fill)
          .enabled(!this.busy)
          .margin({ left: 6 })
          .onClick((): void => {
            this.seedDemo();
          })
      }
      .width('100%')
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 8, bottom: 8 })

      if (this.lastError.length > 0) {
        Text('scanDir 错误：' + this.lastError)
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
                Column() {
                  Text(row.title + (row.version.length > 0 ? '  v' + row.version : ''))
                    .fontSize(15)
                    .fontColor(row.state === 'missing' ? Theme.text3(this.isDark) : Theme.text1(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Text(row.localFile + (row.bytes > 0 ? '  ' + Math.round(row.bytes / 1024) + ' KB' : '')
                    + '  ' + row.statusLabel()
                    + (row.hasUpdate ? '  可更新→v' + row.latest : ''))
                    .fontSize(11)
                    .fontFamily('monospace')
                    .fontColor(row.state === 'ok' ? Theme.text2(this.isDark) : Theme.warning)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .margin({ top: 2 })
                }
                .alignItems(HorizontalAlign.Start)
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
                Text(it.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text1(true))
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                if (it.version.length > 0) {
                  Text('云端 ' + it.version)
                    .fontSize(10)
                    .fontColor(Theme.brand)
                    .backgroundColor('#1A0A59F7')
                    .borderRadius(6)
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .margin({ left: 8 })
                }
                Blank()
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
