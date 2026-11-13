/**
 * 职责：s14 第 2 条（用户 report.txt「云收藏不再单列一页，放进『更多』页作为一项，命名『从云端同步』」）
 *       新建的二级路由页 —— 只做「公共顶栏 + 复用 view/cloud/CloudPage」的壳，页体一个字没搬。
 * 依赖：view/common/BreezeTopBar（公共顶栏）、view/cloud/CloudPage（页体，本轮禁改）、Theme、@kit.ArkUI 的 router/promptAction。
 * 入口：pages/Index → 底栏「更多」→ view/mine/MinePage 的「从云端同步」行 → router.pushUrl(本页)。
 *
 * 为什么做成壳而不是把 CloudPage 抄过来：CloudPage 31,973 B / 770 行，能力探测、同步在途闸门、
 *   chip 取名、sanitizeErrText 那套错因脱敏全在里面，抄一份 = 第二份实现两份皮；lead 本轮硬约束
 *   也是「CloudPage.ets 一个字都不要改」⇒ 唯一零风险的接法就是外面套一层顶栏。
 *
 * 顶栏口径（照抄仓内既有路由页，不自绘）：showBack true + onBack 走 router.back，
 *   与 pages/HistoryPage.ets:212-226、pages/SettingPage.ets:562-572 同构；flatBackground true =
 *   s11 第 7 条「全站路由页统一 flatBackground」，顶栏实底与本页根容器同吃 Theme.background；
 *   scrollProgress 给常量 1（路由页顶栏常驻实底，不参与一级页那条透明到实底的斜坡）。
 *
 * 底部留白 72vp 的裁定（lead 11-13）：**接受，不治**。理由 = 那 72vp 是 CloudPage 自己 Scroll 的
 *   contentEndOffset(Dim.contentBottomReserve)（CloudPage.ets:754，常量 = 16 + 56），只在滚到底时
 *   表现为末项之后的一段余量，不是常驻空白条。三种治法都不成立：expandSafeArea 管的是窗口避让区，
 *   碰不到 Scroll 内部的 contentEndOffset；外层负 padding 会让 CloudPage 的 100% 高度按父内容区解析后
 *   反向多出一截，等于把末项推到屏幕外 = 正是 lead 要避免的裁切；盖同色底只是把留白涂成看不见，
 *   高度没变。⇒ 宁可多白，不裁内容，这条进 s14 验收清单。真要根治只能改 CloudPage（不在本轮写域）。
 */

import { promptAction, router } from '@kit.ArkUI';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme } from '../view/common/Theme';
import { CloudPage } from '../view/cloud/CloudPage';

@Entry
@Component
struct CloudSyncPage {
  @StorageProp('isDark') isDark: boolean = false;

  build() {
    Column() {
      BreezeTopBar({
        title: '从云端同步',
        showBack: true,
        scrollProgress: 1,
        flatBackground: true,
        onBack: (): void => {
          router.back();
        }
      })

      // 页体：CloudPage 根容器自带 100% 宽高与 Theme.background 底色，这里只给它顶栏之外的剩余高度
      CloudPage({
        onRequestTab: (_index: number): void => {
          this.goShelf();
        }
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }

  /**
   * CloudPage 的 onRequestTab 语义 = 跳到底栏某页签（唯一消费点 = 同步成功后那颗「去书架查看」，
   * CloudPage.ets:720-731，实参恒 0 = 书架）；本页是 router 页没有底栏页签可跳，因此 back() 回「更多」页
   * 是等价出口；若将来 C 方案（AppStorage pendingTabIndex）落地，只改这一处。
   *
   * 为什么不是空实现：传空函数 = 成功态那颗按钮点下去没反应，用户最容易理解成「同步完卡住」
   * （lead 11-13 裁定选此档，空实现口径已否）。toast 只说界面位置，不含路径与实现细节。
   */
  private goShelf(): void {
    router.back();
    promptAction.showToast({ message: '书架在底栏第一签，已同步的收藏都在那里' });
  }
}
