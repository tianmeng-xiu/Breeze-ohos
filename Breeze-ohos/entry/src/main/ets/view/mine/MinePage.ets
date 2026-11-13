/**
 * 职责：我的（s14 第 2 条起为一级 Tab 2，即原版「更多」）—— 分组设置列表：阅读设置 / 存储 / 记录 /
 *   云端 / 插件 / 关于，行高 56vp。
 * 依赖：Theme；promptAction（占位项提示）。公共顶栏由 pages/Index.ets 统一提供。
 * 对应 Flutter：lib/page/…「更多」页与其设置分组（原版为 apps_outlined 页签下的功能聚合）。
 *
 * 要求1（重叠项去重，s8 二轮）：一轮只把「外观模式」改成只读状态 + 点击跳通用设置，用户 2026-11-11 22:12
 *   回传仍判为重复（两行点进去是同一个页面）⇒ 本轮**整组撤掉「外观」分组**，外观档只在通用设置里改。
 *   组内另一行「跟随图源标签」是未接入的 toast 占位，撤完只剩这一条死入口，故一并撤（不留空卡片）。
 * 要求8（新增关于页）：「版本」「开源许可」两行与底部页脚统一跳 pages/AboutPage（第 11 条路由）；
 *   连点开诊断的隐藏入口（原 onTapVersion，AppStorage diagGate）随版本行一起搬到 AboutPage 版本行上。
 * 第 9 条（s9 二轮，用户 11-12 13:48「合并版本和开源许可在更多设置内为一项」）：关于分组两条入口合成一条
 *   「关于」（摘要位置给版本号），底部页脚同时改成**不跳页的纯文案** ⇒ 本页关于入口只剩一项；
 *   关于页内部「版本」「许可」两段内容一字未删（用户要合并的是入口，不是砍内容）。
 * 第 4 条（s9 二轮）：阅读记录条数改成「阅读器退出推版本号 + 本页自己重算」（historyRevision / recountHistory），
 *   不再依赖用户碰巧进过书架或阅读记录页才刷新。
 * 存储两行（BUG5）：占用走 ImageCache.diskUsageAsync（文案与设置页共用 CacheUsageText），
 *   清理调 ImageCache.clear；任一入口清理后推 cacheRevision，另一页靠 @StorageProp + @Watch 重算。
 * 第 6 条（s13）：「阅读模式」从 toast 占位改成真选项（横向翻页 / 从上向下滚动），
 *   档位存 util/UserSettings（键 reader_scroll_mode）并同步推 AppStorage 的 readerScrollMode ⇒
 *   阅读器还在路由栈里时改档也能立刻翻档。摘要走取值函数（不写死字符串），
 *   交互沿用 pages/SettingPage.ets:172 阅读方向那套 showActionMenu。
 *   「图片适配」按要求 5 保持占位不动（用户：之后完善阅读器时再处理）。
 * 第 2 条（s14）：底栏三签化后云收藏退出底栏 ⇒ 本页新增「云端」分组，一行「从云端同步」跳
 *   pages/CloudSyncPage（router 页，包壳复用 view/cloud/CloudPage，页面本体零改动）。
 *   放在「记录」与「插件」之间：它既不是设置项、也不是本地记录或插件管理，而是一次性的站端 → 本地
 *   数据搬运动作，夹在「看本地数据」与「管插件」中间正好是它的语义位置；单独成组是为了不与
 *   「阅读记录」并列成两行（同组内两行会被读成同类操作）。
 */

import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { Logger } from '../../util/Logger';
import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { TabAutoHide } from '../common/TabAutoHide';
import { BreezeHost } from '../../util/BreezeHost';
import { MangaRepository } from '../../data/db/MangaRepository';
import { ReadProgress } from '../../data/model/Models';
import { ImageCache, DiskUsage, CacheUsageText } from '../../data/image/ImageCache';
import { UserSettings, ReadScrollMode, SettingLabels } from '../../util/UserSettings';

@Component
export struct MinePage {
  onRequestTab: (index: number) => void = (index: number) => {};

