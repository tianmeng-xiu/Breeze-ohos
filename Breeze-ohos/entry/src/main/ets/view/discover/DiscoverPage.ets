/**
 * 职责：发现页（一级 Tab 1，s5g 页签收敛后）—— 可随滚动收起的工具区（图源切换条）
 *      + 当前图源排行榜（行高 72vp）。
 * s9 需求 5（用户 2026-11-11 22:12）：工具区底部那条 0.5vp Divider 已删 —— 用户口径「明显分割线
 *      很难看」。删线后工具区内容真实高变 50vp，收起动画吃的高度与布局值改为共读本页两个字段
 *      （toolChipGap 与 toolChipRowH）相加得 51.5，不再手抄两个数各算各的（同 BUG6 定案的口径）。
 *      s5i：搜索框改纯入口（点击 push pages/SearchPage，NextE 样式，记录/来源切换都在搜索页）；
 *      图源 chip 条随 pluginSourceEpoch 与插件管理页联动刷新（任务 A）。
 * s10 第 7 条（用户 11-12 13:48）：图源选择跨启动记忆 —— chip 选中即把**源 id**（不是下标）写进
 *      view/search/LastSourceStore（复用 PreferenceStore 单例）；进页与 epoch 刷新都按 id 复原，
 *      源被卸载才回落第一个。本页是 TabContent 子组件，aboutToAppear 只跑一次，故复原挂在
 *      loadPopular 取到列表之后（每次取列表都校验一次 id 是否还在，比挂在生命周期可靠）。
 * 依赖：StateViews / Theme / Anim；data 层 SourceManager / MangaSource。公共顶栏由 pages/Index.ets 统一提供。
 * 对应 Flutter：lib/page/discover/view/discover_page.dart（原版为插件市场，鸿蒙端简化为源列表+排行榜+搜索）。
 */

