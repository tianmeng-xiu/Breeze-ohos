/**
 * 职责：评论区页（需求 4 的「查看评论区」落点，用户 m05810：「评论区之类的来源于插件」）。
 * 数据来源：插件 getCommentFeed（首页/下一页）+ loadCommentReplies（某条的回复）。
 *   字段口径见 data/source/PluginDetail.ets 文件头（上游 comments_cubit.dart / comment_item.dart）。
 *
 * ★ 已支持发评 / 发回复（需求 3），但**真机无处可验**，这条限定别删：
 *   上游发评要先过插件 getLoginBundle 的登录流（上游 lib plugin bridge 目录），我方还没接；
 *   且 s6j 普查里唯一实现了 postComment 的 man-hua-gui 是 demo 桩（返回假数据），
 *   jjmhw / MangaDex 连 postComment 都没实现 ⇒ 本地没有任何一条能真正发出去的图源。
 *   ⇒ 代码按上游 comments_cubit.dart:111/119/166-249 的口径逐字实现（含 insertHint 三种本地
 *     落位策略与整页重拉兜底），插件一旦实现就直接可用；接入前请不要在文档里写「已验证」。
 *   ⇒ 入口仍按 canComment.comic / canComment.reply 置灰并说明（图源说不行就是不行，别硬发）。
 *
 * 能力缺口是常态（jjmhw / MangaDex 都没有评论区）⇒ 首屏失败走 EmptyView/ErrorView，不崩。
 * 依赖：data/source/PluginDetail、view/common（顶栏主题状态视图）。
 * 依据系统 Kit：@kit.ArkUI（router、promptAction）。
 */
import { promptAction, router } from '@kit.ArkUI';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { Anim } from '../view/common/Anim';
import { LoadingView, EmptyView, ErrorView } from '../view/common/StateViews';
import { CommentParams } from '../view/detail/CommentParams';
import { PluginDetail, CommentFeed, CommentItem, CommentPostResult } from '../data/source/PluginDetail';
import { Logger } from '../util/Logger';
import { TextConvert } from '../util/TextConvert';
import { FeatureDiag } from '../util/FeatureDiag';

/**
 * 上游 _bumpReplyCount（comments_cubit.dart:251）的同层列表版本：找到**第一条**同 id 的评论，
 * 回复数 +1。★ 与上游唯一的差别是这里**换引用**（产出一个 replyCount+1 的副本替换原位置）：
 * ArkTS 的 @State 只认引用变化、@Prop 也只按引用比对，原地改 `c.replyCount` 不会让
 * 「查看 N 条回复」重画（与本页 loadMore 的「整体换引用」是同一条约束）。
 * 返回 null = 这份列表里没有该 id（调用方据此判断这条评论在不在当前页）。
 */
function bumpReplyOne(list: CommentItem[], targetId: string): CommentItem[] | null {
  const idx: number = indexOfCommentId(list, targetId);
  if (idx < 0) {
    return null;
  }
  const out: CommentItem[] = [];
  for (let i = 0; i < list.length; i++) {
    out.push(i === idx ? copyCommentBumped(list[i]) : list[i]);
  }
  return out;
}

/** 浅拷贝一条评论并把 replyCount 加一（extern / inlineReplies 按引用带过去，不需要复制）。 */
function copyCommentBumped(c: CommentItem): CommentItem {
  const n: CommentItem = new CommentItem();
  n.id = c.id;
  n.author = c.author;
  n.avatarUrl = c.avatarUrl;
  n.content = c.content;
  n.createdAt = c.createdAt;
  n.replyCount = c.replyCount + 1;
  n.inlineReplies = c.inlineReplies;
  n.extern = c.extern;
  return n;
}

function indexOfCommentId(list: CommentItem[], id: string): number {
  for (let i = 0; i < list.length; i++) {
    if (list[i].id === id) {
      return i;
    }
  }
  return -1;
}

/** 前插一条并整体换新数组（@State 对 push/unshift 不敏感，见 loadMore 同款处理）。 */
function prependComment(list: CommentItem[], created: CommentItem): CommentItem[] {
  const out: CommentItem[] = [created];
  for (let i = 0; i < list.length; i++) {
    out.push(list[i]);
  }
  return out;
}

/**
 * 单条评论（回复同形状复用）。
 * ★ 为什么是 @Component 而不是本页 @Builder：
 *   ① @Builder 形参按值传递、状态变化不重渲染 ⇒ 「收起回复」点击后 UI 不动；
 *   ② @Builder **不能递归**（自身调自身编不过）⇒ 回复只能由外层把 replyList 传进来，
 *      回复内部不再嵌组件（v1 回复不再展开回复，与上游一致）。
 */
