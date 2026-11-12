/**
 * 职责：首页（**s5g 起已从底摘除，暂为未接线组件**）—— 顶部搜索入口 +「继续阅读」+「书架推荐」横向卡片流 + 空态。
 * ⚠ s5g 变更：用户真机反馈「底栏首页和书架重复，内容一致，留一个就行」⇒ 底栏由 5 签收敛为 4 签
 *   （书架/发现/云收藏/更多），本页不再挂 TabContent，BreezeBottomTab 已删除对它的 import。
 *   文件保留是有意的：「继续阅读」区块将来要并入书架页（详情页与阅读记录卡的缺口），
 *   届时直接复用本文件的 recent 加载逻辑（MangaRepository.listHistory + getManga）。
 *   在并入之前，本页不参与运行时路径，页签索引常量（onRequestTab(3)）已失效，勿直接照搬。
 * 依赖：Theme / StateViews；data 层 MangaRepository（listBookshelf / listHistory / getManga）；router。
 * 对应 Flutter：lib/page/home/view/home_page.dart（原版首页多子 Tab，鸿蒙首版收敛为继续阅读+推荐）。
 * 备注：顶部公共顶栏由 pages/Index.ets 统一提供，本页不再自绘顶栏，避免双顶栏。
 */

import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { LoadingView, EmptyView, ErrorView } from '../common/StateViews';
import { MangaRepository } from '../../data/db/MangaRepository';
import { MangaSummary, ReadProgress } from '../../data/model/Models';
import { ReaderParams } from '../reader/ReaderParams';

@Component
export struct HomePage {
  /** 请求切换一级页签（由 BreezeBottomTab 注入） */
  onRequestTab: (index: number) => void = (index: number) => {};

  /** C6-①：纵向主滚动绑定 scroller（所有滚动容器 onDidScroll 只给每帧增量 ⇒ 绝对值必须读 currentOffset，见 §15.9） */
  private homeScroller: Scroller = new Scroller();

  @StorageProp('isDark') isDark: boolean = false;
  /** 继续阅读（按最近进度倒序，最多 6 条） */
  @State recent: MangaSummary[] = [];
  @State recentPage: Map<string, number> = new Map<string, number>();
  /** 书架推荐（最多 6 条） */
  @State recommend: MangaSummary[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.load();
  }