import { router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { TabAutoHide } from '../common/TabAutoHide';
import { LoadingView, EmptyView, ErrorView } from '../common/StateViews';
import { SourceManager } from '../../data/source/SourceManager';
import { MangaSource } from '../../data/source/Source';
import { MangaSummary, SourceInfo } from '../../data/model/Models';
import { DetailParams } from '../detail/DetailParams';
import { LastSourceStore } from '../search/LastSourceStore';
import { Logger } from '../../util/Logger';
import { TextConvert } from '../../util/TextConvert';

@Component
export struct DiscoverPage {
  onRequestTab: (index: number) => void = (index: number) => {};

  /** C6-①：纵向榜单 List 绑 scroller（List.onDidScroll 只给每帧增量，需读累计偏移） */
  private listScroller: Scroller = new Scroller();

  @StorageProp('isDark') isDark: boolean = false;
  /**
   * 简繁转换版本号（util/TextConvert.bumpRev 在词典就绪或切档后自增）：
   * 词典是异步读的，首帧拿到的是原文，就绪后靠它把这一屏重算一遍。
   * 必须在渲染表达式里读到一次（见 cvtShow），只声明不用不会触发重渲染。
   */
  @StorageProp('textConvertRev') cvtRev: number = 0;

  /** 显示文案过一遍简繁转换（只改显示，不参与搜索匹配与屏蔽词匹配）。 */
  private cvtShow(raw: string): string {
    const rev: number = this.cvtRev;
    if (rev <= 0) {
      // 本进程还没就绪过词典也没切过档 = 首帧，原样给，连表都不查
      return raw;
    }
    return TextConvert.getInstance().cvt(raw);
  }
  /** 任务 A②：插件装载/删除/开关后 chip 条同步（bump 端 = PluginManagerView）。 */
  @StorageProp('pluginSourceEpoch') @Watch('onSourceEpoch') pluginEpoch: number = 0;
  @State sources: SourceInfo[] = [];
  @State sourceIndex: number = 0;

  /**
   * 本次进程里用户是否手动选过源（第 7 条）。false = 还没选过 ⇒ loadPopular 取到列表后按上次记忆复原；
   * true = 用户的选择优先，取列表时不许被记忆覆盖（否则切完源后来一次 epoch 刷新就把用户选的回滚了）。
   * 不用 @State：只参与判断，不参与渲染。
   */
  private userPickedSource: boolean = false;
  @State items: MangaSummary[] = [];
  @State loading: boolean = true;
  @State errorMsg: string = '';
  /** s5g：榜单累计偏移超过阈值 ⇒ 顶部工具区收起（配合工具区上的 .animation 做高度/透明度过渡） */
  @State toolCollapsed: boolean = false;

  /**
   * 图源条与工具区顶部的间距（vp）：布局（Scroll 的 margin-top）与折叠高度（toolBarH）共读这一个字段。
   * 不用 @State：它是常量，不参与重渲染。
   */
  private toolChipGap: number = 6;

  /** 图源条行高（vp）：chip 32 上下各留 6，同样是布局与折叠共读的单一来源。 */
  private toolChipRowH: number = 44;

  /**
   * 工具区折叠动画吃的总高（vp）。s9 删掉底部那条 Divider（连同它的 margin-top 8）后，
   * 内容真实高 = margin-top 6 加 行高 44 = 50；原先手抄的 59（= 6 + 44 + 0.5 + 8）已随那条线作废。
   *
   * 取 51.5 = 50 加 1.5 余量，**只多不少**。逐层算清楚：外层 Column 带 clip(true)，内容底边
   * 无论按哪种竖向对齐算都在 50 以内 —— 顶对齐时 = margin-top 6 加行高 44 = 50；外层 Column
   * 默认 justifyContent 是 Center ⇒ 声明值多出的 1.5 会均摊成上下各 0.75，内容底 50.75。
   * 而 chip 自己在 44 高的行里竖向居中（height(32) 写死，Scroll 行内不会把它拉满），
   * 所以 chip 底边最迟落在 50.75 - 6 = 44.75，离裁剪线 51.5 至少 6.75vp ⇒ 不会重演 BUG6 的
   * 「底圆角被切平」。反过来声明值偏小一定切，所以宁可留白不裁字。
   * 注：本 SDK 的 scroll.d.ts 没有 Scroll.align 声明（只有 scrollToIndex 的 ScrollAlign），
   * 故上面按「顶对齐 / 居中」两种口径各算一遍，结论一致，不依赖这个默认值。
   *
   * 与 SearchPage 的差别：本页没有 onAreaChange 实测链路（工具区只有一个定高 Scroll，
   * 内容高不会随字号漂移 —— chip 写死 height(32)，字体放大时文字自己缩在胶囊内），
   * 所以不需要「实测反哺」，两个字段共读即可。SearchPage 那条实测链路原样保留。
   */
  private toolBarH(): number {
    return this.toolChipGap + this.toolChipRowH + 1.5;
  }

  /**
   * 收起判据：向下滚过 48vp 收起，回到 24vp 以内展开（中间留滞回带，避免临界抖动）。
   * s9 之后工具区真实高从 59 变 51.5，48/24 相对 51.5 的比例（0.93 / 0.47）比原先的 0.81 / 0.41
   * 更接近「滚完整个工具区才收起」，行为只变好不变坏 ⇒ 按 lead 裁定不动这套阈值，
   * SearchPage 那套按真实高成比例的写法（syncToolCollapse）也没有搬过来（无真机投诉，不扩大改动面）。
   */
  private syncToolCollapse(offsetY: number): void {
    const want: boolean = this.toolCollapsed;
    const should: boolean = want ? !(offsetY < 24) : (offsetY > 48);
    if (should !== want) {
      this.toolCollapsed = should;
    }
  }

  aboutToAppear(): void {
    // T1：登记本页滚动容器（页索引 1 = 发现），底栏上滑下沉由 TabAutoHide 统一绑定
    TabAutoHide.attach(TabAutoHide.IDX_DISCOVER, this.listScroller);
    // s5i 取证修复（用户反馈「发现页并没有上半部分的过渡」）：
    // ArkUI 的 transition **不对组件首次挂载生效** ⇒ 首屏 List 首次插入是硬切。
    // 这里让内容区在首帧后延迟挂载（先渲染 LoadingView），List 的插入就变成「状态变化引起的挂载」，
    // 从而真正播放淡入上浮；同时覆盖切图源 / epoch 换源 / 重试几条路径。
    setTimeout((): void => {
      this.loadPopular();
    }, 180);
  }

  /**
   * 任务 A②：pluginSourceEpoch 变化 ⇒ 只刷新图源 chip 条。
   * 红线：@Watch 里绝不无条件 loadPopular（bump 时机含「装载但图源集合没变」的场景，
   * 白刷一次网络）。先比 id 序列，一样直接 return；不一样才换 sources 并重载榜单，
   * 且尽量保持当前选中源不跳（找不到才回退第一个）。
   */
  onSourceEpoch(): void {
    const next: SourceInfo[] = SourceManager.getInstance().list();
    if (next.length === this.sources.length) {
      let same: boolean = true;
      for (let i = 0; i < next.length; i++) {
        if (next[i].id !== this.sources[i].id) {
          same = false;
          break;
        }
      }
      if (same) {
        return;
      }
    }
    // 第 7 条：优先按 id 保住当前选中的源（id 比名字稳：插件改了显示名不该把用户的选择弄丢），
    // id 查不到再按名字兜一次（同一源换了 id 的极端情况），两样都没有才回落第一个。
    const curId: string = this.sourceId(this.sourceIndex);
    const curName: string = this.sourceName(this.sourceIndex);
    this.sources = next;
    let keep: number = LastSourceStore.indexOfSource(next, curId);
    if (keep < 0) {
      for (let i = 0; i < next.length; i++) {
        if (next[i].name === curName) {
          keep = i;
          break;
        }
      }
    }
    this.sourceIndex = keep >= 0 ? keep : 0;
    this.loadPopular();
  }

  private currentSource(): MangaSource | null {
    if (this.sources.length === 0) {
      return null;
    }
    const i: number = this.sourceIndex < this.sources.length ? this.sourceIndex : 0;
    return SourceManager.getInstance().get(this.sources[i].id);
  }

  /**
   * A1（用户反馈「搜索栏与排行榜过渡生硬」）：所有驱动内容区换脸的赋值统一走 Anim.to
   * （UIContext.animateTo，220ms EaseOut），配合各内容分支根节点上的 .transition ⇒ 状态分支
   * 互切（List ↔ Loading ↔ Error ↔ Empty）与榜单整批换血都是淡入上浮，不是硬切。
   * 数据流未改（仍在 loadPopular 里赋值），只是把赋值包进动效闭包。
   */
  private animContent(op: () => void): void {
    Anim.to(op, Anim.contentIn, Anim.curveEaseOut());
  }

  async loadPopular(): Promise<void> {
    const startLoading: boolean = this.items.length === 0;
    this.animContent((): void => {
      this.loading = startLoading;
      this.errorMsg = '';
      // s5g：换源/回榜时把顶部工具区恢复展开（否则从收起态切源会一直看不到搜索入口）
      this.toolCollapsed = false;
    });
    try {
      const sm: SourceManager = SourceManager.getInstance();
      this.sources = sm.list();
      // 第 7 条：用户还没手动选过 ⇒ 按上次记忆复原（存的是源 id，插件装卸改变了顺序也不会选错）。
      // 记忆里的源已被卸载（indexOfSource 返回 -1）就保持 0，即原来的「第一个源」口径。
      if (!this.userPickedSource) {
        const mem: number = LastSourceStore.indexOfSource(this.sources, LastSourceStore.readDiscoverId());
        if (mem >= 0) {
          this.sourceIndex = mem;
          Logger.i('[Discover] restore source index=' + mem + ' id=' + this.sources[mem].id);
        }
      }
      if (this.sources.length === 0) {
        this.animContent((): void => {
          this.items = [];
          this.errorMsg = '暂无可用图源';
        });
        return;
      }
      const src: MangaSource | null = this.currentSource();
      if (src === null) {
        this.animContent((): void => {
          this.items = [];
          this.errorMsg = '图源未就绪';
        });
        return;
      }
      const list: MangaSummary[] = await src.fetchPopular(1);
      this.animContent((): void => {
        this.items = list;
      });
    } catch (err) {
      const e = err as BusinessError;
      console.error(`[Discover] popular failed: code=${e.code} msg=${e.message}`);
      this.animContent((): void => {
        this.errorMsg = '排行榜加载失败';
      });
    } finally {
      this.animContent((): void => {
        this.loading = false;
      });
    }
  }

  private openManga(m: MangaSummary): void {
    // 先详情页（s6j 需求 4）：阅读按钮由详情页进阅读器，统一入口
    const params: DetailParams = new DetailParams(m.id, m.sourceId, m.title);
    router.pushUrl({ url: 'pages/DetailPage', params: params })
      .catch((err: BusinessError) => {
        console.error(`[Discover] pushUrl failed: code=${err.code} msg=${err.message}`);
      });
  }

  private sourceName(i: number): string {
    if (i < 0 || i >= this.sources.length) {
      return '';
    }
    return this.sources[i].name;
  }

  /** 同上按 id 取（第 7 条的落盘与复原都吃 id）。 */
  private sourceId(i: number): string {
    if (i < 0 || i >= this.sources.length) {
      return '';
    }
    return this.sources[i].id;
  }

  @Builder
  SourceChip(i: number) {
    Text(this.sourceName(i))
      .fontSize(13)
      .fontColor(this.sourceIndex === i ? Theme.white : Theme.text1(this.isDark))
      .backgroundColor(this.sourceIndex === i ? Theme.brand : Theme.fillColor(this.isDark))
      .borderRadius(Dim.radius)
      .height(32)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .maxLines(1)
      .textAlign(TextAlign.Center)
      .onClick(() => {
        if (this.sourceIndex !== i) {
          // A1：选中态换色走 Anim.to ⇒ backgroundColor/fontColor 为可动画属性，220ms 平滑过渡
          Anim.to((): void => {
            this.sourceIndex = i;
          }, Anim.contentIn, Anim.curveEaseOut());
          // 第 7 条：选中即落盘（写 id 而不是下标），并立起「用户选过」的旗，
          // 之后 loadPopular 重取列表时不会再拿上次记忆把这次选择覆盖掉。
          this.userPickedSource = true;
          LastSourceStore.writeDiscoverId(this.sourceId(i));
          this.loadPopular();
        }
      })
  }

  @Builder
  RankRow(item: MangaSummary, rank: number) {
    Row() {
      Text(`${rank}`)
        .fontSize(14)
        .fontWeight(FontWeight.Medium)
        .fontColor(rank <= 3 ? Theme.warning : Theme.text3(this.isDark))
        .width(24)
        .textAlign(TextAlign.Center)

      Image(item.coverUrl.length > 0 ? item.coverUrl : $r('app.media.ic_app'))
        .width(44)
        .height(58)
        .objectFit(ImageFit.Cover)
        .borderRadius(6)
        .backgroundColor(Theme.coverColor(this.isDark))
        .margin({ left: 4, right: 12 })
        .draggable(false)

      Column() {
        Text(this.cvtShow(item.title))
          .fontSize(14)
          .fontColor(Theme.text1(this.isDark))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text(item.author.length > 0 ? item.author : '佚名')
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

      Text('›')
        .fontSize(20)
        .fontColor(Theme.text3(this.isDark))
        .margin({ left: 8 })
    }
    .width('100%')
    .height(Dim.listItemH)
    .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      // 工具区（图源条）：s5g 加「随滚动收起/展开」过渡；s9 需求 5 后不再画分割线
      Column() {
        // s5j 需求 1（用户 m05810）：搜索条已从本页摘掉 —— 收进顶栏右上角的搜索图标
        // （pages/Index 里 BreezeTopBar.showSearch）。本页只留图源切换条。
        // 图源切换条
        Scroll() {
          Row() {
            ForEach(this.sources, (item: SourceInfo, index: number) => {
              this.SourceChip(index);
            }, (item: SourceInfo) => item.id)
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(this.toolChipRowH)
        .margin({ top: this.toolChipGap })

        // s9 需求 5：原先这条 Divider（0.5vp 加 margin-top 8）已删 —— 用户口径「明显分割线很难看」。
        // 工具区与排行榜之间不再靠一条线分段：排行榜自带的「排行榜」小标题（下方 List 首行）
        // 已经是分组标识，去掉线之后靠间距分段即可。
      }
      .width('100%')
      .clip(true)
      // s5g：上半部分工具区的过渡（用户反馈 s5e 只做了内容区淡入，上半部分仍无过渡）
      // 判据 = 榜单累计偏移 > 48vp ⇒ 收起；回顶 ⇒ 展开。属性动画只吃可动画属性，
      // 这里用 height/opacity（两者皆可动画），不用自研定时器。
      .height(this.toolCollapsed ? 0 : this.toolBarH())
      .opacity(this.toolCollapsed ? 0 : 1)
      .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() })

      if (this.loading) {
        LoadingView({ text: '正在加载…' })
          .layoutWeight(1)
          // A1：四内容分支互切统一淡入上浮（赋值端已包 Anim.to，这里声明进出场效果）
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 8 }))
            .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
      } else if (this.errorMsg.length > 0) {
        ErrorView({
          msg: this.errorMsg,
          onRetry: () => {
            this.loadPopular();
          }
        })
          .layoutWeight(1)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 8 }))
            .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
      } else if (this.items.length === 0) {
        EmptyView({ text: '该图源暂无榜单' })
          .layoutWeight(1)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 8 }))
            .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
      } else {
        List({ space: 0, scroller: this.listScroller }) {
          ListItem() {
            Row() {
              Text('排行榜')
                .fontSize(13)
                .fontWeight(FontWeight.Medium)
                .fontColor(Theme.text2(this.isDark))
                .layoutWeight(1)
                .textAlign(TextAlign.Start)
            }
            .width('100%')
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10, bottom: 6 })
            .alignItems(VerticalAlign.Center)
          }

          ForEach(this.items, (item: MangaSummary, index: number) => {
            ListItem() {
              this.RankRow(item, index + 1);
            }
            // C6-③：榜单行进场淡入上浮（A6 220ms）
            .transition(TransitionEffect.OPACITY
              .combine(TransitionEffect.translate({ y: 12 }))
              .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
            // C6-②：点按反馈
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.openManga(item);
            })
          }, (item: MangaSummary) => item.sourceId + '_' + item.id)
        }
        .width('100%')
        .layoutWeight(1)
        .divider({ strokeWidth: 0.5, color: Theme.dividerColor(this.isDark), startMargin: Dim.pagePadding, endMargin: Dim.pagePadding })
        .scrollBar(BarState.Off)
        // C6-④：List 用 contentEndOffset 预留底部（等价于 padding-bottom，且不裁剪末行）
        .contentEndOffset(Dim.contentBottomReserve)
        // C6-①：List.onDidScroll 只给每帧增量（common.d.ts:25666）⇒ 读 scroller 累计偏移
        .onDidScroll((_offset: number, state: ScrollState) => {
          const y: number = this.listScroller.currentOffset().yOffset;
          Anim.reportTopBar(y);
          // s5g：同一个累计偏移驱动顶部工具区收起（顶栏与工具区共用一条滚动曲线，不各算各的）
          this.syncToolCollapse(y);
          // T1（s5i）：再喂一份给 TabAutoHide 判方向 —— 收起由它显式执行，不再指望框架自动收
          TabAutoHide.onScroll(TabAutoHide.IDX_DISCOVER, y, state);
        })
        // T1：List 只在有数据时挂载 ⇒ 挂载后补一次绑定（aboutToAppear 那次可能落空）
        .onAppear(() => {
          TabAutoHide.flush();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}