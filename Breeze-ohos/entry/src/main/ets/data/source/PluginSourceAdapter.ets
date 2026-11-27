/**
 * 职责：把「已落盘的 .bundle.cjs 插件」适配成宿主 MangaSource（G1）。发现页图源 chip 即由此而来。
 * 约定（三条口径 + runner6.cjs 实测）：
 *  - info() 只用清单静态信息（uuid/name），**绝不触发装载**（chip 条同步渲染，装载是异步的）。
 *  - 懒装载：首个取数方法才 bundleLoadFromPath；bundleList 查重避免重复 loadBundle（整体替换语义会洗掉插件内存态）。
 *  - 页基：宿主 1 基；ranking 统一发 page-1（JM getRankingData 0 基；MD 1 基内部钳 ≥1，实测首页一致）。
 *  - searchComic 直接发 1 基 page（两家 search 均 1 基，实测）。
 *  - 章节统一走 getComicDetail 的 data.normal.eps（JM getChapter 响应里没有 chapters 列表 = 实测）；
 *    标题直接用 eps.name，不再叠加「第N话」前缀。
 *  - fetchPages→getChapter({chapterId,comicId})：comicId 从 fetchChapters/fetchDetail 的缓存补齐
 *    （MD 空 comicId 实测不抛但会打日志降级，补上更干净）；**空页表必须转中文 Error 抛给阅读器**。
 *  - 失败一律抛可直接展示的中文 Error（Source.ets 契约）；JSON 解析全走 JsonUtil 防御式取值。
 * 依据系统 Kit：无（仅 util + data 层）。
 */
import { MangaSource, SearchPageResult } from './Source';
import { MangaSummary, ChapterInfo, PageImage, SourceInfo } from '../model/Models';
import { bundleCall, bundleCallBytes, bundleLoadFromPath, bundleList, BytesResult } from '../../util/PluginRuntime';
import { PluginInit } from '../../util/PluginInit';
import { JmRaceDiag } from '../../util/JmRaceDiag';
import { jparse, jstr, jobj, jarr, jstrArr, jisEmpty, jint, jbool } from '../../util/JsonUtil';
import { Logger } from '../../util/Logger';

/** 图源 id 前缀：plugin:<清单 uuid>。 */
export const PLUGIN_SOURCE_PREFIX: string = 'plugin:';

/**
 * 取图哨兵地址的路径尾段（s17 第 5 条）。e-hentai 0.1.6 的常量 j/v 就是这两串：
 *   j = '/_breeze/read-image'、v = '/_breeze/preview-image'，页对象的 url 字段被写成
 *   new URL(j, origin) ⇒ 整章每页 url 逐字节相同。判定只按路径尾段（不看 host、不看查询串），
 *   因为宿主手里能看到的只有这个地址本身。命中它且手里没 extern = 必挂，提前给出中文真因。
 */
const DEFERRED_IMAGE_PATHS: string[] = ['/_breeze/read-image', '/_breeze/preview-image'];

function isDeferredImageUrl(url: string): boolean {
  if (url.length === 0) {
    return false;
  }
  for (let i = 0; i < DEFERRED_IMAGE_PATHS.length; i++) {
    if (url.endsWith(DEFERRED_IMAGE_PATHS[i])) {
      return true;
    }
  }
  return false;
}

/**
 * ★ 上游 unified_comic_plugin.dart:28 `payload = {...core, 'extern': extern ?? const {}}`
 *   ⇒ **每个 fnPath 的入参对象里必定有 extern 键**（缺省空对象）。插件普遍写
 *   `async function (args = {})` 后直接读 `args.extern`，缺键不会报错但拿不到东西；
 *   更要紧的是页表/评论的 extern 是插件自己的游标与风控上下文，宿主必须原样递回去。
 *   所以下面每个 Arg 类都带 extern 字段 —— 别删。
 */
/** searchComic 入参（类实例 → JSON.stringify，ArkTS 禁裸对象字面量当值用）。 */
class SearchArg {
  keyword: string = '';
  page: number = 1;
  extern: ESObject = JSON.parse('{}');
}

/** getRankingData 入参（宿主已换算过的页码）。 */
class RankingArg {
  page: number = 0;
  extern: ESObject = JSON.parse('{}');
}

/** getComicDetail 入参。 */
class ComicIdArg {
  comicId: string = '';
  extern: ESObject = JSON.parse('{}');
}

/** getChapter 入参。 */
class ChapterArg {
  chapterId: string = '';
  comicId: string = '';
  extern: ESObject = JSON.parse('{}');
}

