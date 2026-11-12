/**
 * 职责：云收藏同步引擎 —— 把「插件源站账号里的云端收藏」拉到本地书架。
 *       对应 report.txt 第 11 条（2026-11-12）：在插件内登录账号后，自动同步该源站云端收藏至本地。
 * 依赖：data/source/SourceManager + PluginSourceAdapter（callExt 通用 fnPath 通道）、
 *       data/db/MangaRepository（落库）、data/kv/PreferenceStore（记住上次同步时间与条数）。
 * 对应 Flutter：上游本体的云端收藏是**场景包**（comicListSceneBundle）协议，UI 直接渲染 scene。
 *       鸿蒙端不做通用 scene 渲染器，改为「取列表 → 落本地书架」：与用户要求的「同步至本地」一致，
 *       也避免为四个插件再造一套 scene 渲染层（2026-11-12 普查 21 个包：5 个有场景包声明）。
 * 约束（三条硬口径）：
 *  - **不硬编码插件名**：列表函数名从插件自己的 getCloudFavoriteSceneBundle 里取（四级回退链，
 *    照抄上游 Breeze 的 scene.fnPath 取法）；取不到才回退两个候选名逐个试。
 *  - **只做单向（站端 → 本地）**：不把本地书架推回站端（上游 start/continueFavoriteAction 未接）。
 *  - 列表项解析复用 PluginSourceAdapter.itemsToSummaries（唯一权威，别处不再写一遍字段兜底顺序）。
 * 依据系统 Kit：无（仅 util + data 层）。
 */

import { SourceManager } from '../source/SourceManager';
import { PLUGIN_SOURCE_PREFIX, PluginSourceAdapter } from '../source/PluginSourceAdapter';
import { MangaRepository } from '../db/MangaRepository';
import { PreferenceStore } from '../kv/PreferenceStore';
import { MangaSummary, SourceInfo } from '../model/Models';
import { jstr, jobj, jbool, jhas, jisEmpty } from '../../util/JsonUtil';
import { Logger } from '../../util/Logger';

/** 场景包声明函数：插件没实现它就直接抛 route not found，属预期路径。 */
const SCENE_BUNDLE_FN: string = 'getCloudFavoriteSceneBundle';
/**
 * 拿不到场景包声明时的回退候选（2026-11-12 从 CDN 拉真包普查到的两个实际函数名）。
 * s11 第 2/3 条：**只在用户点「开始同步」时才拿来懒探**（见 resolveFnPath），绝不进进页探测路径 ——
 * 这两个函数是真的去站端取收藏首页（走网络），把它们放进进页探测就是「重新检查一直转」的成因。
 */
const CANDIDATE_FNS: string[] = ['getCloudFavoriteData', 'getFavoriteData'];
/** 探测超时：只覆盖「场景包声明」这一次本地调用（插件自己回一个描述对象，不发网络）。 */
const PROBE_TIMEOUT_MS: number = 8000;
/** 懒探（候选函数）超时：比进页探测宽，因为这一步确实要等站端回第一页。 */
const LAZY_PROBE_TIMEOUT_MS: number = 12000;
/** 同步总超时与翻页上限：宁可少同步也别把应用挂死。 */
const SYNC_TIMEOUT_MS: number = 180000;
const MAX_PAGES: number = 20;
/** 整批能力探测上限（CloudPage 侧也按这个值估文案）。旧版在页面里声明了却没接上 = 整批没有上限。 */
const PROBE_BATCH_MS: number = 12000;
/** 上次同步时间与条数的键前缀（breeze_prefs 里）。 */
const SYNC_AT_PREFIX: string = 'cloudSyncAt:';
const SYNC_N_PREFIX: string = 'cloudSyncCount:';

/** fnPath 入参：必带 extern（PLUGIN_PORT 24 章入参契约：缺键插件不报错但拿不到东西）。 */
export class CloudFavoriteArg {
  page: number = 1;
  extern: ESObject = JSON.parse('{}');
  /** 收藏夹 id：插件侧读到空串即「全部」（绅士 getCloudFavoriteData 实测语义）。 */
  folderId: string = '';
}

