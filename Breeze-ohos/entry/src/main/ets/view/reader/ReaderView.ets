/**
 * 职责：阅读器视图 —— 横向翻页（Swiper）+ 单击屏中显隐自定义顶栏 + 双指缩放 + 左右点按翻页 + 进度落库。
 * 设置接线（s7a）：阅读方向读 util/UserSettings.readDirection()，rtl 时给 Swiper 加 .direction(Rtl)
 *      —— 布局方向会向下继承，页内左中右三个点按热区随 Row 一起镜像，所以热区的回调不换位
 *      （child0 恒为「上一页」，rtl 下它自然落到屏幕右侧），与上游 reverseHorizontalPageTurn
 *      「交换左右翻页方向」的用户预期一致。放大后点按的行为由 reader_tap_to_scroll 决定：
 *      开 = 平移画面（钳在放大后的可视边界内），关 = 仍然翻页。两项都在 pages/SettingPage 里改。
 * 依赖：Theme/Dim；data 层 SourceManager / MangaSource / ImageCache / MangaRepository；@kit.ImageKit。
 * 对应 Flutter：lib/page/comic_read/widgets/modes/row_mode.dart（横向阅读）
 *              + widgets/chrome/app_bar.dart / bottom.dart（阅读器顶底栏）。
 * 说明：本页是二级全屏页（无底栏），由 pages/ReaderPage.ets 承载路由；
 *      阅读器不依赖系统状态栏，顶栏显隐即「全屏沉浸」。
 */

import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { image } from '@kit.ImageKit';
import { Theme, Dim } from '../common/Theme';
import { SourceManager } from '../../data/source/SourceManager';
import { MangaSource } from '../../data/source/Source';
import { ImageCache } from '../../data/image/ImageCache';
import { MangaRepository } from '../../data/db/MangaRepository';
import { UserSettings } from '../../util/UserSettings';
import { ChapterInfo, PageImage } from '../../data/model/Models';

/** 单页图片：自己按 url 从 ImageCache 取 PixelMap（懒加载，Swiper 只实例化可见页） */
@Component
struct ReaderPageImage {
  @Prop @Watch('onUrlChanged') url: string = '';
  /** 图源 id（空 = 未知，走宿主 HTTP；插件图源才走插件取图 + 反混淆意图）。 */
  @Prop sourceId: string = '';
  /** 章节 id（JM 分块数按章节号推导，必须传）。 */
  @Prop chapterId: string = '';
  @State pm: image.PixelMap | undefined = undefined;
  @State failed: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  /** Swiper 会复用节点，url 变更必须重新解码，否则翻页出现上一张图（串图） */
  onUrlChanged(): void {
    this.pm = undefined;
    this.failed = false;
    this.load();
  }