  /** C6-①：Scroll 绑 scroller（onDidScroll 只给每帧增量，绝对偏移靠 currentOffset，见 §15.9） */
  private mineScroller: Scroller = new Scroller();

  @StorageProp('isDark') isDark: boolean = false;
  /** C13：版本号真实值（原来硬编码 1.0.0 与 bundle versionName 3.0.37 不一致，装机后无法认包）。 */
  @State versionText: string = '';
  /**
   * T3：阅读记录条数（-1 = 尚未取到）。写入方 = BookshelfPage / HistoryPage，第 4 条起再加本页自己的
   *   recountHistory（由 historyRevision 驱动）；任一写入方 push 后本行自动刷新。
   */
  @StorageProp('readHistoryCount') readCount: number = -1;
  /**
   * BUG5：缓存占用的三态（取 CacheUsageText.P_*）。初值 = 统计中，进本页 aboutToAppear 起算。
   * cacheRevision 由任一清理入口（本页 / 通用设置）推一次，@Watch 里重算 ——
   * 本页是 TabContent 子组件，router.back 回来不重跑 aboutToAppear，只有这条路能刷新（同 readCount 口径）。
   */
  @StorageProp('cacheRevision') @Watch('onCacheRevision') cacheRevision: number = 0;
  @State cachePhase: string = CacheUsageText.P_MEASURING;
  @State cacheBytes: number = 0;
  @State cacheFiles: number = 0;
  private cacheBusy: boolean = false;
  /**
   * 统计轮次序号（不进 @State：只用来判迟到，不参与渲染）。口径与 pages/SettingPage.ets 的
   *   measureSeq 完全一致：clear() 会取消在途统计，但被取消那条要等当前批跑完才 settle、busy 才放开，
   *   清理后的必测若走普通闸门就会被这条「还没 settle 的旧轮」吞掉，行内停在清理前的旧数字。
   */
  private measureSeq: number = 0;
  /**
   * 第 4 条：阅读记录「数据版本号」。写点 = pages/ReaderPage.ets 的 onPageHide（返回键、手势返回、被压栈都回调），
   * 书架页与阅读记录页原有的 readHistoryCount 写点保留不动；本页只在版本号变化时自己重算。
   */
  @StorageProp('historyRevision') @Watch('onHistoryRevision') historyRevision: number = 0;
  /**
   * 第 6 条：阅读模式档位（唯一写口 = util/UserSettings.setScrollMode）。
   * @StorageProp 是为了阅读器里改档时本页摘要也跟着变；本页 aboutToAppear 再按偏好纠一次初值
   * （冷启动没进过阅读器时，AppStorage 那个键还没人灌过，本地默认值可能与库里存的档位不符）。
   */
  @StorageProp('readerScrollMode') scrollMode: string = ReadScrollMode.PAGER;
  /** 第 4 条：重算闸门，防连点/连推版本号时并发查库（与 cacheBusy 同型）。 */
  private historyBusy: boolean = false;

  aboutToAppear(): void {
    // T1：登记本页滚动容器（走常量不写字面量：s14 第 2 条起 IDX_MINE 由 3 改成 2），底栏上滑下沉由 TabAutoHide 统一绑定
    TabAutoHide.attach(TabAutoHide.IDX_MINE, this.mineScroller);
    this.measureCache();
    // 第 4 条：冷启动首次进本 Tab 也要取一次条数（TabContent 子组件之后不会再跑 aboutToAppear，
    //      之后就全靠 historyRevision 变化驱动）
    this.recountHistory();
    // 第 6 条：按偏好纠档位初值，并把值灌进 AppStorage（ReaderView 可能还没建，谁先到谁灌）
    const sm: string = UserSettings.readScrollMode();
    UserSettings.pushScrollMode(sm);
    this.scrollMode = sm;
    BreezeHost.appVersion().then((v: string): void => {
      this.versionText = v;
    }).catch((): void => {
      this.versionText = '';
    });
  }


  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  /** T2/T3：行尾条数文案（-1 未知 ⇒ 空串，0 ⇒ 「暂无」）。 */
  private countText(n: number): string {
    if (n < 0) {
      return '';
    }
    return n === 0 ? '暂无' : (n + ' 条');
  }

