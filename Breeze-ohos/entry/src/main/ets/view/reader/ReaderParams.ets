/**
 * 职责：阅读器路由参数（pages/ReaderPage 与 view/ReaderView 共用），router 传参的唯一形状。
 * 依赖：无。
 * 对应 Flutter：lib/page/comic_read/* 的路由参数（comicId / sourceKey / chapterId）。
 * 用法：router.pushUrl({ url: 'pages/ReaderPage', params: new ReaderParams(id, sourceId, title) })
 */
export class ReaderParams {
  mangaId: string = '';
  sourceId: string = '';
  title: string = '';
  chapterId: string = '';

  constructor(mangaId: string = '', sourceId: string = '', title: string = '', chapterId: string = '') {
    this.mangaId = mangaId;
    this.sourceId = sourceId;
    this.title = title;
    this.chapterId = chapterId;
  }
}
