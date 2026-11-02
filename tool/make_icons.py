#!/usr/bin/env python3
"""Generate the app icon and the library logo from one set of primitives.

Both marks are the same idea — a concentration curve over a target band —
with different palettes: warm terracotta for the app a person uses, cool
graphite and mint for the library a developer links against.

Run:  python3 tool/make_icons.py
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SS = 4  # supersampling factor; everything is drawn at 4× then reduced
U = 1024  # design canvas


# --- primitives -----------------------------------------------------------


def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def vertical_gradient(size: int, top: tuple[int, int, int], bottom: tuple[int, int, int]) -> Image.Image:
    strip = Image.new("RGB", (1, size))
    px = strip.load()
    for y in range(size):
        t = y / max(1, size - 1)
        px[0, y] = tuple(round(lerp(a, b, t)) for a, b in zip(top, bottom))
    return strip.resize((size, size), Image.BICUBIC)


def cubic(p0, p1, p2, p3, steps=140):
    out = []
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = mt**3 * p0[0] + 3 * mt**2 * t * p1[0] + 3 * mt * t**2 * p2[0] + t**3 * p3[0]
        y = mt**3 * p0[1] + 3 * mt**2 * t * p1[1] + 3 * mt * t**2 * p2[1] + t**3 * p3[1]
        out.append((x, y))
    return out


# One dose, then decay: a fast rise, a rounded peak and a long tail. Asymmetric
# on purpose — a symmetrical spike reads as "mountain", this reads as a curve.
CURVE_SEGMENTS = [
    ((150, 748), (244, 744), (312, 718), (354, 600)),
    ((354, 600), (390, 486), (392, 330), (436, 330)),
    ((436, 330), (506, 330), (560, 470), (622, 566)),
    ((622, 566), (688, 676), (760, 716), (874, 700)),
]


def curve_points(scale: float, offset: tuple[float, float] = (0, 0), steps: int = 420):
    pts = []
    for seg in CURVE_SEGMENTS:
        pts.extend(cubic(*seg, steps=steps))
    return [((x + offset[0]) * scale, (y + offset[1]) * scale) for x, y in pts]


def draw_curve(draw: ImageDraw.ImageDraw, scale: float, colour, width: float, offset=(0, 0)):
    """Stamp a round pen along the path.

    `ImageDraw.line` with a joint leaves miter spikes and scalloped edges at
    this scale; overlapping discs give an exact round cap and a clean edge.
    """
    pts = curve_points(scale, offset)
    w = max(1, round(width * scale))
    r = w / 2
    for p in pts:
        draw.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r], fill=colour)


def content_layer(colour, band_alpha: int, size: int = U * SS) -> Image.Image:
    """The mark alone, on transparency, in design coordinates."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    s = size / U
    band = colour + (band_alpha,)
    d.rounded_rectangle(
        [132 * s, 404 * s, 892 * s, 608 * s], radius=38 * s, fill=band
    )
    draw_curve(d, s, colour + (255,), 54, offset=(0, 0))

    # The sample point at the peak.
    # No marker: at launcher size a dot on the apex turns the curve into a
    # silhouette of a person. The curve and the band carry the meaning alone.
    return layer


def rounded_mask(size: int, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return mask


def circle_mask(size: int) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(mask)
    d.ellipse([0, 0, size - 1, size - 1], fill=255)
    return mask


def app_master() -> Image.Image:
    size = U * SS
    base = vertical_gradient(size, (200, 129, 100), (150, 74, 51))

    # A soft light from the upper left, so the flat colour does not look dead.
    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        [-size * 0.25, -size * 0.35, size * 0.75, size * 0.65], fill=90
    )
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.12))
    warm = Image.new("RGB", (size, size), (255, 236, 220))
    base = Image.composite(warm, base, glow.point(lambda v: int(v * 0.55)))

    base = base.convert("RGBA")
    base.alpha_composite(content_layer((255, 248, 241), 46, size))
    return base


def library_master() -> Image.Image:
    size = U * SS
    base = vertical_gradient(size, (30, 39, 58), (11, 17, 29)).convert("RGBA")

    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse(
        [size * 0.15, -size * 0.3, size * 1.05, size * 0.6], fill=70
    )
    glow = glow.filter(ImageFilter.GaussianBlur(size * 0.14))
    mint = Image.new("RGB", (size, size), (76, 196, 165))
    base = Image.composite(mint, base.convert("RGB"), glow.point(lambda v: int(v * 0.30))).convert("RGBA")

    # Hairline grid: enough to read as "instrument", not as decoration.
    grid = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gd2 = ImageDraw.Draw(grid)
    s = size / U
    for y in (300, 512, 724):
        gd2.line([150 * s, y * s, 874 * s, y * s], fill=(120, 220, 195, 20), width=max(1, round(1.5 * s)))

    base.alpha_composite(grid)
    base.alpha_composite(content_layer((111, 227, 192), 40, size))
    return base


def resize_to(img: Image.Image, px: int) -> Image.Image:
    return img.resize((px, px), Image.LANCZOS)