/**
 * fetchImageBytes 入参（无 extern 版）。**刻意保留两类**而不是给 ImageArg 加一个可选字段：
 * ArkTS 里给类加字段 = 所有实例的 JSON 都会多一个键，而无 needs-extern 的插件（JM / 哔咖 /
 * 包子 ... 本机九个载荷实测 _breeze/ 与 imagePageHref 全 0 命中）收到的字节就会变,
 * 回归面铺满全部图源。分成两类后「没有 extern」这条最常见的路逐字节不变。
 */
class ImageArg {
  url: string = '';
  timeoutMs: number = 30000;
}

/**
 * fetchImageBytes 入参（带 extern 版，s17 第 5 条）。对齐上游 picture.dart:628-634：
 *   final externPayload = <String,dynamic>{...extern}; ... if (externPayload.isNotEmpty) args["extern"] = externPayload;
 * 即**非空才写**这个键，空对象不写 —— 与插件侧 a.extern 缺省 {} 的读法一致。
 * 键序 url / timeoutMs / extern 与上游 args 的构造顺序相同。
 */
class ImageExternArg {
  url: string = '';
  timeoutMs: number = 30000;
  extern: ESObject = JSON.parse('{}');
}

/** 从 unknown 异常提取 message 原文（同 Index.ets:86 已验证写法）。 */
function errText(e: Object): string {
  // s37 红队取证：`throw undefined` / `throw null` 时 `e as Error` 仍是空值，下读 `.message`
  // 会在 catch 里**二次抛** TypeError 把原错误顶掉。同病四份（本文件 / PluginSettings.ets:177 em /
  // ImageCache.ets:110 errBrief / PluginLoginPage.ets:393 errText），四份必须一起改，否则造新分叉。
  if (e === null || e === undefined) {
    return String(e);
  }
  const x = e as Error;
  const m = x.message;
  if (typeof m === 'string' && m.length > 0) {
    return m;
  }
  return String(e);
}

export class PluginSourceAdapter implements MangaSource {
  /** 清单 uuid（= bundle 装载名）。 */
  readonly uuid: string;
  /** 展示名（清单静态信息；空则文件名派生）。 */
  readonly displayName: string;
  /** filesDir/plugins 下的文件名。 */
  readonly localFile: string;
  /** 插件文件绝对路径（filesDir/plugins/<localFile>，懒装载用）。 */
  readonly absPath: string;
  private loaded: boolean = false;
  private loading: Promise<void> | null = null;
  /** chapterId → mangaId 缓存（fetchPages 补 comicId 用；容量粗限 256）。 */
  private chapterComic: Map<string, string> = new Map<string, string>();

  /**
   * ChapterInfo.id → 插件 getChapter 真正要的那个值（s15 第 1 条，只在两者不同时登记，容量同样 256）。
   * 为什么要这枚表：插件 eps 自己给了四个可用键（id / requestId / logicalKey / storageChapterId），
   * 而宿主只把 eps.id 装进 ChapterInfo（Models.ets 那个接口没有别的位置）。多数插件四者同值所以无嫌，
   * 唯独哔咖（picacomic 0.1.1）的 eps.id = Mongo _id，它的 getChapter 把 chapterId 当 order 用：
   * Number(_id) 得 NaN 再取默认 0，校验处直接抛「chapterId 不能为空」，0 次 HTTP 就失败
   * ＝用户看到的「进去直接无法加载 + 重试，根本无法切下一页」。它自己的 requestId = String(order)。
   *
   * 两条刻意的设计（别改成省事的写法）：
   *  ① **不把归一后的值写进 ChapterInfo.id**。DetailPage 用 progress.chapterId === c.id 判「读至第几页」，
   *    且 fetchChapters 成功就 saveChapters 落库（DB 主键 chapter_id）⇒ 改 id 会让存量章节行与阅读进度同时失配。
   *    所以对外（UI / DB / 路由参数）恒用 id，只有对插件发请求这一跳换成 out 值。
   *  ② **只在 requestId 非空且与 id 不同时才登记**。禁漫 / Mangadex / 漫茶魂 / jjmhw 四者同值、
   *    在猫漢无 requestId ⇒ 这张表对它们根本是空的，发出的字符串逐字节不变，不存在回归面。
   */
  private chapterOutKey: Map<string, string> = new Map<string, string>();

  /**
   * s17 第 5 条诊断计数（进程累计，与 ImageCache 那批计数同样口径，没有复位路径）：
   * extMissing = 地址是取图哨兵而手里没有 extern（= 页表 ext 没能传到取图点，链路断在中间）；
   * extBad = 页表带了 extern 但 JSON.parse 不动；lastExtErr 只记形态不记内容。
   */
  static extMissing: number = 0;
  static extBad: number = 0;
  static lastExtErr: string = '';

