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


def render(size, ss, bars=True, scale=1.0):
    """Render the icon plate.

    `bars=False` keeps the gradient, glow and ring but drops the equalizer —
    that is the adaptive-icon background layer, whose mark is a separate
    foreground layer. `scale` zooms the whole composition about its centre,
    which is how the mark is pulled into the adaptive icon's safe zone.
    """
    width = size * ss
    bars_ = (0.24, 0.43, 0.62, 0.43, 0.24)
    bar_width = 0.078
    gap = 0.042
    total = 5 * bar_width + 4 * gap
    start = 0.5 - total / 2
    centers = [start + i * (bar_width + gap) + bar_width / 2 for i in range(5)]
    # A scaled canvas means one device pixel covers 1/(width*scale) of the
    # master geometry, so the antialias term has to shrink with it.
    aa = width * scale

    pixels = []
    for y in range(width):
        row = []
        ny = ((y + 0.5) / width - 0.5) / scale + 0.5
        for x in range(width):
            nx = ((x + 0.5) / width - 0.5) / scale + 0.5
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
            ring_cov = clamp(0.5 - ring_d * aa)
            if ring_cov > 0:
                color = blend(color, (255, 255, 255), ring_cov * 0.07)

            if bars:
                # Shadow of the equalizer.
                for index, center in enumerate(centers):
                    height = bars_[index]
                    top = 0.545 - height / 2 + 0.014
                    bottom = 0.545 + height / 2 + 0.014
                    d = capsule_distance(nx, ny, center, top, bottom, bar_width / 2)
                    cov = clamp(0.5 - d * aa)
                    if cov > 0:
                        color = blend(color, (0, 0, 0), cov * 0.18)

                # Equalizer bars.
                for index, center in enumerate(centers):
                    height = bars_[index]
                    top = 0.545 - height / 2
                    bottom = 0.545 + height / 2
                    d = capsule_distance(nx, ny, center, top, bottom, bar_width / 2)
                    cov = clamp(0.5 - d * aa)
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
    has_alpha = len(pixels[0][0]) == 4
    raw = bytearray()
    for row in pixels:
        raw.append(0)
        for pixel in row:
            raw.extend(pixel)

    def chunk(kind, data):
        return (
            struct.pack(">I", len(data))
            + kind
            + data
            + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
        )

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6 if has_alpha else 2, 0, 0, 0))
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

# Android. A legacy launcher icon is just the artwork at 48/72/96/144/192, but
# an adaptive icon is drawn on a 108dp canvas whose outer band the launcher
# masks away (circle, squircle, ...). So the plate and the equalizer mark become
# two layers, and the mark is shrunk into the central safe zone.
ANDROID_LEGACY = [
    ("mipmap-mdpi", 48),
    ("mipmap-hdpi", 72),
    ("mipmap-xhdpi", 96),
    ("mipmap-xxhdpi", 144),
    ("mipmap-xxxhdpi", 192),
]
ANDROID_ADAPTIVE = [
    ("mipmap-mdpi", 108),
    ("mipmap-hdpi", 162),
    ("mipmap-xhdpi", 216),
    ("mipmap-xxhdpi", 324),
    ("mipmap-xxxhdpi", 432),
]
MARK_SCALE = 0.68

BAR_HEIGHTS = (0.24, 0.43, 0.62, 0.43, 0.24)
BAR_WIDTH = 0.078
BAR_GAP = 0.042
BAR_CENTERS = [
    (0.5 - (5 * BAR_WIDTH + 4 * BAR_GAP) / 2)
    + index * (BAR_WIDTH + BAR_GAP)
    + BAR_WIDTH / 2
    for index in range(5)
]


def render_mark(size, scale=MARK_SCALE):
    """The equalizer alone, on transparency, centred in the safe zone."""
    pixels = []
    for y in range(size):
        row = []
        ny = (((y + 0.5) / size) - 0.5) / scale + 0.545
        for x in range(size):
            nx = (((x + 0.5) / size) - 0.5) / scale + 0.5
            coverage = 0.0
            color = WHITE
            for index, center in enumerate(BAR_CENTERS):
                height = BAR_HEIGHTS[index]
                d = capsule_distance(
                    nx,
                    ny,
                    center,
                    0.545 - height / 2,
                    0.545 + height / 2,
                    BAR_WIDTH / 2,
                )
                cov = clamp(0.5 - d * size * scale)
                if cov > coverage:
                    coverage = cov
                    color = MINT if index == 2 else WHITE
            row.append((color[0], color[1], color[2], int(round(coverage * 255))))
        pixels.append(row)
    return pixels


def crop_circle(pixels):
    size = len(pixels)
    radius = size / 2
    out = []
    for y in range(size):
        row = []
        for x in range(size):
            r, g, b = pixels[y][x]
            edge = radius - math.hypot(x + 0.5 - radius, y + 0.5 - radius) + 0.5
            row.append((r, g, b, int(round(clamp(edge) * 255))))
        out.append(row)
    return out


def write_android():
    res = os.path.join(ROOT, "tool", "android_overlay", "res")
    for folder, size in ANDROID_LEGACY:
        target = os.path.join(res, folder)
        os.makedirs(target, exist_ok=True)
        art = render(size, 2 if size <= 96 else 1)
        write_png(os.path.join(target, "ic_launcher.png"), art)
        write_png(os.path.join(target, "ic_launcher_round.png"), crop_circle(art))
        print("android legacy", folder, size)
    for folder, size in ANDROID_ADAPTIVE:
        target = os.path.join(res, folder)
        os.makedirs(target, exist_ok=True)
        plate = render(size, 1, bars=False)
        mark = render_mark(size)
        write_png(os.path.join(target, "ic_launcher_background.png"), plate)
        write_png(os.path.join(target, "ic_launcher_foreground.png"), mark)
        write_png(os.path.join(target, "ic_launcher_monochrome.png"), mark)
        print("android adaptive", folder, size)


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
    import sys

    # `--android` regenerates only the launcher resources (fast), `--ios` only
    # the iOS icon set, and no argument does both.
    which = sys.argv[1] if len(sys.argv) > 1 else ""
    if which == "--android":
        write_android()
    elif which == "--ios":
        main()
    else:
        main()
        write_android()
