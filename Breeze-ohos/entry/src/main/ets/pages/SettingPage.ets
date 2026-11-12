/**
 * 职责：宿主级设置页（User-Agent / Cookie / 阅读方向 / 点按翻页 / 外观模式）。
 *      四个死配置键在这里获得唯一 UI 入口：阅读方向（READ_DIRECTION）、放大后点按平移
 *      （READER_TAP_TO_SCROLL）、自定义 User-Agent（USER_AGENT）、Cookie 管理（COOKIE_PREFIX）。
 *      另把「存储」两行从 toast 占位改成真数据（图片缓存占用 / 清理缓存）。
 *      BUG2 修复口径：占用统计走 diskUsageAsync（异步分批 + 批间让帧），失败/未就绪
 *      都是可点重试的文案而不是永远「统计中」；清空后立即重测，并推 cacheRevision
 *      版本号驱动「更多」页存储行重算（两页文案共用 data/image/ImageCache 的 CacheUsageText）。
 *      s9 真机复现（11-12 回传「统计持续失败、点重试无效」）后追加：统计侧的三段时限、
 *      单飞与取消、以及「数不完交部分结果」全在 ImageCache.diskUsageAsync（那里是唯一真源，
 *      本页只负责发起与展示）；本页另加「手动重试失败时 toast 出真实错因」，因为旧文案
 *      只有「统计失败，点此重试」六个字，真机回传一张截图无法定位。
 * 依赖：util/UserSettings（读写与即时生效）、data/net/CookieJar（host 名单与单站清除）、
 *      data/image/ImageCache（磁盘占用与清理）、view/common 目录（顶栏、主题）。
 * 入口：pages/Index → MinePage「通用设置」→ router.pushUrl('pages/SettingPage')。
 *
 * 版式沿用 pages/PluginSettingsPage.ets 已验收的三段范式：分组卡 + ManageRow + 自绘浮层
 * （本 SDK 无 showTextInput，且遮罩与卡片必须是 Stack 兄弟层：ClickEvent 没有 stopPropagation）。
 * 外观（缺陷④ + 要求1，s8 二轮）：三态色档（跟随系统/浅色/深色）在本页有直接选择器，落盘 + setColorMode
 *      走 util/ThemeStore。一轮时「更多」页还留了一行只读状态 + 跳转本页，用户 2026-11-11 22:12 仍判为
 *      重复（两行点进去是同一个页面）⇒ 那行连同整个「外观」分组已从 view/mine/MinePage.ets 撤掉，
 *      **本页是唯一切换入口**；数据源仍是 AppStorage 的 themeMode 一份。
 */
import { promptAction, router } from '@kit.ArkUI';
import { common } from '@kit.AbilityKit';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme, Dim } from '../view/common/Theme';
import { UserSettings, ReadDirection, SettingLabels } from '../util/UserSettings';
import { CookieJar } from '../data/net/CookieJar';
import { ImageCache, DiskUsage, CacheUsageText } from '../data/image/ImageCache';
import { Logger } from '../util/Logger';
import { ThemeStore, ThemeMode, ThemeModeLabels } from '../util/ThemeStore';

/** UA 输入浮层状态（null = 未打开）。 */
class UaEditor {
  text: string = '';
}

@Entry
@Component
struct SettingPage {
  @StorageProp('isDark') isDark: boolean = false;
  /** 三态色档镜像（ThemeStore.apply 写入，切换后本行与选择器一起重绘） */
  @StorageProp('themeMode') themeMode: string = ThemeMode.SYSTEM;

  /** 已存 UA 原文（空串 = 用内置默认） */
  @State uaSaved: string = '';
  /** 当前实际生效的 UA（摘要行展示） */
  @State uaEffective: string = '';
  @State directionLabel: string = SettingLabels.READ_DIRECTION[0];
  @State tapToScroll: boolean = false;
  /** Cookie 站点名单（浮层列表的数据源） */
  @State hosts: string[] = [];
  @State cookiePanel: boolean = false;
  @State uaEdit: UaEditor | null = null;
  /**
   * 图片缓存占用三态（BUG2）：cachePhase 取 CacheUsageText.P_* 之一；
   * bytes/files 只在 P_DONE 下有意义。P_MEASURING 初值 = 进页面第一件事就是「统计中」，
   * 统计失败/目录未就绪都落到可点重试的文案，绝不停在「统计中」。
   */
  @State cachePhase: string = CacheUsageText.P_MEASURING;
  @State cacheBytes: number = 0;
  @State cacheFiles: number = 0;
  /** 统计在途标记：连点与 reload 复用同一次统计，不并发跑两遍 */
  @State cacheBusy: boolean = false;
  /** 统计轮次序号（不进 @State：只用来判迟到，不参与渲染），见 measureCache */
  private measureSeq: number = 0;

