/**
 * 职责：单个插件的「设置 / 能力」页（需求①，用户 m05426 + 上游截图那一屏）。
 * 版式对齐上游 Breeze/lib/page/plugin_settings/widgets/plugin_settings_content.dart：
 *   用户信息 / 登录提示 → 插件自定设置分组 → 能力动作 → **宿主管理区沉底**
 *   （版本 / 更新 / 删除插件 —— 上游还有「调试模式 + 调试地址」，我方无插件热调试通道，不做）。
 *
 * 入口：pages/PluginSettingsPage（由 view/plugins/PluginManagerView 每行「设置」齿轮 pushUrl 进来，
 *       参数 = data/source/PluginSettings.ets 里导出的 PluginSettingsParams）。
 *
 * 依赖：data/source/PluginSettings（读写全部走它，本页不含业务分支）、
 *      view/plugins 的删除/更新口径（本页自带一份最小实现，避免去 import 那个 900 行的 View）、
 *      view/common 目录（顶栏、主题、状态视图）。
 *
 * ⚠ 三条硬约束（写在这里防止后来人改错）：
 * 1) 值一律字符串：开关写 'true'/'false'（真机 MangaDex 用 String(v) 比对，写 boolean 会看着没生效）。
 * 2) choice 用 TextPickerDialog（本 SDK 无 promptAction.showTextInput，实测零命中）；
 *    text/password 用页内自绘浮层输入（AlertDialog/showDialog 都不带输入框）。
 * 3) 删除插件必须先 bundleUnload 再删文件（否则删掉的是文件、内存里还能调用，下次启动才消失）。
 *
 * s17 第 2 条（用户原话「eh 插件网页登录后未显示账户，账号登录选项仍可以点进去」）：
 *      登录卡那一行加「已登录」回显。判据只有一条 = 插件登录方案里**已保存的凭据条数**
 *      （probeLoginState 的注释里写了为什么只有这一条可靠，以及为什么不能用 getSettingsBundle 的 values）。
 *      硬口径：屏上只写形态（「已登录」「已保存 N 项登录凭据」），**绝不回显账号名 / 口令 / cookie 值**，
 *      连字段键名都不上屏（键名是插件内部协议）。入口永不禁用：已登录也要能点进去换账号。 */
