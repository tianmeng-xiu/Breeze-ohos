/**
 * 职责：应用自身检查更新 —— 更新源 = 本仓库 GitHub Releases，更新日志 = Release 正文里的「本次变化」小节。
 * 用法：pages/AboutPage.ets 的「检查更新」行调 UpdateChecker.check()，产出 UpdateOutcome 交给弹窗。
 *
 * ★★ 版本号是两套编号，这里必须讲清楚，否则判「有没有新版」必错：
 *   - versionName（AppScope/app.json5 = 3.0.37）是**对齐上游 Breeze 的镜像版本号**，全程恒 3.0.37，
 *     不随本仓库发版递增（本仓台账：versionName 恒 3.0.37）。它回答「移植自上游哪一版」。
 *   - Release tag（v1.0.0 … v1.8.0）是**本仓库自己的发版编号**，每发一次 Release 加一。
 *     它回答「我装的是第几次发版」。
 *   ⇒ 拿 versionName 去和 tag 比大小是错的（3.0.37 永远大于 1.x ⇒ 永远显示「已最新」）。
 *     本文件的基准用 SELF_TAG（下面那枚常量），**每次发 Release 必须同步改这一行**（发版清单里已列）。
 *
 * 网络：走 data/net/HttpClient（自带 UA / Cookie / gzip / 超时），主源 api.github.com，
 *       备源 = 同一 URL 套 gh-proxy（本机实测两个都通，主源间歇不通时备源能顶上）。
 * 解析：外部 JSON 一律走 util/JsonUtil 的 jstr/jbool/jarr/jobj/jparse（ESObject 逐字段取值），
 *       不许 cast 成具体 class —— 这是本仓对「外部回包」的统一口径（同 data/source/MangadexSource.ets）。
 * 失败：任何一步失败都收进 UpdateOutcome.error 并写日志，不抛异常打断调用方 UI。
 */
import { Logger } from './Logger';
import { HttpClient, HttpStatusError } from '../data/net/HttpClient';
import { jparse, jstr, jarr, jhas, jnum, jisEmpty } from './JsonUtil';

/** 本仓库发版地址（与 pages/AboutPage.ets 的 REPO_URL 同一地址，这里独立一份避免跨页耦合）。 */
const REPO: string = 'tianmeng-xiu/Breeze-ohos';
/** 主源：GitHub API 的 latest（只返回最新的正式版，不含 pre-release/draft —— 正是我们要的语义）。 */
const API_LATEST: string = 'https://api.github.com/repos/' + REPO + '/releases/latest';
/** 备源：同一 API 套一层公共加速代理（本机实测返回体与主源逐字节相同）。 */
const API_LATEST_MIRROR: string = 'https://v4.gh-proxy.org/https://api.github.com/repos/' + REPO + '/releases/latest';
/**
 * ★ 与「当前装机包所属 Release tag」保持一致的发版基准。每次发 Release 改这一行。
 * 改法：写成 tag 原文（带 v）。写错或忘改的后果 = 已装最新包的用户仍看到「发现新版本」，
 * 不会崩、不会误装，但会被当成 BUG 反馈 —— 所以它在发版清单里是一条硬步骤。
 */
const SELF_TAG: string = 'v1.11.0';

/** 一次检查的产出（所有字段都有默认值，失败路径只填 error）。 */
export class UpdateOutcome {
  /** 请求成功且解析出版本号（不代表有新版）。 */
  ok: boolean = false;
  /** ok 且确认没有更新可装。 */
  upToDate: boolean = false;
  /** ok 且 SELF_TAG 落后于线上最新 tag。 */
  hasUpdate: boolean = false;
  /** 失败原因（已成人话，可直接上 UI）；成功时是空串。 */
  error: string = '';
  /** 线上最新 tag（带 v）。 */
  latestTag: string = '';
  /** 线上该版的发布日（YYYY-MM-DD，取不到给空串）。 */
  publishedAt: string = '';
  /** 更新日志：Release 正文「本次变化」小节的条目，一条一个元素。 */
  changelog: string[] = [];
  /** 更新日志是否来自「本次变化」小节（false = 走了兜底截取，UI 要标出来）。 */
  changelogExact: boolean = false;
  /** 发布页（给用户跳转，也用于「复制链接」）。 */
  pageUrl: string = '';
  /** 该版里最大的那个资产名（正常就是 hap）与体积，用来让用户确认没下错东西。 */
  assetName: string = '';
  assetSize: number = 0;
  /** 实际命中的源（'api' / 'mirror'），排障用，也进诊断行。 */
  via: string = '';
}

