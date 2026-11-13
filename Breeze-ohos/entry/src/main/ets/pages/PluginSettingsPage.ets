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
 */
import { promptAction, router } from '@kit.ArkUI';
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
import { PluginLoginParams } from '../data/source/PluginLogin';
import { WebLoginParams } from '../data/source/WebLogin';
import { PluginStore, PluginRecord } from '../util/PluginStore';
import { PluginSourceRegistry } from '../data/source/PluginSourceRegistry';
import { PluginImageOps } from '../data/source/PluginImageOps';
import { PLUGIN_SOURCE_PREFIX } from '../data/source/PluginSourceAdapter';
import { JmMode } from '../data/image/JmDeobfuscate';
import { bundleCall, bundleUnload, pluginRemoveFile } from '../util/PluginRuntime';
import { jstr, jbool, jnum, jparse, jobj, jhas, jisEmpty, jstrArr } from '../util/JsonUtil';
import { cleanDisplayValue, normalizeDisplayKey } from '../util/DisplayValue';
import { Logger } from '../util/Logger';

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

    // 要求5 + 新七条第 4 条：主行「已登录 · 账号名」（账号名跟在登录态后面同一行）；
    // 两级来源都取不到才落「已登录」保底行（绝不回铺原始键）。
    this.userCardLine = cardName.length > 0 ? ('已登录 · ' + cardName) : '已登录';
  }

  private absPath(): string {
    return this.ctx().filesDir + '/plugins/' + this.localFile;
  }

  private toast(msg: string): void {
    try {
      promptAction.showToast({ message: msg, duration: 2200 });
    } catch (e) {
      Logger.i('toast 失败：' + msg);
    }
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
      this.loadError = loadErr;
      this.loading = false;
      return;
    }
    // 2. 全量载入设置
    const b: PluginSettingsBundle = await PluginSettings.load(this.ctx(), this.uuid);
    this.bundle = b;
    if (b.error.length > 0) {
      this.loadError = b.error;
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
      this.toast(err);
      return;
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
    this.toast('正在执行：' + action.title);
    this.rawAction(action).then((r: RawActionResult): void => {
      if (!r.ok) {
        // 失败仍只 toast：与改前的 catch 分支同文案、同样不刷 bundle（没成功就没必要重读）
        this.toast(r.msg);
        return;
      }
      if (this.tryOpenWeb(r.root)) {
        return;
      }
      this.toast(r.msg);
      if (action.fnPath === RELOGIN_FN) {
        this.openLogin();
      }
      // 动作可能改了设置（清会话/重载线路）⇒ 静默刷一次
      if (this.bundle.hasSettings) {
        PluginSettings.load(this.ctx(), this.uuid).then((b: PluginSettingsBundle): void => {
          this.bundle = b;
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
      r.msg = '执行失败：' + (e as Error).message;
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
      .catch((err: Error): void => {
        this.toast('打开网页登录失败：' + err.message);
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
      .catch((err: Error): void => {
        this.toast('打开登录页失败：' + err.message);
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
        }).catch((_e: Object): void => {});
      }).catch((e: Object): void => {
        this.logoutBusy = false;
        this.toast('退出失败：' + (e as Error).message);
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
        this.toast('更新失败：' + jstr(o, 'error', '未知错误'));
        return;
      }
      // installLatest 落盘不自动装载 ⇒ 重新装载本 uuid 才生效
      await PluginSourceRegistry.reloadOne(this.ctx(), this.uuid);
      this.toast(ver.length > 0 ? ('已更新到 ' + ver) : '已是最新');
      this.reload();
    } catch (e) {
      this.toast('更新失败：' + (e as Error).message);
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
      this.toast('删除文件失败：' + (e as Error).message);
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
              this.commit(t.field, t.text);
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
                  this.ManageRow(
                    this.bundle.loginTitle.length > 0 ? this.bundle.loginTitle : '账号登录',
                    this.bundle.loginSubtitle.length > 0 ? this.bundle.loginSubtitle : '点击登录插件账号',
                    false,
                    (): void => {
                      this.openLogin();
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
