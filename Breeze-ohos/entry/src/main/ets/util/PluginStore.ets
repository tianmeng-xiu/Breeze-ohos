/**
 * 职责：S4 插件管理页的「清单桶」—— preferences('plugin_manager') 的 `installed.json` 键，
 *       存 PluginRecord JSON 数组（清单必须含 uuid/localFile/version/sourceUrl/sha256/enabled）。
 *       列表数据 = pluginScanDir('plugins') ⊕ 本桶 join。
 * 依赖：@kit.ArkData preferences、JsonUtil；不碰引擎（纯存储层，引擎调用在 PluginManagerView）。
 * 口径（s14 第 3 条，2026-11-13）：本层字段一律只存**相对文件名**（localFile = scanDir 的 name），
 *       绝对路径由调用方自己拼；因此落盘 JSON 里本来就没有 filesDir，新增字段也不许引入。
 * 约定：与宿主桥的 'plugin_config' 桶分开（那是插件自己的配置，这是宿主的安装清单）。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { jparse, jstr, jbool } from './JsonUtil';
import { Logger } from './Logger';

const PREF_NAME: string = 'plugin_manager';
const LIST_KEY: string = 'installed.json';
const SHOPMAP_KEY: string = 'shopmap.json';
/**
 * getInfo 原文缓存（BUG4）：一个对象，键 = uuid，值 = getInfo 返回的 JSON 原文。
 * 对齐上游 Breeze/lib/plugin/plugin_registry_service.dart:284 persistGetInfoJson（落 ObjectBox）
 * 与 :90-105 getCachedPluginInfo（内存 miss ⇒ readPersistedGetInfoJson 兜底）的语义 ——
 * 我方无 ObjectBox，落同一个 preferences 文件的新键即可，格式与清单互不影响。
 */
const INFO_KEY: string = 'plugin_info.json';

/**
 * 商店映射条目（兜底）：installLatest 落盘件 name → 索引 uuid。
 * s13 第 1 条加 name/version 两列：商店索引里本来就带着中文名与版本号，下载时不存下来，
 * 之后插件自带 getInfo 一旦超时就再没有第二个名字来源，界面上只能拿文件名顶上。
 * 旧落盘数据没这几列 ⇒ 读出来是空串（下面 loadShopMap 走 jstr 缺省），不影响兼容。
 * s14 第 4 条（2026-11-13 用户裁定）再加 iconUrl 一列：索引条目本来就带插件自带图标地址，
 *       下载当时不存下来，之后列表页就再也想不起来它是谁（只能拿应用图标占位）。
 *       存的是**索引里的远程地址字符串**，不是本地路径，也不做本地缓存。
 */
export class ShopMapEntry {
  file: string = '';
  indexUuid: string = '';
  /** 商店索引里的插件名（中文显示名）；手放的文件恒空。 */
  name: string = '';
  /** 下载当时商店索引里的版本号；手放的文件恒空。 */
  version: string = '';
  /** 商店索引里的图标地址（IndexItem.iconUrl 原样）；手放的文件与老落盘数据恒空。 */
  iconUrl: string = '';
}

/** 清单条目（uuid = bundleLoadFromPath 的注册名；localFile = pluginScanDir 的 name，join 键）。 */
export class PluginRecord {
  uuid: string = '';
  name: string = '';
  localFile: string = '';
  version: string = '';
  sourceUrl: string = '';
  sha256: string = '';
  enabled: boolean = true;
  /** 商店索引 uuid（下载/更新时写入；本地手放的文件恒空）。 */
  indexUuid: string = '';
}

export class PluginStore {
  private static prefs: preferences.Preferences | null = null;

  private static async ensure(context: common.Context): Promise<preferences.Preferences> {
    if (PluginStore.prefs === null) {
      const options: preferences.Options = { name: PREF_NAME };
      PluginStore.prefs = await preferences.getPreferences(context, options);
    }
    return PluginStore.prefs;
  }

