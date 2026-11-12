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
