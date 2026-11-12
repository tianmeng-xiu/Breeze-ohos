/**
 * 职责：全项目数据模型（唯一来源）。UI 层只读，数据层负责构造。
 * 替换原 Flutter 依赖：freezed 生成的 model.dart / objectbox 实体（字段语义对齐 UnifiedComicFavorite/History）。
 * 依据系统 Kit：无（纯 ArkTS interface），禁止在这里引入任何 Kit。
 */

/** 漫画摘要：书架、发现页、搜索结果的统一载体。id 为"源内唯一 id"，sourceId 标识来源。 */
export interface MangaSummary {
  id: string;            // 源内唯一 id
  sourceId: string;      // 来源标识
  title: string;
  author: string;        // 未知填 ''
  coverUrl: string;      // 未知填 ''
  description: string;
  tags: string[];
}

/** 章节信息：index 为章节在漫画内的顺序（0 起），由源保证单调。 */
export interface ChapterInfo {
  id: string;
  mangaId: string;
  title: string;
  index: number;
}

/** 单页图片：index 从 0 开始，与阅读器页码一一对应。 */
export interface PageImage {
  index: number;
  url: string;
}

/**
 * 阅读进度：updatedAt 为毫秒时间戳，用于历史列表倒序。
 * sourceId / title 是「最小可展示元数据」（v2 起随进度落库）：manga 表只有加过书架的书才有行，
 * 从发现页直接读的书若不带这两列，阅读记录页会因为查不到元数据而整页空白（bug④）。
 * 读取方一律「先 manga 表查完整元数据，查不到再退回这两列」。
 */
export interface ReadProgress {
  mangaId: string;
  chapterId: string;
  page: number;
  sourceId: string;
  title: string;
  updatedAt: number;
}

/** 来源描述：id 与 MangaSummary.sourceId 对应。 */
export interface SourceInfo {
  id: string;
  name: string;
  language: string;
}

/** 便捷构造：保证必填字段不为 undefined，UI 侧可直接用。 */
export function newMangaSummary(id: string, sourceId: string, title: string): MangaSummary {
  const m: MangaSummary = {
    id: id,
    sourceId: sourceId,
    title: title,
    author: '',
    coverUrl: '',
    description: '',
    tags: []
  };
  return m;
}