import { PromptAction, promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { LoadingView, ErrorView } from '../view/common/StateViews';
import {
  PluginSettings,
  PluginSettingsBundle,
  PluginSettingsParams,
  PluginInfo,
  SettingField,
  SettingSection,
  CapabilityAction,
  LogoutResult,
  LOGOUT_FN
} from '../data/source/PluginSettings';
import {
  PluginLogin,
  PluginLoginParams,
  LoginScheme,
  LoginField,
  LoginResult
} from '../data/source/PluginLogin';
import { WebLoginParams } from '../data/source/WebLogin';
import { PluginStore, PluginRecord } from '../util/PluginStore';
import { PluginSourceRegistry } from '../data/source/PluginSourceRegistry';
import { PluginImageOps } from '../data/source/PluginImageOps';
import { FeatureDiag } from '../util/FeatureDiag';
import { PLUGIN_SOURCE_PREFIX } from '../data/source/PluginSourceAdapter';
import { JmMode } from '../data/image/JmDeobfuscate';
import { bundleCall, bundleUnload, pluginRemoveFile } from '../util/PluginRuntime';
import { jstr, jbool, jnum, jparse, jobj, jhas, jisEmpty, jstrArr } from '../util/JsonUtil';
import { cleanDisplayValue, normalizeDisplayKey } from '../util/DisplayValue';
import { Logger } from '../util/Logger';
// s37 需求 2（用户 m00774）：本页原本是全仓**唯一**能把插件运行时的 `[stack-hook]` 原文
// 整段铺满屏的路径（红队 verify_errtext 第 1 条必修）—— loadErr 由 data/source/PluginSettings.ets:333/:338
// 直接拼出原文，赋给 loadError → ErrorView.msg → StateViews.ets:72 Text（无 maxLines、不截断）。
// 这里按「先 errLog 留全文、再 errBriefForScreen 洗上屏」的三行式接线；只改 page 侧，
// 不动 data/source/PluginSettings.ets 的返回值（那个文件不在本批写域，改了会波及别的调用方）。
import { errBriefForScreen, errLog, errTextOf } from '../util/ErrText';

/**
 * 「跑完这条 action 就跳登录页」的判定名（struct 内不能用 static，故模块级）。
 * 值本身引数据层的唯一权威常量 LOGOUT_FN（data/source/PluginSettings.ets:62），不再各写字面量 ——
 * 要求6 之后同一个 fnPath 有三个消费方：能力组的跳转判定、卡片上的登出行、数据层 PluginSettings.logout。
 */
const RELOGIN_FN: string = LOGOUT_FN;

/** 宿主管理载荷名（与 PluginManagerView:108 的 MGR_NAME 逐字一致，更新要复用它）。 */
const MGR_NAME: string = 'pluginMgr';
/**
 * s15 第 8 条：本页直连引擎调动作时的入参串，与 data/source/PluginSettings.ets:48 的 ARGS_EMPTY 同串
 * （那边未导出）。契约见 §24：插件永远收到恰好一个对象参数且必带 extern 键。
 */
const ACTION_ARGS: string = '[{"extern":{}}]';
/**
 * s33 需求 4：宿主兜底「图片画质」用的配置键。**只认这一条键名**，理由是它有双重出处：
 *  ① 上游 Breeze 的老设置迁移补丁表把它写成插件配置桶的规范键 =
 *    Breeze/lib/object_box/migration/migration_v1_to_v2.dart:129 `'image.quality': bika.imageQuality`；
 *  ② 本仓既往排查台账同结论（该台账不随本仓库发布，此处只复述结论本身）：bika 的实际取图域名
 *    由插件函数 w(fileServer,path,type) 自行改写，排查前必须先问 image.quality 与 network.proxy 两个设置值。
 * 本机逐枚翻过 11 份插件载荷（_tmp/s2/bundles 9 枚 + s16 ehentai + s10 三枚同名副本），
 * 只有哔咔一枚真的读它（bundle 偏移 1502：`await y("image.quality","original")` 决定走
 * img.picacomic.com / s3.picacomic.com / storage.diwodiwo.xyz / storage-b.diwwo.xyz 哪条图床），
 * 其余插件连这个字符串都不出现 ⇒ 所以本行是**按桶里有没有这个键**决定显示，不给所有插件硬塞一行。
 */
const IMAGE_QUALITY_KEY: string = 'image.quality';
/** 上游该键的默认值（Breeze/lib/config/bika/bika_setting.dart:16 @Default('original')）。 */
const IMAGE_QUALITY_DEFAULT: string = 'original';
/**
 * 兜底档位表（两列一一对应）。★ 诚实口径：除 original 外**没有任何一处权威来源给出过合法档位值**
 * （上游只有 @Default('original')，插件 bundle 里没有档位枚举，公开资料也只出现 image-quality: original），
 * 所以这里给的是「按插件内部语义拟定的常见档」+ 一项自由输入，UI 文案里也不承诺其余档位一定被认。
 * 真正生效的判据在插件自己：bika 只做 `值 !== "original"` 的二选一判断（偏移 1502），
 * 也就是说除 original 外的任何非空串都落到「压缩图床」那一侧，档位之间不再有差别。
 */
const QUALITY_VALUES: string[] = [IMAGE_QUALITY_DEFAULT, 'medium', 'low'];
const QUALITY_LABELS: string[] = ['原图（默认，走原图床）', '中等（压缩图床）', '较低（压缩图床，更省流量）'];
/** 自定义输入那一档在菜单里的序号（QUALITY_* 之后的一项）。 */
const QUALITY_CUSTOM_INDEX: number = 3;
/**
 * 上游该键的显示名。i18n 里查不到（上游 UI 标签不来自 strings，`Breeze/lib/i18n` 内无
 * imageQuality 相关 key）⇒ 标签按插件内部语义自拟，并在注释里留这条依据。
 */
const IMAGE_QUALITY_LABEL: string = '图片画质';
/**
 * s15 第 8 条：rawAction 的内部结果（页面私有；数据层的 RawResult/ActionResult 未导出）。
 * ok = 调用有没有跑通（不含业务成败）；root = 原始返回，交 tryOpenWeb 解析；msg = 可直接 toast 的文案。
 */
class RawActionResult {
  ok: boolean = false;
  root: ESObject = JSON.parse('{}');
  msg: string = '';
}
/**
 * s15 第 8 条：先从 box 取某键、拿不到再从 root 取（插件普遍把结果嵌在 data 之下
 * = {source, data:{...}}，少数直接平铺 ⇒ 两种形态都认，谁先给出非空串用谁）。
 */
function pickStr(box: ESObject, root: ESObject, k: string): string {
  const a: string = jstr(box, k, '');
  if (a.length > 0) {
    return a;
  }
  return jstr(root, k, '');
}

/**
 * 疑似凭据的键名名单（小写整段比对，见 isCredentialKey）。
 * 背景（真机实证，_tmp/s2/bundles 里的发行包）：插件普遍把登录凭据当**普通 settings 字段**自报 ——
 *   JmComic  scheme.sections = [{id:'account',fields:[{key:'auth.account',kind:'text',label:'用户名'},
 *                                                    {key:'auth.password',kind:'password',label:'密码'}]}]
 *   bikaComic 另有一组 {key:'account.password',kind:'password',label:'更新密码',fnPath:'updatePassword'}
 *   zaiManHuan 同类（用户名/密码两项都带 fnPath）
 * 宿主照普通项渲染 = 把已登录的凭据摊在设置页上（BUG3-b 要清掉的就是它）。
 * 两档口径：
 *  · STRONG：命中即视为凭据，不给任何豁免（'accountToken' 这种也得藏）。
 *  · WEAK（'auth'）：单独出现算凭据；与 IDENT（账号类标识）同现时不算 ——
 *    否则 'auth.account'（用户名）会被误杀，而它正是登录成功后该展示的东西。
 * 整段比对而不是 includes ⇒ 'authorMode'（段 author）这类正常设置不会被误伤。
 */
const CREDENTIAL_STRONG: string[] = ['pass', 'passwd', 'password', 'pwd', 'token', 'cookie',
  'secret', 'session', 'sessionid', 'sid', 'authorization', 'credential'];
const CREDENTIAL_WEAK: string[] = ['auth'];
const IDENTIFIER_SEGMENTS: string[] = ['account', 'username', 'user', 'userid', 'uid', 'email',
  'mail', 'login', 'name', 'nickname'];

/**
 * 要求5（2026-11-12）：用户名的候选键，**按归一化形态**写、按优先级排。
 * 归一 = normalizeDisplayKey（小写 + 去掉点横线下划线空格冒号），所以 'userName' / 'user_name' /
 * 'USER.NAME' / 'auth.account' 都能命中（后者归一成 authaccount，靠后缀匹配）。
 * 各家插件字段名不统一，真机实证：JmComic 用户信息回包用 account/email，bikaComic 用 userName，
 * 另有插件用 nick / displayName —— 所以是「名单 + 后缀匹配」，不是精确等值。
 * 顺序即优先级：'name' 排最后，否则它会把 username/nickname 一并后缀吃掉。
 */
const USERNAME_KEY_SUFFIXES: string[] = ['username', 'userid', 'nickname', 'nick', 'displayname',
  'loginname', 'account', 'email', 'user', 'name'];

/** 把 key 按 . - _ 空格冒号 与驼峰边界拆段（全小写返回）。 */
function keySegments(key: string): string[] {
  const parts: string[] = [];
  let cur: string = '';
  for (let i = 0; i < key.length; i++) {
    const c: string = key.charAt(i);
    if (c === '.' || c === '-' || c === '_' || c === ' ' || c === ':') {
      if (cur.length > 0) {
        parts.push(cur);
        cur = '';
      }
      continue;
    }
    // 驼峰边界：当前是大写且前一个不是大写 ⇒ 断开（userName ⇒ user + name）
    if (cur.length > 0 && c >= 'A' && c <= 'Z') {
      const prev: string = cur.charAt(cur.length - 1);
      if (prev < 'A' || prev > 'Z') {
        parts.push(cur);
        cur = '';
      }
    }
    cur += c;
  }
  if (cur.length > 0) {
    parts.push(cur);
  }
  return parts;
}

/** 键名是否指向凭据（见上面两档口径）。 */
function isCredentialKey(key: string): boolean {
  const parts: string[] = keySegments(key);
  let hasIdent: boolean = false;
  let hasWeak: boolean = false;
  for (let i = 0; i < parts.length; i++) {
    const seg: string = parts[i].toLowerCase();
    for (let j = 0; j < CREDENTIAL_STRONG.length; j++) {
      if (seg === CREDENTIAL_STRONG[j]) {
        return true;
      }
    }
    for (let j = 0; j < CREDENTIAL_WEAK.length; j++) {
      if (seg === CREDENTIAL_WEAK[j]) {
        hasWeak = true;
      }
    }
    for (let j = 0; j < IDENTIFIER_SEGMENTS.length; j++) {
      if (seg === IDENTIFIER_SEGMENTS[j]) {
        hasIdent = true;
      }
    }
  }
  return hasWeak && !hasIdent;
}

/**
 * 归一后的键是否「像用户名键」：命中候选名单里的任一条后缀。
 * 两处用到 —— ① 卡片取用户名；② 要求5 的「与下方账号重复只留一行」判该设置项是不是账号项。
 * 后缀匹配会有极窄的误判面（'theaccount' 这种也算命中）；误判的后果只是少显示一行重复值，
 * 不会丢数据，故不为此再加分段解析。
 */
function looksLikeUsernameKey(normKey: string): boolean {
  for (let i = 0; i < USERNAME_KEY_SUFFIXES.length; i++) {
    if (normKey.length >= USERNAME_KEY_SUFFIXES[i].length &&
      normKey.endsWith(USERNAME_KEY_SUFFIXES[i])) {
      return true;
    }
  }
  return false;
}

/**
 * 「版本」这一行（BUG4）。**必须是独立 @Component + @Prop，不能走 ManageRow @Builder**：
 * @Builder 的形参是按值传递的快照，父组件的 @State pluginVersion 后续刷新时它不会重渲染
 * —— 于是即便 getInfo 成功回来了，行上仍定格在首次 build 的「未知」（DetailPage.ets:93 的
 * ActionBtn、SettingPage 的缓存行是同一个原因，cache-fix 那边用传取值函数治的）。@Prop 才随状态刷新。
 * 版式 = 只读信息行：不带箭头、不可点（原 ManageRow 的箭头对「版本」这种只读项本来就是误导）。
 */
@Component
struct PluginVersionRow {
  @StorageProp('isDark') isDark: boolean = false;
  /** 副标题：'当前版本 x.y.z' 或 '当前版本 未知'（字段名避开 sub/line 这类可能与组件属性重名的短词） */
  @Prop subText: string = '';

  build() {
    Row() {
      Column() {
        Text('版本')
          .fontSize(15)
          .fontColor(Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.subText.length > 0) {
          Text(this.subText)
            .fontSize(12)
            .fontColor(Theme.text3(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .constraintSize({ minHeight: Dim.menuItemH })
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }
}

/**
 * 「用户信息」这一行（BUG3-b 起，要求5/要求6 于 2026-11-12 改版）。与 PluginVersionRow 同因同治：
 * @Builder 形参按值传递 ⇒ 只有外层 if 条件真的翻转时才重建（空↔非空），
 * 键集不变、只换值（例：登录后昵称变了）时文案会定格在旧值；@Prop 才随父状态刷新。
 * 版式沿用本页原来的只读信息行 InfoRow（不带箭头、不可点）。
 *
 * 要求5：主行只剩「已登录 · 用户名」一句，**不再逐行铺 userInfo 的原始 metadata**
 *（原 subText 副行 = vip/message/email 那一行随之下线，见 userCardLine 注释）。
 * 要求6：插件自报了登出动作（LOGOUT_FN）时在下面多出可点的「退出登录」一行；没报的插件
 * 一行都不出（canLogout=false），不在这里放一个只做一半的假登出。
 */
@Component
struct PluginUserInfoRow {
  @StorageProp('isDark') isDark: boolean = false;
  /** 主行：'已登录 · 用户名'，或用户名与下方账号项同值时的 '已登录'（要求5 去重） */
  @Prop lineText: string = '';
  /** 要求6：该插件 actions 里带 LOGOUT_FN 才出登出行 */
  @Prop canLogout: boolean = false;
  /** 登出在跑：文案换「正在退出…」并挡连点（值由外层 @State 驱动） */
  @Prop logoutBusy: boolean = false;
  onLogout: () => void = () => {};

  build() {
    Column() {
      Row() {
        Column() {
          Text(this.lineText)
            .fontSize(15)
            .fontColor(Theme.text1(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')
      .constraintSize({ minHeight: Dim.menuItemH })
      .padding({ top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      if (this.canLogout) {
        // 登出行（要求6）：破坏性操作 ⇒ 红色文字 + 点击后先弹确认（doLogout），这里只管触发。
        // 与上面主行同宽同边距，靠高度与颜色区分，不画分隔线（口径同第 5 条(1) 已定的删线口径）。
        Row() {
          Text(this.logoutBusy ? '正在退出…' : '退出登录')
            .fontSize(15)
            .fontColor(this.logoutBusy ? Theme.text3(this.isDark) : Theme.error)
            .width('100%')
            .textAlign(TextAlign.Center)
        }
        .width('100%')
        .constraintSize({ minHeight: 44 })
        .clickEffect({ level: ClickEffectLevel.LIGHT })
        .onClick((): void => {
          if (!this.logoutBusy) {
            this.onLogout();
          }
        })
      }
    }
    .width('100%')
  }
}

/**
 * s17 第 2 条：一次登录态探测的结果（只有三个数，任何键名与值都不经这里）。
 *
 * 为什么不拿「非空键数」直接当登录判据：eh 的装载函数 mY 会从 cookie 串里反解回填三键，
 * 且 igneous 是插件跑动中自己会写进去的（取证 _tmp/s16/bundles/ehentai-v0.1.6.bundle.cjs
 * @77450 的 h && (k.ipb_member_id = ...) 与 @1417581 的 fields），只拿到过一枚 igneous 的
 * 设备会被判成「已登录」= 反向假阳性。所以另数一份**插件自己标了 required 的字段**：
 * eh 只有 ipb_member_id / ipb_pass_hash 是 required:!0，igneous 没标 ⇒ 判据自动收紧到
 * 「主凭据至少有一项」。个别插件一枚 required 都没标（实测 bf99008d-0.1.0 的
 * fields:[{key:account,label:用户名},{key:password,label:密码}] 全无 required），
 * 这种退回按 total 判，否则它永远显示不出登录态。
 */
class LoginProbeResult {
  /** 非空且非核验类的字段数（只喂副文案的「已保存 N 项登录凭据」，不参与登录判定） */
  total: number = 0;
  /** 其中插件标了 required 的非空字段数（登录判据） */
  required: number = 0;
  /** 方案里 required 字段的总数；0 = 该插件没标过 required ⇒ 判据退回 total */
  requiredDeclared: number = 0;
}

/**
 * s33 需求 4：「图片画质」这一行（宿主兜底档）。**与 PluginVersionRow / PluginLoginRow 同因同治
 * = 必须是独立 @Component + @Prop**：本页已三处实证 @Builder 形参是按值快照的，
 * 而本行的 subText 会在「用户改完档位」时变（qualityLabel 是 @State），走 ManageRow 会定格在旧值。
 *
 * 只在这里显示**清洗后的档位文案**，不显示任何配置桶原文（值本身只可能是 original/medium/low
 * 这类档位串或用户自填的短串，仍然走 @Prop 传现算好的 label，不把桶内容直接铺屏）。
 */
@Component
struct PluginQualityRow {
  @StorageProp('isDark') isDark: boolean = false;
  /** 副标题：当前档位的中文说明（外层 qualityLabel 现算） */
  @Prop subText: string = '';
  onTap: () => void = () => {};

  build() {
    Row() {
      Column() {
        Text(IMAGE_QUALITY_LABEL)
          .fontSize(15)
          .fontColor(Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        if (this.subText.length > 0) {
          Text(this.subText)
            .fontSize(12)
            .fontColor(Theme.text3(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(Dim.iconSm)
        .fontColor([Theme.text3(this.isDark)])
    }
    .width('100%')
    .constraintSize({ minHeight: Dim.menuItemH })
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      this.onTap();
    })
  }
}

/**
 * s17 第 2 条：登录卡那一行的独立 @Component（此前是 this.ManageRow(...)，形参按值快照 ⇒
 * 登录态变了样不重绘，本项目已三处实证；同文件的 PluginVersionRow / PluginUserInfoRow 就是先例）。
 *
 * 两态显示（verified / savedCount 由外层 @State 经 @Prop 传进来）：
 *  verified=false ⇒ 与改前一字不差（插件自报 loginTitle/loginSubtitle，缺省「账号登录 / 点击登录插件账号」）。
 *       这一档覆盖 未保存 / 只漂着插件自写的可选键 / 探测失败 / 插件不支持 四种情形 ⇒
 *       **不宣称未登录**，只退回原文案（探测挂了不等于用户掉线）。
 *  verified=true  ⇒ 副文案换成「已保存 N 项登录凭据」，右侧加状态点 +「已登录」。N 只报数，
 *       不写「完整 / 齐了 / 已全部保存」这类语义：eh 的可选键会随插件跑动漂移，N 会 2 变 3（_tmp/s17/ACCEPT.md 第三节）。
 *
 * 硬口径：这里只可能渲染 count 这个数与固定中文，没有任何一路把账号名 / 口令 / cookie 值
 * 或字段键名带到屏上（值的去向只在登录页与插件存储之间，见 pages/PluginLoginPage.ets 文件头）。
 * 整行始终可点（onOpen）：已登录也要能进去换账号，不为了显示状态把入口禁掉。
 */
@Component
struct PluginLoginRow {
  @StorageProp('isDark') isDark: boolean = false;
  /** 主文案：插件自报 loginTitle，空则调用方给「账号登录」 */
  @Prop title: string = '';
  /** savedCount 为 0 时的副文案（插件自报 loginSubtitle，空则「点击登录插件账号」） */
  @Prop baseSub: string = '';
  /** 已保存且非空的凭据条数（只报数） */
  @Prop savedCount: number = 0;
  /** 是否够格说「已登录」（判据 = required 那一份账，见 LoginProbeResult）；false = 原样退回 */
  @Prop verified: boolean = false;
  onOpen: () => void = () => {};

  build() {
    Row() {
      Column() {
        Text(this.title)
          .fontSize(15)
          .fontColor(Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(this.verified ? ('已保存 ' + String(this.savedCount) + ' 项登录凭据') : this.baseSub)
          .fontSize(12)
          .fontColor(this.verified ? Theme.text2(this.isDark) : Theme.text3(this.isDark))
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .margin({ top: 3 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      // 已登录标记：状态点沿用全站同一套 dot + 文案形态，色取 Theme.success（不新造色值）。
      // 与右侧箭头之间留 6vp，两条不会挤在一起；整组不可压缩，长主文案让位（flexShrink 口径）。
      if (this.verified) {
        Row({ space: 5 }) {
          Circle({ width: 6, height: 6 })
            .fill(Theme.success)
          Text('已登录')
            .fontSize(12)
            .fontColor(Theme.text2(this.isDark))
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .backgroundColor(Theme.fillColor(this.isDark))
        .borderRadius(Dim.coverRadius)
        .alignItems(VerticalAlign.Center)
        .flexShrink(0)
        .margin({ right: 6 })
      }

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(Dim.iconSm)
        .fontColor([Theme.text3(this.isDark)])
        .flexShrink(0)
    }
    .width('100%')
    .constraintSize({ minHeight: Dim.menuItemH })
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick((): void => {
      this.onOpen();
    })
  }
}

/** 文本输入浮层的模式（password 只是遮罩显示，存的都是原文）。 */
class EditTarget {
  field: SettingField = new SettingField();
  text: string = '';
  password: boolean = false;
}

@Entry
@Component
struct PluginSettingsPage {
  @StorageProp('isDark') isDark: boolean = false;

  /** 路由参数 */
  @State uuid: string = '';
  @State displayName: string = '';
  @State localFile: string = '';
  /** onPageShow 首屏必然跟一次 aboutToAppear 的 reload，先把这一次吞掉（省一轮 bundleCall）。 */
  private shownOnce: boolean = true;

  /** 载入态 */
  @State loading: boolean = true;
  @State loadError: string = '';
  @State @Watch('onBundleChanged') bundle: PluginSettingsBundle = new PluginSettingsBundle();
  /** 插件自报版本（getInfo.version），空则用 displayName 之外的清单版本 */
  @State pluginVersion: string = '';
  /** 正在保存的字段 key（给它上灰，避免连点重复提交） */
  @State busyKey: string = '';
  /** 文本输入浮层（null = 不显示） */
  @State edit: EditTarget | null = null;
  /** 删除确认浮层 */
  @State confirmDelete: boolean = false;
  /**
   * 用户信息键列表（@State 化才能在 build 里安全遍历 —— Map 的迭代器不能直接进 ForEach）。
   * 用 forEach 收集，不用 Array.from(map.keys())：后者在 ArkTS 严格模式对 IterableIterator
   * 的重载解析不稳，s5i 之前就为类似写法编过一次改一次。
   * BUG3-b：这里同时是脱敏闸门 —— 凭据类的键不进列表，用户信息区就摊不出密码/令牌。
   */
  @State userInfoKeys: string[] = [];
  /**
   * 用户信息卡的主行文案（要求5：'已登录 · 用户名' 或去重后的 '已登录'）。
   * 派生同 viewSections —— 在 onBundleChanged 里算一次，不在 build 里现算。
   */
  @State userCardLine: string = '已登录';
  // （曾在此加 @State accountName / canSwitchAccount：收掉重复账号项的判定全在 onBundleChanged 里
  // 一次算完，build 侧不读它们 ⇒ 不留死状态，两个值退回局部常量。）
  /** 要求6：该插件是否自报了登出动作（actions 里有 LOGOUT_FN）；false ⇒ 卡片不出登出行。 */
  @State canLogout: boolean = false;
  /**
   * 「能力」组实际渲染的动作（bundle.actions 去掉与卡片登出行重复的那条，见 onBundleChanged）。
   * 派生同 viewSections：build 会反复跑，不在里面现算。
   */
  @State capabilityActions: CapabilityAction[] = [];
  /** 要求6：登出在跑（挡连点 + 文案换「正在退出…」）。 */
  @State logoutBusy: boolean = false;
  /**
   * 设置页真正渲染的分组（bundle.sections 去掉凭据类字段、再扔掉空组）。
   * 在 onBundleChanged 里派生一次，不在 build 里现算（build 会反复跑）。
   */
  @State viewSections: SettingSection[] = [];
  /** 反混淆模式的展示文案（进页读一次、用户改完再刷一次；不直接读 pref 以免 build 里做异步）。 */
  @State jmLabel: string = '自动（推荐）';
  /**
   * s33 需求 4：该插件是否真的认「图片画质」这个键（= 值表里存在 image.quality）。
   * 参与 UI 判定 ⇒ 必须 @State（本页 s11 真机踩过：读私有字段不重渲染）。
   * 不给所有插件硬塞这一行的理由见 IMAGE_QUALITY_KEY 注释（11 枚载荷里只有哔咔读它）。
   */
  @State hasQuality: boolean = false;
  /** 「图片画质」行的展示文案（同上，在 onBundleChanged 里派生一次，不在 build 里现算）。 */
  @State qualityLabel: string = '未设置';
  /**
   * s17 第 2 条：插件登录方案里**已保存且非空**的凭据条数（只进 UI 的是这个数，值不上屏）。
   * 参与 UI 判定 ⇒ 必须 @State（s11 真机踩过：读私有字段不重渲染）。
   */
  @State loginSavedCount: number = 0;
  /**
   * s17 第 2 条：这次探测够不够格说「已登录」。判据 = 插件标了 required 的字段里至少一项非空
   * （没标 required 的插件退回「任一非空」）。参与 UI 判定 ⇒ 必须 @State（s11 真机踩过）。
   */
  @State loginVerified: boolean = false;
  /** 登录态探测的代次号：只有最新一代的回包允许落值，迟到的旧回包直接丢。 */
  private loginProbeSeq: number = 0;
  /** 上一次真正发出探测的时刻（Date.now 毫秒），只给 onPageShow 那一档节流用；0 = 还没探过。 */
  private loginProbeAt: number = 0;
  /** 灰条代次闸门与当前 id（0 = 屏上没有自己开的灰条），只被 openBusyToast/closeBusyToast 读写 */
  private busySeq: number = 0;
  private busyToastId: number = 0;

  /** 本插件对应的图源 id（ImageCache 与取图通道都以它为准）。 */
  private sourceId(): string {
    return PLUGIN_SOURCE_PREFIX + this.uuid;
  }

  aboutToAppear(): void {
    try {
      const raw: Object = router.getParams();
      if (raw instanceof PluginSettingsParams) {
        this.uuid = raw.uuid;
        this.displayName = raw.name;
        this.localFile = raw.localFile;
      } else if (raw !== null && raw !== undefined) {
        const src: ESObject = raw;
        this.uuid = src.uuid !== undefined ? String(src.uuid) : '';
        this.displayName = src.name !== undefined ? String(src.name) : '';
        this.localFile = src.localFile !== undefined ? String(src.localFile) : '';
      }
    } catch (e) {
      Logger.w('PluginSettingsPage 参数解析失败：' + (e as Error).message);
    }
    this.refreshJmLabel();
    this.reload();
  }

  private ctx(): common.UIAbilityContext {
    return getContext(this) as common.UIAbilityContext;
  }

  /** bundle 整体换引用时触发（@State 对 Map 内部 set 不敏感 ⇒ 所有写入方都必须换新对象）。 */
  onBundleChanged(): void {
    const keys: string[] = [];
    this.bundle.userInfo.forEach((v: string, k: string): void => {
      // BUG-A/BUG-B 交叉点（同一根因的第三处判定）：userInfo 的值同样可能是引号字面量 ——
      // 未登录时插件常回 account 为空引号对。判「有没有用户信息」必须按**清洗后**的长度，
      // 否则两个引号算有值 ⇒ 出信息卡显示引号，并且按三态优先级把登录入口顶掉，BUG-A 从这条路复现。
      if (cleanDisplayValue(v).length > 0 && !isCredentialKey(k)) {
        keys.push(k);
      }
    });
    this.userInfoKeys = keys;

    // 顶卡是否走 'info' 档（与 topCardMode() 第一档同判据）。下面两处复用同一个布尔，不再各写一遍：
    // ① 要不要把设置列表里重复的账号项收掉；② 账号项是否按「跟随登录态」只读。
    // 注意它**不是**登录证明，含义只是「插件声明能显示用户信息，且组里确有可展示的键」。所以插件
    // 没实现 getUserInfoBundle、或组里的键全被凭据剔空时它是 false，那时设置项一律保持可编辑 ——
    // 没有登录页的插件只有这一处能填账号，那种情况下收掉/锁死等于把人锁在门外。
    const infoMode: boolean = this.bundle.canShowUserInfo && keys.length > 0;

    // 要求6：登出能力按「插件自报」判定，不硬编码插件名单。先算它，因为下面「账号项要不要收掉 /
    // 要不要锁成只读」两处都依赖它。
    let hasLogout: boolean = false;
    for (let i = 0; i < this.bundle.actions.length; i++) {
      if (this.bundle.actions[i].fnPath === RELOGIN_FN) {
        hasLogout = true;
        break;
      }
    }
    this.canLogout = hasLogout;

    // 防锁死闸门（新七条第 4 条）：用户是否**另有换账号的路** —— 插件给了登录页，或给了登出动作。
    // 只有另有出路时，设置列表里的账号项才允许收掉/锁成只读；两条都没有的插件，那一项就是填账号
    // 的唯一入口，收掉或锁死等于把人锁在门外（BUG-A 同类的错误：修一个显示问题、堵死一条主路径）。
    const switchable: boolean = this.bundle.canLogin || hasLogout;

    // s12 第 2 条（真机 2026-11-12 20:18，禁漫天堂 0.0.7）：顶卡不在 info 档（= 卡片上没有
    // 「已登录」那一行）⇒ 账号名没有展示位，可见设置项里凡是键名像账号键的项一律不进列表
    // （下面字段循环里那条）。
    // 现场根因：auth.account 落在 IDENTIFIER_SEGMENTS ⇒ isCredentialKey 判 false ⇒ 它不属于
    // BUG3-b 那条凭据剔除；而未登录时 infoMode=false ⇒ canTakeOver=false、cardName 为空串，
    // 两道去重闸都放行 ⇒ 未登录态下面挂着一行可点可改的用户名（用户报的「登出后用户名依旧在，
    // 并且可以修改）。与 dropAccountFields 是两条互补判据：那条管「卡片接管后
    // 去掉同键重复项」（s15 第 6 条起不再要求 cardName 非空，只看 canTakeOver），
    // 这条管「卡片没接管时不留可改残留」（顶卡不在 info 档那一档）。
    // 两条各管一档、互不重叠。
    //
    // 为什么还要 && switchable（lead 结案收窄，原实现只看顶卡档位）：本文件既有防锁死原则
    // （上面 switchable 的注释）= 用户没有别的登录出路时，那一行就是填账号的唯一入口，绝不能隐。
    // 两个效果都是实测/在册取证要保的：① 在线翻译类插件（canShowUserInfo=false、canLogin=false、
    // 无登出动作）设置项里有一项 key=translate.email，归一后以 email 结尾会被「像账号键」误命中
    // ⇒ 无卡档下被隐掉，用户再也填不了那个可选邮箱；② 未来出现「无登录页 + 无登录卡 + 账号项
    // 是纯持久化字段」的插件时不会把人锁死。禁漫天堂 canLogin=true 且自报 clearPluginSession、
    // 哔咔 canLogin=true ⇒ switchable 恒真 ⇒ 本条对两个真机现场一点没削弱。
    const hideAccountRows: boolean = switchable && this.topCardMode() !== 'info';


    // 要求6：登出入口只留一处。卡片上那行「退出登录」的显示条件就是顶卡走 'info' 档，即上面那个
    // infoMode（与 topCardMode() 第一档同判据，不再重述第三遍）。该档成立时把动作组里同 fnPath 的
    // 这条**隐掉**，否则同一页出现两个登出入口（用户第 5 条就在抱怨重复项）。其余档位（登录卡 /
    // 占位卡）仍照原样渲染插件自报的这条 —— 那时卡片上没有登出行，删掉它等于抹掉插件唯一的登出路径。
    const cardShowsLogout: boolean = hasLogout && infoMode;
    const acts: CapabilityAction[] = [];
    for (let i = 0; i < this.bundle.actions.length; i++) {
      if (cardShowsLogout && this.bundle.actions[i].fnPath === RELOGIN_FN) {
        continue;
      }
      acts.push(this.bundle.actions[i]);
    }
    this.capabilityActions = acts;

    const visible: SettingSection[] = [];
    for (let i = 0; i < this.bundle.sections.length; i++) {
      const sec: SettingSection = this.bundle.sections[i];
      const kept: SettingField[] = [];
      for (let j = 0; j < sec.fields.length; j++) {
        const f: SettingField = sec.fields[j];
        // BUG3-b：password 类字段既不能显示现值、也不给编辑入口（值仍在 values 里，插件自己读得到）
        if (f.kind === 'password' || isCredentialKey(f.key)) {
          continue;
        }
        // s12 第 2 条：未登录档（顶卡非 info **且用户另有登录出路**）隐掉账号名行。**带 fnPath 的项不隐** —— 那是插件自报的
        // 服务端 setter（与 :1068 / :1105 同一条 fnPath 例外，用户明示的「除非上游提供对云端用户名的
        // 修改」），隐掉等于抹掉插件自己给的账号通路。非账号项一律不受本条影响。
        if (hideAccountRows && f.fnPath.length === 0
          && looksLikeUsernameKey(normalizeDisplayKey(f.key))) {
          continue;
        }
        kept.push(f);
      }
      if (kept.length > 0) {
        const g = new SettingSection();
        g.id = sec.id;
        g.title = sec.title;
        g.fields = kept;
        visible.push(g);
      }
    }

    // 新七条第 4 条（2026-11-12 16:15 回传）：账号名显示在「已登录」后面同一行，且只读、下方不再
    // 单开一项。卡片账号名的来源两级：① userInfo 候选键（插件自报的用户信息，最权威）；② 可见设置
    // 项里键名像账号键的那一项 —— 有的插件 userInfo 不带用户名，只在 scheme.sections 给一项「用户名」，
    // 只查 ① 就会退成「卡片只有已登录 + 下面单开一行用户名」= 本条要消灭的现场。两级都取不到 ⇒ 空串。
    // 双重闸门 infoMode && switchable（理由见上面两处注释）：任一不成立 ⇒ 不但不收重复项，
    // 连「从设置项借账号名上卡片」也不做。原因：不收项却把名字抄上卡片 = 同一个值在页面上出现两次，
    // 正是本条要消灭的重复；不借名则卡片只显「已登录」、下面那行照旧可编辑，两头都不破。
    const canTakeOver: boolean = infoMode && switchable;
    const cardName: string = this.accountNameFrom(keys, canTakeOver ? visible : []);
    // s15 第 6 条（用户拍板口径 A）：卡片接管后，同键可编辑项**无条件**收掉（判据见该方法注释）。
    // 本行只需守住「接管与否」这一道闸门 = canTakeOver，它自带 switchable（有登录页或登出动作）
    // ⇒ 收掉之后用户仍有换账号的路。另有一条天然不变量兜底：cardName 为空当且仅当 ① userInfo 候选
    // 键都空 且 ② 可见项里没有一项「键名像账号键且值非空」（accountNameFrom 的二级就是来找它的），
    // 所以卡片没名字时本行收掉的必然只是个空值项，不会把用户填过的账号名藏起来。
    this.viewSections = canTakeOver ? this.dropAccountFields(visible) : visible;

    // s33 需求 4：「图片画质」宿主兜底行的两道判定，都在这一处算完（build 里不现算）。
    //  ① declared = 插件自己在 scheme 里给了这一项 ⇒ 上面列表已有可点行，绝不再开第二行
    //     （与要求6「同一页不留两个入口」同一口径）。
    //  ② 值表里存在这个键才显示本行。值表 = 插件 getSettingsBundle 的 data.values **加**宿主桶
    //     覆盖（PluginSettings.mergeValues :365），两路任一命中都算：插件自报了但没进 scheme（哔咔
    //     就是这形态：values 里有 image.quality、scheme 里只有账号/屏蔽/接口线路），或插件压根没自报
    //     但用户以前存过值。都不命中 ⇒ 该插件不认画质，硬塞一行只会让人以为改了有用。
    let declared: boolean = false;
    for (let i = 0; i < this.bundle.sections.length && !declared; i++) {
      const flds: SettingField[] = this.bundle.sections[i].fields;
      for (let j = 0; j < flds.length; j++) {
        if (flds[j].key === IMAGE_QUALITY_KEY) {
          declared = true;
          break;
        }
      }
    }
    const qv: string | undefined = this.bundle.values.get(IMAGE_QUALITY_KEY);
    // ★ 先把可空值收敛成非空串再判：ArkTS 的类型窄化不穿过中间那枚 boolean（写成
    //   hasQ ? f(cleanDisplayValue(qv)) : … 会报 10605999 string | undefined 不能喂 string），
    //   而且清洗只做一次。语义与「未定义 / 清洗后空串 ⇒ 不显示本行」完全等价。
    const qraw: string = qv === undefined ? '' : cleanDisplayValue(qv);
    const hasQ: boolean = !declared && qraw.length > 0;
    this.hasQuality = hasQ;
    this.qualityLabel = hasQ ? this.qualityLabelOf(qraw) : '未设置';

    // 要求5 + 新七条第 4 条：主行「已登录 · 账号名」（账号名跟在登录态后面同一行）；
    // 两级来源都取不到才落「已登录」保底行（绝不回铺原始键）。
    this.userCardLine = cardName.length > 0 ? ('已登录 · ' + cardName) : '已登录';
  }

  private absPath(): string {
    return this.ctx().filesDir + '/plugins/' + this.localFile;
  }

  /**
   * s17 第 2 条：探一次「这个插件自己存了几条登录凭据」。
   *
   * ★ 为什么只有这一条信号可靠（取证见 _tmp/s16/bundles/ehentai-v0.1.6.bundle.cjs）：
   *   1) 设置页原来的判据是 getSettingsBundle ⇒ canShowUserInfo，而 eh 恒回 canShowUserInfo:!1、
   *      整个 bundle 里 0 处 getUserInfoBundle ⇒ topCardMode() 永远落第二档 'login'，
   *      那一行的主/副文案就是硬编码兜底，登录与否它一个字都不变（= 用户报的现场）。
   *   2) 想退一步读 getSettingsBundle.values 里的 cookie 键也不行：eh 把那几个键闸在
   *      legacyHost（宿主版本 < 3.0.34）后面，我们 3.0.37 ⇒ 那里连键都不带。
   *   3) getLoginBundle 的初值是唯一一条「插件自己承认存了凭据」的通道：四枚实现该方法的插件
   *      （eh / bika / jjmhw / jm）都把已存值放进 scheme.values 或 data 顶层，
   *      而 data/source/PluginLogin.ets 的 fetchScheme(:353-376) 把清洗后为空的值一律不写进 initial
   *      ⇒ 「fields 里有多少项在 initial 上有非空值」严格等价于「插件存了几条凭据」。
   *
   * 只数 fields ∩ initial 的非空项，不数 initial 的全部键：初值是 {...data, ...data.values} 合并来的，
   * 里面可能混有线路、站点这类普通设置项，拿键数当登录凭据数会虚报。
   * 验证码图与滑块两项刻意跳过（kind 决定）：那是核验题的临时值，不是存下来的凭据。
   *
   * 失败语义：任何异常 / 不支持 ⇒ 计数归 0，UI 退回改前那句原文案。⇒ 这一条**只会在确有把握时
   * 说「已登录」，永远不会反过来宣称「未登录」**（探测挂了不等于用户掉线，s11 三原则第 3 条同口径）。
   *
   * 只在四个「登录态可能变了」的点调用（reload / onPageShow / 能力动作后的静默重读 / 登出后的静默重读），
   * 刻意不挂 onBundleChanged：commit() 改一个设置项也会换 bundle 引用，挂上去等于每改一项
   * 多打一次 getLoginBundle（个别插件那一句会发网络请求，不能这么浪费）。
   */
  /**
   * @param throttleMs 距上次发出探测不足这个毫秒数就整次跳过（0 = 不节流）。
   * 只有 onPageShow 那一档传非 0：eh 的 getLoginBundle 走 mY，含七次 storage 读，且 directConnect
   * 为真时 mQ(l) 是无条件跑的一次网络（bundle @77530 的短路里 skipExProbe 只跳 mM/mP 两档），
   * 来回切页时这一档最频繁 ⇒ 800ms 内重复进页不重探（已显示的结果继续用，不会闪回原文案）。
   */
  private probeLoginState(throttleMs: number): void {
    if (this.uuid.length === 0 || !this.bundle.canLogin) {
      this.loginSavedCount = 0;
      this.loginVerified = false;
      return;
    }
    const now: number = Date.now();
    if (throttleMs > 0 && this.loginProbeAt > 0 && now - this.loginProbeAt < throttleMs) {
      return;
    }
    this.loginProbeAt = now;
    const seq: number = this.loginProbeSeq + 1;
    this.loginProbeSeq = seq;
    PluginLogin.fetchScheme(this.uuid).then((r: LoginResult<LoginScheme>): void => {
      // 代次闸门： onPageShow 与静默重读可能并行发出两探，慢的那一回包不能盖掉新的结果
      if (seq !== this.loginProbeSeq) {
        return;
      }
      if (!r.ok || r.data === null) {
        this.loginSavedCount = 0;
        this.loginVerified = false;
        return;
      }
      const p: LoginProbeResult = this.countSaved(r.data);
      this.loginSavedCount = p.total;
      this.loginVerified = p.requiredDeclared > 0 ? p.required > 0 : p.total > 0;
    }).catch((e: Object): void => {
      if (seq !== this.loginProbeSeq) {
        return;
      }
      this.loginSavedCount = 0;
      this.loginVerified = false;
      Logger.w('登录态探测失败（不影响设置项读写）：' + (e as Error).message);
    });
  }

  /**
   * 数方案字段的两份账（键名与值都不上屏，只回计数）：
   *  total = 非空且非核验类的字段数（副文案报数用）；
   *  required / requiredDeclared = 插件标了 required 的那部分（登录判据，见 LoginProbeResult）。
   * 验证码图与滑块刻意跳过：那是核验题的临时值，不是存下来的凭据；password 也跳过
   * （值最敏感且跨插件共享桶里它最可能是别人的，见 _tmp/s17/ACCEPT.md 第六节）。
   */
  private countSaved(s: LoginScheme): LoginProbeResult {
    const out: LoginProbeResult = new LoginProbeResult();
    for (let i = 0; i < s.fields.length; i++) {
      const f: LoginField = s.fields[i];
      if (f.key.length === 0 || f.isPassword() || f.isCaptchaImage() || f.isSlider()) {
        continue;
      }
      if (f.required) {
        out.requiredDeclared++;
      }
      const v: string | undefined = s.initial.get(f.key);
      if (v === undefined || v.length === 0) {
        continue;
      }
      out.total++;
      if (f.required) {
        out.required++;
      }
    }
    return out;
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2200 });
    } catch (e) {
      Logger.i('toast 失败：' + msg);
    }
  }

  /**
   * s17 第 2 条附带：能力动作「进行中」灰条的生命周期（只服务 execAction，别处仍用 toast）。
   *
   * 改前这里只有 this.toast('正在执行：' + 标题)，而 showToast 发出去就撤不回来
   * （@ohos.promptAction.d.ts:1798-1831 那条 showToast 没有任何取消口），动作再快也要挂满 2200ms：
   * 点「前往网页登录」时页面早就跳走了，灰条还压在网页登录页上；慢动作则是结果 toast 被旧灰条盖住。
   * 现在换成 openToast（同文件 :1860，@since 18，回 id）+ 动作一落定就 closeToast（:1884）。
   * compileSdkVersion 与 compatibleSdkVersion 都是 26.0.0（Breeze-ohos/build-profile.json5）⇒ API18 可用。
   *
   * 三条兜底，最坏情况就是退回改前行为，不会更差：
   *  1) 拿不到 UIContext 档的 PromptAction ⇒ 直接退回 this.toast（本仓先例 = pages/SearchPage.ets 里
   *     getUIContext 外面包 try/catch，注释写明「过早可能拿不到实例」）。
   *     走 UIContext 档而不是全局 promptAction 是 SDK NOTE 的明确要求（:1842-1845 全局口有
   *     ambiguous UI context 问题），全局 showToast 已在 18 废弃也是同一原因。
   *  2) openToast 回 id 是异步的，动作可能比 id 先结束 ⇒ busySeq 代次闸门：过期的 id 一到就地关掉，
   *     连点两个动作时上一条灰条也不会留下孤儿。
   *  3) closeToast 对已过期/已被顶掉的 id 抛 103401（SDK 原话 Cannot find the toast）⇒ try/catch 吞掉只留日志。
   * duration 取满上限 10000（ShowToastOptions.duration 注释 :170-173：>10000 按 10000 截），
   * 只是防「动作本身悬挂时灰条永不消失」，正常路径一律由 closeBusyToast 提前撤。
   */
  private openBusyToast(msg: string): void {
    this.closeBusyToast();
    this.busySeq = this.busySeq + 1;
    const seq: number = this.busySeq;
    let pa: PromptAction | null = null;
    try {
      pa = this.getUIContext().getPromptAction();
    } catch (e) {
      pa = null;
    }
    if (pa === null) {
      this.toast(msg);
      return;
    }
    const opts: promptAction.ShowToastOptions = { message: msg, duration: 10000 };
    try {
      pa.openToast(opts).then((id: number): void => {
        if (seq !== this.busySeq) {
          this.safeCloseToast(id);
          return;
        }
        this.busyToastId = id;
      }).catch((e: Object): void => {
        Logger.i('openToast 未生效，退回普通提示：' + (e as Error).message);
        this.toast(msg);
      });
    } catch (e) {
      this.toast(msg);
    }
  }

  /** 撤掉自己开的灰条；同时让在飞的 openToast 回包作废（回来就地关，不留孤儿）。 */
  private closeBusyToast(): void {
    this.busySeq = this.busySeq + 1;
    if (this.busyToastId !== 0) {
      this.safeCloseToast(this.busyToastId);
      this.busyToastId = 0;
    }
  }

  private safeCloseToast(id: number): void {
    try {
      this.getUIContext().getPromptAction().closeToast(id);
    } catch (e) {
      Logger.i('closeToast 忽略（多半已过期）：' + (e as Error).message);
    }
  }

  /** 离页时兜一层：动作在飞时用户直接返回，灰条不该跟着带到下一页（toast 是窗口级，不随页面销毁）。 */
  aboutToDisappear(): void {
    this.closeBusyToast();
  }

  async reload(): Promise<void> {
    this.loading = true;
    this.loadError = '';
    if (this.uuid.length === 0 || this.localFile.length === 0) {
      this.loadError = '缺少插件参数，请从插件管理页进入';
      this.loading = false;
      return;
    }
    // 1. 装载（多数入口进来时已装载，这一步是幂等保险；失败就是真装载不了，给错误态）
    const loadErr: string = await PluginSettings.ensureLoaded(this.uuid, this.absPath());
    if (loadErr.length > 0) {
      // s37 需求 2：原文（可能含 bundle 路径 / [stack-hook] / 引擎堆栈）只进日志，屏上收成一句人话。
      // 必须先记后洗 —— errBriefForScreen 是纯函数，不写日志。
      errLog('[PluginSettings] ensureLoaded', loadErr);
      this.loadError = errBriefForScreen(loadErr, '插件装载失败，请回到插件管理页重新导入该插件');
      this.loading = false;
      return;
    }
    // 2. 全量载入设置
    const b: PluginSettingsBundle = await PluginSettings.load(this.ctx(), this.uuid);
    this.bundle = b;
    // s17 第 2 条：登录态回显的探测点之一（另三处见 probeLoginState 注释）。不 await：
    // 它是给登录卡补状态的第二条腿，不能挡首屏，也不能把 loading 拖着。
    this.probeLoginState(0);
    if (b.error.length > 0) {
      // s37 需求 2：同一条 ErrorView 路径的第二个来源（getSettingsBundle 失败），同样先记后洗。
      errLog('[PluginSettings] getSettingsBundle', b.error);
      this.loadError = errBriefForScreen(b.error, '插件设置读取失败，请稍后重试或重进本页');
    }
    this.loading = false;
    // 3. 版本 + 插件自报名字（异步补，不挡首屏）
    this.refreshInfo();
  }

  /**
   * BUG4 的取数编排（对齐上游 plugin_registry_service.dart 的「先缓存后现调」）：
   *   ① 先读落盘的 getInfo 原文 ⇒ 重进本页秒显版本/名字，不等网络；
   *   ② 再现调一次 getInfo（8s 上限）⇒ 成功就刷新 UI 并回写缓存，失败/超时它内部已回退缓存；
   *   ③ 版本仍为空（首次装、从没调通过）才走 resolveVersionFallback 的清单/文件名兜底。
   * 旧写法这里打了**两次** getInfo（pluginVersion 与 fetchName 各一次），第二次还没超时保护；
   * 现在合成一次，version 与 name 同源于同一条回包（也避免两者来自不同次调用而互相矛盾）。
   */
  private refreshInfo(): void {
    PluginSettings.cachedInfo(this.ctx(), this.uuid).then((c: PluginInfo): void => {
      if (c.version.length > 0) {
        this.pluginVersion = c.version;
      }
      if (c.name.length > 0) {
        this.displayName = c.name;
      }
    }).catch((_e: Object): void => {});
    PluginSettings.info(this.ctx(), this.uuid).then((info: PluginInfo): void => {
      if (info.name.length > 0) {
        this.displayName = info.name;
      }
      if (info.version.length > 0) {
        this.pluginVersion = info.version;
        return;
      }
      this.resolveVersionFallback();
    }).catch((_e: Object): void => {
      this.resolveVersionFallback();
    });
  }

  /**
   * 版本兜底三级链（s7b 真机缺陷：装好的插件版本一直显示「未知」）：
   *   1) getInfo.version（上面那步，插件自报，最准；含本次现调与上次落盘原文两路，
   *      落盘那路在 PluginSettings.info 的 catch 里，见该注释）
   *   2) 宿主清单 PluginRecord.version（util/PluginStore 的 installed.json，商店下载/更新时写入）
   *   3) 落盘文件名派生（plugin_mgr.bundle.cjs:383 命名规则 = 前段uuid + '-' + tag + '.bundle.cjs'）
   * 走通一级就停：清单 version 是「仓库清单声明值」，可能比实际 release tag 新
   *（例 JmComic 清单 0.1.0 / 实际 0.0.7），所以它只能当兜底，不能反客为主。
   */
  private resolveVersionFallback(): void {
    if (this.pluginVersion.length > 0) {
      return;
    }
    PluginStore.loadAll(this.ctx()).then((list: PluginRecord[]): void => {
      for (let i = 0; i < list.length; i++) {
        if (list[i].uuid === this.uuid && list[i].version.length > 0) {
          this.pluginVersion = list[i].version;
          return;
        }
      }
      const derived: string = this.versionFromFileName(this.localFile);
      if (derived.length > 0) {
        this.pluginVersion = derived;
      }
    }).catch((_e: Object): void => {});
  }

  /**
   * 从文件名尾巴取版本 tag：先剥 '.bundle.cjs'，再取第一个 '-' 之后的整段
   *（版本号自带点，不能按 '.' 切）。只认以数字开头的结果，手放的自定义命名一律放弃，
   * 免得把 'my-test-build' 这类当版本号显示。
   */
  private versionFromFileName(fileName: string): string {
    const suffix: string = '.bundle.cjs';
    if (!fileName.endsWith(suffix)) {
      return '';
    }
    const stem: string = fileName.slice(0, fileName.length - suffix.length);
    const dash: number = stem.indexOf('-');
    if (dash < 0 || dash === stem.length - 1) {
      return '';
    }
    const tag: string = stem.slice(dash + 1);
    const head: string = tag.charAt(0);
    if (head < '0' || head > '9') {
      return '';
    }
    return tag.length <= 24 ? tag : '';
  }

  // ---------------- 写回 ----------------

  /** 提交一个字段（值 = 字符串）。 */
  private async commit(field: SettingField, value: string): Promise<void> {
    if (this.busyKey.length > 0) {
      return;
    }
    this.busyKey = field.key;
    const err: string = await PluginSettings.commitField(this.ctx(), this.uuid, field, value);
    this.busyKey = '';
    if (err.length > 0) {
      // s37 需求 2：commitField 失败串可能带 em(e) 原文（如 '保存失败：<引擎串>'）⇒ 先记后洗。
      errLog('[PluginSettings] commitField', err);
      this.toast(errBriefForScreen(err, '保存失败，请稍后重试'));
      return;
    }
    if (field.key === IMAGE_QUALITY_KEY) {
      const d: FeatureDiag = FeatureDiag.get();
      d.iqWrites += 1;
      d.iqLast = value;
    }
    // 本地即时回显（不整页 reload：多数插件 getSettingsBundle 会重发网络请求，很慢）
    this.bundle.values.set(field.key, value);
    const next = new PluginSettingsBundle();
    next.sections = this.bundle.sections;
    next.actions = this.bundle.actions;
    next.values = this.bundle.values;
    next.canShowUserInfo = this.bundle.canShowUserInfo;
    next.canLogin = this.bundle.canLogin;
    next.loginTitle = this.bundle.loginTitle;
    next.loginSubtitle = this.bundle.loginSubtitle;
    next.canShowDetail = this.bundle.canShowDetail;
    next.userInfo = this.bundle.userInfo;
    next.error = this.bundle.error;
    next.hasSettings = this.bundle.hasSettings;
    this.bundle = next;
  }

  /** choice/select：TextPickerDialog（range 用 label 数组，回索引再映射回 value）。 */
  private pickOption(field: SettingField): void {
    if (field.options.length === 0) {
      this.toast('该选项没有可选值');
      return;
    }
    const labels: string[] = [];
    let cur: number = 0;
    const curVal: string = this.valOf(field);
    for (let i = 0; i < field.options.length; i++) {
      labels.push(field.options[i].label);
      if (field.options[i].value === curVal) {
        cur = i;
      }
    }
    TextPickerDialog.show({
      range: labels,
      selected: cur,
      canLoop: false,
      onAccept: (result: TextPickerResult): void => {
        let idx: number = cur;
        if (typeof result.index === 'number') {
          idx = result.index as number;
        }
        if (idx < 0 || idx >= field.options.length) {
          return;
        }
        this.commit(field, field.options[idx].value);
      }
    });
  }

  /** multiChoice：本 SDK 无多选对话框 ⇒ 用 TextPickerDialog 单选逐项替换（选中的拼成 JSON 数组串）。 */
  private pickMulti(field: SettingField): void {
    if (field.options.length === 0) {
      this.toast('该选项没有可选值');
      return;
    }
    const labels: string[] = [];
    for (let i = 0; i < field.options.length; i++) {
      labels.push(field.options[i].label);
    }
    TextPickerDialog.show({
      range: labels,
      canLoop: false,
      onAccept: (result: TextPickerResult): void => {
        let idx: number = 0;
        if (typeof result.index === 'number') {
          idx = result.index as number;
        }
        if (idx < 0 || idx >= field.options.length) {
          return;
        }
        // 上游副标题显示「N 项」⇒ 值必须是 JSON 数组串，这里做「切换该项」语义
        const key: string = this.valOf(field);
        let arr: string[] = [];
        try {
          const parsed: ESObject = JSON.parse(key.length > 0 ? key : '[]');
          if (Array.isArray(parsed)) {
            const raw: ESObject[] = parsed as ESObject[];
            for (let i = 0; i < raw.length; i++) {
              arr.push(String(raw[i]));
            }
          }
        } catch (e) {
          arr = [];
        }
        const v: string = field.options[idx].value;
        const at: number = arr.indexOf(v);
        if (at >= 0) {
          arr.splice(at, 1);
        } else {
          arr.push(v);
        }
        this.commit(field, JSON.stringify(arr));
      }
    });
  }

  private openEditor(field: SettingField, password: boolean): void {
    const t = new EditTarget();
    t.field = field;
    // BUG3-b 纵深防御：凭据类字段 normally 已在 onBundleChanged 被剔出 viewSections、到不了这里；
    // 万一将来某插件把密码项伪装成 kind:'text' 且键名不在名单里漏进来，password 模式也绝不把
    // 已存值灌进输入框（旧写法 t.text = this.valOf(field) 会把密码原文显示成掩码，看得见拷得走）。
    // 代价：password 模式点「确定」会用当前输入覆盖旧值，因此不填就取消（见 EditOverlay 的确定分支）。
    t.text = password ? '' : this.valOf(field);
    t.password = password;
    this.edit = t;
  }

  /**
   * 能力组动作入口。命中「清会话」这条时**先弹确认**再执行（要求6：登出是破坏性操作，
   * 同一页的两个入口不能一个有确认一个没有 —— 卡片那行走 confirmLogout，这条走 confirmAction）。
   * 这条的语义与卡片登出行不同、故不合并：上游 view/plugin_settings_page.dart:729 是「清完跳登录页
   * 重登」，卡片那行是「清完留在本页」。两个都留着：未登录/占位档时它是唯一登出路径。
   */
  private runAction(action: CapabilityAction): void {
    if (action.fnPath === RELOGIN_FN) {
      this.confirmAction(action);
      return;
    }
    this.execAction(action);
  }

  /** 能力组「清会话」这条的确认弹窗（确认后仍走原 execAction ⇒ 保留跳登录页的上游语义）。 */
  private confirmAction(action: CapabilityAction): void {
    const opts: promptAction.ShowDialogOptions = {
      title: action.title,
      message: '将请求插件清除当前账号的登录状态，并跳到登录页重新登录。设置项与其它配置不受影响。',
      buttons: [
        { text: '继续', color: Theme.error },
        { text: '取消', color: Theme.text2(this.isDark) }
      ]
    };
    promptAction.showDialog(opts).then((res: promptAction.ShowDialogSuccessResponse): void => {
      if (res.index !== 0) {
        return;
      }
      this.execAction(action);
    }).catch((_e: Object): void => {});
  }

  /**
   * 原 runAction 的执行体（不含确认）。
   *
   * s15 第 8 条（用户 11-13 拍板 A 方案）改写：改前只 toast 一条字符串，插件回的 data 全丢 ⇒
   * 判不出「这条动作其实是要开网页」。现在改成先拿结构化返回再看怎么走：**命中 openWeb ⇒ 开内嵌
   * 登录页**（并直接 return，不再 toast、不再刷 bundle —— 跳走了刷了也白刷）；其余动作与失败路径
   * 仍走原来的 toast，观感与改前逐字一致（含 RELOGIN_FN 跳登录页、成功后静默刷 bundle）。
   *
   * ★ 能力动作**全生命周期只在这里调这一次**（lead 红线）：新页不再自己探一遍动作，所有参数从
   *   这里的返回里取、经 WebLoginParams 传过去。理由：清会话这类动作有副作用，探第二次 = 重复执行；
   *   不能因为「eh 这条恰好无副作用」就把分发器写成可以重复调用的形状。
   */
  private execAction(action: CapabilityAction): void {
    // s17 附带：改成可撤销的灰条，动作落定即撤（见 openBusyToast 注释）
    this.openBusyToast('正在执行：' + action.title);
    this.rawAction(action).then((r: RawActionResult): void => {
      if (!r.ok) {
        // 失败仍只 toast：与改前的 catch 分支同文案、同样不刷 bundle（没成功就没必要重读）
        this.closeBusyToast();
        this.toast(r.msg);
        return;
      }
      if (this.tryOpenWeb(r.root)) {
        // 已经跳网页登录页：灰条必须在这里撤，否则它会盖在登录页上到超时
        this.closeBusyToast();
        return;
      }
      this.closeBusyToast();
      this.toast(r.msg);
      if (action.fnPath === RELOGIN_FN) {
        this.openLogin();
      }
      // 动作可能改了设置（清会话/重载线路）⇒ 静默刷一次
      if (this.bundle.hasSettings) {
        PluginSettings.load(this.ctx(), this.uuid).then((b: PluginSettingsBundle): void => {
          this.bundle = b;
          // s17 第 2 条：能力动作里「清会话」这类会直接改登录态 ⇒ 跟着补一次登录态探测
          this.probeLoginState(0);
        }).catch((_e: Object): void => {});
      }
    });
  }

  /**
   * s15 第 8 条：跑一个能力动作并把**原始返回**留在页面侧解析一次。
   *
   * 为什么在页面侧另开一条而不改数据层：PluginSettings.runAction（data/source/PluginSettings.ets:517）
   * 的返回类型是 Promise<string>（只回 toast 文案），openUrl 在第一层就被丢掉了；而改它的签名要动
   * data/source/PluginSettings.ets，不在本条写域。本方法与数据层 callAction(:496) 走的是**同一条**
   * 引擎通道（同一个 bundleCall、同一份入参串 ACTION_ARGS ⇒ §24 契约不变），差别只在解析结果的去向，
   * 没有新增第二条调用路径。文案兜底（插件没回 message ⇒ '已执行：' + title）也照抄 callAction，
   * 保证非 openWeb 的动作 toast 出来的字与改前一字不差。
   */
  private rawAction(action: CapabilityAction): Promise<RawActionResult> {
    const r: RawActionResult = new RawActionResult();
    if (action.fnPath.length === 0) {
      r.msg = '该操作缺少 fnPath';
      return Promise.resolve(r);
    }
    return bundleCall(this.uuid, action.fnPath, ACTION_ARGS).then((raw: string): RawActionResult => {
      const o: ESObject = jparse(raw);
      r.ok = true;
      r.root = o;
      const box: ESObject = jobj(o, 'data');
      const msg: string = pickStr(box, o, 'message');
      r.msg = msg.length > 0 ? msg : ('已执行：' + action.title);
      return r;
    }).catch((e: Object): RawActionResult => {
      // s37 需求 2：能力动作失败的 r.msg 会直接 this.toast 上屏 ⇒ 同样先记后洗。
      const rawAct: string = errTextOf(e);
      errLog('[PluginSettings] execAction', rawAct);
      r.msg = errBriefForScreen(rawAct, '执行失败，请稍后重试');
      return r;
    });
  }

  /**
   * s15 第 8 条：返回里带「去网页登录」就把参数取全并跳内嵌页；返回是否已跳（已跳 ⇒ 调用方不再 toast）。
   *
   * 判据两条任一成立即算：① action.type === 'openWeb'（eh 给的规范形态，实测 eh.cjs@1404075：
   *   data.{accepted, openUrl, cookiePollIntervalMs:5e5, ignoreCookieNames:[cf_clearance],
   *   setCookieFnPath:'setEhentaiForumCookie', action:{type:'openWeb', payload:{title,url}}, message}）；
   * ② 同时给了 openUrl 与 setCookieFnPath（宽松档，别的插件不套 action 这层也能吃）。
   *
   * **只给 openUrl 不给 setCookieFnPath 不当作登录动作**：开了页也无处回传，等于把用户扔在一个
   * 跟登录无关的网页里 ⇒ 那种情况退回 toast，至少把插件的 message 原话给用户看。
   * 路由条目 pages/WebLoginPage 由 lead 加进 main_pages.json（本条写域不含该文件）；加之前点这条
   * 会落到下面的 catch 提示，不会静默无反应。
   */
  private tryOpenWeb(root: ESObject): boolean {
    const box: ESObject = jobj(root, 'data');
    const act: ESObject = jobj(box, 'action');
    const payload: ESObject = jobj(act, 'payload');
    const type: string = jstr(act, 'type', '');
    let url: string = jstr(payload, 'url', '');
    if (url.length === 0) {
      url = pickStr(box, root, 'openUrl');
    }
    const target: string = pickStr(box, root, 'setCookieFnPath');
    const shaped: boolean = type === 'openWeb' || (url.length > 0 && target.length > 0);
    if (!shaped || url.length === 0 || target.length === 0) {
      return false;
    }
    const p: WebLoginParams = new WebLoginParams(this.uuid, this.displayName, this.localFile);
    p.openUrl = url;
    p.setCookieFnPath = target;
    p.setTitle = jstr(payload, 'title', '');
    let iv: number = jnum(box, 'cookiePollIntervalMs', 0);
    if (iv <= 0) {
      iv = jnum(root, 'cookiePollIntervalMs', 0);
    }
    p.pollIntervalMs = iv;
    let ig: string[] = jstrArr(box, 'ignoreCookieNames');
    if (ig.length === 0) {
      ig = jstrArr(root, 'ignoreCookieNames');
    }
    p.ignoreCookieNames = ig;
    p.message = pickStr(box, root, 'message');
    // requiredNames 刻意不填：eh 没给这个字段（实测 8 份 .cjs 只有 ignoreCookieNames），
    // 新页自己有兜底必需键名单，插件哪天开始下发就自动以插件为准
    router.pushUrl({ url: 'pages/WebLoginPage', params: p })
      .catch((err: Object): void => {
        // s37 需求 2：同页 toast 也走「先记后洗」。这五处红队列为轻危（只有 toast，不铺满屏），
        // 但都是把 (e as Error).message 原样拼上去 —— 引擎串会带 bundle 路径与堆栈片段。
        const raw: string = errTextOf(err);
        errLog('[PluginSettings] openWebLogin', raw);
        this.toast(errBriefForScreen(raw, '打开网页登录失败，请稍后重试'));
      });
    return true;
  }

  /**
   * s15 第 8 条：能力组副文案。插件侧 capabilities 只有 {title, fnPath} 两个键
   * （实测 8 份 .cjs = bika/copy/eh/mangui/noyacg/shen/webtoon/zai，没有 description/message 字段，
   * 数据层解析也只取这两个键并滤掉 dumpRuntimeInfo）⇒ 说明只能宿主自己按 fnPath 归类写。
   * 认不出的动作回**空串**：ManageRow 的 sub 为空就不画那行，宁可少一行说明，
   * 也不能把 fnPath 这种内部函数名当文案上屏（改前 :1500 就是这个观感缺陷）。（与 s12「路径不上屏」同一条口径）
   */
  private actionSub(a: CapabilityAction): string {
    const fn: string = a.fnPath;
    if (fn === RELOGIN_FN) {
      return '清除当前账号的登录状态，随后跳到登录页';
    }
    if (fn.indexOf('WebLogin') >= 0) {
      return '打开内嵌网页完成登录，登录成功后自动把凭据交回插件';
    }
    return '';
  }

  /**
   * 打开插件登录页（缺陷③）。装载状态由登录页自己 ensureLoaded，这里只带三个参数。
   * 参数类与 PluginSettingsParams 同口径（pushUrl 传实例，页面侧 instanceof 取回）。
   */
  private openLogin(): void {
    const p: PluginLoginParams = new PluginLoginParams(this.uuid, this.displayName, this.localFile);
    router.pushUrl({ url: 'pages/PluginLoginPage', params: p })
      .catch((err: Object): void => {
        // s37 需求 2：同 openWebLogin（见该处注释）。
        const raw: string = errTextOf(err);
        errLog('[PluginSettings] openLogin', raw);
        this.toast(errBriefForScreen(raw, '打开登录页失败，请稍后重试'));
      });
  }

  /**
   * 登出（要求6）：确认弹窗 → PluginSettings.logout → 成功则静默重读 bundle 回登录态 + toast，
   * 失败只 toast 带原因。三档行为都在此：
   *  成功：插件清了会话 ⇒ getUserInfoBundle 回空/回引号对 ⇒ userInfoKeys 空 ⇒ topCardMode 落
   *        'login' ⇒ 顶部回到登录卡（用户要求「保留登录入口」的那条路径，与登录成功正好互逆）。
   *  失败：不动任何状态，toast 出插件/引擎给的原因。
   *  弹窗被取消或点遮罩（showDialog 的 Promise 会 reject，同 SearchPage 删除确认的处理）：什么都不做。
   *
   * 文案刻意**不承诺**「退出后不会自动登录/下次需要重新登录」：s8 真机诊断 cfg=0/9 说明这类插件
   * 一次都没走宿主持久化通道，会话在插件自己手里，宿主只能转达登出请求，管不到它存了什么。
   */
  private confirmLogout(): void {
    if (this.logoutBusy) {
      return;
    }
    const opts: promptAction.ShowDialogOptions = {
      title: '退出登录',
      message: '将请求插件清除当前账号的登录状态。设置项与其它配置不受影响。',
      buttons: [
        { text: '退出登录', color: Theme.error },
        { text: '取消', color: Theme.text2(this.isDark) }
      ]
    };
    promptAction.showDialog(opts).then((res: promptAction.ShowDialogSuccessResponse): void => {
      if (res.index !== 0) {
        return;
      }
      this.logoutBusy = true;
      PluginSettings.logout(this.uuid).then((r: LogoutResult): void => {
        this.logoutBusy = false;
        this.toast(r.msg);
        if (!r.ok) {
          return;
        }
        // 静默重读（不走 reload 的骨架屏）：用户信息卡与登录卡的可见性都由 bundle 驱动，
        // 换 bundle 引用 ⇒ onBundleChanged 重算 ⇒ 顶卡自动回 'login'。
        PluginSettings.load(this.ctx(), this.uuid).then((b: PluginSettingsBundle): void => {
          this.bundle = b;
          // s17 第 2 条：登出成功 ⇒ 插件把凭据键写成空值 ⇒ 探测应回 0，登录卡副文案自动回原文案
          this.probeLoginState(0);
        }).catch((_e: Object): void => {});
      }).catch((e: Object): void => {
        this.logoutBusy = false;
        // s37 需求 2：同 openWebLogin（见该处注释）。
        const raw: string = errTextOf(e);
        errLog('[PluginSettings] logout', raw);
        this.toast(errBriefForScreen(raw, '退出失败，请稍后重试'));
      });
    }).catch((_e: Object): void => {});
  }

  /**
   * 从登录页返回时刷一次（登录改了插件侧用户信息/会话）。
   * ⚠ onPageShow 只在 @Entry 上生效；本页是 @Entry（TabContent 子组件才不生效，别照抄那条结论）。
   * 首次进入也会走一次，用 shownOnce 跳过（否则 aboutToAppear 的 reload 之外多打一轮 bundleCall）。
   */
  onPageShow(): void {
    if (this.shownOnce) {
      this.shownOnce = false;
      return;
    }
    if (this.uuid.length === 0 || this.loadError.length > 0) {
      return;
    }
    PluginSettings.load(this.ctx(), this.uuid).then((b: PluginSettingsBundle): void => {
      this.bundle = b;
      // s17 第 2 条（本条的主路径）：从插件登录页或网页登录页 router.back 回来就走这里。
      // 本页是 @Entry ⇒ onPageShow 会跑（TabContent 子组件才不跑，别把那条结论套过来），
      // 所以**不需要新开一套 AppStorage 版本号 push + @StorageProp + @Watch**：
      // 那三例（readHistoryCount / searchHistoryCount / shelfRevision）都是「Tab 页之间」的跨页刷新，
      // 本页的返回本来就有生命周期可用，再加一个全局键 = 第二个权威源 + 多一处要维护的时序。
      // 800ms 节流：见 probeLoginState 的 throttleMs 注释（来回切页不重探）
      this.probeLoginState(800);
    }).catch((_e: Object): void => {});
  }

  // ---------------- 宿主管理区 ----------------

  /**
   * 图片反混淆模式（BUG1 花屏的手动闸门，详见 data/image/JmDeobfuscate.ets 文件头差异 3）。
   * auto = 仅 uuid 白名单或插件自报 isJm 时强制还原，其余靠内容自证；
   * on/off = 用户强开/强关。改完立即生效：ImageCache 的插件图缓存键含 intent，
   * 且 PluginImageOps.setMode 会清掉该源的适配器与探测记忆。
   */
  private refreshJmLabel(): void {
    const m: string = PluginImageOps.install().mode(this.sourceId());
    this.jmLabel = m === JmMode.ON ? '强制开启' : (m === JmMode.OFF ? '已关闭' : '自动（推荐）');
  }

  private pickJmMode(): void {
    promptAction.showActionMenu({
      title: '图片反混淆',
      buttons: [
        { text: '自动（仅在识别到混淆时还原）', color: Theme.brand },
        { text: '强制开启（该源每页都还原）', color: Theme.brand },
        { text: '已关闭（该源永不还原）', color: Theme.brand }
      ]
    }).then(async (res: promptAction.ActionMenuSuccessResponse): Promise<void> => {
      const mode: string = res.index === 1 ? JmMode.ON : (res.index === 2 ? JmMode.OFF : JmMode.AUTO);
      await PluginImageOps.install().setMode(this.sourceId(), mode);
      this.refreshJmLabel();
      this.toast('图片反混淆：' + (mode === JmMode.ON ? '已强制开启，回阅读页重进本章生效'
        : (mode === JmMode.OFF ? '已关闭' : '已设为自动')));
    }).catch((e: Error): void => {
      Logger.i('反混淆选择取消：' + e.message);
    });
  }

  /** 画质档位值 → 展示文案：命中兜底表用中文，否则原样回显（自定义值也要看得见）。 */
  private qualityLabelOf(v: string): string {
    if (v.length === 0) {
      return '未设置';
    }
    for (let i = 0; i < QUALITY_VALUES.length; i++) {
      if (QUALITY_VALUES[i] === v) {
        return QUALITY_LABELS[i];
      }
    }
    return '自定义：' + v;
  }

  /**
   * 画质这一项的 SettingField（宿主合成，不在 bundle.sections 里）。
   * fnPath 留空 = 让 commitField 走「无自带 setter」那条 ⇒ 落桶 + 补发 onSettingChanged；
   * persist 必须 true（默认值），false 就不落桶、插件下次读不到。
   */
  private qualityField(): SettingField {
    const f = new SettingField();
    f.key = IMAGE_QUALITY_KEY;
    f.kind = 'text';
    f.label = IMAGE_QUALITY_LABEL;
    return f;
  }

  /** 当前画质值（清洗后；未设置 = 空串）。 */
  private qualityValue(): string {
    const v: string | undefined = this.bundle.values.get(IMAGE_QUALITY_KEY);
    return v === undefined ? '' : cleanDisplayValue(v);
  }

  /**
   * s33 需求 4：选画质档。形态照 pickJmMode（同一套 showActionMenu + catch 取消）。
   * 最后一项是「自己填」—— 因为**除 original 外没有任何权威档位表**（依据见 IMAGE_QUALITY_KEY
   * 与 QUALITY_VALUES 的注释），插件真有别的档位名时用户至少能直接写进去，不必等我们改代码。
   * 写入走 commit() ⇒ PluginSettings.commitField 三步：先试插件 setter（本键无 fnPath ⇒ 跳过）、
   * 再落宿主桶（与插件自己 save_plugin_config 同一个 uuid 桶，s19 起两侧对齐）、
   * 最后补一次通用 onSettingChanged（插件多半没导出，内部忽略）。
   * ★ 生效时机说明写在这里免得后来人误判：哔咔是**每次拼图片地址时现读**这个键
   *   （bundle 偏移 1502 的 await y("image.quality","original") 在 w() 函数体内），
   *   所以改完下一张图就换图床，不需要重启；不像某些插件那样只在 init 读一次。
   */
  private pickQuality(): void {
    const cur: string = this.qualityValue();
    const labels: string[] = [];
    for (let i = 0; i < QUALITY_LABELS.length; i++) {
      labels.push(QUALITY_LABELS[i]);
    }
    labels.push('自己填一个值');
    promptAction.showActionMenu({
      title: IMAGE_QUALITY_LABEL,
      buttons: [
        { text: labels[0], color: Theme.brand },
        { text: labels[1], color: Theme.brand },
        { text: labels[2], color: Theme.brand },
        { text: labels[3], color: Theme.brand }
      ]
    }).then((res: promptAction.ActionMenuSuccessResponse): void => {
      if (res.index === QUALITY_CUSTOM_INDEX) {
        this.openQualityEditor();
        return;
      }
      if (res.index < 0 || res.index >= QUALITY_VALUES.length) {
        return;
      }
      const v: string = QUALITY_VALUES[res.index];
      if (v === cur) {
        this.toast('图片画质：' + this.qualityLabelOf(v) + '（没变）');
        return;
      }
      this.commit(this.qualityField(), v);
    }).catch((e: Error): void => {
      Logger.i('画质选择取消：' + e.message);
    });
  }

  /**
   * 自定义画质值。**复用现有的 edit 浮层**（EditTarget.field 是普通 SettingField，
   * 现造一枚 key/label 齐备的就够用）⇒ 不再新开一层浮层：本页遮罩必须做兄弟层那条约束
   * （EditOverlay 注释里的 stopPropagation 实测）多一层就多一处坑，且这层的输入/确定/取消
   * 三条行为与这里要的完全一致。
   */
  private openQualityEditor(): void {
    const f = new SettingField();
    f.key = IMAGE_QUALITY_KEY;
    f.kind = 'text';
    f.label = IMAGE_QUALITY_LABEL + '（插件自定义值）';
    const t = new EditTarget();
    t.field = f;
    t.text = this.qualityValue();
    t.password = false;
    this.edit = t;
  }

  /** 更新：复用插件商店载荷的 installLatest（要求该行登记过 indexUuid，未登记直接说明）。 */
  private async doUpdate(): Promise<void> {
    const recs: PluginRecord[] = await PluginStore.loadAll(this.ctx());
    let indexUuid: string = '';
    for (let i = 0; i < recs.length; i++) {
      if (recs[i].uuid === this.uuid) {
        indexUuid = recs[i].indexUuid;
        break;
      }
    }
    if (indexUuid.length === 0) {
      this.toast('该插件不是从商店安装的，无法自动更新');
      return;
    }
    this.toast('正在检查更新…');
    try {
      const raw: string = await bundleCall(MGR_NAME, 'installLatest', JSON.stringify([indexUuid]));
      const o: ESObject = jparse(raw);
      const ok: boolean = jbool(o, 'ok', false);
      const ver: string = jstr(o, 'version', '');
      if (!ok) {
        // s37 需求 2：插件自报的 error 原文只进日志（它可能带 URL / 引擎串）。
        const rawErr: string = jstr(o, 'error', '未知错误');
        errLog('[PluginSettings] installLatest', rawErr);
        this.toast(errBriefForScreen(rawErr, '更新失败，请稍后重试'));
        return;
      }
      // installLatest 落盘不自动装载 ⇒ 重新装载本 uuid 才生效
      await PluginSourceRegistry.reloadOne(this.ctx(), this.uuid);
      // v1.3.0：verWarn = 'declared-X>got-Y' ⇒ 实拿低于清单声明时明示，不再静默
      const vw: string = jstr(o, 'verWarn', '');
      let vwNote: string = '';
      if (vw.length > 0) {
        const gt: number = vw.indexOf('>got-');
        vwNote = gt < 0 ? '（清单标注的版本取不到，已装实际可取的版本）'
          : '（注意：清单标注 ' + vw.slice('declared-'.length, gt) + ' 取不到，实际装的是 ' + vw.slice(gt + '>got-'.length) + '）';
      }
      this.toast((ver.length > 0 ? ('已更新到 ' + ver) : '已是最新') + vwNote);
      this.reload();
    } catch (e) {
      // s37 需求 2：同 openWebLogin（见该处注释）。
      const rawUpd: string = errTextOf(e);
      errLog('[PluginSettings] update', rawUpd);
      this.toast(errBriefForScreen(rawUpd, '更新失败，请稍后重试'));
    }
  }

  /** 删除：先卸内存 ⇒ 删文件 ⇒ 清登记 ⇒ 清图源 ⇒ 退页（与 PluginManagerView.deleteRow 同序）。 */
  private async doDelete(): Promise<void> {
    this.confirmDelete = false;
    try {
      await bundleUnload(this.uuid);
    } catch (e) {
      Logger.i('bundleUnload 忽略：' + (e as Error).message);
    }
    try {
      await pluginRemoveFile(this.absPath());
    } catch (e) {
      // s37 需求 2：同 openWebLogin（见该处注释）。
      const rawDel: string = errTextOf(e);
      errLog('[PluginSettings] deleteFile', rawDel);
      this.toast(errBriefForScreen(rawDel, '删除文件失败，请稍后重试'));
      return;
    }
    await PluginStore.remove(this.ctx(), this.uuid);
    PluginSourceRegistry.unregisterOne(this.uuid);
    // 通知发现页刷新图源（与 PluginManagerView 同一个信号）
    const n: number = (AppStorage.get<number>('pluginSourceEpoch') ?? 0) + 1;
    AppStorage.setOrCreate<number>('pluginSourceEpoch', n);
    // s14 第 3 条：兜底不再拿落盘文件名上屏（同 view/plugins/PluginManagerView.ets 的删除 toast 口径）。
    this.toast('已删除 ' + (this.displayName.length > 0 ? this.displayName : '插件'));
    router.back();
  }

  // ---------------- 顶部卡片三态 ----------------

  /**
   * 顶部卡片该出哪一张（BUG-A：真机回归 —— 未登录时整块登录入口消失，只剩「暂无用户信息」）。
   *
   * 回归成因：s8 把外层条件从 canShowUserInfo && userInfoKeys.length > 0 放宽成 canShowUserInfo
   * （为了让「能显示用户信息但组里被凭据剔空」也出卡片），但没动 else if (canLogin) —— 于是
   * canShowUserInfo=true 且未登录（userInfo 空）的插件走进第一支渲染占位卡，登录卡片整块不可达，
   * 用户没有任何入口登录，形成死锁。真机 JmComic(0.0.7) 与 bikaComic 两张截图都是这一现场。
   *
   * 三档严格优先级（与上游 plugin_settings_content.dart 的 userInfoSection / loginSection 同序）：
   *  'info'        已登录且信息组里真有可展示的键 ⇒ 用户信息卡（登录态优先于登录入口，HEAD 语义）；
   *  'login'       未登录（或只剩凭据键）但插件支持登录 ⇒ 登录卡；这一档必须排在占位卡之前，
   *                否则就退回 BUG-A；
   *  'placeholder' 不支持登录、但声明能显示用户信息且组为空 ⇒ 保留 s8 那条「暂无用户信息」占位；
   *  ''            三者皆无 ⇒ 顶部不出卡（只出下面设置项/能力/管理区）。
   * 返回空串表示不出卡；'info' 与 'placeholder' 共用信息卡壳（build 里再二选一）。
   */
  private topCardMode(): string {
    if (this.bundle.canShowUserInfo && this.userInfoKeys.length > 0) {
      return 'info';
    }
    if (this.bundle.canLogin) {
      return 'login';
    }
    if (this.bundle.canShowUserInfo) {
      return 'placeholder';
    }
    return '';
  }

  // ---------------- 取值/文案 ----------------

  /**
   * 取当前值（**出口统一过 cleanDisplayValue**，真机 BUG-B）。**方法名绝不能叫 valueOf**：
   * struct 里把私有方法命名成 Object 的成员（valueOf/toString/hasOwnProperty…）会让「本 struct
   * 赋给形参 Object」的调用全部报 `10505001 Argument of type 'PluginSettingsPage' is not
   * assignable to parameter of type 'Object'. Property 'valueOf' is private in type ...`
   * （s5i 首编实测：一条命名错炸出 16 条 ERROR，且报错行号落在 @State 声明区，完全看不出是命名问题）。
   *
   * 为什么在出口清洗（BUG-B 的根因位）：插件把「没填过」序列化成引号字面量 —— 未登录时 JmComic 的
   * auth.account 存的就是两个双引号（长度 2）。上一轮只洗了登录表单初值（data/source/PluginLogin.ets），
   * 设置页这一路没洗 ⇒ fieldSub 的「空串才显示未设置」判不空 ⇒ 把两个引号当用户名原样上屏。
   * 清洗放**出口**而不是各调用点：本方法有 7 个消费方（isOn、choiceLabel、multiLabel、pickOption、
   * pickMulti、openEditor、fieldSub 与 ForEach 的 key），逐点包必漏一个。规则与登录侧同一份实现
   * （util/DisplayValue.ets），不在这里另立标准。
   */
  private valOf(field: SettingField): string {
    const v: string | undefined = this.bundle.values.get(field.key);
    return v === undefined ? '' : cleanDisplayValue(v);
  }

  private isOn(field: SettingField): boolean {
    const v: string = this.valOf(field);
    return v === 'true' || v === '1';
  }

  /** choice 的显示文案：拿 value 反查 label（上游 selectedLabel 同款）。 */
  private choiceLabel(field: SettingField): string {
    const v: string = this.valOf(field);
    for (let i = 0; i < field.options.length; i++) {
      if (field.options[i].value === v) {
        return field.options[i].label;
      }
    }
    return v.length > 0 ? v : '未选择';
  }

  private multiLabel(field: SettingField): string {
    const v: string = this.valOf(field);
    if (v.length === 0) {
      return '未选择';
    }
    try {
      const p: ESObject = JSON.parse(v);
      if (Array.isArray(p)) {
        const n: number = (p as ESObject[]).length;
        return n === 0 ? '未选择' : (n + ' 项');
      }
    } catch (e) {
      // 非 JSON 就当单值
    }
    return v;
  }

  private fieldSub(field: SettingField): string {
    const k: string = field.kind;
    if (k === 'switch') {
      return this.isOn(field) ? '已启用' : '已关闭';
    }
    if (k === 'select' || k === 'choice') {
      return this.choiceLabel(field);
    }
    if (k === 'multiChoice') {
      return this.multiLabel(field);
    }
    if (k === 'password') {
      const v: string = this.valOf(field);
      if (v.length === 0) {
        return '未设置';
      }
      let stars: string = '';
      const n: number = v.length > 12 ? 12 : v.length;
      for (let i = 0; i < n; i++) {
        stars += '*';
      }
      return stars;
    }
    // 普通项（含 BUG-B 的 auth.account「用户名」）：valOf 出口已清洗 ⇒ 引号字面量洗成空串 ⇒ 显示「未设置」。
    const v2: string = this.valOf(field);
    return v2.length > 0 ? v2 : '未设置';
  }

  /**
   * 从 userInfo 里挑用户名（要求5）。**按归一化后缀 + 优先级**找：键归一（normalizeDisplayKey）后
   * 命中 USERNAME_KEY_SUFFIXES 的某一条后缀就算候选，靠前的后缀先赢（同一后缀有多个键时按
   * userInfo 的键序取第一个清洗后非空的）。
   *
   * 与旧 userLine 的两处实质差别：
   *  ① 旧版是**精确等值**名单（userName/name/nickname/user/account/email），插件写 user_name、
   *     auth.account、displayName 就全落空 ⇒ 走 keys[0] 兜底，把 uid 之类的值当用户名上屏；
   *     现按归一后缀匹配，这几种写法都能命中。
   *  ② 旧版兜底「取 keys[0]」= 用户抱怨的「拿一个不相干的原始字段顶上来」。现**删掉该兜底**，
   *     取不到就返回空串，由调用方（onBundleChanged）落「已登录」通用保底行 —— 用户明确写了
   *     「禁止找不到就把所有键全铺出来」，取第一个键是同一毛病的单键版。
   * 值仍过 cleanDisplayValue（BUG-B 同一份实现），与 onBundleChanged 筛键集同判据。
   */
  private usernameFrom(keys: string[]): string {
    for (let i = 0; i < USERNAME_KEY_SUFFIXES.length; i++) {
      const suffix: string = USERNAME_KEY_SUFFIXES[i];
      for (let j = 0; j < keys.length; j++) {
        const nk: string = normalizeDisplayKey(keys[j]);
        if (nk.length < suffix.length || !nk.endsWith(suffix)) {
          continue;
        }
        const v: string | undefined = this.bundle.userInfo.get(keys[j]);
        const cleaned: string = v === undefined ? '' : cleanDisplayValue(v);
        if (cleaned.length > 0) {
          return cleaned;
        }
      }
    }
    return '';
  }

  /**
   * 卡片上要显示的账号名（要求5 起用，新七条第 4 条改造）。**两级来源，按权威性排**：
   *  ① userInfo 候选键 —— 走 usernameFrom（插件自报的用户信息，最权威，键名归一后按后缀优先级挑）；
   *  ② 可见设置项里「键名像账号键」且清洗后非空的第一项 —— 必须留这二级：JmComic(0.0.7) 这类插件
   *     的 userInfo 根本不带用户名，只在 scheme.sections 给一项「用户名」，只查 ① 就会退成
   *     「卡片只有已登录 + 下面单开一行用户名」= 真机截图现场，也正是本条要消灭的形态。
   * 两处刻意与 dropAccountFields 对齐，避免「借了名又收不掉项」造成同值出现两次：
   *  · groups 传空数组 = 调用方在说「本插件不能由卡片接管账号展示」（闸门不通过，见 onBundleChanged
   *    的 canTakeOver），此时整级跳过；
   *  · 带 fnPath 的项跳过（dropAccountFields 那侧不收它，见其注释 ③），名字也就不从它借。
   * 两级都取不到返回空串，由调用方落「已登录」保底行（绝不回铺原始键）。
   */
  private accountNameFrom(keys: string[], groups: SettingSection[]): string {
    const fromInfo: string = this.usernameFrom(keys);
    if (fromInfo.length > 0) {
      return fromInfo;
    }
    for (let i = 0; i < groups.length; i++) {
      const fields: SettingField[] = groups[i].fields;
      for (let j = 0; j < fields.length; j++) {
        const f: SettingField = fields[j];
        if (f.fnPath.length > 0 || !looksLikeUsernameKey(normalizeDisplayKey(f.key))) {
          continue;
        }
        const v: string = this.valOf(f); // 出口已过 cleanDisplayValue ⇒ 上屏就是它
        if (v.length > 0) {
          return v;
        }
      }
    }
    return '';
  }

  /**
   * 把设置列表里与「卡片账号」同键的可编辑项收掉（不再重复单开用户名一项）。
   * s15 第 6 条（2026-11-13 用户拍板的口径 A）：**信息卡接管账号展示之后，凡是与登录所用键
   * 同名 / 同键（looksLikeUsernameKey）且不带 fnPath 的可编辑项一律不再出现在卡片下方**。
   * 与旧判据的关系：旧的那条「清洗后值与卡片账号名相等（忽略大小写）才收」是**本判据的特例**
   * —— 值非空且与卡片同名时两版都收；新判据多收的是「值为空」那一档。现场就是这一档：插件的
   * 账号项是纯持久化字段、登录后也不回写值，旧判据里 v.length > 0 不成立 ⇒ 永远留在卡片下方，
   * 用户看到的就是「已经登录了，下面还挂着一行空的、可以改的用户名」（屏幕上写「未设置」）。
   * 两条前提都在调用点（见 onBundleChanged 里 infoMode / switchable / canTakeOver 那段），本函数
   * 不再自造第三个条件，也不再看卡片名是否非空：
   *  ① 只有 canTakeOver = infoMode && switchable 成立时才会调到本函数。卡片没接管（未登录、
   *    插件没自报用户信息、或用户另无登出出路）时根本不调用 ⇒ 那一行照旧可编辑，绝不会把
   *    用户唯一的改账号入口搬掉（switchable 防锁死闸门的理由不变）。
   *  ② **带 fnPath 的项一律不收**：那是上游契约里明给的服务端 setter（例：更新简介 = account.slogan
   *    + fnPath updateProfile + persist:false），收了就是替插件把功能藏了。卡片账号名那侧
   *    （accountNameFrom）同判据跳过带 fnPath 的项，两边对齐 ⇒ 既不会借了名又收不掉项，也不会收了项却没借到名。
   * 卡片侧的空值形态（硬约束③）：userCardLine 本来就是 cardName 非空才拼「已登录 · 名字」、
   * 否则只显「已登录」（见 onBundleChanged 末尾），所以收掉一个空值项不会在卡片上留空白行。
   * 口径核对（别照直觉写）：isCredentialKey('auth.account') **返回 false**（两档口径 —— 'auth' 弱
   *   命中但 'account' 在 IDENTIFIER_SEGMENTS 里 ⇒ 判非凭据），所以账号项**在**可见表里、会被这里收；
   *   被 BUG3-b 提前剔掉的是 password/token/cookie 那类强凭据段，它们本来也不是用户名。
   * 整组被收空就让它整组消失：JmComic 的「账号」组只有用户名一项（密码项已被 BUG3-b 剔掉），
   *   留着判「组里至少保一项」等于在最主要的场景里不做事 —— 用户要的就是这一组不再单开。
   */
  private dropAccountFields(groups: SettingSection[]): SettingSection[] {
    const out: SettingSection[] = [];
    for (let i = 0; i < groups.length; i++) {
      const fields: SettingField[] = groups[i].fields;
      const kept: SettingField[] = [];
      for (let j = 0; j < fields.length; j++) {
        const f: SettingField = fields[j];
        // 唯一判据：不带 fnPath + 键名像账号键 ⇒ 收。不再看值（旧的逐字相等判据已废止，理由见上方注释）。
        if (f.fnPath.length === 0 && looksLikeUsernameKey(normalizeDisplayKey(f.key))) {
          continue;
        }
        kept.push(f);
      }
      if (kept.length === 0) {
        continue;
      }
      if (kept.length === fields.length) {
        out.push(groups[i]);
        continue;
      }
      const g = new SettingSection();
      g.id = groups[i].id;
      g.title = groups[i].title;
      g.fields = kept;
      out.push(g);
    }
    return out;
  }

  // ---------------- UI ----------------

  @Builder
  SectionCard(title: string) {
    if (title.length > 0) {
      Text(title)
        .fontSize(13)
        .fontColor(Theme.text2(this.isDark))
        .width('100%')
        .padding({ left: Dim.pagePadding, top: 16, bottom: 6 })
    }
  }

  @Builder
  FieldRow(field: SettingField) {
    Column() {
      Row() {
        Column() {
          Text(field.label)
            .fontSize(15)
            .fontColor(Theme.text1(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)

          Text(this.fieldSub(field))
            .fontSize(12)
            .fontColor(Theme.text3(this.isDark))
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        if (field.kind === 'switch') {
          Toggle({ type: ToggleType.Switch, isOn: this.isOn(field) })
            .enabled(this.busyKey !== field.key)
            .onChange((on: boolean): void => {
              // 只有用户拨动才写回；回显用的 set 不走这里（Toggle 由 isOn 驱动）
              const cur: boolean = this.isOn(field);
              if (cur !== on) {
                this.commit(field, on ? 'true' : 'false');
              }
            })
        } else if (field.kind === 'select' || field.kind === 'choice' || field.kind === 'multiChoice') {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(Dim.iconSm)
            .fontColor([Theme.text3(this.isDark)])
        } else {
          SymbolGlyph($r('sys.symbol.square_and_pencil'))
            .fontSize(Dim.iconSm)
            .fontColor([Theme.text3(this.isDark)])
        }
      }
      .width('100%')
      .constraintSize({ minHeight: Dim.menuItemH })
      .padding({ top: 10, bottom: 10 })
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      const k: string = field.kind;
      if (k === 'switch') {
        // 开关只由 Toggle 的 onChange 写回：点整行再提交一次会和它撞车
        // （busyKey 虽能吞掉第二次，但 Toggle 视觉态可能与值不一致），故直接返回。
        return;
      }
      if (k === 'multiChoice') {
        this.pickMulti(field);
      } else if (k === 'select' || k === 'choice') {
        this.pickOption(field);
      } else {
        this.openEditor(field, k === 'password');
      }
    })
  }

  @Builder
  ManageRow(title: string, sub: string, danger: boolean, onTap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(danger ? Theme.error : Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        if (sub.length > 0) {
          Text(sub)
            .fontSize(12)
            .fontColor(Theme.text3(this.isDark))
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .margin({ top: 3 })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(Dim.iconSm)
        .fontColor([Theme.text3(this.isDark)])
    }
    .width('100%')
    .constraintSize({ minHeight: Dim.menuItemH })
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
    .clickEffect({ level: ClickEffectLevel.LIGHT })
    .onClick(() => {
      onTap();
    })
  }

  /**
   * 浮层三件套取值器。
   * @Builder 体内不适合写 `this.edit.field.label` 这种「可空属性的连续访问」——
   * ArkTS 的窄化只在同一表达式内生效（this.edit 是 @State 可变属性），
   * 一律走这三个方法把可空性挡在方法里。
   */
  private editLabel(): string {
    const t = this.edit;
    return t === null ? '' : t.field.label;
  }

  private editText(): string {
    const t = this.edit;
    return t === null ? '' : t.text;
  }

  private editIsPassword(): boolean {
    const t = this.edit;
    return t !== null && t.password;
  }

  /**
   * 文本输入浮层。
   * ⚠ 遮罩与卡片必须是**兄弟层**（Stack 的两个子节点），不能把 onClose 挂在外层容器上：
   *   本 SDK 的 ClickEvent **没有 stopPropagation**（component/common.d.ts 的 ClickEvent 只有
   *   globalDisplayX/Y、displayX/Y、windowX/Y 六个成员，s5i 首编实测 `Property 'stopPropagation'
   *   does not exist on type 'ClickEvent'`），挂外层会让点输入框/确定键冒泡把浮层直接关掉。
   */
  @Builder
  EditOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.edit = null;
        })

      Column() {
        Text(this.editLabel())
          .fontSize(16)
          .fontColor(Theme.text1(this.isDark))
          .margin({ bottom: 12 })
          .width('100%')
          .textAlign(TextAlign.Start)

        TextInput({ text: this.editText(), placeholder: '请输入' })
          .type(this.editIsPassword() ? InputType.Password : InputType.Normal)
          .fontSize(15)
          .height(44)
          .backgroundColor(Theme.fillColor(this.isDark))
          .borderRadius(8)
          .onChange((v: string): void => {
            const t = this.edit;
            if (t !== null) {
              t.text = v;
            }
          })

        Row() {
          Text('取消')
            .fontSize(15)
            .fontColor(Theme.text2(this.isDark))
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.edit = null;
            })
          Blank()
          Text('确定')
            .fontSize(15)
            .fontColor(Theme.brand)
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              const t = this.edit;
              if (t === null) {
                return;
              }
              this.edit = null;
              // password 模式不预填现值（见 openEditor）⇒ 用户没输入就点确定 = 取消，
              // 绝不能把空串当新值提交，那等于静默清掉已保存的凭据。
              if (t.password && t.text.length === 0) {
                return;
              }
              // s33 需求 4：画质这键**不能留空**。留空不等于「恢复默认」——插件侧是
              // await y("image.quality","original") 这种取法（偏移 1502），空串取到的是空串不是
              // 缺省值，而它只做 值 !== "original" 的二选一 ⇒ 空串会被当成「走压缩图床」，
              // 且空串过不了 hasQuality 的非空判据，这行会自己消失、用户再也改不回来。
              if (t.field.key === IMAGE_QUALITY_KEY && t.text.trim().length === 0) {
                this.toast('这里不能留空。想要原图请填 ' + IMAGE_QUALITY_DEFAULT);
                return;
              }
              // 画质档顺手 trim：插件是字符串全等比较，多一个空格就落到压缩图床那侧。
              this.commit(t.field, t.field.key === IMAGE_QUALITY_KEY ? t.text.trim() : t.text);
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
          title: this.displayName.length > 0 ? this.displayName : '插件设置',
          showBack: true,
          scrollProgress: 1,
          // 新七条第 7 条（lead 裁定 11-12 17:00）：全站路由页统一打开 flatBackground —— 顶栏实底档与本页根容器
          // 同吃 Theme.background，消除「顶栏一块色、页面一块色」的两块皮。开关默认 false，一级页不受影响。
          flatBackground: true,
          onBack: (): void => {
            router.back();
          }
        })

        if (this.loading) {
          LoadingView({ text: '正在读取插件设置…' })
            .layoutWeight(1)
        } else if (this.loadError.length > 0) {
          ErrorView({
            msg: this.loadError,
            onRetry: (): void => {
              this.reload();
            }
          })
            .layoutWeight(1)
        } else {
          Scroll() {
            Column() {
              // ---- 用户信息 / 登录提示（上游 userInfoSection / loginSection）----
              // 三态由 topCardMode() 单点裁决：有用户信息出信息卡 → 否则能登录出登录卡 →
              // 否则出「暂无用户信息」占位卡（BUG-A 修的就是第二档以前被第一档吃掉）。
              // 这里刻意只用两张卡片壳：'info' 与 'placeholder' 的标题、壳、内边距完全相同，
              // 合用同一个 Column 容器、内部按模式二选一，避免同一段壳复制三份。
              if (this.topCardMode() === 'login') {
                this.SectionCard('登录')
                Column() {
                  // s17 第 2 条：独立 @Component 而不是 this.ManageRow —— 后者的形参是按值快照的，
                  // 登录态变了这一行的样不会刷（本项目三处实证）。savedCount 走 @Prop 随 @State 刷新。
                  PluginLoginRow({
                    title: this.bundle.loginTitle.length > 0 ? this.bundle.loginTitle : '账号登录',
                    baseSub: this.bundle.loginSubtitle.length > 0 ? this.bundle.loginSubtitle : '点击登录插件账号',
                    savedCount: this.loginSavedCount,
                    verified: this.loginVerified,
                    onOpen: (): void => {
                      this.openLogin();
                    }
                  })
                }
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
                .backgroundColor(Theme.cardColor(this.isDark))
                .borderRadius(Dim.radius)
                .margin({ left: Dim.pagePadding, right: Dim.pagePadding })
              } else if (this.topCardMode().length > 0) {
                // 上游 content.dart:237-311：canShowUserInfo 为真就出卡片，
                // 组里有什么取决于 userInfo —— 空（或只剩凭据被剔完）时是「暂无用户信息」，
                // 不是不出卡片。BUG3-b 要的正是这里：登录成功后这一屏显示用户信息，
                // 永不出密码项（凭据键已在 onBundleChanged 挡掉）。
                this.SectionCard('用户信息')
                Column() {
                  if (this.topCardMode() === 'info') {
                    // 独立 @Component（同 PluginVersionRow）：登录返回后同键集换值也要刷新
                    PluginUserInfoRow({
                      lineText: this.userCardLine,
                      canLogout: this.canLogout,
                      logoutBusy: this.logoutBusy,
                      onLogout: (): void => {
                        this.confirmLogout();
                      }
                    })
                  } else {
                    Text('暂无用户信息')
                      .fontSize(14)
                      .fontColor(Theme.text3(this.isDark))
                      .width('100%')
                      .textAlign(TextAlign.Start)
                      .padding({ top: 10, bottom: 10 })
                  }
                }
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
                .backgroundColor(Theme.cardColor(this.isDark))
                .borderRadius(Dim.radius)
                .margin({ left: Dim.pagePadding, right: Dim.pagePadding })
              }

              // ---- 插件自定设置（上游 settingSections，在上）----
              // 遍历 viewSections（= bundle.sections 去掉凭据类字段后的派生列表，见 onBundleChanged）
              if (this.viewSections.length > 0) {
                ForEach(this.viewSections, (sec: SettingSection) => {
                  this.SectionCard(sec.title)
                  Column() {
                    ForEach(sec.fields, (f: SettingField) => {
                      this.FieldRow(f)
                    }, (f: SettingField) => sec.id + '_' + f.key + '_' + this.valOf(f))
                  }
                  .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
                  .backgroundColor(Theme.cardColor(this.isDark))
                  .borderRadius(Dim.radius)
                  .margin({ left: Dim.pagePadding, right: Dim.pagePadding })
                }, (sec: SettingSection) => sec.id + '_' + sec.fields.length)
              } else if (!this.bundle.canLogin) {
                Column() {
                  Text('该插件未提供设置项')
                    .fontSize(14)
                    .fontColor(Theme.text2(this.isDark))
                    .margin({ top: 8 })
                }
                .width('100%')
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 20, bottom: 8 })
              }

              // ---- 能力动作（上游 actionsSection）----
              if (this.capabilityActions.length > 0) {
                this.SectionCard('能力')
                Column() {
                  // 喂派生数组 capabilityActions（不是 bundle.actions）：与卡片登出行重复的那条已在
                  // onBundleChanged 里隐掉；key 仍用 fnPath（动作组内 fnPath 唯一，数据层已去过空值）。
                  // s15 第 8 条：副文案改走 actionSub(a) —— 原先这里直接把 a.fnPath 当副文案上屏，
                  // 用户看到的是一串内部函数名（截图里那行 startEhentaiWebLogin）。fnPath 只当 key 用。
                  ForEach(this.capabilityActions, (a: CapabilityAction) => {
                    this.ManageRow(a.title, this.actionSub(a), false, (): void => {
                      this.runAction(a);
                    })
                  }, (a: CapabilityAction) => a.fnPath)
                }
                .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
                .backgroundColor(Theme.cardColor(this.isDark))
                .borderRadius(Dim.radius)
                .margin({ left: Dim.pagePadding, right: Dim.pagePadding })
              }

              // ---- 宿主管理区（上游 managementSection，沉底）----
              this.SectionCard('插件管理')
              Column() {
                // 第 5 条(1)：行分隔线删除 —— 卡片底色与页面底色已有层次，不再画明显分割线，行距由 ManageRow 上下 padding 提供
                // BUG4：独立 @Component（@Prop 随状态刷新）；@Builder 版会把文案定格在首帧的「未知」
                PluginVersionRow({
                  subText: '当前版本 ' + (this.pluginVersion.length > 0 ? this.pluginVersion : '未知')
                })
                this.ManageRow('图片反混淆', '部分图源把漫画页切成横向条带并倒序存放（画面看起来是花屏）。'
                  + '当前：' + this.jmLabel,
                  false, (): void => {
                    this.pickJmMode();
                  })
                // s33 需求 4：画质兜底行。只在「插件认这个键、但没在设置列表里自报这一项」时出现
                // （判定与原因见 onBundleChanged 里 declared / hasQ 那段），所以不能无条件渲染。
                if (this.hasQuality) {
                  PluginQualityRow({
                    subText: '当前：' + this.qualityLabel,
                    onTap: (): void => {
                      this.pickQuality();
                    }
                  })
                }
                this.ManageRow('更新', '从插件商店重新拉取最新版本并覆盖当前文件',
                  false, (): void => {
                    this.doUpdate();
                  })
                this.ManageRow('删除插件', '彻底删除插件文件，并清除其配置与图源',
                  true, (): void => {
                    this.confirmDelete = true;
                  })
              }
              .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
              .backgroundColor(Theme.cardColor(this.isDark))
              .borderRadius(Dim.radius)
              .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

              // s14 第 3 条（2026-11-13 用户裁定：面向他人使用，UI 少给实现细节）：这里原本把
              // 落盘文件名（形如 uuid前段-标签.bundle.cjs）居中打在管理卡片下方。文件名是纯实现细节，
              // 既不给用户信息也无从核对 ⇒ 整条撤下，只留原来的底部留白。文件名仍在 hilog 里。
              Column()
                .width('100%')
                .height(28)
            }
            .width('100%')
          }
          .layoutWeight(1)
          .scrollBar(BarState.Off)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')

      if (this.edit !== null) {
        this.EditOverlay()
      }

      if (this.confirmDelete) {
        // 同款兄弟层结构（EditOverlay 注释里的原因）：遮罩是独立一层，卡片是另一层，
        // 外层 Stack 默认 alignContent=Center ⇒ 卡片自然居中，且点卡片不会关掉对话框。
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('rgba(0,0,0,0.45)')
          .onClick(() => {
            this.confirmDelete = false;
          })

        Column() {
          Text('确认删除该插件？')
            .fontSize(17)
            .fontColor(Theme.text1(this.isDark))
            .margin({ bottom: 10 })
          Text('此操作将删除插件文件及其配置数据，且不可恢复。')
            .fontSize(13)
            .fontColor(Theme.text2(this.isDark))
            .textAlign(TextAlign.Center)
            .lineHeight(20)
          Row() {
            Text('取消')
              .fontSize(15)
              .fontColor(Theme.text2(this.isDark))
              .padding(10)
              .onClick(() => {
                this.confirmDelete = false;
              })
            Blank()
            Text('删除')
              .fontSize(15)
              .fontColor(Theme.error)
              .padding(10)
              .onClick(() => {
                this.doDelete();
              })
          }
          .width('100%')
          .margin({ top: 16 })
        }
        .width('80%')
        .padding(22)
        .backgroundColor(Theme.cardColor(this.isDark))
        .borderRadius(Dim.radius)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