/** 单个源站的云收藏能力。 */
export class CloudCapability {
  /** 图源 id（plugin: 前缀）。 */
  sourceId: string = '';
  /** 展示名（图源清单名）。 */
  name: string = '';
  /** 该源站是否支持云收藏。 */
  supported: boolean = false;
  /** 实际使用的列表函数名。 */
  fnPath: string = '';
  /**
   * 判定依据：scene-bundle / scene-no-fnpath / scene-missing / timeout / no-adapter / pending（整批占位）。
   * **timeout 与 scene-missing 必须分开**：前者是「这次没答上」，后者是「这插件确实没这能力」。
   * 混在一起 = 「重新检查」对白等的插件永远翻不了案（timeout 的结果不进缓存，就是为了可重试）。
   */
  via: string = '';
}

/** 一次同步的结果。 */
export class CloudSyncResult {
  ok: boolean = false;
  /** 抓到并写进书架的条数（含已在书架的）。 */
  synced: number = 0;
  /** 本次新增（之前不在书架）的条数。 */
  added: number = 0;
  /** 翻了几页。 */
  pages: number = 0;
  /** 是否翻到站端末尾。 */
  reachedEnd: boolean = false;
  err: string = '';
}

export class CloudFavoriteSync {
  /** 探测结果缓存（进程内）：反复进出不重复探测。key = sourceId。 */
  private static probeCache: Map<string, CloudCapability> = new Map<string, CloudCapability>();

  /** 清探测缓存（插件装卸或启用状态变化后调）。 */
  static forgetProbes(): void {
    CloudFavoriteSync.probeCache.clear();
  }

  /** 插件图源（顺序 = 图源表顺序 = 发现页 chip 顺序）。 */
  private static pluginSources(): SourceInfo[] {
    const all: SourceInfo[] = SourceManager.getInstance().list();
    const out: SourceInfo[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].id.indexOf(PLUGIN_SOURCE_PREFIX) === 0) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /** 取适配器（不在图源表、或非插件适配器 → null，不抛）。 */
  static adapterOf(sourceId: string): PluginSourceAdapter | null {
    if (sourceId.indexOf(PLUGIN_SOURCE_PREFIX) !== 0) {
      return null;
    }
    const s = SourceManager.getInstance().get(sourceId);
    if (s === null) {
      return null;
    }
    if (!(s instanceof PluginSourceAdapter)) {
      return null;
    }
    return s as PluginSourceAdapter;
  }

  /**
   * 从场景包里取列表函数名（四级回退链，照抄上游 Breeze 的取法）：
   * scene.list.fnPath / list.fn_path / body.request.fnPath / body.request.fn_path / scene.fnPath / scene.fn_path
   */
  private static fnPathOfScene(root: ESObject): string {
    const data: ESObject = jobj(root, 'data');
    let scene: ESObject = jobj(data, 'scene');
    if (jisEmpty(scene)) {
      scene = jobj(root, 'scene');
    }
    const list: ESObject = jobj(scene, 'list');
    const req: ESObject = jobj(jobj(scene, 'body'), 'request');
    const cands: string[] = [
      jstr(list, 'fnPath', ''), jstr(list, 'fn_path', ''),
      jstr(req, 'fnPath', ''), jstr(req, 'fn_path', ''),
      jstr(scene, 'fnPath', ''), jstr(scene, 'fn_path', '')
    ];
    for (let i = 0; i < cands.length; i++) {
      if (cands[i].length > 0) {
        return cands[i];
      }
    }
    return '';
  }

