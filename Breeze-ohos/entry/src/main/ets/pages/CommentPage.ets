/**
 * 职责：评论区页（需求 4 的「查看评论区」落点，用户 m05810：「评论区之类的来源于插件」）。
 * 数据来源：插件 getCommentFeed（首页/下一页）+ loadCommentReplies（某条的回复）。
 *   字段口径见 data/source/PluginDetail.ets 文件头（上游 comments_cubit.dart / comment_item.dart）。
 *
 * ★ v1 明确**只读**，不做发评：
 *   上游发评要先过插件 getLoginBundle 的登录流（上游 lib plugin bridge 目录），
 *   且 s6j 普查里唯一实现了 postComment 的 man-hua-gui 是 demo 桩（返回假数据）。
 *   ⇒ 发评入口显示为一行说明（canComment=false 时说明「该图源未开放评论」），
 *     将来接登录流再开，不要在这里假装能发。
 *
 * 能力缺口是常态（jjmhw / MangaDex 都没有评论区）⇒ 首屏失败走 EmptyView/ErrorView，不崩。
 * 依赖：data/source/PluginDetail、view/common（顶栏主题状态视图）。
 * 依据系统 Kit：@kit.ArkUI（router）。
 */
import { router } from '@kit.ArkUI';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { Anim } from '../view/common/Anim';
import { LoadingView, EmptyView, ErrorView } from '../view/common/StateViews';
import { CommentParams } from '../view/detail/CommentParams';
import { PluginDetail, CommentFeed, CommentItem } from '../data/source/PluginDetail';
import { Logger } from '../util/Logger';

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
  @StorageProp('isDark') isDark: boolean = false;
  onToggle: () => void = () => {};

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
          Text(this.item.author.length > 0 ? this.item.author : '匿名')
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

      Text(this.item.content)
        .fontSize(14)
        .fontColor(Theme.text1(this.isDark))
        .lineHeight(21)
        .width('100%')
        .margin({ top: 8 })

      if (!this.isReply && this.item.replyCount > 0) {
        Row() {
          Text(this.hasReplies ? '收起回复' : ('查看 ' + this.item.replyCount + ' 条回复'))
            .fontSize(12)
            .fontColor(Theme.brand)
          if (this.busy) {
            Text('加载中…')
              .fontSize(12)
              .fontColor(Theme.text3(this.isDark))
              .margin({ left: 8 })
          }
        }
        .margin({ top: 8 })
        .onClick(() => {
          this.onToggle();
        })
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
   * ★ ForEach 的 key 必须把「回复展开态」编进去。
   * ArkUI 的 ForEach key 不变 ⇒ 子项**不重新构建**（即使 @State replyMap 换了引用、
   * 即使 @Builder 形参是值传递）。首版把 key 写成 'c_'+idx+'_'+id，实测表现是
   * 「点『查看 N 条回复』毫无反应」——数据已经拉到了，UI 没重画。
   * 现在把 open/busy 拼进 key，展开即换 key ⇒ 该条 ListItem 重建。
   */
  private keyOf(prefix: string, idx: number, c: CommentItem): string {
    const open: boolean = this.repliesOf(c.id) !== undefined;
    const busy: boolean = this.replyBusy === c.id;
    return prefix + '_' + idx + '_' + c.id + '_' + (open ? 'o' : 'c') + (busy ? 'b' : '');
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

  build() {
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
        ErrorView({ msg: this.loadError })
          .layoutWeight(1)
      } else if (this.top.length === 0 && this.items.length === 0) {
        EmptyView({ text: '这里还没有评论', hint: '该图源未返回任何评论' })
          .layoutWeight(1)
      } else {
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
                  onToggle: (): void => {
                    this.toggleReplies(c);
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
                  onToggle: (): void => {
                    this.toggleReplies(c);
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
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
