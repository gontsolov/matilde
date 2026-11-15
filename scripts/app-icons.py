#!/usr/bin/env python3
"""Render the alternative app icons in assets/app-icons/ to the PNGs bundled with Matilde.

    python3 scripts/app-icons.py                         # regenerate Resources/AppIcons/*.png
    python3 scripts/app-icons.py --sheet docs/app-icons.png
    python3 scripts/app-icons.py --iconset nib build/Nib.iconset   # every .icns size, for iconutil

The SVGs are the sources; the default icon stays assets/AppIcon.png. Choices and their order
come from the AppIconChoice enum in Sources/Matilde/AppIcon.swift. Needs `cairosvg` and Pillow
(pip install cairosvg pillow). The generated PNGs are committed, so CI and app builds need neither.
"""
import argparse
import io
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENUM = ROOT / "Sources/Matilde/AppIcon.swift"
SVG_DIR = ROOT / "assets/app-icons"
DEFAULT_SOURCE = ROOT / "assets/AppIcon.png"
PNG_DIR = ROOT / "Sources/Matilde/Resources/AppIcons"
FONT = ROOT / "Sources/Matilde/Resources/Fonts/Newsreader.ttf"
DEFAULT = "matilde"
# The Dock draws at most 256 points (512 pixels); Settings thumbnails are far smaller.
BUNDLED_SIZE = 512
ICONSET_SIZES = [16, 32, 128, 256, 512]


def choices(source=None):
    """Ordered (case, resource name) pairs from the AppIconChoice enum."""
    text = source if source is not None else ENUM.read_text()
    body = text.split("enum AppIconChoice", 1)[1].split("}", 1)[0]
    return re.findall(r'^\s*case (\w+) = "([a-z0-9-]+)"', body, re.M)


def svg_path(name):
    return SVG_DIR / f"{name}.svg"


def svg_info(name):
    """The <title> and <desc> of an icon's SVG: its display name and one-line style."""
    svg = svg_path(name).read_text()
    title = re.search(r"<title>(.*?)</title>", svg).group(1)
    desc = re.search(r"<desc>(.*?)</desc>", svg).group(1)
    return title, desc


def render(name, size):
    """RGBA image of one choice at size x size pixels."""
    from PIL import Image
    if name == DEFAULT:
        return Image.open(DEFAULT_SOURCE).convert("RGBA").resize((size, size), Image.LANCZOS)
    import cairosvg
    png = cairosvg.svg2png(url=str(svg_path(name)), output_width=size, output_height=size)
    return Image.open(io.BytesIO(png)).convert("RGBA")


def save_png(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    # No metadata, so unchanged icons regenerate byte-identical.
    image.save(path, optimize=True)


def bundle(names):
    from PIL import Image
    wanted = {f"{name}.png" for _, name in names}
    for stale in PNG_DIR.glob("*.png"):
        if stale.name not in wanted:
            stale.unlink()
    for _, name in names:
        # Render large and reduce, which keeps hairlines and dashes smooth.
        image = render(name, BUNDLED_SIZE * 2).resize((BUNDLED_SIZE, BUNDLED_SIZE), Image.LANCZOS)
        save_png(image, PNG_DIR / f"{name}.png")


def iconset(name, folder):
    """Every size iconutil expects, each rendered from the vector source."""
    for size in ICONSET_SIZES:
        save_png(render(name, size), folder / f"icon_{size}x{size}.png")
        save_png(render(name, size * 2), folder / f"icon_{size}x{size}@2x.png")


def contact_sheet(names, output):
    """Each choice at 1024 (shown at half size), 128, 32 and 16 pixels, on light and dark backgrounds."""
    from PIL import Image, ImageDraw, ImageFont
    col, head, pad = 600, 150, 40
    panel = 512 + 24 + 128 + 60
    width, height = col * len(names) + pad, head + 2 * panel + 3 * pad
    sheet = Image.new("RGB", (width, height), "#FFFFFF")
    draw = ImageDraw.Draw(sheet)

    def font(size, weight):
        f = ImageFont.truetype(str(FONT), size)
        try:
            f.set_variation_by_axes([weight, min(72, size)])
        except (OSError, ValueError):
            pass
        return f
    title_font, desc_font, small = font(38, 560), font(19, 400), ImageFont.truetype(str(FONT), 16)
    backgrounds = [("#F4F1EA", "#3D4038", "#8A877C"), ("#1E1F21", "#E4E2DC", "#8E8C86")]
    for index, (case, name) in enumerate(names):
        x = pad + index * col
        title, desc = ("Matilde (default)", "The current icon: a copper tilde pressed into handmade paper.") \
            if name == DEFAULT else svg_info(name)
        draw.text((x, 34), title, fill="#2B2A26", font=title_font)
        words, line, lines = desc.split(), "", []
        for word in words:
            trial = f"{line} {word}".strip()
            if draw.textlength(trial, font=desc_font) > col - 60 and line:
                lines.append(line)
                line = word
            else:
                line = trial
        lines.append(line)
        for n, text in enumerate(lines):
            draw.text((x, 84 + n * 24), text, fill="#6B685E", font=desc_font)
        big, mid, s32, s16 = render(name, 1024), render(name, 128), render(name, 32), render(name, 16)
        for row, (bg, ink, muted) in enumerate(backgrounds):
            top = head + pad + row * (panel + pad)
            draw.rectangle((x - pad // 2, top - pad // 2, x + col - pad // 2, top + panel - pad // 2), fill=bg)
            half = big.resize((512, 512), Image.LANCZOS)
            sheet.paste(half, (x, top), half)
            y = top + 512 + 24
            sheet.paste(mid, (x, y), mid)
            draw.text((x + 4, y + 130), "128", fill=muted, font=small)
            sheet.paste(s32, (x + 170, y + 48), s32)
            draw.text((x + 170, y + 130), "32", fill=muted, font=small)
            sheet.paste(s16, (x + 230, y + 56), s16)
            draw.text((x + 226, y + 130), "16", fill=muted, font=small)
            # The same 32 and 16 pixel renders enlarged 4x, pixel for pixel.
            z32 = s32.resize((128, 128), Image.NEAREST)
            z16 = s16.resize((64, 64), Image.NEAREST)
            sheet.paste(z32, (x + 290, y), z32)
            draw.text((x + 290, y + 130), "32 ×4", fill=muted, font=small)
            sheet.paste(z16, (x + 450, y + 32), z16)
            draw.text((x + 450, y + 130), "16 ×4", fill=muted, font=small)
            if index == 0:
                draw.text((x + 400, top + 512 - 26), "1024 at 50%", fill=muted, font=small)
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output, optimize=True)
    print(f"wrote {output}")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sheet", type=Path, help="also write a PNG contact sheet to this path")
    parser.add_argument("--iconset", nargs=2, metavar=("NAME", "FOLDER"), help="write an .iconset folder for one choice")
    args = parser.parse_args(argv)
    names = choices()
    bundle(names)
    print(f"rendered {len(names)} app icons at {BUNDLED_SIZE} px")
    if args.iconset:
        iconset(args.iconset[0], Path(args.iconset[1]))
    if args.sheet:
        contact_sheet(names, args.sheet)


if __name__ == "__main__":
    main(sys.argv[1:])