  /** 诊断串（面板 16 号行 imageChain 末尾追加）：无异常时返回空串，不占屏宽。 */
  static externHint(): string {
    if (PluginSourceAdapter.extMissing === 0 && PluginSourceAdapter.extBad === 0) {
      return '';
    }
    return ' extMiss=' + PluginSourceAdapter.extMissing + ' extBad=' + PluginSourceAdapter.extBad
      + (PluginSourceAdapter.lastExtErr.length > 0 ? ' extErr=' + PluginSourceAdapter.lastExtErr : '');
  }

  constructor(uuid: string, displayName: string, localFile: string, filesDir: string) {
    this.uuid = uuid;
    this.displayName = displayName;
    this.localFile = localFile;
    this.absPath = filesDir + '/plugins/' + localFile;
  }

  /** chip 描述：纯清单静态信息，零装载（红线）。 */
  info(): SourceInfo {
    const s: SourceInfo = {
      id: PLUGIN_SOURCE_PREFIX + this.uuid,
      name: this.displayName,
      language: 'zh'
    };
    return s;
  }

  // ---------------- 懒装载 ----------------

  private async loadOnce(): Promise<void> {
    let already: boolean = false;
    try {
      const lst: string[] = await bundleList();
      for (let i = 0; i < lst.length; i++) {
        if (lst[i] === this.uuid) {
          already = true;
        }
      }
    } catch (e) {
      // bundleList 失败按未装载处理（loadBundle 幂等覆盖）
    }
    if (!already) {
      const ret: string = await bundleLoadFromPath(this.uuid, this.absPath);
      if (ret !== 'ok') {
        throw new Error('bundleLoadFromPath 返回 "' + ret + '"');
      }
      Logger.i('插件图源首次装载：' + this.displayName + ' (' + this.uuid + ')');
      // 懒装载 = 启动链（PluginAutoLoader）没覆盖到的件，首次取数才进引擎 ⇒ 这里补一次 init
      PluginInit.mark(this.uuid);
    }
    this.loaded = true;
  }

  private async ensureLoaded(action: string): Promise<void> {
    if (this.loaded) {
      return;
    }
    const pending: Promise<void> | null = this.loading;
    if (pending !== null) {
      try {
        await pending;
      } catch (e) {
        throw new Error(action + '：装载插件失败：' + errText(e as Object));
      }
      return;
    }
    const p: Promise<void> = this.loadOnce();
    this.loading = p;
    try {
      await p;
    } catch (e) {
      throw new Error(action + '：装载插件失败：' + errText(e as Object));
    } finally {
      this.loading = null;
    }
  }

  /** 装载后调用 bundleCall，异常统一包成「<action>（fnPath）：<原错>」。 */
  private async call(action: string, fnPath: string, arg: Object): Promise<ESObject> {
    await this.ensureLoaded(action);
    // s50 修①（治「排行榜首次点击必失败」）：本插件的 init 还在飞时有界等它落地（上限 12 s，
    // 见 PluginInit.INIT_WAIT_MS 的真机依据），落地/未导出/从未 mark 都零开销立即返回。
    // 只记不拦：等完不管成败都照常发请求，超时保留原报错面 —— 等待本身不制造新错误。
    // 真机 s49 双报告的 pf 段 init=run ∧ age=-1（t=823ms 打到死回退域拿 nginx 404）就是这条冷窗。
    await PluginInit.awaitInitReady(this.uuid);
    let raw: string = '';
    try {
      raw = await bundleCall(this.uuid, fnPath, JSON.stringify([arg]));
    } catch (e) {
      throw new Error(action + '（' + fnPath + '）：' + errText(e as Object));
    }
    const o: ESObject = jparse(raw);
    if (jisEmpty(o)) {
      throw new Error(action + '（' + fnPath + '）：插件返回无法解析的 JSON');
    }
    return o;
  }

  // ---------------- 映射（runner6.cjs mirror 六函数的 ArkTS 版，改一边同步另一边） ----------------

  /** metadata[type in types] → ' / ' 连接的值串；无则 ''。 */
  private static metaValue(item: ESObject, type: string): string {
    const md: ESObject[] = jarr(item, 'metadata');
    for (let i = 0; i < md.length; i++) {
      if (jstr(md[i], 'type', '') !== type) {
        continue;
      }
      const vals: ESObject[] = jarr(md[i], 'value');
      const parts: string[] = [];
      for (let k = 0; k < vals.length; k++) {
        const v: ESObject = vals[k];
        let s: string = '';
        if (typeof v === 'string') {
          s = v as string;
        } else if (v !== null && v !== undefined && typeof v === 'object') {
          s = jstr(v, 'name', '');
        }
        if (s.length > 0) {
          parts.push(s);
        }
      }
      if (parts.length > 0) {
        return parts.join(' / ');
      }
    }
    return '';
  }

