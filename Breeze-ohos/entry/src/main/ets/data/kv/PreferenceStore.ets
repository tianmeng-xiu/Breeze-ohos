/**
 * 职责：轻量键值配置持久化（UA、阅读方向、上次选中的源等），同步读 + 异步写。
 * 替换原 Flutter 依赖：shared_preferences。
 * 依据系统 Kit：@kit.ArkData (preferences)。
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from '../../util/Logger';

/** 偏好文件名（落在应用沙箱 preferences 目录）。 */
const PREF_NAME: string = 'breeze_prefs';

export class PreferenceStore {
  private static instance: PreferenceStore | null = null;
  private prefs: preferences.Preferences | null = null;
  private initPromise: Promise<void> | null = null;

  static getInstance(): PreferenceStore {
    if (PreferenceStore.instance === null) {
      PreferenceStore.instance = new PreferenceStore();
    }
    return PreferenceStore.instance;
  }

  /** 幂等初始化：并发调用共享同一个 Promise，失败后可重试。 */
  async init(context: common.UIAbilityContext): Promise<void> {
    if (this.prefs !== null) {
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
      const options: preferences.Options = { name: PREF_NAME };
      this.prefs = await preferences.getPreferences(context, options);
      Logger.i('偏好设置初始化完成');
    } catch (err) {
      const be = err as BusinessError;
      Logger.e('偏好设置初始化失败 code=' + be.code + ' message=' + be.message);
      throw new Error('偏好设置打开失败(' + be.code + ')：' + be.message);
    }
  }

  isReady(): boolean {
    return this.prefs !== null;
  }

  // ------------------------------------------------------------ 同步读

  getString(key: string, def: string): string {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = p.getSync(key, def);
      if (typeof v === 'string') {
        return v as string;
      }
      return def;
    } catch (err) {
      Logger.ex('读取配置失败 ' + key, err as Object);
      return def;
    }
  }

  getBool(key: string, def: boolean): boolean {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = p.getSync(key, def);
      if (typeof v === 'boolean') {
        return v as boolean;
      }
      return def;
    } catch (err) {
      Logger.ex('读取配置失败 ' + key, err as Object);
      return def;
    }
  }

  getInt(key: string, def: number): number {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = p.getSync(key, def);
      if (typeof v === 'number') {
        return v as number;
      }
      return def;
    } catch (err) {
      Logger.ex('读取配置失败 ' + key, err as Object);
      return def;
    }
  }

  // ------------------------------------------------------------ 异步写

  async putString(key: string, value: string): Promise<void> {
    await this.putValue(key, value);
  }

  async putBool(key: string, value: boolean): Promise<void> {
    await this.putValue(key, value);
  }

  async putInt(key: string, value: number): Promise<void> {
    await this.putValue(key, value);
  }

  private async putValue(key: string, value: preferences.ValueType): Promise<void> {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      throw new Error('偏好设置尚未初始化，请先调用 PreferenceStore.init(context)');
    }
    try {
      await p.put(key, value);
      await p.flush();
    } catch (err) {
      const be = err as BusinessError;
      Logger.e('写入配置失败 ' + key + ' code=' + be.code + ' message=' + be.message);
      throw new Error('保存设置失败(' + be.code + ')：' + be.message);
    }
  }

  /** 删除单键（可选能力）。 */
  async remove(key: string): Promise<void> {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      return;
    }
    try {
      await p.delete(key);
      await p.flush();
    } catch (err) {
      Logger.ex('删除配置失败 ' + key, err as Object);
    }
  }

  /** 清空（可选能力，用于"恢复默认设置"）。 */
  async clear(): Promise<void> {
    const p: preferences.Preferences | null = this.prefs;
    if (p === null) {
      return;
    }
    try {
      await p.clear();
      await p.flush();
    } catch (err) {
      Logger.ex('清空配置失败', err as Object);
    }
  }
}

/** 常用配置键常量，避免各页硬编码字符串。 */
export class PrefKeys {
  static readonly USER_AGENT: string = 'http_user_agent';
  static readonly LAST_SOURCE_ID: string = 'last_source_id';
  static readonly READ_DIRECTION: string = 'read_direction';
  static readonly READER_TAP_TO_SCROLL: string = 'reader_tap_to_scroll';
  /** T2 搜索记录：值为 JSON 字符串数组（最新在前，上限 20 条），读写走 data/kv/SearchHistory。 */
  static readonly SEARCH_HISTORY: string = 'search_history';
  /** JM 分块反混淆模式：`jmDeobf:<插件 uuid>` = auto / on / off（见 data/image/JmDeobfuscate）。 */
  static readonly JM_DEOBF_PREFIX: string = 'jmDeobf:';
  static readonly COOKIE_PREFIX: string = 'cookie:';

  /** Cookie 键全名：前缀只有 COOKIE_PREFIX 一处字面量，别处再拼一次迟早漂。 */
  static cookieKey(host: string): string {
    return PrefKeys.COOKIE_PREFIX + host;
  }
}
