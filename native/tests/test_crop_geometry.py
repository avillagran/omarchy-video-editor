"""Crop regions shown in PROGRAM must equal pixels consumed by OUTPUT."""
import json
import os
from pathlib import Path
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QJSEngine

APP = QGuiApplication.instance() or QGuiApplication([])
ROOT = Path(__file__).resolve().parents[1]


class CropGeometry(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine = QJSEngine()
        source = ROOT / "qml" / "CropGeometry.js"
        result = cls.engine.evaluate(source.read_text(), source.as_uri())
        if result.isError():
            raise AssertionError(result.toString())
        cls.fit_fn = cls.engine.globalObject().property("fit")
        cls.fit_corner_fn = cls.engine.globalObject().property("fitCorner")

    def fit(self, box, aspect, sw=1920, sh=1080):
        js_box = self.engine.evaluate("(" + json.dumps(box) + ")")
        return self.fit_fn.call([js_box, aspect, sw, sh]).toVariant()

    def fit_corner(self, box, corner, aspect, sw=1920, sh=1080):
        js_box = self.engine.evaluate("(" + json.dumps(box) + ")")
        return self.fit_corner_fn.call([js_box, corner, aspect, sw, sh]).toVariant()

    def assert_source_aspect(self, box, expected, places=5):
        actual = (box["w"] * 1920) / (box["h"] * 1080)
        self.assertAlmostEqual(actual, expected, places=places)

    def test_full_output_region_is_9_by_16_and_keeps_center(self):
        fitted = self.fit({"x": 0, "y": 0, "w": 100, "h": 100}, 9 / 16)
        self.assert_source_aspect(fitted, 9 / 16)
        self.assertAlmostEqual(fitted["x"] + fitted["w"] / 2, 50)
        self.assertAlmostEqual(fitted["y"] + fitted["h"] / 2, 50)

    def test_apilar_regions_match_each_output_slot(self):
        top = self.fit({"x": 10, "y": 10, "w": 70, "h": 70}, (9 / 16) / 0.35)
        bottom = self.fit({"x": 10, "y": 10, "w": 70, "h": 70}, (9 / 16) / 0.65)
        self.assert_source_aspect(top, (9 / 16) / 0.35)
        self.assert_source_aspect(bottom, (9 / 16) / 0.65)

    def test_pip_foreground_region_is_square_in_source_pixels(self):
        fitted = self.fit({"x": 20, "y": 20, "w": 50, "h": 50}, 1)
        self.assert_source_aspect(fitted, 1)

    def test_corner_resize_keeps_the_opposite_corner_fixed(self):
        original = {"x": 20, "y": 20, "w": 30, "h": 50}
        for corner, opposite in (("se", (20, 20)), ("nw", (50, 70)),
                                 ("ne", (20, 70)), ("sw", (50, 20))):
            fitted = self.fit_corner(original, corner, 9 / 16)
            ox = fitted["x"] if corner.endswith("e") else fitted["x"] + fitted["w"]
            oy = fitted["y"] if corner.startswith("s") else fitted["y"] + fitted["h"]
            self.assertAlmostEqual(ox, opposite[0], places=6, msg=corner)
            self.assertAlmostEqual(oy, opposite[1], places=6, msg=corner)
            self.assert_source_aspect(fitted, 9 / 16)


if __name__ == "__main__":
    unittest.main()
