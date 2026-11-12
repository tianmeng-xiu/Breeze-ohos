/**
 * 职责：搜索页（NextE 样式）—— 关键词输入 + 来源切换条（内置 MangaDex + 全部 plugin: 图源
 *      + 「全部」聚合项）+ 搜索记录（仅未搜索时展示）+ 结果大图栅格（T9 需求 3，要求 2 起每行三列）。
 * T9 需求 2（用户 m05810）：工具区（输入框 + 来源条）随滚动收起，机制与发现页一致：
 *      Grid 绑 scroller 读累计偏移（onDidScroll 只给每帧增量），滞回带宽按工具区真实高度成比例，
 *      收起动画按工具区实际高度算（数值必须与真实高度一致，否则残留半截）。
 * BUG6（真机截图取证）：折叠高度原先手抄 100vp（把内边距、搜索框、间距、行高口算相加），
 *      可这行数与真机实际布局差了几 vp，clip 落在 chip 中间 —— 深色态下三枚 chip 的下圆角被切平成直边。
 *      现改为内层内容不设固定高、由 onAreaChange 量真实高再喂折叠动画（估算值只当下限），
 *      尺寸 Token 与兜底值统一收在 view/common/GlassStyle.ets。
 * s9 需求 5（用户 2026-11-11 22:12 反馈，参考华为画廊搜索页两张截图）：搜索记录区默认竖向居中，
 *      键盘弹起后整体上移到键盘上方、收起后回原位；无记录时不再显示「暂无搜索记录」占位，整块留空。
 *      键盘避让选型 = UIContext.setKeyboardAvoidMode(RESIZE)，理由与还原口径见 setKbAvoid 注释。
 *      同一条追加（lead 批准）：输入框右侧改用官方 searchButton「搜索」，点击复用 onSubmit，见 build 内注释。
 * 失败口径：多源聚合时单源 try/catch 收集错误，有结果就显示（顶部一条部分失败横幅），
 *      全失败才 ErrorView（文案带失败源）。
 * 点击：结果卡跳详情页（pages/DetailPage，参数类 view/detail/DetailParams，路由在 main_pages.json 登记）。
 * 依赖：view/common/MangaGridCard、BreezeTopBar、StateViews、Theme、Anim；data 层 SourceManager / SearchHistory。
 */
import { KeyboardAvoidMode, promptAction, router } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { MangaGridCard } from '../view/common/MangaGridCard';
import { Theme, Dim } from '../view/common/Theme';
import { Anim } from '../view/common/Anim';
import { LoadingView, EmptyView, ErrorView } from '../view/common/StateViews';
import { SourceManager } from '../data/source/SourceManager';
import { MangaSource } from '../data/source/Source';
import { MangaSummary, SourceInfo } from '../data/model/Models';
import { SearchHistory } from '../data/kv/SearchHistory';
import { DetailParams } from '../view/detail/DetailParams';
import { GlassStyle, GlassButton } from '../view/common/GlassStyle';
import { Logger } from '../util/Logger';

/** 聚合搜索伪图源 id（chips 行首「全部」）。 */
const ALL_SOURCES_ID: string = '__all__';

/** 单源搜索结果收集（类实例承载，避开裸对象字面量限制）。 */
class SourceOutcome {
  name: string = '';
  items: MangaSummary[] = [];
  err: string = '';
}

@Entry
@Component
struct SearchPage {
  @StorageProp('isDark') isDark: boolean = false;
  /** G1 联动：插件装载/删除后 chip 条同步（与 DiscoverPage 同一个 epoch）。 */
  @StorageProp('pluginSourceEpoch') @Watch('onSourceEpoch') pluginEpoch: number = 0;

  /** chips 数据 = [全部] + SourceManager.list() */
  @State chips: SourceInfo[] = [];
  @State chipIndex: number = 0;
  @State keyword: string = '';
  @State history: string[] = [];
  @State searched: boolean = false;
  @State loading: boolean = false;
  @State items: MangaSummary[] = [];
  @State errorMsg: string = '';
  /** 部分源失败横幅（有结果时显示，不拦截展示） */
  @State partialMsg: string = '';
  /** T9 需求 2：工具区随累计滚动收起（滞回判据见 syncToolCollapse） */
  @State toolCollapsed: boolean = false;

  /** 结果栅格绑 scroller：Grid.onDidScroll 只给每帧增量 ⇒ 绝对偏移必须从 scroller 读 */
  private gridScroller: Scroller = new Scroller();

  /**
   * chip 最大宽（vp）：初值是上限，首帧布局后由工具区 onAreaChange 用实测宽反解（见 syncChipMax）。
   * 判据与上限都在 GlassStyle.chipMaxWidth 里：真机插件名很长（例：禁漫天堂加英文后缀），
   * 无约束时一枚 chip 就能顶满屏宽 ⇒ 后面的源看不见。
   * 必须 @State：onAreaChange 在首帧之后才回调，普通字段改了不会让 ForEach 里的 chip 重渲染。
   */
  @State chipMax: number = GlassStyle.chipMaxCap;