  /** 列表项 / 详情 comicInfo → MangaSummary（字段兜底顺序照抄 mirror；rawOverride=详情 data.raw）。 */
  private static mapItem(item: ESObject, rawOverride: ESObject | null, sourceId: string): MangaSummary {
    const raw: ESObject = rawOverride !== null ? rawOverride : jobj(item, 'raw');
    let author: string = PluginSourceAdapter.metaValue(item, 'author');
    if (author.length === 0) {
      // JM comicInfo 的 author 直接挂在 item 上（不在 raw 里）= bundle 源码实测。
      author = jstr(item, 'author', '');
    }
    if (author.length === 0) {
      author = jstr(raw, 'author', '');
    }
    if (author.length === 0) {
      author = jstrArr(raw, 'author').join(' / ');
    }
    const cover: ESObject = jobj(item, 'cover');
    const tagsSrc: string[] = [];
    const md: ESObject[] = jarr(item, 'metadata');
    for (let i = 0; i < md.length; i++) {
      const t: string = jstr(md[i], 'type', '');
      if (t === 'tags' || t === 'categories') {
        const vals: ESObject[] = jarr(md[i], 'value');
        for (let k = 0; k < vals.length; k++) {
          const v: ESObject = vals[k];
          if (typeof v === 'string') {
            tagsSrc.push(v as string);
          } else if (v !== null && v !== undefined && typeof v === 'object') {
            const nm: string = jstr(v, 'name', '');
            if (nm.length > 0) {
              tagsSrc.push(nm);
            }
          }
        }
      }
    }
    const tags: string[] = tagsSrc.slice(0, 12);
    const s: MangaSummary = {
      id: jstr(item, 'id', jstr(raw, 'id', '')),
      sourceId: sourceId,
      title: jstr(item, 'title', jstr(raw, 'name', '')),
      author: author,
      coverUrl: jstr(cover, 'url', ''),
      description: jstr(raw, 'description', jstr(item, 'description', '')),
      tags: tags
    };
    return s;
  }

  /** 列表容器：data.items 优先，退回 items（两 bundle 同构，实测）。
   *  static public：云收藏同步（data/cloud/CloudFavoriteSync）复用同一个解析器，
   *  不再造第二套字段兜底顺序（一个事实只有一个权威位置）。 */
  static itemsToSummaries(root: ESObject, sourceId: string): MangaSummary[] {
    let items: ESObject[] = jarr(jobj(root, 'data'), 'items');
    if (items.length === 0) {
      items = jarr(root, 'items');
    }
    const out: MangaSummary[] = [];
    for (let i = 0; i < items.length; i++) {
      const s: MangaSummary = PluginSourceAdapter.mapItem(items[i], null, sourceId);
      if (s.id.length > 0 && s.title.length > 0) {
        out.push(s);
      }
    }
    return out;
  }

  /**
   * 搜索分页解析（★ 与 itemsToSummaries 的区别 = 这一条要把 paging / extern 带出来）。
   * paging 位置照上游 unified_plugin_search.dart:64-66：`data.paging` 优先、退回顶层 `paging`；
   * items 同样 data.items 优先退顶层 items（与 itemsToSummaries 同一口径）。
   * ★ 判「到底」只有两条腿（★ 曾经有第三条腿「pages > 0 且 page >= pages」，s34 已删，理由见下）：
   *   ① paging.hasReachedMax == true（插件明说）
   *   ② 本页零条目（最弱信号，但插件普遍就这么表达到底）
   * ★★ 为什么不得拿 pages 与 page 比（s34 真机缺陷一的根因）：JMComic 的 searchComic 回包写的是
   *   paging:{page:f,pages:f,...}（bundle 内 f = 本次请求页码）—— 它的 pages 是 **页码的别名**、
   *   不是总页数，于是「page >= pages」在第一页就成立 ⇒ 宿主把每一源都判「到底」⇒ 底部直接显示
   *   「没有更多了」且永远不再取下一页。上游同样不看 pages：get_plugin_result.dart:34-35 只把
   *   parsed.paging.page 记成「下次取 page+1」的游标、只有 parsed.paging.hasReachedMax 参与判到底
   *   （unified_plugin_search.dart:21 `map['hasReachedMax'] == true`）。真没到底的源由插件自己回
   *   hasReachedMax=false（JM 的式子 = 空页 / 不足 80 条 / 累计条数达 total 三者之一）+ 本处 ② 兜住。
   * itemsToSummaries 里那条「id/title 双非空」过滤在这里同样生效，
   * 但**判空用原始条数**：过滤后为空而原始非空 = 数据脏，不能当成「到底」。
   */
  static parseSearchPage(root: ESObject, sourceId: string, reqPage: number): SearchPageResult {
    const r: SearchPageResult = new SearchPageResult();
    r.page = reqPage;
    const data: ESObject = jobj(root, 'data');
    let items: ESObject[] = jarr(data, 'items');
    if (items.length === 0) {
      items = jarr(root, 'items');
    }
    const pgSrc: ESObject = jisEmpty(data) ? jobj(root, 'paging') : jobj(data, 'paging');
    const pg: ESObject = jisEmpty(pgSrc) ? jobj(root, 'paging') : pgSrc;
    if (!jisEmpty(pg)) {
      const p: number = jint(pg, 'page', 0);
      if (p > 0) {
        r.page = p;
      }
      r.pages = jint(pg, 'pages', 0);
      r.hasReachedMax = jbool(pg, 'hasReachedMax', false);
    }
    const out: MangaSummary[] = [];
    for (let i = 0; i < items.length; i++) {
      const s: MangaSummary = PluginSourceAdapter.mapItem(items[i], null, sourceId);
      if (s.id.length > 0 && s.title.length > 0) {
        out.push(s);
      }
    }
    r.items = out;
    if (!r.hasReachedMax && items.length === 0) {
      r.hasReachedMax = true;
    }
    // 回包 extern（顶层，上游 get_plugin_result.dart:37）：非空对象才序列化带走。
    const ext: ESObject = jobj(root, 'extern');
    if (!jisEmpty(ext)) {
      try {
        r.extern = JSON.stringify(ext);
      } catch (e) {
        r.extern = '';
      }
    }
    return r;
  }

