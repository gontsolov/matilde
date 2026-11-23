#!/usr/bin/env python3
"""Vendor Tabler Icons named in MatildeIcon.swift and convert them to template PDFs.

    python3 scripts/tabler-icons.py            # fetch missing SVGs, regenerate every PDF
    python3 scripts/tabler-icons.py --sheet build/icons.png   # also render a contact sheet

Needs network access for missing SVGs and `cairosvg` (pip install cairosvg) to convert.
The generated PDFs are committed, so CI and app builds need neither.
"""
import argparse
import re
import sys
import urllib.request
from pathlib import Path

TABLER_VERSION = "v3.52.0"
# Tabler draws a 2-point stroke on its 24-point grid; this lighter weight suits Matilde's controls.
STROKE_WIDTH = 1.5

ROOT = Path(__file__).resolve().parents[1]
ENUM = ROOT / "Sources/Matilde/MatildeIcon.swift"
SVG_DIR = ROOT / "assets/tabler-icons"
PDF_DIR = ROOT / "Sources/Matilde/Resources/Icons"
FILLED = "-filled"


def icon_names(source=None):
    """Ordered (case, Tabler name) pairs from the MatildeIcon enum."""
    text = source if source is not None else ENUM.read_text()
    return re.findall(r'^\s*case (\w+) = "([a-z0-9-]+)"', text, re.M)


def svg_path(name):
    return SVG_DIR / ("filled" if name.endswith(FILLED) else "outline") / (name.removesuffix(FILLED) + ".svg")


def fetch(name):
    path = svg_path(name)
    if path.exists():
        return
    url = f"https://raw.githubusercontent.com/tabler/tabler-icons/{TABLER_VERSION}/icons/{path.parent.name}/{path.name}"
    path.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url) as response:
        path.write_bytes(response.read())
    print(f"fetched {path.relative_to(ROOT)}")


def prepared_svg(name, stroke=STROKE_WIDTH, color="#000"):
    svg = svg_path(name).read_text()
    svg = re.sub(r"<!--.*?-->", "", svg, flags=re.S).strip()
    if 'stroke-width="2"' in svg:
        svg = svg.replace('stroke-width="2"', f'stroke-width="{stroke:g}"')
    return svg.replace("currentColor", color)


def pdf_surface():
    """cairosvg's PDF surface with a fixed creation date, so unchanged icons regenerate byte-identical."""
    import cairocffi
    import cairosvg.surface

    class FixedDatePDF(cairocffi.PDFSurface):
        def __init__(self, *args, **kwargs):
            super().__init__(*args, **kwargs)
            self.set_metadata(cairocffi.PDF_METADATA_CREATE_DATE, "2026-01-01T00:00:00Z")

    class Surface(cairosvg.surface.PDFSurface):
        surface_class = FixedDatePDF
    return Surface


def convert(names):
    surface = pdf_surface()
    PDF_DIR.mkdir(parents=True, exist_ok=True)
    wanted = {f"{name}.pdf" for _, name in names}
    for stale in PDF_DIR.glob("*.pdf"):
        if stale.name not in wanted:
            stale.unlink()
    for _, name in names:
        # 72 dpi keeps the page at Tabler's 24 x 24 point grid.
        pdf = surface.convert(bytestring=prepared_svg(name).encode(), dpi=72)
        (PDF_DIR / f"{name}.pdf").write_bytes(pdf)