  async load(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      const repo: MangaRepository = MangaRepository.getInstance();
      const shelf: MangaSummary[] = await repo.listBookshelf();
      this.recommend = shelf.length > 6 ? shelf.slice(0, 6) : shelf;

      const history: ReadProgress[] = await repo.listHistory();
      const rec: MangaSummary[] = [];
      const pages: Map<string, number> = new Map<string, number>();
      const limit: number = history.length > 6 ? 6 : history.length;
      for (let i = 0; i < limit; i++) {
        const p: ReadProgress = history[i];
        const m: MangaSummary | null = await repo.getManga(p.mangaId);
        if (m !== null) {
          rec.push(m);
          pages.set(m.id, p.page);
        }
      }
      this.recent = rec;
      this.recentPage = pages;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Home] load failed: code=${e.code} msg=${e.message}`);
      this.errorMsg = '首页数据加载失败';
    } finally {
      this.loading = false;
    }
  }

  private openManga(m: MangaSummary): void {
    const params: ReaderParams = new ReaderParams(m.id, m.sourceId, m.title);
    router.pushUrl({ url: 'pages/ReaderPage', params: params })
      .catch((err: BusinessError) => {
        console.error(`[Home] pushUrl failed: code=${err.code} msg=${err.message}`);
      });
  }

  private pageText(mangaId: string): string {
    const p: number | undefined = this.recentPage.get(mangaId);
    if (p === undefined || p <= 0) {
      return '未开始';
    }
    return `读到第 ${p} 页`;
  }

  @Builder
  SectionTitle(text: string) {
    Row() {
      Text(text)
        .fontSize(15)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text1(this.isDark))
        .layoutWeight(1)
        .textAlign(TextAlign.Start)

      Text('更多')
        .fontSize(12)
        .fontColor(Theme.text3(this.isDark))
        .height(24)
        .padding({ left: 8, right: 2 })
        .textAlign(TextAlign.End)
        .onClick(() => {
          this.onRequestTab(3);
        })
    }
    .width('100%')
    .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 16, bottom: 10 })
  }

  @Builder
  BookCard(item: MangaSummary, subtitle: string) {
    Column() {
      Image(item.coverUrl.length > 0 ? item.coverUrl : $r('app.media.ic_app'))
        .width(96)
        .height(128)
        .objectFit(ImageFit.Cover)
        .borderRadius(Dim.coverRadius)
        .backgroundColor(Theme.coverColor(this.isDark))
        .draggable(false)

      Text(item.title)
        .fontSize(12)
        .fontColor(Theme.text1(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .lineHeight(16)
        .width(96)
        .margin({ top: 6 })
        .textAlign(TextAlign.Start)

      Text(subtitle)
        .fontSize(10)
        .fontColor(Theme.text3(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(96)
        .margin({ top: 2 })
        .textAlign(TextAlign.Start)
    }
    .width(96)
    .margin({ right: 12 })
    // C6-②：点按反馈
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.openManga(item);
    })
  }

  build() {
    Column() {
      // 搜索入口（点击切到「发现」页）
      Row() {
        Text('🔍')
          .fontSize(14)
          .margin({ right: 6 })
        Text('搜索漫画 / 作者')
          .fontSize(14)
          .fontColor(Theme.text3(this.isDark))
          .layoutWeight(1)
          .textAlign(TextAlign.Start)
      }
      .width('100%')
      .height(48)
      .padding({ left: 12, right: 12 })
      .margin({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10 })
      .backgroundColor(Theme.fillColor(this.isDark))
      .borderRadius(Dim.radius)
      .onClick(() => {
        this.onRequestTab(3);
      })

      if (this.loading) {
        LoadingView({ text: '正在整理书架…' })
          .layoutWeight(1)
      } else if (this.errorMsg.length > 0) {
        ErrorView({
          msg: this.errorMsg,
          onRetry: () => {
            this.load();
          }
        })
          .layoutWeight(1)
      } else if (this.recent.length === 0 && this.recommend.length === 0) {
        Column() {
          EmptyView({ text: '这里还很空', hint: '去「发现」找一部漫画，加进书架就会出现在这里' })
            .layoutWeight(1)
          Text('去发现')
            .fontSize(14)
            .fontColor(Theme.brand)
            .height(48)
            .padding({ left: 16, right: 16 })
            .onClick(() => {
              this.onRequestTab(3);
            })
        }
        .layoutWeight(1)
      } else {
        Scroll(this.homeScroller) {
          Column() {
            if (this.recent.length > 0) {
              this.SectionTitle('继续阅读')
              List({ space: 0 }) {
                ForEach(this.recent, (item: MangaSummary) => {
                  ListItem() {
                    this.BookCard(item, this.pageText(item.id));
                  }
                  // C6-③：卡片进场淡入上浮（A6 220ms）
                  .transition(TransitionEffect.OPACITY
                    .combine(TransitionEffect.translate({ y: 12 }))
                    .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
                }, (item: MangaSummary) => 'r_' + item.sourceId + '_' + item.id)
              }
              .listDirection(Axis.Horizontal)
              .height(192)
              .width('100%')
              .padding({ left: Dim.pagePadding, right: 4 })
              .scrollBar(BarState.Off)
            }

            if (this.recommend.length > 0) {
              this.SectionTitle('书架推荐')
              List({ space: 0 }) {
                ForEach(this.recommend, (item: MangaSummary) => {
                  ListItem() {
                    this.BookCard(item, item.author.length > 0 ? item.author : '未知作者');
                  }
                  .transition(TransitionEffect.OPACITY
                    .combine(TransitionEffect.translate({ y: 12 }))
                    .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
                }, (item: MangaSummary) => 'b_' + item.sourceId + '_' + item.id)
              }
              .listDirection(Axis.Horizontal)
              .height(192)
              .width('100%')
              .padding({ left: Dim.pagePadding, right: 4 })
              .scrollBar(BarState.Off)
            }

            // C6-④：底部预留（悬浮胶囊 16 + 56），原 24 高的收尾垫高到 contentBottomReserve
            Row().width('100%').height(Dim.contentBottomReserve)
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        // C6-①：Scroll.onDidScroll 的 yOffset 也是「每帧增量」（SDK scroll.d.ts:1397 per frame + 正方向语义存疑），
        // 不能当绝对偏移用 ⇒ 与 List/Grid 同法读 scroller 累计偏移（SDK 里 ScrollOnScrollCallback 的注释就是 offset per frame）
        .onDidScroll((_x: number, _y: number, _state: ScrollState) => {
          Anim.reportTopBar(this.homeScroller.currentOffset().yOffset);
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
