/**
 * 职责：云收藏页（一级 Tab 2）—— 选一个插件源站，把它站端的云端收藏同步进本地书架。
 *       对应 report.txt 第 11 条（2026-11-12）：在插件内登录账号后，自动同步该源站云端收藏至本地。
 *       原先这页是 WebDAV 占位页（整页删掉重写，占位文案已无意义：上游鸿蒙端无 WebDAV 计划）。
 * 依赖：StateViews / Theme / Anim；data/cloud/CloudFavoriteSync（能力探测 + 同步）。
 *       公共顶栏由 pages/Index.ets 统一提供，本页不自绘顶栏。
 * 对应 Flutter：上游把云端收藏做成场景包直接渲染；鸿蒙端按用户口径改成「同步进本地书架」，
 *       因此本页只负责选源 + 触发 + 结果反馈，列表一律看书架（避免两份收藏两张皮）。
 * 约束：
 *  - 本页是 TabContent 子组件，router.back 回来不重跑 aboutToAppear ⇒ 图源变化统一接 AppStorage
 *    的 pluginSourceEpoch（bump 端 = view/plugins/PluginManagerView）。
 *  - **不接 shelfRevision 的 @Watch**（本页不是书架列表，收到版本号无事可做）；反过来同步成功后
 *    由本页推 shelfRevision，让书架页静默重查（推 = 只写 AppStorage 数字，本页不订阅 ⇒ 无回环）。
 *  - 能力探测要等数据层就绪（图源是 initDataLayer 里注册的），所以进页面先等 pluginSourceEpoch，
 *    没有就在下一次 epoch 变化时再探；绝不在 aboutToAppear 里同步阻塞式探测。
 *  - s11 第 2/3 条三条硬约束（都是真机回传逼出来的，勿改回）：
 *    ① 忙闲必须走 @State（status），**不得用私有 boolean 喂 .enabled()/.visibility()**：
 *       非状态变量的变化不触发重渲染 ⇒ 探测早就结束了，「开始同步」还停在 disabled 的旧渲染结果上
 *       = 用户看到的「同步始终为灰色，无法进行同步」。busy() 现在只读 status。
 *    ② 探测整批有上限（CloudFavoriteSync.PROBE_BATCH_MS），且探测路径零网络 ⇒ 「重新检查」不可能无限转。
 *    ③ chip 名优先插件自己 getInfo 报的名字（纯本地缓存，零网络），退清单名，再退文件名派生名
 *       = 用户看到的「bf99008d-0.0.7」是最后一档，不是插件设定的名字。
 */

import { Theme, Dim } from '../common/Theme';
import { Anim } from '../common/Anim';
import { EmptyView } from '../common/StateViews';
import { TabAutoHide } from '../common/TabAutoHide';
import { common } from '@kit.AbilityKit';
import { CloudCapability, CloudFavoriteSync, CloudSyncResult } from '../../data/cloud/CloudFavoriteSync';
import { PLUGIN_SOURCE_PREFIX } from '../../data/source/PluginSourceAdapter';
import { PluginInfo, PluginSettings } from '../../data/source/PluginSettings';
import { Logger } from '../../util/Logger';

// 整批探测上限的权威值在 data/cloud/CloudFavoriteSync（PROBE_BATCH_MS=12000）。
// 旧版这里另有一份 40000 且全文没用到 = 「重新检查持续加载」没有上限的成因之一，s11 删掉。

export class CloudPageStatus {
  static readonly IDLE: string = 'idle';
  static readonly PROBING: string = 'probing';
  static readonly SYNCING: string = 'syncing';
  static readonly DONE: string = 'done';
  static readonly FAILED: string = 'failed';
}

@Component
export struct CloudPage {
  onRequestTab: (index: number) => void = (index: number) => {};

  @StorageProp('isDark') isDark: boolean = false;
  /** 图源变化（安装/删除/开关/装载）⇒ 清探测缓存重探。 */
  @StorageProp('pluginSourceEpoch') @Watch('onSourceEpoch') pluginEpoch: number = 0;

  /** 支持云收藏的源站（探测结果，顺序 = 图源表顺序）。 */
  @State caps: CloudCapability[] = [];
  @State sourceIndex: number = 0;
  @State status: string = CloudPageStatus.IDLE;
  /** 结果/错因文案（失败也走它，页内常驻显示，不靠 toast 一闪而过）。 */
  @State message: string = '';
  /** 同步中的实时条数。 */
  @State liveCount: number = 0;

  /** s10 第 11 条：纵向内容区绑 scroller —— Scroll.onDidScroll 只给每帧增量，判方向要读累计偏移。 */
  private bodyScroller: Scroller = new Scroller();

