/**
 * 职责：插件「详情增强」与「评论 / 点赞」通道（需求 4，用户 m05810）。
 *   MangaSource 六方法只够列表/详情摘要/章节/页表，详情页要的评价数、点赞数、相关推荐、
 *   评论区、能否点赞都在插件的**扩展返回体**里，本文件负责把它们取出来并摊平成 UI 可用的形状。
 *
 * 上游契约依据（逐字对齐，勿自创字段名）：
 *   - 详情返回体 NormalComicAllInfo：Breeze/lib/page/comic_info/json/normal/
 *       normal_comic_all_info.freezed.dart:19 ⇒ comicInfo / preview / eps / recommend /
 *       totalViews / totalLikes / totalComments / isFavourite / isLiked /
 *       allowComments / allowLike / allowCollected / allowDownload + 四个 *Reason 文案。
 *     ⇒ **统计与可用性都由插件给**，UI 必须按 allow* 置灰并把 *Reason 当提示文案。
 *   - 评论：Breeze/lib/page/comments/cubit/comments_cubit.dart:113/121/284/329
 *       getCommentFeed{comicId,page} ⇒ data.{topItems,items,replyMode,canComment.{comic,reply},
 *                                          paging.hasReachedMax}
 *       loadCommentReplies{comicId,commentId,page} ⇒ data.{items,paging.hasReachedMax}
 *       postComment / postCommentReply（本文件末尾两条通道；入参与回包口径逐字抄上游
 *       comments_cubit.dart:111/119/184/208，见那两个 static 的注释）
 *   - 条目形状：Breeze/lib/page/comments/model/comment_item.dart:41
 *       id / author.{name,avatar.{url,path}} / content / createdAt(字符串) / replyCount / replies[]
 *   - 点赞/收藏 fnPath：collect_comic.dart:399/442/477/947/960/982
 *       toggleLike / toggleFavorite / startFavoriteAction / continueFavoriteAction /
 *       listFavoriteFolders / moveFavoriteToFolder
 *
 * ★ 能力缺口是**常态**，必须优雅降级（s6j 实测字符串计数，别以为插件都支持）：
 *     jjmhw 0.4.0：startFavoriteAction / continueFavoriteAction / recommend=8，**无评论、无点赞**
 *     man-hua-gui 0.1.0：getCommentFeed / loadCommentReplies / postComment / toggleLike 都有，
 *                        但源码位置串显示是 demo 桩（返回「示例」假数据、toggleLike 只翻本地状态）
 *     real(MangaDex 1.3.1)：recommend=1，评论/点赞全无
 *   ⇒ 所有方法**失败即空值**（空数组 / allowed=false + reason），绝不抛给页面。
 *
 * 依赖倒置：本文件收**图源 id**（'plugin:<uuid>'），内部经 SourceManager 取适配器；
 *   内置图源（MangaDex）直接返回空 ⇒ 详情页自然显示「该图源未提供」。
 * 依据系统 Kit：无。
 */
import { SourceManager } from './SourceManager';
import { MangaSource } from './Source';
import { PLUGIN_SOURCE_PREFIX, PluginSourceAdapter } from './PluginSourceAdapter';
import { MangaSummary, newMangaSummary } from '../model/Models';
import { jstr, jbool, jint, jarr, jobj, jhas, jisEmpty, jparse } from '../../util/JsonUtil';
import { bundleCall } from '../../util/PluginRuntime';
import { errBriefForScreen, errLog, errTextOf } from '../../util/ErrText';
import { Logger } from '../../util/Logger';

/**
 * ★ 入参统一形状（上游 unified_comic_plugin.dart:28 原文
 *   `payload = {...core, 'extern': extern ?? const {}}`）：
 *   **每个 fnPath 的入参对象里必定有 extern 键**，缺省是空对象。
 *   插件侧普遍直接读 args[0].extern（JM 系用它带风控头 / 评论用它带回游标），
 *   缺键会拿到 undefined 直接抛 ⇒ 下面每个 Arg 类都带 extern 字段，别删。
 */