  /**
   * 工具区内容实测高（vp）：由内层内容 Column 的 onAreaChange 写入，0 = 还没量到。
   * 必须 @State：折叠动画的 height 要跟着它变（普通字段改了不动画）。
   */
  @State toolMeasuredH: number = 0;

  /**
   * 来源条行高（vp）：初值取 Token 的 44，chip 实测比它高时按实测撑开（见 syncChipRowH）。
   * 必须 @State：行高变了要重排，普通字段改了不动。
   */
  @State chipRowH: number = GlassStyle.toolChipRowH;

  /**
   * 折叠动画吃的总高（vp）。BUG6 的教训是这个数以前手抄成 100（= padding-top 10 + 输入框 40 +
   * 来源条 margin 6 + 行高 44），可真机上内层实际落位比这套算术低几 vp，
   * clip 就把三枚 chip 的下圆角切平成一条直边（截图上「全部 / MangaDex / 禁漫天堂」底部齐平）。
   * 现在两条腿：布局Token 估高永远作为下限（首帧没量到也不会矮于它，不会闪 0 高），
   * 实测高加固定余量只往上抬、不下压；再按上限夹取，防一次异常读数把结果区顶掉大半屏。
   */
  private toolBarH(): number {
    // 兜底档也带上 clipSlack：常态下内层量到 90，实测档算出来 90+10+8+8=116，
    // 而纯布局Token 只有 108 —— 少了这 8 就会在首帧量到之后由 108 动画长到 116，
    // 看着像工具区进门先抖一下。两边都含余量，常态首帧就是同一个数，不动画。
    const est: number = GlassStyle.toolBarLayoutH() + GlassStyle.toolClipSlack;
    const cap: number = GlassStyle.toolBarLayoutH() + GlassStyle.toolHeightCapExtra;
    if (this.toolMeasuredH > 0) {
      const h: number = this.toolMeasuredH + GlassStyle.toolPadTop +
        GlassStyle.toolBottomPad + GlassStyle.toolClipSlack;
      const use: number = h > cap ? cap : h;
      return use > est ? use : est;
    }
    return est;
  }

  /**
   * 内层内容实测高入库：**只接受往上抬的读数**（不足 1vp 的增幅忽略）。
   * 为什么不能双向接受：外层折叠时高度归 0，收起动画途中也是从满高连续插值下来的，
   * 内层被父高夹住必然量到 20、44 这种「被压扁的高」。这种偏小的数一旦写进去，
   * toolBarH() 就跟着变小，展开时容器偏矮，chip 下圆角又被切一刀 —— BUG6 换个位置复现。
   * 反过来单向取大是安全的：真机上内容比算术值高（本 BUG 的起因）会被如实抬起来；
   * 系统字体放大让内容真变高，读数自然往上走并被采纳；字体缩回小档时只会多留十几 vp 白，
   * 比把字切了划算（工具区高度偏大不产生任何截断）。
   * 低于下限的读数一并丢弃，那是折叠态量到的 0 附近值，不是内容高。
   * 留一条日志：真机回报里要能看到实测高与最终折叠高两个数。
   */
  private syncToolHeight(h: number): void {
    if (h < GlassStyle.toolHeightFloor) {
      return;
    }
    if (h - this.toolMeasuredH < 1) {
      return;
    }
    this.toolMeasuredH = h;
    Logger.i('[Search] toolContentH=' + h.toFixed(1) + ' toolBarH=' + this.toolBarH().toFixed(1));
  }

  /**
   * 来源条行高跟着 chip 实测高走：行高写死 44 时，系统字体放大（最大档可到 2 倍）会让
   * 13fp 的 chip 文字高出胶囊下限 32，进而顶出这一行 —— List 交叉轴溢出是被裁的，
   * 表现就是 chip 文字上下各少一条。所以用 chip 自己的高把这一行撑开（上下各留 6）。
   * chip 高只由字号决定、不由行高决定（alignListItem 是 Center，不会把 item 拉满行高），
   * 因此这条链路不会自我放大；再叠一层封顶双保险，极端读数最多多留白，不会吃掉结果区。
   * 允许往回缩：字体缩回小档时行高跟着回落，不留永久白边。
   */
  private syncChipRowH(h: number): void {
    if (h <= 0) {
      return;
    }
    const capped: number = h > GlassStyle.toolChipRowMax ? GlassStyle.toolChipRowMax : h;
    const want: number = capped + 12 > GlassStyle.toolChipRowH
      ? capped + 12
      : GlassStyle.toolChipRowH;
    if (Math.abs(want - this.chipRowH) < 1) {
      return;
    }
    this.chipRowH = want;
  }

  /**
   * 收起判据按工具区真实高度成比例：下滚过 0.5 倍高收起、回到 0.25 倍高以内展开
   * （滞回带防临界抖动）。原来是写死的 48/24 —— 工具区高度一改那两个数就对不上了：
   * 阈值明显小于条高会「一滚就收起」，明显大于条高则滚完整个工具区还不收。
   */
  private syncToolCollapse(offsetY: number): void {
    const h: number = this.toolBarH();
    const collapseAt: number = h * 0.5;
    const expandAt: number = h * 0.25;
    const want: boolean = this.toolCollapsed;
    const should: boolean = want ? !(offsetY < expandAt) : (offsetY > collapseAt);
    if (should !== want) {
      this.toolCollapsed = should;
    }
  }

