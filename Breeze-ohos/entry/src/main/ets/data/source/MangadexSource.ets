/**
 * 职责：内置示例源 —— MangaDex（公开 REST API，无需登录）。热门/搜索/详情/章节/图片五件套齐全。
 * 替换原 Flutter 依赖：breeze 内置的漫画源 dart 实现（原项目为其自研解析，这里换成官方 JSON API）。
 * 依据系统 Kit：@kit.NetworkKit (http，经 data/net/HttpClient)；JSON 逐字段取值走 util/JsonUtil（ESObject）。
 *
 * API 基线（2024 起稳定，实测 200 OK）：
 *   热门 GET /manga?limit=&offset=&includes%5B%5D=cover_art&order%5BfollowedCount%5D=desc
 *   搜索 GET /manga?limit=&offset=&title=<kw>&includes%5B%5D=cover_art
 *   详情 GET /manga/<id>?includes%5B%5D=cover_art&includes%5B%5D=author&includes%5B%5D=artist
 *   章节 GET /manga/<id>/feed?limit=500&offset=&order%5Bvolume%5D=asc&order%5Bchapter%5D=asc
 *   图片 GET /at-home/server/<chapterId>  (注意不是 /chapter/<id>)
 * 注意：URL 里的 [ ] 必须写成 %5B%5D，否则部分 CDN/网关会 400。
 */
import { MangaSummary, ChapterInfo, PageImage, SourceInfo } from '../model/Models';
import { MangaSource, SourceIds } from './Source';
import { HttpClient } from '../net/HttpClient';
import { jarr, jbool, jhas, jisEmpty, jobj, jstr, jstrArr, jnum, jparse } from '../../util/JsonUtil';
import { Logger } from '../../util/Logger';

const API_BASE: string = 'https://api.mangadex.org';
const UPLOAD_BASE: string = 'https://uploads.mangadex.org';
const PAGE_SIZE: number = 20;
const FEED_PAGE: number = 500;
const FEED_MAX_TOTAL: number = 5000;
const COVER_SUFFIX: string = '.256.jpg';
/** 请求 UA：MangaDex 对浏览器 UA 返回 403 'Bot challenge not passed'，必须用应用标识。 */
const SRC_UA: string = 'Breeze-OHOS/1.0';

/** 标题/简介的多语言优先顺序：中文优先，退化到罗马音/英文。 */
const LANG_PREF: string[] = ['zh-hk', 'zh', 'zh-cn', 'zh-tw', 'en', 'ja-ro', 'ja', 'ko',
  'es-la', 'es', 'pt-br', 'fr', 'de', 'ru', 'it', 'id', 'vi', 'th', 'pl', 'tr', 'uk', 'ar'];

/** 从多语言字典里按优先级取第一个非空值。 */
function pickLocalized(dict: ESObject): string {
  for (let i = 0; i < LANG_PREF.length; i++) {
    const v: string = jstr(dict, LANG_PREF[i], '');
    if (v.length > 0) {
      return v;
    }
  }
  return '';
}

/** 章节展示名：Vol.3 第12话 标题。 */
function buildChapterTitle(attrs: ESObject): string {
  const vol: string = jstr(attrs, 'volume', '');
  const num: string = jstr(attrs, 'chapter', '');
  const name: string = jstr(attrs, 'title', '');
  let label: string = num.length > 0 ? '第' + num + '话' : '未知话数';
  if (vol.length > 0) {
    label = 'Vol.' + vol + ' ' + label;
  }
  if (name.length > 0) {
    label = label + ' ' + name;
  }
  return label;
}

export class MangadexSource implements MangaSource {
  info(): SourceInfo {
    const s: SourceInfo = {
      id: SourceIds.MANGADEX,
      name: 'MangaDex',
      language: 'multi'
    };
    return s;
  }

  /** 统一请求头（每个请求显式带 UA，避免上层改过 HttpClient 默认值后又被 Bot challenge）。 */
  private headers(): Map<string, string> {
    const h: Map<string, string> = new Map<string, string>();
    h.set('User-Agent', SRC_UA);
    h.set('Accept', 'application/json');
    return h;
  }

  private async fetchText(url: string): Promise<string> {
    return HttpClient.getInstance().getText(url, this.headers());
  }

  // ------------------------------------------------------------ 列表

  async fetchPopular(page: number): Promise<MangaSummary[]> {
    const offset: number = this.offsetOf(page);
    const url: string = API_BASE + '/manga?limit=' + PAGE_SIZE + '&offset=' + offset +
      '&includes%5B%5D=cover_art&includes%5B%5D=author&includes%5B%5D=artist' +
      '&order%5BfollowedCount%5D=desc' +
      '&contentRating%5B%5D=safe&contentRating%5B%5D=suggestive';
    try {
      const text: string = await this.fetchText(url);
      const root: ESObject = jparse(text);
      if (jisEmpty(root)) {
        throw new Error('返回内容不是合法 JSON');
      }
      return this.parseList(root);
    } catch (err) {
      throw this.wrap(err, '热门列表加载失败');
    }
  }

