/**
 * 职责：搜索结果大图栅格的封面卡（T9 需求 3）—— 封面走 ImageCache（PixelMap 由缓存持有，
 *      调用方不 release），空地址/加载失败给占位色块不留白洞；标题两行 + 图源小字。
 * 依赖：data/image/ImageCache、view/common/Theme；@kit.ImageKit。
 * 说明：单独成组件是因为每张卡要各自异步取图（@State pm），页面层只管布局与点击。
 */
import { image } from '@kit.ImageKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Dim } from './Theme';
import { ImageCache } from '../../data/image/ImageCache';

@Component
export struct MangaGridCard {
  /** 作品标题（@Prop 原始类型，父层换数据自动刷新） */
  @Prop title: string = '';
  /** 封面地址（空串 = 直接占位块） */
  @Prop @Watch('onCoverChanged') coverUrl: string = '';
  /** 图源小字（如 MangaDex / 禁漫天堂） */
  @Prop sourceName: string = '';
  @StorageProp('isDark') isDark: boolean = false;
  @State pm: image.PixelMap | undefined = undefined;
  @State failed: boolean = false;
  /**
   * s21 黑区修法：与 @State pm 分开的**持有账本**（同 view/reader/ReaderView.ets 的 held/setShown 口径）。
   * 「清理图片缓存」与 LRU 淘汰都不该 release 仍在显示的那一张：被 release 后 Image 画整幅纯黑，
   * 不抛异常也不留日志（阅读器上的同款缺陷就是那条黑区）。
   */
  private held: image.PixelMap | undefined = undefined;

  aboutToAppear(): void {
    this.load();
  }

  aboutToDisappear(): void {
    this.setShown(undefined);
  }

  /** 挂载/摘除唯一入口：retain 在前、unpin 在后，再把值喂给 @State。 */
  private setShown(next: image.PixelMap | undefined): void {
    const prev: image.PixelMap | undefined = this.held;
    if (next !== undefined) {
      ImageCache.getInstance().retain(next);
      this.held = next;
    } else {
      this.held = undefined;
    }
    this.pm = next;
    if (prev !== undefined && prev !== next) {
      ImageCache.getInstance().unpin(prev);
    }
  }

  /** Grid 虚拟滚动可能复用节点：地址变了必须清掉旧图重取，否则串封面 */
  onCoverChanged(): void {
    this.setShown(undefined);
    this.failed = false;
    this.load();
  }

  private async load(): Promise<void> {
    if (this.coverUrl.length === 0) {
      this.failed = true;
      return;
    }
    try {
      const map: image.PixelMap = await ImageCache.getInstance().load(this.coverUrl);
      this.setShown(map);
    } catch (err) {
      const e = err as BusinessError;
      console.error('[SearchCard] cover failed: code=' + e.code + ' msg=' + e.message);
      this.failed = true;
    }
  }

  build() {
    Column() {
      // 封面：竖版漫画比例 0.7（宽/高）。解码中 = 占位色块；失败也回到占位块（不留白洞）
      Stack({ alignContent: Alignment.Center }) {
        if (this.pm !== undefined) {
          Image(this.pm)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .draggable(false)
        }
      }
      .width('100%')
      .aspectRatio(0.7)
      .borderRadius(Dim.coverRadius)
      .clip(true)
      .backgroundColor(Theme.fillColor(this.isDark))

      Text(this.title.length > 0 ? this.title : '无标题')
        .fontSize(13)
        .fontColor(Theme.text1(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 6 })

      Text(this.sourceName)
        .fontSize(11)
        .fontColor(Theme.text3(this.isDark))
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 2 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