  /** 带超时的等待：探测与同步都靠它兜底，插件挂住不会拖死 UI。 */
  private static withTimeout<T>(p: Promise<T>, ms: number, tag: string): Promise<T> {
    return new Promise<T>((resolve: (v: T) => void, reject: (e: Error) => void) => {
      const timer: number = setTimeout(() => {
        reject(new Error(tag + '超时（' + Math.floor(ms / 1000) + ' 秒）'));
      }, ms);
      p.then((v: T) => {
        clearTimeout(timer);
        resolve(v);
      }).catch((e: Error) => {
        clearTimeout(timer);
        reject(e);
      });
    });
  }

  /**
   * 探测单个源站是否支持云收藏，并给出该用的函数名。
   * 顺序：场景包声明（不调业务网络，插件只回一个描述对象）→ 两个候选函数名。
   */
  static async probe(sourceId: string): Promise<CloudCapability> {
    const hit: CloudCapability | undefined = CloudFavoriteSync.probeCache.get(sourceId);
    if (hit !== undefined) {
      return hit;
    }
    const cap: CloudCapability = new CloudCapability();
    cap.sourceId = sourceId;
    const ad: PluginSourceAdapter | null = CloudFavoriteSync.adapterOf(sourceId);
    if (ad === null) {
      cap.via = 'no-adapter';
      return cap;
    }
    cap.name = ad.displayName;
    try {
      const empty: CloudFavoriteArg = new CloudFavoriteArg();
      const scene: ESObject = await CloudFavoriteSync.withTimeout<ESObject>(
        ad.callExt('读取云收藏声明', SCENE_BUNDLE_FN, empty), PROBE_TIMEOUT_MS, '声明读取');
      cap.fnPath = CloudFavoriteSync.fnPathOfScene(scene);
      if (cap.fnPath.length > 0) {
        cap.supported = true;
        cap.via = 'scene-bundle';
        CloudFavoriteSync.probeCache.set(sourceId, cap);
        return cap;
      }
      cap.via = 'scene-no-fnpath';
    } catch (err) {
      const msg: string = (err as Error).message;
      if (msg.indexOf('超时') >= 0) {
        // 白等一档：声明读取也有上限（PROBE_TIMEOUT_MS），挂住的插件到此为止。
        // **故意不进 probeCache**：进了缓存就等于把「这次没答上」永久判成「不支持」，
        // 用户点「重新检查」也永远翻不了案。
        cap.via = 'timeout';
        Logger.w('云收藏声明超时：' + sourceId + ' → ' + msg);
        return cap;
      }
      // 未实现该函数的插件在这里抛（route not found）= 预期路径，只降级不报错，可以缓存住。
      cap.via = 'scene-missing';
      Logger.d('云收藏声明不可用：' + sourceId + ' → ' + msg);
    }
    // s11 第 2/3 条：进页探测到此为止 —— 不再拿 CANDIDATE_FNS 去真取收藏（那是走网络的）。
    // 没声明的插件交给 resolveFnPath 在「点同步」那一刻懒探，进页面因此永远不会卡在网络上。
    CloudFavoriteSync.probeCache.set(sourceId, cap);
    return cap;
  }

  /**
   * 懒探列表函数名（**只在点同步时调**）：拿 CANDIDATE_FNS 真取一次首页。
   * 与旧版进页探测的区别就一条：这一步用户已经明确要同步了，等站端是应该的。
   * 返回空串 = 两个候选都不存在；真错误（未登录/网络）返回该候选名，让 sync 去抛原文。
   */
  static async resolveFnPath(sourceId: string): Promise<string> {
    const ad: PluginSourceAdapter | null = CloudFavoriteSync.adapterOf(sourceId);
    if (ad === null) {
      return '';
    }
    for (let i = 0; i < CANDIDATE_FNS.length; i++) {
      const fn: string = CANDIDATE_FNS[i];
      try {
        const a: CloudFavoriteArg = new CloudFavoriteArg();
        await CloudFavoriteSync.withTimeout<ESObject>(ad.callExt('探测云收藏', fn, a),
          LAZY_PROBE_TIMEOUT_MS, '云收藏探测');
        return fn;
      } catch (err) {
        const msg: string = (err as Error).message;
        if (msg.indexOf('not found') < 0 && msg.indexOf('route') < 0) {
          return fn;
        }
      }
    }
    return '';
  }

