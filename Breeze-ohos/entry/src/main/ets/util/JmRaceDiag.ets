/**
 * 职责：s49 取证探针（**纯观测，零行为影响**）。两症状各留一条可判读的证据链：
 *  症状① 排行榜首次点击必失败：PluginInit.mark 是 fire-and-forget，首个 getRankingData
 *        可能落在插件 init 的端点池冷建窗口内 ⇒ 这里记「第一次失败时的 init 态与距 init
 *        完成的毫秒」，配合 pfOk（重试即好）判冷窗口竞态是否成立。
 *  症状② 章节空页表：宿主在 getChapter 回空页表时抛「章节页表为空」。诱因两个候选：
 *        B1 章节 id 被插件伪造成 albumId（特征 = 章节只有 1 枚且 chapterId === comicId）；
 *        B2 登录态未生效（特征 = 事件发生时 init 还没跑完，或距 init 完成已超 30 min TTL）。
 *  s49 只取证不修；s50 起 B2 那条已有自愈通路（空页表 → 补跑 init → 重试一次），
 *  本类新增 kick= / kickOk= 两枚计数用来判「自愈试过」与「自愈真的有效」。
 * 设计口径（与派工书 §2.1 一致）：
 *  - 计数与取证只写在这里，行号拼装统一由 pages/Index.ets 的 24 号行做（行号是证据链锚点）。
 *  - 两个快照都是**只记第一次**（后续调用只涨计数）：要判的是「第一次为什么失败」，
 *    后面重复的那次没有新信息。章节列表那枚是覆盖式「最近一次」，因为它便宜、
 *    且失败前那一次正是我们要看的。
 *  - imgState 与 sig 都在本类内部算（imgStateOf / sigOf），适配器只递原始对象与原始文本 ——
 *    字符串逻辑不往取数链路里堆。imgState 只认 images 这一个键名：JM 0.1.1 的 getChapter
 *    只读 d.images（bundle @95451），而它回给宿主的包装对象里根本没有 images
 *    （只有 data.chapter.pages）⇒ 真机若恒 img=0 本身就是证据：插件读的那一层宿主看不见。
 *    **别**把 img=0 直接当成「响应里没有图片」的结论。
 *  - 输出红线：只输出键名、计数、标记名、消毒后的错误片段。**绝不**输出凭据、URL 查询串、
 *    响应正文、账号名。
 * 依据系统 Kit：无（纯 ArkTS，不 import 任何 Kit 与业务模块）。
 */

/** 键名数组的显示上限：最多 8 枚、单枚最多 18 字符（cap 预算见派工书 §4）。 */
const KEY_MAX: number = 8;
const KEY_LEN: number = 18;

/** 标记词表：只显示命中了哪几个名字，**永不**输出正文。比较前把文本转小写。 */
const SIG_NAMES: string[] = ['login', '18', 'auth', 'err', 'nodata'];
const SIG_HITS: string[][] = [
  ['登入', '登录', 'login'],
  ['18', '成人', '驗證', '验证'],
  ['401', ' unauthorized ', '驗證碼'],
  ['error', '失败', '異常', '异常'],
  ['无数据', 'no data']
];

/** err= 一段的消毒长度（含凭据字样则整段替换，不给片段）。 */
const ERR_MAX: number = 110;

/** 章节名快照的显示长度。 */
const NAME_MAX: number = 24;

/** 找 images 的闸门：深度 ≤ 4、访问节点 ≤ 64（探针不得在大响应上变成开销）。 */
const SCAN_DEPTH: number = 4;
const SCAN_NODES: number = 64;

function hasHit(text: string, words: string[]): boolean {
  for (let i = 0; i < words.length; i++) {
    if (text.indexOf(words[i]) >= 0) {
      return true;
    }
  }
  return false;
}

/** 可下探的子节点判定：对象且非数组（数组不下探 —— 页数组可能很大，探针不吃这个开销）。 */
function isPlainNode(v: ESObject): boolean {
  return v !== null && v !== undefined && typeof v === 'object' && !Array.isArray(v);
}

