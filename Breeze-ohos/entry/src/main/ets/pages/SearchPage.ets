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
 * s10 需求 2 与 7（用户 11-12 13:48 report 第 2、7 条）：
 *      2 =「特殊情况下输入法弹起时搜索记录不上移」⇒ 除页面生命周期那三处挂点外，再在输入框
 *        进入编辑态（即将弹键盘）时补发一次 RESIZE，setKbAvoid 内带回读校验与日志（见该函数注释）。
 *      7 =「最后一次退出时选中的源，下次进入默认选中」⇒ chip 选中源按 id 落盘
 *        （view/search/LastSourceStore，复用 PreferenceStore 单例），reloadChips 优先回填该 id。
 * s11 需求 6 与 7（用户 11-12 16:15 report 第 6、7 条）：
 *      6 =「详情页点标签 / 作者直接搜对应源」⇒ 路由参数多带一个 keyword（view/search/SearchEntryParams），
 *        aboutToAppear 先选源后灌词并自动搜一次；带词进入不再自动聚焦（不弹键盘，见 entryWithKeyword）。
 *      7 =「统一搜索页上下配色」⇒ 本页 BreezeTopBar 传 flatBackground: true，
 *        顶栏实底档底色从 cardColor 换成本页根容器同一个 Theme.background。
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
import { MangaSource, SearchPageResult } from '../data/source/Source';
import { MangaSummary, SourceInfo } from '../data/model/Models';
import { SearchHistory } from '../data/kv/SearchHistory';
import { DetailParams } from '../view/detail/DetailParams';
import { GlassStyle, GlassButton } from '../view/common/GlassStyle';
import { LastSourceStore } from '../view/search/LastSourceStore';
import { Logger } from '../util/Logger';
import { FeatureDiag } from '../util/FeatureDiag';

/** 聚合搜索伪图源 id（chips 行首「全部」）。 */
const ALL_SOURCES_ID: string = '__all__';

/** 单源搜索结果收集（类实例承载，避开裸对象字面量限制）。 */
class SourceOutcome {
  name: string = '';
  items: MangaSummary[] = [];
  err: string = '';
  /** 本次拿到的页码（1 基）。 */
  page: number = 1;
  /** 该源是否已到底（回包 paging 判定，三条腿见 PluginSourceAdapter.parseSearchPage）。 */
  reached: boolean = true;
  /** 翻页游标（回包 extern 原样 JSON 串，'' = 该源不用游标）。 */
  extern: string = '';
}

/**
 * s33 需求 2：每个源各自的翻页状态。
 * ★ 为什么按源存而不是全局存一个页码：聚合搜索是 N 个源拼成一列（doSearch 并发聚合），
 *   各源页数与游标互不相干，全局页码会让第二页只有「最后一个源」在推进、其余源重复第 1 页。
 * 非 @State：只参与取数决策，不进 build；底部那一行读的是 moreState（下面那个 @State）。
 */
class SourcePaging {
  id: string = '';
  name: string = '';
  /**
   * 已取到的最后一页（1 基）。★ 0 = 连第 1 页都没拿到（首屏就失败）—— 取下一页统一发
   * page + 1，所以这一档必须真是 0，否则「重新加载」会去发第 2 页、把失败那源的第 1 页永久跳过。
   */
  page: number = 1;
  reached: boolean = true;
  /** 取下一页失败过 ⇒ 不再重试（弱网下避免每次触底都撞一遍）。 */
  failed: boolean = false;
  extern: string = '';
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

  /**
   * s33 需求 2：底部那一行的状态（'' = 不显示这行 / 'more' = 还有下一页 /
   * 'loading' = 正在取下一页 / 'end' = 没有更多了 / 'fail' = 取下一页失败）。
   * 用字符串而不是三个 bool：四态互斥，三个 bool 要维护 8 种组合里的非法那些。
   */
  @State moreState: string = '';
  /** 下一页取数中（不进 build 判据，只当互斥闸；与 moreState='loading' 同步维护）。 */
  private loadingMore: boolean = false;
  /** 各源翻页状态（见 SourcePaging 注释）。 */
  private pagings: SourcePaging[] = [];
  /**
   * 搜索代号：每次 doSearch 自增。loadMoreResults 是异步的，用户在它 in-flight 时
   * 改词重搜 ⇒ 手里那份「上一页 + 新页」会把旧结果追加到新结果后面。返回时比代号，
   * 不一致直接丢弃（不追加、不改 moreState）。
   */
  private searchSeq: number = 0;