/** {comicId, extern} */
class ComicIdArg {
  comicId: string = '';
  extern: ESObject = JSON.parse('{}');
}

/** {comicId, page, extern} */
class CommentFeedArg {
  comicId: string = '';
  page: number = 0;
  extern: ESObject = JSON.parse('{}');
}

/** {comicId, commentId, page, extern} */
class CommentReplyArg {
  comicId: string = '';
  commentId: string = '';
  page: number = 0;
  extern: ESObject = JSON.parse('{}');
}

/** {comicId, currentLiked, extern}（上游 collect_comic.dart:948：插件靠它判断是点赞还是取消） */
class ToggleLikeArg {
  comicId: string = '';
  currentLiked: boolean = false;
  extern: ESObject = JSON.parse('{}');
}

/** {comicId, currentFavorite, extern}（上游 collect_comic.dart:478，注意上游是**美式** Favorite） */
class ToggleFavArg {
  comicId: string = '';
  currentFavorite: boolean = false;
  extern: ESObject = JSON.parse('{}');
}

/** {comicId, content, extern}（上游 comments_cubit.dart:114 core={comicId,content}，extern 恒空对象） */
class CommentPostArg {
  comicId: string = '';
  content: string = '';
  extern: ESObject = JSON.parse('{}');
}

/** {comicId, commentId, content, extern}（上游 :122 core + :123 extern = **被回复那条自己的 extern**） */
class CommentReplyPostArg {
  comicId: string = '';
  commentId: string = '';
  content: string = '';
  extern: ESObject = JSON.parse('{}');
}

/** 统计 + 可用性（全部来自插件详情返回体）。 */
export class DetailStat {
  views: number = -1;
  likes: number = -1;
  comments: number = -1;
  isLiked: boolean = false;
  isFavourite: boolean = false;
  /** -1 未知 / 0 不允许 / 1 允许（不用三态 boolean，UI 要区分「插件没说」与「插件说不行」） */
  likeAllowed: number = -1;
  commentAllowed: number = -1;
  favouriteAllowed: number = -1;
  downloadAllowed: number = -1;
  likeReason: string = '';
  commentReason: string = '';
}

/** 一条评论（回复共用同形状；上游 comment_item.dart 的 replies[] 在这里内联展开一层）。 */
export class CommentItem {
  id: string = '';
  author: string = '';
  avatarUrl: string = '';
  content: string = '';
  /** 插件给的是字符串，原样显示（各家格式不统一，不做解析以免误显示） */
  createdAt: string = '';
  replyCount: number = 0;
  /** 上游 replyMode='inline' 时回复随主帖一起来；lazy 时为空、点开再拉 */
  inlineReplies: CommentItem[] = [];
  /** ★ 上游 loadCommentReplies 要把**这条评论自己的 extern** 原样带回（游标/风控上下文），丢了就翻不了页 */
  extern: ESObject = JSON.parse('{}');
}

/** 一页评论。 */
export class CommentFeed {
  items: CommentItem[] = [];
  /** 置顶（上游 topItems） */
  top: CommentItem[] = [];
  canCommentComic: boolean = false;
  canReply: boolean = false;
  hasReachedMax: boolean = true;
  /** 上游 data.replyMode（缺省 'lazy'）：'inline' = 回复已随主帖内联，不必再调 loadCommentReplies */
  replyMode: string = 'lazy';
  /** 非空 = 本次拉取失败/不支持，页面显示它 */
  error: string = '';
}

/**
 * 发评 / 发回复的返回（页面据此决定「本地插哪 / 要不要整页重拉 / 提示什么」）。
 * ★ 为什么这里**破**「用 string[] 三元组」的旧约定（toggleLike / toggleFavourite 那种）：
 *   本结果要带 ok + created(对象) + needsRefetch + strategy + targetCommentId + error 六样，
 *   数组下标写到第六位既读不出含义又极易错位 ⇒ 宁可多声明一个类（字段全给缺省值，绝不 null）。
 * 字段口径 = 上游 comments_cubit.dart:184-199 + :208-249（_submitCommentMutation /
 *   _buildMutationAppliedState）与插件契约 CommentMutationContract
 *   （Breeze/rust/rquickjs_playground/pnpm_demo/types/type.d.ts:216-234）。
 */