  private rememberChapter(mangaId: string, chapters: ChapterInfo[]): void {
    for (let i = 0; i < chapters.length; i++) {
      if (this.chapterComic.size > 256) {
        this.chapterComic.clear();
        break;
      }
      this.chapterComic.set(chapters[i].id, mangaId);
    }
  }

  // ---------------- MangaSource 实现 ----------------

  /** 发现页热门：getRankingData。页基换算见文件头（宿主 1 基 → 发 page-1）。 */
  async fetchPopular(page: number): Promise<MangaSummary[]> {
    const p1: number = Math.max(1, Math.floor(page) || 1);
    const a: RankingArg = new RankingArg();
    a.page = p1 - 1;
    // s49 取证（纯观测）：只包住这一跳 await 记耗时与失败快照，映射逻辑不动、异常原样上抛。
    // 用途 = 判「排行榜首次点击必失败」是不是落在插件 init 的冷窗口内（24 号行 jmRace 的 pf 段）。
    const t0: number = Date.now();
    let o: ESObject;
    try {
      o = await this.call('加载热门失败', 'getRankingData', a);
    } catch (e) {
      JmRaceDiag.notePopular(Date.now() - t0, PluginInit.stateOf(this.uuid),
        PluginInit.doneAgeMs(this.uuid), errText(e as Object));
      // ArkTS 禁裸重抛（10605087 arkts-limited-throw）：this.call 抛的本就是 Error，命中
      // instanceof 时抛**同一个实例**（对象身份与 message 都不变）；非 Error 才兜一层
      // new Error(errText(...))，message 仍取原 message 原文 —— 与 :241 同款写法。
      const again: Error = e instanceof Error ? e as Error : new Error(errText(e as Object));
      throw again;
    }
    JmRaceDiag.notePopularOk(Date.now() - t0);
    return PluginSourceAdapter.itemsToSummaries(o, PLUGIN_SOURCE_PREFIX + this.uuid);
  }

  /**
   * 搜索：searchComic（两家均 1 基，直接透传）。
   * 上游 get_plugin_result.dart:21-27 的 core = {keyword, page, isSearchAggregate} + extern
   * ⇒ **本轮刻意不带 isSearchAggregate**：上游只有聚合页才传 true，而 s32 之前所有真机验收
   *   都是在「无此键」的载荷上跑出来的；插件若读它（多半用来在聚合态省掉逐条富化），
   *   加键 = 改动全部 21 枚插件的已验收路径，与本次「加翻页」无关，不顺手做。
   * externJson 非空 = 回传上一页游标（上游 :37 `blocState.pluginExtern = parsed.extern`）。
   */
  async searchPage(keyword: string, page: number, externJson: string): Promise<SearchPageResult> {
    const a: SearchArg = new SearchArg();
    a.keyword = keyword;
    a.page = Math.max(1, Math.floor(page) || 1);
    if (externJson.length > 0) {
      const ext: ESObject = jparse(externJson);
      if (!jisEmpty(ext)) {
        a.extern = ext;
      }
    }
    const o: ESObject = await this.call('搜索失败', 'searchComic', a);
    return PluginSourceAdapter.parseSearchPage(o, PLUGIN_SOURCE_PREFIX + this.uuid, a.page);
  }

