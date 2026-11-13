/**
 * 职责：pages/WebLoginPage 的路由参数契约（s15 第 8 条引入，s16 第 3 条从页面文件里搬出来）。
 *
 * ★ 为什么这个类不能留在 pages/WebLoginPage.ets 里（真机踩过的根因，别再搬回去）：
 *   本类要被 pages/PluginSettingsPage 反向 import（它 new 一份再 router.pushUrl），而声明它的文件
 *   本身是 @Entry 页面 ⇒ 页面模块被反向引用时拿到的类身份与页面自己加载的那份不是同一枚，
 *   回到页面里 raw instanceof WebLoginParams 判假 ⇒ aboutToAppear 整段赋值被跳过 ⇒ webSrc 空串、
 *   title 停在默认值、detail 空串 = 真机表现为「点了前往网页登录，页面既不报错也不出网页」。
 *   全仓其余五枚路由参数类（data/source/PluginLogin.ets、data/source/PluginSettings.ets、
 *   view/detail/DetailParams.ets、view/reader/ReaderParams.ets、view/search/SearchEntryParams.ets）
 *   全都声明在非页面模块，正是同一条口径。⇒ 参数契约进模块，页面只留 UI 与运行时。
 *
 * 本文件不 import 任何 UI，只依赖 util/JsonUtil 的防御式取值；路由参数只带函数名（setCookieFnPath），
 * 不带任何凭据 —— cookie 值由 WebLoginPage 摘到后经 util/PluginRuntime.bundleCall 直接交给插件 setter。
 */
import { jstr, jnum, jstrArr } from '../../util/JsonUtil';
/**
 * 跳转参数（与 PluginLoginParams / PluginSettingsParams 同口径：pushUrl 传实例，页面侧 instanceof 判型取回）。
 * ★ 所有字段都是「调用方已经调过一次能力动作、从返回里取好的值」—— 本页不再发能力动作（文件头 1）。
 * 路由参数只带函数名（setCookieFnPath），不带任何凭据。
 */
export class WebLoginParams {
  uuid: string = '';
  name: string = '';
  localFile: string = '';
  /** 顶栏标题：优先用动作返回 action.payload.title（如「E-Hentai 论坛登录」）。 */
  setTitle: string = '';
  /** 要加载的登录地址（动作返回 openUrl）。 */
  openUrl: string = '';
  /** 回传目标 fnPath（动作返回 setCookieFnPath，如 setEhentaiForumCookie）。空 = 无法回传。 */
  setCookieFnPath: string = '';
  /** 动作给的轮询间隔（毫秒）。仅当它比兜底节拍更密且不超过整页上限才采纳，见文件头 3。 */
  pollIntervalMs: number = 0;
  /** 就绪必需键：动作返回里若插件给出就用它给的，空则用兜底档 REQUIRED。 */
  requiredNames: string[] = [];
  /** 会话类名单（动作返回 ignoreCookieNames）。 */
  ignoreCookieNames: string[] = [];
  /** 动作给的提示文案（如「请在 WebView 登录后回传 cookie 到 …」），原样显示给用户。 */
  message: string = '';

  constructor(uuid: string, name: string, localFile: string) {
    this.uuid = uuid;
    this.name = name;
    this.localFile = localFile;
  }
}
/**
 * 从 router.getParams() 的返回里取回跳转参数，两种形态都吃：
 *  1) 实例（类身份一致时 pushUrl 传的对象原样回来）⇒ 直接返回，行为与 s15 完全一致；
 *  2) 普通对象（类身份对不上时 instanceof 判假，路由器交回来的只是同形状的数据）⇒ 逐字段按名取。
 * 取不到的一律落回类里的默认值，**不抛**：页面拿到的是一份能用的空参数（openUrl 为空串），
 * 由页面自己按 openUrl 空不空决定说什么话 —— 说「本次没拿到地址」，不能说「插件没有给出」，
 * 后者会把宿主的锅甩给插件（s16 第 3 条要求）。
 */
export function readWebLoginParams(raw: Object): WebLoginParams {
  if (raw instanceof WebLoginParams) {
    return raw as WebLoginParams;
  }
  const out: WebLoginParams = new WebLoginParams('', '', '');
  if (raw === null || raw === undefined) {
    return out;
  }
  const o: ESObject = raw as ESObject;
  out.uuid = jstr(o, 'uuid', '');
  out.name = jstr(o, 'name', '');
  out.localFile = jstr(o, 'localFile', '');
  out.setTitle = jstr(o, 'setTitle', '');
  out.openUrl = jstr(o, 'openUrl', '');
  out.setCookieFnPath = jstr(o, 'setCookieFnPath', '');
  out.pollIntervalMs = jnum(o, 'pollIntervalMs', 0);
  out.requiredNames = jstrArr(o, 'requiredNames');
  out.ignoreCookieNames = jstrArr(o, 'ignoreCookieNames');
  out.message = jstr(o, 'message', '');
  return out;
}