/**
 * 显式栈遍历找 images 键（不用递归、不吃调用深度）。返回：
 * 0 = 整个响应里没有 images 键 / 1 = 有但不是数组 / 2 = 是数组且长度 0 / 3 = 是数组且非空。
 * 3 理论上走不到调用点（宿主看的是 pages 不是 images），留作反向对照。
 */
function scanImagesState(root: ESObject): number {
  const stack: ESObject[] = [root];
  const depths: number[] = [0];
  let budget: number = SCAN_NODES;
  while (stack.length > 0 && budget > 0) {
    const cur: ESObject = stack.pop() as ESObject;
    const d: number = depths.pop() as number;
    budget -= 1;
    const keys: string[] = Object.keys(cur);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i] !== 'images') {
        continue;
      }
      const hit: ESObject = cur[keys[i]];
      if (!Array.isArray(hit)) {
        return 1;
      }
      return (hit as ESObject[]).length === 0 ? 2 : 3;
    }
    if (d >= SCAN_DEPTH) {
      continue;
    }
    for (let i = 0; i < keys.length; i++) {
      const v: ESObject = cur[keys[i]];
      if (!isPlainNode(v)) {
        continue;
      }
      stack.push(v as ESObject);
      depths.push(d + 1);
    }
  }
  return 0;
}

/** 键名数组裁形（最多 KEY_MAX 枚、单枚 KEY_LEN 字符），空数组给一个短横。 */
function keyText(keys: string[]): string {
  if (keys.length === 0) {
    return '-';
  }
  const n: number = keys.length < KEY_MAX ? keys.length : KEY_MAX;
  let s: string = '';
  for (let i = 0; i < n; i++) {
    if (i > 0) {
      s += ',';
    }
    const k: string = keys[i];
    s += k.length > KEY_LEN ? k.slice(0, KEY_LEN) : k;
  }
  return s;
}

/** 错误文案消毒：先砍查询串，再截 ERR_MAX；带凭据字样就整段替换。 */
function sanitizeErr(raw: string): string {
  if (raw.length === 0) {
    return '-';
  }
  let s: string = raw.replace(/\?.*$/, '?');
  if (s.indexOf('Bearer') >= 0 || s.indexOf('token') >= 0) {
    return '<redacted>';
  }
  if (s.length > ERR_MAX) {
    s = s.slice(0, ERR_MAX);
  }
  return s;
}

/** 插件 uuid 只显示前 13 位（够区分 21 枚载荷，且不把整串 uuid 塞进面板）。 */
function shortUuid(uuid: string): string {
  return uuid.length > 13 ? uuid.slice(0, 13) : uuid;
}

/**
 * 24 号行 jmRace 的读数仓库（全静态，与 util/PluginInit.ets 同风格、无 struct）。
 * 所有计数是**本进程累计**、重启归零；除 ch 段外快照都是「只记第一次」。
 */
export class JmRaceDiag {
  // ---- 章节空页表（症状②）
  private static pcN: number = 0;
  private static pcOk: number = 0;
  private static pcPages: number = 0;
  private static pcHit: boolean = false;
  private static pcMs: number = 0;
  private static pcInit: string = '-';
  private static pcAge: number = -1;
  private static pcCid: string = '-';
  private static pcMid: string = '-';
  private static pcSame: number = 0;
  private static pcFake: number = 0;
  private static pcImg: number = -1;
  private static pcTop: string = '-';
  private static pcChap: string = '-';
  private static pcSig: string = 'none';
  // ---- 章节列表最近一次（覆盖式；-1 = 本进程还没取过章节列表）
  private static chEps: number = -1;
  private static chId: string = '-';
  private static chName: string = '-';
  private static chSrc: string = '-';
  // ---- s50 修②的自愈计数（补跑 init）：kick = 触发自愈的次数；kickOk = 自愈之后那次真读成的次数。
  // 两数联立才分得清「试了但没用」（kick>0 ∧ kickOk=0）与「自愈有效」（kickOk>0）。
  private static kick: number = 0;
  private static kickOk: number = 0;
  // ---- 排行榜取数（症状①）
  private static pfN: number = 0;
  private static pfOk: number = 0;
  private static pfOkMs: number = -1;
  private static pfHit: boolean = false;
  private static pfMs: number = 0;
  private static pfInit: string = '-';
  private static pfAge: number = -1;
  private static pfErr: string = '-';