  /**
   * s11 第 6 条：本次是不是「带词进来」（详情页点作者名 / 标签）。
   * 只读一次（build 首帧喂 defaultFocus），普通字段即可，不需要 @State：
   * defaultFocus 是组件创建时才生效的属性，之后再变也没有重读的意义。
   * 作用 = 带词进来时不自动聚焦 ⇒ 不弹输入法。理由：这条路径的意图是「看结果」，
   * 而键盘弹起会吃掉小屏近一半高度（参考机 303vp / 814vp），刚落地就被盖住一半结果
   * 属于会被当新 bug 报回来的观感。用户想改词时自己点输入框，避让链照旧生效。
   */
  private entryWithKeyword: boolean = false;

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
   *   aboutToAppear 也补一次：getUIContext 过早可能拿不到实例，拿不到就交给后面的挂点。
   *
   * 第 2 条补的那一手（用户 11-12 13:48「特殊情况下输入法弹起时搜索记录不上移，大部分情况正常」）：
   * 上面三个挂点都在「页面可见」这一层，而避让量是键盘 show 事件里算的 —— 冷启动首帧
   * .defaultFocus(true) 抢跑、或从详情页返回本页时时序抖动，都可能出现「键盘先弹、档位后落」。
   * 那一档下 OFFSET 的判据是「焦点输入框会不会被键盘遮住」，本页输入框在顶上、根本没被遮
   * ⇒ 整页一步都不挪 ⇒ 记录区原地不动 = 用户看到的「不上移」；等档位随后落到 RESIZE，
   * 这一次弹起也不会再补算，只有下一次弹键盘才正常 —— 与「说不清触发方法」完全对得上。
   * 正解见 build 里 Search 的 onEditChange：在「即将弹键盘」那一刻再下发一次（幂等）。
   * 这里额外带回读校验（UIContext.d.ts:4845 getKeyboardAvoidMode）：档位对不对直接进日志，
   * 真机回传时不用靠复现猜。
   */
  private setKbAvoid(useResize: boolean): void {
    const want: number = useResize ? KeyboardAvoidMode.RESIZE : KeyboardAvoidMode.OFFSET;
    const wantName: string = useResize ? 'RESIZE' : 'OFFSET';
    let back: number = -1;
    try {
      const ctx: UIContext = this.getUIContext();
      ctx.setKeyboardAvoidMode(useResize ? KeyboardAvoidMode.RESIZE : KeyboardAvoidMode.OFFSET);
      back = ctx.getKeyboardAvoidMode();
    } catch (e) {
      Logger.i('[Search] kbAvoid skipped (no UIContext yet) want=' + wantName);
      return;
    }
    // 读数口径 0/1/2/3/4 = OFFSET / RESIZE / OFFSET_WITH_CARET / RESIZE_WITH_CARET / NONE
    // （实体枚举 @ohos.arkui.UIContext.d.ts:5645，别和 component/common.d.ts:26918 那个同名诱饵混）
    if (back !== want) {
      Logger.e('[Search] kbAvoid MISMATCH want=' + wantName + '(' + want + ') got=' + back);
    } else {
      Logger.i('[Search] kbAvoid=' + wantName);
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
    // s11 第 6 条：入口可带 sourceId 与 keyword（SearchEntryParams）。
    // sourceId ⇒ 默认选中该源；keyword ⇒ 灌进输入框并就地搜一次（详情页点作者名 / 标签的入口）。
    // 顺序很重要：先选源、后搜（doSearch 吃 currentChipId()，源没定就先搜错源）。
    let entryKw: string = '';
    let entrySid: string = '';
    let sidFound: boolean = false;
    try {
      const raw: Object = router.getParams();
      if (raw !== null && raw !== undefined) {
        const src: ESObject = raw;
        const sid: string = src.sourceId !== undefined ? String(src.sourceId) : '';
        entrySid = sid;
        if (sid.length > 0) {
          for (let i = 0; i < this.chips.length; i++) {
            if (this.chips[i].id === sid) {
              this.chipIndex = i;
              sidFound = true;
              break;
            }
          }
        }
        entryKw = src.keyword !== undefined ? String(src.keyword).trim() : '';
      }
    } catch (e) {
      // 参数缺失无所谓，默认已选第一个真实源
    }
    if (entryKw.length > 0 && entrySid.length > 0 && !sidFound) {
      // 带词进来但指定源已经找不到了（详情页停留期间插件被卸）：这条路径的意图是「搜这个词」，
      // 落到「上次记忆的另一个源」会给出毫不相干的窄结果 ⇒ 回落到 chip 0 = 全部聚合，
      // 至少不漏。只带 sourceId 不带词的老路径行为逐字未变（仍按 reloadChips 的记忆口径）。
      this.chipIndex = 0;
      Logger.i('[Search] entry source gone, fallback ALL: ' + entrySid);
    }
    if (entryKw.length > 0) {
      // aboutToAppear 在首帧 build 之前 ⇒ 这里赋值，Search({ value: this.keyword }) 首次绘制就带词，
      // 不会出现「空框闪一下再长出一串字」。随后直接搜：doSearch 内部的 resetViewForNewSearch
      // 里 scrollEdge 会因为 Grid 还没挂载而抛错，那处已有 try/catch 兜住（注释写着首次搜索）。
      // 不挂 onAppear 再搜的理由：那会让 searched 先以 false 画一帧「搜索记录」空态再跳结果，白闪一下。
      this.keyword = entryKw;
      this.entryWithKeyword = true;
      Logger.i('[Search] entry keyword=' + entryKw + ' source=' + this.currentChipId());
      this.doSearch();
    }
  }

  onSourceEpoch(): void {
    this.reloadChips(false);
  }

  /**
   * 重建 chip 条。选中位按 id 复原（第 7 条：插件装卸会让列表长度与顺序变化，故一律比 id、不比下标）。
   * clampFirst=true（首次进入）：上次记忆命中就用它，否则老口径「第一个真实源」（下标 1，0 是聚合项「全部」）。
   * clampFirst=false（pluginSourceEpoch 刷新）：先保住当前选中的那个源（epoch bump 不该把用户选的源换掉），
   * 当前选中已被卸载才退到上次记忆，两样都没有才回落 0。
   */
  private reloadChips(clampFirst: boolean): void {
    const srcs: SourceInfo[] = SourceManager.getInstance().list();
    const all: SourceInfo = { id: ALL_SOURCES_ID, name: '全部', language: '' };
    const next: SourceInfo[] = [all];
    for (let i = 0; i < srcs.length; i++) {
      next.push(srcs[i]);
    }
    // 重排之前先记下当前选中的 id（this.chips 还是旧列表，下标才有意义）
    const keepId: string = (this.chipIndex >= 0 && this.chipIndex < this.chips.length)
      ? this.chips[this.chipIndex].id : '';
    this.chips = next;
    if (clampFirst) {
      const mem: number = LastSourceStore.indexOfSource(next, LastSourceStore.readSearchId());
      this.chipIndex = mem >= 0 ? mem : (next.length > 1 ? 1 : 0);
      Logger.i('[Search] restore source index=' + this.chipIndex + ' id=' + this.currentChipId());
      return;
    }
    let idx: number = LastSourceStore.indexOfSource(next, keepId);
    if (idx < 0) {
      idx = LastSourceStore.indexOfSource(next, LastSourceStore.readSearchId());
    }
    this.chipIndex = idx >= 0 ? idx : 0;
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

  /**
   * 单源搜索（含装载等待），异常转 SourceOutcome.err，绝不冒泡打断其它源。
   * s33 需求 2：改走 searchPage 以带回 paging / extern（旧 search() 把两者丢了，
   * 宿主无从判断还有没有下一页）。
   */
  private async searchOne(info: SourceInfo, kw: string): Promise<SourceOutcome> {
    const out: SourceOutcome = new SourceOutcome();
    out.name = info.name;
    try {
      const src: MangaSource | null = SourceManager.getInstance().get(info.id);
      if (src === null) {
        out.err = '图源未就绪';
        return out;
      }
      const r: SearchPageResult = await src.searchPage(kw, 1, '');
      out.items = r.items;
      out.page = r.page;
      out.reached = r.hasReachedMax;
      out.extern = r.extern;
    } catch (e) {
      const x = e as Error;
      const m = x.message;
      out.err = (typeof m === 'string' && m.length > 0) ? m : String(e);
      out.reached = true;
    }
    return out;
  }

  /**
   * s33 需求 2：取各源下一页。
   * ★ 触底自动翻页但**失败不无限重试**：失败的源一次性标 failed 剔除，否则弱网下每次触底
   *   都会重打一遍（评论页那边靠 hasReachedMax=false 时点一次只重试一次，这里同理收口）。
   * ★ 只在「还开着」（未到底且未失败）的源上推进；全部关掉 ⇒ 'end'。
   */
  async loadMoreResults(): Promise<void> {
    if (this.loadingMore || this.loading || this.moreState !== 'more') {
      // s34：这里必须留读数。这一行 return 掉的情形（在翻页 / 首屏没回 / 已判到底）与「触底事件
      // 压根没触发」在 20 号行上原本长一个样，真机那一轮就是被这个歧义拖了一轮。
      FeatureDiag.get().spBlocked += 1;
      return;
    }
    const kw: string = this.keyword.trim();
    if (kw.length === 0) {
      return;
    }
    const open: SourcePaging[] = [];
    for (let i = 0; i < this.pagings.length; i++) {
      if (!this.pagings[i].reached && !this.pagings[i].failed) {
        open.push(this.pagings[i]);
      }
    }
    if (open.length === 0) {
      this.moreState = 'end';
      FeatureDiag.get().spEnd += 1;
      return;
    }
    FeatureDiag.get().spCalls += 1;
    this.loadingMore = true;
    this.moreState = 'loading';
    const seq: number = this.searchSeq;
    const jobs: Promise<SourceOutcome>[] = [];
    for (let i = 0; i < open.length; i++) {
      jobs.push(this.searchOnePage(open[i], kw));
    }
    const outs: SourceOutcome[] = await Promise.all(jobs);
    if (seq !== this.searchSeq) {
      // 期间用户已改词重搜 ⇒ 这一批属于旧结果，整批丢弃（doSearch 已重置 moreState/pagings）
      this.loadingMore = false;
      FeatureDiag.get().spStale += 1;
      Logger.i('[Search] loadMore 结果作废（搜索已换代）');
      return;
    }
    const merged: MangaSummary[] = [];
    for (let i = 0; i < this.items.length; i++) {
      merged.push(this.items[i]);
    }
    let anyOk: boolean = false;
    for (let i = 0; i < open.length; i++) {
      const p: SourcePaging = open[i];
      const o: SourceOutcome = outs[i];
      if (o.err.length > 0) {
        p.failed = true;
        FeatureDiag.get().spFail += 1;
        continue;
      }
      anyOk = true;
      FeatureDiag.get().spOk += 1;
      // s34：「翻页无进展」兜底 —— 回包页码没往前走（插件不认页码、或把自己的页码原样回吐）就说明
      // 这一源再也取不出新东西，就地关掉它。刻意用「页码有没有前进」而不是「page >= pages」判到底：
      // 后者会被 JMComic 那种 pages = 页码别名的回包误判（见 PluginSourceAdapter.parseSearchPage 注释）。
      p.reached = o.reached || !(o.page > p.page);
      p.page = o.page > p.page ? o.page : p.page;
      p.extern = o.extern.length > 0 ? o.extern : p.extern;
      if (!p.reached && o.items.length === 0) {
        p.reached = true; // 零条目 = 到底（parseSearchPage 同样这么判，这里补上聚合侧）
      }
      for (let k = 0; k < o.items.length; k++) {
        merged.push(o.items[k]);
      }
    }
    this.loadingMore = false;
    let stillOpen: boolean = false;
    let anyFailed: boolean = false;
    for (let i = 0; i < this.pagings.length; i++) {
      if (this.pagings[i].failed) {
        anyFailed = true;
      }
      if (!this.pagings[i].reached && !this.pagings[i].failed) {
        stillOpen = true;
      }
    }
    // ★ s34 第 1 条：只要还有失败源就是 'fail'，不能因为「别的源到底了」就报 'end'。
    //   旧写法 anyOk ? 'end' : 'fail' 的真机后果 = jm 翻页超时、pic 恰好到底 ⇒ 底部显示
    //   「没有更多了」，而 jm 那个失败源再没有任何重试入口（用户原话「也没有按钮让其重新加载」）。
    //   不 break 也是为了把 anyFailed 数完（stillOpen 先到 true 就跳会漏掉后面的失败源）。
    const next: string = stillOpen ? 'more' : (anyFailed ? 'fail' : (anyOk ? 'end' : 'fail'));
    if (next === 'end') {
      FeatureDiag.get().spEnd += 1;
    }
    Logger.i('[Search] loadMore page+1 ok=' + (anyOk ? 1 : 0) + ' total=' + merged.length + ' state=' + next);
    // @State 对数组 push 不敏感 ⇒ 整体换引用（同 CommentPage.loadMore 口径）
    this.animContent((): void => {
      this.items = merged;
      this.moreState = next;
    });
  }

  /**
   * 「下一页加载失败」那行的点击重试：把被标 failed 的源放回候选（页码不推进 = 重打同一页），
   * 然后走正常翻页路。只在 'fail' 态可点，所以这里不必再判状态。
   */
  private retryMore(): void {
    let revived: number = 0;
    for (let i = 0; i < this.pagings.length; i++) {
      if (this.pagings[i].failed) {
        this.pagings[i].failed = false;
        // ★ 一起清 reached：出错时 reached 被置过 true（那只是「别再自动试」的语义），
        // 不复位的话 loadMoreResults 的候选（!reached && !failed）仍然为空 ⇒ 按钮点了等于没点。
        // 页码不动 = 从「最后一个成功页 + 1」续，不会重复已拿到的那几页。
        this.pagings[i].reached = false;
        revived++;
      }
    }
    if (revived === 0) {
      this.moreState = 'end';
      return;
    }
    // loadMoreResults 首行要求 'more'，而这里是 'fail' 态 ⇒ 先把闸门打开
    this.moreState = 'more';
    this.loadMoreResults();
  }

  /** 单源下一页（searchOnePage 与 searchOne 同构，只是页码与游标由 p 提供）。 */
  private async searchOnePage(p: SourcePaging, kw: string): Promise<SourceOutcome> {
    const out: SourceOutcome = new SourceOutcome();
    out.name = p.name;
    out.page = p.page + 1;
    try {
      const src: MangaSource | null = SourceManager.getInstance().get(p.id);
      if (src === null) {
        out.err = '图源未就绪';
        return out;
      }
      const r: SearchPageResult = await src.searchPage(kw, p.page + 1, p.extern);
      out.items = r.items;
      out.page = r.page;
      out.reached = r.hasReachedMax;
      out.extern = r.extern;
    } catch (e) {
      const x = e as Error;
      const m = x.message;
      out.err = (typeof m === 'string' && m.length > 0) ? m : String(e);
      out.reached = true;
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
    // s33 需求 2：换代 + 清翻页现场。loadingMore 也一并清掉：上一次「下一页」可能正在
    // in-flight，它回来时会比 searchSeq 发现已换代而自己丢弃结果（见 loadMoreResults）。
    this.searchSeq = this.searchSeq + 1;
    this.pagings = [];
    this.loadingMore = false;
    this.moreState = '';
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
      const pgs: SourcePaging[] = [];
      let okCount: number = 0;
      for (let i = 0; i < outs.length; i++) {
        const o: SourceOutcome = outs[i];
        const p: SourcePaging = new SourcePaging();
        p.id = targets[i].id;
        p.name = o.name;
        // s34：失败的源页码记 0（不是 o.page —— 出错时它停在默认值 1，看着像「第 1 页已到手」）。
        // 取下一页发的是 page + 1 ⇒ 记 1 会让重试直接跳第 2 页，该源第 1 页永久缺失且不报错。
        p.page = o.err.length > 0 ? 0 : o.page;
        p.reached = o.reached || o.err.length > 0;
        p.failed = o.err.length > 0;
        p.extern = o.extern;
        pgs.push(p);
        if (o.err.length > 0) {
          errs.push(o.name + '：' + o.err);
        } else {
          okCount++;
          for (let k = 0; k < o.items.length; k++) {
            merged.push(o.items[k]);
          }
        }
      }
      this.pagings = pgs;
      if (merged.length === 0 && errs.length > 0 && okCount === 0) {
        // 全失败 ⇒ ErrorView，文案带失败源（截断防爆行）
        const j: string = errs.join('；');
        this.animContent((): void => {
          this.items = [];
          this.moreState = '';
          this.errorMsg = '搜索失败（' + j.slice(0, 160) + '）';
        });
      } else {
        let anyOpen: boolean = false;
        let anyFailed: boolean = false;
        for (let i = 0; i < pgs.length; i++) {
          if (pgs[i].failed) {
            anyFailed = true;
          }
          if (!pgs[i].reached && !pgs[i].failed) {
            anyOpen = true;
          }
        }
        this.animContent((): void => {
          this.items = merged;
          this.partialMsg = errs.length > 0 ? ('部分源失败：' + errs.join('；').slice(0, 120)) : '';
          // 底部行只在有结果时出现（空结果走 EmptyView，那已经是「没有更多」的意思）
          // 同理 s34：失败源存在时最终要给 'fail'（那一行带「重新加载」按钮），别报「没有更多了」。
          //   jm 首屏超时、pic 出结果的组合在真机很常见，旧写法这时底部只有「继续下滑加载更多」
          //   或「没有更多了」，失败源被永久剔除（p.failed 之后没人再复位）。
          //   ★ 档位次序 = more 优先于 fail：还有源能翻就先让它翻（这里若让 fail 抢先，
          //   loadMoreResults 首行的 moreState !== 'more' 闸门会把健康源的翻页一起挡死）。
          //   翻页侧那条（loadMoreResults 末尾）用的是同一个次序，两边必须一致。
          this.moreState = merged.length === 0 ? '' : (anyOpen ? 'more' : (anyFailed ? 'fail' : 'end'));
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
        // s11 第 7 条（用户 11-12 16:15 report 第 7 条「顶栏纯白、下面页面底色浅灰」）：
        // 本页顶栏此前吃顶栏组件的默认实底令牌 cardColor（浅色 #FFFFFF），而本页根容器的
        // backgroundColor 吃 Theme.background（浅色 #F1F3F5、深色 dBg #000000 对比 dCard #1C1C1E）⇒ 两块皮。
        // flatBackground 是 BreezeTopBar 本轮新增的开关（默认 false，其余页面零变化），
        // 打开后实底档换成与本页根容器同一个 Theme.background ⇒ 顶栏与页面无缝。
        // 本页 scrollProgress 未传（默认 1）= 恒实底档，所以效果是全程同色，滚动中也不会跳色；
        // R6 互斥红线未碰：玻璃档（真机无材质，进不去）仍走 systemMaterial 那条分支。
        flatBackground: true,
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
          // s9 口径（无词进入 = 顶栏图标 / 发现页残留入口）：自动聚焦、直接弹键盘，一个字没改。
          // s11 第 6 条新增档：带词进来时不聚焦（判据与理由见 entryWithKeyword 字段注释）。
          // 键盘避让那条链（RESIZE 下发 + onEditChange 补发 + 离开还原）两档共用，未做任何改动。
          .defaultFocus(!this.entryWithKeyword)
          .onChange((value: string) => {
            this.keyword = value;
          })
          .onSubmit(() => {
            this.doSearch();
          })
          // s10 第 2 条：输入框进入编辑态（= 键盘即将弹起）时把 RESIZE 档再下发一次。
          // SDK search.d.ts:631-644 onEditChange 原文「The text box is in the editing state when it has the
          // caret placed in it」，@since 12 ⇒ 真机 API26 可用；它是键盘 show 之前最后一次本页可控的时机，
          // 正好堵住「键盘先弹、档位后落」那个时序缝（详见 setKbAvoid 注释）。setKbAvoid 幂等，
          // 常态下这一次读回的还是 RESIZE，只会多一行 kbAvoid=RESIZE 日志，不改布局、不触发重排。
          .onEditChange((editing: boolean) => {
            if (editing) {
              this.setKbAvoid(true);
            }
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
                      // 第 7 条：选中即落盘（存 chip.id，不存下标）。不抓「退出」时机 —— 选中即写幂等、
                      // 开销一次 flush，异步且内部吞异常；下次进页由 reloadChips 按 id 回填。
                      LastSourceStore.writeSearchId(chip.id);
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
        // s33 需求 2：触底自动取下一页（List/Scroll 同 SDK 方法，grid.d.ts:1048）。
        // 触底后还会不会再来一次取决于内容是否变高：变了重新布局就不再触发，
        // 没变（该源到底）⇒ 靠 moreState 闸住（loadMoreResults 首行判 'more'）。
        .onReachEnd((): void => {
          this.loadMoreResults();
        })
        // T9 需求 2：onDidScroll 只给每帧增量 ⇒ 从 scroller 读绝对偏移，同喂顶栏斜坡与工具区收起
        .onDidScroll((_offset: number, _state: ScrollState) => {
          const y: number = this.gridScroller.currentOffset().yOffset;
          Anim.reportTopBar(y);
          this.syncToolCollapse(y);
        })

        // s33 需求 2：翻页状态行。**放 Grid 外**（固定贴在结果区底部）—— 本 SDK 的
        // GridItemAttribute 没有 columnSpan（gridItem.d.ts 实测零命中），塞进 GridItem
        // 只占一列宽、三列下看着像坏了，与上面那条计数行同一个理由。
        if (this.moreState.length > 0) {
          Row() {
            if (this.moreState === 'loading') {
              // 不用 LoadingView：它自带 width/height 100%（StateViews.ets:27-28），
              // 塞进这条 40vp 的行里会把行撑满剩余高度。这里要的是行内小转圈。
              LoadingProgress()
                .width(16)
                .height(16)
                .color(Theme.brand)
                .margin({ right: 6 })
              Text('加载中…')
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
            } else if (this.moreState === 'end') {
              Text('没有更多了')
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
            } else if (this.moreState === 'fail') {
              // s34 第 1 条（用户原话「也没有按钮让其重新加载」）：原来这里是一行 12fp 的橙字，
              // 真机上既看不出可点、点起来也只有几个字的面积 ⇒ 改成胶囊按钮，文案自解释。
              // 文案不写「下一页」：这一态现在也覆盖首屏某源失败（见 doSearch 的 anyFailed 分支），
              // 那种情况下失败的是第 1 页，写「下一页」会误导。
              Text('有图源加载失败')
                .fontSize(12)
                .fontColor(Theme.warning)
                .margin({ right: 10 })
              Button('重新加载', { type: ButtonType.Capsule, stateEffect: true })
                .height(28)
                .fontSize(12)
                .backgroundColor(Theme.brand)
                .fontColor(Theme.white)
                .onClick((): void => {
                  this.retryMore();
                })
            } else {
              Text('继续下滑加载更多')
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
            }
          }
          .width('100%')
          .height(40)
          .justifyContent(FlexAlign.Center)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
