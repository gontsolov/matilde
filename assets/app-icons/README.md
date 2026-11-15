# Alternative app icons

Vector sources for the icons offered in Settings → General → App Icon. The default icon stays `assets/AppIcon.png`.

Every alternative keeps the default icon's layout exactly: the same continuous-corner body and the same tilde, in the same place and size, measured from `assets/AppIcon.png` (body 870 × 861 at (77, 83) on the 1024 canvas, corner 210; the tilde was traced from the copper original). Only colour, material and texture change.

| File | Name | Style |
| --- | --- | --- |
| `leather.svg` | Leather | The tilde debossed into oxblood leather and saddle-stitched along its length. |
| `neon.svg` | Neon | The tilde bent in glowing neon tube on a midnight wall. |
| `blueprint.svg` | Blueprint | The tilde drafted in dashed white lines on blueprint paper. |
| `chalk.svg` | Chalk | The tilde drawn in chalk on a smudged slate board. |

Each SVG defines the shared shapes once, as `#body`, `#tilde` (its outline) and `#spine` (its centre line, used for stitching and dashes); keep those three paths identical across files. Textures are vector patterns (seeded grain, grid, bricks, chalk drag marks), and the drop shadow and inner bevels are stacked strokes and offset clips, so any SVG renderer agrees and nothing needs fonts or bitmaps. Each SVG's `<title>` and `<desc>` are its display name and one-line style.

After editing an SVG, run `python3 scripts/app-icons.py` (needs `cairosvg` and Pillow) and commit the regenerated `Sources/Matilde/Resources/AppIcons/*.png`. `--sheet docs/app-icons.png` refreshes the contact sheet; `--iconset NAME FOLDER` writes every `.icns` size for `iconutil`. To add or remove a choice, also update the `AppIconChoice` enum in `Sources/Matilde/AppIcon.swift`.
