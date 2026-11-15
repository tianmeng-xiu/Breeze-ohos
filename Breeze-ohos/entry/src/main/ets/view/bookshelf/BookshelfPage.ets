/**
 * 职责：书架页（一级 Tab 2）—— 3 列封面网格、进度角标、下拉刷新、点击进阅读器。
 * 依赖：StateViews / Theme；data 层 MangaRepository + Models。公共顶栏由 pages/Index.ets 统一提供。
 * 第 3 条（冷启动首屏不再要点重试）：数据层初始化在 data/DataBootstrap.ets 的 initDataLayer，而 EntryAbility 不 await 它
 *      ⇒ 首屏常跑在 DbHelper.init 前面，旧写法直接查库必抛「数据库尚未初始化」⇒ 出错误态，要人手点一次重试才出内容。
 *      现在 reload() 先 await repo.init(ctx)（幂等，见 data/db/DbHelper.ets:108）失败再退避重试；空态只在查询成功之后才出现。
 * 新七条第 5 条（删了插件之后，书架里的书删不掉）：本页原本只有「点封面进详情」和空态「去发现」两个触点，
 *      而移出书架的唯一 UI 出口在 pages/DetailPage.ets:384 —— 进详情页要先拿到图源数据，插件已卸 ⇒ 进不去 ⇒ 删不掉（死锁）。
 *      现在长按封面即可「移出书架」：路径上只调 MangaRepository.removeFromBookshelf(id)（data/db/MangaRepository.ets:105，
 *      只删本地 bookshelf 表的一行），不碰图源、不联网 ⇒ 「源还在但不想要」与「源已删的孤儿条目」两种情形同一入口都能删。
 * 对应 Flutter：lib/page/bookshelf/view/bookshelf_page.dart + widgets/folder_shelf_page.dart
 *              + widgets/comic_simplify_entry_grid.dart（childAspectRatio 0.75、间距 15、3 列）。
 */

import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { common } from '@kit.AbilityKit';
import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { TabAutoHide } from '../common/TabAutoHide';
import { LoadingView, EmptyView, ErrorView } from '../common/StateViews';
import { MangaRepository } from '../../data/db/MangaRepository';
import { MangaSummary, ReadProgress } from '../../data/model/Models';
import { DetailParams } from '../detail/DetailParams';
import { SourceManager } from '../../data/source/SourceManager';

/** 第 3 条：等数据库就绪的退避档（毫秒）；首屏最多 1 + 2 次尝试，全失败才落错误态。 */
const READY_RETRY_DELAYS: number[] = [150, 300];

