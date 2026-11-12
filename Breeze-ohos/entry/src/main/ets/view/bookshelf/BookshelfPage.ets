/**
 * 职责：书架页（一级 Tab 2）—— 3 列封面网格、进度角标、下拉刷新、点击进阅读器。
 * 依赖：StateViews / Theme；data 层 MangaRepository + Models。公共顶栏由 pages/Index.ets 统一提供。
 * 对应 Flutter：lib/page/bookshelf/view/bookshelf_page.dart + widgets/folder_shelf_page.dart
 *              + widgets/comic_simplify_entry_grid.dart（childAspectRatio 0.75、间距 15、3 列）。
 */

import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { TabAutoHide } from '../common/TabAutoHide';
import { LoadingView, EmptyView, ErrorView } from '../common/StateViews';
import { MangaRepository } from '../../data/db/MangaRepository';
import { MangaSummary, ReadProgress } from '../../data/model/Models';
import { DetailParams } from '../detail/DetailParams';

@Component
export struct BookshelfPage {
  /** 请求切换到某个一级页签（如空态引导去「发现」） */
  onRequestTab: (index: number) => void = (index: number) => {};

  /**
   * C6-①：Grid 的 onDidScroll 只给「每帧增量」（OnScrollCallback = (scrollOffset, scrollState)），
   * 拿不到绝对偏移 ⇒ 必须绑 Scroller，从 currentOffset().yOffset 读累计值喂顶栏斜坡。
   */
  private gridScroller: Scroller = new Scroller();

  @StorageProp('isDark') isDark: boolean = false;
  /** 书架数据版本号：DetailPage 加/移书架后 push（AppStorage 'shelfRevision'），变化即静默重查。
   *  本页是 TabContent 子组件，router.back 回来不会重跑 aboutToAppear，不接这个就会「加完不显示」。 */
  @StorageProp('shelfRevision') @Watch('onShelfRevision') shelfRevision: number = 0;
  @State list: MangaSummary[] = [];
  @State progressMap: Map<string, number> = new Map<string, number>();
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State errorMsg: string = '';

  private onShelfRevision(): void {
    // 初值 0 ⇒ 首次绑定不会误触发（@Watch 只在变化后回调）
    this.reload();
  }

  aboutToAppear(): void {
    // T1：登记本页滚动容器，底栏「上滑下沉隐藏」由 TabAutoHide 统一绑定（页索引 0 = 书架）
    TabAutoHide.attach(TabAutoHide.IDX_SHELF, this.gridScroller);
    this.reload();
  }

