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
import { MangaSource } from './Source';
import { MangaSummary, ChapterInfo, PageImage, SourceInfo } from '../model/Models';
import { bundleCall, bundleCallBytes, bundleLoadFromPath, bundleList, BytesResult } from '../../util/PluginRuntime';
import { jparse, jstr, jobj, jarr, jstrArr, jisEmpty } from '../../util/JsonUtil';
import { Logger } from '../../util/Logger';

/** 图源 id 前缀：plugin:<清单 uuid>。 */
export const PLUGIN_SOURCE_PREFIX: string = 'plugin:';

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

/** fetchImageBytes 入参。 */
class ImageArg {
  url: string = '';
  timeoutMs: number = 30000;
}

/** 从 unknown 异常提取 message 原文（同 Index.ets:86 已验证写法）。 */
function errText(e: Object): string {
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
  private metaValue(item: ESObject, type: string): string {
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
  private mapItem(item: ESObject, rawOverride: ESObject | null): MangaSummary {
    const raw: ESObject = rawOverride !== null ? rawOverride : jobj(item, 'raw');
    let author: string = this.metaValue(item, 'author');
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
      sourceId: PLUGIN_SOURCE_PREFIX + this.uuid,
      title: jstr(item, 'title', jstr(raw, 'name', '')),
      author: author,
      coverUrl: jstr(cover, 'url', ''),
      description: jstr(raw, 'description', jstr(item, 'description', '')),
      tags: tags
    };
    return s;
  }

  /** 列表容器：data.items 优先，退回 items（两 bundle 同构，实测）。 */
  private itemsToSummaries(root: ESObject): MangaSummary[] {
    let items: ESObject[] = jarr(jobj(root, 'data'), 'items');
    if (items.length === 0) {
      items = jarr(root, 'items');
    }
    const out: MangaSummary[] = [];
    for (let i = 0; i < items.length; i++) {
      const s: MangaSummary = this.mapItem(items[i], null);
      if (s.id.length > 0 && s.title.length > 0) {
        out.push(s);
      }
    }
    return out;
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
    const o: ESObject = await this.call('加载热门失败', 'getRankingData', a);
    return this.itemsToSummaries(o);
  }

  /** 搜索：searchComic（两家均 1 基，直接透传）。 */
  async search(keyword: string, page: number): Promise<MangaSummary[]> {
    const a: SearchArg = new SearchArg();
    a.keyword = keyword;
    a.page = Math.max(1, Math.floor(page) || 1);
    const o: ESObject = await this.call('搜索失败', 'searchComic', a);
    return this.itemsToSummaries(o);
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
    return this.mapItem(info, jisEmpty(dataRaw) ? null : dataRaw);
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
    return out;
  }

  /** 页表：getChapter；空页表转中文 Error（阅读器契约：失败必须抛，不能空列表白屏）。 */
  async fetchPages(chapterId: string): Promise<PageImage[]> {
    const a: ChapterArg = new ChapterArg();
    a.chapterId = chapterId;
    const cached: string | undefined = this.chapterComic.get(chapterId);
    a.comicId = cached !== undefined ? cached : this.lastMangaId;
    const o: ESObject = await this.call('加载章节内容失败', 'getChapter', a);
    let chapter: ESObject = jobj(jobj(o, 'data'), 'chapter');
    let pages: ESObject[] = jarr(chapter, 'pages');
    if (pages.length === 0) {
      chapter = jobj(o, 'chapter');
      pages = jarr(chapter, 'pages');
    }
    if (pages.length === 0) {
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
      const p: PageImage = { index: i, url: url };
      out.push(p);
    }
    if (usable === 0) {
      // 全空 URL 的页表同样是白屏（JM 需要 jwt/风控时会返回这种壳），一并转中文 Error。
      throw new Error('章节页表缺少图片地址（' + this.displayName + ' chapterId=' + chapterId + '）');
    }
    return out;
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
    a.chapterId = chapterId;
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
  async fetchImageBytes(url: string): Promise<ArrayBuffer> {
    await this.ensureLoaded('取图失败');
    const a: ImageArg = new ImageArg();
    a.url = url;
    a.timeoutMs = 30000;
    let r: BytesResult;
    try {
      r = await bundleCallBytes(this.uuid, 'fetchImageBytes', JSON.stringify([a]));
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
    this.loaded = true;
  }
}