  /** 详情：getComicDetail → data.normal.comicInfo（raw 兜底取 data.raw，照抄 mirror）；确认不存在返回 null。 */
  async fetchDetail(id: string): Promise<MangaSummary | null> {
    const a: ComicIdArg = new ComicIdArg();
    a.comicId = id;
    const o: ESObject = await this.call('加载详情失败', 'getComicDetail', a);
    const data: ESObject = jobj(o, 'data');
    const normal: ESObject = jobj(data, 'normal');
    if (jisEmpty(normal)) {
      return null;
    }
    const info: ESObject = jobj(normal, 'comicInfo');
    if (jisEmpty(info)) {
      return null;
    }
    if (jstr(info, 'id', '').length === 0 && jstr(info, 'title', '').length === 0) {
      return null;
    }
    this.rememberManga(id);
    // mirror 同款：详情项的 raw 兜底用 data.raw（comicInfo 自身没有 raw 字段）。
    const dataRaw: ESObject = jobj(data, 'raw');
    return PluginSourceAdapter.mapItem(info, jisEmpty(dataRaw) ? null : dataRaw, PLUGIN_SOURCE_PREFIX + this.uuid);
  }

  private lastMangaId: string = '';

  private rememberManga(mangaId: string): void {
    if (mangaId.length > 0) {
      this.lastMangaId = mangaId;
    }
  }

  /** 章节列表：统一走 detail.eps（JM getChapter 无 chapters 列表 = 实测）；标题直接用 eps.name。 */
  async fetchChapters(mangaId: string): Promise<ChapterInfo[]> {
    const a: ComicIdArg = new ComicIdArg();
    a.comicId = mangaId;
    const o: ESObject = await this.call('加载章节失败', 'getComicDetail', a);
    const normal: ESObject = jobj(jobj(o, 'data'), 'normal');
    const eps: ESObject[] = jarr(normal, 'eps');
    const out: ChapterInfo[] = [];
    for (let i = 0; i < eps.length; i++) {
      const e: ESObject = eps[i];
      const id: string = jstr(e, 'id', jstr(jobj(e, 'raw'), 'id', ''));
      if (id.length === 0) {
        continue;
      }
      // s15 第 1 条：把插件自己的 requestId 留下当出口值（仅当它与 id 不同，理由见字段注释）。
      const reqId: string = jstr(e, 'requestId', '');
      if (reqId.length > 0 && reqId !== id) {
        if (this.chapterOutKey.size > 256) {
          this.chapterOutKey.clear();
        }
        this.chapterOutKey.set(id, reqId);
      }
      const t1: string = jstr(e, 'title', '');
      const t2: string = jstr(e, 'name', '');
      const t3: string = jstr(jobj(e, 'raw'), 'name', '');
      let title: string = t1;
      if (title.length === 0) {
        title = t2;
      }
      if (title.length === 0) {
        title = t3;
      }
      const c: ChapterInfo = {
        id: id,
        mangaId: mangaId,
        title: title.length > 0 ? title : ('第' + (i + 1) + '话'),
        index: i
      };
      out.push(c);
    }
    this.rememberManga(mangaId);
    this.rememberChapter(mangaId, out);
    // s49 取证（纯观测）：覆盖式记最近一次章节列表的枚数与首枚 id/title。
    // 用途 = 与页表为空那次联立判「假单章」（eps=1 且首章 id 等于作品 id ⇒ 插件伪造，见 24 号行 ch 段）。
    JmRaceDiag.noteChapters(this.uuid, mangaId, out.length,
      out.length > 0 ? out[0].id : '', out.length > 0 ? out[0].title : '');
    return out;
  }

  /**
   * 对插件发 getChapter 时的章节 id 出口映射：未登记（多数插件）= 原样返回，
   * 已登记（哔咖）= 换成它自己的 requestId。只包这一跳，对外层无任何影响。
   */
  private outChapterId(chapterId: string): string {
    const mapped: string | undefined = this.chapterOutKey.get(chapterId);
    return mapped !== undefined ? mapped : chapterId;
  }