  aboutToAppear(): void {
    this.reload();
    // 占用统计与其余字段分开：其余字段都是同步读，统计是异步 I/O，
    // 不该被「改完 UA / 清完 Cookie」这类无关刷新反复触发。
    this.measureCache();
  }

  /** 从存储层刷新全部展示字段（都是同步读，返回本页时也走它拿最新值） */
  private reload(): void {
    const snap = UserSettings.snapshot(CookieJar.getInstance().knownHosts().length);
    this.uaSaved = snap.userAgent;
    this.uaEffective = snap.effectiveUserAgent;
    this.directionLabel = snap.readDirection === ReadDirection.RTL
      ? SettingLabels.READ_DIRECTION[1] : SettingLabels.READ_DIRECTION[0];
    this.tapToScroll = snap.tapToScroll;
    this.hosts = CookieJar.getInstance().knownHosts();
  }

  /**
   * 占用统计（BUG2 真因所在）：旧实现把 diskUsage()（listFileSync + 每文件 statSync）
   * 塞进 setTimeout(16) —— setTimeout 只是延后一帧，整串同步系统调用仍在 UI 线程上跑完，
   * 文件一多就把设置页首帧卡白，且任一次调用抛错时只把数字写成 0，看着像「0 B」而不是失败。
   * 现在走 diskUsageAsync：列举与 stat 都在 native 线程，每 64 个一批、批间让出一帧。
   *
   * 关于「点重试无效」（本轮派工书要我验到底的一条）：本页的 busy 闸门**不是**卡死点 ——
   * 下面 then 与 catch 两条路径都写了 cacheBusy=false，链上没有任何不 settle 的 await
   * （init 内部的 doInit 全程是同步系统调用，必然 settle）。真正「无效」的原因是旧
   * diskUsageAsync 把「20s 超时」判成失败、且超时后不取消旧 walk（withTimeout 用
   * Promise.race 且计时器不 clear）：每次点重试只是再挂一条完整 walk 上去，旧的还在原地
   * 抢同一批文件，越点越慢、每次都撞同一条超时 ⇒ 用户看到的就是「点了没反应，还是失败」。
   * 修法放在唯一真源 ImageCache（单飞复用 + 代数取消 + 软预算交部分结果），
   * 本页只补一条「手动重试失败时把错因弹出来」，自动首测保持安静。
   *
   * fromTap=true 表示这是用户点出来的重试；force=true 供 clearCache 用：
   * clear() 会取消在途统计，但被取消那条要等当前批跑完才 settle、busy 才放开，
   * 清理后的必测若走普通闸门会被「还没 settle 的旧轮」吞掉，于是清理后行内停在旧数。
   * force 直接开新一轮（旧轮因 seq 过期自动作废）；ImageCache 侧是单飞的，
   * 就算真有在途也只是复用它，不会叠第二条 walk。
   */
  private measureCache(fromTap: boolean = false, force: boolean = false): void {
    if (this.cacheBusy && !force) {
      return;
    }
    this.cacheBusy = true;
    this.cachePhase = CacheUsageText.P_MEASURING;
    // 本轮序号：clear() 会取消在途统计，被取消那条仍会在稍后 settle（交部分结果）。
    // 若它晚于清理后的新一轮落地，就会把清理前的旧数字写回来 ⇒ 迟到的旧一轮一律丢弃，
    // cacheBusy 也交给最新那一轮复位（与 ImageCache 侧 recordQuality 的代数守卫同一条思路）。
    const seq: number = this.measureSeq + 1;
    this.measureSeq = seq;
    // 追加 B（cache-fix 报的残留）：ImageCache.init 只排在 DataBootstrap 里，而 EntryAbility
    // 是 fire-and-forget 不 await ⇒ 冷启动直进设置页可能跑到 init 前面，cacheRoot 空串时
    // ensureCacheRoot() 只能返回 false（没 context 算不出 cacheDir），于是「未就绪，点此重试」点了不动。
    // 正解 = 重试点先补一次 init 再统计（init 内部 ready + initPromise 双保险，幂等）；
    // init 失败只记日志继续统计，保持「点了不弹错」，文案仍走 CacheUsageText 三态。
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ImageCache.getInstance().init(ctx)
      .catch((e: Object): void => {
        Logger.ex('补跑 ImageCache.init 失败（继续统计，不弹错）', e);
      })
      .then((): Promise<DiskUsage> => {
        return ImageCache.getInstance().diskUsageAsync();
      })
      .then((u: DiskUsage): void => {
        if (seq !== this.measureSeq) {
          return;
        }
        this.cacheBusy = false;
        this.cacheBytes = u.bytes;
        this.cacheFiles = u.files;
        // ready=false ⇒ 目录仍没建起来，给可重试文案（口径不变）
        this.cachePhase = u.ready ? CacheUsageText.P_DONE : CacheUsageText.P_NOT_READY;
      })
      .catch((err: Object): void => {
        Logger.ex('统计缓存失败', err);
        if (seq !== this.measureSeq) {
          return;
        }
        this.cacheBusy = false;
        // 具体 code 与 message 由 ImageCache.walkUsage 写进 CacheUsageText（两页共用的口径），
        // 行内文案因此带得出错因；toast 只对手动重试弹这一次
        this.cachePhase = CacheUsageText.P_FAILED;
        if (fromTap) {
          this.toast('缓存统计失败：' + ((err as Error).message ?? String(err)));
        }
      });
  }

