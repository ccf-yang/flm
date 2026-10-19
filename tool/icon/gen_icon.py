#!/usr/bin/env python3
"""Generate the flm app icon without any third-party imaging library."""

import json
import math
import os
import struct
import zlib

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
ICON_DIR = os.path.join(ROOT, "assets", "icon")
IOS_DIR = os.path.join(ROOT, "tool", "ios_overlay", "AppIcon.appiconset")

DARK = (9, 16, 30)
TEAL = (16, 148, 136)
MINT = (94, 234, 212)
WHITE = (247, 255, 252)


def clamp(value, low=0.0, high=1.0):
    return low if value < low else high if value > high else value


def blend(dst, src, alpha):
    return (
        int(dst[0] + (src[0] - dst[0]) * alpha),
        int(dst[1] + (src[1] - dst[1]) * alpha),
        int(dst[2] + (src[2] - dst[2]) * alpha),
    )


def capsule_distance(px, py, cx, top, bottom, radius):
    if py < top:
        dy = top - py
    elif py > bottom:
        dy = py - bottom
    else:
        dy = 0.0
    dx = px - cx
    return math.hypot(dx, dy) - radius


def render(size, ss):
    width = size * ss
    bars = (0.24, 0.43, 0.62, 0.43, 0.24)
    bar_width = 0.078
    gap = 0.042
    total = 5 * bar_width + 4 * gap
    start = 0.5 - total / 2
    centers = [start + i * (bar_width + gap) + bar_width / 2 for i in range(5)]

    pixels = []
    for y in range(width):
        row = []
        ny = (y + 0.5) / width
        for x in range(width):
            nx = (x + 0.5) / width
            t = clamp((nx + ny) / 2)
            color = (
                int(DARK[0] + (TEAL[0] - DARK[0]) * t),
                int(DARK[1] + (TEAL[1] - DARK[1]) * t),
                int(DARK[2] + (TEAL[2] - DARK[2]) * t),
            )

            # Soft light behind the mark.
            glow_d = math.hypot(nx - 0.5, ny - 0.42)
            glow = clamp(1 - glow_d / 0.62)
            if glow > 0:
                color = blend(color, (255, 255, 255), glow * glow * 0.07)

            # Faint ring.
            ring_d = abs(math.hypot(nx - 0.5, ny - 0.5) - 0.355) - 0.005
            ring_cov = clamp(0.5 - ring_d * width)
            if ring_cov > 0:
                color = blend(color, (255, 255, 255), ring_cov * 0.07)

            # Shadow of the equalizer.
            for index, center in enumerate(centers):
                height = bars[index]
                top = 0.545 - height / 2 + 0.014
                bottom = 0.545 + height / 2 + 0.014
                d = capsule_distance(nx, ny, center, top, bottom, bar_width / 2)
                cov = clamp(0.5 - d * width)
                if cov > 0:
                    color = blend(color, (0, 0, 0), cov * 0.18)

            # Equalizer bars.
            for index, center in enumerate(centers):
                height = bars[index]
                top = 0.545 - height / 2
                bottom = 0.545 + height / 2
                d = capsule_distance(nx, ny, center, top, bottom, bar_width / 2)
                cov = clamp(0.5 - d * width)
                if cov > 0:
                    color = blend(color, MINT if index == 2 else WHITE, cov)

            row.append(color)
        pixels.append(row)

    if ss == 1:
        return pixels

    out = []
    for y in range(size):
        row = []
        for x in range(size):
            r = g = b = 0
            for oy in range(ss):
                for ox in range(ss):
                    pixel = pixels[y * ss + oy][x * ss + ox]
                    r += pixel[0]
                    g += pixel[1]
                    b += pixel[2]
            count = ss * ss
            row.append((r // count, g // count, b // count))
        out.append(row)
    return out


def write_png(path, pixels):
    height = len(pixels)
    width = len(pixels[0])
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for r, g, b in row:
            raw.extend((r, g, b))

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as handle:
        handle.write(png)


ICONS = [
    ("Icon-App-20x20@2x.png", 40),
    ("Icon-App-20x20@3x.png", 60),
    ("Icon-App-29x29@1x.png", 29),
    ("Icon-App-29x29@2x.png", 58),
    ("Icon-App-29x29@2x-ipad.png", 58),
    ("Icon-App-29x29@3x.png", 87),
    ("Icon-App-40x40@1x.png", 40),
    ("Icon-App-40x40@2x.png", 80),
    ("Icon-App-40x40@2x-ipad.png", 80),
    ("Icon-App-40x40@3x.png", 120),
    ("Icon-App-60x60@2x.png", 120),
    ("Icon-App-60x60@3x.png", 180),
    ("Icon-App-76x76@1x.png", 76),
    ("Icon-App-76x76@2x.png", 152),
    ("Icon-App-83.5x83.5@2x.png", 167),
    ("Icon-App-1024x1024@1x.png", 1024),
]


def main():
    os.makedirs(ICON_DIR, exist_ok=True)
    os.makedirs(IOS_DIR, exist_ok=True)

    master = render(1024, 2)
    write_png(os.path.join(ICON_DIR, "app_icon_1024.png"), master)

    cache = {}
    for name, size in ICONS:
        if size not in cache:
            if size == 1024:
                pixels = master
            else:
                ss = 4 if size <= 180 else 2
                pixels = render(size, ss)
            cache[size] = pixels
        write_png(os.path.join(IOS_DIR, name), cache[size])
        print("wrote", name, size)

    contents = {
        "images": [
            {"size": "20x20", "idiom": "iphone", "filename": "Icon-App-20x20@2x.png", "scale": "2x"},
            {"size": "20x20", "idiom": "iphone", "filename": "Icon-App-20x20@3x.png", "scale": "3x"},
            {"size": "29x29", "idiom": "iphone", "filename": "Icon-App-29x29@2x.png", "scale": "2x"},
            {"size": "29x29", "idiom": "iphone", "filename": "Icon-App-29x29@3x.png", "scale": "3x"},
            {"size": "40x40", "idiom": "iphone", "filename": "Icon-App-40x40@2x.png", "scale": "2x"},
            {"size": "40x40", "idiom": "iphone", "filename": "Icon-App-40x40@3x.png", "scale": "3x"},
            {"size": "60x60", "idiom": "iphone", "filename": "Icon-App-60x60@2x.png", "scale": "2x"},
            {"size": "60x60", "idiom": "iphone", "filename": "Icon-App-60x60@3x.png", "scale": "3x"},
            {"size": "29x29", "idiom": "ipad", "filename": "Icon-App-29x29@1x.png", "scale": "1x"},
            {"size": "29x29", "idiom": "ipad", "filename": "Icon-App-29x29@2x-ipad.png", "scale": "2x"},
            {"size": "40x40", "idiom": "ipad", "filename": "Icon-App-40x40@1x.png", "scale": "1x"},
            {"size": "40x40", "idiom": "ipad", "filename": "Icon-App-40x40@2x-ipad.png", "scale": "2x"},
            {"size": "76x76", "idiom": "ipad", "filename": "Icon-App-76x76@1x.png", "scale": "1x"},
            {"size": "76x76", "idiom": "ipad", "filename": "Icon-App-76x76@2x.png", "scale": "2x"},
            {"size": "83.5x83.5", "idiom": "ipad", "filename": "Icon-App-83.5x83.5@2x.png", "scale": "2x"},
            {"size": "1024x1024", "idiom": "ios-marketing", "filename": "Icon-App-1024x1024@1x.png", "scale": "1x"},
        ],
        "info": {"version": 1, "author": "xcode"},
    }
    with open(os.path.join(IOS_DIR, "Contents.json"), "w", encoding="utf-8") as handle:
        json.dump(contents, handle, indent=2)
        handle.write("\n")


if __name__ == "__main__":
    main()