  /**
   * 在途闸门：**必须是普通字段**（防止 TabContent 反复进出时并发发起），
   * 但它绝不参与 UI 判定 —— UI 只看 @State status（见文件头约束①）。
   */
  private probing: boolean = false;
  /** 同上：同步在途闸门，不参与 UI 判定。 */
  private syncing: boolean = false;
  /** chip 展示名（key = sourceId）：插件 getInfo 的本地缓存名优先。 */
  private displayNames: Map<string, string> = new Map<string, string>();

  aboutToAppear(): void {
    // T1：登记本页滚动容器（页索引 2 = 云收藏）；纵向 Scroll 在 if 分支里可能晚于此处挂载，
    // 故挂载处再补一次 attach（attach 内部按 scroller 去重，重复调用无副作用）。
    TabAutoHide.attach(TabAutoHide.IDX_CLOUD, this.bodyScroller);
    this.detect();
  }

  private onSourceEpoch(): void {
    // 插件装卸 ⇒ 能力可能凭空出现或消失，缓存必须作废。
    CloudFavoriteSync.forgetProbes();
    this.detect();
  }

  /** 忙闲口径 = @State status（**不看私有 boolean**，理由见文件头约束①）。 */
  private busy(): boolean {
    return this.status === CloudPageStatus.PROBING || this.status === CloudPageStatus.SYNCING;
  }

  /** chip 展示名：本地缓存的 getInfo.name → 清单名 → 文件名派生名（第三档 = 真机截图那种）。 */
  private nameOf(cap: CloudCapability): string {
    const hit: string | undefined = this.displayNames.get(cap.sourceId);
    if (hit !== undefined && hit.length > 0) {
      return hit;
    }
    return cap.name;
  }

  private cur(): CloudCapability | null {
    if (this.sourceIndex < 0 || this.sourceIndex >= this.caps.length) {
      return null;
    }
    return this.caps[this.sourceIndex];
  }

  /** 探测所有插件源站的云收藏能力（结果只保留 supported 的）。 */
  private async detect(): Promise<void> {
    if (this.probing) {
      return;
    }
    this.probing = true;
    this.status = CloudPageStatus.PROBING;
    this.message = '';
    try {
      const all: CloudCapability[] = await CloudFavoriteSync.listCapabilities();
      const ok: CloudCapability[] = [];
      let pending: number = 0;
      for (let i = 0; i < all.length; i++) {
        if (all[i].supported) {
          ok.push(all[i]);
        } else if (all[i].via === 'pending' || all[i].via === 'timeout') {
          // 两种「这次没答上」：整批到点仍是占位（pending）、单源声明读取超时（timeout）。
          // 都不等于「不支持」：本轮不显示，但文案要说清楚，否则用户以为插件装少了，
          // 而且这两类下次「重新检查」还会再探（timeout 不进缓存）。
          pending += 1;
        }
      }
      Anim.to((): void => {
        this.caps = ok;
        this.sourceIndex = 0;
        this.status = CloudPageStatus.IDLE;
        if (pending > 0) {
          this.message = '还有 ' + pending + ' 个插件没及时回应，可点「重新检查」再看一次。';
        }
      }, Anim.contentIn, Anim.curveEaseOut());
      Logger.i('云收藏能力探测：支持 ' + ok.length + '/' + all.length + ' 个插件源，未回应 ' + pending + ' 个');
      // 名字解析排在状态落回之后：chip 先按清单名出现，本地缓存名到了再换（不发网络，基本同一帧）。
      await this.resolveNames(ok);
    } catch (err) {
      Logger.ex('云收藏能力探测异常', err as Object);
      this.status = CloudPageStatus.FAILED;
      this.message = (err as Error).message;
    } finally {
      this.probing = false;
      // 兜底：status 仍停在 PROBING 说明上面两条路都没落回（极端：Anim.to 未执行）。
      // status 是唯一忙闲口径，卡在这里 = 同步按钮永久灰 = 真机回传的第三条。
      if (this.status === CloudPageStatus.PROBING) {
        this.status = CloudPageStatus.IDLE;
      }
    }
  }

