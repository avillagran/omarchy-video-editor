"""Regression checks for the apilar TOP/BOT region contract."""
from pathlib import Path
import re
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "qml" / "main.qml").read_text()


class ApilarRegionContract(unittest.TestCase):
    def test_default_top_box_uses_apilar_top_not_global_region(self):
        body = re.search(r"function activeBoxA\(\) \{(.*?)\n  \}", SOURCE, re.S)
        self.assertIsNotNone(body)
        self.assertIn('lay === "apilar" ? apilarTop', body.group(1))

    def test_top_and_bottom_keep_the_user_selected_source_crops(self):
        body = re.search(r"function setRegion\(key, box\) \{(.*?)\n  \}", SOURCE, re.S)
        self.assertIsNotNone(body)
        text = body.group(1)
        self.assertIn('if (key === "A") r.top = box; else r.bottom = box', text)


if __name__ == "__main__":
    unittest.main()
