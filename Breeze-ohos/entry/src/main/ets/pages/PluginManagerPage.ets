/**
 * 职责：插件管理路由页（二级页，S4 最小闭环）—— 公共顶栏 + PluginManagerView。
 * 依赖：view/common/BreezeTopBar、view/plugins/PluginManagerView。
 * 入口：pages/Index 底栏「更多」→ MinePage「插件管理」→ router.pushUrl('pages/PluginManagerPage')。
 */
import { router } from '@kit.ArkUI';
import { BreezeTopBar } from '../view/common/BreezeTopBar';
import { Theme } from '../view/common/Theme';
import { PluginManagerView } from '../view/plugins/PluginManagerView';

@Entry
@Component
struct PluginManagerPage {
  @StorageProp('isDark') isDark: boolean = false;

  build() {
    Column() {
      BreezeTopBar({
        title: '插件管理',
        showBack: true,
        // 新七条第 7 条（lead 裁定 11-12 17:00）：全站路由页统一打开 flatBackground —— 顶栏实底档与本页根容器
        // 同吃 Theme.background，消除「顶栏一块色、页面一块色」的两块皮。开关默认 false，一级页不受影响。
        flatBackground: true,
        onBack: (): void => {
          router.back();
        }
      })
      PluginManagerView()
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}