  async load(): Promise<void> {
    if (this.url.length === 0) {
      this.failed = true;
      return;
    }
    try {
      const map: image.PixelMap = await ImageCache.getInstance()
        .loadPage(this.url, this.sourceId, this.chapterId);
      this.pm = map;
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Reader] decode failed: code=${e.code} msg=${e.message}`);
      this.failed = true;
    }
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.pm !== undefined) {
        Image(this.pm)
          .width('100%')
          .height('100%')
          .objectFit(ImageFit.Contain)
          .draggable(false)
      } else if (this.failed) {
        Column() {
          Text('图片加载失败')
            .fontSize(14)
            .fontColor(Theme.white)
          Text('点按左右可翻页')
            .fontSize(12)
            .fontColor(Theme.dTextSecondary)
            .margin({ top: 6 })
        }
      } else {
        LoadingProgress()
          .width(32)
          .height(32)
          .color(Theme.white)
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Component
export struct ReaderView {
  /** 漫画 id（必填） */
  @Prop mangaId: string = '';
  /** 图源 id（必填） */
  @Prop sourceId: string = '';
  /** 漫画标题（顶栏展示） */
  @Prop title: string = '';
  /** 指定章节 id，空则取第一章 */
  @Prop chapterId: string = '';

  @StorageProp('topSafeHeight') topSafe: number = 0;
  @State urls: string[] = [];
  @State pageIndex: number = 0;
  @State chapterName: string = '';
  /** 实际打开的章节 id（用于落库进度；入参 chapterId 为空时取首章） */
  @State currentChapterId: string = '';
  @State loading: boolean = true;
  @State errorMsg: string = '';
  @State chromeVisible: boolean = true;
  @State zoomScale: number = 1;
  @State baseZoomScale: number = 1;
  /** 放大后的平移量（vp）：只有 zoomScale>1 时非零，翻页/重进章节都归零 */
  @State offsetX: number = 0;
  @State offsetY: number = 0;
  /** 阅读区实际尺寸（平移钳位与步长都按它算，onAreaChange 提供） */
  @State areaW: number = 0;
  @State areaH: number = 0;
  /** 进页时读一次：rtl 方向 + 放大后点按是否平移 */
  @State rtl: boolean = false;
  @State tapPans: boolean = false;

  private swiperController: SwiperController = new SwiperController();
  /** 放大判定的死区：缩放回到 1 附近就恢复「点按翻页」，别留 1.0000001 的尾巴 */
  private static readonly ZOOM_EPS: number = 0.02;

  aboutToAppear(): void {
    this.rtl = UserSettings.isRtl();
    this.tapPans = UserSettings.tapToScroll();
    this.loadPages();
  }

  async loadPages(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      if (this.mangaId.length === 0) {
        this.errorMsg = '缺少漫画参数';
        return;
      }
      const src: MangaSource | null = SourceManager.getInstance().get(this.sourceId);
      if (src === null) {
        this.errorMsg = '图源未就绪';
        return;
      }
      const chapters: ChapterInfo[] = await src.fetchChapters(this.mangaId);
      if (chapters.length === 0) {
        this.errorMsg = '该漫画暂无章节';
        return;
      }
      let target: ChapterInfo = chapters[0];
      if (this.chapterId.length > 0) {
        for (let i = 0; i < chapters.length; i++) {
          if (chapters[i].id === this.chapterId) {
            target = chapters[i];
            break;
          }
        }
      }
      this.chapterName = target.title;
      this.currentChapterId = target.id;
      const pages: PageImage[] = await src.fetchPages(target.id);
      const list: string[] = [];
      for (let i = 0; i < pages.length; i++) {
        list.push(pages[i].url);
      }
      this.urls = list;
      if (list.length === 0) {
        this.errorMsg = '本章节没有图片';
      }
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Reader] load failed: code=${e.code} msg=${e.message}`);
      this.errorMsg = '章节加载失败';
    } finally {
      this.loading = false;
    }
  }

  /**
   * 落库进度，并把 sourceId / title 一起带上（bug④ 修法）。
   * manga 表只有「加入书架」才会写 ⇒ 从发现页直接读的书若不带上这两项，
   * 阅读记录页会因查不到元数据而整页空白。
   */
  private async saveProgress(): Promise<void> {
    try {
      await MangaRepository.getInstance()
        .saveProgress(this.mangaId, this.currentChapterId, this.pageIndex, this.sourceId, this.title);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Reader] saveProgress failed: code=${e.code} msg=${e.message}`);
    }
  }

  private prevPage(): void {
    if (this.pageIndex > 0) {
      this.swiperController.showPrevious();
    }
  }

  private nextPage(): void {
    if (this.pageIndex < this.urls.length - 1) {
      this.swiperController.showNext();
    }
  }

  /** 放大后允许的最大平移：内容放大后超出视口的那一半（锚点是中心） */
  private maxOffsetX(): number {
    return this.areaW * (this.zoomScale - 1) / 2;
  }

  private maxOffsetY(): number {
    return this.areaH * (this.zoomScale - 1) / 2;
  }

  /** 把当前平移量收进钳位框（缩放变小、或视口尺寸刚拿到时都要重算一次） */
  private clampOffsets(): void {
    if (this.zoomScale <= 1 + ReaderView.ZOOM_EPS) {
      this.offsetX = 0;
      this.offsetY = 0;
      return;
    }
    const mx: number = this.maxOffsetX();
    const my: number = this.maxOffsetY();
    if (this.offsetX > mx) {
      this.offsetX = mx;
    } else if (this.offsetX < -mx) {
      this.offsetX = -mx;
    }
    if (this.offsetY > my) {
      this.offsetY = my;
    } else if (this.offsetY < -my) {
      this.offsetY = -my;
    }
  }

  /**
   * 左/右热区：未放大 = 翻页；放大且开了「点按平移」= 沿点的那一侧平移约一屏宽（80% 视口）。
   * 放大但没开该设置时仍按原来的翻页走，行为对老用户零惊喜。
   */
  private tapSide(forward: boolean): void {
    if (this.tapPans && this.zoomScale > 1 + ReaderView.ZOOM_EPS) {
      const step: number = this.areaW > 0 ? this.areaW / this.zoomScale * 0.8 : 200;
      this.offsetX += forward ? -step : step;
      this.clampOffsets();
      return;
    }
    if (forward) {
      this.nextPage();
    } else {
      this.prevPage();
    }
  }

  /** 左/中/右点按热区：左翻、中显隐顶栏、右翻（放在 Swiper 页内，避免遮挡滑动手势） */
  @Builder
  TapZones() {
    Row() {
      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.tapSide(false);
        })

      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.chromeVisible = !this.chromeVisible;
        })

      Column()
        .layoutWeight(1)
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.tapSide(true);
        })
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  ReaderTopBar() {
    Column() {
      Row() {
        Stack() {
          Path({
            width: Dim.backIcon,
            height: Dim.backIcon,
            commands: 'M15.5 5 L7.5 12 L15.5 19'
          })
            .stroke(Theme.white)
            .strokeWidth(2)
            .strokeLineCap(LineCapStyle.Round)
            .strokeLineJoin(LineJoinStyle.Round)
            .fill(Color.Transparent)
        }
        .width(Dim.backHit)
        .height(Dim.backHit)
        .borderRadius(Dim.backHit / 2)
        .onClick(() => {
          this.saveProgress();
          router.back();
        })

        Column() {
          Text(this.title)
            .fontSize(Dim.topBarTitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.white)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          Text(this.chapterName)
            .fontSize(11)
            .fontColor(Theme.dTextSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
            .margin({ top: 2 })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 4 })

        Text(this.urls.length > 0 ? `${this.pageIndex + 1}/${this.urls.length}` : '0/0')
          .fontSize(12)
          .fontColor(Theme.white)
          .maxLines(1)
      }
      .width('100%')
      .height(Dim.topBarH + this.topSafe)
      .padding({
        top: this.topSafe,
        left: 8,
        right: Dim.pagePadding
      })
      .alignItems(VerticalAlign.Center)

      // 第 5 条(1) 例外：这条**保留**。它在阅读器顶栏的深色 scrim 浮层上（背景 = Theme.scrim，
      // 浮在图片之上），半透明白是浮层的视觉边界而非页面分割线；这里也不该用
      // Theme.dividerColor（那是页面色档的浅灰线，压在黑 scrim 上看不见）。
      Divider()
        .strokeWidth(0.5)
        .color('#33FFFFFF')
    }
    .width('100%')
    .backgroundColor(Theme.scrim)
  }

  build() {
    Stack({ alignContent: Alignment.TopStart }) {
      // 阅读区：横向 Swiper + 双指缩放 + 三分区点按（左/中/右）
      Stack({ alignContent: Alignment.Center }) {
        if (this.loading) {
          LoadingProgress()
            .width(36)
            .height(36)
            .color(Theme.white)
        } else if (this.errorMsg.length > 0) {
          Column() {
            Text(this.errorMsg)
              .fontSize(14)
              .fontColor(Theme.white)
            Text('点按重试')
              .fontSize(12)
              .fontColor(Theme.brand)
              .margin({ top: 10 })
              .onClick(() => {
                this.loadPages();
              })
          }
        } else {
          Swiper(this.swiperController) {
            ForEach(this.urls, (item: string, index: number) => {
              // 每页内部分左/中/右三个点按热区：点按不阻断 Swiper 的左右滑动
              Stack({ alignContent: Alignment.Center }) {
                ReaderPageImage({
                  url: item,
                  sourceId: this.sourceId,
                  chapterId: this.currentChapterId
                })
                this.TapZones()
              }
              .width('100%')
              .height('100%')
            }, (item: string, index: number) => 'p' + index)
          }
          .index(this.pageIndex)
          .loop(false)
          .vertical(false)
          .indicator(false)
          .duration(200)
          .width('100%')
          .height('100%')
          .scale({ x: this.zoomScale, y: this.zoomScale })
          .translate({ x: this.offsetX, y: this.offsetY })
          .onChange((index: number) => {
            this.pageIndex = index;
            // 换页必须清平移，否则新页一进来就是歪的（放大态下翻页最容易撞到这个）
            this.offsetX = 0;
            this.offsetY = 0;
            this.saveProgress();
          })
        }
      }
      .direction(this.rtl ? Direction.Rtl : Direction.Ltr)
      .width('100%')
      .height('100%')
      // 平移钳位要有视口尺寸：onAreaChange 比 getWindowSize 可靠（分屏/折叠屏变化会回调）
      .onAreaChange((_o: Area, n: Area) => {
        const w: number = Number(n.width);
        const h: number = Number(n.height);
        if (w > 0 && h > 0 && (w !== this.areaW || h !== this.areaH)) {
          this.areaW = w;
          this.areaH = h;
          this.clampOffsets();
        }
      })
      .gesture(
        PinchGesture({ fingers: 2 })
          .onActionStart(() => {
            this.baseZoomScale = this.zoomScale;
          })
          .onActionUpdate((event: GestureEvent) => {
            let s: number = this.baseZoomScale * event.scale;
            if (s < 1) {
              s = 1;
            }
            if (s > 4) {
              s = 4;
            }
            this.zoomScale = s;
          })
          .onActionEnd(() => {
            if (this.zoomScale < 1.05) {
              this.zoomScale = 1;
            }
            this.baseZoomScale = this.zoomScale;
            // 缩放变小后原平移量可能出界，收尾统一钳一次
            this.clampOffsets();
          })
      )

      // 顶栏：单击屏中切换显隐（隐藏即全屏沉浸）
      if (this.chromeVisible) {
        this.ReaderTopBar();
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.black)
  }
}
