#!/usr/bin/env python3
"""生成 ClaudePicker 的 .icns 图标。

图形来自 Sources/ClaudeDeck/main.swift 里的 ClawdMark（像素风 Clawd 吉祥物）。
源 cells 是 15×15 的 viewBox（x 0…15、y 6…15，内容中心 (7.5, 10.5)），
这里按 Big Sur 图标规范放大到 1024 画布：深色圆角底 + 橙色 Clawd。

用法: python3 scripts/make_icon.py <输出目录>
产物: <输出目录>/AppIcon.iconset/*.png 与 <输出目录>/AppIcon.icns
"""
import sys
import os
import math
from PIL import Image, ImageDraw

# ClawdMark cells: (x, y, w, h, kind)  kind: b=身体 e=眼
CELLS = [
    (3, 11, 1, 4, "b"), (5, 11, 1, 4, "b"), (9, 11, 1, 4, "b"), (11, 11, 1, 4, "b"),
    (2, 6, 11, 7, "b"),
    (0, 9, 2, 2, "b"), (13, 9, 2, 2, "b"),
    (4, 8, 1, 2, "e"), (10, 8, 1, 2, "e"),
]
VIEW_BOX = (0, 3, 15, 15)  # x, y, w, h

BODY = (215, 119, 87)    # 0.843, 0.467, 0.341
EYE = (26, 26, 26)       # 0.102, 0.102, 0.102

CANVAS = 1024
# Big Sur 规范：图标体 824×824 居中，留出阴影空间
INSET = 100
BODY_SIZE = CANVAS - INSET * 2
RADIUS = int(BODY_SIZE * 0.2237)  # 约 184


def rounded_bg() -> Image.Image:
    """深色圆角底，带自上而下的轻微渐变。"""
    img = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    # 渐变层
    grad = Image.new("RGBA", (BODY_SIZE, BODY_SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    top = (38, 40, 48)
    bot = (18, 19, 24)
    for y in range(BODY_SIZE):
        t = y / (BODY_SIZE - 1)
        c = tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3))
        gd.line([(0, y), (BODY_SIZE, y)], fill=c + (255,))
    # 圆角遮罩
    mask = Image.new("L", (BODY_SIZE, BODY_SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, BODY_SIZE - 1, BODY_SIZE - 1], radius=RADIUS, fill=255
    )
    img.paste(grad, (INSET, INSET), mask)
    return img


def draw_clawd(img: Image.Image) -> Image.Image:
    """按 ClawdMark 的等比缩放规则把细胞的矩形画上去。"""
    vb_x, vb_y, vb_w, vb_h = VIEW_BOX
    # 吉祥物占图标体的比例（留出边距，视觉上不顶格）
    box = BODY_SIZE * 0.56
    scale = min(box / vb_w, box / vb_h)
    # 内容在画布居中
    ox = (CANVAS - vb_w * scale) / 2 - vb_x * scale
    oy = (CANVAS - vb_h * scale) / 2 - vb_y * scale

    d = ImageDraw.Draw(img)
    for (x, y, w, h, kind) in CELLS:
        x0 = ox + x * scale
        y0 = oy + y * scale
        x1 = x0 + w * scale
        y1 = y0 + h * scale
        d.rectangle([x0, y0, x1 - 1, y1 - 1], fill=BODY if kind == "b" else EYE)
    return img


def main() -> int:
    out_dir = sys.argv[1] if len(sys.argv) > 1 else "build/icon"
    os.makedirs(out_dir, exist_ok=True)

    img = draw_clawd(rounded_bg())
    master = os.path.join(out_dir, "icon_1024.png")
    img.save(master)
    print("master ->", master)

    iconset = os.path.join(out_dir, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    # Apple 要求的 iconset 尺寸集合
    specs = [
        (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
        (256, 1), (256, 2), (512, 1), (512, 2),
    ]
    for size, scale in specs:
        px = size * scale
        name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
        img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    print("iconset ->", iconset)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
