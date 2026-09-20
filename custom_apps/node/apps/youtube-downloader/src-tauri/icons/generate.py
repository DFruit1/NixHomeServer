#!/usr/bin/env python3
"""Generate the YouTube Downloader icon set.

The mark is a white play triangle above a download arrow on the app's red
accent, so it reads as "video download" and is distinguishable from the plain
YouTube logo (and from the old Tauri template icon).

Run from anywhere:
    python3 src-tauri/icons/generate.py

Requires Pillow.
"""
from pathlib import Path

from PIL import Image, ImageDraw

RED = (185, 28, 28, 255)
WHITE = (255, 255, 255, 255)

# Glyph in a 100x100 local box, centered on (50, 50).
PLAY = [(28, 8), (28, 48), (72, 28)]
SHAFT = (42, 52, 58, 68)
HEAD = [(24, 64), (76, 64), (50, 92)]

HERE = Path(__file__).resolve().parent
APP_DIR = HERE.parent.parent
ICON_DIR = HERE
ANDROID_RES = APP_DIR / "src-tauri" / "gen" / "android" / "app" / "src" / "main" / "res"

SS = 4  # supersample factor


def _map(x, y, ox, oy, scale):
    return (ox + x * scale, oy + y * scale)


def draw_glyph(draw, ox, oy, scale, color=WHITE):
    draw.polygon([_map(x, y, ox, oy, scale) for x, y in PLAY], fill=color)
    draw.rectangle(
        [
            _map(SHAFT[0], SHAFT[1], ox, oy, scale),
            _map(SHAFT[2], SHAFT[3], ox, oy, scale),
        ],
        fill=color,
    )
    draw.polygon([_map(x, y, ox, oy, scale) for x, y in HEAD], fill=color)


def glyph_offsets(size, glyph_scale):
    box = size * glyph_scale
    scale = box / 100
    ox = (size - box) / 2
    oy = (size - box) / 2
    return ox, oy, scale


def render(size, background, glyph_scale, corner_radius=0.0):
    canvas = size * SS
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    if background is not None:
        if corner_radius > 0:
            draw.rounded_rectangle(
                [0, 0, canvas - 1, canvas - 1],
                radius=corner_radius * canvas,
                fill=background,
            )
        else:
            draw.rectangle([0, 0, canvas - 1, canvas - 1], fill=background)
    ox, oy, scale = glyph_offsets(canvas, glyph_scale)
    draw_glyph(draw, ox, oy, scale)
    return image.resize((size, size), Image.LANCZOS)


def render_circle(size, glyph_scale):
    canvas = size * SS
    image = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.ellipse([0, 0, canvas - 1, canvas - 1], fill=RED)
    ox, oy, scale = glyph_offsets(canvas, glyph_scale)
    draw_glyph(draw, ox, oy, scale)
    return image.resize((size, size), Image.LANCZOS)


def write_png(path, image):
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path)
    print(f"wrote {path.relative_to(APP_DIR)} ({image.width}x{image.height})")


def main():
    # Desktop source icons.
    desktop = {
        ICON_DIR / "32x32.png": 32,
        ICON_DIR / "128x128.png": 128,
        ICON_DIR / "128x128@2x.png": 256,
        ICON_DIR / "icon.png": 512,
    }
    for path, size in desktop.items():
        write_png(path, render(size, RED, 0.68, corner_radius=0.2))
    ico_base = render(256, RED, 0.68, corner_radius=0.2)
    ico_base.save(
        ICON_DIR / "icon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)],
    )
    print(f"wrote {(ICON_DIR / 'icon.ico').relative_to(APP_DIR)}")

    # Android legacy and adaptive layers.
    legacy_sizes = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
    fg_sizes = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}
    for density, size in legacy_sizes.items():
        base = ANDROID_RES / f"mipmap-{density}"
        write_png(base / "ic_launcher.png", render(size, RED, 0.66))
        write_png(base / "ic_launcher_round.png", render_circle(size, 0.58))
    for density, size in fg_sizes.items():
        base = ANDROID_RES / f"mipmap-{density}"
        write_png(base / "ic_launcher_foreground.png", render(size, None, 0.58))

    write_vectors()


def write_vectors():
    box = 108 * 0.58
    scale = box / 100
    offset = (108 - box) / 2

    def p(x, y):
        return (offset + x * scale, offset + y * scale)

    play = " ".join(
        f"{'M' if i == 0 else 'L'}{p(x, y)[0]:.2f},{p(x, y)[1]:.2f}"
        for i, (x, y) in enumerate(PLAY)
    ) + " Z"
    shaft = p(*SHAFT[:2])
    shaft_end = p(*SHAFT[2:])
    shaft_path = (
        f"M{shaft[0]:.2f},{shaft[1]:.2f} "
        f"h{shaft_end[0] - shaft[0]:.2f} v{shaft_end[1] - shaft[1]:.2f} "
        f"h{-(shaft_end[0] - shaft[0]):.2f} Z"
    )
    head = " ".join(
        f"{'M' if i == 0 else 'L'}{p(x, y)[0]:.2f},{p(x, y)[1]:.2f}"
        for i, (x, y) in enumerate(HEAD)
    ) + " Z"

    foreground = f"""<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#FFFFFF"
        android:pathData="{play}" />
    <path
        android:fillColor="#FFFFFF"
        android:pathData="{shaft_path}" />
    <path
        android:fillColor="#FFFFFF"
        android:pathData="{head}" />
</vector>
"""
    background = """<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path
        android:fillColor="#B91C1C"
        android:pathData="M0,0h108v108h-108z" />
</vector>
"""
    fg_path = ANDROID_RES / "drawable-v24" / "ic_launcher_foreground.xml"
    bg_path = ANDROID_RES / "drawable" / "ic_launcher_background.xml"
    fg_path.write_text(foreground)
    bg_path.write_text(background)
    print(f"wrote {fg_path.relative_to(APP_DIR)}")
    print(f"wrote {bg_path.relative_to(APP_DIR)}")


if __name__ == "__main__":
    main()