@Component
struct CommentRowView {
  @Prop item: CommentItem = new CommentItem();
  @Prop isTop: boolean = false;
  @Prop isReply: boolean = false;
  /** undefined = 未展开；有值 = 已展开（空数组也要传，表示「展开但无回复」） */
  @Prop replyList: CommentItem[] = [];
  @Prop hasReplies: boolean = false;
  @Prop busy: boolean = false;
  /** 图源是否开放回复（插件 canComment.reply）。false ⇒ 回复入口画出来但置灰，点击给说明。 */
  @Prop canReply: boolean = false;
  /** 有提交在飞（上游 posting）⇒ 回复入口一并置灰，防连点重复提交。 */
  @Prop posting: boolean = false;
  @StorageProp('isDark') isDark: boolean = false;
  onToggle: () => void = () => {};
  onReply: () => void = () => {};

  /**
   * 简繁转换版本号：放在渲染层（本组件）—— ForEach 的键不随档位变、父层重跑 build
   * 也不重建这些行，只有本组件自己观察版本号，词典就绪/切档后作者与正文才会重算
   * （同 pages/HistoryPage.ets 的 HistoryRowItem 形态；上游消费点 = plugin_comments_scaffold.dart:224/:232）。
   */
  @StorageProp('textConvertRev') cvtRev: number = 0;

  /** 显示文案过一遍简繁转换（只改显示，不参与搜索匹配与屏蔽词匹配）。 */
  private cvtShow(raw: string): string {
    const rev: number = this.cvtRev;
    if (rev <= 0) {
      return raw;
    }
    return TextConvert.getInstance().cvt(raw);
  }

  /**
   * 置灰时点「回复」给的那句人话。两个原因分开说，别混成一句「不支持」：
   *   ① 插件 canComment.reply=false（图源没开放回复）；② 插件漏 id ⇒ 拿不到 commentId，
   *   上游 postReply 也是靠 item.id 组 core（comments_cubit.dart:122），没 id 连请求都组不出来。
   * 为什么不显示插件给的 *Reason：那是**详情**返回体里的 allowCommentsReason
   *   （normal_comic_all_info），评论回包的 canComment 只有 comic/reply 两个 bool，没有文案字段。
   */
  private replyGateTip(): string {
    if (this.item.id.length === 0) {
      return '这条评论缺少标识，无法回复';
    }
    return '该图源未开放回复评论';
  }