  /** 存储行摘要（文案口径与「更多」页共用 CacheUsageText） */
  private cacheSummary(): string {
    return CacheUsageText.of(this.cachePhase, this.cacheBytes, this.cacheFiles);
  }

  private uaSummary(): string {
    return this.uaSaved.length > 0 ? this.uaSaved : ('默认：' + this.uaEffective);
  }

  private toast(msg: string): void {
    promptAction.showToast({ message: msg });
  }

  // ---------------- 事件 ----------------

  private pickDirection(): void {
    promptAction.showActionMenu({
      title: '阅读方向',
      buttons: [
        { text: '从左到右（默认）', color: Theme.brand },
        { text: '从右到左（日漫）', color: Theme.brand }
      ]
    }).then(async (res: promptAction.ActionMenuSuccessResponse): Promise<void> => {
      const v: string = res.index === 1 ? ReadDirection.RTL : ReadDirection.LTR;
      await UserSettings.setReadDirection(v);
      this.directionLabel = v === ReadDirection.RTL
        ? SettingLabels.READ_DIRECTION[1] : SettingLabels.READ_DIRECTION[0];
      this.toast(v === ReadDirection.RTL ? '已改为从右到左，重进阅读器生效' : '已改为从左到右');
    }).catch((e: Error): void => {
      Logger.i('阅读方向选择取消：' + e.message);
    });
  }

  private async onToggleTap(e: boolean): Promise<void> {
    try {
      await UserSettings.setTapToScroll(e);
      this.tapToScroll = e;
      this.toast(e ? '放大后点按改为平移画面' : '放大后点按仍为翻页');
    } catch (err) {
      this.toast('保存失败：' + (err as Error).message);
    }
  }

  private openUaEditor(): void {
    const ed: UaEditor = new UaEditor();
    // 预填「已存原文」而不是生效值：生效值含内置默认串，预填它会让「清空恢复默认」变成
    // 「把默认串存成自定义 UA」，两者语义不同（前者删键，后者写键）。
    ed.text = this.uaSaved;
    this.uaEdit = ed;
  }

  private async commitUa(): Promise<void> {
    const ed: UaEditor | null = this.uaEdit;
    this.uaEdit = null;
    if (ed === null) {
      return;
    }
    try {
      await UserSettings.setUserAgent(ed.text);
      this.reload();
      this.toast(ed.text.trim().length === 0 ? '已恢复默认 User-Agent' : 'User-Agent 已保存并立即生效');
    } catch (err) {
      this.toast('保存失败：' + (err as Error).message);
    }
  }