  /**
   * BUG5：占用统计（与通用设置同一入口 diskUsageAsync，同一套文案 CacheUsageText）。
   * force=true 供两个「必须测一次」的入口用（本页清理完、以及通用设置清理后推来的 cacheRevision）：
   *   那两处 busy 可能仍被一条已被 clear() 取消、但还没 settle 的旧轮占着，普通闸门会把这次必测静默吞掉。
   *   force 直接开新一轮（旧轮因 seq 过期自动作废）；ImageCache 侧单飞，不会因此叠第二条 walk。
   */
  private measureCache(force: boolean = false): void {
    if (this.cacheBusy && !force) {
      return;
    }
    this.cacheBusy = true;
    this.cachePhase = CacheUsageText.P_MEASURING;
    const seq: number = this.measureSeq + 1;
    this.measureSeq = seq;
    // 追加 B（cache-fix 报的残留，与通用设置同一修法）：先补一次 ImageCache.init 再统计。
    // init 只在 DataBootstrap 里跑且 EntryAbility 不 await ⇒ 冷启动可能跑到它前面；
    // cacheRoot 空串时 ensureCacheRoot() 只能 false ⇒「未就绪，点此重试」点了永远不动。
    // init 幂等（ready + initPromise 双保险），失败只记日志继续统计，不弹错、文案口径不变。
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ImageCache.getInstance().init(ctx)
      .catch((e: Object): void => {
        Logger.ex('补跑 ImageCache.init 失败（继续统计，不弹错）', e);
      })
      .then((): Promise<DiskUsage> => {
        return ImageCache.getInstance().diskUsageAsync();
      })
      .then((u: DiskUsage): void => {
        if (seq !== this.measureSeq) {
          return;
        }
        this.cacheBusy = false;
        this.cacheBytes = u.bytes;
        this.cacheFiles = u.files;
        this.cachePhase = u.ready ? CacheUsageText.P_DONE : CacheUsageText.P_NOT_READY;
      })
      .catch((err: Object): void => {
        Logger.ex('统计缓存占用失败', err);
        if (seq !== this.measureSeq) {
          return;
        }
        this.cacheBusy = false;
        this.cachePhase = CacheUsageText.P_FAILED;
      });
  }

  /** 清理缓存：与通用设置「清空图片缓存」同一实现，清完推版本号让那边一起重算。 */
  private clearCache(): void {
    ImageCache.getInstance().clear().then((): void => {
      this.measureCache(true);
      ImageCache.bumpCacheRevision();
      this.toast('已清空图片缓存');
    }).catch((err: Object): void => {
      Logger.ex('清理图片缓存失败', err);
      this.measureCache(true);
      this.toast('清理失败：' + ((err as Error).message ?? String(err)));
    });
  }

  /**
   * 第 4 条：重算阅读记录条数。口径与 pages/HistoryPage.ets:130、view/bookshelf/BookshelfPage.ets 完全一致
   *   = MangaRepository.listHistory().length（同一条 SELECT，不另算一套）。
   * 失败（含冷启动 db 未就绪）一律**保持原值、绝不写 0**：把「还没查到」显示成「0 条」比不刷新更糟，
   *   与第 3 条书架那个坑同源。真正的「等库就绪」由书架页的 ensureDbReady 负责；阅读器退出时进度刚落库，
   *   数据层必然已就绪，所以这里只需要容错，不需要退避重试。
   */
  private recountHistory(): void {
    if (this.historyBusy) {
      return;
    }
    this.historyBusy = true;
    MangaRepository.getInstance().listHistory()
      .then((rows: ReadProgress[]): void => {
        this.historyBusy = false;
        AppStorage.setOrCreate<number>('readHistoryCount', rows.length);
      })
      .catch((err: Object): void => {
        this.historyBusy = false;
        // 保持原值：readCount 为 -1 时行尾仍是空串（countText），不会被读成「0 条」
        Logger.ex('重算阅读记录条数失败（保持原值不写 0）', err);
      });
  }

  /** 第 4 条：阅读器退出（onPageHide）推的版本号变化 ⇒ 重算条数。 */
  private onHistoryRevision(): void {
    this.recountHistory();
  }