def save_png(img: Image.Image, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG", optimize=True)


# --- app icon -------------------------------------------------------------


def build_app_icons(root: Path) -> None:
    master = app_master()
    flat = master.convert("RGB").resize((U, U), Image.LANCZOS)
    rounded = master.resize((U, U), Image.LANCZOS)
    rounded.putalpha(rounded_mask(U, 232))
    circle = master.resize((U, U), Image.LANCZOS)
    circle.putalpha(circle_mask(U))

    for keep in (flat, rounded, circle):
        keep.load()

    # iOS: full bleed, no alpha, no rounding — the system masks it.
    ios_dir = root / "ios/Runner/Assets.xcassets/AppIcon.appiconset"
    contents = json.loads((ios_dir / "Contents.json").read_text())
    for entry in contents["images"]:
        name = entry.get("filename")
        if not name:
            continue
        base = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        px = round(base * scale)
        save_png(resize_to(flat, px), ios_dir / name)

    # Android legacy icons, plus an adaptive foreground and a monochrome layer.
    densities = {
        "mdpi": 1.0,
        "hdpi": 1.5,
        "xhdpi": 2.0,
        "xxhdpi": 3.0,
        "xxxhdpi": 4.0,
    }
    android = root / "android/app/src/main/res"
    content = content_layer((255, 248, 241), 46)
    bbox = content.getbbox()
    content = content.crop(bbox)

    for name, factor in densities.items():
        legacy = int(48 * factor)
        save_png(resize_to(rounded, legacy), android / f"mipmap-{name}/ic_launcher.png")
        save_png(resize_to(circle, legacy), android / f"mipmap-{name}/ic_launcher_round.png")

        canvas = int(108 * factor)
        fg = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        target = int(canvas * 0.62)
        scaled = content.copy()
        scaled.thumbnail((target, target), Image.LANCZOS)
        fg.alpha_composite(scaled, ((canvas - scaled.width) // 2, (canvas - scaled.height) // 2))
        save_png(fg, android / f"mipmap-{name}/ic_launcher_foreground.png")

        mono_content = content_layer((255, 255, 255), 70)
        mono_content = mono_content.crop(mono_content.getbbox())
        mono_content.thumbnail((target, target), Image.LANCZOS)
        mono = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
        mono.alpha_composite(mono_content, ((canvas - mono_content.width) // 2, (canvas - mono_content.height) // 2))
        save_png(mono, android / f"mipmap-{name}/ic_launcher_monochrome.png")

    # Windows .ico
    ico = rounded.copy()
    ico.save(
        root / "windows/runner/resources/app_icon.ico",
        sizes=[(16, 16), (24, 24), (32, 32), (40, 40), (48, 48), (64, 64), (128, 128), (256, 256)],
    )

    # Keep the source artwork in the repository, so the icon can be regenerated
    # without the rasteriser that produced it.
    save_png(resize_to(flat, 1024), root / "assets/icon.png")
    save_png(resize_to(rounded, 512), root / "assets/icon-rounded.png")


# --- library logo ---------------------------------------------------------


def build_library_assets(root: Path) -> None:
    master = library_master()
    rounded = master.resize((U, U), Image.LANCZOS)
    rounded.putalpha(rounded_mask(U, 232))
    save_png(resize_to(rounded.convert("RGB"), 1024), root / "assets/logo.png")
    save_png(resize_to(rounded.convert("RGB"), 256), root / "assets/logo-256.png")

    # GitHub social preview.
    card = Image.new("RGB", (1280, 640))
    bg = Image.new("RGB", (1280, 640), (11, 17, 30))
    grad = vertical_gradient(640, (18, 26, 43), (9, 13, 23)).resize((1280, 640))
    card.paste(grad)

    glow = Image.new("L", (1280, 640), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([40, 180, 360, 500], fill=70)
    glow = glow.filter(ImageFilter.GaussianBlur(90))
    card = Image.composite(Image.new("RGB", (1280, 640), (26, 61, 54)), card, glow.point(lambda v: int(v * 0.8)))

    logo = resize_to(rounded, 176)  # noqa: E501 — downscaled from the 1024 master
    card.paste(logo, (96, 232), logo)

    title_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 88)
    sub_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 32)
    small_font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 25)

    draw = ImageDraw.Draw(card)
    draw.text((312, 218), "hrt-pk-core", font=title_font, fill=(240, 246, 252))
    draw.text(
        (316, 330),
        "Offline pharmacokinetics for estradiol and testosterone HRT",
        font=sub_font,
        fill=(164, 180, 201),
    )
    draw.rounded_rectangle([316, 394, 436, 398], radius=2, fill=(111, 227, 192))
    draw.text(
        (316, 424),
        "JSON over C ABI  ·  Android · iOS · Windows · macOS · Linux",
        font=small_font,
        fill=(120, 138, 160),
    )

    # No decoration behind the text: a ghost curve at this scale only adds a
    # scalloped edge and competes with the subtitle.
    card.save(root / "assets/social-preview.png", "PNG", optimize=True)


def write_svg(root: Path) -> None:
    svg = """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024" role="img" aria-label="hrt-pk-core">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#1e273a"/>
      <stop offset="1" stop-color="#0b111d"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="232" fill="url(#bg)"/>
  <g stroke="#78dcc3" stroke-opacity="0.08" stroke-width="1.5">
    <line x1="150" y1="300" x2="874" y2="300"/>
    <line x1="150" y1="512" x2="874" y2="512"/>
    <line x1="150" y1="724" x2="874" y2="724"/>
  </g>
  <rect x="132" y="404" width="760" height="204" rx="38" fill="#6fe3c0" fill-opacity="0.16"/>
  <path d="M150 748 C244 744 312 718 354 600 C390 486 392 330 436 330 C506 330 560 470 622 566 C688 676 760 716 874 700"
        fill="none" stroke="#6fe3c0" stroke-width="54" stroke-linecap="round" stroke-linejoin="round"/>
</svg>
"""
    (root / "assets/logo.svg").write_text(svg, encoding="utf-8")


def main() -> None:
    app_root = Path(os.environ.get("APP_ROOT", Path(__file__).resolve().parents[1]))
    lib_root = Path(os.environ.get("LIB_ROOT", app_root.parent / "hrt-pk-core"))
    build_app_icons(app_root)
    build_library_assets(lib_root)
    write_svg(lib_root)
    print("app icons →", app_root)
    print("library logo →", lib_root)


if __name__ == "__main__":
    main()
