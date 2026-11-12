/**
 * 职责：给 ImageCache 注入「按图源取字节 + 反混淆意图」的通道（依赖倒置：
 *   data/image 不得反向 import data/source，否则 ImageCache→SourceManager→Adapter→ImageCache 成环）。
 * 为什么必须有（真机 BUG 的两半根因）：
 *   ① JM 系图站要 Referer/风控头才给正确图，插件的 fetchImageBytes 会带
 *      （PluginSourceAdapter.fetchImageBytes），而阅读器过去只把 url 交给 ImageCache 走宿主
 *      HttpClient（UA=Breeze-OHOS/1.0、无 Referer）⇒ 部分源拿到错误图。
 *   ② 分块混淆的还原必须在拿到「插件给的那份字节」之后做 ⇒ 两件事同一个通道给。
 * 接线点：data/DataBootstrap.ets 调 PluginImageOps.install()。
 * 约定：这里一律传**图源 id**（如 'plugin:<uuid>'），不是清单 uuid —— 免得在 image 层做前缀运算。
 */

export interface PluginImageChannel {
  /**
   * 取页图字节。
   * 返回 null = 不是插件图源 / 通道未就绪（调用方走宿主 HTTP）；
   * 抛错 = 插件取图失败（调用方回落宿主 HTTP，再失败才报错）。
   */
  fetch(sourceId: string, url: string): Promise<ArrayBuffer | null>;

  /**
   * 反混淆意图（每个 URL 问一次，结果参与缓存键，故必须对同一入参稳定）：
   *   ''       不处理（非插件 / 模式 off / 章节号根本不会分块）
   *   'force'  必须重排（uuid 白名单、isJm=true 或用户手动强开）
   *   'detect' 由内容检测决定（宁花屏不崩 + 自校验回退）
   */
  deobfIntent(sourceId: string, chapterId: string, url: string): Promise<string>;
}

export class BytesChannels {
  private static channel: PluginImageChannel | null = null;

  static register(c: PluginImageChannel): void {
    BytesChannels.channel = c;
  }

  /** 未接线（启动早期）返回 null，调用方必须能处理。 */
  static get(): PluginImageChannel | null {
    return BytesChannels.channel;
  }
}
