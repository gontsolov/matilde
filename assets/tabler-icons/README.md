# Tabler Icons sources

Unmodified SVGs from Tabler Icons `v3.52.0` (MIT, see `LICENSE`), limited to the icons listed in `Sources/Matilde/MatildeIcon.swift`. The app bundles the PDFs generated from them in `Sources/Matilde/Resources/Icons/`.

To add or change an icon, edit the `MatildeIcon` raw value and run:

```sh
python3 scripts/tabler-icons.py --sheet build/icon-contact-sheet.png
```

The script fetches missing SVGs from the pinned release and regenerates every PDF. It needs `cairosvg` (`pip install cairosvg`); `TABLER_VERSION` and `STROKE_WIDTH` sit at the top of the script.
