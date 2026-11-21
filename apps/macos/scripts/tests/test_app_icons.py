import importlib.util
import re
import struct
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[2]  # apps/macos
REPO = ROOT.parents[1]
spec = importlib.util.spec_from_file_location("app_icons", ROOT / "scripts/app-icons.py")
app_icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app_icons)


def png_header(path):
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n"), path
    width, height, depth, color = struct.unpack(">IIBB", data[16:26])
    return width, height, color


class AppIconTests(unittest.TestCase):
    names = app_icons.choices()

    def test_default_comes_first_and_names_are_unique(self):
        self.assertEqual(self.names[0], ("matilde", app_icons.DEFAULT))
        self.assertGreaterEqual(len(self.names), 5)
        self.assertEqual(len({n for _, n in self.names}), len(self.names))

    def test_every_alternative_has_a_grid_aligned_svg(self):
        for case, name in self.names[1:]:
            with self.subTest(case=case):
                svg = app_icons.svg_path(name).read_text()
                self.assertIn('viewBox="0 0 1024 1024"', svg)
                body = re.search(r'<path id="body" d="([^"]+)"', svg).group(1)
                numbers = [float(v) for v in re.findall(r"-?\d+(?:\.\d+)?", body)]
                self.assertEqual((min(numbers), max(numbers)), (77, 947), "the default icon's body")
                self.assertNotIn("<image", svg, "sources stay vector")
                self.assertNotIn("<text", svg, "letters are outlined so rendering needs no fonts")
                title, desc = app_icons.svg_info(name)
                self.assertTrue(title and desc)
        self.assertEqual({p.stem for p in app_icons.SVG_DIR.glob("*.svg")}, {n for _, n in self.names[1:]})

    def test_alternatives_share_one_layout(self):
        """Every alternative draws the same body and the same tilde; only materials differ."""
        shapes = set()
        for _, name in self.names[1:]:
            svg = app_icons.svg_path(name).read_text()
            shapes.add(tuple(re.search(rf'<path id="{part}" d="([^"]+)"', svg).group(1) for part in ("body", "tilde", "spine")))
        self.assertEqual(len(shapes), 1)

    def test_every_choice_is_bundled_as_a_512_px_rgba_png(self):
        self.assertEqual({p.stem for p in app_icons.PNG_DIR.glob("*.png")}, {n for _, n in self.names})
        for _, name in self.names:
            with self.subTest(name=name):
                self.assertEqual(png_header(app_icons.PNG_DIR / f"{name}.png"), (512, 512, 6))

    def test_titles_match_the_swift_enum(self):
        swift = app_icons.ENUM.read_text()
        for case, name in self.names[1:]:
            title, _ = app_icons.svg_info(name)
            self.assertIn(f'case .{case}: return "{title}"', swift)

    def test_gold_foil_is_gone(self):
        """Removed choice: no case, source or bundled image, so a saved value falls back to the default."""
        self.assertNotIn("gold-foil", {n for _, n in self.names})
        self.assertFalse(app_icons.svg_path("gold-foil").exists())
        self.assertFalse((app_icons.PNG_DIR / "gold-foil.png").exists())

    def test_bundling(self):
        self.assertIn('.copy("Resources/AppIcons")', (ROOT / "Package.swift").read_text())
        self.assertTrue(re.search(r"AppIcons/\*\.png", (REPO / ".github/workflows/ci.yml").read_text()))


if __name__ == "__main__":
    unittest.main()