export class CommentPostResult {
  /** 插件是否受理了这次提交（契约里的 data.ok；缺键按 false，宁可提示失败也不假装成功） */
  ok: boolean = false;
  /** true = 要求放弃本地插入、整页重拉（上游 data.insertHint.needsRefetch） */
  needsRefetch: boolean = false;
  /** '' | 'prependAfterTop' | 'prepend'（上游 insertHint.strategy，缺省按 ''走兜底前插） */
  strategy: string = '';
  /** 'prepend' 的目标评论 id（上游优先 hint.targetCommentId，回退 data.parentId） */
  targetCommentId: string = '';
  /** 插件回的新评论；null = 它没给 ⇒ 无法本地插入，只能重拉 */
  created: CommentItem | null = null;
  /** 非空 = 失败/不支持，页面直接显示它（已翻译成人话，不含堆栈） */
  error: string = '';
}

/** 详情页一次性拿到的全部增强信息。 */
export class ComicExtras {
  /** 统计（即使详情失败也是可用对象，字段全默认值） */
  stat: DetailStat = new DetailStat();
  recommend: MangaSummary[] = [];
  /** 章节数（从同一份 eps 里数出来的，省一次调用） */
  chapterCount: number = 0;
  /** true = 该图源不支持/未取到详情增强（UI 只显示简介与章节） */
  empty: boolean = true;
}

function allowOf(o: ESObject, key: string): number {
  if (o === undefined || o === null || jisEmpty(o)) {
    return -1;
  }
  const v: ESObject = o[key];
  if (v === undefined || v === null) {
    return -1;
  }
  return v === true ? 1 : (v === false ? 0 : -1);
}

function numOf(o: ESObject, key: string): number {
  const n: number = jint(o, key, -1);
  if (n >= 0) {
    return n;
  }
  // 有的插件给字符串数字
  const s: string = jstr(o, key, '');
  if (s.length === 0) {
    return -1;
  }
  const p: number = parseInt(s, 10);
  return isFinite(p) ? p : -1;
}

/** 评论条目解析（上游 CommentItem.fromMap 同形状；缺字段一律兜底不跳过错行）。
 *  depth 只用来封顶递归层数（上游 comment_item.dart:41 是无深度递归，我方给 3 层封顶
 *  防插件返回自引用结构把 UI 拖死；3 层已远超上游 UI 实际展示的一层回复）。 */
function parseComment(raw: ESObject, depth: number): CommentItem | null {
  if (jisEmpty(raw)) {
    return null;
  }
  const it: CommentItem = new CommentItem();
  it.id = jstr(raw, 'id', '');
  const author: ESObject = jobj(raw, 'author');
  it.author = jisEmpty(author) ? '' : jstr(author, 'name', '');
  if (it.author.length === 0) {
    it.author = jstr(raw, 'authorName', '');
  }
  if (!jisEmpty(author)) {
    const avatar: ESObject = jobj(author, 'avatar');
    it.avatarUrl = jisEmpty(avatar) ? '' : jstr(avatar, 'url', '');
  }
  it.content = jstr(raw, 'content', jstr(raw, 'message', ''));
  it.createdAt = jstr(raw, 'createdAt', jstr(raw, 'time', ''));
  const rcRaw: ESObject = raw['replyCount'];
  if (typeof rcRaw === 'number') {
    it.replyCount = rcRaw as number;
  } else {
    const rcs: string = jstr(raw, 'replyCount', '');
    const p: number = parseInt(rcs, 10);
    it.replyCount = isFinite(p) ? p : 0;
  }
  // extern 原样留着（loadCommentReplies 要把它带回去；上游 comment_item.dart:56 同款）
  const ex: ESObject = raw['extern'];
  if (ex !== undefined && ex !== null && typeof ex === 'object') {
    it.extern = ex;
  }
  if (depth > 0) {
    it.inlineReplies = parseCommentList(jarr(raw, 'replies'), depth - 1);
    if (it.inlineReplies.length > 0 && it.replyCount === 0) {
      it.replyCount = it.inlineReplies.length;
    }
  }
  if (it.content.length === 0 && it.author.length === 0) {
    return null;
  }
  // 插件漏 id ⇒ 留空串，调用方据此禁用该条的「回复」按钮（loadCommentReplies 靠 id）
  return it;
}