  async search(keyword: string, page: number): Promise<MangaSummary[]> {
    const kw: string = keyword ? keyword.trim() : '';
    if (kw.length === 0) {
      return [];
    }
    const offset: number = this.offsetOf(page);
    const url: string = API_BASE + '/manga?limit=' + PAGE_SIZE + '&offset=' + offset +
      '&title=' + encodeURIComponent(kw) +
      '&includes%5B%5D=cover_art&includes%5B%5D=author&includes%5B%5D=artist' +
      '&contentRating%5B%5D=safe&contentRating%5B%5D=suggestive';
    try {
      const text: string = await this.fetchText(url);
      const root: ESObject = jparse(text);
      if (jisEmpty(root)) {
        throw new Error('返回内容不是合法 JSON');
      }
      return this.parseList(root);
    } catch (err) {
      throw this.wrap(err, '搜索失败');
    }
  }

  // ------------------------------------------------------------ 详情

  async fetchDetail(id: string): Promise<MangaSummary | null> {
    if (!id || id.length === 0) {
      return null;
    }
    const url: string = API_BASE + '/manga/' + encodeURIComponent(id) +
      '?includes%5B%5D=cover_art&includes%5B%5D=author&includes%5B%5D=artist';
    try {
      const text: string = await this.fetchText(url);
      const root: ESObject = jparse(text);
      if (jisEmpty(root)) {
        return null;
      }
      const data: ESObject = jobj(root, 'data');
      if (!jhas(data, 'id')) {
        return null;
      }
      return this.parseManga(data);
    } catch (err) {
      throw this.wrap(err, '漫画详情加载失败');
    }
  }

  // ------------------------------------------------------------ 章节

  async fetchChapters(mangaId: string): Promise<ChapterInfo[]> {
    if (!mangaId || mangaId.length === 0) {
      return [];
    }
    const out: ChapterInfo[] = [];
    let offset: number = 0;
    let index: number = 0;
    let total: number = -1;
    try {
      while (offset < FEED_MAX_TOTAL) {
        const url: string = API_BASE + '/manga/' + encodeURIComponent(mangaId) + '/feed' +
          '?limit=' + FEED_PAGE + '&offset=' + offset +
          '&includes%5B%5D=scanlation_group' +
          '&order%5Bvolume%5D=asc&order%5Bchapter%5D=asc';
        const text: string = await this.fetchText(url);
        const root: ESObject = jparse(text);
        if (jisEmpty(root)) {
          break;
        }
        if (total < 0) {
          total = jnum(root, 'total', 0);
        }
        const data: ESObject[] = jarr(root, 'data');
        if (data.length === 0) {
          break;
        }
        for (let i = 0; i < data.length; i++) {
          const item: ESObject = data[i];
          const attrs: ESObject = jobj(item, 'attributes');
          // 外链章节（pages=0 / externalUrl 非空 / isUnavailable）在 App 内不可读，过滤掉
          const hasPages: boolean = jhas(attrs, 'pages');
          const pages: number = jnum(attrs, 'pages', 0);
          const externalUrl: string = jstr(attrs, 'externalUrl', '');
          const unavailable: boolean = jbool(attrs, 'isUnavailable', false);
          // pages 字段存在且为 0 => 外链章节；字段缺失则先保留，等打开时再由 at-home 兜底报错
          if ((hasPages && pages <= 0) || externalUrl.length > 0 || unavailable) {
            continue;
          }
          const chapterId: string = jstr(item, 'id', '');
          if (chapterId.length === 0) {
            continue;
          }
          const ci: ChapterInfo = {
            id: chapterId,
            mangaId: mangaId,
            title: buildChapterTitle(attrs),
            index: index
          };
          index = index + 1;
          out.push(ci);
        }
        offset = offset + data.length;
        if (total >= 0 && offset >= total) {
          break;
        }
        if (data.length < FEED_PAGE) {
          break;
        }
      }
      Logger.i('MangaDex 章节数=' + out.length + ' manga=' + mangaId);
      return out;
    } catch (err) {
      throw this.wrap(err, '章节列表加载失败');
    }
  }

  // ------------------------------------------------------------ 图片

