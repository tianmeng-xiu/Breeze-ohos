/**
 * 职责：三态占位视图 —— LoadingView / EmptyView / ErrorView，各页面统一复用。
 * 依赖：Theme（./Theme）。
 * 对应 Flutter：lib/page/bookshelf/widgets/bookshelf_empty_view.dart、
 *              同目录 *_loading_view.dart 以及各页面的错误重试分支。
 * 约束：只做展示，不发请求；重试动作由调用方通过 onRetry 注入。
 */

import { Theme } from './Theme';

@Component
export struct LoadingView {
  @Prop text: string = '加载中…';
  @StorageProp('isDark') isDark: boolean = false;

  build() {
    Column() {
      LoadingProgress()
        .width(40)
        .height(40)
        .color(Theme.brand)
      Text(this.text)
        .fontSize(14)
        .fontColor(Theme.text2(this.isDark))
        .margin({ top: 12 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
export struct EmptyView {
  @Prop text: string = '暂无内容';
  @Prop hint: string = '';
  @StorageProp('isDark') isDark: boolean = false;

  build() {
    Column() {
      // 纯文字占位，避免引入额外图标资源
      Text(this.text)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(Theme.text2(this.isDark))
        .textAlign(TextAlign.Center)
      if (this.hint.length > 0) {
        Text(this.hint)
          .fontSize(13)
          .fontColor(Theme.text3(this.isDark))
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
          .padding({ left: 32, right: 32 })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}

@Component
export struct ErrorView {
  @Prop msg: string = '加载失败，请稍后重试';
  @StorageProp('isDark') isDark: boolean = false;
  onRetry: () => void = () => {};

  build() {
    Column() {
      Text(this.msg)
        .fontSize(14)
        .fontColor(Theme.text2(this.isDark))
        .textAlign(TextAlign.Center)
        .padding({ left: 32, right: 32 })
        // s39 需求 1：这里原先没有任何行数上限，聚合出来的长报错会把整屏铺满、把「重试」
        // 按钮顶出可视区（用户截图那种形态）。四行 = 一句定死文案（最长 21 字）外加两三组
        // 原因绰绰有余，再多就是没用的重复，超出部分省略号收尾。
        .maxLines(4)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Button('重试')
        .fontSize(14)
        .fontColor(Theme.white)
        .backgroundColor(Theme.brand)
        .height(48)
        .padding({ left: 24, right: 24 })
        .borderRadius(24)
        .margin({ top: 16 })
        .onClick(() => {
          this.onRetry();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
