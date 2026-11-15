# Alternative app icons

Vector sources for the icons offered in Settings → General → App Icon. The default icon stays `assets/AppIcon.png`.

| File | Name | Style |
| --- | --- | --- |
| `nib.svg` | Nib | Skeuomorphic: a polished brass fountain-pen nib on stitched oxblood leather. |
| `caret.svg` | Caret | Flat and geometric: a cream text cursor on terracotta, mid-sentence. |
| `typewriter.svg` | Typewriter | Tactile: a glass-topped, chrome-ringed typewriter key on olive felt, lettered in Newsreader. |
| `midnight.svg` | Midnight | Dark: a crescent moon over a lit page on deep ink blue. |
| `paper-plane.svg` | Paper Plane | Illustrated: a ruled notebook page folded into a paper plane on an apricot sky. |

Every file follows the macOS grid: a 1024 × 1024 canvas with an 824 × 824 continuous-corner body at (100, 100), a soft drop shadow drawn as stacked strokes (so any SVG renderer agrees), and a light top rim. Each SVG's `<title>` and `<desc>` are its display name and one-line style. Letters are outlined paths (the Typewriter “M” is Newsreader, SIL Open Font License, at weight 560 and optical size 72), so rendering needs no fonts.

After editing an SVG, run `python3 scripts/app-icons.py` (needs `cairosvg` and Pillow) and commit the regenerated `Sources/Matilde/Resources/AppIcons/*.png`. `--sheet docs/app-icons.png` refreshes the contact sheet; `--iconset NAME FOLDER` writes every `.icns` size for `iconutil`. To add or remove a choice, also update the `AppIconChoice` enum in `Sources/Matilde/AppIcon.swift`.
