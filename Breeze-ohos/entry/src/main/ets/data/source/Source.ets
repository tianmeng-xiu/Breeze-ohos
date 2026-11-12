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
export interface MangaSource {
  /** 源描述（id 与 MangaSummary.sourceId 对应）。 */
  info(): SourceInfo;
  /** 热门/发现页列表。 */
  fetchPopular(page: number): Promise<MangaSummary[]>;
  /** 关键字搜索。 */
  search(keyword: string, page: number): Promise<MangaSummary[]>;
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