  /**
   * 列出所有插件源站及其云收藏能力。
   * s11 第 2 条：旧版逐个 await ⇒ N 个源串成 N×超时，装得多就一直转。现在**并行**发起，
   * 外加一层整批硬上限（PROBE_BATCH_MS —— 旧版页面里那份 40000 声明了没人用 = 整批没有上限），
   * 到点交**已完成的部分结果**（旧版到点什么都没有）。
   */
  static probeAll(timeoutMs: number): Promise<CloudCapability[]> {
    return new Promise<CloudCapability[]>((resolve: (v: CloudCapability[]) => void) => {
      const srcs: SourceInfo[] = CloudFavoriteSync.pluginSources();
      if (srcs.length === 0) {
        resolve([]);
        return;
      }
      // 先按源顺序占位，谁先回谁占自己的格子 ⇒ 交出去的结果顺序仍 = 图源表顺序
      const out: CloudCapability[] = [];
      for (let i = 0; i < srcs.length; i++) {
        const ph: CloudCapability = new CloudCapability();
        ph.sourceId = srcs[i].id;
        ph.via = 'pending';
        out.push(ph);
      }
      let timer: number = -1;
      let finished: boolean = false;
      const finish = (): void => {
        if (finished) {
          return;
        }
        finished = true;
        if (timer >= 0) {
          clearTimeout(timer);
        }
        resolve(out);
      };
      timer = setTimeout((): void => {
        Logger.w('云收藏能力探测整批超时，交部分结果');
        finish();
      }, timeoutMs);
      let done: number = 0;
      for (let i = 0; i < srcs.length; i++) {
        const idx: number = i;
        CloudFavoriteSync.probe(srcs[idx].id).then((cap: CloudCapability): void => {
          out[idx] = cap;
          done += 1;
          if (done >= srcs.length) {
            finish();
          }
        }).catch((err: Error): void => {
          Logger.ex('云收藏探测异常 ' + srcs[idx].id, err as Object);
          done += 1;
          if (done >= srcs.length) {
            finish();
          }
        });
      }
    });
  }

  /** 兼容旧调用点的名字：整批上限走 PROBE_BATCH_MS。 */
  static listCapabilities(): Promise<CloudCapability[]> {
    return CloudFavoriteSync.probeAll(PROBE_BATCH_MS);
  }

  /** 上次同步时间（毫秒；0 = 从未）。 */
  static lastSyncAt(sourceId: string): number {
    return PreferenceStore.getInstance().getInt(SYNC_AT_PREFIX + sourceId, 0);
  }

  /** 上次同步条数（-1 = 从未）。 */
  static lastSyncCount(sourceId: string): number {
    return PreferenceStore.getInstance().getInt(SYNC_N_PREFIX + sourceId, -1);
  }

  private static async rememberSync(sourceId: string, count: number): Promise<void> {
    const ps: PreferenceStore = PreferenceStore.getInstance();
    if (!ps.isReady()) {
      return;
    }
    try {
      await ps.putInt(SYNC_AT_PREFIX + sourceId, Date.now());
      await ps.putInt(SYNC_N_PREFIX + sourceId, count);
    } catch (err) {
      Logger.ex('写入云收藏同步时间失败', err as Object);
    }
  }