  /** imgState 出口（口径见 scanImagesState）：非对象一律 0。 */
  static imgStateOf(o: ESObject): number {
    if (!isPlainNode(o)) {
      return 0;
    }
    return scanImagesState(o);
  }

  /** 标记词只在原始文本上探，**只回标记名**（+ 连接），全不命中回 none。 */
  static sigOf(rawText: string): string {
    if (rawText.length === 0) {
      return 'none';
    }
    const low: string = rawText.toLowerCase();
    let s: string = '';
    for (let i = 0; i < SIG_NAMES.length; i++) {
      if (!hasHit(low, SIG_HITS[i])) {
        continue;
      }
      s += s.length === 0 ? SIG_NAMES[i] : ('+' + SIG_NAMES[i]);
    }
    return s.length === 0 ? 'none' : s;
  }

  /**
   * 页表为空的取证入口（适配器在两处 throw 之前各调一次）。
   * imgState / sig 由调用方用本类的 imgStateOf / sigOf 现算后递进来 —— 计算在本类里，
   * 适配器只负责递原始对象、原始文本与两组键名。
   */
  static noteChapterEmpty(ms: number, initState: string, initAgeMs: number, chapterId: string,
    comicId: string, keysTop: string[], keysChapter: string[], imgState: number, sig: string): void {
    JmRaceDiag.pcN += 1;
    if (JmRaceDiag.pcHit) {
      return;
    }
    JmRaceDiag.pcHit = true;
    JmRaceDiag.pcMs = ms;
    JmRaceDiag.pcInit = initState;
    JmRaceDiag.pcAge = initAgeMs;
    JmRaceDiag.pcCid = chapterId;
    JmRaceDiag.pcMid = comicId;
    JmRaceDiag.pcSame = chapterId === comicId ? 1 : 0;
    // fake = 「章节只有 1 枚」且「章节 id 等于作品 id」= B1 的加强判据。
    JmRaceDiag.pcFake = (JmRaceDiag.pcSame === 1 && JmRaceDiag.chEps === 1) ? 1 : 0;
    JmRaceDiag.pcImg = imgState;
    JmRaceDiag.pcTop = keyText(keysTop);
    JmRaceDiag.pcChap = keyText(keysChapter);
    JmRaceDiag.pcSig = sig;
  }

  /** 页表成功次数与页数（证明「后来成功了」，与 pcN 联立才不把一次抖动读成坏源）。 */
  static noteChapterOk(n: number): void {
    JmRaceDiag.pcOk += 1;
    JmRaceDiag.pcPages = n;
  }

  /** s50 修②：触发一次「补跑 init 再重试」（两处空页表分支各调一次，每轮 fetchPages 至多一次）。 */
  static noteChapterKick(): void {
    JmRaceDiag.kick += 1;
  }

  /** s50 修②：补跑 init 之后那一次重试读成了 ⇒ 自愈有效（与 kick 联立判「试了但没用」）。 */
  static noteChapterKickOk(): void {
    JmRaceDiag.kickOk += 1;
  }

  /** 章节列表最近一次（覆盖式）。name 截 24 字符，绝不记 URL、绝不记凭据。 */
  static noteChapters(uuid: string, mangaId: string, epsCount: number, firstId: string, firstName: string): void {
    JmRaceDiag.chSrc = shortUuid(uuid);
    JmRaceDiag.chEps = epsCount;
    JmRaceDiag.chId = firstId.length > 0 ? firstId : (mangaId.length > 0 ? mangaId : '-');
    JmRaceDiag.chName = firstName.length > NAME_MAX ? firstName.slice(0, NAME_MAX) : firstName;
  }

