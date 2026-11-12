# -*- coding: utf-8 -*-
"""
Breeze HarmonyOS 图标生成脚本（可复跑）。
职责：生成 entry/src/main/resources/base/media 下的 15 张底栏页签图标（48x48，
      浅色未选中 #99182431 / 选中 #0A59F7 / 深色未选中 #99E5E5E5）、
      分层应用图标（layered_image.json + foreground.png + background.png）、
      startIcon.png、ic_app.png（封面兜底图），以及 AppScope/resources/base/media/app_icon.png。
依赖：Python 3 + Pillow（pip install pillow）
用法：python scripts/gen_icons.py
说明：ArkUI 的 Image 用 fillColor 只能给 SVG 着色，PNG 无法运行时着色，因此每种状态预生成一张彩色 PNG。
"""
import json
import os

from PIL import Image, ImageDraw

# ---------------------------------------------------------------- 路径

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)                      # .../Breeze-ohos
ENTRY_MEDIA = os.path.join(PROJECT, 'entry', 'src', 'main', 'resources', 'base', 'media')
APPSCOPE_MEDIA = os.path.join(PROJECT, 'AppScope', 'resources', 'base', 'media')

# ---------------------------------------------------------------- 调色

OFF = (0x18, 0x24, 0x31, 0x99)    # #99182431 浅色未选中（主文字 60%）
SEL = (0x0A, 0x59, 0xF7, 0xFF)    # #0A59F7  选中品牌蓝
DARK = (0xE5, 0xE5, 0xE5, 0x99)   # #99E5E5E5 深色未选中
BRAND = (0x0A, 0x59, 0xF7, 0xFF)
WHITE = (255, 255, 255, 255)

TAB_SIZE = 48      # 24vp @2x
APP_SIZE = 288     # 应用图标
SS = 8             # 超采样倍数，抗锯齿


def unit(size):
    """返回 (超采样画布边长, 单位换算函数)。"""
    side = size * SS

    def u(v):
        return int(round(v * side / 24.0))

    return side, u


def render_icon(size, color, draw_fn):
    """用 24x24 逻辑坐标绘制，超采样后缩放，最后用 color 上色。"""
    side, u = unit(size)
    mask = Image.new('L', (side, side), 0)
    draw_fn(ImageDraw.Draw(mask), u)
    mask = mask.resize((size, size), Image.LANCZOS)
    out = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    out.paste(Image.new('RGBA', (size, size), color), (0, 0), mask)
    return out


# ---------------------------------------------------------------- 5 个页签图形

def draw_home(d, u):
    """首页：实心房子 + 门洞。"""
    d.polygon([(u(12), u(2.4)), (u(21.4), u(10.4)), (u(21.4), u(21.4)),
               (u(2.6), u(21.4)), (u(2.6), u(10.4))], fill=255)
    d.rounded_rectangle([u(9.4), u(13.0), u(14.6), u(21.6)], radius=u(0.9), fill=0)


def draw_cloud(d, u):
    """云收藏：三圆 + 平底圆角的云朵剪影。"""
    d.ellipse([u(2.6), u(9.0), u(12.4), u(18.8)], fill=255)
    d.ellipse([u(9.0), u(5.0), u(20.0), u(16.0)], fill=255)
    d.ellipse([u(6.0), u(7.0), u(15.6), u(16.6)], fill=255)
    d.rounded_rectangle([u(3.2), u(11.6), u(20.6), u(18.4)], radius=u(3.4), fill=255)


def draw_shelf(d, u):
    """书架：三本书脊。"""
    d.rounded_rectangle([u(3.6), u(3.4), u(8.2), u(20.6)], radius=u(0.9), fill=255)
    d.rounded_rectangle([u(9.6), u(3.4), u(14.2), u(20.6)], radius=u(0.9), fill=255)
    d.rounded_rectangle([u(15.6), u(6.2), u(20.2), u(20.6)], radius=u(0.9), fill=255)


def draw_discover(d, u):
    """发现：放大镜（空心圆 + 手柄）。"""
    d.ellipse([u(3.0), u(3.0), u(16.6), u(16.6)], fill=255)
    d.ellipse([u(6.2), u(6.2), u(13.4), u(13.4)], fill=0)
    d.line([(u(15.0), u(15.0)), (u(21.2), u(21.2))], fill=255, width=u(2.4))


