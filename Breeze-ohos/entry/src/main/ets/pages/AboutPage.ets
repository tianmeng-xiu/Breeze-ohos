/**
 * 职责：关于页（第 11 条路由 pages/AboutPage）—— 应用名、版本、仓库入口，加上 README 里的免责声明与许可声明。
 * 入口：第 9 条合并后 =「更多」页「关于」分组唯一一行「关于」；底部页脚改成纯文案不再跳页（同页入口只留一项）。
 * 版式：顶部大卡（图标 + 应用名 + 副标题 + 版本）→「应用」分组（可点的行）→「项目性质」「与上游的关系」
 *      「责任限制」「许可」四段。卡片、行高、字号全部复用 view/common/Theme 的 Theme 与 Dim 令牌，
 *      浅色深色两套都成立。按第 5 条(1) 口径**整页不画 Divider**：卡片底色与页面底色已有层次，段距由 padding 给。
 * 文案来源（硬性）：逐条取自仓库根 README.md「声明与免责」「许可」两节与 NOTICE.md 的许可表，
 *      只搬文件里真实写过的内容，不自行新增承诺或声明。README/NOTICE 里点名的模型名**不搬进代码**
 *      （本仓库口径：模型名只允许出现在 md，代码与注释一律不写）。
 * 版本：bundleManager.getBundleInfoForSelf 取 versionName（另带 versionCode 作构建号），**不硬编码版本号**；
 *      取不到回落 FAILED_VERSION（读取中与读取失败两种占位分开），构建号取不到就不显示那一段。
 * 隐藏入口：C13 的「连点版本 5 次开开发者诊断」（AppStorage diagGate）随版本行一起搬到本页，
 *      顶部卡的版本行与「应用」分组的版本行都接它。
 * 仓库跳转：先 ctx.openLink（官方为打开链接准备的入口，@since 12），失败退隐式 Want（viewData +
 *      entity.system.browsable），两级都失败才 toast 并把地址念出来；全程写日志，不静默。
 */
import { promptAction, router } from '@kit.ArkUI';
import { bundleManager, common, Want } from '@kit.AbilityKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { Logger } from '../util/Logger';

/** 仓库地址（与 README、NOTICE 头部一致；点击后用系统浏览器打开）。 */
const REPO_URL: string = 'https://github.com/tianmeng-xiu/Breeze-ohos';
/** 仓库地址的短显示形式（行内不铺满整行）。 */
const REPO_LABEL: string = 'github.com/tianmeng-xiu/Breeze-ohos';
/** 还没取到 versionName 时的占位（不写死具体版本号，避免与真实包不一致）。 */
const UNKNOWN_VERSION: string = '读取中';
/** bundleManager 读取失败时的终值：与「读取中」区分开，别把失败显示成还在读。 */
const FAILED_VERSION: string = '未知';

/** 上游与第三方来源的一行（NOTICE.md §1、§2 台账，页面三列显示）。 */
class UpstreamRow {
  name: string = '';
  lic: string = '';
  note: string = '';

  constructor(name: string, lic: string, note: string) {
    this.name = name;
    this.lic = lic;
    this.note = note;
  }
}

/** 许可台账：许可名与「0 处逐段借鉴」这类结论都照 NOTICE.md 原文写，不做改写。 */
const UPSTREAMS: UpstreamRow[] = [
  new UpstreamRow('Breeze（Flutter 原版）', 'MPL-2.0',
    '未复制任何 Dart 源码，仅按其接口事实在 ArkTS 与 Rust 里重新实现'),
  new UpstreamRow('NextE（HarmonyOS）', 'MIT',
    '交互范式与 UI 版式参考，截至本版本 0 处逐段借鉴'),
  new UpstreamRow('qingye-reader（HarmonyOS）', 'GPL-3.0',
    '交互设计参考，截至本版本 0 处逐段借鉴'),
  new UpstreamRow('Breeze-plugin-list 插件索引', '各插件自定',
    '运行时向该索引发 HTTP 请求拉插件列表；索引条目与插件的合法性由维护者与插件作者负责'),
  new UpstreamRow('随源码分发的第三方组件', 'MIT、Apache-2.0 等',
    'rquickjs-sys 补丁副本、内嵌 quickjs-ng、Temporal polyfill 等，各自保留原始许可文本，不得删除')
];

