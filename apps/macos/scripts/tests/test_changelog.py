import importlib.util
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("changelog", Path(__file__).parents[1] / "changelog.py")
changelog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(changelog)

GOOD = """---
version: 1.2.3
date: 2026-12-01
title: A small thing
matilde: Hello there.
---

A short intro
over two lines.

- **One** thing, with a [link](https://matilde.page).
- Another
  that wraps.
"""


class ChangelogTests(unittest.TestCase):
    def write(self, folder, name, text):
        path = Path(folder) / name
        path.write_text(text, encoding="utf-8")
        return path

    def test_every_committed_entry_is_valid(self):
        found = changelog.entries()
        self.assertGreater(len(found), 0)
        versions = [fields["version"] for fields, _ in found]
        self.assertEqual(versions, sorted(versions, key=lambda v: tuple(map(int, v.split("."))), reverse=True))

    def test_the_current_app_version_has_an_entry(self):
        import json
        config = json.loads((Path(__file__).parents[2] / "Config/release.json").read_text())
        changelog.require(config["version"])

    def test_missing_entry_fails_the_release(self):
        with tempfile.TemporaryDirectory() as folder, self.assertRaises(changelog.ChangelogError) as error:
            changelog.require("9.9.9", root=folder)
        self.assertIn("changelog/9.9.9.md", str(error.exception))

    def test_parses_front_matter_paragraphs_and_bullets(self):
        with tempfile.TemporaryDirectory() as folder:
            fields, body = changelog.parse(self.write(folder, "1.2.3.md", GOOD))
        self.assertEqual(fields["title"], "A small thing")
        self.assertEqual(changelog.blocks(body), [
            ("p", "A short intro over two lines."),
            ("ul", ["**One** thing, with a [link](https://matilde.page).", "Another that wraps."]),
        ])
        fragment = changelog.to_html(fields, body)
        self.assertNotIn("DOCTYPE", fragment)
        self.assertNotIn("<body", fragment)
        self.assertIn('<strong>One</strong> thing, with a <a href="https://matilde.page">link</a>.', fragment)

    def test_rejects_bad_entries(self):
        cases = {
            "1.2.3.md": GOOD.replace("title: A small thing\n", ""),
            "1.2.4.md": GOOD,  # file name doesn't match the version
            "1.2.5.md": GOOD.replace("version: 1.2.3", "version: 1.2.5").replace("2026-12-01", "1 Dec"),
            "1.2.6.md": GOOD.replace("version: 1.2.3", "version: 1.2.6").replace("Hello there.", '"Quoted"'),
            "1.2.7.md": GOOD.replace("version: 1.2.3", "version: 1.2.7").replace("Another", "Fixed (#42)"),
            "1.2.8.md": GOOD.replace("version: 1.2.3", "version: 1.2.8").replace("Another", "Nothing is read by us"),
            "1.2.9.md": GOOD.replace("version: 1.2.3", "version: 1.2.9").replace("Another", "Edit `AppModel.swift`"),
        }
        with tempfile.TemporaryDirectory() as folder:
            for name, text in cases.items():
                with self.subTest(name=name), self.assertRaises(changelog.ChangelogError):
                    changelog.parse(self.write(folder, name, text))


if __name__ == "__main__":
    unittest.main()