  /**
   * 同步一个源站的云端收藏到本地书架。
   * 落库全走 MangaRepository.addToBookshelf（内部先 upsertManga 再写 bookshelf，
   * 已在书架的保留原 added_at ⇒ 重复同步不会把书架排序打乱）。
   * 未登录时插件自己抛「请先登录账号密码」，原样透给页面显示。
   */
  static async sync(sourceId: string, onPage: (done: number, pages: number) => void): Promise<CloudSyncResult> {
    const res: CloudSyncResult = new CloudSyncResult();
    const cap: CloudCapability = await CloudFavoriteSync.probe(sourceId);
    // 声明里没有函数名（或压根没声明）⇒ 这一刻才懒探候选名：用户已经点了同步，等站端是应该的。
    let fn: string = cap.fnPath;
    if (fn.length === 0) {
      fn = await CloudFavoriteSync.resolveFnPath(sourceId);
    }
    if (fn.length === 0) {
      res.err = (cap.name.length > 0 ? cap.name : '该图源') + ' 的插件没有提供云端收藏';
      return res;
    }
    const ad: PluginSourceAdapter | null = CloudFavoriteSync.adapterOf(sourceId);
    if (ad === null) {
      res.err = '图源已不在内存，请先在插件管理里启用它';
      return res;
    }
    const repo: MangaRepository = MangaRepository.getInstance();
    const seen: Map<string, boolean> = new Map<string, boolean>();
    // 外传游标原样递回：插件用它带分页与风控上下文（哔咔还带 sort）。
    let extern: ESObject = JSON.parse('{}');
    try {
      const run: Promise<void> = (async (): Promise<void> => {
        for (let page = 1; page <= MAX_PAGES; page++) {
          const a: CloudFavoriteArg = new CloudFavoriteArg();
          a.page = page;
          a.extern = extern;
          const root: ESObject = await ad.callExt('拉取云端收藏', fn, a);
          const items: MangaSummary[] = PluginSourceAdapter.itemsToSummaries(root, sourceId);
          res.pages = page;
          const nx: ESObject = jobj(root, 'extern');
          if (!jisEmpty(nx)) {
            extern = nx;
          }
          for (let i = 0; i < items.length; i++) {
            const m: MangaSummary = items[i];
            if (seen.has(m.id)) {
              continue;
            }
            seen.set(m.id, true);
            // isInBookshelf 只按 manga_id 判（bookshelf 主键 = manga_id，跨源同款视为同一条）。
            if (!(await repo.isInBookshelf(m.id))) {
              res.added += 1;
            }
            await repo.addToBookshelf(m);
            res.synced += 1;
          }
          onPage(res.synced, res.pages);
          if (CloudFavoriteSync.reachedMax(root) || items.length === 0) {
            res.reachedEnd = true;
            return;
          }
        }
      })();
      await CloudFavoriteSync.withTimeout<void>(run, SYNC_TIMEOUT_MS, '云收藏同步');
      res.ok = true;
      await CloudFavoriteSync.rememberSync(sourceId, res.synced);
      Logger.i('云收藏同步完成 ' + sourceId + ' 条数=' + res.synced + ' 新增=' + res.added + ' 页数=' + res.pages
        + ' 到底=' + (res.reachedEnd ? 'yes' : 'no'));
    } catch (err) {
      res.err = (err as Error).message;
      Logger.ex('云收藏同步失败 ' + sourceId, err as Object);
    }
    return res;
  }

  /**
   * 是否已到站端末尾：hasReachedMax 三处兜底（2026-11-12 两个真实包形态不同）
   *  - 绅士 data.hasReachedMax
   *  - 哔咔 data.paging.hasReachedMax，且根级再镜像一份 paging/items
   */
  private static reachedMax(root: ESObject): boolean {
    const data: ESObject = jobj(root, 'data');
    if (CloudFavoriteSync.flagOf(data)) {
      return true;
    }
    const rp: ESObject = jobj(root, 'paging');
    if (CloudFavoriteSync.flagOf(rp)) {
      return true;
    }
    return CloudFavoriteSync.flagOf(jobj(data, 'paging'));
  }

  /** 对象上若有 hasReachedMax 键则按其布尔值返回，没有该键 = false（不能当「到底」）。 */
  private static flagOf(o: ESObject): boolean {
    if (!jhas(o, 'hasReachedMax')) {
      return false;
    }
    return jbool(o, 'hasReachedMax', false);
  }
}