def contact_sheet(names, output):
    """Each icon at Tabler's default stroke and Matilde's stroke, in light and dark, beside the SF Symbol it replaces."""
    import io
    import cairosvg
    from PIL import Image, ImageDraw, ImageFont
    replaced = sf_symbols()
    scale, columns, cell_w, cell_h = 2, 3, 400, 64
    rows = (len(names) + columns - 1) // columns
    sheet = Image.new("RGB", (columns * cell_w * scale, (rows * cell_h + 40) * scale), "#f6f2e8")
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("DejaVuSans.ttf", 11 * scale)
        small = ImageFont.truetype("DejaVuSans.ttf", 9 * scale)
    except OSError:
        font = small = ImageFont.load_default()
    draw.text((12 * scale, 12 * scale), f"Tabler {TABLER_VERSION}: default 2.0 stroke | Matilde {STROKE_WIDTH:g} at 16/24 pt | dark",
              fill="#3b3a33", font=font)

    def render(name, stroke, color, size):
        png = cairosvg.svg2png(bytestring=prepared_svg(name, stroke, color).encode(),
                               output_width=size * scale, output_height=size * scale)
        return Image.open(io.BytesIO(png)).convert("RGBA")

    for index, (case, name) in enumerate(names):
        x = (index % columns) * cell_w * scale
        y = ((index // columns) * cell_h + 40) * scale
        sheet.paste(render(name, 2, "#3b3a33", 24), (x + 10 * scale, y + 4 * scale), render(name, 2, "#3b3a33", 24))
        sheet.paste(render(name, STROKE_WIDTH, "#3b3a33", 24), (x + 44 * scale, y + 4 * scale),
                    render(name, STROKE_WIDTH, "#3b3a33", 24))
        sheet.paste(render(name, STROKE_WIDTH, "#3b3a33", 16), (x + 78 * scale, y + 8 * scale),
                    render(name, STROKE_WIDTH, "#3b3a33", 16))
        draw.rounded_rectangle((x + 100 * scale, y, x + 132 * scale, y + 32 * scale), 5 * scale, fill="#1c1d1f")
        sheet.paste(render(name, STROKE_WIDTH, "#d9d6cf", 24), (x + 104 * scale, y + 4 * scale),
                    render(name, STROKE_WIDTH, "#d9d6cf", 24))
        draw.text((x + 142 * scale, y + 2 * scale), f".{case}  {name}", fill="#3b3a33", font=font)
        old = ", ".join(replaced.get(case, [])) or "(new)"
        draw.text((x + 142 * scale, y + 18 * scale), f"was SF {old}", fill="#7a776c", font=small)
    output.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(output)
    print(f"wrote {output}")


# The SF Symbols each case replaced, for the contact sheet and review.
SF_REPLACED = {
    "sidebar": ["sidebar.left"], "newDocument": ["square.and.pencil"], "document": ["doc.text"],
    "board": ["square.grid.2x2"], "more": ["ellipsis.circle"], "stash": ["tray", "tray.fill"],
    "askMatilde": ["text.bubble", "text.bubble.fill"], "askMatildeError": ["exclamationmark.bubble"],
    "stop": ["stop.circle"], "search": ["magnifyingglass"], "clear": ["xmark.circle.fill"],
    "newFolder": ["folder.badge.plus"], "folder": ["folder"], "folderOpen": ["folder.fill"],
    "settings": ["gearshape"], "chevronRight": ["chevron.right"], "chevronDown": ["chevron.down"],
    "chevronUp": ["chevron.up"], "plus": ["plus"], "minus": ["minus"], "close": ["xmark"],
    "check": ["checkmark"], "branch": ["arrow.triangle.branch"], "goal": ["flag"],
    "compare": ["rectangle.split.2x1"], "fit": ["arrow.up.left.and.arrow.down.right"],
    "activeDraft": ["pencil.tip"], "note": ["note.text"], "archive": ["archivebox"],
    "done": ["checkmark.circle.fill"], "send": ["arrow.up.circle.fill"], "stopReply": ["stop.circle.fill"],
    "typography": ["textformat"], "key": ["key"], "sync": [], "heading": ["textformat.size"], "bulletList": ["list.bullet"],
    "numberedList": ["list.number"], "checkbox": ["checkmark.square"], "quote": ["text.quote"],
    "codeBlock": ["curlybraces"], "bold": ["bold"], "italic": ["italic"],
    "inlineCode": ["chevron.left.forwardslash.chevron.right"], "link": ["link"], "photo": ["photo"],
    "devices": ["laptopcomputer.and.iphone"], "laptop": ["laptopcomputer"], "phone": ["iphone"],
    "lock": ["lock"], "world": ["globe.europe.africa"], "cloudLock": ["key.icloud"],
    "alert": ["exclamationmark.circle"], "circleCheck": ["checkmark.circle"],
    "refresh": ["arrow.triangle.2.circlepath"], "download": ["square.and.arrow.down", "arrow.down.app"],
    "printer": ["printer"], "copy": ["doc.on.doc"],
    "trash": ["trash"], "save": [], "sparkles": [], "feedback": [], "sun": [], "moon": [], "sunMoon": [], "spellCheck": [],
}


def sf_symbols():
    return SF_REPLACED


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sheet", type=Path, help="also write a PNG contact sheet to this path")
    args = parser.parse_args(argv)
    names = icon_names()
    for _, name in names:
        fetch(name)
    convert(names)
    print(f"converted {len(names)} icons at stroke {STROKE_WIDTH:g} from Tabler {TABLER_VERSION}")
    if args.sheet:
        contact_sheet(names, args.sheet)


if __name__ == "__main__":
    main(sys.argv[1:])