  /** 页表：getChapter；空页表转中文 Error（阅读器契约：失败必须抛，不能空列表白屏）。 */
  async fetchPages(chapterId: string): Promise<PageImage[]> {
    const a: ChapterArg = new ChapterArg();
    a.chapterId = this.outChapterId(chapterId);
    const cached: string | undefined = this.chapterComic.get(chapterId);
    a.comicId = cached !== undefined ? cached : this.lastMangaId;
    // s49 取证（纯观测）：只记一次取数耗时与两个失败分支的现场快照，**成功路径零额外开销**
    //（rawText 的整包 stringify 只在要抛的那条路上做）。异常文案与返回语义一字未动。
    const t0: number = Date.now();
    // s50 修②（治「章节页表为空」）：空页表 / 全空地址都先补跑一次 init（端点池走缓存、
    // 登录重发把插件进程内 30 min TTL 的登录态补回来）再重试**一次**；仍然空才按原文案抛。
    // 依据 = s48/s49 取证：JM 0.1.1 的 getChapter 在登录态缺失时拿 HTTP 200 + images 缺位，
    // 插件自己不抛错 ⇒ 宿主只能看到干净的空页表；而真机「杀掉重开就自己好了」= 重登补上了 jwt。
    // kicked 是本轮局部量：每次 fetchPages 至多自愈一次，绝不做二次重试。
    let kicked: boolean = false;
    for (let round = 0; round < 2; round++) {
      const o: ESObject = await this.call('加载章节内容失败', 'getChapter', a);
      let chapter: ESObject = jobj(jobj(o, 'data'), 'chapter');
      let pages: ESObject[] = jarr(chapter, 'pages');
      if (pages.length === 0) {
        chapter = jobj(o, 'chapter');
        pages = jarr(chapter, 'pages');
      }
      if (pages.length === 0) {
        if (!kicked) {
          kicked = true;
          JmRaceDiag.noteChapterKick();
          await PluginInit.kickInit(this.uuid);
          continue;
        }
        // s49 取证：init 态与 age= 判 B2（事件早于登录生效 / 超 30 min TTL），
        // 两个 id 与 img= 判 B1（章节 id 被伪造成 albumId）。a.chapterId 是出口值、a.comicId 本就是 string。
        let rawText: string = '';
        try {
          rawText = JSON.stringify(o);
        } catch (e) {
          rawText = '';
        }
        JmRaceDiag.noteChapterEmpty(Date.now() - t0, PluginInit.stateOf(this.uuid),
          PluginInit.doneAgeMs(this.uuid), a.chapterId, a.comicId, Object.keys(o), Object.keys(chapter),
          JmRaceDiag.imgStateOf(o), JmRaceDiag.sigOf(rawText));
        throw new Error('章节页表为空（' + this.displayName + ' chapterId=' + chapterId + '）');
      }
      const out: PageImage[] = [];
      let usable: number = 0;
      for (let i = 0; i < pages.length; i++) {
        const pg: ESObject = pages[i];
        const url: string = jstr(pg, 'url', jstr(jobj(pg, 'extern'), 'url', ''));
        if (url.length > 0) {
          usable++;
        }
        // s17 第 5 条：把这一页的 extern 原样带上（空对象记空串，与「非空才透传」的出口对齐）。
        // 这是 e-hentai 这类哨兵 url 图源唯一的取图入参，也是同章各页唯一可分标识。
        const extObj: ESObject = jobj(pg, 'extern');
        let ext: string = '';
        if (!jisEmpty(extObj)) {
          try {
            ext = JSON.stringify(extObj);
          } catch (e) {
            ext = '';
          }
        }
        const p: PageImage = { index: i, url: url, ext: ext };
        out.push(p);
      }
      if (usable === 0) {
        // 全空 URL 的页表同样是白屏（JM 需要 jwt/风控时会返回这种壳），一并转中文 Error。
        // s49 取证：pages 非空 ⇒ imgState 恒按 3（数组非空，反向对照位）；同样 stringify 只走这条路。
        if (!kicked) {
          kicked = true;
          JmRaceDiag.noteChapterKick();
          await PluginInit.kickInit(this.uuid);
          continue;
        }
        let rawText2: string = '';
        try {
          rawText2 = JSON.stringify(o);
        } catch (e) {
          rawText2 = '';
        }
        JmRaceDiag.noteChapterEmpty(Date.now() - t0, PluginInit.stateOf(this.uuid),
          PluginInit.doneAgeMs(this.uuid), a.chapterId, a.comicId, Object.keys(o), Object.keys(chapter),
          3, JmRaceDiag.sigOf(rawText2));
        throw new Error('章节页表缺少图片地址（' + this.displayName + ' chapterId=' + chapterId + '）');
      }
      JmRaceDiag.noteChapterOk(out.length);
      if (kicked) {
        // 24 号行 kickOk= = 「补跑 init 之后这次读成了」的直读证据（kick= 只证明触发自愈，
        // kickOk= 才证明自愈有效；两数联立才不会把「试了但没用」读成「修好了」）。
        JmRaceDiag.noteChapterKickOk();
      }
      return out;
    }
    // 循环内两条出路必居其一（return 或 throw），这行只是编译器要的可达性兜底，文案与首分支同形。
    throw new Error('章节页表为空（' + this.displayName + ' chapterId=' + chapterId + '）');
  }

