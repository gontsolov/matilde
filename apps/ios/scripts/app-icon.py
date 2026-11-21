#!/usr/bin/env python3
"""Make the iOS app icon (IOS-11) from the Mac icon, apps/macos/assets/AppIcon.png.

iOS wants a full-bleed, opaque 1024 px square and rounds the corners itself, so the Mac icon's
own rounded body, bevel and shadow can't be used as they are. This keeps the paper and the
copper tilde exactly as drawn and replaces only the body's edge: the body is scaled to fill the
square, and its rim is covered with paper texture mirrored from a clean patch, blended in under a
soft rounded mask.

    python3 scripts/app-icon.py        # from apps/ios/, needs Pillow and numpy
"""
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent.parent
SOURCE = HERE.parent / "macos/assets/AppIcon.png"
TARGET = HERE / "Matilde/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
SIZE = 1024
# The body on the Mac icon's 1024 canvas (assets/app-icons/README.md): 870 x 861 at (77, 83).
BODY = (77, 83, 77 + 870, 83 + 861)


def main() -> None:
    source = Image.open(SOURCE).convert("RGBA")
    scale = source.width / 1024
    body = source.crop(tuple(round(v * scale) for v in BODY)).resize((SIZE, SIZE), Image.LANCZOS)

    # A clean paper patch above the tilde, mirrored into a seamless tile.
    patch = np.asarray(body.crop((300, 70, 724, 330)).convert("RGB"))
    tile = np.concatenate([patch, patch[:, ::-1]], axis=1)
    tile = np.concatenate([tile, tile[::-1]], axis=0)
    reps = (SIZE // tile.shape[0] + 1, SIZE // tile.shape[1] + 1, 1)
    paper = Image.fromarray(np.tile(tile, reps)[:SIZE, :SIZE])

    # Keep the drawn body inside its rim; feather the boundary.
    inset, radius = 64, 170
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle((inset, inset, SIZE - inset, SIZE - inset), radius=radius, fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(28))

    icon = Image.composite(body.convert("RGB"), paper, mask)
    TARGET.parent.mkdir(parents=True, exist_ok=True)
    icon.save(TARGET, optimize=True)
    print(f"wrote {TARGET.relative_to(HERE)} ({SIZE} x {SIZE}, opaque)")


if __name__ == "__main__":
    main()