  /**
   * 读每个源插件 getInfo 的**本地缓存**名字（PluginSettings.cachedInfo 纯读 preferences，零网络零装载）。
   * 缓存里没有就不写，chip 继续用清单名/文件名派生名 —— 绝不为了名字去现调 getInfo（那要走网络）。
   */
  private async resolveNames(caps: CloudCapability[]): Promise<void> {
    if (caps.length === 0) {
      return;
    }
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    let changed: boolean = false;
    for (let i = 0; i < caps.length; i++) {
      const sid: string = caps[i].sourceId;
      if (sid.indexOf(PLUGIN_SOURCE_PREFIX) !== 0) {
        continue;
      }
      try {
        const info: PluginInfo = await PluginSettings.cachedInfo(ctx, sid.slice(PLUGIN_SOURCE_PREFIX.length));
        if (info.name.length > 0 && info.name !== caps[i].name) {
          this.displayNames.set(sid, info.name);
          changed = true;
        }
      } catch (e) {
        Logger.d('云收藏读插件缓存名失败 ' + sid);
      }
    }
    if (changed) {
      // Map 不是状态变量：靠重排 caps 触发 ForEach 重渲染（key 里带上名字，见 build）。
      this.caps = caps.slice();
    }
  }

  /** 上次同步情况（一句话；从未同步返回空串）。 */
  private lastLine(): string {
    const c: CloudCapability | null = this.cur();
    if (c === null) {
      return '';
    }
    const at: number = CloudFavoriteSync.lastSyncAt(c.sourceId);
    const n: number = CloudFavoriteSync.lastSyncCount(c.sourceId);
    if (at <= 0) {
      return '';
    }
    const d: Date = new Date(at);
    const mm: string = (d.getMonth() + 1) < 10 ? '0' + (d.getMonth() + 1) : String(d.getMonth() + 1);
    const dd: string = d.getDate() < 10 ? '0' + d.getDate() : String(d.getDate());
    const hh: string = d.getHours() < 10 ? '0' + d.getHours() : String(d.getHours());
    const mi: string = d.getMinutes() < 10 ? '0' + d.getMinutes() : String(d.getMinutes());
    return '上次同步 ' + mm + '-' + dd + ' ' + hh + ':' + mi + '，共 ' + (n < 0 ? '未知' : String(n)) + ' 条';
  }

  /** 触发同步。 */
  private async doSync(): Promise<void> {
    if (this.syncing) {
      return;
    }
    const c: CloudCapability | null = this.cur();
    if (c === null) {
      return;
    }
    this.syncing = true;
    this.status = CloudPageStatus.SYNCING;
    this.liveCount = 0;
    this.message = '';
    try {
      const res: CloudSyncResult = await CloudFavoriteSync.sync(c.sourceId,
        (done: number, pages: number): void => {
          this.liveCount = done;
        });
      if (res.ok) {
        const tail: string = res.reachedEnd ? '' : '（已达本次上限，可再点一次继续）';
        this.status = CloudPageStatus.DONE;
        this.message = '已同步 ' + res.synced + ' 条到书架，其中新增 ' + res.added + ' 条' + tail;
        // 书架页靠 AppStorage 'shelfRevision' 静默重查（同 DetailPage 加/移书架的口径）：真新增了才推。
        if (res.added > 0) {
          const cur: number = AppStorage.get<number>('shelfRevision') ?? 0;
          AppStorage.setOrCreate<number>('shelfRevision', cur + 1);
        }
      } else {
        this.status = CloudPageStatus.FAILED;
        // 未登录等插件自抛的中文提示原样透出，不加前缀（用户要看到插件自己的话）。
        this.message = res.err.length > 0 ? res.err : '同步失败';
      }
    } catch (err) {
      this.status = CloudPageStatus.FAILED;
      this.message = (err as Error).message;
      Logger.ex('云收藏同步按钮异常', err as Object);
    } finally {
      this.syncing = false;
    }
  }

  private statusText(): string {
    if (this.status === CloudPageStatus.PROBING) {
      return '正在检查各插件是否支持云端收藏…';
    }
    if (this.status === CloudPageStatus.SYNCING) {
      return this.liveCount > 0 ? ('正在同步…已写入 ' + this.liveCount + ' 条') : '正在从站端拉取收藏…';
    }
    return this.message;
  }

  @Builder
  SourceChip(i: number) {
    Text(this.nameOf(this.caps[i]))
      .fontSize(13)
      .fontColor(this.sourceIndex === i ? Theme.white : Theme.text1(this.isDark))
      .backgroundColor(this.sourceIndex === i ? Theme.brand : Theme.fillColor(this.isDark))
      .borderRadius(Dim.radius)
      .height(32)
      .padding({ left: 14, right: 14 })
      .margin({ right: 8 })
      .maxLines(1)
      .textAlign(TextAlign.Center)
      .onClick((): void => {
        if (this.sourceIndex !== i) {
          Anim.to((): void => {
            this.sourceIndex = i;
            this.message = '';
            this.status = CloudPageStatus.IDLE;
          }, Anim.contentIn, Anim.curveEaseOut());
        }
      })
  }