@Entry
@Component
struct AboutPage {
  @StorageProp('isDark') isDark: boolean = false;
  /** versionName（bundleManager 异步取，空串 = 还没取到） */
  @State versionText: string = '';
  /** versionCode 构建号；空串 = 没取到，整段不显示 */
  @State buildText: string = '';
  /** C13 隐藏入口：连点计数与时间戳（从「更多」页随版本行一起搬过来） */
  private verTaps: number = 0;
  private verLastTap: number = 0;

  aboutToAppear(): void {
    this.loadVersion();
  }

  /** 版本号：DEFAULT flag 已带 versionName 与 versionCode，不必叠 appInfo。 */
  private loadVersion(): void {
    bundleManager.getBundleInfoForSelf(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT)
      .then((info: bundleManager.BundleInfo): void => {
        const vn: string = info.versionName ?? '';
        this.versionText = vn;
        const vc: number = info.versionCode;
        this.buildText = vc > 0 ? String(vc) : '';
      })
      .catch((e: Object): void => {
        Logger.ex('bundleManager 读版本号失败', e);
        this.versionText = FAILED_VERSION;
        this.buildText = '';
      });
  }

  /** 版本行文案：构建号取不到就只出版本号，两段都取不到给占位。 */
  private versionLine(): string {
    const v: string = this.versionText.length > 0 ? this.versionText : UNKNOWN_VERSION;
    if (this.buildText.length > 0) {
      return '版本 ' + v + '（构建 ' + this.buildText + '）';
    }
    return '版本 ' + v;
  }

  /**
   * 系统浏览器打开仓库。Want 在 SDK 里是 export default class（纯字段声明、无运行时实现），
   * 所以按官方文档形态写类型化对象字面量：字段名与类型都对得上已声明的 Want ⇒ 不触发 10605038，
   * 也不会出现 new Want() 运行时「不是构造器」的风险。没有浏览器或被拦截都 toast，不静默失败。
   */
  /**
   * 打开仓库主页。两级：先走官方为「打开链接」准备的 openLink（UIAbilityContext.d.ts:300，@since 12，
   * 其注释 :257-258 指定必须能匹配到带 entity.system.browsable 的浏览器），失败再退隐式 Want，
   * 两级都失败才 toast —— 目标是「点了要么开起来、要么说清楚」，绝不静默。
   */
  private openRepo(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.openLink(REPO_URL).catch((e1: Object): void => {
      Logger.ex('openLink 打开失败，回退隐式 Want', e1);
      // 回退用 @ohos.ability.wantConstant.d.ts 的原文常量：:195 ACTION_VIEW_DATA =
      // 'ohos.want.action.viewData'、:286 ENTITY_BROWSABLE = 'entity.system.browsable'。
      // Want 在 SDK 里是 d.ts 的 export default class（只有字段声明、无运行时构造器），
      // 所以按官方文档形态写「类型化对象字面量」，不要改成 new Want()（运行时没有构造器会炸）。
      const want: Want = {
        action: 'ohos.want.action.viewData',
        entities: ['entity.system.browsable'],
        uri: REPO_URL
      };
      ctx.startAbility(want).catch((e2: Object): void => {
        Logger.ex('隐式 Want 打开仓库也失败', e2);
        this.toast('没找到可打开链接的浏览器，仓库地址：' + REPO_URL);
      });
    });
  }

