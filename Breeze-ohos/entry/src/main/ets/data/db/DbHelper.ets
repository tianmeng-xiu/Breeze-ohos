/**
 * 职责：关系型数据库唯一入口。负责 getRdbStore、建表建索引、幂等初始化与 version 迁移框架。
 * 替换原 Flutter 依赖：objectbox（Store.create / 实体 schema 生成）。
 * 依据系统 Kit：@kit.ArkData (relationalStore，SQLite)。
 */
import { relationalStore } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../util/Logger';

/** 库文件名，落在应用沙箱 databases 目录下。 */
export const DB_NAME: string = 'breeze.db';
/** 当前 schema 版本。新增表/列时 +1，并在 MIGRATIONS 里追加一步。 */
export const DB_VERSION: number = 2;

export const TABLE_MANGA: string = 'manga';
export const TABLE_BOOKSHELF: string = 'bookshelf';
export const TABLE_PROGRESS: string = 'read_progress';
export const TABLE_CHAPTER: string = 'chapter';

/** 迁移步骤：version 为目标版本，sqls 为从上一版本升级到该版本要执行的语句（必须幂等）。 */
interface MigrationStep {
  version: number;
  sqls: string[];
}

/** 建表语句集合（全部 IF NOT EXISTS，保证重复 init 不报错）。 */
const CREATE_SQLS: string[] = [
  // 1. manga：漫画元数据缓存（对应 ObjectBox 的 UnifiedComicFavorite 元数据部分，不含收藏状态）
  `CREATE TABLE IF NOT EXISTS ${TABLE_MANGA} (
    manga_id TEXT PRIMARY KEY NOT NULL,
    source_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    cover_url TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    updated_at INTEGER NOT NULL DEFAULT 0
  )`,
  // 2. bookshelf：书架（对应 ObjectBox 的 UnifiedComicFavorite，收藏即一行）
  `CREATE TABLE IF NOT EXISTS ${TABLE_BOOKSHELF} (
    manga_id TEXT PRIMARY KEY NOT NULL,
    source_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    author TEXT NOT NULL DEFAULT '',
    cover_url TEXT NOT NULL DEFAULT '',
    description TEXT NOT NULL DEFAULT '',
    tags TEXT NOT NULL DEFAULT '[]',
    added_at INTEGER NOT NULL DEFAULT 0,
    sort_index INTEGER NOT NULL DEFAULT 0
  )`,
  // 3. read_progress：阅读进度（对应 ObjectBox 的 UnifiedComicHistory 的章节/页码子集）
  //    source_id / title 是 v2 补的两列（bug④「阅读记录点开是空白页」的修法，见 MIGRATIONS 注释）：
  //    manga 表只有「加入书架」才会写，从发现页直接读的书有进度无元数据 ⇒ 进度行自带最小元数据。
  `CREATE TABLE IF NOT EXISTS ${TABLE_PROGRESS} (
    manga_id TEXT PRIMARY KEY NOT NULL,
    chapter_id TEXT NOT NULL DEFAULT '',
    page INTEGER NOT NULL DEFAULT 0,
    source_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    updated_at INTEGER NOT NULL DEFAULT 0
  )`,
  // 4. chapter：章节缓存（对应 ObjectBox 中无独立表、原由源实时拉取的章节列表）
  `CREATE TABLE IF NOT EXISTS ${TABLE_CHAPTER} (
    chapter_id TEXT PRIMARY KEY NOT NULL,
    manga_id TEXT NOT NULL DEFAULT '',
    title TEXT NOT NULL DEFAULT '',
    chapter_index INTEGER NOT NULL DEFAULT 0,
    updated_at INTEGER NOT NULL DEFAULT 0
  )`,
  'CREATE INDEX IF NOT EXISTS idx_manga_source ON manga (source_id)',
  'CREATE INDEX IF NOT EXISTS idx_bookshelf_added ON bookshelf (added_at)',
  'CREATE INDEX IF NOT EXISTS idx_progress_updated ON read_progress (updated_at)',
  'CREATE INDEX IF NOT EXISTS idx_chapter_manga ON chapter (manga_id, chapter_index)'
];

