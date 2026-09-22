#!/usr/bin/env python3
"""生成 SYNY 应用图标（纯标准库，无需 Pillow）。

输出：build/icon.icns 与 build/icon_preview.png
用法：python3 tools/make_icon.py
"""

from __future__ import annotations

import math
import os
import shutil
import struct
import subprocess
import sys
import zlib

SS = 4  # 超采样倍数，用于抗锯齿

TOP = (0x3B, 0x82, 0xF6)   # 蓝
BOTTOM = (0x0B, 0xB0, 0xA0)  # 青


# --------------------------------------------------------------------------- #
# 基础绘图
# --------------------------------------------------------------------------- #
def _smoothstep(edge0, edge1, x):
    if edge0 == edge1:
        return 0.0 if x < edge0 else 1.0
    t = min(max((x - edge0) / (edge1 - edge0), 0.0), 1.0)
    return t * t * (3 - 2 * t)


def _rounded_box_sd(px, py, cx, cy, hw, hh, r):
    qx = abs(px - cx) - hw + r
    qy = abs(py - cy) - hh + r
    return min(max(qx, qy), 0.0) + math.hypot(max(qx, 0.0), max(qy, 0.0)) - r


def render(size: int):
    """返回 size x size 的 RGBA 行列表。"""
    n = size * SS
    aa = SS * 0.75  # 边缘过渡宽度（子像素单位）

    cx = cy = n / 2.0
    hw = hh = n / 2.0 - n * 0.045
    radius = n * 0.225

    # 无线信号：圆心靠下，弧线向上张开
    gx, gy = n * 0.5, n * 0.735
    dot_r = n * 0.062
    arcs = [(n * 0.145, n * 0.062), (n * 0.255, n * 0.062), (n * 0.365, n * 0.058)]
    half_span = 48.0

    rows_hi = []
    for y in range(n):
        row = bytearray()
        for x in range(n):
            px, py = x + 0.5, y + 0.5

            # 底板
            sd = _rounded_box_sd(px, py, cx, cy, hw, hh, radius)
            body = 1.0 - _smoothstep(-aa, aa, sd)
            if body <= 0.0:
                row += b"\x00\x00\x00\x00"
                continue

            # 渐变（左上 -> 右下）
            t = min(max(((px / n) + (py / n)) / 2.0, 0.0), 1.0)
            col = [TOP[i] + (BOTTOM[i] - TOP[i]) * t for i in range(3)]

            # 信号图形
            glyph = 0.0
            dx, dy = px - gx, gy - py        # dy 向上为正
            dist = math.hypot(dx, dy)
            ang = math.degrees(math.atan2(dy, dx))
            angular = 1.0 - _smoothstep(half_span - SS * 0.6, half_span + SS * 0.6,
                                        abs(ang - 90.0))
            for ring_r, ring_w in arcs:
                band = abs(dist - ring_r) - ring_w / 2.0
                glyph = max(glyph, (1.0 - _smoothstep(-aa, aa, band)) * angular)
            glyph = max(glyph, 1.0 - _smoothstep(dot_r - aa, dot_r + aa, dist))

            if glyph > 0.0:
                col = [col[i] + (255.0 - col[i]) * glyph for i in range(3)]

            alpha = int(round(255 * body))
            row += bytes((int(col[0]), int(col[1]), int(col[2]), alpha))
        rows_hi.append(row)

    # 降采样
    rows_out = []
    for y in range(size):
        row = bytearray()
        for x in range(size):
            r = g = b = a = 0
            for sy in range(SS):
                src = rows_hi[y * SS + sy]
                for sx in range(SS):
                    i = (x * SS + sx) * 4
                    r += src[i]
                    g += src[i + 1]
                    b += src[i + 2]
                    a += src[i + 3]
            k = SS * SS
            row += bytes((r // k, g // k, b // k, a // k))
        rows_out.append(row)
    return rows_out


def write_png(path: str, size: int, rows) -> None:
    raw = b"".join(b"\x00" + bytes(row) for row in rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


# --------------------------------------------------------------------------- #
ICONSET_ENTRIES = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]


def main() -> int:
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    build = os.path.join(root, "build")
    iconset = os.path.join(build, "SYNY.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset, exist_ok=True)

    cache = {}
    for name, size in ICONSET_ENTRIES:
        if size not in cache:
            cache[size] = render(size)
        write_png(os.path.join(iconset, name), size, cache[size])
    write_png(os.path.join(build, "icon_preview.png"), 512, cache[512])

    icns = os.path.join(build, "icon.icns")
    if shutil.which("iconutil"):
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
        print("已生成 {}".format(icns))
    else:
        print("未找到 iconutil，跳过 .icns 生成")
    print("已生成 {}".format(os.path.join(build, "icon_preview.png")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
