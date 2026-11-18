/**
 * 职责：本轮新功能（搜索触底翻页 / 发评论 / 图片画质写入）的**进程内计数**，
 * 汇总成一行给诊断面板 20 号行 featChain（INFO，不计入 verdict）。
 *
 * 为什么要这一行：s32 那一轮「竖向到底不切章」只能靠用户手感和截图判读，
 * 判不出是主路径生效还是保底接手（结论是保底）。这次四个新功能每一项都留一个读数，
 * 回传时能直接区分「没触发 / 触发了但失败 / 成功了」三种情形，不用来回猜。
 *
 * 口径：
 * - 只计数，不存正文（评论内容、图片地址一律不落这里）。
 * - 单例 + 模块级，跨页面共享；进程重启归零（与 ReaderDiag / PluginIconDiag 同款）。
 * - 刻意不自己往诊断面板加行：行号是证据链的引用锚点，加行由 pages/Index.ets 统一做
 *   （同 view/plugins/PluginManagerView.ets:290 那段说明）。
 */
export class FeatureDiag {
  private static inst: FeatureDiag | undefined = undefined;

  /** 搜索：触底发起下一页请求的次数。 */
  spCalls: number = 0;
  /** 搜索：成功追加到结果的下一页次数。 */
  spOk: number = 0;
  /** 搜索：某源下一页失败的次数（可点重试）。 */
  spFail: number = 0;
  /** 搜索：判定「没有更多了」的次数（翻页链正常收尾的证据）。 */
  spEnd: number = 0;
  /** 搜索：换代丢弃（用户改词后旧请求回来）的次数。 */
  spStale: number = 0;
  /**
   * 搜索：触底事件进来了但被首行闸门挡下的次数（正在翻页 / 首屏还没回 / 已判定到底）。
   * ★ s34 补这一枚的直接原因 = 真机 sp=0/0/0/0/0 什么都判不出来：「onReachEnd 没触发」与
   *   「触底了但 moreState 已是 end 被 return」两种情形读数完全一样，而根因是后者
   *   （判到底判错了）。有这一枚才能区分「压根没触底」与「触底了但被认为没内容可取」。
   */
  spBlocked: number = 0;

  /** 评论：提交（发评 + 回复）发起次数。 */
  cmCalls: number = 0;
  /** 评论：插件回成功且已落位/重拉的次数。 */
  cmOk: number = 0;
  /** 评论：失败次数（含插件报错）。 */
  cmFail: number = 0;
  /** 评论：其中「插件未实现该功能」的次数（route not found）。 */
  cmNoRoute: number = 0;
  /** 评论：成功里走整体重拉的次数（其余 = 本地插条目，代价更低）。 */
  cmRefetch: number = 0;

  /** 图片画质：写入次数与最近一次值。 */
  iqWrites: number = 0;
  iqLast: string = '';

  private constructor() {
  }

  static get(): FeatureDiag {
    if (FeatureDiag.inst === undefined) {
      FeatureDiag.inst = new FeatureDiag();
    }
    return FeatureDiag.inst;
  }

  /** 单行摘要（判读口径写在 pages/Index.ets 的 20 号行注释里）。 */
  static hint(): string {
    const d: FeatureDiag = FeatureDiag.get();
    return 'sp=' + d.spCalls + '/' + d.spOk + '/' + d.spFail + '/' + d.spEnd + '/' + d.spStale + '/' + d.spBlocked
      + ' cm=' + d.cmCalls + '/' + d.cmOk + '/' + d.cmFail + '/' + d.cmNoRoute + '/' + d.cmRefetch
      + ' iq=' + d.iqWrites + '/' + d.iqLast;
  }
}