  /** 清理版本号变化（本页或通用设置清的都一样）：重新统计一次。 */
  private onCacheRevision(): void {
    this.measureCache(true);
  }

  /** 缓存行文案（含点击可重试的两种失败态）。 */
  private cacheText(): string {
    return CacheUsageText.of(this.cachePhase, this.cacheBytes, this.cacheFiles);
  }

  /** 第 6 条：阅读模式行摘要（取值函数，不写死；标签与 UserSettings.SettingLabels 同源防漂移）。 */
  private scrollModeText(): string {
    return this.scrollMode === ReadScrollMode.WEBTOON
      ? SettingLabels.READ_SCROLL_MODE[1] : SettingLabels.READ_SCROLL_MODE[0];
  }

  /**
   * 第 6 条：选阅读模式。交互与文案形态照抄 pages/SettingPage.ets:172 的「阅读方向」（同一套
   * showActionMenu 两档），不自己发明第三种控件。setScrollMode 第一步同步推 AppStorage ⇒
   * 本行摘要与阅读器同时跟手，第二步异步落库（失败只 toast，不回滚界面：档位是纯展示偏好）。
   */
  private pickScrollMode(): void {
    promptAction.showActionMenu({
      title: '阅读模式',
      buttons: [
        { text: '横向翻页（默认）', color: Theme.brand },
        { text: '从上向下滚动（条漫）', color: Theme.brand }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse): void => {
      const v: string = res.index === 1 ? ReadScrollMode.WEBTOON : ReadScrollMode.PAGER;
      UserSettings.setScrollMode(v).catch((e: Object): void => {
        this.toast('保存失败：' + String(e));
      });
      // @StorageProp 是单向下发，本地再置一次，避免摘要晚一帧才跟上
      this.scrollMode = v;
      this.toast(v === ReadScrollMode.WEBTOON ? '已改为从上向下滚动' : '已改为横向翻页');
    }).catch((e: Error): void => {
      Logger.i('阅读模式选择取消：' + e.message);
    });
  }

  @Builder
  GroupCard(title: string, items: MineMenuItem[]) {
    Column() {
      Text(title)
        .fontSize(13)
        .fontColor(Theme.text2(this.isDark))
        .width('100%')
        .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 16, bottom: 6 })
        .textAlign(TextAlign.Start)

      Column() {
        ForEach(items, (it: MineMenuItem) => {
          Column() {
            Row() {
              Text(it.label)
                .fontSize(15)
                .fontColor(Theme.text1(this.isDark))
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })

              Text(it.subOf())
                .fontSize(13)
                .fontColor(Theme.text3(this.isDark))
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .margin({ left: 8, right: 4 })

              Text('›')
                .fontSize(18)
                .fontColor(Theme.text3(this.isDark))
            }
            .width('100%')
            .height(Dim.menuItemH)
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            .alignItems(VerticalAlign.Center)
            // C6-②：设置行点按反馈
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              it.onTap();
            })
            .backgroundColor(Theme.cardColor(this.isDark))

            // 第 5 条(1)：卡片底色与页面底色已有层次，不再画明显分割线，行距由 padding 提供
          }
          .width('100%')
        }, (it: MineMenuItem) => it.label + '|' + it.subOf())
      }
      .borderRadius(Dim.radius)
      .clip(true)
    }
    .width('100%')
  }

  build() {
    Column() {
      Scroll(this.mineScroller) {
        Column() {
          this.GroupCard('阅读设置', [
            // 第 6 条：真选项（原来写死「横向翻页」+ toast 占位）。摘要必须走取值函数：
            // @Builder 形参按值传递，把状态值当字符串喂进去就会永远定格在首帧（本仓踩过三次）
            new MineMenuItem('阅读模式', (): string => {
              return this.scrollModeText();
            }, () => {
              this.pickScrollMode();
            }),
            new MineMenuItem('图片适配', (): string => {
              return '适应宽度';
            }, () => {
              this.toast('图片适配将在阅读器内设置');
            })
          ])

          // BUG5：占用是真统计值，失败/未就绪时文案本身就是「点此重试」，点击再统计一次
          this.GroupCard('存储', [
            new MineMenuItem('缓存占用', (): string => {
              return this.cacheText();
            }, () => {
              this.measureCache();
            }),
            new MineMenuItem('清理缓存', (): string => {
              return '';
            }, () => {
              this.clearCache();
            })
          ])

          this.GroupCard('记录', [
            new MineMenuItem('阅读记录', (): string => {
              return this.countText(this.readCount);
            }, () => {
              router.pushUrl({ url: 'pages/HistoryPage' });
            })
          ])

          // s14 第 2 条：云收藏从底栏撤下后在这一行进（label 逐字 = 从云端同步）。
          // 摘要给空串：本页不探测云收藏能力，任何摘要文案都会变成「第二份状态」需要自己维护。
          this.GroupCard('云端', [
            new MineMenuItem('从云端同步', (): string => {
              return '';
            }, (): void => {
              router.pushUrl({ url: 'pages/CloudSyncPage' });
            })
          ])

          this.GroupCard('插件', [
            new MineMenuItem('插件管理', (): string => {
              return '';
            }, () => {
              router.pushUrl({ url: 'pages/PluginManagerPage' });
            }),
            // s7a：宿主级设置页（外观模式、阅读方向、放大点按平移、UA、Cookie、图片缓存统计与清理）
            new MineMenuItem('通用设置', (): string => {
              return '';
            }, () => {
              router.pushUrl({ url: 'pages/SettingPage' });
            })
          ])

          // 第 9 条：「版本」与「开源许可」合并成一条「关于」—— 两行原本都 pushUrl 同一个 pages/AboutPage，是纯重复入口。
          // 摘要位置给版本号，仍走取值函数 subOf ⇒ @State versionText 到货后这行自己换文案（@Builder 形参按值传递的坑）。
          this.GroupCard('关于', [
            new MineMenuItem('关于', (): string => {
              return this.versionText;
            }, (): void => {
              router.pushUrl({ url: 'pages/AboutPage' });
            })
          ])

          Text('Breeze · HarmonyOS Next')
            .fontSize(12)
            .fontColor(Theme.text3(this.isDark))
            .width('100%')
            .textAlign(TextAlign.Center)
            // C6-④：底部预留（悬浮胶囊 16 + 56），原 24 改成 contentBottomReserve
            .margin({ top: 24, bottom: Dim.contentBottomReserve })
            // 要求8（s8）曾让页脚也跳关于页；第 9 条把关于入口收敛成一项，这条已被下面的注释作废
            // 第 9 条：去掉 .clickEffect 与 .onClick（与关于分组同页 = 第二个重复入口）；要求8 的「点击关于进新页」
            //          由上面那条「关于」承担，语义没丢。
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
      // C6-①：Scroll.onDidScroll 的 yOffset 是「每帧增量」不是绝对偏移（SDK scroll.d.ts:1397）⇒ 读 scroller 累计值
      // T1：累计偏移同时喂 TabAutoHide 判方向（s5i：收起动作由它显式执行）
      .onDidScroll((_x: number, _y: number, state: ScrollState) => {
        const y: number = this.mineScroller.currentOffset().yOffset;
        Anim.reportTopBar(y);
        TabAutoHide.onScroll(TabAutoHide.IDX_MINE, y, state);
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}

/**
 * 设置项模型（ArkTS 不允许匿名对象字面量歧义，统一用具名类）。
 * ⚠ 摘要一律存**取值函数**（subOf）而不是字符串：GroupCard 是 @Builder，形参按值传递 ⇒
 *   字符串在调用点就被烤定，之后状态变了这一行不会刷新（本仓两处既有教训：
 *   CommentPage.ets:28、DetailPage.ets:601）。存函数并在 Text 里调用，读到的 @State /
 *   @StorageProp 才会记成该文本节点的依赖，值变了才换文案（BUG5 修复的关键一环）。
 */
export class MineMenuItem {
  label: string;
  subOf: () => string;
  onTap: () => void;

  constructor(label: string, subOf: () => string, onTap: () => void) {
    this.label = label;
    this.subOf = subOf;
    this.onTap = onTap;
  }
}