  private async clearAllCookies(): Promise<void> {
    this.cookiePanel = false;
    try {
      await CookieJar.getInstance().clear();
      this.reload();
      this.toast('已清除全部 Cookie');
    } catch (err) {
      this.toast('清除失败：' + (err as Error).message);
    }
  }

  private async removeOneHost(host: string): Promise<void> {
    try {
      await CookieJar.getInstance().removeHost(host);
      this.hosts = CookieJar.getInstance().knownHosts();
      this.toast('已清除 ' + host);
    } catch (err) {
      this.toast('清除失败：' + (err as Error).message);
    }
  }

  /**
   * 清空图片缓存：clear() 现在自身异步分批，且列举失败会抛出（旧实现吞异常 ⇒
   * 「清了但还在」却报成功）。成功后立刻重测并推 cacheRevision 让「更多」页同步。
   */
  private async clearCache(): Promise<void> {
    try {
      await ImageCache.getInstance().clear();
      // force：此刻被 clear 取消的旧轮可能还没 settle，普通闸门会把这次必测吞掉
      this.measureCache(false, true);
      ImageCache.bumpCacheRevision();
      this.toast('已清空图片缓存');
    } catch (err) {
      // 清理失败不改动已显示的占用数字，只提示；重测一次让数字与磁盘现状对齐。
      // 这里同样要 force：clear() 首行已取消在途统计，那条旧轮没 settle 前 busy 还是 true。
      this.measureCache(false, true);
      this.toast('清理失败：' + (err as Error).message);
    }
  }

  // ---------------- 视图 ----------------

  /** 下标 → 色档字面量（ALL 的顺序 = ThemeModeLabels.ALL：跟随系统 / 浅色 / 深色）。 */
  private modeAt(idx: number): string {
    if (idx === 1) {
      return ThemeMode.LIGHT;
    }
    if (idx === 2) {
      return ThemeMode.DARK;
    }
    return ThemeMode.SYSTEM;
  }

  /** 选档：落盘 + setColorMode + AppStorage 三处一起（详见 util/ThemeStore 头注释）。 */
  private pickMode(mode: string): void {
    if (mode === this.themeMode) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ThemeStore.setMode(ctx, mode, ThemeStore.sysDark(ctx))
      .catch((e: Object): void => {
        Logger.ex('切换外观模式失败', e);
      });
  }