  async reload(): Promise<void> {
    if (!this.refreshing) {
      this.loading = this.list.length === 0;
    }
    this.errorMsg = '';
    try {
      const repo: MangaRepository = MangaRepository.getInstance();
      const items: MangaSummary[] = await repo.listBookshelf();
      const history: ReadProgress[] = await repo.listHistory();
      const map: Map<string, number> = new Map<string, number>();
      for (let i = 0; i < history.length; i++) {
        const p: ReadProgress = history[i];
        map.set(p.mangaId, p.page);
      }
      this.list = items;
      this.progressMap = map;
      // T3：顺手把阅读条数推给「更多」页行尾角标（本页已经查过 history，零额外开销；
      // 否则用户没进过阅读记录页时那一行会一直显示「未知」）
      AppStorage.setOrCreate<number>('readHistoryCount', history.length);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Bookshelf] load failed: code=${e.code} msg=${e.message}`);
      this.errorMsg = '书架加载失败';
    } finally {
      this.loading = false;
      this.refreshing = false;
    }
  }

  /** 进度角标文案：无阅读记录时返回空串 */
  private progressText(mangaId: string): string {
    const page: number | undefined = this.progressMap.get(mangaId);
    if (page === undefined || page <= 0) {
      return '';
    }
    return `第 ${page} 页`;
  }

  private openManga(m: MangaSummary): void {
    // 先详情页（s6j 需求 4）：与发现页/搜索页同口径
    const params: DetailParams = new DetailParams(m.id, m.sourceId, m.title);
    router.pushUrl({ url: 'pages/DetailPage', params: params })
      .catch((err: BusinessError) => {
        console.error(`[Bookshelf] pushUrl failed: code=${err.code} msg=${err.message}`);
      });
  }

  @Builder
  CoverCell(item: MangaSummary, progress: string) {
    Column() {
      Stack({ alignContent: Alignment.BottomEnd }) {
        Image(item.coverUrl.length > 0 ? item.coverUrl : $r('app.media.ic_app'))
          .width('100%')
          .aspectRatio(Dim.coverRatio)
          .objectFit(ImageFit.Cover)
          .borderRadius(Dim.coverRadius)
          .backgroundColor(Theme.coverColor(this.isDark))
          .draggable(false)

        if (progress.length > 0) {
          Text(progress)
            .fontSize(10)
            .fontColor(Theme.white)
            .backgroundColor(Theme.scrim)
            .borderRadius(6)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .margin({ right: 6, bottom: 6 })
            .maxLines(1)
        }
      }
      .width('100%')

      Text(item.title)
        .fontSize(12)
        .fontColor(Theme.text1(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(16)
        .margin({ top: 6 })
        .width('100%')
        .textAlign(TextAlign.Start)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    // C6-②：点按反馈（系统触感缩放，A7）
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.openManga(item);
    })
  }

  build() {
    Column() {
      if (this.loading) {
        LoadingView({ text: '正在加载书架…' })
          .layoutWeight(1)
      } else if (this.errorMsg.length > 0) {
        ErrorView({
          msg: this.errorMsg,
          onRetry: () => {
            this.reload();
          }
        })
          .layoutWeight(1)
      } else if (this.list.length === 0) {
        Column() {
          EmptyView({
            text: '书架还是空的',
            hint: '去「发现」找一部漫画加入书架吧'
          })
            .layoutWeight(1)
          Text('去发现')
            .fontSize(14)
            .fontColor(Theme.brand)
            .height(48)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              // s5g 页签顺序：0 书架 / 1 发现 / 2 云收藏 / 3 更多 ⇒ 去发现 = 1
              this.onRequestTab(1);
            })
        }
        .layoutWeight(1)
      } else {
        Refresh({ refreshing: $$this.refreshing }) {
          Grid(this.gridScroller) {
            ForEach(this.list, (item: MangaSummary) => {
              GridItem() {
                this.CoverCell(item, this.progressText(item.id));
              }
              // C6-③：网格项进场（A6 220ms + ease-out），滚动/刷新后新条目淡入上浮
              .transition(TransitionEffect.OPACITY
                .combine(TransitionEffect.translate({ y: 12 }))
                .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
            }, (item: MangaSummary) => item.sourceId + '_' + item.id)
          }
          .columnsTemplate('1fr 1fr 1fr')
          .columnsGap(Dim.gridGap)
          .rowsGap(16)
          // C6-④：底部预留 = 悬浮胶囊底距 16 + 胶囊高 56 ⇒ 末行不被胶囊遮挡（V15）
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12, bottom: Dim.contentBottomReserve })
          .width('100%')
          .height('100%')
          .scrollBar(BarState.Off)
          // C6-①：顶栏斜坡（Grid 回调是每帧增量 ⇒ 读 scroller 的累计偏移）
          // T1：同一个累计偏移交给 TabAutoHide 判方向（s5i：收起由它显式执行，不是框架自动收）
          .onDidScroll((_offset: number, state: ScrollState) => {
            const y: number = this.gridScroller.currentOffset().yOffset;
            Anim.reportTopBar(y);
            TabAutoHide.onScroll(TabAutoHide.IDX_SHELF, y, state);
          })
          // T1：Grid 只有在「有书」时才挂载，aboutToAppear 那次 bind 可能落空 ⇒ 挂载后补一次
          .onAppear(() => {
            TabAutoHide.flush();
          })
        }
        .onRefreshing(() => {
          this.reload();
        })
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}