/** 让出若干毫秒：与 data/image/ImageCache.ets:40 的 yieldFrame 同型写法（Promise 包 setTimeout）。 */
function sleepMs(ms: number): Promise<void> {
  return new Promise<void>((resolve: () => void): void => {
    setTimeout((): void => {
      resolve();
    }, ms);
  });
}

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
  /**
   * 第 3 条：是否已完成过一次成功的查询。空态（书架还是空的）只在本开关为真之后才允许渲染，
   * 否则「还没查到」会被显示成「没有书」——这是文案不对的另一半原因。
   */
  @State loadedOnce: boolean = false;
  /** 新七条第 5 条：删除在飞的闸门，防连点长按重复下发同一条 delete。 */
  private removing: boolean = false;

  private onShelfRevision(): void {
    // 初值 0 ⇒ 首次绑定不会误触发（@Watch 只在变化后回调）
    this.reload();
  }

  aboutToAppear(): void {
    // T1：登记本页滚动容器，底栏「上滑下沉隐藏」由 TabAutoHide 统一绑定（页索引 0 = 书架）
    TabAutoHide.attach(TabAutoHide.IDX_SHELF, this.gridScroller);
    this.reload();
  }

  /**
   * 第 3 条：把「等数据层就绪」收进本页。repo.init 转交 DbHelper.init，它是幂等的（data/db/DbHelper.ets:108-123：
   * store 已存在直接返回；init 在飞则共享同一个 initPromise）⇒ 本页 await 它不会与 DataBootstrap 抢建库；
   * 失败时 DbHelper 会把 initPromise 置空 ⇒ 下一次调用是真重试。仍失败才按退避档重试，全败抛出落错误态。
   */
  private async ensureDbReady(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    const repo: MangaRepository = MangaRepository.getInstance();
    let last: Error = new Error('数据库尚未初始化');
    for (let k: number = 0; k <= READY_RETRY_DELAYS.length; k++) {
      try {
        await repo.init(ctx);
        return;
      } catch (err) {
        last = err as Error;
        console.warn('[Bookshelf] 等数据库就绪第 ' + (k + 1) + ' 次失败：' + last.message);
        if (k < READY_RETRY_DELAYS.length) {
          await sleepMs(READY_RETRY_DELAYS[k]);
        }
      }
    }
    throw last;
  }

  async reload(): Promise<void> {
    if (!this.refreshing) {
      this.loading = this.list.length === 0;
    }
    this.errorMsg = '';
    try {
      // 第 3 条：先等库就绪再查（幂等 await + 退避重试），首屏不再撞在未初始化的库上
      await this.ensureDbReady();
      const repo: MangaRepository = MangaRepository.getInstance();
      const items: MangaSummary[] = await repo.listBookshelf();
      const history: ReadProgress[] = await repo.listHistory();
      const map: Map<string, number> = new Map<string, number>();
      for (let i = 0; i < history.length; i++) {
        const p: ReadProgress = history[i];
        map.set(p.mangaId, p.page);
      }
      this.loadedOnce = true;
      this.list = items;
      this.progressMap = map;
      // T3：顺手把阅读条数推给「更多」页行尾角标（本页已经查过 history，零额外开销；
      // 否则用户没进过阅读记录页时那一行会一直显示「未知」）
      AppStorage.setOrCreate<number>('readHistoryCount', history.length);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Bookshelf] load failed: code=${e.code} msg=${e.message}`);
      // 第 3 条：只有真失败（含等库三次都败）才落错误态；loadedOnce 保持原值 ⇒ 空态不会被误显示
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

  /** 新七条第 5 条：源是否还在册。只用来决定确认框怎么说，删除路径本身不读它（孤儿条目必须删得掉）。 */
  private sourceAlive(sourceId: string): boolean {
    try {
      return SourceManager.getInstance().get(sourceId) !== null;
    } catch (err) {
      console.warn('[Bookshelf] 查图源在册状态失败，按孤儿条目处理：' + (err as Error).message);
      return false;
    }
  }

  /**
   * 新七条第 5 条：长按封面 ⇒ 确认框 ⇒ 移出书架。
   * 刻意不复用 DetailPage 的 onShelf（那条链路要先取到图源数据才渲染得出按钮）；
   * 这里从确认框到落库全程只有本地 bookshelf 表，插件删了、没网也走得通。
   */
  private confirmRemove(m: MangaSummary): void {
    if (this.removing) {
      return;
    }
    const alive: boolean = this.sourceAlive(m.sourceId);
    AlertDialog.show({
      title: '移出书架',
      message: alive
        ? '把《' + m.title + '》从书架移出？阅读进度会保留。'
        : '《' + m.title + '》的图源已经不在册了。要把它从书架移出吗？',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '移出',
        fontColor: Theme.error,
        action: () => {
          this.doRemove(m);
        }
      }
    });
  }

  /** 真正落库：只删 bookshelf 表那一行（不碰图源）；成功后推 shelfRevision，列表由本页 @Watch 重查收敛。 */
  private doRemove(m: MangaSummary): void {
    this.removing = true;
    MangaRepository.getInstance().removeFromBookshelf(m.id).then((): void => {
      this.removing = false;
      // 与 pages/DetailPage.ets:395-408 的 onShelf 同一协议：只推版本号，让本页（及其他订阅者）重查后收敛，
      // 不在这里手改 this.list —— 手改会让 reload() 里的 loading 判据在「删掉最后一本」时误显示加载态。
      const cur: number = AppStorage.get<number>('shelfRevision') ?? 0;
      AppStorage.setOrCreate<number>('shelfRevision', cur + 1);
      promptAction.showToast({ message: '已移出书架' });
    }).catch((err: Object): void => {
      this.removing = false;
      promptAction.showToast({ message: '移出失败：' + (err as BusinessError).message });
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
          // s30 第 7 条「从哪来、到哪去」：这枚封面与详情页头图共享同一条转场线（id 规则 =
          // 'cover_' + sourceId + '_' + 作品 id，两边必须逐字符一致；带 sourceId 是因为不同源的
          // 作品 id 会撞号）。API = sharedTransition（common.d.ts:20241，@since 7，classic router 兼容）。
          // ★ id 只能配在两页各一枚组件上：详情页「相关推荐」那批 DetailCover 刻意**不带** id，
          //   否则一页内同 id 超两枚 = 撞 SDK 上限，转场会挑错目标。
          // s31 第 6 条（用户原话「从书架点开书本和关闭书本的时候动画应当统一……适当放缓动画速度」）：
          // 时长从 contentIn(220) 换 pageHero(360)，与 pages/DetailPage.ets 头图那一枚**逐字同参**。
          // 为什么必须两边同值：共享元素两端各自的 options 里 duration/curve 谁生效由框架决定，
          // 两边不同值时进入与退出的观感会不对称（这正是用户说的「点开是一套、关闭是另一套」）。
          .sharedTransition('cover_' + item.sourceId + '_' + item.id, {
            duration: Anim.pageHero,
            curve: Anim.curveEaseOut(),
            type: SharedTransitionEffectType.Exchange
          })

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
    // 新七条第 5 条：长按 = 移出书架。TapGesture 与 LongPressGesture 系统本身互不冲突，
    // 这里**不要**用 GestureGroup 串（串成 EXCLUDE 会让点按进详情失效，同 SearchPage.ets:731 的口径）。
    .gesture(
      LongPressGesture({ duration: 400 })
        .onAction((): void => {
          this.confirmRemove(item);
        })
    )
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
      } else if (!this.loadedOnce) {
        // 第 3 条：既没成功也没报错（两次重载交错的窗口）⇒ 继续显示加载态，绝不显示「书架还是空的」
        LoadingView({ text: '正在加载书架…' })
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
        Column() {
          // 新七条第 5 条（lead 补，11-12 17:05）：长按是隐藏触点，UI 上零提示 = 用户找不到删除入口。
          // 只在「有书」这一支出现（空态不需要），一行灰字不吃高度，比改成右滑/多选的成本低得多。
          Text('长按封面可移出书架')
            .fontSize(11)
            .fontColor(Theme.text3(this.isDark))
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 2 })
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
        .width('100%')
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}