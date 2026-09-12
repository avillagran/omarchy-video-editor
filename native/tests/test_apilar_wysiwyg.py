"""WYSIWYG apilar mapping must match Stream's drawCover semantics."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = (ROOT / "qml" / "OutputPreview.qml").read_text()
MAIN = (ROOT / "qml" / "main.qml").read_text()


class ApilarWysiwygContract(unittest.TestCase):
    def test_each_output_zone_centers_cover_crop_inside_selected_region(self):
        for video_id in ("vMain", "vBot"):
            block = re.search(
                rf"id: {video_id}(.*?)(?=\n          }}\n        }}|\n        // ----)",
                OUTPUT,
                re.S,
            )
            self.assertIsNotNone(block, video_id)
            text = block.group(1)
            self.assertIn("visibleW", text)
            self.assertIn("visibleH", text)
            self.assertIn("(rw - visibleW) / 2", text)
            self.assertIn("(rh - visibleH) / 2", text)

    def test_regions_remain_user_selected_source_crops(self):
        self.assertNotIn("fitApilarCrop", MAIN)
        set_region = re.search(r"function setRegion\(key, box\) \{(.*?)\n  \}", MAIN, re.S)
        self.assertIsNotNone(set_region)
        self.assertIn('if (key === "A") r.top = box; else r.bottom = box', set_region.group(1))


if __name__ == "__main__":
    unittest.main()