  /**
   * chipMax 用实测宽反解：入参是工具区 onAreaChange 给的宽度（窗口内容宽，vp）。
   * 为什么不用 ScreenUtil.widthVp()：它 = display.getDefaultDisplaySync().width / densityPixels
   * （SafeArea.ets:15-23），拿的是物理屏宽，分屏与折叠屏展开态下都比可用宽大 ⇒ 反解出的
   * maxWidth 偏大，短中文名也不易触发截断。实测宽在尺寸变化时会再次回调，且只在变化时写 @State。
   * 日志留一条：真机回报里要能看到实测宽度与实际 chipMax 数值。
   */
  private syncChipMax(w: number): void {
    if (w <= 0) {
      return;
    }
    const next: number = GlassStyle.chipMaxWidth(w);
    if (Math.abs(next - this.chipMax) < 1) {
      return;
    }
    this.chipMax = next;
    Logger.i('[Search] toolBarWidth=' + w.toFixed(1) + ' chipMax=' + next);
  }

  /**
   * 键盘避让档位（s9 需求 5：键盘弹起后搜索记录区整体上移，收起后回原位）。
   *
   * 选型 RESIZE 的理由（三条都对着 SDK 原文核过）：
   *  1. 参考截图自证（两图同为 1320x2848，逐行取墨迹带的脚本 = _tmp/searchr9/measure2.py）：
   *     普通态「搜索记录」标题加 chips 的墨迹带 = y 1547 至 1700；键盘态 = y 1017 至 1170
   *     ⇒ 整块上移 530px。B 图键盘上沿 y=1788 ⇒ 键盘高 1060px。**位移恰为键盘高的一半**。
   *     两态里顶栏与搜索框都纹丝不动（搜索框墨迹行同为 200 至 481）。
   *     「页面高缩到键盘上方 加 内容竖向居中」正好给 K/2 且顶部不动；整页平移（OFFSET）
   *     位移是 K，会把顶栏顶出屏幕 —— 与参考图不符，故排除。
   *  2. UIContext.d.ts:4811 原文：RESIZE 下「百分比宽高的组件随页面一起 resize」—— 本页根容器
   *     与记录区都是百分比/layoutWeight，正是这一档的目标形态；定高的工具区不受影响。
   *  3. 不选 expandSafeArea(KEYBOARD)：同一处 NOTE（UIContext.d.ts:4814）写明 RESIZE 档下它不生效，
   *     且 common.d.ts:17212 要求组件自己贴到键盘边缘，与「居中」诉求相反。
   *  4. 不选自己监听 window 的 keyboardHeightChange（@ohos.window.d.ts:5484）再算位移：
   *     要自管避让量、动画与回弹，而本页已是 setWindowLayoutFullScreen 沉浸式，
   *     等于再造一处手抄算术 —— BUG6 的教训（手抄高度与真实落位差几 vp 就切内容）。
   *
   * ⚠ 档位是 **UIContext（窗口）级**属性，不是页面级：本页离开后不还原就会把详情页评论输入框、
   *   插件登录页头像输入框的避让方式一起改掉。故 onPageShow 上 RESIZE、onPageHide 与
   *   aboutToDisappear 还原成 SDK 口径的默认值 OFFSET（UIContext.d.ts:4826）。
   *   aboutToAppear 也补一次：getUIContext 过早可能拿不到实例，拿不到就交给 onPageShow。
   */
  private setKbAvoid(useResize: boolean): void {
    try {
      this.getUIContext().setKeyboardAvoidMode(useResize ? KeyboardAvoidMode.RESIZE : KeyboardAvoidMode.OFFSET);
    } catch (e) {
      Logger.i('[Search] setKeyboardAvoidMode skipped (no UIContext yet)');
    }
  }

  onPageShow(): void {
    this.setKbAvoid(true);
  }

  onPageHide(): void {
    this.setKbAvoid(false);
  }

  aboutToDisappear(): void {
    this.setKbAvoid(false);
  }

  aboutToAppear(): void {
    this.setKbAvoid(true);
    this.history = SearchHistory.list();
    AppStorage.setOrCreate<number>('searchHistoryCount', this.history.length);
    this.reloadChips(true);
    // 入口可带 sourceId（SearchEntryParams）⇒ 默认选中该源
    try {
      const raw: Object = router.getParams();
      if (raw !== null && raw !== undefined) {
        const src: ESObject = raw;
        const sid: string = src.sourceId !== undefined ? String(src.sourceId) : '';
        if (sid.length > 0) {
          for (let i = 0; i < this.chips.length; i++) {
            if (this.chips[i].id === sid) {
              this.chipIndex = i;
              break;
            }
          }
        }
      }
    } catch (e) {
      // 参数缺失无所谓，默认已选第一个真实源
    }
  }