function parseCommentList(arr: ESObject[], depth: number): CommentItem[] {
  const out: CommentItem[] = [];
  for (let i = 0; i < arr.length; i++) {
    const one: CommentItem | null = parseComment(arr[i], depth);
    if (one !== null) {
      out.push(one);
    }
  }
  return out;
}

/** 详情返回体里的 items 形状列表 → MangaSummary（recommend/preview 两种容器都用它）。 */
function parseSummaryList(arr: ESObject[]): MangaSummary[] {
  const out: MangaSummary[] = [];
  for (let i = 0; i < arr.length; i++) {
    const e: ESObject = arr[i];
    if (jisEmpty(e)) {
      continue;
    }
    const id: string = jstr(e, 'id', '');
    const title: string = jstr(e, 'title', '');
    if (id.length === 0 && title.length === 0) {
      continue;
    }
    const cover: ESObject = jobj(e, 'cover');
    const m: MangaSummary = newMangaSummary(id.length > 0 ? id : title, '', title);
    m.author = jstr(e, 'author', '');
    m.coverUrl = jisEmpty(cover) ? jstr(e, 'coverUrl', '') : jstr(cover, 'url', '');
    m.description = jstr(e, 'intro', jstr(e, 'description', ''));
    out.push(m);
  }
  return out;
}

/**
 * 解析「插件返回体里的布尔状态」。三种形状都吃（各家实现不一）：
 *   裸 `true` / `{liked:bool}` / `{data:{liked:bool}}`；`key` 传要取的字段名。
 * 注意 jparse 对非对象根返回共享空对象 ⇒ 裸布尔必须先看原文，不能靠 typeof。
 */
function readBoolResult(raw: string, key: string, fallback: boolean): boolean {
  const t: string = raw.trim();
  if (t === 'true') {
    return true;
  }
  if (t === 'false') {
    return false;
  }
  const v: ESObject = jparse(raw);
  const inner: ESObject = jobj(v, 'data');
  if (jhas(inner, key)) {
    return jbool(inner, key, fallback);
  }
  if (jhas(v, key)) {
    return jbool(v, key, fallback);
  }
  return fallback;
}

/**
 * 把发评/发回复的**异常**翻成人话。
 * ★ 未实现该 fnPath 的插件抛的是带 `route not found` 的原文（判定同
 *   data/cloud/CloudFavoriteSync.ets:202 那条注释），直接甩给用户就是一串英文路由名
 *   ⇒ 只认这一枚特征换成中文。**故意不放宽到裸 'not found'**：HTTP 404 之类的真故障
 *   也会含那四个字，误判成「不支持」会把该报的错盖掉。
 *   其余原样返回（callExt 已把它包成「发表评论失败（postComment）：<原错>」的可读形态，
 *   不再截断，免得丢掉插件自己写的说明）。
 */
function postErrorText(msg: string, what: string): string {
  if (msg.indexOf('route not found') >= 0) {
    return '这个图源不支持' + what + '（插件未实现该功能）';
  }
  return msg;
}

