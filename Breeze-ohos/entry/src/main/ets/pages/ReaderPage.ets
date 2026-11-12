/**
 * 职责：阅读器路由页（二级页，无底栏、无公共顶栏，顶栏由 ReaderView 自行控制显隐）。
 * 依赖：view/reader/ReaderView、view/reader/ReaderParams。
 * 第 4 条：本页面加 onPageHide 推 historyRevision。阅读进度落库点在 view/reader/ReaderView.ets 的 saveProgress
 *   （换页与返回键都调，很频繁）⇒ 不在那里查条数；退出阅读器的出口（返回键、手势返回、被新页压栈）只有本页的
 *   onPageHide 全覆盖，所以只推一个版本号，条数由 view/mine/MinePage.ets 自己重算。
 * 对应 Flutter：lib/page/comic_read/comic_read_page.dart。
 */
import { router } from '@kit.ArkUI';
import { ReaderParams } from '../view/reader/ReaderParams';
import { ReaderView } from '../view/reader/ReaderView';
import { Theme } from '../view/common/Theme';

@Entry
@Component
struct ReaderPage {
  @State params: ReaderParams = new ReaderParams();
  @StorageProp('isDark') isDark: boolean = false;

  aboutToAppear(): void {
    try {
      const raw: Object = router.getParams();
      if (raw instanceof ReaderParams) {
        this.params = raw;
      } else if (raw !== null && raw !== undefined) {
        // 兼容仅传 JSON 对象的场景：逐字段读取，避免 ArkTS 结构类型互赋
        const p: ReaderParams = new ReaderParams();
        const src: ESObject = raw;
        p.mangaId = src.mangaId !== undefined ? String(src.mangaId) : '';
        p.sourceId = src.sourceId !== undefined ? String(src.sourceId) : '';
        p.title = src.title !== undefined ? String(src.title) : '';
        p.chapterId = src.chapterId !== undefined ? String(src.chapterId) : '';
        this.params = p;
      }
    } catch (e) {
      // 参数缺失时保持空路由参数，ReaderView 内做空态处理
    }
  }

  /**
   * 第 4 条：@Entry 页被 router 弹出或被新页盖住都会回调 onPageHide ⇒ 这是退出阅读器的全覆盖出口。
   * 这里只推版本号、不查库（查库与口径判断都在 MinePage.recountHistory，与 HistoryPage 同一条 SELECT）。
   */
  onPageHide(): void {
    AppStorage.setOrCreate<number>('historyRevision', (AppStorage.get<number>('historyRevision') ?? 0) + 1);
  }

  build() {
    Column() {
      ReaderView({
        mangaId: this.params.mangaId,
        sourceId: this.params.sourceId,
        title: this.params.title,
        chapterId: this.params.chapterId
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.isDark ? '#000000' : Theme.bg)
  }
}
