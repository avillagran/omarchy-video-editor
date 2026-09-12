"""Apilar source crops must match their vertical output-slot aspect ratios."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "qml" / "main.qml").read_text()


class ApilarOutputMapping(unittest.TestCase):
    def test_source_crop_geometry_is_not_rewritten_by_output_split(self):
        self.assertNotIn("fitApilarCrop", SOURCE)

    def test_split_does_not_overwrite_source_crop_positions(self):
        body = re.search(r"function setSplit\(f\) \{(.*?)\n  \}", SOURCE, re.S)
        self.assertIsNotNone(body)
        self.assertNotIn("regions.top", body.group(1))
        self.assertNotIn("regions.bottom", body.group(1))


if __name__ == "__main__":
    unittest.main()