  onSourceEpoch(): void {
    this.reloadChips(false);
  }

  /** 重建 chip 条；clampFirst=true 时默认选第一个真实源（首次进入）。 */
  private reloadChips(clampFirst: boolean): void {
    const srcs: SourceInfo[] = SourceManager.getInstance().list();
    const all: SourceInfo = { id: ALL_SOURCES_ID, name: '全部', language: '' };
    const next: SourceInfo[] = [all];
    for (let i = 0; i < srcs.length; i++) {
      next.push(srcs[i]);
    }
    this.chips = next;
    if (clampFirst) {
      this.chipIndex = next.length > 1 ? 1 : 0;
    } else if (this.chipIndex >= next.length) {
      this.chipIndex = 0;
    }
  }

  /** 结果卡「图源」小字：按条目 sourceId 反查 chip 名（聚合搜索时各条目源不同）。 */
  private sourceNameOf(sid: string): string {
    for (let i = 0; i < this.chips.length; i++) {
      if (this.chips[i].id === sid) {
        return this.chips[i].name;
      }
    }
    return '';
  }

  private animContent(op: () => void): void {
    Anim.to(op, Anim.contentIn, Anim.curveEaseOut());
  }

  private currentChipId(): string {
    if (this.chipIndex < 0 || this.chipIndex >= this.chips.length) {
      return ALL_SOURCES_ID;
    }
    return this.chips[this.chipIndex].id;
  }

  /** 单源搜索（含装载等待），异常转 SourceOutcome.err，绝不冒泡打断其它源。 */
  private async searchOne(info: SourceInfo, kw: string): Promise<SourceOutcome> {
    const out: SourceOutcome = new SourceOutcome();
    out.name = info.name;
    try {
      const src: MangaSource | null = SourceManager.getInstance().get(info.id);
      if (src === null) {
        out.err = '图源未就绪';
        return out;
      }
      out.items = await src.search(kw, 1);
    } catch (e) {
      const x = e as Error;
      const m = x.message;
      out.err = (typeof m === 'string' && m.length > 0) ? m : String(e);
    }
    return out;
  }

  /** 新搜索/切源重搜：工具区恢复展开 + 栅格回顶（否则收起态下换结果会一直看不到入口）。 */
  private resetViewForNewSearch(): void {
    this.animContent((): void => {
      this.toolCollapsed = false;
    });
    try {
      this.gridScroller.scrollEdge(Edge.Top);
    } catch (e) {
      // Grid 尚未挂载（首次搜索）时忽略
    }
  }

