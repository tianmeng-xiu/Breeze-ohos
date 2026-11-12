/**
 * 职责：评论区路由参数（唯一权威定义）。
 * 用法：router.pushUrl({ url: 'pages/CommentPage', params: new CommentParams(mangaId, sourceId, title) })
 * 为什么单独一个文件：ArkTS 禁裸对象字面量（10605038），且 DetailPage 是唯一入口，
 *   与 DetailParams 分开是为了各自演进（评论页将来可能要带评论首屏数据，详情参数不该被牵连）。
 * 依据系统 Kit：无。
 */
export class CommentParams {
  mangaId: string = '';
  sourceId: string = '';
  title: string = '';

  constructor(mangaId: string = '', sourceId: string = '', title: string = '') {
    this.mangaId = mangaId;
    this.sourceId = sourceId;
    this.title = title;
  }
}