  /** 排行榜取数失败：只记第一次快照，后续调用只 pfN += 1。 */
  static notePopular(ms: number, initState: string, initAgeMs: number, err: string): void {
    JmRaceDiag.pfN += 1;
    if (JmRaceDiag.pfHit) {
      return;
    }
    JmRaceDiag.pfHit = true;
    JmRaceDiag.pfMs = ms;
    JmRaceDiag.pfInit = initState;
    JmRaceDiag.pfAge = initAgeMs;
    JmRaceDiag.pfErr = sanitizeErr(err);
  }

  /** 排行榜取数成功次数（配合 pfN 证「点一次重试即恢复」），首次成功留 pfOkMs。 */
  static notePopularOk(ms: number): void {
    JmRaceDiag.pfOk += 1;
    if (JmRaceDiag.pfOkMs < 0) {
      JmRaceDiag.pfOkMs = ms;
    }
  }

  /** 判读用的一句（自截 700 字符，照 PluginInit.hint 尾部的写法）。 */
  static hint(): string {
    let s: string = 'pcN=' + JmRaceDiag.pcN + ' pcOk=' + JmRaceDiag.pcOk + ' pcPages=' + JmRaceDiag.pcPages;
    if (JmRaceDiag.pcHit) {
      s += ' | pc: cid=' + JmRaceDiag.pcCid + ' mid=' + JmRaceDiag.pcMid
        + ' same=' + JmRaceDiag.pcSame + ' eps=' + JmRaceDiag.chEps + ' fake=' + JmRaceDiag.pcFake
        + ' img=' + JmRaceDiag.pcImg + ' top=' + JmRaceDiag.pcTop + ' chap=' + JmRaceDiag.pcChap
        + ' sig=' + JmRaceDiag.pcSig + ' init=' + JmRaceDiag.pcInit + ' age=' + JmRaceDiag.pcAge
        + ' t=' + JmRaceDiag.pcMs + 'ms';
    }
    // s50 修②的自愈读数（总是带上，0/0 = 本进程从没触发过自愈 = 空页表没再出现过）。
    s += ' | kick=' + JmRaceDiag.kick + ' kickOk=' + JmRaceDiag.kickOk;
    s += ' | pfN=' + JmRaceDiag.pfN + ' pfOk=' + JmRaceDiag.pfOk;
    if (JmRaceDiag.pfOkMs >= 0) {
      s += ' pfOkMs=' + JmRaceDiag.pfOkMs;
    }
    if (JmRaceDiag.pfHit) {
      s += ' | pf: init=' + JmRaceDiag.pfInit + ' age=' + JmRaceDiag.pfAge
        + ' t=' + JmRaceDiag.pfMs + 'ms err=' + JmRaceDiag.pfErr;
    }
    if (JmRaceDiag.chEps >= 0) {
      s += ' | ch: src=' + JmRaceDiag.chSrc + ' eps=' + JmRaceDiag.chEps + ' id=' + JmRaceDiag.chId
        + ' name=' + JmRaceDiag.chName;
    }
    // 判读口径（真机只看得见这一行，所以把口径写全）：
    //   pc 段 same=1 且 fake=1 ⇒ 章节 id 被插件伪造成 albumId（B1）；
    //   init=none 或 init=run ⇒ 事件早于任何一次成功登录（B2）；
    //   age 大于 1800000 ⇒ 距 init 完成已超 30 min TTL（端点池与 jwt 都可能已失效）；
    //   img=0 无 images 键、1 有但不是数组、2 空数组、3 非空数组（3 属反向对照）；
    //   pf 段 init=run 或 age=-1 ⇒ 首次排行榜落在 init 冷窗口内；pfOk 大于 0 ⇒ 重试即好；
    //   多图源共用这一枚探针 ⇒ ch 段的 src= 是发起那次章节列表的插件 uuid 前缀；
    //   s50 起 kick= 是「空页表后补跑 init」的触发次数、kickOk= 是补跑后那次真读成的次数
    //   （kick>0 而 kickOk=0 = 自愈试过但没用，得回头看 pc 段的 init/age/sig 找别的原因）。
    if (s.length > 700) {
      return s.slice(0, 699) + '…';
    }
    return s;
  }
}