  async fetchPages(chapterId: string): Promise<PageImage[]> {
    if (!chapterId || chapterId.length === 0) {
      return [];
    }
    const url: string = API_BASE + '/at-home/server/' + encodeURIComponent(chapterId);
    try {
      const text: string = await this.fetchText(url);
      const root: ESObject = jparse(text);
      if (jisEmpty(root)) {
        throw new Error('返回内容不是合法 JSON');
      }
      let baseUrl: string = jstr(root, 'baseUrl', '');
      if (baseUrl.length === 0) {
        throw new Error('接口未返回图片服务器地址（章节可能已被删除）');
      }
      if (baseUrl.endsWith('/')) {
        baseUrl = baseUrl.substring(0, baseUrl.length - 1);
      }
      const chapter: ESObject = jobj(root, 'chapter');
      const hash: string = jstr(chapter, 'hash', '');
      if (hash.length === 0) {
        throw new Error('接口未返回章节图片 hash');
      }
      // 原图优先，没有原图才用省流图
      let files: string[] = jstrArr(chapter, 'data');
      let mode: string = 'data';
      if (files.length === 0) {
        files = jstrArr(chapter, 'dataSaver');
        mode = 'data-saver';
      }
      const pages: PageImage[] = [];
      for (let i = 0; i < files.length; i++) {
        const fileName: string = files[i];
        if (fileName.length === 0) {
          continue;
        }
        const page: PageImage = {
          index: pages.length,
          url: baseUrl + '/' + mode + '/' + hash + '/' + encodeURIComponent(fileName),
          // 非插件图源没有页表 extern：空串 = 没有页面上下文，取图走宿主 HTTP。
          ext: ''
        };
        pages.push(page);
      }
      if (pages.length === 0) {
        throw new Error('该章节没有可用图片（可能是外链章节）');
      }
      return pages;
    } catch (err) {
      throw this.wrap(err, '章节图片加载失败');
    }
  }

  // ------------------------------------------------------------ 解析

  private parseList(root: ESObject): MangaSummary[] {
    const data: ESObject[] = jarr(root, 'data');
    const out: MangaSummary[] = [];
    for (let i = 0; i < data.length; i++) {
      const m: MangaSummary = this.parseManga(data[i]);
      if (m.id.length > 0) {
        out.push(m);
      }
    }
    return out;
  }

  /** 单条 manga 对象 -> MangaSummary（字段缺失一律走默认值，永不抛异常）。 */
  private parseManga(item: ESObject): MangaSummary {
    const id: string = jstr(item, 'id', '');
    const attrs: ESObject = jobj(item, 'attributes');

    let title: string = pickLocalized(jobj(attrs, 'title'));
    if (title.length === 0) {
      // 标题字典可能只有非常规语言键，退化到 altTitles
      const alts: ESObject[] = jarr(attrs, 'altTitles');
      for (let i = 0; i < alts.length; i++) {
        const alt: ESObject = alts[i];
        const candidates: string[] = ['zh', 'zh-hk', 'en', 'ja-ro', 'ja'];
        for (let j = 0; j < candidates.length; j++) {
          const v: string = jstr(alt, candidates[j], '');
          if (v.length > 0) {
            title = v;
            break;
          }
        }
        if (title.length > 0) {
          break;
        }
      }
    }
    if (title.length === 0) {
      title = '未命名作品';
    }

    const descRaw: string = pickLocalized(jobj(attrs, 'description'));
    const description: string = this.cleanText(descRaw);

    const tags: string[] = [];
    const tagArr: ESObject[] = jarr(attrs, 'tags');
    for (let i = 0; i < tagArr.length && tags.length < 12; i++) {
      const tagName: string = pickLocalized(jobj(jobj(tagArr[i], 'attributes'), 'name'));
      if (tagName.length > 0) {
        tags.push(tagName);
      }
    }

    let author: string = '';
    let coverFile: string = '';
    const rels: ESObject[] = jarr(item, 'relationships');
    for (let i = 0; i < rels.length; i++) {
      const rel: ESObject = rels[i];
      const type: string = jstr(rel, 'type', '');
      const relAttrs: ESObject = jobj(rel, 'attributes');
      if ((type === 'author' || type === 'artist') && author.length === 0) {
        author = jstr(relAttrs, 'name', '');
      } else if (type === 'cover_art') {
        coverFile = jstr(relAttrs, 'fileName', '');
      }
    }

    let coverUrl: string = '';
    if (coverFile.length > 0 && id.length > 0) {
      coverUrl = UPLOAD_BASE + '/covers/' + id + '/' + coverFile + COVER_SUFFIX;
    }

    const m: MangaSummary = {
      id: id,
      sourceId: SourceIds.MANGADEX,
      title: title,
      author: author,
      coverUrl: coverUrl,
      description: description,
      tags: tags
    };
    return m;
  }

  /** 简介里混有 [b]…[/b] 之类的 BBCode 与换行，做一次轻量清洗并截断。 */
  private cleanText(raw: string): string {
    if (!raw) {
      return '';
    }
    let s: string = raw;
    const bbCode: RegExp = new RegExp('\\[[^\\]]{1,20}\\]', 'g');
    s = s.replace(bbCode, '');
    s = s.replace(/\s+/g, ' ').trim();
    return s.length > 500 ? s.substring(0, 500) + '…' : s;
  }

  private offsetOf(page: number): number {
    const p: number = page > 0 ? page : 0;
    return p * PAGE_SIZE;
  }

  private wrap(err: Object, prefix: string): Error {
    if (err instanceof Error) {
      const e: Error = err;
      return new Error(prefix + '：' + e.message);
    }
    return new Error(prefix + '：未知错误');
  }
}