def draw_more(d, u):
    """更多：四宫格。"""
    r = u(2.0)
    d.rounded_rectangle([u(3.6), u(3.6), u(10.6), u(10.6)], radius=r, fill=255)
    d.rounded_rectangle([u(13.4), u(3.6), u(20.4), u(10.6)], radius=r, fill=255)
    d.rounded_rectangle([u(3.6), u(13.4), u(10.6), u(20.4)], radius=r, fill=255)
    d.rounded_rectangle([u(13.4), u(13.4), u(20.4), u(20.4)], radius=r, fill=255)


TAB_ICONS = [
    ('home', draw_home),
    ('cloud', draw_cloud),
    ('shelf', draw_shelf),
    ('discover', draw_discover),
    ('more', draw_more),
]


# ---------------------------------------------------------------- 应用图标

def draw_book(size, fg, spine, safe_scale=1.0):
    """书本图形：整幅 96 单位画布，safe_scale 用于分层图标前景的安全区收缩。"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    k = size / 96.0 * safe_scale
    off = (size - 96.0 * k) / 2.0

    def p(v):
        return int(round(off + v * k))

    d.rounded_rectangle([p(20), p(30), p(76), p(66)], radius=int(4 * k), fill=fg)
    d.rectangle([p(45), p(30), p(51), p(66)], fill=spine)
    d.rounded_rectangle([p(20), p(30), p(45), p(66)], radius=int(4 * k), fill=fg)
    d.rounded_rectangle([p(51), p(30), p(76), p(66)], radius=int(4 * k), fill=fg)
    return img


def app_icon(size=APP_SIZE):
    img = Image.new('RGBA', (size, size), BRAND)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=int(size * 0.22), fill=BRAND)
    book = draw_book(size, WHITE, BRAND)
    img.alpha_composite(book)
    return img


# ---------------------------------------------------------------- 主流程

def main():
    for d in (ENTRY_MEDIA, APPSCOPE_MEDIA):
        os.makedirs(d, exist_ok=True)

    # 15 张页签图标
    variants = [('', OFF), ('_sel', SEL), ('_d', DARK)]
    for name, fn in TAB_ICONS:
        for suffix, color in variants:
            path = os.path.join(ENTRY_MEDIA, 'ic_tab_' + name + suffix + '.png')
            render_icon(TAB_SIZE, color, fn).save(path)
            print('wrote', path)

    # 分层应用图标：background(纯色) + foreground(书本，留安全区)
    bg = Image.new('RGBA', (APP_SIZE, APP_SIZE), BRAND)
    bg.save(os.path.join(ENTRY_MEDIA, 'background.png'))
    fg = draw_book(APP_SIZE, WHITE, (0, 0, 0, 0), safe_scale=0.72)
    fg.save(os.path.join(ENTRY_MEDIA, 'foreground.png'))
    with open(os.path.join(ENTRY_MEDIA, 'layered_image.json'), 'w', encoding='utf-8') as f:
        json.dump({'layered-image': {'background': '$media:background',
                                     'foreground': '$media:foreground'}}, f, ensure_ascii=False, indent=2)
    print('wrote layered_image.json / foreground.png / background.png')

    # 启动页图标 + 应用图标
    icon = app_icon()
    icon.save(os.path.join(ENTRY_MEDIA, 'startIcon.png'))
    icon.save(os.path.join(ENTRY_MEDIA, 'app_icon.png'))
    icon.save(os.path.join(APPSCOPE_MEDIA, 'app_icon.png'))
    print('wrote startIcon.png / app_icon.png (entry + AppScope)')

    # 封面兜底图：蓝底透明 + 白色书本，加载失败时避免空白
    cover = Image.new('RGBA', (192, 256), (0xE5, 0xE8, 0xEA, 0xFF))
    book = draw_book(192, BRAND, (0xE5, 0xE8, 0xEA, 0xFF), safe_scale=0.42)
    cover.alpha_composite(book, (0, int((256 - 192) / 2)))
    cover.save(os.path.join(ENTRY_MEDIA, 'ic_app.png'))
    print('wrote ic_app.png')


if __name__ == '__main__':
    main()