/**
 * 解析发评/发回复回包的 data 段（只吃 data，envelope 由调用方剥）。
 * 逐字对齐 CommentMutationContract（type.d.ts:216-234）：
 *   data.{ok, mode, parentId?, created, insertHint.{needsRefetch, strategy?, targetCommentId?}}
 * 与上游读取顺序一致（comments_cubit.dart:185 先读 needsRefetch，:209 再读 created）。
 * 插件缺字段一律兜底：created 缺失/形状不对 ⇒ null（页面据此走整页重拉），绝不抛。
 */
function parseCommentMutation(data: ESObject): CommentPostResult {
  const r: CommentPostResult = new CommentPostResult();
  if (jisEmpty(data)) {
    r.error = '插件返回为空';
    return r;
  }
  r.ok = jbool(data, 'ok', false);
  const hint0: ESObject = jobj(data, 'insertHint');
  const createdRaw0: ESObject = jobj(data, 'created');
  // ★ 三种口径都要吃（这里比上游**谨慎**、比契约**宽松**，理由写在这）：
  //   · 上游 _submitCommentMutation **完全不读 data.ok**（comments_cubit.dart:175-199）：
  //     没抛异常就当成功、直接发「发布成功」提示；
  //   · 契约 CommentMutationContract 把 ok 列为**必填** ⇒ 显式给了 false 就是真失败；
  //   · 现实里各家桩实现经常省掉 ok，只给 created / insertHint。若照契约硬判 false，
  //     就会在插件**已经发成功**的情况下弹「发布失败」——那是最糟的假失败。
  //   ⇒ 折中：显式 false 才算失败；ok 缺键时改用「有没有成功证据」（回了 created 或回了
  //     insertHint）来判受理，两者都没有才算失败。
  if (!jhas(data, 'ok')) {
    r.ok = !jisEmpty(createdRaw0) || !jisEmpty(hint0) || jstr(data, 'mode', '').length > 0;
  }
  if (!jisEmpty(hint0)) {
    r.needsRefetch = jbool(hint0, 'needsRefetch', false);
    r.strategy = jstr(hint0, 'strategy', '');
    r.targetCommentId = jstr(hint0, 'targetCommentId', '');
  }
  // 上游 :212 的 parentId 回退口（回复场景里有的插件只在 data 顶层给父 id）
  if (r.targetCommentId.length === 0) {
    r.targetCommentId = jstr(data, 'parentId', '');
  }
  const createdRaw: ESObject = createdRaw0;
  if (!jisEmpty(createdRaw)) {
    // depth 传 0：created 就是刚发的那一条，插件不会带回复，省掉一次无谓递归
    r.created = parseComment(createdRaw, 0);
  }
  return r;
}

export class PluginDetail {
  private static adapters: Map<string, PluginSourceAdapter | null> = new Map<string, PluginSourceAdapter | null>();

  /** 图源 id → 插件适配器（非插件源返回 null 并记忆，避免每次重查 instanceof）。 */
  private static adapterFor(sourceId: string): PluginSourceAdapter | null {
    const hit: PluginSourceAdapter | null | undefined = PluginDetail.adapters.get(sourceId);
    if (hit !== undefined) {
      return hit;
    }
    let ad: PluginSourceAdapter | null = null;
    if (sourceId.startsWith(PLUGIN_SOURCE_PREFIX)) {
      const src: MangaSource | null = SourceManager.getInstance().get(sourceId);
      if (src !== null && src instanceof PluginSourceAdapter) {
        ad = src as PluginSourceAdapter;
      }
    }
    PluginDetail.adapters.set(sourceId, ad);
    return ad;
  }

  /** 插件 uuid（详情页要直接调 bundleCall 时用）。 */
  static uuidOf(sourceId: string): string {
    return sourceId.startsWith(PLUGIN_SOURCE_PREFIX)
      ? sourceId.slice(PLUGIN_SOURCE_PREFIX.length)
      : '';
  }

  /** 图源注册/注销后清引用。 */
  static invalidate(sourceId: string): void {
    PluginDetail.adapters.delete(sourceId);
  }

