"""把 Clawd Dev Life 的 APNG / 简单 SVG 还原成 24x24 像素帧（288px 素材每 12px 一个像素）。

输出 JSON：{ palette: ["#rrggbb", ...], clips: { name: { frames: [str], durations: [ms] } } }
每帧是 576 个字符，'.' 为透明，其余字符为调色板下标（base 62 一字符）。
"""
import json
import re
import sys
from pathlib import Path

from PIL import Image, ImageSequence

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])
GRID = 24
GRID_X = 23  # viewBox 从 x=-4.5 开始：横向像素从 6px 处起算，共 23 列
CELL = 12
ALPHABET = ''.join(chr(c) for c in range(33, 127) if chr(c) not in '."\\')

APNG = [
    'thinking', 'plan', 'ultrathink', 'todo', 'simple', 'bug', 'loop', 'deadline',
    'subagents', 'team2', 'compact', 'clone', 'proceed', 'passed_long', 'lgtm', 'error', 'esc',
    'sleep', 'yawn', 'wake', 'dizzy', 'hello', 'right', 'notfound', 'rmrf', 'coffee', 'fish', 'duck',

]
SVG = ['idle', 'drag']

palette: list[str] = []
index: dict[str, int] = {}
stats = {'cells': 0, 'mixed': 0}


def color_key(r: int, g: int, b: int) -> str:
    # 把非常接近的颜色合并，压小调色板
    return f'#{r & 0xF8:02x}{g & 0xF8:02x}{b & 0xF8:02x}'


def code_of(hex_color: str) -> str:
    if hex_color not in index:
        index[hex_color] = len(palette)
        palette.append(hex_color)
    i = index[hex_color]
    if i >= len(ALPHABET):
        raise SystemExit(f'调色板超过 {len(ALPHABET)} 色')
    return ALPHABET[i]


def sample(frame: Image.Image) -> str:
    rgba = frame.convert('RGBA')
    px = rgba.load()
    out = []
    for y in range(GRID):
        for x in range(GRID_X):
            cx, cy = CELL + x * CELL, y * CELL + CELL // 2
            r, g, b, a = px[cx, cy]
            # 校验：格子四角和中心是否同色（衡量是否严格对齐 12px 网格）
            corners = {px[cx - 5, cy - 5], px[cx + 4, cy + 4], px[cx, cy]}
            stats['cells'] += 1
            if len(corners) > 1:
                stats['mixed'] += 1
            out.append('.' if a < 128 else code_of(color_key(r, g, b)))
    return ''.join(out)


def apng(name: str) -> dict:
    img = Image.open(SRC / f'{name}.apng')
    frames, durations = [], []
    for frame in ImageSequence.Iterator(img):
        grid = sample(frame)
        d = int(frame.info.get('duration', 100) or 100)
        # 相邻相同的帧合并，时长累加
        if frames and frames[-1] == grid:
            durations[-1] += d
        else:
            frames.append(grid)
            durations.append(d)
    return {'frames': frames, 'durations': durations}


RECT = re.compile(r'<rect ([^>]*)/>')
ATTR = re.compile(r'(\w+)="([^"]*)"')


def svg(name: str) -> dict:
    """只处理这套素材里的像素 SVG：rect + 组上的 fill；忽略 CSS 动画，另外手工做一帧眨眼。"""
    text = (SRC / f'{name}.svg').read_text()
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', text).group(1).split()]
    grid = ['.'] * (GRID_X * GRID)
    blink = list(grid)
    fill_stack: list[str | None] = []
    lid_depth = None
    for token in re.finditer(r'<g([^>]*)>|</g>|<rect ([^>]*)/>', text):
        whole = token.group(0)
        if whole.startswith('<g'):
            attrs = dict(ATTR.findall(token.group(1) or ''))
            fill_stack.append(attrs.get('fill'))
            if 'lid' in attrs.get('class', ''):
                lid_depth = len(fill_stack)
        elif whole == '</g>':
            if lid_depth == len(fill_stack):
                lid_depth = None
            fill_stack.pop()
        else:
            attrs = dict(ATTR.findall(token.group(2)))
            fill = attrs.get('fill') or next((f for f in reversed(fill_stack) if f), None)
            if not fill or attrs.get('opacity') == '0':
                continue
            fill = fill.lstrip('#')
            if len(fill) == 3:
                fill = ''.join(c * 2 for c in fill)
            code = code_of(color_key(int(fill[0:2], 16), int(fill[2:4], 16), int(fill[4:6], 16)))
            x0, y0 = float(attrs.get('x', 0)) - vb[0] - 0.5, float(attrs.get('y', 0)) - vb[1]
            w, h = float(attrs['width']), float(attrs['height'])
            for yy in range(int(y0), int(y0 + h)):
                for xx in range(int(x0), int(x0 + w)):
                    if 0 <= xx < GRID_X and 0 <= yy < GRID:
                        grid[yy * GRID_X + xx] = code
                        if lid_depth is None:
                            blink[yy * GRID_X + xx] = code
    # 眨眼帧：眼皮那层不画，露出身体颜色
    body = next((c for c in grid if c != '.'), '.')
    blink = [b if b != '.' or g == '.' else body for g, b in zip(grid, blink)]
    open_eyes = ''.join(grid)
    closed = ''.join(blink)
    if open_eyes == closed:
        return {'frames': [open_eyes], 'durations': [1000]}
    return {'frames': [open_eyes, closed, open_eyes], 'durations': [5200, 180, 1]}


clips = {}
for name in APNG:
    if (SRC / f'{name}.apng').exists():
        clips[name] = apng(name)
for name in SVG:
    if (SRC / f'{name}.svg').exists():
        clips[name] = svg(name)

OUT.write_text(json.dumps({'w': GRID_X, 'h': GRID, 'palette': palette, 'clips': clips}, separators=(',', ':')))
mixed = stats['mixed'] / max(1, stats['cells'])
print(f'clips={len(clips)} colors={len(palette)} frames={sum(len(c["frames"]) for c in clips.values())} '
      f'bytes={OUT.stat().st_size} misaligned={mixed:.2%}')
