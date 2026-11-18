/**
 * 职责：漫画来源（图源）统一接口。所有源插件只需实现本接口，UI 与仓库层完全不感知具体站点。
 * 替换原 Flutter 依赖：breeze 的 ComicSource / 各 dart 源实现（原为内置硬编码分支）。
 * 依据系统 Kit：无（纯 ArkTS interface）。
 */
import { MangaSummary, ChapterInfo, PageImage, SourceInfo } from '../model/Models';

/**
 * 一个可插拔的图源。
 * 约定：
 *  - 所有方法失败时抛 Error（message 可直接展示给用户），不要返回 null 代替错误（fetchDetail 除外）。
 *  - page 从 0 开始，源内部自行换算 offset/limit。
 *  - 返回的 MangaSummary.sourceId 必须等于 info().id。
 */
/**
 * 一页搜索结果（含翻页信息）。
 * ★ 为什么要新加这一层而不是给 search() 加个 bool：插件回包里本来就带 paging
 *   （上游 unified_plugin_search.dart:16-23 读 page/pages/total/hasReachedMax），
 *   旧 search() 走 itemsToSummaries 把它整块丢了 ⇒ 宿主无从判断「还有没有下一页」，
 *   只能靠「返回空数组」这一条最弱的信号。extern 是插件自己的翻页游标，必须原样回收
 *   （上游 get_plugin_result.dart:37 `blocState.pluginExtern = parsed.extern`），
 *   否则第二页永远重复第一页。存 JSON 串而不是 ESObject：调用方是 UI 的 @State，
 *   字符串可比较、可进 key，也免得 UI 层持有插件对象图。
 */
export class SearchPageResult {
  items: MangaSummary[] = [];
  /** 本次返回的是第几页（插件回包 page，缺省 = 请求页）。 */
  page: number = 1;
  /** 总页数；0 = 插件没给（不可用于判到底）。 */
  pages: number = 0;
  /** 插件明说「到底了」。缺省 false（宁可多试一次，由空页兜底判到底）。 */
  hasReachedMax: boolean = false;
  /** 回包 extern 原样（JSON 串，'' = 没有）。下次请求要递回去。 */
  extern: string = '';
}

export interface MangaSource {
  /** 源描述（id 与 MangaSummary.sourceId 对应）。 */
  info(): SourceInfo;
  /** 热门/发现页列表。 */
  fetchPopular(page: number): Promise<MangaSummary[]>;
  /**
   * 关键字搜索（带翻页信息）。page 1 基；externJson = 上一页回包的游标（首页传 ''）。
   * 失败抛 Error（Source.ets 契约）。
   */
  searchPage(keyword: string, page: number, externJson: string): Promise<SearchPageResult>;
  /** 详情；源确认该 id 不存在时返回 null。 */
  fetchDetail(id: string): Promise<MangaSummary | null>;
  /** 章节列表，index 由源保证单调递增（0 起）。 */
  fetchChapters(mangaId: string): Promise<ChapterInfo[]>;
  /** 章节图片列表，index 从 0 开始与阅读器页码一一对应。 */
  fetchPages(chapterId: string): Promise<PageImage[]>;
}

/** 内置源的 id 常量，避免各处硬编码字符串。 */
export class SourceIds {
  static readonly MANGADEX: string = 'mangadex';
}