  /**
   * 详情增强：一次 getComicDetail 拿全（统计 + 相关推荐 + 章节数）。
   * 与 Adapter.fetchDetail 用同一个 fnPath，只是**不摊平**、直接读 NormalComicAllInfo 的字段。
   * 失败返回 empty=true 的空壳，不抛。
   */
  static async extras(sourceId: string, mangaId: string): Promise<ComicExtras> {
    const out: ComicExtras = new ComicExtras();
    const ad: PluginSourceAdapter | null = PluginDetail.adapterFor(sourceId);
    if (ad === null) {
      return out;
    }
    const a: ComicIdArg = new ComicIdArg();
    a.comicId = mangaId;
    let o: ESObject;
    try {
      o = await ad.callExt('详情增强失败', 'getComicDetail', a);
    } catch (e) {
      Logger.w('详情增强：' + (e as Error).message);
      return out;
    }
    const data: ESObject = jobj(o, 'data');
    const normal: ESObject = jobj(data, 'normal');
    if (jisEmpty(normal)) {
      return out;
    }
    out.stat.views = numOf(normal, 'totalViews');
    out.stat.likes = numOf(normal, 'totalLikes');
    out.stat.comments = numOf(normal, 'totalComments');
    out.stat.isLiked = jbool(normal, 'isLiked', false);
    out.stat.isFavourite = jbool(normal, 'isFavourite', false);
    out.stat.likeAllowed = allowOf(normal, 'allowLike');
    out.stat.commentAllowed = allowOf(normal, 'allowComments');
    out.stat.favouriteAllowed = allowOf(normal, 'allowCollected');
    out.stat.downloadAllowed = allowOf(normal, 'allowDownload');
    out.stat.likeReason = jstr(normal, 'allowLikeReason', '');
    out.stat.commentReason = jstr(normal, 'allowCommentsReason', '');
    const eps: ESObject[] = jarr(normal, 'eps');
    out.chapterCount = eps.length;
    const rec: ESObject[] = jarr(normal, 'recommend');
    const list: MangaSummary[] = parseSummaryList(rec);
    for (let i = 0; i < list.length; i++) {
      list[i].sourceId = sourceId;
    }
    out.recommend = list;
    out.empty = false;
    return out;
  }

  /**
   * 评论首页 / 下一页（page 传 1 基，内部换算与上游一致：上游 cubit 直接透传 page）。
   * 任何异常 → CommentFeed.error，页面据此显示「该图源未提供评论区」。
   */
  static async comments(sourceId: string, comicId: string, page: number): Promise<CommentFeed> {
    const feed: CommentFeed = new CommentFeed();
    const ad: PluginSourceAdapter | null = PluginDetail.adapterFor(sourceId);
    if (ad === null) {
      feed.error = '该图源未提供评论区';
      return feed;
    }
    const a: CommentFeedArg = new CommentFeedArg();
    a.comicId = comicId;
    a.page = Math.max(1, Math.floor(page) || 1);
    let o: ESObject;
    try {
      o = await ad.callExt('评论区加载失败', 'getCommentFeed', a);
    } catch (e) {
      // s37 需求 2：原始串只进日志，error 给一句人话（页面直接把它铺到 ErrorView 上）。
      const raw: string = errTextOf(e);
      errLog('[PluginDetail] comments', raw);
      feed.error = errBriefForScreen(raw, '评论区加载失败，请稍后重试');
      return feed;
    }
    const data: ESObject = jobj(o, 'data');
    if (jisEmpty(data)) {
      feed.error = '评论区返回为空';
      return feed;
    }
    feed.items = parseCommentList(jarr(data, 'items'), 2);
    feed.top = parseCommentList(jarr(data, 'topItems'), 2);
    // 上游 comments_cubit.dart:345 `data['replyMode']?.toString() ?? 'lazy'`
    const mode: string = jstr(data, 'replyMode', '');
    feed.replyMode = mode.length > 0 ? mode : 'lazy';
    const can: ESObject = jobj(data, 'canComment');
    if (!jisEmpty(can)) {
      feed.canCommentComic = jbool(can, 'comic', false);
      feed.canReply = jbool(can, 'reply', false);
    }
    const paging: ESObject = jobj(data, 'paging');
    feed.hasReachedMax = jisEmpty(paging) ? true : jbool(paging, 'hasReachedMax', true);
    if (feed.items.length === 0 && feed.top.length === 0) {
      feed.error = '这里还没有评论';
    }
    return feed;
  }

