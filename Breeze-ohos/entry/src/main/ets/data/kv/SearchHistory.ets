/**
 * 职责：T2 搜索记录 —— 发现页搜索关键词的本地历史（最新在前、去重、上限 20 条）。
 * 存储：复用 preferences（键 PrefKeys.SEARCH_HISTORY），值是 JSON 字符串数组，
 *      编解码直接借用 util/JsonUtil 的 decodeTags（它就是「JSON 字符串数组 ⇄ string[]」，
 *      语义通用且已带异常兜底），不另写一套解析。
 * 依赖：data/kv/PreferenceStore、util/JsonUtil。
 * 调用方：view/discover/DiscoverPage（搜索成功后 record、未搜索时展示 chips、点击回填）。
 *
 * 设计取舍：
 *  - 读用同步（页面 aboutToAppear 要立刻渲染 chips，不等 Promise）；写用异步并**吞异常**，
 *    搜索记录是锦上添花，写失败绝不能冒泡打断搜索流程。
 *  - 不区分图源：一条关键词全局共用（与同类阅读器一致；分图源会把 20 条额度切得过碎）。
 */
import { PreferenceStore, PrefKeys } from './PreferenceStore';
import { decodeTags } from '../../util/JsonUtil';
import { Logger } from '../../util/Logger';

export class SearchHistory {
  /** 最多保留多少条（超出从尾部丢弃） */
  static readonly MAX: number = 20;

  /** 同步读全部（最新在前）。偏好库未就绪时返回空数组，不抛。 */
  static list(): string[] {
    try {
      const raw: string = PreferenceStore.getInstance().getString(PrefKeys.SEARCH_HISTORY, '');
      if (raw.length === 0) {
        return [];
      }
      return SearchHistory.sanitize(decodeTags(raw));
    } catch (err) {
      Logger.ex('读取搜索记录失败', err as Object);
      return [];
    }
  }

  /**
   * 记一条：空串/纯空白忽略；已存在则提到最前（等价于「最近搜过」置顶）；超长截尾。
   * 返回写入后的完整列表，调用方可直接刷 UI，省一次读。
   */
  static async record(keyword: string): Promise<string[]> {
    const kw: string = SearchHistory.norm(keyword);
    if (kw.length === 0) {
      return SearchHistory.list();
    }
    const next: string[] = [kw];
    const old: string[] = SearchHistory.list();
    for (let i = 0; i < old.length && next.length < SearchHistory.MAX; i++) {
      if (old[i] !== kw) {
        next.push(old[i]);
      }
    }
    await SearchHistory.persist(next);
    return next;
  }

  /** 删单条（chips 上的「×」不适用，这里给清空/长按删除留位）。 */
  static async remove(keyword: string): Promise<string[]> {
    const kw: string = SearchHistory.norm(keyword);
    const next: string[] = [];
    const old: string[] = SearchHistory.list();
    for (let i = 0; i < old.length; i++) {
      if (old[i] !== kw) {
        next.push(old[i]);
      }
    }
    await SearchHistory.persist(next);
    return next;
  }

  /** 清空（发现页「清空记录」）。 */
  static async clear(): Promise<void> {
    try {
      await PreferenceStore.getInstance().remove(PrefKeys.SEARCH_HISTORY);
    } catch (err) {
      Logger.ex('清空搜索记录失败', err as Object);
    }
  }

  // ---------------------------------------------------------------- 内部

  private static norm(s: string): string {
    if (s === null || s === undefined) {
      return '';
    }
    return s.trim();
  }

  /** 兜底清洗：去空串、去重复、限长 64（防手改偏好库塞进超长串撑爆 chips 布局）。 */
  private static sanitize(src: string[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < src.length && out.length < SearchHistory.MAX; i++) {
      const v: string = SearchHistory.norm(src[i]);
      if (v.length === 0 || v.length > 64) {
        continue;
      }
      let dup: boolean = false;
      for (let j = 0; j < out.length; j++) {
        if (out[j] === v) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        out.push(v);
      }
    }
    return out;
  }

  private static async persist(list: string[]): Promise<void> {
    try {
      if (list.length === 0) {
        await PreferenceStore.getInstance().remove(PrefKeys.SEARCH_HISTORY);
        return;
      }
      await PreferenceStore.getInstance().putString(PrefKeys.SEARCH_HISTORY, JSON.stringify(list));
    } catch (err) {
      // 写失败只记日志：搜索本身已经成功，不该因记录失败报错
      Logger.ex('写入搜索记录失败', err as Object);
    }
  }
}
