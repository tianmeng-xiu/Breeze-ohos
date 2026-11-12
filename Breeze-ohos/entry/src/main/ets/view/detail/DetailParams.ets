/**
 * 职责：详情页路由参数（唯一权威定义，任何跳转都用它，别手写对象字面量）。
 * 用法：router.pushUrl({ url: 'pages/DetailPage', params: new DetailParams(m.id, m.sourceId, m.title) })
 * 为什么单独一个文件：SearchPage / DiscoverPage / 书架 / 阅读记录页 都要跳详情，
 *   ArkTS 禁裸对象字面量（10605038）⇒ 必须有已声明的类，放这里避免各处重复声明。
 * 依据系统 Kit：无。
 */
export class DetailParams {
  /** 图源内作品 id */
  mangaId: string = '';
  /** 图源 id（内置 'mangadex' 或插件 'plugin:<uuid>'） */
  sourceId: string = '';
  /** 标题（详情还没拿到时先占位显示） */
  title: string = '';

  constructor(mangaId: string = '', sourceId: string = '', title: string = '') {
    this.mangaId = mangaId;
    this.sourceId = sourceId;
    this.title = title;
  }
}
