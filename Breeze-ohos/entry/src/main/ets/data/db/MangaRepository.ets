/**
 * 职责：书架 / 漫画元数据 / 阅读进度 / 章节缓存的全部读写，UI 层唯一的数据访问入口。
 * 替换原 Flutter 依赖：objectbox（Box<UnifiedComicFavorite>/<UnifiedComicHistory> 的 put/remove/query）。
 * 依据系统 Kit：@kit.ArkData (relationalStore + RdbPredicates)。
 *
 * ---- ObjectBox 实体 -> 表 映射（原 Breeze/lib/object_box/model.dart）----
 * UnifiedComicFavorite { uniqueKey,source,comicId,title,description,cover,creator,metadata,createdAt,deleted }
 *   -> bookshelf (主键 manga_id)                        // 收藏 = 书架一行；metadata 里的 tags 落到 tags 列
 *   -> manga     (主键 manga_id)                        // 同一份元数据的缓存副本，供详情页/发现页复用
 *      source -> source_id, comicId -> manga_id, cover -> cover_url, creator -> author
 * UnifiedComicHistory { uniqueKey,source,comicId,chapterId,chapterTitle,chapterOrder,pageIndex,lastReadAt,updatedAt }
 *   -> read_progress (主键 manga_id)                     // 每部漫画只保留最后一条进度，等价于原 uniqueKey 去重
 *      chapterId -> chapter_id, pageIndex -> page, lastReadAt/updatedAt -> updated_at
 *   -> chapter (主键 chapter_id)                         // 章节列表离线缓存（原实现每次向源实时拉取）
 * ObjectBox 的自增 @Id 全部弃用：业务主键直接作为 TEXT 主键，跨端/跨源不会冲突。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { DbHelper, TABLE_MANGA, TABLE_BOOKSHELF, TABLE_PROGRESS, TABLE_CHAPTER } from './DbHelper';
import { MangaSummary, ReadProgress, ChapterInfo } from '../model/Models';
import { encodeTags, decodeTags } from '../../util/JsonUtil';
import { Logger } from '../../util/Logger';

/** manga / bookshelf 共用的列顺序，供 query 时显式指定。 */
const COLS_MANGA: string[] = ['manga_id', 'source_id', 'title', 'author', 'cover_url', 'description', 'tags'];
/** v2：进度表带 source_id / title 最小元数据（bug④ 修法，见 DbHelper.MIGRATIONS）。 */
const COLS_PROGRESS: string[] = ['manga_id', 'chapter_id', 'page', 'source_id', 'title', 'updated_at'];
/** 万一迁移没跑成（老库 + ALTER 失败）时的降级列集：少了元数据但页面还能出内容，不能整页报错。 */
const COLS_PROGRESS_LEGACY: string[] = ['manga_id', 'chapter_id', 'page', 'updated_at'];
const COLS_CHAPTER: string[] = ['chapter_id', 'manga_id', 'title', 'chapter_index'];

export class MangaRepository {
  private static instance: MangaRepository | null = null;

  static getInstance(): MangaRepository {
    if (MangaRepository.instance === null) {
      MangaRepository.instance = new MangaRepository();
    }
    return MangaRepository.instance;
  }

  /** 幂等：内部转交 DbHelper，重复调用安全。 */
  async init(context: common.UIAbilityContext): Promise<void> {
    await DbHelper.getInstance().init(context);
  }

  // ---------------------------------------------------------------- 书架

