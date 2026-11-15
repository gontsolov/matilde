import importlib.util
import re
import unittest
import zlib
from pathlib import Path

ROOT = Path(__file__).parents[2]
spec = importlib.util.spec_from_file_location("tabler_icons", ROOT / "scripts/tabler-icons.py")
icons = importlib.util.module_from_spec(spec)
spec.loader.exec_module(icons)

# SF Symbols intentionally kept: menu items, where macOS draws its own menu imagery.
KEPT_SYSTEM_SYMBOLS = {"doc.on.doc", "trash"}


def pdf_objects(data):
    """Raw and decompressed PDF bodies, so object-stream dictionaries are visible."""
    parts = [data]
    for match in re.finditer(rb"stream\r?\n(.*?)endstream", data, re.S):
        try:
            parts.append(zlib.decompress(match.group(1)))
        except zlib.error:
            pass
    return b"\n".join(parts)


class IconResourceTests(unittest.TestCase):
    names = icons.icon_names()

    def test_enum_cases_are_unique(self):
        cases = [case for case, _ in self.names]
        files = [name for _, name in self.names]
        self.assertGreater(len(cases), 30)
        self.assertEqual(len(cases), len(set(cases)))
        self.assertEqual(len(files), len(set(files)))

    def test_every_icon_has_a_vendored_svg_and_single_page_vector_pdf(self):
        for case, name in self.names:
            with self.subTest(case=case):
                svg = icons.svg_path(name).read_text()
                self.assertIn('viewBox="0 0 24 24"', svg)
                pdf = (icons.PDF_DIR / f"{name}.pdf").read_bytes()
                self.assertTrue(pdf.startswith(b"%PDF-"))
                body = pdf_objects(pdf)
                self.assertRegex(body, rb"/Count 1\b")
                self.assertRegex(body, rb"/MediaBox \[ ?0 0 24 24 ?\]")
                self.assertNotIn(b"/Subtype /Image", body, "icons must stay vector")
                if not name.endswith(icons.FILLED):
                    self.assertIn(f"{icons.STROKE_WIDTH:g} w".encode(), body, "PDF is stale; rerun scripts/tabler-icons.py")

    def test_no_unused_icon_files(self):
        expected_pdfs = {f"{name}.pdf" for _, name in self.names}
        self.assertEqual({p.name for p in icons.PDF_DIR.glob("*.pdf")}, expected_pdfs)
        expected_svgs = {icons.svg_path(name) for _, name in self.names}
        self.assertEqual(set(icons.SVG_DIR.glob("*/*.svg")), expected_svgs)

    def test_license_and_bundling(self):
        for folder in (icons.SVG_DIR, icons.PDF_DIR):
            self.assertIn("MIT License", (folder / "LICENSE").read_text())
        self.assertIn(icons.TABLER_VERSION, (icons.PDF_DIR / "SOURCE.md").read_text())
        self.assertIn('.copy("Resources/Icons")', (ROOT / "Package.swift").read_text())

    def test_remaining_sf_symbols_are_deliberate(self):
        used = set()
        for path in (ROOT / "Sources").rglob("*.swift"):
            text = path.read_text()
            used |= set(re.findall(r'(?:systemName|systemImage|systemSymbolName):\s*"([^"]+)"', text))
            self.assertNotRegex(text, r"(?:systemName|systemImage|systemSymbolName):\s*[^\s\"]",
                                f"{path.name} builds an SF Symbol name dynamically")
        self.assertEqual(used, KEPT_SYSTEM_SYMBOLS)

    def test_contact_sheet_labels_cover_every_case(self):
        self.assertEqual(set(icons.SF_REPLACED), {case for case, _ in self.names})


if __name__ == "__main__":
    unittest.main()
