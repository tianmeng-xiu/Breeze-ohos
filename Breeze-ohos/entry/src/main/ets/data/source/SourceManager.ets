/**
 * 职责：图源注册表（单例）。内置源在构造时自动注册，也允许运行期 register 自定义源。
 * 替换原 Flutter 依赖：breeze 的 comic_source 全局实例与 dart 侧 switch 分支。
 * 依据系统 Kit：无（纯 ArkTS），仅依赖 data/source 内的接口 + data/kv 的开关位。
 *
 * s52（2026-11-27 用户裁定）：**内置图源变成可开关的**。内置源（MangaDex 那一枚早期联调用源）
 * 过去无条件出现在发现页/搜索页的来源条里，用户要求改成「放在插件管理内由用户决定是否开启」。
 * 三条口径（用户三选项里拍定的前两项 + 第三项）：
 *  1) **注册与可见分离**：内置源始终 register 在册 ⇒ `get()` / `require()` 恒可用 ⇒ 关掉的源
 *     **仍然读得懂**：书架/收藏/历史里已存的该源作品照常打开、照常取图取章节。
 *     这与「插件停用」不同（停用走 unregister，点进去会报「未找到图源」），是有意区分：
 *     内置源不会带来任何磁盘/内存负担，把已收藏的书变成打不开的书只让人以为坏了。
 *  2) **缺省关闭**：偏好键缺失 = 未启用。理由 = 那是早期联调用的示例源，默认摊在所有人面前
 *     不如让用户自己决定；代价（老用户升级后书架里的 MangaDex 作品仍在、但来源条里没它）
 *     由「读得懂」这一条兜住。
 *  3) **可见性只影响 chip 条**：UI 一律改读 visibleList()；`list()` 保持「全部在册」原义不动
 *     —— PluginSourceRegistry 的 stale 扫描与 CloudFavoriteSync 的插件筛选都靠它，
 *     把隐藏混进 list() 会让那两处误判（前者按 list() 决定注销谁，后者按它决定云收藏范围）。
 */
import { SourceInfo } from '../model/Models';
import { MangaSource, SourceIds } from './Source';
import { MangadexSource } from './MangadexSource';
import { PreferenceStore, PrefKeys } from '../kv/PreferenceStore';
import { Logger } from '../../util/Logger';

export class SourceManager {
  private static instance: SourceManager | null = null;
  /** id -> 源实例；插入顺序即 list() 顺序。 */
  private sources: Map<string, MangaSource> = new Map();
  private order: string[] = [];
  private builtInDone: boolean = false;
  /**
   * 被用户关掉的图源 id（只影响 visibleList()，不影响 get/require）。
   * 存「关掉的那些」而不是「开着的那些」：新注册的源默认可见才是原来所有调用点的既有预期，
   * 反过来存会让插件源一注册就因不在集合里而消失。
   */
  private hidden: Set<string> = new Set<string>();
  /** 内置源 id（按注册顺序），applyPrefs 按它逐个读开关位。 */
  private builtInIds: string[] = [];

  private constructor() {
  }

  /** 单例：首次取用时自动注册内置源（幂等）。 */
  static getInstance(): SourceManager {
    if (SourceManager.instance === null) {
      const mgr: SourceManager = new SourceManager();
      mgr.initBuiltIn();
      SourceManager.instance = mgr;
    }
    return SourceManager.instance;
  }

  /** 注册（同 id 覆盖元数据但保持位置）。 */
  register(s: MangaSource): void {
    if (s === null || s === undefined) {
      return;
    }
    const id: string = s.info().id;
    if (id.length === 0) {
      Logger.w('忽略 id 为空的源');
      return;
    }
    if (!this.sources.has(id)) {
      this.order.push(id);
    }
    this.sources.set(id, s);
    Logger.i('图源已注册：' + id);
  }

  /** 注销一个源（G1：插件停用/删除后 chip 消失）。不存在则忽略；两张表同删，重注册顺序稳定。 */
  unregister(id: string): void {
    if (!this.sources.has(id)) {
      return;
    }
    this.sources.delete(id);
    const i: number = this.order.indexOf(id);
    if (i >= 0) {
      this.order.splice(i, 1);
    }
    // 顺带清开关位：否则删掉的插件 uuid 若被复用，会继承上一次的隐藏态。
    this.hidden.delete(id);
    Logger.i('图源已注销：' + id);
  }

  /** 已注册源描述列表（供设置页/发现页展示）。 */
  list(): SourceInfo[] {
    const out: SourceInfo[] = [];
    for (let i = 0; i < this.order.length; i++) {
      const s: MangaSource | undefined = this.sources.get(this.order[i]);
      if (s !== undefined) {
        out.push(s.info());
      }
    }
    return out;
  }

