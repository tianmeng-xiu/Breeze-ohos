/**
 * 职责：搜索页路由参数（唯一权威定义）。
 * 用法：router.pushUrl({ url: 'pages/SearchPage', params: new SearchEntryParams(sourceId) })
 * sourceId 可为空串（= 搜索页自己回落到「全部来源」或第一个真实源）。
 * 为什么单独一个文件：顶栏图标（pages/Index）、发现页残留入口都可能跳搜索页，
 *   ArkTS 禁裸对象字面量（10605038）⇒ 必须有已声明的类。
 * 依据系统 Kit：无。
 */
export class SearchEntryParams {
  /** 期望默认选中的图源 id（空 = 不指定） */
  sourceId: string = '';

  constructor(sourceId: string = '') {
    this.sourceId = sourceId;
  }
}