  /**
   * 通用扩展口（能力面比 MangaSource 六方法宽）：详情页的详情扩展 / 相关推荐 / 点赞 / 评论
   * 都从这里走，语义与内部 call 完全一致（懒装载 + 中文 Error）。
   * 只增不改：MangaSource 六方法的实现一行没动。
   */
  async callExt(action: string, fnPath: string, arg: Object): Promise<ESObject> {
    return this.call(action, fnPath, arg);
  }

  /** 页表带 extern（JM 反混淆要 name/type 时用；PageImage 只有 url，别把它当唯一来源）。 */
  async fetchPageRawList(chapterId: string): Promise<ESObject[]> {
    const a: ChapterArg = new ChapterArg();
    a.chapterId = this.outChapterId(chapterId);
    const cached: string | undefined = this.chapterComic.get(chapterId);
    a.comicId = cached !== undefined ? cached : this.lastMangaId;
    const o: ESObject = await this.call('加载章节内容失败', 'getChapter', a);
    let chapter: ESObject = jobj(jobj(o, 'data'), 'chapter');
    let pages: ESObject[] = jarr(chapter, 'pages');
    if (pages.length === 0) {
      chapter = jobj(o, 'chapter');
      pages = jarr(chapter, 'pages');
    }
    return pages;
  }

  /**
   * 二进制取图（bytes 通道）：阅读器经 ImageCache.loadViaPlugin 调用（带插件 Referer/风控头）。
   * kind=json 视为失败。
   */
  async fetchImageBytes(url: string, ext: string): Promise<ArrayBuffer> {
    await this.ensureLoaded('取图失败');
    // s17 第 5 条：ext 非空才写 extern 键（上游 picture.dart:632 同构）。上游之所以必须写，
    // 是因为 e-hentai 这类插件每页 url 都是同一个哨兵地址，真图页地址只在该页 extern.href 里。
    let payload: string = '';
    if (ext.length > 0) {
      const ea: ImageExternArg = new ImageExternArg();
      ea.url = url;
      ea.timeoutMs = 30000;
      try {
        ea.extern = JSON.parse(ext);
      } catch (e) {
        // ext 解析不动就退回不带 extern（等价于修复前的行为），并在诊断里钉一笔：
        // 「页表给了 extern 但形态不是 JSON」和「压根没传到 extern」是两种要分开修的缺陷。
        PluginSourceAdapter.extBad++;
        PluginSourceAdapter.lastExtErr = 'parse ' + errText(e as Object);
      }
      payload = JSON.stringify([ea]);
    } else {
      if (isDeferredImageUrl(url)) {
        // 地址是插件的取图哨兵（/_breeze/read-image 之类）而手里没有 extern ⇒ 这一张必然失败，
        // 且失败点在插件内部、0 次网络请求。钉计数 + 把真因写成中文，别让屏上只剩一句英文。
        PluginSourceAdapter.extMissing++;
        throw new Error('取图失败：该图源每页共用同一个取图地址，需要页面上下文才能取图（本次没能传达到插件）');
      }
      const a: ImageArg = new ImageArg();
      a.url = url;
      a.timeoutMs = 30000;
      payload = JSON.stringify([a]);
    }
    let r: BytesResult;
    try {
      r = await bundleCallBytes(this.uuid, 'fetchImageBytes', payload);
    } catch (e) {
      throw new Error('取图失败（fetchImageBytes）：' + errText(e as Object));
    }
    if (r.kind !== 'bytes') {
      throw new Error('取图失败（fetchImageBytes）：返回非二进制（kind=' + r.kind + '）');
    }
    return r.bytes;
  }

  /** 引擎侧是否已装载本插件（诊断/注销联动用，不触发装载）。 */
  isLoaded(): boolean {
    return this.loaded;
  }

  /**
   * 强制重载（更新落盘后用）：loadBundle 是整体替换语义，会把磁盘上的新文件重新装进同名槽。
   * 未装载过则只清标志，下次取数自然装新文件。
   */
  async reload(): Promise<void> {
    this.loaded = false;
    this.loading = null;
    const ret: string = await bundleLoadFromPath(this.uuid, this.absPath);
    if (ret !== 'ok') {
      throw new Error('bundleLoadFromPath 返回 "' + ret + '"');
    }
    // reload = 同名整体替换，插件内存态被洗掉 ⇒ 撤 done 记账后补跑一次 init
    PluginInit.rearm(this.uuid);
    this.loaded = true;
  }
}