  build() {
    Column() {
      Row() {
        // 头像位：插件给的头像多数要额外签名，v1 用首字母占位（不额外发请求）
        Stack() {
          Text(this.item.author.length > 0 ? this.item.author.substring(0, 1) : '?')
            .fontSize(this.isReply ? 12 : 14)
            .fontColor(Theme.white)
        }
        .width(this.isReply ? 24 : 32)
        .height(this.isReply ? 24 : 32)
        .borderRadius(this.isReply ? 12 : 16)
        .backgroundColor(Theme.brand)

        Column() {
          Text(this.item.author.length > 0 ? this.cvtShow(this.item.author) : '匿名')
            .fontSize(13)
            .fontColor(Theme.text2(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.item.createdAt.length > 0) {
            Text(this.item.createdAt)
              .fontSize(11)
              .fontColor(Theme.text3(this.isDark))
              .margin({ top: 2 })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 10 })
        .layoutWeight(1)

        if (this.isTop) {
          Text('置顶')
            .fontSize(10)
            .fontColor(Theme.warning)
            .padding({ left: 6, right: 6, top: 2, bottom: 2 })
            .borderRadius(6)
            .borderWidth(0.5)
            .borderColor(Theme.warning)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Text(this.cvtShow(this.item.content))
        .fontSize(14)
        .fontColor(Theme.text1(this.isDark))
        .lineHeight(21)
        .width('100%')
        .margin({ top: 8 })

      // 操作行：左「查看 N 条回复 / 收起回复」，右「回复」入口（需求 3）。
      // ★ 必须两个入口各自独立：旧版只在 replyCount>0 时画一个 Row ⇒ replyCount==0 的楼层
      //   连「回复」都没有，新楼发不出去就没法回。这里 replyCount==0 也画行、只画「回复」。
      // ★ 上游口径：canCommentReply=false 时**直接不画**回复图标（plugin_comments_scaffold.dart:268），
      //   我方按 lead 口径改成「画出来但置灰 + 点了给一句人话」，用户才知道是被图源限制而不是坏了。
      //   置灰色 = Theme.text3（与本页次要文字同档），文案来源见 replyGateTip()。
      if (!this.isReply) {
        Row() {
          if (this.item.replyCount > 0) {
            Text(this.hasReplies ? '收起回复' : ('查看 ' + this.item.replyCount + ' 条回复'))
              .fontSize(12)
              .fontColor(Theme.brand)
              .onClick(() => {
                this.onToggle();
              })
            if (this.busy) {
              Text('加载中…')
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
                .margin({ left: 8 })
            }
          }
          Blank()
          Text('回复')
            .fontSize(12)
            .fontColor(this.canReply && this.item.id.length > 0 ? Theme.brand : Theme.text3(this.isDark))
            .padding({ left: 10, right: 2, top: 2, bottom: 2 })
            .onClick(() => {
              if (this.posting) {
                promptAction.showToast({ message: '上一条还在提交，请稍候', duration: 1600 });
                return;
              }
              // 置灰态（图源没开放回复 / 这条没 id）不静默吞掉点击 —— 给一句人话说明为什么点不动
              if (!this.canReply || this.item.id.length === 0) {
                promptAction.showToast({ message: this.replyGateTip(), duration: 2200 });
                return;
              }
              this.onReply();
            })
        }
        .width('100%')
        .margin({ top: 8 })
        .alignItems(VerticalAlign.Center)
      }

      // 展开的回复（一层，不再递归）
      if (!this.isReply && this.hasReplies) {
        Column() {
          ForEach(this.replyList, (r: CommentItem, idx: number) => {
            Column() {
              CommentRowView({ item: r, isTop: false, isReply: true })
            }
            .width('100%')
            .padding({ left: 12, top: 10 })
          }, (r: CommentItem, idx: number) => 'r' + idx + '_' + r.id)
          if (this.replyList.length === 0) {
            Text('暂无回复')
              .fontSize(12)
              .fontColor(Theme.text3(this.isDark))
          }
        }
        .width('100%')
        .margin({ top: 8 })
        .padding({ left: 8 })
        .border({ width: { left: 2 }, color: Theme.dividerColor(this.isDark) })
        .alignItems(HorizontalAlign.Start)
      }
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding({ bottom: this.isReply ? 0 : 14 })
  }
}

@Entry
@Component
struct CommentPage {
  @StorageProp('isDark') isDark: boolean = false;

  @State mangaId: string = '';
  @State sourceId: string = '';
  @State title: string = '';

  @State loading: boolean = true;
  @State loadError: string = '';
  @State top: CommentItem[] = [];
  @State items: CommentItem[] = [];
  @State canCommentComic: boolean = false;
  @State canReply: boolean = false;
  @State hasMore: boolean = false;
  @State page: number = 1;
  /** 下一页加载中（防止滚动触底重复请求） */
  @State loadingMore: boolean = false;
  /** 已展开回复的评论 id → 回复数组（未展开的不请求） */
  @State replyMap: Map<string, CommentItem[]> = new Map<string, CommentItem[]>();
  /** 正在拉回复的 id（显示「回复加载中…」） */
  @State replyBusy: string = '';
  /**
   * 有提交在飞（上游 CommentsViewState.posting，comments_cubit.dart:23/171/204）。
   * 上游用它在 postComment/postReply 开头 `if (state.posting) return;` 挡住重复提交，
   * 并把 FAB / 回复图标的 onPressed 置 null —— 我方等价实现：本标志 + 入口置灰 + 直接 return。
   */
  @State posting: boolean = false;
  /** 输入浮层是否打开（发评 / 回复共用一个浮层，靠 replyTo 区分）。 */
  @State composeOpen: boolean = false;
  /** null = 发整页评论；有值 = 回复这条（上游 postReply(item, content) 的 item）。 */
  @State replyTo: CommentItem | null = null;
  /**
   * 浮层里的输入内容（关掉浮层即清空，不留草稿——与上游每次新建 controller 一致）。
   * ★ **故意不加 @State**（这是 EditOverlay 那边 `t.text` 也是普通字段的真正原因，
   *   它的注释只写了「@Builder 里挡可空」，没写这一条）：TextArea 的 text 形参一旦被
   *   响应式状态驱动，就会在每次 onChange 后回灌给组件 ⇒ 光标被拽到末尾、中间改字打不了。
   *   本值只在点「确认」那一刻读一次（submitCompose），页面重渲染不需要它参与，
   *   所以它没有响应式需求；浮层每次打开都是新建的组件，初值由 draftText() 给（那时已是 ''）。
   */
  private draft: string = '';

  /**
   * ★ ForEach 的 key 必须把「回复展开态」编进去。
   * ArkUI 的 ForEach key 不变 ⇒ 子项**不重新构建**（即使 @State replyMap 换了引用、
   * 即使 @Builder 形参是值传递）。首版把 key 写成 'c_'+idx+'_'+id，实测表现是
   * 「点『查看 N 条回复』毫无反应」——数据已经拉到了，UI 没重画。
   * 现在把 open/busy 拼进 key，展开即换 key ⇒ 该条 ListItem 重建。
   */
  private keyOf(prefix: string, idx: number, c: CommentItem): string {
    const open: boolean = this.repliesOf(c.id) !== undefined;
    const busy: boolean = this.replyBusy === c.id;
    // ★ posting 也要进 key：同上，key 不变 ⇒ 子项不重建 ⇒ @Prop posting 不会重新同步，
    //   提交进行中那一瞬间各行的「回复」不会变灰。多付一次「可见行重建」换灰态是真的。
    //   （重复提交本身不靠这个灰态兜：openReply/submitCompose 第一行都各自挡了 posting。）
    // ★ replyCount 同理要进 key：发回复成功后 bumpReplyOne 只换数组元素引用，
    //   楼层已展开时 open 位不变 ⇒ 光换数组「查看 N 条回复」那个数字不会重画。
    return prefix + '_' + idx + '_' + c.id + '_' + (open ? 'o' : 'c') + (busy ? 'b' : '')
      + (this.posting ? 'p' : '') + '_n' + c.replyCount;
  }

  aboutToAppear(): void {
    try {
      const raw: Object = router.getParams();
      if (raw instanceof CommentParams) {
        this.mangaId = raw.mangaId;
        this.sourceId = raw.sourceId;
        this.title = raw.title;
      } else if (raw !== null && raw !== undefined) {
        const src: ESObject = raw;
        this.mangaId = src.mangaId !== undefined ? String(src.mangaId) : '';
        this.sourceId = src.sourceId !== undefined ? String(src.sourceId) : '';
        this.title = src.title !== undefined ? String(src.title) : '';
      }
    } catch (e) {
      Logger.w('CommentPage 参数解析失败：' + (e as Error).message);
    }
    this.reload();
  }

  async reload(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    // ★ 与上游 loadInitial 一致（comments_cubit.dart:52-58 把 expandedIds / replyItems 一起清空）。
    //   这条在「发评成功后整页重拉」这条路径上是**必需**的，不只是整洁：若留着旧的展开态，
    //   用户刚发出去的那条回复会看起来「消失了」—— 楼层仍显示展开，里面装的却是发成功之前
    //   那批旧回复（新数据在插件那边，我方没重拉那一层）。折叠掉让用户自己再点开才是对的。
    this.replyMap = new Map<string, CommentItem[]>();
    this.replyBusy = '';
    const feed: CommentFeed = await PluginDetail.comments(this.sourceId, this.mangaId, 1);
    this.top = feed.top;
    this.items = feed.items;
    this.canCommentComic = feed.canCommentComic;
    this.canReply = feed.canReply;
    this.hasMore = !feed.hasReachedMax;
    this.page = 1;
    if (feed.error.length > 0) {
      // 「这里还没有评论」是可展示的空态，其余是失败
      if (feed.error === '这里还没有评论') {
        this.loadError = '';
      } else {
        this.loadError = feed.error;
      }
    }
    this.loading = false;
  }

  async loadMore(): Promise<void> {
    if (this.loadingMore || !this.hasMore || this.loading) {
      return;
    }
    this.loadingMore = true;
    const feed: CommentFeed = await PluginDetail.comments(this.sourceId, this.mangaId, this.page + 1);
    this.loadingMore = false;
    if (feed.error.length > 0 && feed.items.length === 0) {
      this.hasMore = false;
      return;
    }
    if (feed.items.length === 0) {
      this.hasMore = false;
      return;
    }
    this.page = this.page + 1;
    const merged: CommentItem[] = [];
    for (let i = 0; i < this.items.length; i++) {
      merged.push(this.items[i]);
    }
    for (let i = 0; i < feed.items.length; i++) {
      merged.push(feed.items[i]);
    }
    // @State 对数组 push 不敏感 ⇒ 整体换引用
    Anim.to((): void => {
      this.items = merged;
      this.hasMore = !feed.hasReachedMax;
    }, Anim.contentIn, Anim.curveEaseOut());
  }

  /** 展开/收起某条评论的回复（首次展开才拉）。 */
  async toggleReplies(c: CommentItem): Promise<void> {
    if (c.id.length === 0) {
      return;
    }
    const hit: CommentItem[] | undefined = this.replyMap.get(c.id);
    if (hit !== undefined) {
      // 已展开 ⇒ 收起（删键并换 Map 引用）
      this.replyMap.delete(c.id);
      const next: Map<string, CommentItem[]> = new Map<string, CommentItem[]>();
      this.replyMap.forEach((v: CommentItem[], k: string): void => {
        next.set(k, v);
      });
      Anim.to((): void => {
        this.replyMap = next;
      }, Anim.contentIn, Anim.curveEaseOut());
      return;
    }
    if (this.replyBusy === c.id) {
      return;
    }
    // replyMode='inline' 的插件把回复随主帖一起给了（上游 comments_cubit.dart:345 的 replyMode）
    // ⇒ 就地展开，绝不再打一次 loadCommentReplies（会把同一批回复拉两遍）。
    let list: CommentItem[] = [];
    if (c.inlineReplies.length > 0) {
      list = c.inlineReplies;
    } else {
      this.replyBusy = c.id;
      list = await PluginDetail.replies(this.sourceId, this.mangaId, c, 1);
      this.replyBusy = '';
    }
    const next: Map<string, CommentItem[]> = new Map<string, CommentItem[]>();
    this.replyMap.forEach((v: CommentItem[], k: string): void => {
      next.set(k, v);
    });
    next.set(c.id, list);
    Anim.to((): void => {
      this.replyMap = next;
    }, Anim.contentIn, Anim.curveEaseOut());
  }

  private repliesOf(id: string): CommentItem[] | undefined {
    if (id.length === 0) {
      return undefined;
    }
    return this.replyMap.get(id);
  }

  // ---------------- 发评 / 发回复（需求 3） ----------------

  /** 打开浮层发整页评论（上游 FAB → _postComicComment，plugin_comments_scaffold.dart:76-84/429-438）。 */
  private openCompose(): void {
    if (this.posting) {
      return;
    }
    this.replyTo = null;
    this.draft = '';
    this.composeOpen = true;
  }

  /** 打开浮层回复某条（上游行内回复图标 → _postReply，同文件 :268-285/440-449）。 */
  private openReply(c: CommentItem): void {
    if (this.posting) {
      return;
    }
    this.replyTo = c;
    this.draft = '';
    this.composeOpen = true;
  }

  private closeCompose(): void {
    this.composeOpen = false;
    this.replyTo = null;
    this.draft = '';
  }

  /** 浮层标题（上游 t.comments.postComment='发表评论' / postReply='回复评论'）。 */
  private composeTitle(): string {
    return this.replyTo === null ? '发表评论' : '回复评论';
  }

  /** 浮层占位（上游 postCommentHint='输入评论内容' / postReplyHint='输入回复内容'）。 */
  private composeHint(): string {
    return this.replyTo === null ? '输入评论内容' : '输入回复内容';
  }

  /**
   * 输入框内容。走 getter 而不是直读 this.draft（与 PluginSettingsPage:1964 editText() 同一个理由）：
   * TextInput/TextArea 的 text 形参若被当成「受控属性」随每次 onChange 回灌，光标会跳到最后
   * ⇒ getter 只在组件创建时读一次，输入过程由组件自己持有，关掉浮层才销毁重建（= 清空草稿）。
   */
  private draftText(): string {
    return this.draft;
  }

  /** 提交按钮文案：在飞时显示「提交中…」并吃掉点击（上游把按钮 onPressed 置 null 的等价物）。 */
  private submitLabel(): string {
    return this.posting ? '提交中…' : '确认';
  }

  /**
   * 提交。整页评论与回复走同一条流程（上游也是同一个 _submitCommentMutation，
   * comments_cubit.dart:166），差别只在 fnPath 与 extern。
   * 口径逐条对齐上游：
   *   :171 posting 门 ⇒ 这里第一行 return；
   *   :196 成功提示**在重拉之前**先发 ⇒ 先 toast 再（必要时）reload，别把顺序写反，
   *        否则弱网下用户要等整页拉完才看到「发布成功」；
   *   :200-202 失败 ⇒ 「发布失败: <原因>」（上游 postFailed 同措辞）；
   *   :203-205 finally ⇒ 无论成败都要把 posting 放下来（本方法用两条出口各自置回，
   *        ArkTS 这里没有 finally 语义差别可读性问题，但为了不漏，早退路径也都写了）。
   */
  async submitCompose(): Promise<void> {
    if (this.posting) {
      return;
    }
    const target: CommentItem | null = this.replyTo;
    // 上游 _openInputDialog 返回后 `if (content.isEmpty) return;`（scaffold :434-436），
    // 且 trim 后才提交（:480）⇒ 这里同样先 trim，空内容不打插件也不关浮层以外的状态。
    const content: string = this.draft.trim();
    if (content.length === 0) {
      promptAction.showToast({ message: this.composeHint() + '不能为空', duration: 1800 });
      return;
    }
    this.posting = true;
    FeatureDiag.get().cmCalls += 1;
    let res: CommentPostResult;
    if (target === null) {
      res = await PluginDetail.postComment(this.sourceId, this.mangaId, content);
    } else {
      res = await PluginDetail.postCommentReply(this.sourceId, this.mangaId, target, content);
    }
    if (res.error.length > 0 || !res.ok) {
      this.posting = false;
      const why: string = res.error.length > 0 ? res.error : '插件没有确认受理这次提交';
      const d: FeatureDiag = FeatureDiag.get();
      d.cmFail += 1;
      // 单独记「插件未实现」这一档：真机上 most 图源都是这一档，没有它
      // 就分不清「代码坏了」与「这个图源本来没这功能」（判据 = PluginDetail.postErrorText 那句人话）。
      if (why.indexOf('不支持') >= 0) {
        d.cmNoRoute += 1;
      }
      promptAction.showToast({ message: '发布失败: ' + why, duration: 2600 });
      Logger.w('发评失败 ok=' + (res.ok ? 'true' : 'false') + ' err=' + why);
      return;
    }
    this.closeCompose();
    // 先给成功提示，再动列表（顺序同上游 :196/:197）
    promptAction.showToast({ message: '发布成功', duration: 1800 });
    const applied: boolean = !res.needsRefetch && this.applyLocal(res);
    const dd: FeatureDiag = FeatureDiag.get();
    dd.cmOk += 1;
    if (!applied) {
      dd.cmRefetch += 1;
    }
    if (!applied) {
      // 上游 :197 `if (!applied) await loadInitial();` ⇒ 重拉整页兜底。
      // reload() 里连 replyMap 一起清（同上游 loadInitial :55），理由见那边的注释。
      await this.reload();
    }
    this.posting = false;
  }

  /**
   * 本地落位（上游 _buildMutationAppliedState，comments_cubit.dart:208-249）——三种策略 + 一个兜底：
   *   ① 'prependAfterTop' ⇒ 插到 items 最前（置顶区下面），:219；
   *   ② 'prepend' + 有 targetCommentId ⇒ 插进该楼层的回复列表最前、该楼层置为已展开、
   *      并在 top/items 里把该楼层的 replyCount +1（:222-245，等价 _bumpReplyCount :251）；
   *   ③ 'prepend' 但 target 为空 / ④ strategy 没给 ⇒ 一律退化成「插到 items 最前」（:248 兜底）。
   * 返回 false = 没能本地插入（插件没回 created），调用方据此整页重拉。
   * ★ created 缺失是上游也走的同一条路（:210 return null ⇒ :197 loadInitial），
   *   不是我方兜底偷懒：没有条目内容就插不进列表，只能重拉让服务端给。
   * ★ bump 之所以画得出来：同一次提交还把 replyMap[target] 置上 ⇒ keyOf 的 open 位翻成 'o'
   *   ⇒ 该 ListItem 重建（与上面 keyOf 注释是同一条 ForEach 约束）。
   */
  private applyLocal(res: CommentPostResult): boolean {
    const maybe: CommentItem | null = res.created;
    if (maybe === null) {
      return false;
    }
    // 已过 null 判定 ⇒ 收成非空本地量再用：闭包里读可空属性 ArkTS 不给窄化，
    // 下面三处都要把这条塞进 Anim.to 的闭包，所以先落地一个非空 const。
    const created: CommentItem = maybe;
    if (res.strategy === 'prependAfterTop') {
      Anim.to((): void => {
        this.items = prependComment(this.items, created);
      }, Anim.contentIn, Anim.curveEaseOut());
      return true;
    }
    if (res.strategy === 'prepend' && res.targetCommentId.length > 0) {
      const targetId: string = res.targetCommentId;
      const cur: CommentItem[] | undefined = this.replyMap.get(targetId);
      const current: CommentItem[] = cur !== undefined ? cur : [];
      const next: Map<string, CommentItem[]> = new Map<string, CommentItem[]>();
      this.replyMap.forEach((v: CommentItem[], k: string): void => {
        next.set(k, v);
      });
      next.set(targetId, prependComment(current, created));
      const bumpedTop: CommentItem[] | null = bumpReplyOne(this.top, targetId);
      const bumpedItems: CommentItem[] | null = bumpReplyOne(this.items, targetId);
      Anim.to((): void => {
        this.replyMap = next;
        if (bumpedTop !== null) {
          this.top = bumpedTop;
        }
        if (bumpedItems !== null) {
          this.items = bumpedItems;
        }
      }, Anim.contentIn, Anim.curveEaseOut());
      return true;
    }
    // 上游 :248 的兜底前插（含 strategy 未知/为空的情况）
    Anim.to((): void => {
      this.items = prependComment(this.items, created);
    }, Anim.contentIn, Anim.curveEaseOut());
    return true;
  }

  /** 发评入口的说明文案（canCommentComic=false 时在底栏里显示，不弹 toast，常驻更好读）。 */
  private composeGateText(): string {
    if (this.canCommentComic) {
      return '';
    }
    return '该图源未开放评论';
  }

  /**
   * 底部「发表评论」输入条（对齐上游 FAB 的位置语义，但按 lead 口径做成常驻输入条）。
   * 关键约束（照抄 pages/PluginSettingsPage.ets:1981 浮层的结论）：
   *   · 动态文案一律走上面那些 getter —— @Builder 形参是按值快照，写 this.draft 直读不会随状态刷新；
   *   · 门在 canCommentComic：false ⇒ 整条置灰、点它只给一句说明（composeGateText），绝不弹输入框。
   * 这条放在 List **外面**当根 Column 的最后一个子节点，所以 List 的
   * contentEndOffset(Dim.contentBottomReserve) 不用改：底栏高度 ≠ 需要额外预留的滚动余量，
   * 它自己占布局，列表可视区自动变短。
   */
  @Builder
  ComposeBar() {
    Row() {
      Text(this.canCommentComic ? '说点什么…' : this.composeGateText())
        .fontSize(14)
        .fontColor(Theme.text3(this.isDark))
        .layoutWeight(1)
        .height(40)
        .padding({ left: 14 })
        .textAlign(TextAlign.Start)
        .backgroundColor(Theme.fillColor(this.isDark))
        .borderRadius(20)
        .onClick(() => {
          if (!this.canCommentComic) {
            promptAction.showToast({ message: '该图源未开放评论', duration: 2200 });
            return;
          }
          this.openCompose();
        })
      Text(this.posting ? '提交中…' : '发表评论')
        .fontSize(14)
        .fontColor(this.canCommentComic && !this.posting ? Theme.brand : Theme.text3(this.isDark))
        .padding({ left: 12, right: 2, top: 10, bottom: 10 })
        .onClick(() => {
          if (!this.canCommentComic) {
            promptAction.showToast({ message: '该图源未开放评论', duration: 2200 });
            return;
          }
          if (this.posting) {
            return;
          }
          this.openCompose();
        })
    }
    .width('100%')
    .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 8, bottom: 8 })
    .backgroundColor(Theme.cardColor(this.isDark))
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 输入浮层（发评 / 回复共用）。**结构照抄** PluginSettingsPage.ets:1981-2061 的 EditOverlay：
   * 遮罩与卡片必须是 Stack 的**两个兄弟层**，关闭只挂遮罩 —— 本 SDK 的 ClickEvent 没有
   * stopPropagation（只有 globalDisplayX/Y、displayX/Y、windowX/Y），挂外层会让点输入框/确认
   * 时冒泡把浮层直接关掉（那条实测记录见 s5i，别重踩）。
   */
  @Builder
  ComposeOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          if (this.posting) {
            return;
          }
          this.closeCompose();
        })

      Column() {
        Text(this.composeTitle())
          .fontSize(16)
          .fontColor(Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ bottom: 12 })

        TextArea({ text: this.draftText(), placeholder: this.composeHint() })
          .fontSize(15)
          .height(88)
          .backgroundColor(Theme.fillColor(this.isDark))
          .borderRadius(8)
          .onChange((v: string): void => {
            this.draft = v;
          })

        Row() {
          Text('取消')
            .fontSize(15)
            .fontColor(Theme.text2(this.isDark))
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              if (this.posting) {
                return;
              }
              this.closeCompose();
            })
          Blank()
          Text(this.submitLabel())
            .fontSize(15)
            .fontColor(this.posting ? Theme.text3(this.isDark) : Theme.brand)
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.submitCompose();
            })
        }
        .width('100%')
        .margin({ top: 8 })
      }
      .width('86%')
      .padding(20)
      .backgroundColor(Theme.cardColor(this.isDark))
      .borderRadius(Dim.radius)
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      Column() {
        BreezeTopBar({
          title: this.title.length > 0 ? ('评论 · ' + this.title) : '评论区',
          showBack: true,
          // 新七条第 7 条（lead 裁定 11-12 17:00）：全站路由页统一打开 flatBackground —— 顶栏实底档与本页根容器
          // 同吃 Theme.background，消除「顶栏一块色、页面一块色」的两块皮。开关默认 false，一级页不受影响。
          flatBackground: true,
          onBack: () => {
            router.back();
          }
        })

        if (this.loading) {
          LoadingView({ text: '正在加载评论区…' })
            .layoutWeight(1)
        } else if (this.loadError.length > 0) {
          // s37：ErrorView 的 onRetry 默认空函数而「重试」按钮恒画 ⇒ 显式接到本页真实重载入口。
          ErrorView({
            msg: this.loadError,
            onRetry: (): void => {
              this.reload();
            }
          })
            .layoutWeight(1)
        } else if (this.top.length === 0 && this.items.length === 0) {
          Column() {
            EmptyView({ text: '这里还没有评论', hint: '该图源未返回任何评论' })
              .layoutWeight(1)
            this.ComposeBar()
          }
          .width('100%')
          .layoutWeight(1)
        } else {
          Column() {
            List({ space: 0 }) {
              ListItem() {
                Column() {
                  Text(this.canCommentComic ? '以下评论来自该作品在该图源的公开评论'
                    : '以下评论来自该作品在该图源的公开评论（该图源未开放评论）')
                    .fontSize(11)
                    .fontColor(Theme.text3(this.isDark))
                    .width('100%')
                }
                .width('100%')
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12, bottom: 10 })
              }

              ForEach(this.top, (c: CommentItem, idx: number) => {
                ListItem() {
                  Column() {
                    CommentRowView({
                      item: c,
                      isTop: true,
                      isReply: false,
                      replyList: this.repliesOf(c.id) !== undefined ? (this.repliesOf(c.id) as CommentItem[]) : [],
                      hasReplies: this.repliesOf(c.id) !== undefined,
                      busy: this.replyBusy === c.id,
                      canReply: this.canReply,
                      posting: this.posting,
                      onToggle: (): void => {
                        this.toggleReplies(c);
                      },
                      onReply: (): void => {
                        this.openReply(c);
                      }
                    })
                    // 第 5 条(1)：行分隔线删除 —— 行间距已够层次，不再画明显分割线
                  }
                  .width('100%')
                  .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
                }
              }, (c: CommentItem, idx: number) => this.keyOf('top', idx, c))

              ForEach(this.items, (c: CommentItem, idx: number) => {
                ListItem() {
                  Column() {
                    CommentRowView({
                      item: c,
                      isTop: false,
                      isReply: false,
                      replyList: this.repliesOf(c.id) !== undefined ? (this.repliesOf(c.id) as CommentItem[]) : [],
                      hasReplies: this.repliesOf(c.id) !== undefined,
                      busy: this.replyBusy === c.id,
                      canReply: this.canReply,
                      posting: this.posting,
                      onToggle: (): void => {
                        this.toggleReplies(c);
                      },
                      onReply: (): void => {
                        this.openReply(c);
                      }
                    })
                    // 第 5 条(1)：行分隔线删除 —— 行间距已够层次，不再画明显分割线
                  }
                  .width('100%')
                  .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
                }
              }, (c: CommentItem, idx: number) => this.keyOf('c', idx, c))

              ListItem() {
                Column() {
                  if (this.loadingMore) {
                    Text('加载中…')
                      .fontSize(12)
                      .fontColor(Theme.text3(this.isDark))
                  } else if (this.hasMore) {
                    Text('加载更多')
                      .fontSize(13)
                      .fontColor(Theme.brand)
                      .onClick(() => {
                        this.loadMore();
                      })
                  } else {
                    Text('没有更多了')
                      .fontSize(12)
                      .fontColor(Theme.text3(this.isDark))
                  }
                }
                .width('100%')
                .height(56)
                .justifyContent(FlexAlign.Center)
              }
            }
            .layoutWeight(1)
            .scrollBar(BarState.Off)
            .contentEndOffset(Dim.contentBottomReserve)
            .onReachEnd(() => {
              this.loadMore();
            })

            this.ComposeBar()
          }
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(Theme.background(this.isDark))

      // 输入浮层：与上面的根 Column 是兄弟层（Stack 默认 alignContent=Center ⇒ 卡片自然居中）。
      if (this.composeOpen) {
        this.ComposeOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