  /**
   * 用户可见的图源列表（发现页 / 搜索页来源条的唯一口径）= list() 去掉被关掉的。
   * ★ 新增这一层而不动 list() 的理由见文件头口径 3。
   */
  visibleList(): SourceInfo[] {
    const all: SourceInfo[] = this.list();
    if (this.hidden.size === 0) {
      return all;
    }
    const out: SourceInfo[] = [];
    for (let i = 0; i < all.length; i++) {
      if (!this.hidden.has(all[i].id)) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /**
   * 图源显示名；不认识（含已注销的插件源）返回空串，由调用方决定回落成什么。
   * 与 visibleList 无关：关掉的源照样有名字 ⇒ 收藏里那本书的来源小字不会退化成 'mangadex'。
   */
  nameOf(id: string): string {
    const s: MangaSource | undefined = this.sources.get(id);
    return s === undefined ? '' : s.info().name;
  }

  get(id: string): MangaSource | null {
    const s: MangaSource | undefined = this.sources.get(id);
    return s === undefined ? null : s;
  }

  /** 取源，取不到直接抛可展示的中文错误（调用方不必再判空）。 */
  require(id: string): MangaSource {
    const s: MangaSource | null = this.get(id);
    if (s === null) {
      throw new Error('未找到图源：' + id);
    }
    return s;
  }

  has(id: string): boolean {
    return this.sources.has(id);
  }

  /** 注册内置源；重复调用安全。 */
  initBuiltIn(): void {
    if (!this.builtInDone) {
      this.builtInDone = true;
      this.register(new MangadexSource());
      this.builtInIds.push(SourceIds.MANGADEX);
      Logger.i('内置图源数量：' + this.order.length + '（' + SourceIds.MANGADEX + '）');
    }
    // 每次调用都按偏好重下发一遍可见性（幂等、纯同步读）。★ 不能只在首次注册时做：
    // 若本页在 PreferenceStore.init 之前就被 getInstance() 建起来（那时同步读只能拿到缺省值），
    // 首次分支就再也不会进来，而 DataBootstrap:41 那次 initBuiltIn 正是唯一能纠正它的时机。
    this.applyPrefs();
    Logger.i('内置图源可见：' + this.visibleBuiltInList().length + ' / ' + this.builtInIds.length);
  }

  /** 内置源全量（插件管理页那一节的行来源，含被关掉的）。 */
  builtInList(): SourceInfo[] {
    const out: SourceInfo[] = [];
    for (let i = 0; i < this.builtInIds.length; i++) {
      const s: MangaSource | undefined = this.sources.get(this.builtInIds[i]);
      if (s !== undefined) {
        out.push(s.info());
      }
    }
    return out;
  }

  /** 内置源里当前开着的那些（只用于启动日志这类汇总口径）。 */
  visibleBuiltInList(): SourceInfo[] {
    const all: SourceInfo[] = this.builtInList();
    const out: SourceInfo[] = [];
    for (let i = 0; i < all.length; i++) {
      if (!this.hidden.has(all[i].id)) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /** 某源是否开着（不在册的 id 一律回 false）。 */
  isEnabled(id: string): boolean {
    return this.sources.has(id) && !this.hidden.has(id);
  }

  /**
   * 按偏好把内置源的可见性重下发一遍（同步读，缺失 = 未启用）。幂等，可反复调。
   * 之所以做成独立方法而不是只写在 initBuiltIn 里：万一有调用点在 PreferenceStore.init 之前
   * 就摸过 SourceManager.getInstance()（那时同步读只能拿到缺省值），数据层就绪后再调一次
   * 就能把状态纠正回来。
   */
  applyPrefs(): void {
    const ps: PreferenceStore = PreferenceStore.getInstance();
    for (let i = 0; i < this.builtInIds.length; i++) {
      const id: string = this.builtInIds[i];
      const on: boolean = ps.getBool(PrefKeys.sourceEnabledKey(id), false);
      if (on) {
        this.hidden.delete(id);
      } else {
        this.hidden.add(id);
      }
    }
  }

  /**
   * 开/关某个**内置**图源（插件管理页那一枚开关的后端）。
   * 口径与 PluginStore.setEnabled 一致：**先落盘、落盘成功才改内存态**，写失败返回 false
   * 让调用方保持 UI 原状，不出现「显示已开启但重启后又关了」。
   *
   * ★ 只接受内置源 id，插件源一律返回 false —— 不是偷懒，是防一份状态两个真相：
   *   插件的启用态由 PluginStore 的 installed.json 记录（那里还带着文件缺失、装载结果等一堆状态），
   *   而本方法的偏好位只在 applyPrefs 里按 builtInIds 回放。若允许这里给插件源写偏好位，
   *   就会出现「盘上插件是启用的、内存里却被藏了、重启又自己冒出来」这种查都查不出来的分裂。
   *   插件的开关请走 PluginStore.setEnabled + PluginSourceRegistry.unregisterOne 那条既有通路。
   */
  async setEnabled(id: string, enabled: boolean): Promise<boolean> {
    if (this.builtInIds.indexOf(id) < 0) {
      return false;
    }
    if (!this.sources.has(id)) {
      return false;
    }
    await PreferenceStore.getInstance().putBool(PrefKeys.sourceEnabledKey(id), enabled);
    if (enabled) {
      this.hidden.delete(id);
    } else {
      this.hidden.add(id);
    }
    Logger.i('图源开关：' + id + ' → ' + (enabled ? '启用' : '停用'));
    return true;
  }

  /**
   * 诊断面板 25 号行（s52，INFO 不计入判定）：内置图源开关的现场读数。
   * 为什么需要它：这一枚开关的落点是 preferences，出问题时「UI 显示开着但来源条里没有」和
   * 「偏好里其实是 false」两种病因在界面上完全一样；把在册数 / 可见数 / 每源的内存态与盘上值
   * 并排打出来，一眼就能分清是内存态没同步（内存 true 盘上 false = applyPrefs 没跑对）
   * 还是本来就该关着（两边都 false = 正常）。
   * 只输出计数与 id，不输出任何 URL / 凭据。
   */
  diagHint(): string {
    const ps: PreferenceStore = PreferenceStore.getInstance();
    let s: string = 'reg=' + this.order.length + ' vis=' + this.visibleList().length
      + ' bi=' + this.builtInIds.length + ' biVis=' + this.visibleBuiltInList().length
      + ' done=' + (this.builtInDone ? 1 : 0);
    for (let i = 0; i < this.builtInIds.length; i++) {
      const id: string = this.builtInIds[i];
      s += ' | ' + id + ' mem=' + (this.isEnabled(id) ? 1 : 0)
        + ' disk=' + (ps.getBool(PrefKeys.sourceEnabledKey(id), false) ? 1 : 0);
    }
    return s;
  }
}