  /**
   * 某条评论的回复（翻页用；失败返回空数组，不弹错——回复是次要信息）。
   * ★ 收**整条 CommentItem** 而不是 id：上游 comments_cubit.dart:286 要把这条评论自己的
   *   `extern` 原样带回（插件用它当游标），只传 id 会丢游标 ⇒ 第二页永远重复第一页。
   */
  static async replies(sourceId: string, comicId: string, item: CommentItem, page: number): Promise<CommentItem[]> {
    const empty: CommentItem[] = [];
    if (item.id.length === 0) {
      return empty;
    }
    const ad: PluginSourceAdapter | null = PluginDetail.adapterFor(sourceId);
    if (ad === null) {
      return empty;
    }
    const a: CommentReplyArg = new CommentReplyArg();
    a.comicId = comicId;
    a.commentId = item.id;
    a.page = Math.max(1, Math.floor(page) || 1);
    a.extern = item.extern;
    try {
      const o: ESObject = await ad.callExt('回复加载失败', 'loadCommentReplies', a);
      return parseCommentList(jarr(jobj(o, 'data'), 'items'), 1);
    } catch (e) {
      Logger.w('回复加载：' + (e as Error).message);
      return empty;
    }
  }

  /**
   * 点赞开关。返回 [成功, 新状态, 提示]（用 string[] 而不是自定义类：调用点只有一处，
   * 且 ArkTS 里三元组比再声明一个 Result 类更省，字段含义写在注释里）。
   * ★ 必须带 currentLiked（上游 collect_comic.dart:948）——插件靠它决定这次是点赞还是取消。
   */
  static async toggleLike(sourceId: string, comicId: string, current: boolean): Promise<string[]> {
    const ad: PluginSourceAdapter | null = PluginDetail.adapterFor(sourceId);
    if (ad === null) {
      return ['false', current ? 'true' : 'false', '该图源不支持点赞'];
    }
    const a: ToggleLikeArg = new ToggleLikeArg();
    a.comicId = comicId;
    a.currentLiked = current;
    try {
      const raw: string = await bundleCall(PluginDetail.uuidOf(sourceId), 'toggleLike', JSON.stringify([a]));
      const liked: boolean = readBoolResult(raw, 'liked', !current);
      return ['true', liked ? 'true' : 'false', ''];
    } catch (e) {
      return ['false', current ? 'true' : 'false', (e as Error).message];
    }
  }

  /**
   * 收藏开关（收藏 = 上游 toggleFavorite；我方书架另有本地表，两者不互相同步，UI 上分开说明）。
   * ★ 入参键是**美式** currentFavorite、回包键是 **data['favorited']**（上游 collect_comic.dart:478/481，
   *   它非 bool 直接抛 StateError）⇒ 先读美式，再兜底英式，最后兜 isFavourite。
   * ★ 上游还会读 `data['nextStep']`（=='selectFolder' 时弹目录选择）；我方没有云端收藏夹目录，
   *   所以把它如实转成一句提示，不让用户以为收藏失败了。
   */
  static async toggleFavourite(sourceId: string, comicId: string, current: boolean): Promise<string[]> {
    const ad: PluginSourceAdapter | null = PluginDetail.adapterFor(sourceId);
    if (ad === null) {
      return ['false', current ? 'true' : 'false', '该图源不支持收藏'];
    }
    const a: ToggleFavArg = new ToggleFavArg();
    a.comicId = comicId;
    a.currentFavorite = current;
    try {
      const raw: string = await bundleCall(PluginDetail.uuidOf(sourceId), 'toggleFavorite', JSON.stringify([a]));
      let fav: boolean = readBoolResult(raw, 'favorited', !current);
      if (!fav) {
        fav = readBoolResult(raw, 'favourite', !current);
      }
      if (!fav) {
        fav = readBoolResult(raw, 'isFavourite', !current);
      }
      let note: string = '';
      const nextStep: string = jstr(jobj(jparse(raw), 'data'), 'nextStep', '');
      if (nextStep === 'selectFolder') {
        note = '已收藏，但该图源要求选择收藏夹（本应用暂不支持云端收藏夹目录）';
      }
      return ['true', fav ? 'true' : 'false', note];
    } catch (e) {
      return ['false', current ? 'true' : 'false', (e as Error).message];
    }
  }