export class UpdateChecker {
  /** 最近一次检查的单行摘要（诊断 20 号行用；从未检查过 = 空串）。 */
  private static lastHint: string = '';

  /** 取最近一次检查摘要（诊断面板调）。 */
  static lastHintOf(): string {
    return UpdateChecker.lastHint;
  }

  /**
   * 检查更新。manual = 用户主动点的（true 时失败要弹人话，false 时只写日志）。
   * 主源失败自动换备源再试一次；两个都失败才报 error。
   */
  static async check(): Promise<UpdateOutcome> {
    const out: UpdateOutcome = new UpdateOutcome();
    const first: UpdateOutcome = await UpdateChecker.fetchOne(API_LATEST, 'api');
    if (first.ok) {
      UpdateChecker.remember(first);
      return first;
    }
    Logger.i('[Update] 主源失败，转备源：' + first.error);
    const second: UpdateOutcome = await UpdateChecker.fetchOne(API_LATEST_MIRROR, 'mirror');
    if (second.ok) {
      UpdateChecker.remember(second);
      return second;
    }
    // 两个都挂：报第二个的错（更接近用户当下网络实况），但把主源错也留进日志
    Logger.e('[Update] 主备源均失败 main=' + first.error + ' mirror=' + second.error);
    out.error = second.error.length > 0 ? second.error : first.error;
    UpdateChecker.lastHint = 'via=none err=' + cut20(out.error);
    return out;
  }

  /** 把一次成功结果压成诊断摘要（不带 changelog 正文，只记条数与是否精确命中）。 */
  private static remember(o: UpdateOutcome): void {
    UpdateChecker.lastHint = 'via=' + o.via + ' latest=' + o.latestTag + ' self=' + SELF_TAG
      + (o.hasUpdate ? ' NEW' : (o.upToDate ? ' LATEST' : ''))
      + ' log=' + o.changelog.length + (o.changelogExact ? '(exact)' : '(fallback)')
      + ' asset=' + cut20(o.assetName) + '/' + o.assetSize;
  }

  /** 装机包所属发版号（UI 显示「当前版本」用，与 versionName 分开显示）。 */
  static selfTag(): string {
    return SELF_TAG;
  }

  /** 单源取一次并判定，任何异常都在这里收口成 UpdateOutcome.error。 */
  private static async fetchOne(url: string, via: string): Promise<UpdateOutcome> {
    const out: UpdateOutcome = new UpdateOutcome();
    out.via = via;
    let text: string = '';
    try {
      // 429 是 GitHub 匿名 API 最常见的失败（无 token 每 IP 60 次/小时），单独成人话
      text = await HttpClient.getInstance().getText(url, UpdateChecker.headers());
    } catch (e) {
      const x = e as Error;
      const msg: string = (typeof x.message === 'string' && x.message.length > 0) ? x.message : String(e);
      const st: number = e instanceof HttpStatusError ? (e as HttpStatusError).statusCode : 0;
      out.error = UpdateChecker.friendly(st, msg);
      return out;
    }
    // jparse 不抛异常：空串/非法 JSON/顶层不是对象 ⇒ 返回共享空对象，用 jisEmpty 判
    const root: ESObject = jparse(text);
    if (jisEmpty(root)) {
      out.error = '更新源返回的内容看不懂（不是 JSON）';
      Logger.e('[Update] JSON 解析失败 via=' + via + ' len=' + text.length);
      return out;
    }
    const tag: string = jstr(root, 'tag_name', '');
    if (tag.length === 0) {
      // 代理/网关有时会回一个 200 的 HTML 错误页，jparse 可能仍成功但没有 tag_name
      out.error = '更新源没给出版本号';
      return out;
    }
    out.ok = true;
    out.latestTag = tag;
    out.pageUrl = jstr(root, 'html_url', 'https://github.com/' + REPO + '/releases');
    out.publishedAt = UpdateChecker.dateOnly(jstr(root, 'published_at', ''));
    const body: string = jstr(root, 'body', '');
    const cl: Changelog = UpdateChecker.changelogOf(body);
    out.changelog = cl.lines;
    out.changelogExact = cl.exact;
    UpdateChecker.pickAsset(root, out);
    const cmp: number = compareSemver(UpdateChecker.tagToSemver(SELF_TAG), UpdateChecker.tagToSemver(tag));
    out.upToDate = cmp >= 0;
    out.hasUpdate = cmp < 0;
    Logger.i('[Update] via=' + via + ' latest=' + tag + ' self=' + SELF_TAG + ' cmp=' + cmp +
      ' log=' + out.changelog.length + (out.changelogExact ? '(exact)' : '(fallback)') +
      ' asset=' + out.assetName + '/' + out.assetSize);
    return out;
  }

