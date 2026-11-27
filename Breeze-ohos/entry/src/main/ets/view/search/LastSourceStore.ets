/**
 * 职责：记住「上一次选中的图源」，供搜索页与发现页下次进入时默认回填（用户 11-12 13:48 report 第 7 条）。
 * 存储：复用 data/kv/PreferenceStore 单例（同名偏好库 breeze_prefs，不新建 preferences 实例），
 *      同步读 + 异步写并吞异常 —— 记住源是锦上添花，写失败绝不打断切源交互（与 data/kv/SearchHistory 同一口径）。
 * 键口径：
 *  - 两页各存各的键，互不串：搜索页选 MangaDex 不该把发现页的源一起改掉。需求把两页并列，
 *    「最后一次退出时选择哪个源，则下一次进入默认选中那个源」= 按页各自的语义。
 *  - 存源 id 字符串而不是下标：插件装卸（s52 起还包括内置图源开关的切换）会让图源列表
 *    （SourceManager.visibleList()）的长度与顺序都变化，下标必然选错源；
 *    进页后拿 id 在 chip 列表里查，查不到（源被卸载）才回落到原有的默认档。
 *  - 为什么不复用 PrefKeys.LAST_SOURCE_ID：那是**单键**，两页共用必然互相覆盖；且 data/kv/PreferenceStore.ets
 *    不在本次写域。键名就近定义在本文件（值仍落进同名偏好库，读写仍走 PreferenceStore 单例 = 等价复用）。
 * 依据系统 Kit：无（间接经 PreferenceStore 用 @kit.ArkData.preferences）。
 */
import { PreferenceStore } from '../../data/kv/PreferenceStore';
import { SourceInfo } from '../../data/model/Models';
import { Logger } from '../../util/Logger';

export class LastSourceStore {
  /** 搜索页上次选中的图源 id（含聚合项 __all__：用户选「全部」就下次默认「全部」）。 */
  private static readonly KEY_SEARCH: string = 'last_search_source_id';

  /** 发现页上次选中的图源 id。 */
  private static readonly KEY_DISCOVER: string = 'last_discover_source_id';

  /** 读搜索页记忆：偏好库未就绪或无记录都返回空串（不抛）。 */
  static readSearchId(): string {
    return LastSourceStore.read(LastSourceStore.KEY_SEARCH);
  }

  /** 读发现页记忆。 */
  static readDiscoverId(): string {
    return LastSourceStore.read(LastSourceStore.KEY_DISCOVER);
  }

  /** 写搜索页记忆（选中即写：幂等、开销小，不去抓「退出」时机）。 */
  static writeSearchId(id: string): void {
    LastSourceStore.write(LastSourceStore.KEY_SEARCH, id);
  }

  /** 写发现页记忆。 */
  static writeDiscoverId(id: string): void {
    LastSourceStore.write(LastSourceStore.KEY_DISCOVER, id);
  }

  /**
   * 按源 id 在下拉/chip 列表里查下标，查不到返回 -1（调用方回落到自己的默认档）。
   * 两页共用同一个查找口径，故收在这里而不是各写一份。
   */
  static indexOfSource(list: SourceInfo[], id: string): number {
    if (id.length === 0) {
      return -1;
    }
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return i;
      }
    }
    return -1;
  }

  // ---------------------------------------------------------------- 内部

  private static read(key: string): string {
    try {
      return PreferenceStore.getInstance().getString(key, '');
    } catch (err) {
      Logger.ex('读取上次图源失败', err as Object);
      return '';
    }
  }

  private static write(key: string, id: string): void {
    if (id.length === 0) {
      return;
    }
    // putString 内部把 BusinessError 转成 Error 抛出，这里必须兜住 rejected：
    // 调用点是 chip 的 onClick，不该因持久化失败冒泡打断切源。
    PreferenceStore.getInstance().putString(key, id)
      .catch((err: Object): void => {
        Logger.ex('写入上次图源失败', err);
      });
  }
}
