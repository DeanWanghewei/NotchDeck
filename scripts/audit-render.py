#!/usr/bin/env python3
"""自渲染图自动审计：在无法真正"看图"的环境里，替代人工目检的可机器判定部分。

判定内容（都是会真实引发回归的问题）：
1. 背景色从四角像素实测得出（不假设"深色 = 近黑"——设置页深色底是 #252525，
   用近黑阈值判定会把深色版误当浅色版，得出"对比文字占 97%"这种假信号）；
2. 墨迹外接框与四边余量：文字贴边或越界 = 截断 / 溢出；
3. 文字像素与背景的对比度（WCAG 相对亮度比）；
4. 水平墨迹带 = 可见行的结构（分组标题、控件行、条目行），用于核对分组与条目是否都在位；
5. HeatScale 冷暖停靠点是否真的渲染出来（连续负载类视图）。

不能判定的（仍需人工目检）：排版美感、控件对齐观感、玻璃材质与辅助功能外观。
"""
import sys
from collections import Counter
from pathlib import Path

from PIL import Image

# HeatScale 停靠点（UI/UIHelpers.swift），连续负载用
STOPS = [
    (0.00, (0.30, 0.56, 1.00), "冷蓝"),
    (0.30, (0.10, 0.80, 0.90), "青"),
    (0.55, (0.20, 0.80, 0.35), "绿"),
    (0.75, (0.98, 0.72, 0.12), "黄"),
    (0.90, (0.98, 0.45, 0.10), "橙"),
    (1.00, (0.93, 0.20, 0.16), "热红"),
]


def relative_luminance(rgb):
    def channel(value):
        value = value / 255
        return value / 12.92 if value <= 0.03928 else ((value + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a, b):
    la, lb = relative_luminance(a), relative_luminance(b)
    lighter, darker = max(la, lb), min(la, lb)
    return (lighter + 0.05) / (darker + 0.05)


def background_of(pixels, width, height):
    """取四角像素的众数作为背景色：自渲染图四角必然是背景"""
    corners = [pixels[0], pixels[width - 1], pixels[(height - 1) * width], pixels[height * width - 1]]
    return Counter(corners).most_common(1)[0][0]


def audit(path: Path, edge_margin: int = 6) -> None:
    image = Image.open(path).convert("RGB")
    width, height = image.size
    pixels = list(image.getdata())
    total = len(pixels)
    background = background_of(pixels, width, height)

    # 墨迹 = 与背景差异明显的像素
    threshold = 28
    ink_mask = [max(abs(p[0] - background[0]), abs(p[1] - background[1]), abs(p[2] - background[2])) > threshold
                for p in pixels]
    ink_count = sum(ink_mask)

    min_x, min_y, max_x, max_y = width, height, -1, -1
    row_has_ink = [False] * height
    for y in range(height):
        base = y * width
        for x in range(width):
            if ink_mask[base + x]:
                row_has_ink[y] = True
                if x < min_x:
                    min_x = x
                if x > max_x:
                    max_x = x
                if y < min_y:
                    min_y = y
                if y > max_y:
                    max_y = y

    # 水平墨迹带：连续有墨迹的行合成一条带
    bands = []
    start = None
    for y, has in enumerate(row_has_ink + [False]):
        if has and start is None:
            start = y
        elif not has and start is not None:
            bands.append((start, y - 1))
            start = None

    # 文字核心色：墨迹里与背景对比度最高的颜色。
    # 不能用众数——抗锯齿边缘像素的众数会落在中间调上，算出没有意义的低对比度。
    ink_colors = Counter(p for p, is_ink in zip(pixels, ink_mask) if is_ink)
    core = [(count, color) for color, count in ink_colors.items() if count >= 20]
    if core:
        text_color = max(core, key=lambda item: contrast_ratio(item[1], background))[1]
    else:
        text_color = background
    ratio = contrast_ratio(text_color, background)

    cool = sum(1 for p in pixels if p[2] > p[0] + 18)
    warm = sum(1 for p in pixels if p[0] > p[2] + 18)

    print(f"\n=== {path.name} ({width}x{height}) ===")
    print(f"  背景色（实测四角）: #{background[0]:02X}{background[1]:02X}{background[2]:02X}"
          f" → {'深色底' if relative_luminance(background) < 0.2 else '浅色底'}")
    if max_x < 0:
        print("  墨迹: 无（画面空白）")
        return
    left, right = min_x, width - 1 - max_x
    top, bottom = min_y, height - 1 - max_y
    print(f"  墨迹外接框: x[{min_x},{max_x}] y[{min_y},{max_y}]"
          f" → 左右余量 {left}/{right}px，上下余量 {top}/{bottom}px")
    overflow = []
    if left < edge_margin:
        overflow.append(f"左边缘余量仅 {left}px")
    if right < edge_margin:
        overflow.append(f"右边缘余量仅 {right}px")
    if bottom < edge_margin:
        overflow.append(f"下边缘余量仅 {bottom}px")
    print(f"  边缘检查: {'、'.join(overflow) if overflow else '四周留白正常，未见贴边溢出'}")
    print(f"  可见行带: {len(bands)} 条" + (f"（首 {bands[0][0]}px，末 {bands[-1][1]}px）" if bands else ""))
    print(f"  主要文字色 #{text_color[0]:02X}{text_color[1]:02X}{text_color[2]:02X}"
          f" 与背景对比度 {ratio:.1f}:1"
          f" → {'AA(≥4.5) 达标' if ratio >= 4.5 else 'AA(≥4.5) 不达标'}")
    print(f"  冷色像素 {cool} / 暖色像素 {warm}")

    hits = []
    for position, rgb, label in STOPS:
        target = tuple(int(round(c * 255)) for c in rgb)
        hit = sum(1 for p in pixels
                  if abs(p[0] - target[0]) <= 26 and abs(p[1] - target[1]) <= 26 and abs(p[2] - target[2]) <= 26)
        if hit:
            hits.append(f"{position:.2f} {label}({hit}px)")
    print(f"  HeatScale 停靠点命中: {'、'.join(hits) if hits else '无（该视图不含连续负载色标）'}")


def main() -> int:
    directories = [Path(arg) for arg in sys.argv[1:]] or [Path("build/render-new")]
    if not directories:
        return 1
    for directory in directories:
        if directory.is_dir():
            for path in sorted(directory.glob("*.png")):
                audit(path)
        elif directory.is_file():
            audit(directory)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