  /** 读全量清单；解析失败 ⇒ 空数组（坏数据不炸页面，save 时会整体覆盖）。 */
  static async loadAll(context: common.Context): Promise<PluginRecord[]> {
    const out: PluginRecord[] = [];
    try {
      const p: preferences.Preferences = await PluginStore.ensure(context);
      const raw: string = String(p.getSync(LIST_KEY, '[]'));
      const root: ESObject = jparse(raw);
      if (!Array.isArray(root)) {
        return out;
      }
      const arr: ESObject[] = root as ESObject[];
      for (let i = 0; i < arr.length; i++) {
        const it: ESObject = arr[i];
        if (it === null || it === undefined || typeof it !== 'object') {
          continue;
        }
        const rec: PluginRecord = new PluginRecord();
        rec.uuid = jstr(it, 'uuid', '');
        rec.name = jstr(it, 'name', '');
        rec.localFile = jstr(it, 'localFile', '');
        rec.version = jstr(it, 'version', '');
        rec.sourceUrl = jstr(it, 'sourceUrl', '');
        rec.sha256 = jstr(it, 'sha256', '');
        rec.enabled = jbool(it, 'enabled', true);
        rec.indexUuid = jstr(it, 'indexUuid', '');
        if (rec.uuid.length > 0 && rec.localFile.length > 0) {
          out.push(rec);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.e('PluginStore.loadAll 失败: ' + (err.message ?? String(e)));
    }
    return out;
  }

  /** upsert（按 uuid 覆盖或追加）并落盘。 */
  static async save(context: common.Context, rec: PluginRecord): Promise<void> {
    const list: PluginRecord[] = await PluginStore.loadAll(context);
    let replaced: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].uuid === rec.uuid) {
        list[i] = rec;
        replaced = true;
        break;
      }
    }
    if (!replaced) {
      list.push(rec);
    }
    await PluginStore.persist(context, list);
  }

  /**
   * 按 uuid 删除条目（只动清单，不删文件——文件删除走 pluginRemoveFile，顺序由调用方保证）。
   * 顺带清该 uuid 的 getInfo 缓存：重装后若旧缓存还在，会把上一个版本的版本号顶回来。
   */
  static async remove(context: common.Context, uuid: string): Promise<void> {
    const list: PluginRecord[] = await PluginStore.loadAll(context);
    const kept: PluginRecord[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].uuid !== uuid) {
        kept.push(list[i]);
      }
    }
    await PluginStore.persist(context, kept);
    await PluginStore.dropGetInfo(context, uuid);
  }

  /** 改 enabled 开关（找不到条目返回 false）。 */
  static async setEnabled(context: common.Context, uuid: string, enabled: boolean): Promise<boolean> {
    const list: PluginRecord[] = await PluginStore.loadAll(context);
    let hit: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].uuid === uuid) {
        list[i].enabled = enabled;
        hit = true;
      }
    }
    if (hit) {
      await PluginStore.persist(context, list);
    }
    return hit;
  }

  private static async persist(context: common.Context, list: PluginRecord[]): Promise<void> {
    const p: preferences.Preferences = await PluginStore.ensure(context);
    await p.put(LIST_KEY, JSON.stringify(list));
    await p.flush();
  }

  // ---------------- getInfo 原文缓存（BUG4：版本「一直未知」的持久化兜底） ----------------

  /**
   * 读整个 getInfo 缓存对象；坏数据一律回**新建的**空对象。
   * ⚠ 不能把 jparse 的返回值直接往外递：键缺失/内容非法时 jparse 回的是它模块级**共享**的
   *   EMPTY_OBJ 哨兵（util/JsonUtil.ets:132 的注释写得很清楚），而 saveGetInfo 要往返回值上
   *   写键 ⇒ 会把数据种进那个共享哨兵，别处拿 jisEmpty 判空的地方就此失真。
   *   所以这里只认「自己 JSON.parse 出来的对象」，其余一律新建。
   */
  private static readInfoMap(p: preferences.Preferences): ESObject {
    try {
      const text: string = String(p.getSync(INFO_KEY, '{}'));
      const parsed: ESObject = JSON.parse(text);
      if (parsed !== null && parsed !== undefined && typeof parsed === 'object' && !Array.isArray(parsed)) {
        return parsed;
      }
      Logger.w('PluginStore getInfo 缓存不是对象，按空处理');
    } catch (e) {
      Logger.w('PluginStore getInfo 缓存非法 JSON，按空处理');
    }
    return JSON.parse('{}');
  }

  /**
   * 存一份 getInfo 原文（= 上游 plugin_registry_service.dart:284 persistGetInfoJson 的等价）。
   * 两条硬口径：① 只在**成功**时写 —— 失败绝不能拿空串覆盖旧值，否则一次超时就永久丢掉可用版本；
   * ② 与上游 :302 相同则跳过写的口径一致，值没变不落盘（省一次 flush）。
   */
  static async saveGetInfo(context: common.Context, uuid: string, json: string): Promise<void> {
    if (uuid.length === 0 || json.length === 0) {
      return;
    }
    try {
      const p: preferences.Preferences = await PluginStore.ensure(context);
      const map: ESObject = PluginStore.readInfoMap(p);
      if (typeof map[uuid] === 'string' && (map[uuid] as string) === json) {
        return;
      }
      map[uuid] = json;
      await p.put(INFO_KEY, JSON.stringify(map));
      await p.flush();
    } catch (e) {
      const err = e as BusinessError;
      Logger.e('PluginStore.saveGetInfo 失败: ' + (err.message ?? String(e)));
    }
  }

  /**
   * 取缓存的 getInfo 原文；没有 ⇒ 空串（调用方自行回退下一级）。
   * 走 ensure() 而不是直接读静态字段：本页可能先于任何清单读写进来（重启后直接点设置齿轮），
   * 那时 prefs 还是 null。ensure 命中缓存后是同步返回级别的花费，不影响「秒显」。
   */
  static async readGetInfo(context: common.Context, uuid: string): Promise<string> {
    if (uuid.length === 0) {
      return '';
    }
    try {
      const p: preferences.Preferences = await PluginStore.ensure(context);
      const v: ESObject = PluginStore.readInfoMap(p)[uuid];
      return typeof v === 'string' ? (v as string) : '';
    } catch (e) {
      const err = e as BusinessError;
      Logger.e('PluginStore.readGetInfo 失败: ' + (err.message ?? String(e)));
      return '';
    }
  }

  /**
   * 抹掉某 uuid 的 getInfo 缓存（删插件 / 重装时调，避免旧版本号顶回新插件）。
   * 用「重建一张不含该键的表」而不是 delete/in：ArkTS 严格模式不支持 delete 运算符，
   * 仓内也没有 in 的用法先例 ⇒ 全走 Object.keys 重建。
   */
  static async dropGetInfo(context: common.Context, uuid: string): Promise<void> {
    if (uuid.length === 0) {
      return;
    }
    try {
      const p: preferences.Preferences = await PluginStore.ensure(context);
      const map: ESObject = PluginStore.readInfoMap(p);
      const keys: string[] = Object.keys(map);
      let hit: boolean = false;
      const kept: Record<string, string> = {};
      for (let i = 0; i < keys.length; i++) {
        const k: string = keys[i];
        if (k === uuid) {
          hit = true;
          continue;
        }
        if (typeof map[k] === 'string') {
          kept[k] = map[k] as string;
        }
      }
      if (!hit) {
        return;
      }
      await p.put(INFO_KEY, JSON.stringify(kept));
      await p.flush();
    } catch (e) {
      const err = e as BusinessError;
      Logger.e('PluginStore.dropGetInfo 失败: ' + (err.message ?? String(e)));
    }
  }

  /** 读 file→indexUuid（外加 s13 起的 name/version、s14 起的 iconUrl）映射；解析失败 ⇒ 空数组（同 loadAll 容错口径）。 */
  static async loadShopMap(context: common.Context): Promise<ShopMapEntry[]> {
    const out: ShopMapEntry[] = [];
    try {
      const p: preferences.Preferences = await PluginStore.ensure(context);
      const raw: string = String(p.getSync(SHOPMAP_KEY, '[]'));
      const root: ESObject = jparse(raw);
      if (!Array.isArray(root)) {
        return out;
      }
      const arr: ESObject[] = root as ESObject[];
      for (let i = 0; i < arr.length; i++) {
        const it: ESObject = arr[i];
        const file: string = jstr(it, 'file', '');
        const idx: string = jstr(it, 'indexUuid', '');
        if (file.length > 0 && idx.length > 0) {
          const e = new ShopMapEntry();
          e.file = file;
          e.indexUuid = idx;
          // 老数据缺这几列就是空串：不因此丢条目（映射本身还要用来认「这是商店下载的哪一本」）
          e.name = jstr(it, 'name', '');
          e.version = jstr(it, 'version', '');
          e.iconUrl = jstr(it, 'iconUrl', '');
          out.push(e);
        }
      }
    } catch (e) {
      const err = e as BusinessError;
      Logger.e('PluginStore.loadShopMap 失败: ' + (err.message ?? String(e)));
    }
    return out;
  }

  /** 写映射（按 file upsert；同 indexUuid 的旧文件条目一并剔除 ⇒ 更新换代后只留最新落盘件）。
   *  s14：后三个形参一律带默认值 ⇒ s13 之前那两处调用点的写法依旧合法。 */
  static async saveShopMap(context: common.Context, file: string, indexUuid: string,
    name: string = '', version: string = '', iconUrl: string = ''): Promise<void> {
    const list: ShopMapEntry[] = await PluginStore.loadShopMap(context);
    const kept: ShopMapEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].file === file || list[i].indexUuid === indexUuid) {
        continue;
      }
      kept.push(list[i]);
    }
    const ne = new ShopMapEntry();
    ne.file = file;
    ne.indexUuid = indexUuid;
    ne.name = name;
    ne.version = version;
    ne.iconUrl = iconUrl;
    kept.push(ne);
    const p: preferences.Preferences = await PluginStore.ensure(context);
    await p.put(SHOPMAP_KEY, JSON.stringify(kept));
    await p.flush();
  }
}