  private static headers(): Map<string, string> {
    const m: Map<string, string> = new Map();
    // Accept 明确要 JSON：GitHub API 不带这个头时可能回 HTML
    m.set('Accept', 'application/vnd.github+json');
    return m;
  }

  /** 状态码 → 人话。403/429 分开写：前者多为匿名限额，后者是明确限流，处置话术不同。 */
  private static friendly(status: number, msg: string): string {
    if (status === 403) {
      return '更新源拒绝了请求（GitHub 匿名访问限额）';
    }
    if (status === 404) {
      return '更新源上没找到发布记录';
    }
    if (status === 429) {
      return '更新源访问太频繁，稍后再试';
    }
    if (status >= 500) {
      return '更新源暂时不可用（' + status + '）';
    }
    return msg.length > 0 ? msg : '检查更新失败';
  }

  /** 资产里挑体积最大的那枚当主包（hap 远大于 SHA256SUMS.txt，天然胜出）。 */
  private static pickAsset(root: ESObject, out: UpdateOutcome): void {
    if (!jhas(root, 'assets')) {
      return;
    }
    const arr: ESObject[] = jarr(root, 'assets');
    let best: number = -1;
    for (let i = 0; i < arr.length; i++) {
      const size: number = jnum(arr[i], 'size', 0);
      if (size > best) {
        best = size;
        out.assetName = jstr(arr[i], 'name', '');
        out.assetSize = size;
      }
    }
  }

  /** ISO 时间串取日期段（'2026-11-16T15:00:17Z' → '2026-11-16'）。 */
  private static dateOnly(iso: string): string {
    const i: number = iso.indexOf('T');
    return i > 0 ? iso.substring(0, i) : iso;
  }

  /** 'v1.8.0' / '1.8.0' → '1.8.0'（去前缀 v 与前后空白）。 */
  private static tagToSemver(tag: string): string {
    const t: string = tag.trim();
    return t.length > 0 && (t.charAt(0) === 'v' || t.charAt(0) === 'V') ? t.substring(1) : t;
  }

  /**
   * 从 Release 正文里抽「本次变化」小节。
   * 本仓库发版模板固定有 `## 本次变化` 一段（Markdown 无序列表）。找不到这段就兜底：
   * 剥掉表格/代码块/标题行后取前若干行，并标 exact=false（UI 会写「（从发布说明截取）」）。
   */
  private static changelogOf(body: string): Changelog {
    const c: Changelog = new Changelog();
    if (body.length === 0) {
      return c;
    }
    const lines: string[] = body.split('\n');
    let start: number = -1;
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].trim();
      if (isHeading(t)) {
        // 命中「本次变化」这一级标题：进到该段
        if (t.indexOf('本次变化') >= 0 || t.indexOf('Changes') >= 0) {
          start = i + 1;
          break;
        }
      }
    }
    if (start >= 0) {
      for (let i = start; i < lines.length; i++) {
        const t: string = lines[i].trim();
        if (isHeading(t)) {
          break; // 下一个标题 = 本段结束
        }
        const item: string = stripBullet(t);
        if (item.length > 0) {
          c.lines.push(item);
        }
      }
      if (c.lines.length > 0) {
        c.exact = true;
        return c;
      }
    }
    // ---- 兜底：整篇正文剥掉结构行，取前 6 行非空文本 ----
    for (let i = 0; i < lines.length && c.lines.length < 6; i++) {
      const t: string = lines[i].trim();
      if (t.length === 0 || t.substring(0, 1) === '#' || t.substring(0, 1) === '|' ||
        t.substring(0, 1) === '`' || t.substring(0, 3) === '---') {
        continue;
      }
      c.lines.push(stripBullet(t));
    }
    return c;
  }
}