  /** 书架列表，按加入时间倒序。 */
  async listBookshelf(): Promise<MangaSummary[]> {
    try {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_BOOKSHELF);
      predicates.orderByDesc('added_at');
      const rs: relationalStore.ResultSet =
        await this.queryRows(predicates, TABLE_BOOKSHELF, 'ORDER BY added_at DESC', COLS_MANGA);
      const list: MangaSummary[] = [];
      try {
        while (rs.goToNextRow()) {
          list.push(this.rowToManga(rs));
        }
      } finally {
        rs.close();
      }
      return list;
    } catch (err) {
      throw this.wrap(err, '读取书架失败');
    }
  }

  async isInBookshelf(id: string): Promise<boolean> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_BOOKSHELF);
      predicates.equalTo('manga_id', id);
      const rs: relationalStore.ResultSet = await store.query(predicates, ['manga_id']);
      try {
        return rs.goToNextRow();
      } finally {
        rs.close();
      }
    } catch (err) {
      throw this.wrap(err, '查询书架状态失败');
    }
  }

  /** 加入书架：同时写入 manga 缓存；已存在则只刷新元数据、保留原 added_at（不改变排序）。 */
  async addToBookshelf(m: MangaSummary): Promise<void> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const now: number = Date.now();
      await this.upsertManga(m);

      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_BOOKSHELF);
      predicates.equalTo('manga_id', m.id);
      const changed: number = await store.update(this.toBookshelfBucket(m, -1), predicates);
      if (changed === 0) {
        await store.insert(TABLE_BOOKSHELF, this.toBookshelfBucket(m, now));
      }
    } catch (err) {
      throw this.wrap(err, '加入书架失败');
    }
  }

  async removeFromBookshelf(id: string): Promise<void> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_BOOKSHELF);
      predicates.equalTo('manga_id', id);
      await store.delete(predicates);
    } catch (err) {
      throw this.wrap(err, '移出书架失败');
    }
  }

  // ---------------------------------------------------------------- 漫画元数据

  /** 插入或更新漫画元数据缓存。 */
  async upsertManga(m: MangaSummary): Promise<void> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const bucket: relationalStore.ValuesBucket = this.toMangaBucket(m, Date.now());
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_MANGA);
      predicates.equalTo('manga_id', m.id);
      const changed: number = await store.update(bucket, predicates);
      if (changed === 0) {
        await store.insert(TABLE_MANGA, bucket);
      }
    } catch (err) {
      throw this.wrap(err, '保存漫画信息失败');
    }
  }

  /** 读缓存中的漫画元数据，未命中返回 null（调用方随后走网络）。 */
  async getManga(id: string): Promise<MangaSummary | null> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_MANGA);
      predicates.equalTo('manga_id', id);
      const rs: relationalStore.ResultSet = await store.query(predicates, COLS_MANGA);
      try {
        if (rs.goToNextRow()) {
          return this.rowToManga(rs);
        }
        return null;
      } finally {
        rs.close();
      }
    } catch (err) {
      throw this.wrap(err, '读取漫画信息失败');
    }
  }

  // ---------------------------------------------------------------- 阅读进度

  /**
   * 保存阅读进度（每部漫画仅一行，覆盖式）。
   * sourceId / title 由阅读器透传，随进度一起落库 —— 这样「读过但没加书架」的书在阅读记录里
   * 也有内容可显示（bug④ 空白页的根因就是 manga 表没这些书的行）。两个参数可空是为了
   * 兼容历史调用点；空值只是少显示书名，不影响进度本身。
   */
  async saveProgress(mangaId: string, chapterId: string, page: number,
    sourceId: string = '', title: string = ''): Promise<void> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const bucket: relationalStore.ValuesBucket = {
        'manga_id': mangaId,
        'chapter_id': chapterId,
        'page': page,
        'source_id': sourceId,
        'title': title,
        'updated_at': Date.now()
      };
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PROGRESS);
      predicates.equalTo('manga_id', mangaId);
      try {
        const changed: number = await store.update(bucket, predicates);
        if (changed === 0) {
          await store.insert(TABLE_PROGRESS, bucket);
        }
      } catch (inner) {
        // 降级路径：极老库上 v2 迁移未生效（ALTER 失败）⇒ 少两列也必须把进度写进去
        const legacy: relationalStore.ValuesBucket = {
          'manga_id': mangaId,
          'chapter_id': chapterId,
          'page': page,
          'updated_at': Date.now()
        };
        const changed2: number = await store.update(legacy, predicates);
        if (changed2 === 0) {
          await store.insert(TABLE_PROGRESS, legacy);
        }
      }
    } catch (err) {
      throw this.wrap(err, '保存阅读进度失败');
    }
  }

  async getProgress(mangaId: string): Promise<ReadProgress | null> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PROGRESS);
      predicates.equalTo('manga_id', mangaId);
      const rs: relationalStore.ResultSet = await store.query(predicates, COLS_PROGRESS);
      try {
        if (rs.goToNextRow()) {
          return this.rowToProgress(rs);
        }
        return null;
      } finally {
        rs.close();
      }
    } catch (err) {
      throw this.wrap(err, '读取阅读进度失败');
    }
  }

  /** 阅读历史，按 updatedAt 倒序。 */
  async listHistory(): Promise<ReadProgress[]> {
    try {
      const rs: relationalStore.ResultSet = await this.queryProgress('ORDER BY updated_at DESC');
      const list: ReadProgress[] = [];
      try {
        while (rs.goToNextRow()) {
          list.push(this.rowToProgress(rs));
        }
      } finally {
        rs.close();
      }
      return list;
    } catch (err) {
      throw this.wrap(err, '读取阅读历史失败');
    }
  }

  /**
   * T3：清空全部阅读进度（read_progress 整表）。
   * 影响面：阅读记录页会空、书架封面的「第 N 页」角标会消失（两者同源，见 BookshelfPage.progressText）。
   * 不动书架列表与章节缓存 —— 用户清的是「读到哪了」，不是「我收藏了什么」。
   */
  async clearProgress(): Promise<void> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_PROGRESS);
      await store.delete(predicates);
    } catch (err) {
      throw this.wrap(err, '清空阅读记录失败');
    }
  }

  // ---------------------------------------------------------------- 章节缓存（附加能力）


  /** 覆盖式保存某漫画的章节列表（先删后插，保证顺序与源一致）。 */
  async saveChapters(mangaId: string, chapters: ChapterInfo[]): Promise<void> {
    try {
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const del: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_CHAPTER);
      del.equalTo('manga_id', mangaId);
      await store.delete(del);
      const now: number = Date.now();
      for (let i = 0; i < chapters.length; i++) {
        const c: ChapterInfo = chapters[i];
        const bucket: relationalStore.ValuesBucket = {
          'chapter_id': c.id,
          'manga_id': c.mangaId,
          'title': c.title,
          'chapter_index': c.index,
          'updated_at': now
        };
        await store.insert(TABLE_CHAPTER, bucket);
      }
    } catch (err) {
      throw this.wrap(err, '缓存章节列表失败');
    }
  }

  async listChapters(mangaId: string): Promise<ChapterInfo[]> {
    try {
      const predicates: relationalStore.RdbPredicates = new relationalStore.RdbPredicates(TABLE_CHAPTER);
      predicates.equalTo('manga_id', mangaId);
      predicates.orderByAsc('chapter_index');
      const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
      const rs: relationalStore.ResultSet = await store.query(predicates, COLS_CHAPTER);
      const list: ChapterInfo[] = [];
      try {
        while (rs.goToNextRow()) {
          const c: ChapterInfo = {
            id: rs.getString(rs.getColumnIndex('chapter_id')),
            mangaId: rs.getString(rs.getColumnIndex('manga_id')),
            title: rs.getString(rs.getColumnIndex('title')),
            index: rs.getLong(rs.getColumnIndex('chapter_index'))
          };
          list.push(c);
        }
      } finally {
        rs.close();
      }
      return list;
    } catch (err) {
      throw this.wrap(err, '读取章节列表失败');
    }
  }

  // ---------------------------------------------------------------- 内部

  /**
   * 统一的查询出口：优先用 RdbPredicates（契约要求），
   * 若某些 ROM 版本对"无条件谓词"支持异常，则回退到等价 SQL，保证列表页永远不白屏。
   */
  private async queryRows(predicates: relationalStore.RdbPredicates, table: string,
    orderSql: string, columns: string[]): Promise<relationalStore.ResultSet> {
    const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
    try {
      return await store.query(predicates, columns);
    } catch (err) {
      const be = err as BusinessError;
      Logger.w('RdbPredicates 查询失败(' + be.code + ')，回退 SQL：' + be.message);
      const sql: string = 'SELECT ' + columns.join(',') + ' FROM ' + table + ' ' + orderSql;
      return await store.querySql(sql);
    }
  }

  private toMangaBucket(m: MangaSummary, updatedAt: number): relationalStore.ValuesBucket {
    const bucket: relationalStore.ValuesBucket = {
      'manga_id': m.id,
      'source_id': m.sourceId,
      'title': m.title,
      'author': m.author,
      'cover_url': m.coverUrl,
      'description': m.description,
      'tags': encodeTags(m.tags),
      'updated_at': updatedAt
    };
    return bucket;
  }

  /** addedAt < 0 表示"不写 added_at"（更新已有行时保留原值），避免刷新元数据打乱书架排序。 */
  private toBookshelfBucket(m: MangaSummary, addedAt: number): relationalStore.ValuesBucket {
    if (addedAt < 0) {
      const partial: relationalStore.ValuesBucket = {
        'source_id': m.sourceId,
        'title': m.title,
        'author': m.author,
        'cover_url': m.coverUrl,
        'description': m.description,
        'tags': encodeTags(m.tags)
      };
      return partial;
    }
    const full: relationalStore.ValuesBucket = {
      'manga_id': m.id,
      'source_id': m.sourceId,
      'title': m.title,
      'author': m.author,
      'cover_url': m.coverUrl,
      'description': m.description,
      'tags': encodeTags(m.tags),
      'added_at': addedAt,
      'sort_index': addedAt
    };
    return full;
  }

  private rowToManga(rs: relationalStore.ResultSet): MangaSummary {
    const m: MangaSummary = {
      id: rs.getString(rs.getColumnIndex('manga_id')),
      sourceId: rs.getString(rs.getColumnIndex('source_id')),
      title: rs.getString(rs.getColumnIndex('title')),
      author: rs.getString(rs.getColumnIndex('author')),
      coverUrl: rs.getString(rs.getColumnIndex('cover_url')),
      description: rs.getString(rs.getColumnIndex('description')),
      tags: decodeTags(rs.getString(rs.getColumnIndex('tags')))
    };
    return m;
  }

  private rowToProgress(rs: relationalStore.ResultSet): ReadProgress {
    const p: ReadProgress = {
      mangaId: rs.getString(rs.getColumnIndex('manga_id')),
      chapterId: rs.getString(rs.getColumnIndex('chapter_id')),
      page: rs.getLong(rs.getColumnIndex('page')),
      // v2 两列：列缺失（老库迁移未生效）时给空串，读取方自己有回退，不在这抛
      sourceId: this.optStr(rs, 'source_id'),
      title: this.optStr(rs, 'title'),
      updatedAt: rs.getLong(rs.getColumnIndex('updated_at'))
    };
    return p;
  }

  /**
   * 读进度表：优先带 v2 两列，列不存在（迁移失败的老库）就退到 v1 四列。
   * 不这么做的话，一次 getColumnIndex 越界会让整个阅读记录页抛错 ⇒ 又变成空白页。
   */
  private async queryProgress(orderSql: string): Promise<relationalStore.ResultSet> {
    const store: relationalStore.RdbStore = DbHelper.getInstance().getStore();
    try {
      return await store.querySql('SELECT ' + COLS_PROGRESS.join(',') + ' FROM ' + TABLE_PROGRESS + ' ' + orderSql);
    } catch (err) {
      const be = err as BusinessError;
      Logger.w('进度表 v2 列查询失败(' + be.code + ')，回退 v1 列：' + be.message);
      return await store.querySql('SELECT ' + COLS_PROGRESS_LEGACY.join(',') + ' FROM ' + TABLE_PROGRESS + ' ' + orderSql);
    }
  }

  /** 列存在才读，否则空串（v2 列在极老库上可能缺失）。 */
  private optStr(rs: relationalStore.ResultSet, col: string): string {
    try {
      const idx: number = rs.getColumnIndex(col);
      if (idx < 0) {
        return '';
      }
      return rs.getString(idx);
    } catch (err) {
      return '';
    }
  }

  /** 把 Kit 的 BusinessError 转成可直接 showToast 的中文 Error（保留 code）。 */
  private wrap(err: Object, prefix: string): Error {
    const be = err as BusinessError;
    const code: number = be.code;
    const rawMsg: string = be.message;
    const msg: string = rawMsg ? rawMsg : '未知错误';
    if (typeof code === 'number') {
      Logger.e(prefix + ' code=' + code + ' message=' + msg);
      return new Error(prefix + '(' + code + ')：' + msg);
    }
    Logger.e(prefix + ' message=' + msg);
    return new Error(prefix + '：' + msg);
  }
}