  async doSearch(): Promise<void> {
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      promptAction.showToast({ message: '请输入搜索关键词' });
      return;
    }
    this.resetViewForNewSearch();
    const sid: string = this.currentChipId();
    const targets: SourceInfo[] = [];
    if (sid === ALL_SOURCES_ID) {
      for (let i = 1; i < this.chips.length; i++) {
        targets.push(this.chips[i]);
      }
    } else {
      for (let i = 0; i < this.chips.length; i++) {
        if (this.chips[i].id === sid) {
          targets.push(this.chips[i]);
        }
      }
    }
    if (targets.length === 0) {
      this.animContent((): void => {
        this.searched = true;
        this.loading = false;
        this.items = [];
        this.partialMsg = '';
        this.errorMsg = '暂无可用图源';
      });
      return;
    }
    this.animContent((): void => {
      this.searched = true;
      this.loading = true;
      this.errorMsg = '';
      this.partialMsg = '';
    });
    try {
      // 并发聚合：每源独立 try/catch（searchOne 内部消化），单源失败不拖垮整页
      const jobs: Promise<SourceOutcome>[] = [];
      for (let i = 0; i < targets.length; i++) {
        jobs.push(this.searchOne(targets[i], kw));
      }
      const outs: SourceOutcome[] = await Promise.all(jobs);
      const merged: MangaSummary[] = [];
      const errs: string[] = [];
      let okCount: number = 0;
      for (let i = 0; i < outs.length; i++) {
        const o: SourceOutcome = outs[i];
        if (o.err.length > 0) {
          errs.push(o.name + '：' + o.err);
        } else {
          okCount++;
          for (let k = 0; k < o.items.length; k++) {
            merged.push(o.items[k]);
          }
        }
      }
      if (merged.length === 0 && errs.length > 0 && okCount === 0) {
        // 全失败 ⇒ ErrorView，文案带失败源（截断防爆行）
        const j: string = errs.join('；');
        this.animContent((): void => {
          this.items = [];
          this.errorMsg = '搜索失败（' + j.slice(0, 160) + '）';
        });
      } else {
        this.animContent((): void => {
          this.items = merged;
          this.partialMsg = errs.length > 0 ? ('部分源失败：' + errs.join('；').slice(0, 120)) : '';
        });
        // 至少一源成功才记（与旧 Discover 搜索口径一致：全失败不记废词）
        if (okCount > 0) {
          SearchHistory.record(kw).then((next: string[]): void => {
            this.history = next;
            AppStorage.setOrCreate<number>('searchHistoryCount', next.length);
          }).catch((): void => {
          });
        }
      }
    } finally {
      this.animContent((): void => {
        this.loading = false;
      });
    }
  }

  /** 点记录 chip：回填关键词直接搜。 */
  private applyHistory(kw: string): void {
    Anim.to((): void => {
      this.keyword = kw;
    }, Anim.contentIn, Anim.curveEaseOut());
    this.doSearch();
  }

  /**
   * 待办：长按记录 chip 删单条。
   * 确认框用 promptAction.showDialog（Promise 版，@ohos.promptAction.d.ts:1949；回包 ShowDialogSuccessResponse.index 即按钮下标，0=删除）；
   * 数据层 SearchHistory.remove 返回删后全表，直接刷 history 与 AppStorage 计数，不自己拼数组。
   * 点遮罩关闭会让 Promise 失败 ⇒ catch 里什么都不做（用户没确认就是不该删）。
   */
  private removeHistory(kw: string): void {
    // 外层对象显式标注接口（ArkTS 严格模式 10505038 的正规解法），buttons 内联交给
    // Array<Button> 的声明类型推断，按钮顺序即 index：0=删除、1=取消。
    const opts: promptAction.ShowDialogOptions = {
      title: '删除这条搜索记录？',
      message: kw,
      buttons: [
        { text: '删除', color: Theme.error },
        { text: '取消', color: Theme.text2(this.isDark) }
      ]
    };
    promptAction.showDialog(opts).then((res: promptAction.ShowDialogSuccessResponse): void => {
      if (res.index !== 0) {
        return;
      }
      SearchHistory.remove(kw).then((next: string[]): void => {
        this.history = next;
        AppStorage.setOrCreate<number>('searchHistoryCount', next.length);
      }).catch((): void => {
        // 写失败由 SearchHistory 内部记日志，这里不重复报
      });
    }).catch((): void => {
      // 取消 / 点遮罩关闭
    });
  }

  private clearHistory(): void {
    SearchHistory.clear().then((): void => {
      this.history = [];
      AppStorage.setOrCreate<number>('searchHistoryCount', 0);
    }).catch((): void => {
    });
  }

  /** T9：点结果卡跳详情页（路由在 main_pages.json 登记，参数类是唯一权威定义）。 */
  private openDetail(m: MangaSummary): void {
    const params: DetailParams = new DetailParams(m.id, m.sourceId, m.title);
    router.pushUrl({ url: 'pages/DetailPage', params: params })
      .catch((err: BusinessError) => {
        console.error('[Search] pushUrl DetailPage failed: code=' + err.code + ' msg=' + err.message);
      });
  }

  build() {
    Column() {
      BreezeTopBar({
        title: '搜索',
        showBack: true,
        onBack: (): void => {
          router.back();
        }
      })

      // 工具区（输入框 + 来源切换条）：T9 需求 2 —— 与发现页同机制随滚动收起/展开。
      // height/opacity 是可动画属性，.animation 做 220ms EaseOut 过渡；clip 防残留半截。
      // 内层只负责摆内容并且**不设固定高**：它的 onAreaChange 给出真实布局高，外层折叠动画吃这个值。
      // （以前只有外层一个写死的 height，内容一旦比它高就被 clip 切平，这就是 BUG6。）
      Column() {
        Column() {
          Search({ value: this.keyword, placeholder: '搜索漫画名 / 作者' })
          .width('100%')
          .height(GlassStyle.toolSearchH)
          .backgroundColor(Theme.fillColor(this.isDark))
          .placeholderColor(Theme.text3(this.isDark))
          // 深色模式正文发黑修复：SDK 实证 units.d.ts:2021 的 Font 只有 size、weight、family、style
          // 四个字段，**没有 color** ⇒ 文字色只能走 Search 自己的 fontColor（search.d.ts:538，
          // 默认 #FF182431 就是深色底上近黑的根因）。textFont 继续只管字号。
          .fontColor(Theme.text1(this.isDark))
          .textFont({ size: 14 })
          .defaultFocus(true)
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => {
            this.doSearch();
          })
          // s9 需求 5 追加（lead 批准，用官方 API 不自拼 Row）：输入框右侧「搜索」文字按钮。
          // SDK search.d.ts:524 searchButton(value: ResourceStr, option?: SearchButtonOptions)，@since 8，
          // SearchButtonOptions 只有 fontSize、fontColor、autoDisable 三字段（:377-414）。
          // :506 原文「Clicking the search button triggers both onSubmit and onClick」⇒ 点击直接走进
          // 上面已有的 onSubmit → doSearch()，零新增逻辑，也不用另挂 onClick。
          // ① fontColor 走 Theme.brand（#0A59F7），不用 SDK 默认 #ff3f97e9（与 chip 选中态、
          //    BreezeTopBar 强调色同一个令牌，深浅两档同值）。
          // ② autoDisable: true（@since 18，真机 API26 可用）= 空输入时按钮自动置灰，省一次空搜；
          //    doSearch() 的 kw.length === 0 提示兜底仍在（软键盘搜索键、错误页重试两处共用同一路径）。
          // ③ 字号取 15 与输入正文 textFont size 14 齐平（SDK 默认 16fp 会比正文大一号）。
          // 横向占位量过了再下结论（参考图 m00784 逐列取色，换算 1320px / 3.5 = 377vp 见 key 记忆）：
          // 参考端输入框胶囊 x55-1264 = 宽 345.4vp、高 38.3vp（与我们 toolSearchH 40 同量级）；蓝色
          // 「搜索」两字墨迹 x1120-1208 = 25.1vp（每字约 12.5vp ⇒ 参考端按钮字号约 14fp），墨迹右端
          // 距胶囊右缘 16vp ⇒ 整条按钮连留白只吃约 41vp。参考端 placeholder 墨迹 x115-438 = 92.3vp
          // 除 5 个码点（4 汉字加省略号）⇒ 单个汉字宽按 18-20vp 记（含字距，比字号本身宽）。
          // 我们的输入框 328vp（内容宽 360 减左右 padding 16x2）：placeholder「搜索漫画名 / 作者」
          // 7 个汉字按 20vp 加两个半宽符号按 10vp = 160vp，左侧搜索图标 16vp（SDK :545 默认 16vp），
          // 按钮取参考实测 41vp 的两倍宽档 80vp ⇒ 合计 256vp，仍余 72vp ⇒ 不会挤到省略号，
          // 所以 placeholder 文案一个字没改。参考图里按钮与正文之间也没有竖分隔线（唯一的高竖列
          // x184-186 落在 placeholder 字形里，是笔画不是线），我们也不用额外画。
          // 竖向无影响：.height(GlassStyle.toolSearchH) 定高 40，按钮画在框内，工具区那条实测链不吃它。
          .searchButton('搜索', { fontSize: 15, fontColor: Theme.brand, autoDisable: true })

          // 来源切换条（含「全部」聚合项）：横向 List 而非 Scroll 加 Row。
          // 换掉的理由：Scroll 的行尾没有内容偏移可用，最后一枚 chip 永远贴屏幕右缘，看着像渲染坏了；
          // List 有 contentEndOffset（list.d.ts:1090，@since 11）能真的把「内容末尾」往回留出一段可滚距离。
          // 横向 List 的交叉轴是竖向，alignListItem 默认 Start 会把 chip 顶到上边，故显式居中。
          List({ space: GlassStyle.chipGap }) {
            ForEach(this.chips, (chip: SourceInfo, index: number) => {
              ListItem() {
                Text(chip.name)
                  .fontSize(13)
                  .fontColor(this.chipIndex === index ? Theme.white : Theme.text1(this.isDark))
                  .backgroundColor(this.chipIndex === index ? Theme.brand : GlassStyle.chipBg(this.isDark))
                  // 选中态实底不描边，未选中态才加玻璃细边（静态玻璃，见 GlassStyle 头注释）
                  .borderWidth(this.chipIndex === index ? 0 : GlassStyle.strokeWidth())
                  .borderColor(GlassStyle.stroke(this.isDark))
                  .borderRadius(Dim.radius)
                  .padding({ left: 14, right: 14 })
                  .maxLines(1)
                  // 一条 constraintSize 管两件事（两条会互相覆盖，别拆着写）：
                  // ① maxWidth = 截断修复：长插件名（例：禁漫天堂加英文后缀）无约束时一枚 chip 顶满屏宽；
                  // ② minHeight 而不是定高 = 字号放大安全：系统字体放大时 13fp 的行高会超过 32，
                  //    写死 height 会把 chip 文字上下各切一刀；下限之下普通字号仍是整齐的 32 高胶囊，
                  //    极端字号自行长高，外层折叠高由内层实测高跟着抬，不会切在字上。
                  .constraintSize({ maxWidth: this.chipMax, minHeight: GlassStyle.toolChipH })
                  // 把自己的真实高报给来源条行高（字号放大时撑开这一行，见 syncChipRowH）
                  .onAreaChange((_o: Area, n: Area): void => {
                    this.syncChipRowH(Number(n.height));
                  })
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .textAlign(TextAlign.Center)
                  .clickEffect({ level: ClickEffectLevel.LIGHT })
                  .onClick(() => {
                    if (this.chipIndex !== index) {
                      Anim.to((): void => {
                        this.chipIndex = index;
                      }, Anim.contentIn, Anim.curveEaseOut());
                      // 已出结果时切源直接重搜（NextE 行为：结果跟着源走）
                      if (this.searched && this.keyword.trim().length > 0) {
                        this.doSearch();
                      }
                    }
                  })
              }
            }, (chip: SourceInfo) => chip.id)
          }
          .listDirection(Axis.Horizontal)
          .alignListItem(ListItemAlign.Center)
          .contentEndOffset(GlassStyle.chipEndPad)
          .scrollBar(BarState.Off)
          .width('100%')
          // 行高跟着 chip 实测高走（初值 = Token 44）：字号放大时这一行被撑开，chip 文字不被切
          .height(this.chipRowH)
          .margin({ top: GlassStyle.toolRowGap })
        }
        .width('100%')
        // 内层收尾：内容高不写死，这里量到的就是「搜索框 加 间距 加 来源条」的真实布局高。
        // 外层折叠高在它基础上再加上内边距与底部余量（见 toolBarH()），所以裁剪线必然落在 chip 之下。
        .onAreaChange((_o: Area, n: Area): void => {
          this.syncToolHeight(Number(n.height));
        })
      }
      .width('100%')
      // 外层有显式高度，而 Column 的 justifyContent 默认是 Center：折叠高留了余量就必须显式顶对齐，
      // 否则内容会在余量里竖向居中，反把顶上的搜索框挤到裁剪线外（表现为输入框上边被切）。
      .justifyContent(FlexAlign.Start)
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: GlassStyle.toolPadTop })
      // 「上下材质不一」修复：原先这里挂 GlassStyle.toolBg 半透明底 + backdropBlur，与下面的纯色页面
      // 背景之间留下一条直角硬边（截图上那条横向色差）。工具区静态时背后就是同色页面底，blur 本身
      // 也无内容可糊 ⇒ 直接不给独立底色，工具区与页面同底，分界消失。玻璃档只保留在 chip 与按钮上
      // （GlassStyle.chipBg、GlassButton），那里是浮在内容上的小面积控件，有边界是合理的。
      // 实测宽在这里取：onAreaChange 给的是本组件 border-box 宽（含左右 padding），等于页面内容宽，
      // 正好是 chipMaxWidth 期望的入参口径；分屏与折叠屏展开态会再次回调，比 display 物理屏宽准。
      .onAreaChange((_o: Area, n: Area): void => {
        this.syncChipMax(Number(n.width));
      })
      .clip(true)
      .height(this.toolCollapsed ? 0 : this.toolBarH())
      .opacity(this.toolCollapsed ? 0 : 1)
      .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() })

      // 未发起过搜索：搜索记录区（搜索中/有结果时让位给栅格 —— T9 需求 3 口径）。
      // s9 需求 5（用户 2026-11-11 22:12）两条一起落在这里：
      //  ① 没有记录就**整块留空** —— 不再渲染「暂无搜索记录」。参考截图（华为画廊搜索页普通态）
      //     中间本来就是一整片空白，任何占位文案都比空白显眼，用户口径是「界面空就行」。
      //     标题行也一并随记录消失：没记录时留着「搜索记录」加「清空」两个入口是死控件，更脏。
      //  ② 有记录时竖向居中（中置）：外层 layoutWeight(1) 吃掉顶栏与工具区之下的全部剩余高度，
      //     justifyContent(Center) 把「标题行 加 记录 chips」这一坨摆正中。
      //     键盘弹起后的上移**不在这里算**：靠 onPageShow 上挂的 RESIZE 避让档把整个页面高
      //     缩到键盘上方，居中区跟着变矮 ⇒ 内容自动上移约半个键盘高；收起键盘页面高复原 ⇒ 回原位。
      //     位移全程由布局重算得出，不吃任何手抄的键盘高度常量（BUG6 那条教训）。
      //  ③ 已知边界（2026-11-11 裁定「宁可留白不裁字」：故意不加截断，也不为它再叠一条实测链路）：
      //     外层 layoutWeight 容器不带 clip，内容比可用高更高时是**向上探进工具区**（绘制层重叠，
      //     不是裁剪）。极端档按参考机 377x814vp（1320x2848 除以 3.5）算：20 条记录每条都触到
      //     chip 的 160vp 宽上限 ⇒ 一行只放得下两枚（可用宽 377-16*2=345，两枚带间距要 336）
      //     ⇒ 10 行 x (28 加 8) = 360，加标题行 34 = 394vp；可用高常态 = 814-56-116 = 642（放得下），
      //     键盘态再减 303（键盘 1060px 除以 3.5）= 339 ⇒ 上下各溢出约 28vp，首行探进工具区下沿。
      //     日常口径（个位数条、每条几个字 ⇒ chip 约 60vp 宽、一行四枚）总高不过百来 vp，居中稳在
      //     中间，离这个边界还有三倍余量。真要收口，正解是给这一坨套 Scroll 并在超高时改顶对齐，
      //     不要改成定高容器 —— 那正是 BUG6 的成因。
      if (!this.searched) {
        Column() {
          if (this.history.length > 0) {
            Column() {
              Row() {
                Text('搜索记录')
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(Theme.text2(this.isDark))
                  .layoutWeight(1)
                // 长按删单条的使用提示（不加这行没人知道能长按）
                Text('长按可删除')
                  .fontSize(11)
                  .fontColor(Theme.text3(this.isDark))
                  .margin({ right: 10 })
                // 清空：换成流动玻璃按钮（静态玻璃加 rotate 驱动的双边缘光效，见 GlassStyle 头注释）
                GlassButton({
                  label: '清空',
                  w: 62,
                  h: 26,
                  radiusV: 13,
                  onTap: (): void => {
                    this.clearHistory();
                  }
                })
              }
              .width('100%')
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
              // 只留底距：竖向居中之后顶部再留 14 会把整块往上顶 7vp，不再是真居中
              .margin({ bottom: 8 })

              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.history, (kw: string) => {
                  Text(kw)
                    .fontSize(12)
                    .fontColor(Theme.text2(this.isDark))
                    .backgroundColor(Theme.fillColor(this.isDark))
                    .borderRadius(14)
                    .height(28)
                    .padding({ left: 12, right: 12 })
                    .margin({ right: 8, bottom: 8 })
                    .maxLines(1)
                    .constraintSize({ maxWidth: 160 })
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .textAlign(TextAlign.Center)
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => {
                      this.applyHistory(kw);
                    })
                    // T2 尾巴 ⑦：长按删单条。TapGesture 与 LongPressGesture 系统本身互不冲突，
                    // 这里**不要**用 GestureGroup 把两者串起来（串成 EXCLUDE 会让回填失效）。
                    .gesture(
                      LongPressGesture({ duration: 400 })
                        .onAction((): void => {
                          this.removeHistory(kw);
                        })
                    )
                }, (kw: string) => kw)
              }
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
          }
        }
        .width('100%')
        .layoutWeight(1)
        // 中置：剩余高度竖向居中（横向仍从左排，交给内层 Column 的 alignItems Start）
        .justifyContent(FlexAlign.Center)
      } else if (this.loading) {
        LoadingView({ text: '正在搜索…' })
          .layoutWeight(1)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 8 }))
            .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
      } else if (this.errorMsg.length > 0) {
        ErrorView({
          msg: this.errorMsg,
          onRetry: () => {
            this.doSearch();
          }
        })
          .layoutWeight(1)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 8 }))
            .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
      } else if (this.items.length === 0) {
        EmptyView({ text: '没有搜到相关漫画', hint: '换个关键词或切换来源试试' })
          .layoutWeight(1)
          .transition(TransitionEffect.OPACITY
            .combine(TransitionEffect.translate({ y: 8 }))
            .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
      } else {
        // T9 需求 3：大图栅格，从左到右填满、换行继续；要求 2 改为每行三列（与书架同列数口径）。
        // Grid(scroller) 是位置参数（List 才是 { space, scroller }，别照抄）。
        // ★ 本 SDK 的 GridItemAttribute 没有 columnSpan/rowSpan（只有 rowStart/rowEnd/
        //   columnStart/columnEnd，gridItem.d.ts:156-210）⇒ 通栏的横幅与计数行**不能**塞进
        //   GridItem 再跨列，只能放在 Grid 外面的 Column 里（Grid 用 layoutWeight 吃剩余高度）。
        Column() {
          if (this.partialMsg.length > 0) {
            Text(this.partialMsg)
              .fontSize(11)
              .fontColor(Theme.warning)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
              .textAlign(TextAlign.Start)
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
          }
          Text('搜索结果 ' + this.items.length + ' 条')
            .fontSize(13)
            .fontWeight(FontWeight.Medium)
            .fontColor(Theme.text2(this.isDark))
            .width('100%')
            .textAlign(TextAlign.Start)
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            .margin({ top: 10, bottom: 2 })
        }
        .width('100%')

        Grid(this.gridScroller) {
          ForEach(this.items, (item: MangaSummary, index: number) => {
            GridItem() {
              MangaGridCard({
                title: item.title,
                coverUrl: item.coverUrl,
                sourceName: this.sourceNameOf(item.sourceId)
              })
            }
            .transition(TransitionEffect.OPACITY
              .combine(TransitionEffect.translate({ y: 12 }))
              .animation({ duration: Anim.contentIn, curve: Anim.curveEaseOut() }))
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.openDetail(item);
            })
          }, (item: MangaSummary, index: number) => item.sourceId + '_' + item.id + '_' + index)
        }
        // 要求 2：三列。360vp 窄屏算下来单卡 (360 - 16*2 - 10*2) / 3 = 102.7vp，
        // 封面 aspectRatio(0.7) ⇒ 高 146.7vp，加标题两行与来源行整卡约 206vp，不会挤爆。
        // 间距故意不走 Dim.gridGap(12)/书架的 rowsGap(16)：三列后每卡只剩约 103vp，
        // 列间距每加 2vp 单卡就少 1.3vp，标题（卡内 13fp，两行约 15 个汉字）最先不够用，
        // 所以列间距保持 10、行间距保持 12，比书架略紧一点换标题的横向余量。
        .columnsTemplate('1fr 1fr 1fr')
        .columnsGap(10)
        .rowsGap(12)
        .width('100%')
        .layoutWeight(1)
        .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 10 })
        .scrollBar(BarState.Off)
        // 底部留白用 contentEndOffset（=72），不要 padding —— padding 会裁末行
        .contentEndOffset(Dim.contentBottomReserve)
        // T9 需求 2：onDidScroll 只给每帧增量 ⇒ 从 scroller 读绝对偏移，同喂顶栏斜坡与工具区收起
        .onDidScroll((_offset: number, _state: ScrollState) => {
          const y: number = this.gridScroller.currentOffset().yOffset;
          Anim.reportTopBar(y);
          this.syncToolCollapse(y);
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