  @Builder
  SectionCard(title: string) {
    Text(title)
      .fontSize(13)
      .fontColor(Theme.text2(this.isDark))
      .width('100%')
      .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 16, bottom: 6 })
      .textAlign(TextAlign.Start)
  }

  /**
   * 标题 + 摘要 + 右箭头（与插件设置页同款）。
   * ⚠ 摘要必须是**取值函数**而不是字符串：@Builder 形参按值传递、值变了不重渲染
   *   （本仓已两次踩过并写下注释：CommentPage.ets:28「收起回复点击后 UI 不动」、
   *   DetailPage.ets:601「点赞成功后文案定格在旧值」）。真机 BUG2「永远统计中」
   *   除了同步统计卡主线程之外，还有这一层：统计完了指纹也刷不到这一行上。
   *   取值函数在 Text 节点内调用 ⇒ 读到的 @State 会记成该节点的依赖（与 isDark
   *   在本页各 Text 里生效是同一套机制），统计完成才能立刻换文案。
   */
  @Builder
  ManageRow(title: string, subOf: () => string, danger: boolean, onTap: () => void) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(danger ? Theme.error : Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        if (subOf().length > 0) {
          Text(subOf())
            .fontSize(12)
            .fontColor(Theme.text3(this.isDark))
            .margin({ top: 3 })
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
            .textAlign(TextAlign.Start)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('›')
        .fontSize(18)
        .fontColor(Theme.text3(this.isDark))
        .margin({ left: 8 })
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

  @Builder
  SwitchRow(title: string, sub: string, isOn: boolean) {
    Row() {
      Column() {
        Text(title)
          .fontSize(15)
          .fontColor(Theme.text1(this.isDark))
          .width('100%')
          .textAlign(TextAlign.Start)
        Text(sub)
          .fontSize(12)
          .fontColor(Theme.text3(this.isDark))
          .margin({ top: 3 })
          .width('100%')
          .textAlign(TextAlign.Start)
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(Theme.brand)
        .onChange((v: boolean): void => {
          // 开关的 onChange 会随外部刷新重复回调，只在值真的变了才落库
          if (v !== this.tapToScroll) {
            this.onToggleTap(v);
          }
        })
    }
    .width('100%')
    .constraintSize({ minHeight: Dim.menuItemH })
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  /** UA 输入浮层（与插件设置页 EditOverlay 同构：遮罩与卡片是 Stack 兄弟层） */
  @Builder
  UaOverlay() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.uaEdit = null;
        })

      Column() {
        Text('自定义 User-Agent')
          .fontSize(16)
          .fontColor(Theme.text1(this.isDark))
          .margin({ bottom: 6 })
          .width('100%')
          .textAlign(TextAlign.Start)

        Text('仅影响 ArkTS 宿主侧请求（图源接口、插件商店与更新检查）；插件内部请求由插件自己决定。'
          + '留空 = 恢复内置默认。')
          .fontSize(12)
          .fontColor(Theme.text3(this.isDark))
          .lineHeight(18)
          .width('100%')
          .textAlign(TextAlign.Start)
          .margin({ bottom: 12 })

        TextInput({ text: this.uaEditText(), placeholder: this.uaEffective })
          .fontSize(14)
          .height(44)
          .backgroundColor(Theme.fillColor(this.isDark))
          .borderRadius(8)
          .onChange((v: string): void => {
            const ed: UaEditor | null = this.uaEdit;
            if (ed !== null) {
              ed.text = v;
            }
          })

        Row() {
          Text('取消')
            .fontSize(15)
            .fontColor(Theme.text2(this.isDark))
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.uaEdit = null;
            })
          Blank()
          Text('清空')
            .fontSize(15)
            .fontColor(Theme.warning)
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              const ed: UaEditor | null = this.uaEdit;
              if (ed !== null) {
                ed.text = '';
              }
              this.commitUa();
            })
          Text('确定')
            .fontSize(15)
            .fontColor(Theme.brand)
            .padding(10)
            .margin({ left: 6 })
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.commitUa();
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

  /** 可空 @State 在 @Builder 内一律走取值器（窄化只在同一表达式内生效） */
  private uaEditText(): string {
    const ed: UaEditor | null = this.uaEdit;
    return ed === null ? '' : ed.text;
  }

  /** Cookie 管理浮层 */
  @Builder
  CookiePanel() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('rgba(0,0,0,0.45)')
        .onClick(() => {
          this.cookiePanel = false;
        })

      Column() {
        Row() {
          Text('已保存 Cookie 的站点')
            .fontSize(16)
            .fontColor(Theme.text1(this.isDark))
            .layoutWeight(1)
          Text('全部清除')
            .fontSize(14)
            .fontColor(Theme.error)
            .padding(6)
            .onClick(() => {
              this.clearAllCookies();
            })
        }
        .width('100%')
        .margin({ bottom: 8 })

        if (this.hosts.length === 0) {
          Text('暂无记录。登录或访问需要会话的站点后会自动出现在这里。')
            .fontSize(13)
            .fontColor(Theme.text2(this.isDark))
            .lineHeight(20)
            .width('100%')
            .padding({ top: 6, bottom: 10 })
        } else {
          Scroll() {
            Column() {
              ForEach(this.hosts, (h: string) => {
                Row() {
                  Text(h)
                    .fontSize(14)
                    .fontColor(Theme.text1(this.isDark))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .layoutWeight(1)
                  Text('清除')
                    .fontSize(13)
                    .fontColor(Theme.error)
                    .padding(6)
                    .onClick(() => {
                      this.removeOneHost(h);
                    })
                }
                .width('100%')
                .height(Dim.menuItemH)
                .alignItems(VerticalAlign.Center)
              }, (h: string) => h)
            }
            .width('100%')
          }
          .height(280)
          .scrollBar(BarState.Auto)
        }

        Row() {
          Blank()
          Text('关闭')
            .fontSize(15)
            .fontColor(Theme.brand)
            .padding(10)
            .clickEffect({ level: ClickEffectLevel.LIGHT })
            .onClick(() => {
              this.cookiePanel = false;
            })
        }
        .width('100%')
        .margin({ top: 6 })
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
          title: '设置',
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
            // ---- 外观 ----
            this.SectionCard('外观')
            Column() {
              Text('界面深浅色。选「跟随系统」时随系统深浅色变化，手选两档会盖住系统设置')
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
                .width('100%')
                .padding({ top: 12 })
                .textAlign(TextAlign.Start)
              Row() {
                ForEach(ThemeModeLabels.ALL, (label: string, idx: number) => {
                  Text(label)
                    .fontSize(14)
                    .fontColor(this.modeAt(idx) === this.themeMode ? Theme.white : Theme.text1(this.isDark))
                    .textAlign(TextAlign.Center)
                    .height(36)
                    .layoutWeight(1)
                    .backgroundColor(this.modeAt(idx) === this.themeMode ? Theme.brand : Theme.fillColor(this.isDark))
                    .borderRadius(8)
                    .margin({ right: idx === ThemeModeLabels.ALL.length - 1 ? 0 : 8 })
                    .clickEffect({ level: ClickEffectLevel.LIGHT })
                    .onClick(() => {
                      this.pickMode(this.modeAt(idx));
                    })
                }, (label: string) => label)
              }
              .width('100%')
              .margin({ top: 10, bottom: 12 })
            }
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            .backgroundColor(Theme.cardColor(this.isDark))
            .borderRadius(Dim.radius)
            .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

            // ---- 阅读 ----
            this.SectionCard('阅读')
            Column() {
              this.ManageRow('阅读方向',
                (): string => {
                  return '当前：' + this.directionLabel + '。从右到左适合日漫，翻页键位会左右互换';
                },
                false, (): void => {
                  this.pickDirection();
                })
            }
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            .backgroundColor(Theme.cardColor(this.isDark))
            .borderRadius(Dim.radius)
            .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

            this.SectionCard('阅读器手势')
            Column() {
              this.SwitchRow('放大后点按平移',
                '开启后，图片放大时点左/右侧改为平移画面；未放大时仍按方向翻页',
                this.tapToScroll)
            }
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            .backgroundColor(Theme.cardColor(this.isDark))
            .borderRadius(Dim.radius)
            .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

            // ---- 网络 ----
            this.SectionCard('网络')
            Column() {
              this.ManageRow('自定义 User-Agent',
                (): string => {
                  return this.uaSummary();
                },
                false, (): void => {
                  this.openUaEditor();
                })
              // 第 5 条(1)：卡片底色与页面底色已有层次，不再画明显分割线，行距由 padding 提供
              this.ManageRow('Cookie',
                (): string => {
                  return this.hosts.length === 0 ? '暂无记录' : (this.hosts.length + ' 个站点');
                },
                false, (): void => {
                  this.cookiePanel = true;
                })
            }
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            .backgroundColor(Theme.cardColor(this.isDark))
            .borderRadius(Dim.radius)
            .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

            // ---- 存储 ----
            this.SectionCard('存储')
            Column() {
              this.ManageRow('图片缓存',
                (): string => {
                  return this.cacheSummary();
                },
                false, (): void => {
                  // 点按 = 用户显式重试 ⇒ 失败要把错因弹出来（fromTap）
                  this.measureCache(true);
                })
              // 第 5 条(1)：卡片底色与页面底色已有层次，不再画明显分割线，行距由 padding 提供
              this.ManageRow('清空图片缓存',
                (): string => {
                  return '清掉已下载的图片文件，阅读记录与书架不受影响';
                },
                true, (): void => {
                  this.clearCache();
                })
            }
            .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
            .backgroundColor(Theme.cardColor(this.isDark))
            .borderRadius(Dim.radius)
            .margin({ left: Dim.pagePadding, right: Dim.pagePadding })

            Text('设置保存后立即生效，无需重启')
              .fontSize(11)
              .fontColor(Theme.text3(this.isDark))
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 16, bottom: Dim.contentBottomReserve })
          }
          .width('100%')
        }
        .layoutWeight(1)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
      }
      .width('100%')
      .height('100%')

      if (this.uaEdit !== null) {
        this.UaOverlay()
      }

      if (this.cookiePanel) {
        this.CookiePanel()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
