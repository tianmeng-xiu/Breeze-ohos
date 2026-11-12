/**
 * 职责：云收藏页（一级 Tab 1）—— 占位页，说明 WebDAV 同步在鸿蒙端待接入。
 * 依赖：StateViews / Theme（公共顶栏由 pages/Index.ets 统一提供，本页不自绘顶栏）。
 * 对应 Flutter：lib/page/old_home/…cloud* 云收藏相关页面（原版走 WebDAV 远端收藏）。
 */

import { Theme } from '../common/Theme';
import { EmptyView } from '../common/StateViews';

@Component
export struct CloudPage {
  onRequestTab: (index: number) => void = (index: number) => {};

  @StorageProp('isDark') isDark: boolean = false;

  build() {
    Column() {
      EmptyView({
        text: 'WebDAV 同步在鸿蒙端待接入',
        hint: '本地书架已可正常使用（书架页）；云收藏将在后续版本通过 WebDAV 与桌面端互通。'
      })
        .layoutWeight(1)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Theme.background(this.isDark))
  }
}