/**
 * Markdown 标题行判定：行首 1~6 个井号 + 至少一个空白。
 * 写成函数而不是内联正则 = 本文件有两处用到，且避开在正则里写斜杠（见 stripBullet 的说明）。
 */
function isHeading(t: string): boolean {
  if (t.length < 2 || t.substring(0, 1) !== '#') {
    return false;
  }
  let n: number = 0;
  while (n < t.length && t.substring(n, n + 1) === '#') {
    n++;
  }
  if (n > 6) {
    return false;
  }
  return t.substring(n, n + 1) === ' ' || t.substring(n, n + 1) === '\t';
}

/** 诊断摘要用的短截断（防止长错误串把 20 号行挤掉后段）。 */
function cut20(s: string): string {
  return s.length > 28 ? s.substring(0, 28) : s;
}

/** changelogOf 的中间产物。 */
class Changelog {
  lines: string[] = [];
  exact: boolean = false;
}

/** 去掉 Markdown 列表符号与行内反引号/粗体星号，让条目在 Text 里干净显示。 */
function stripBullet(t: string): string {
  let s: string = t;
  if (s.indexOf('- ') === 0 || s.indexOf('* ') === 0) {
    s = s.substring(2);
  }
  // 有序列表 '1. xxx'：切掉首个「数字 + 点 + 空白」之前的部分
  if (/^\d+\./.test(s)) {
    const dot: number = s.indexOf('.');
    const rest: string = s.substring(dot + 1);
    if (rest.substring(0, 1) === ' ' || rest.substring(0, 1) === '\t') {
      s = rest.trim();
    }
  }
  // 反引号与粗体星号用 split/join 去掉，不用正则字面量：
  // 「星号紧跟斜杠」这两个字符连在一起就是块注释的收尾符，写进正则字面量里会让本仓那条
  // 朴素的块注释配平自检（数 /* 与 */ 的个数）打脏 —— s33 真踩到，报成 30/31 假不平。
  // 连这条注释本身都不能把那两个字符连写，所以这里用文字描述。
  s = s.split('`').join('');
  s = s.split('**').join('');
  return s.trim();
}

/**
 * 点分数字版本比较：a>b 返 1，a<b 返 -1，等返 0。
 * 非数字段按 0 处理（'1.8.0-beta' 的第三段是 '0-beta' ⇒ 取前导数字 0），缺的段按 0 补齐。
 */
export function compareSemver(a: string, b: string): number {
  const pa: string[] = a.split('.');
  const pb: string[] = b.split('.');
  const n: number = pa.length > pb.length ? pa.length : pb.length;
  for (let i = 0; i < n; i++) {
    const va: number = leadingInt(i < pa.length ? pa[i] : '0');
    const vb: number = leadingInt(i < pb.length ? pb[i] : '0');
    if (va > vb) {
      return 1;
    }
    if (va < vb) {
      return -1;
    }
  }
  return 0;
}

/** 取字符串前导整数（'20'→20、'0-beta'→0、''→0）。 */
function leadingInt(s: string): number {
  const t: string = s.trim();
  let n: number = 0;
  while (n < t.length) {
    const c: string = t.substring(n, n + 1);
    if (c < '0' || c > '9') {
      break;
    }
    n++;
  }
  if (n === 0) {
    return 0;
  }
  const v: number = Number.parseInt(t.substring(0, n), 10);
  return Number.isNaN(v) ? 0 : v;
}