/**
 * 迁移表：v2 给 read_progress 补两列（bug④「阅读记录正确记录条数，但点开是空白页」）。
 * 根因：manga 表只有 addToBookshelf 会写（内部 upsertManga），阅读器 saveProgress 只写 read_progress
 *      ⇒ 从发现页直接读、没加书架的书「有进度无元数据」，HistoryPage 逐条 getManga 全 null ⇒ 全跳过 ⇒ 空白页。
 * 修法：进度行自带 source_id + title 最小元数据，HistoryPage 在 manga 查不到时回退用这两列。
 * SQLite 的 ADD COLUMN 允许 NOT NULL，只要给了常量 DEFAULT；重复执行会报 duplicate column，
 * 故 migrate() 逐步落版本号 + 下面 try 兜住（幂等，升级中断下次可续跑）。
 */
const MIGRATIONS: MigrationStep[] = [
  {
    version: 2,
    sqls: [
      `ALTER TABLE ${TABLE_PROGRESS} ADD COLUMN source_id TEXT NOT NULL DEFAULT ''`,
      `ALTER TABLE ${TABLE_PROGRESS} ADD COLUMN title TEXT NOT NULL DEFAULT ''`
    ]
  }
];

export class DbHelper {
  private static instance: DbHelper | null = null;
  private store: relationalStore.RdbStore | null = null;
  private initPromise: Promise<void> | null = null;

  static getInstance(): DbHelper {
    if (DbHelper.instance === null) {
      DbHelper.instance = new DbHelper();
    }
    return DbHelper.instance;
  }

  /** 幂等初始化：并发调用共享同一个 Promise，失败后可重试。 */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.store !== null) {
      return;
    }
    if (this.initPromise !== null) {
      await this.initPromise;
      return;
    }
    this.initPromise = this.doInit(context);
    try {
      await this.initPromise;
    } catch (err) {
      this.initPromise = null;
      throw err as Error;
    }
  }

  private async doInit(context: common.UIAbilityContext): Promise<void> {
    try {
      const config: relationalStore.StoreConfig = {
        name: DB_NAME,
        securityLevel: relationalStore.SecurityLevel.S1
      };
      const store: relationalStore.RdbStore = await relationalStore.getRdbStore(context, config);
      const current: number = store.version;
      if (current === 0) {
        for (let i = 0; i < CREATE_SQLS.length; i++) {
          await store.executeSql(CREATE_SQLS[i]);
        }
        store.version = DB_VERSION;
        Logger.i('数据库首次创建完成，version=' + DB_VERSION);
      } else if (current < DB_VERSION) {
        await this.migrate(store, current, DB_VERSION);
        store.version = DB_VERSION;
        Logger.i('数据库迁移完成 ' + current + ' -> ' + DB_VERSION);
      } else if (current > DB_VERSION) {
        // 降级安装：只告警不破坏数据，按现有 schema 继续用（缺列由调用方兜底）。
        Logger.w('数据库版本高于代码版本：db=' + current + ' code=' + DB_VERSION);
      }
      this.store = store;
    } catch (err) {
      const be = err as BusinessError;
      Logger.e('数据库初始化失败 code=' + be.code + ' message=' + be.message);
      throw new Error('数据库打开失败(' + be.code + ')：' + be.message);
    }
  }

  /**
   * 顺序执行迁移步骤，每步成功即落盘版本号，中途失败下次可从断点续跑。
   * 单条语句失败只告警不中断：ALTER TABLE ADD COLUMN 重复执行会报 duplicate column，
   * 而列已存在正是我们想要的结果（升级中断后的重跑必须能过）。
   */
  private async migrate(store: relationalStore.RdbStore, from: number, to: number): Promise<void> {
    for (let i = 0; i < MIGRATIONS.length; i++) {
      const step: MigrationStep = MIGRATIONS[i];
      if (step.version > from && step.version <= to) {
        for (let j = 0; j < step.sqls.length; j++) {
          try {
            await store.executeSql(step.sqls[j]);
          } catch (err) {
            const be = err as BusinessError;
            Logger.w('迁移语句跳过 code=' + be.code + '：' + be.message);
          }
        }
        store.version = step.version;
        Logger.i('迁移到 v' + step.version + ' 完成');
      }
    }
  }

  /** 取已初始化的 store；未 init 时抛出可直接展示给用户的中文错误。 */
  getStore(): relationalStore.RdbStore {
    if (this.store === null) {
      throw new Error('数据库尚未初始化，请先调用 DbHelper.init(context)');
    }
    return this.store;
  }

  isReady(): boolean {
    return this.store !== null;
  }

  /** 关闭数据库（进程退出/测试重置时调用），之后可再次 init。 */
  async close(): Promise<void> {
    if (this.store === null) {
      return;
    }
    try {
      await this.store.close();
    } catch (err) {
      Logger.ex('关闭数据库失败', err as Object);
    }
    this.store = null;
    this.initPromise = null;
  }
}
