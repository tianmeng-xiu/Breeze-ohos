/**
 * 职责：搜索页路由参数（唯一权威定义）。
 * 用法：router.pushUrl({ url: 'pages/SearchPage', params: new SearchEntryParams(sourceId, keyword) })
 * sourceId 可为空串（= 搜索页自己回落到「全部来源」或第一个真实源）。
 * keyword 可为空串（= 不带词，只是选源）；非空时搜索页把它灌进输入框并自动搜一次
 *   （s11 第 6 条，用户 11-12 16:15 report 第 6 条：详情页点作者名 / 标签直达「该源 + 该词」的结果页）。
 * 两个参数都带默认值 ⇒ 既有调用点 new SearchEntryParams('')（pages/Index.ets 顶栏搜索图标）
 *   一个字都不用改 ⇒ 加字段不是破坏性变更，Index.ets 无需同步改（我写域外，本来也不该动）。
 * 为什么单独一个文件：顶栏图标（pages/Index）、发现页残留入口、详情页都可能跳搜索页，
 *   ArkTS 禁裸对象字面量（10605038）⇒ 必须有已声明的类。
 * 依据系统 Kit：无。
 */
export class SearchEntryParams {
  /** 期望默认选中的图源 id（空 = 不指定） */
  sourceId: string = '';
  /** 期望直接搜的关键词（空 = 不带词；非空 = 灌进输入框并自动搜一次） */
  keyword: string = '';

  constructor(sourceId: string = '', keyword: string = '') {
    this.sourceId = sourceId;
    this.keyword = keyword;
  }
}