  /**
   * 发一条整页级评论（需求 3）。入参逐字对齐上游 comments_cubit.dart:111-117：
   *   fnPath 'postComment'，core {comicId, content}，extern **恒空对象**（整页评论没有上下文要带）。
   * ★ 与读侧不同，这里**不能**静默兜成空值就完事：提交是有副作用的动作，用户必须知道成没成，
   *   所以失败一律把原因写进 CommentPostResult.error 交回页面弹提示。
   * ★ 未实现 postComment 的插件（普查里只有 man-hua-gui 这个 demo 桩实现了它）走
   *   postErrorText 换成人话，不是 bug 路径。
   */
  static async postComment(sourceId: string, comicId: string, content: string): Promise<CommentPostResult> {
    const r: CommentPostResult = new CommentPostResult();
    const ad: PluginSourceAdapter | null = PluginDetail.adapterFor(sourceId);
    if (ad === null) {
      r.error = '该图源不支持发评论';
      return r;
    }
    const a: CommentPostArg = new CommentPostArg();
    a.comicId = comicId;
    a.content = content;
    try {
      const o: ESObject = await ad.callExt('发表评论失败', 'postComment', a);
      const parsed: CommentPostResult = parseCommentMutation(jobj(o, 'data'));
      return parsed;
    } catch (e) {
      r.error = postErrorText((e as Error).message, '发评论');
      return r;
    }
  }

  /**
   * 回复某条评论（需求 3）。入参逐字对齐上游 comments_cubit.dart:119-125：
   *   fnPath 'postCommentReply'，core {comicId, commentId: item.id, content}，
   *   extern = **这条被回复的评论自己的 extern**（上游 :123 原样回传；JM 系拿它当风控上下文，
   *   少带它轻则插件报错、重则发错楼层）⇒ 所以签名收整条 CommentItem 而不是 id，
   *   与 replies() 同一个理由（见上面的注释）。
   * id 为空的条目（插件漏 id）没法回：直接给提示，不打插件。
   */
  static async postCommentReply(sourceId: string, comicId: string, item: CommentItem,
    content: string): Promise<CommentPostResult> {
    const r: CommentPostResult = new CommentPostResult();
    if (item.id.length === 0) {
      r.error = '这条评论缺少标识，无法回复';
      return r;
    }
    const ad: PluginSourceAdapter | null = PluginDetail.adapterFor(sourceId);
    if (ad === null) {
      r.error = '该图源不支持回复评论';
      return r;
    }
    const a: CommentReplyPostArg = new CommentReplyPostArg();
    a.comicId = comicId;
    a.commentId = item.id;
    a.content = content;
    a.extern = item.extern;
    try {
      const o: ESObject = await ad.callExt('回复评论失败', 'postCommentReply', a);
      const parsed: CommentPostResult = parseCommentMutation(jobj(o, 'data'));
      return parsed;
    } catch (e) {
      r.error = postErrorText((e as Error).message, '回复评论');
      return r;
    }
  }

  /** 是否**可能**有评论区（只查是否插件源，真正支持与否要等 comments() 返回）。 */
  static mayHaveComments(sourceId: string): boolean {
    return PluginDetail.adapterFor(sourceId) !== null;
  }
}