  /** C13 隐藏入口：连点计数与提示。第 3 次起给递减提示，第 5 次开闸（AppStorage diagGate）。 */
  private onTapVersion(): void {
    const now: number = Date.now();
    if (now - this.verLastTap > 1500) {
      this.verTaps = 0;
    }
    this.verLastTap = now;
    const opened: boolean = AppStorage.get<boolean>('diagGate') ?? false;
    if (opened) {
      this.toast('诊断入口已开启');
      return;
    }
    this.verTaps += 1;
    const left: number = 5 - this.verTaps;
    if (left <= 0) {
      AppStorage.setOrCreate<boolean>('diagGate', true);
      this.verTaps = 0;
      this.toast('开发者诊断已开启');
      return;
    }
    if (left <= 3) {
      this.toast('再点 ' + left + ' 次开启开发者诊断');
    }
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  /** 分组标题（与 pages/SettingPage.ets 的 SectionCard 同规格）。 */
  @Builder
  SectionCard(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Theme.text2(this.isDark))
      .width('100%')
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 16, bottom: 6 })
      .textAlign(TextAlign.Start)
  }

  /** 说明段：13 号正文 + 20 行高；段间距只靠 padding（本模块不画分割线）。 */
  @Builder
  Para(text: string) {
    Text(text)
      .fontSize(13)
      .fontColor(Theme.text2(this.isDark))
      .lineHeight(20)
      .width('100%')
      .textAlign(TextAlign.Start)
      .padding({ top: 12, bottom: 12 })
  }

  /**
   * 名称 + 取值 + 可选箭头。取值必须是取值函数：@Builder 形参按值传递、值变了不重渲染
   * （本仓踩过三次，见 view/mine/MinePage.ets 与 pages/SettingPage.ets 的同类注释）。
   * 版本号是异步取的，只有在 Text 节点内调用才会把 @State 记成该节点的依赖。
   * 注：形参名不叫 valueOf —— 那是 Object.prototype 的保留名（本仓已把它列进保留名清单）。
   */
  @Builder
  InfoRow(label: string, subOf: () => string, chevron: boolean, onTap: () => void) {
    Row() {
      Text(label)
        .fontSize(15)
        .fontColor(Theme.text1(this.isDark))
        .margin({ right: 12 })
      Text(subOf())
        .fontSize(13)
        .fontColor(Theme.text2(this.isDark))
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
        .textAlign(TextAlign.End)
      if (chevron) {
        Text('›')
          .fontSize(18)
          .fontColor(Theme.text3(this.isDark))
          .margin({ left: 8 })
      }
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

  /** 许可台账一行：名称 + 许可（品牌色）+ 说明。 */
  @Builder
  UpstreamItem(it: UpstreamRow) {
    Column() {
      Row() {
        Text(it.name)
          .fontSize(14)
          .fontColor(Theme.text1(this.isDark))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(it.lic)
          .fontSize(12)
          .fontColor(Theme.brand)
          .margin({ left: 8 })
      }
      .width('100%')

      Text(it.note)
        .fontSize(12)
        .fontColor(Theme.text3(this.isDark))
        .lineHeight(18)
        .width('100%')
        .textAlign(TextAlign.Start)
        .margin({ top: 3 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Column() {
      BreezeTopBar({
        title: '关于',
        showBack: true,
        scrollProgress: 1,
        // 新七条第 7 条（lead 裁定 11-12 17:00）：全站路由页统一打开 flatBackground —— 顶栏实底档与本页根容器
        // 同吃 Theme.background，消除「顶栏一块色、页面一块色」的两块皮。开关默认 false，一级页不受影响。
        flatBackground: true,
        onBack: (): void => {
          router.back();
        }
      })

      Scroll() {
        Column() {
          // ---- 顶部卡：图标 + 应用名 + 副标题 + 版本（版本行兼作 C13 隐藏入口） ----
          Column() {
            Row() {
              // 图标与真机统一（s10 第 10 条提出 → s12 第 4 条结案，两次都动这行，口径以本注释为准）。
              // 旧引用 app.media.ic_app 是**封面兜底图**（192x256 非方形、浅灰底 + 小书本），跟启动器上看到的
              // 图标不是同一张 —— 这是「关于页图标和实际图标不统一」的原始根因。
              // s10 曾换成启动器合成的 app.media.layered_image（background.png 纯蓝底 + foreground.png 白色书本），
              // 理由 = 与启动器逐像素同源（LayeredDrawableDescriptor，@ohos.arkui.drawableDescriptor.d.ts:161-188）。
              // **s12 真机实测该改法不成立**：Image 组件里 layered_image 渲染成整块纯白（截图量算 = 图标区
              // (150,330)-(400,560) 内 54,453 个像素全是 (255,255,255)，而 app_icon.png 主色是 (10,89,247) 蓝
              // 66,548 像素）⇒ 启动器会自己合成 background+foreground，Image 组件不会，只拿到那层 JSON 描述符
              // 就画了个空。**结论：Image 组件必须引用成品位图 app_icon**（与 startIcon 逐字节相同、同一造型）。
              // module.json5:16 的 icon 仍是 layered_image —— 那是启动器用途（启动器会合成），**不要跟着改**。
              // 21 张 media png 是出包红线，一个字节未动，只换引用。borderRadius 复刻启动器的圆角遮罩。
              Image($r('app.media.app_icon'))
                .width(64)
                .height(64)
                .borderRadius(14)

              Column() {
                Text('Breeze')
                  .fontSize(20)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(Theme.text1(this.isDark))
                  .width('100%')
                  .textAlign(TextAlign.Start)
                Text('HarmonyOS NEXT 漫画阅读器 · 个人移植项目')
                  .fontSize(12)
                  .fontColor(Theme.text2(this.isDark))
                  .lineHeight(18)
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .margin({ top: 4 })
                Text(this.versionLine())
                  .fontSize(12)
                  .fontColor(Theme.text3(this.isDark))
                  .width('100%')
                  .textAlign(TextAlign.Start)
                  .margin({ top: 6 })
                  .clickEffect({ level: ClickEffectLevel.LIGHT })
                  .onClick(() => {
                    this.onTapVersion();
                  })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              .margin({ left: 14 })
            }
            .width('100%')
            .padding({ top: 16, bottom: 16 })
            .alignItems(VerticalAlign.Center)
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
          .backgroundColor(Theme.cardColor(this.isDark))
          .borderRadius(Dim.radius)
          .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

          // ---- 应用：可点的行 ----
          this.SectionCard('应用')
          Column() {
            this.InfoRow('开源仓库', (): string => {
              return REPO_LABEL;
            }, true, (): void => {
              this.openRepo();
            })
            this.InfoRow('版本', (): string => {
              return this.versionLine();
            }, false, (): void => {
              this.onTapVersion();
            })
            this.InfoRow('运行环境', (): string => {
              return 'HarmonyOS · API 26 · 手机';
            }, false, (): void => {
            })
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
          .backgroundColor(Theme.cardColor(this.isDark))
          .borderRadius(Dim.radius)
          .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

          // ---- 项目性质（README 声明与免责 §1、§4） ----
          this.SectionCard('项目性质')
          Column() {
            this.Para('本项目纯属娱乐性质的个人业余项目，同时也是对当前 AI 编码能力边界的一次探索。'
              + '作者本人不是专业开发者，也不是相关行业从业者；项目整体由 AI 工具完成，因此应被理解为'
              + '一份 AI 生成结果的公开样本，而不是一个经过专业工程评审的软件产品。代码质量、安全性、'
              + '正确性与可维护性均未作任何保证。')
            this.Para('项目处于初始阶段，存在很多 BUG。已知与未知的问题都很多；是否修复、如何修复、'
              + '何时修复均待定，作者保留在不通知的情况下修改、暂停或终止本项目的权利。')
            this.Para('本项目不含任何图源内容（不内置、不分发、也不代查任何漫画内容或图源站点），'
              + '也不提供、不托管、不推荐任何漫画内容或图源。使用者应仅将本项目用于个人学习与技术交流，'
              + '并遵守所在国家或地区的法律法规。插件引擎依赖系统网络与设备能力，异常使用可能影响设备'
              + '或账号状态，风险自负。')
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
          .backgroundColor(Theme.cardColor(this.isDark))
          .borderRadius(Dim.radius)
          .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

          // ---- 与上游的关系（README §3 + NOTICE §1、§2、§3） ----
          this.SectionCard('与上游的关系')
          Column() {
            this.Para('本仓库是个人移植项目，与 Breeze、NextE、qingye-reader 的原作者无隶属关系，'
              + '也未获得任何授权、背书或认可；提及这些项目仅为说明移植来源与设计参考。')
            ForEach(UPSTREAMS, (it: UpstreamRow) => {
              this.UpstreamItem(it)
            }, (it: UpstreamRow) => it.name)
            this.Para('插件由第三方作者独立开发与分发，其功能、内容、合法性、安全性与可用性完全由插件作者负责；'
              + '插件内容与使用责任由插件作者与使用者承担，与本项目及作者无关。本项目依赖的第三方库、工具'
              + '与服务，作者不对其内容、功能、安全性或合法性负责，使用风险由使用者自行评估与承担。')
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
          .backgroundColor(Theme.cardColor(this.isDark))
          .borderRadius(Dim.radius)
          .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

          // ---- 责任限制（README §2 + NOTICE §6.3） ----
          this.SectionCard('责任限制')
          Column() {
            this.Para('本项目以「原样（AS IS）」提供，作者不作任何形式的担保，包括但不限于适销性、'
              + '特定用途适用性、不侵犯第三方权利、无错误、无中断运行、内容准确性与安全性。')
            this.Para('作者不对本项目承担任何责任：没有义务持续更新，没有义务修复任何 BUG，'
              + '没有义务实现任何被提出的功能，也没有义务提供技术支持、答疑、适配新机型或新系统版本。'
              + '对因使用、复制、修改、分发本项目而产生的任何直接、间接、特殊、附带或后果性损害'
              + '（含数据丢失、设备损坏或变砖、账号被封禁、阅读记录或下载内容丢失、网络费用、业务中断、'
              + '利润损失）不承担任何责任。')
            this.Para('用户应自行评估适用性并承担全部使用风险。若上游项目或第三方权利人认为本仓库存在不当之处，'
              + '请在仓库开 Issue 说明，作者会在力所能及的范围内处理，但同样不承诺时限。')
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
          .backgroundColor(Theme.cardColor(this.isDark))
          .borderRadius(Dim.radius)
          .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

          // ---- 许可（README「许可」节 + NOTICE 开头与 §4） ----
          this.SectionCard('许可')
          Column() {
            this.Para('代码本体以 GPL-3.0（或稍后版本，GPL-3.0-or-later）发布，全文见仓库根目录 LICENSE；'
              + '来源、许可表与随源码分发的第三方组件见 NOTICE.md，vendored 目录各自保留原始许可文本，'
              + '不得删除。')
            this.Para('GPL-3.0 授予你复制、分发、修改的自由；同时上面的「原样提供、无担保、无支持义务」'
              + '与 GPL 第 16 条（WARRANTY DISCLAIMER）及第 17 条（LIMITATION OF LIABILITY）一致适用。'
              + '任何分发行为均须同时携带上述许可文本与免责声明。')
            this.InfoRow('完整声明与许可全文', (): string => {
              return REPO_LABEL;
            }, true, (): void => {
              this.openRepo();
            })
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
          .backgroundColor(Theme.cardColor(this.isDark))
          .borderRadius(Dim.radius)
          .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

          Text('使用本应用前，请先读完仓库 README 的「声明与免责」一节')
            .fontSize(11)
            .fontColor(Theme.text3(this.isDark))
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ top: 18, bottom: Dim.contentBottomReserve })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
