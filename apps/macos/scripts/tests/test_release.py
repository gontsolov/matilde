import importlib.util
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("release_version", Path(__file__).parents[1] / "release-version.py")
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class ReleaseVersionTests(unittest.TestCase):
    def test_numeric_order_for_updater(self):
        self.assertGreater(version.parse_version("0.10.0"), version.parse_version("0.9.9"))
        self.assertGreater(version.parse_version("1.0.0"), version.parse_version("0.99.99"))

    def test_rejects_invalid_or_ambiguous_release_inputs(self):
        for value in ["", "v1.2.3", "01.2.3", "1.2", "1.2.3-beta", "1.2.3\n", "1.100.0", "$(whoami)"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                version.parse_version(value)