  build() {
    Column() {
      if (this.probing && this.caps.length === 0) {
        Column() {
          LoadingProgress()
            .width(40)
            .height(40)
            .color(Theme.brand)
          Text('正在检查各插件是否支持云端收藏…')
            .fontSize(14)
            .fontColor(Theme.text2(this.isDark))
            .margin({ top: 12 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      } else if (this.caps.length === 0) {
        Column() {
          EmptyView({
            text: '还没有插件支持云端收藏',
            hint: '去「更多 - 插件管理」安装或启用带云端收藏的图源插件（如绅士漫画、拷贝漫画、哔咔漫画），并在插件设置里登录账号后回到本页。已安装但不支持的插件不会出现在这里。'
          })
            .layoutWeight(1)
          Button('重新检查')
            .fontSize(14)
            .fontColor(Theme.brand)
            .backgroundColor(Theme.fillColor(this.isDark))
            .height(40)
            .borderRadius(20)
            .padding({ left: 20, right: 20 })
            .margin({ bottom: Dim.contentBottomReserve })
            .onClick((): void => {
              CloudFavoriteSync.forgetProbes();
              this.detect();
            })
        }
        .width('100%')
        .layoutWeight(1)
      } else {
        // 源站选择条（与发现页图源条同款 chip，横向滚动）
        Scroll() {
          Row() {
            ForEach(this.caps, (item: CloudCapability, index: number) => {
              this.SourceChip(index);
            }, (item: CloudCapability) => item.sourceId + '|' + this.nameOf(item))
          }
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding })
        }
        .scrollable(ScrollDirection.Horizontal)
        .scrollBar(BarState.Off)
        .width('100%')
        .height(44)

        Scroll(this.bodyScroller) {
          Column() {
            Text('把所选源站账号里的云端收藏同步进本地书架')
              .fontSize(14)
              .fontColor(Theme.text1(this.isDark))
              .width('100%')
              .textAlign(TextAlign.Start)
            Text('同步只做单向（站端 → 本地）；已在书架的保持原加入时间，不会打乱书架排序。')
              .fontSize(12)
              .fontColor(Theme.text3(this.isDark))
              .width('100%')
              .textAlign(TextAlign.Start)
              .margin({ top: 6 })

            if (this.lastLine().length > 0) {
              Text(this.lastLine())
                .fontSize(12)
                .fontColor(Theme.text3(this.isDark))
                .width('100%')
                .textAlign(TextAlign.Start)
                .margin({ top: 10 })
            }

            Button(this.status === CloudPageStatus.SYNCING ? '同步中…' : '开始同步')
              .fontSize(15)
              .fontColor(Theme.white)
              .backgroundColor(this.busy() ? Theme.text3(this.isDark) : Theme.brand)
              .height(44)
              .borderRadius(22)
              .width('100%')
              .margin({ top: 18 })
              .enabled(!this.busy())
              .onClick((): void => {
                this.doSync();
              })

            if (this.statusText().length > 0) {
              Text(this.statusText())
                .fontSize(13)
                .fontColor(this.status === CloudPageStatus.FAILED ? Theme.warning : Theme.text2(this.isDark))
                .width('100%')
                .textAlign(TextAlign.Start)
                .margin({ top: 12 })
            }

            if (this.status === CloudPageStatus.DONE) {
              Button('去书架查看')
                .fontSize(14)
                .fontColor(Theme.brand)
                .backgroundColor(Theme.fillColor(this.isDark))
                .height(40)
                .borderRadius(20)
                .margin({ top: 12 })
                .onClick((): void => {
                  this.onRequestTab(0);
                })
            }

            if (this.status === CloudPageStatus.FAILED) {
              Button('重试')
                .fontSize(14)
                .fontColor(Theme.brand)
                .backgroundColor(Theme.fillColor(this.isDark))
                .height(40)
                .borderRadius(20)
                .margin({ top: 12 })
                .onClick((): void => {
                  this.doSync();
                })
            }
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ left: Dim.pagePadding, right: Dim.pagePadding, top: 12 })
        }
        .scrollable(ScrollDirection.Vertical)
        .scrollBar(BarState.Off)
        .align(Alignment.Top)
        .layoutWeight(1)
        .contentEndOffset(Dim.contentBottomReserve)
        // T1：Scroll.onDidScroll 只给每帧增量（scroll.d.ts:1400）⇒ 读 scroller 累计偏移喂给 TabAutoHide 判方向
        .onDidScroll((_offset: number, state: ScrollState) => {
          TabAutoHide.onScroll(TabAutoHide.IDX_CLOUD, this.bodyScroller.currentOffset().yOffset, state);
        })
        // T1：本页 Scroll 在 if 分支里，可能晚于 aboutToAppear 那次 attach ⇒ 挂载后补一次联动登记
        .onAppear(() => {
          TabAutoHide.flush();
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
