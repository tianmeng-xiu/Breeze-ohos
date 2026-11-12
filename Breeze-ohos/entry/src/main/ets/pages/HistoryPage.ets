/**
 * 职责：T3 阅读记录页（二级路由页）—— 按最近阅读时间倒序列出读过的漫画，点一下回到上次的进度。
 * 依赖：view/common/BreezeTopBar、Theme、StateViews；data/db/MangaRepository（listHistory + getManga）；
 *      view/detail/DetailParams（点条目先进详情页，与发现页/书架/搜索页同口径）。
 * 入口：pages/Index「更多」→ MinePage「阅读记录」→ router.pushUrl('pages/HistoryPage')。
 *
 * 数据来源说明（不新建表）：阅读记录 = read_progress 表按 updated_at 倒序，
 * 即 MangaRepository.listHistory()（阅读器每次 saveProgress 都会刷新 updated_at，见 ReaderView:159）。
 * 因此这里**只读**，不额外写库；一部漫画一条（覆盖式进度），与书架的进度角标同源，不会出现两套记录打架。
 */
import { promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { LoadingView, EmptyView, ErrorView } from '../view/common/StateViews';
import { MangaRepository } from '../data/db/MangaRepository';
import { MangaSummary, ReadProgress } from '../data/model/Models';
import { DetailParams } from '../view/detail/DetailParams';

@Component
struct HistoryRowItem {
  coverUrl: string = '';
  title: string = '';
  sub: string = '';
  time: string = '';
  /**
   * ⚠ 必须 @Prop 不能裸字段：父组件传的是 @StorageProp('isDark') 的值，
   * ArkTS V1 禁止「被装饰变量 → 未装饰普通属性」（10905315 The '@StorageProp' property
   * 'isDark' cannot be assigned to the 'regular' property 'isDark'，s5h 首编实测）。
   */
  @Prop isDark: boolean = false;
  onTap: () => void = () => {};

  build() {
    Row() {
      Image(this.coverUrl.length > 0 ? this.coverUrl : $r('app.media.ic_app'))
        .width(44)
        .height(58)
        .objectFit(ImageFit.Cover)
        .borderRadius(6)
        .backgroundColor(Theme.coverColor(this.isDark))
        .draggable(false)
        .margin({ right: 12 })

      Column() {
        Text(this.title)
          .fontSize(14)
          .fontColor(Theme.text1(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(this.sub)
          .fontSize(12)
          .fontColor(Theme.text2(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 4 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text(this.time)
        .fontSize(11)
        .fontColor(Theme.text3(this.isDark))
        .margin({ left: 8 })
    }
    .width('100%')
    .height(Dim.listItemH)
    .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.onTap();
    })
  }
}

@Entry
@Component
struct HistoryPage {
  @StorageProp('isDark') isDark: boolean = false;
  /** 一行 = 一条进度 + 它对应的漫画（getManga 查不到就跳过：本地图库里没这本书说明是历史记录残留） */
  @State rows: HistoryEntry[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';

  aboutToAppear(): void {
    this.reload();
  }

  async reload(): Promise<void> {
    this.loading = true;
    this.errorMsg = '';
    try {
      const repo: MangaRepository = MangaRepository.getInstance();
      const history: ReadProgress[] = await repo.listHistory();
      const out: HistoryEntry[] = [];
      for (let i = 0; i < history.length; i++) {
        const p: ReadProgress = history[i];
        const m: MangaSummary | null = await repo.getManga(p.mangaId);
        const e = new HistoryEntry();
        e.mangaId = p.mangaId;
        e.page = p.page;
        e.updatedAt = p.updatedAt;
        if (m !== null) {
          // 有加过书架（或详情页缓存过）⇒ 用完整元数据，封面/作者都在
          e.sourceId = m.sourceId;
          e.title = m.title;
          e.coverUrl = m.coverUrl;
        } else {
          // bug④：读过但没加书架的书 manga 表没行 —— 用进度行自带的 source_id / title 兜住。
          // 之前这里是 continue ⇒ 全部跳过 ⇒ 整页空白（角标条数却还是对的）。
          e.sourceId = p.sourceId;
          e.title = p.title.length > 0 ? p.title : '未知作品';
          e.coverUrl = '';
        }
        if (e.sourceId.length === 0) {
          // 连来源都不知道 ⇒ 点进去必然「图源未就绪」，这种残留行不显示
          continue;
        }
        out.push(e);
      }
      this.rows = out;
      // 本页是阅读记录条数的权威写入方：载入后推给「更多」页行尾角标（@StorageProp 自动刷新，
      // 因为 MinePage 是 TabContent 子组件，它自己的 onPageShow 不会触发）
      AppStorage.setOrCreate<number>('readHistoryCount', out.length);
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[History] load failed: code=${e.code} msg=${e.message}`);
      this.errorMsg = '阅读记录加载失败';
    } finally {
      this.loading = false;
    }
  }

  private open(e: HistoryEntry): void {
    // 先详情页（s6j 需求 4）：详情页会自己读进度并给出「继续阅读」
    const params: DetailParams = new DetailParams(e.mangaId, e.sourceId, e.title);
    router.pushUrl({ url: 'pages/DetailPage', params: params })
      .catch((err: BusinessError) => {
        console.error(`[History] pushUrl failed: code=${err.code} msg=${err.message}`);
      });
  }

  /** 清空全部阅读记录（进度表整表清 = 书架进度角标一并消失，这一点在确认框里写明白）。 */
  private confirmClear(): void {
    if (this.rows.length === 0) {
      promptAction.showToast({ message: '还没有阅读记录' });
      return;
    }
    AlertDialog.show({
      title: '清空阅读记录',
      message: '将清除全部 ' + this.rows.length + ' 条阅读进度，书架上的页码角标也会一并消失。',
      autoCancel: true,
      alignment: DialogAlignment.Center,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '清空',
        fontColor: Theme.error,
        action: () => {
          MangaRepository.getInstance().clearProgress().then((): void => {
            this.rows = [];
            AppStorage.setOrCreate<number>('readHistoryCount', 0);
            promptAction.showToast({ message: '已清空阅读记录' });
          }).catch((err: Object): void => {
            promptAction.showToast({ message: '清空失败：' + (err as BusinessError).message });
          });
        }
      }
    });
  }

  private subText(e: HistoryEntry): string {
    return e.page > 0 ? ('读到第 ' + e.page + ' 页') : '刚开始读';
  }

  /** 相对时间：刚刚 / N 分钟前 / N 小时前 / 昨天 / M-D（跨年带年份）。避免让用户读毫秒时间戳。 */
  private timeText(ts: number): string {
    if (ts <= 0) {
      return '';
    }
    const diff: number = Date.now() - ts;
    if (diff < 60000) {
      return '刚刚';
    }
    if (diff < 3600000) {
      return Math.floor(diff / 60000) + ' 分钟前';
    }
    if (diff < 86400000) {
      return Math.floor(diff / 3600000) + ' 小时前';
    }
    if (diff < 172800000) {
      return '昨天';
    }
    const d: Date = new Date(ts);
    const y: number = d.getFullYear();
    const nowY: number = new Date().getFullYear();
    const md: string = (d.getMonth() + 1) + '-' + d.getDate();
    return y === nowY ? md : (y + '-' + md);
  }

  build() {
    Column() {
      BreezeTopBar({
        title: '阅读记录',
        showBack: true,
        actionText: this.rows.length > 0 ? '清空' : '',
        scrollProgress: 1,
        onBack: (): void => {
          router.back();
        },
        onAction: (): void => {
          this.confirmClear();
        }
      })

      if (this.loading) {
        LoadingView({ text: '正在读取记录…' })
          .layoutWeight(1)
      } else if (this.errorMsg.length > 0) {
        ErrorView({
          msg: this.errorMsg,
          onRetry: () => {
            this.reload();
          }
        })
          .layoutWeight(1)
      } else if (this.rows.length === 0) {
        EmptyView({
          text: '还没有阅读记录',
          hint: '去「发现」找一部漫画开始阅读'
        })
          .layoutWeight(1)
      } else {
        List({ space: 0 }) {
          ForEach(this.rows, (it: HistoryEntry) => {
            ListItem() {
              HistoryRowItem({
                coverUrl: it.coverUrl,
                title: it.title,
                sub: this.subText(it),
                time: this.timeText(it.updatedAt),
                isDark: this.isDark,
                onTap: () => {
                  this.open(it);
                }
              })
            }
          }, (it: HistoryEntry) => it.mangaId + '_' + it.updatedAt)
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: Theme.dividerColor(this.isDark), startMargin: Dim.pagePadding + 56, endMargin: Dim.pagePadding })
        .scrollBar(BarState.Off)
        // 二级页没有悬浮底栏，但仍留一点呼吸，末行不至于贴屏幕边
        .contentEndOffset(24)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}

/** ArkTS 严格模式：对象字面量必须 new 已声明类（10605038）⇒ 视图模型显式声明 */
class HistoryEntry {
  mangaId: string = '';
  sourceId: string = '';
  title: string = '';
  coverUrl: string = '';
  page: number = 0;
  updatedAt: number = 0;
}
