"""Regression tests for Omareel's project-serializable layer keyframes."""
import os
import json
from pathlib import Path
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
from PySide6.QtCore import QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QJSEngine

APP = QGuiApplication.instance() or QGuiApplication([])
ROOT = Path(__file__).resolve().parents[1]
OVERLAY_SOURCE = (ROOT / "qml" / "OverlayLayers.qml").read_text()
MAIN_SOURCE = (ROOT / "qml" / "main.qml").read_text()
ENGINE_SOURCE = (ROOT / "src" / "engine.cpp").read_text()


class KeyframeInterpolation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.engine = QJSEngine()
        source = ROOT / "qml" / "Keyframes.js"
        cls.result = cls.engine.evaluate(source.read_text(), source.as_uri())
        if cls.result.isError():
            raise AssertionError(cls.result.toString())
        cls.api = cls.engine.globalObject()

    def evaluate(self, layer, time):
        js_layer = self.engine.evaluate("(" + json.dumps(layer) + ")")
        return self.api.property("at").call([js_layer, time]).toVariant()

    def opacity(self, layer, time):
        js_layer = self.engine.evaluate("(" + json.dumps(layer) + ")")
        return self.api.property("opacityAt").call([js_layer, time]).toNumber()

    def patched_frames(self, layer, patch, time, easing="linear"):
        js_layer = self.engine.evaluate("(" + json.dumps(layer) + ")")
        js_patch = self.engine.evaluate("(" + json.dumps(patch) + ")")
        return self.api.property("patchedFrames").call([js_layer, js_patch, time, easing]).toVariant()

    def test_interpolates_numeric_properties_between_keyframes(self):
        layer = {
            "x": 0.1, "y": 0.2, "size": 40,
            "keyframes": [
                {"time": 0, "x": 0.1, "y": 0.2, "size": 40, "easing": "linear"},
                {"time": 2, "x": 0.9, "y": 0.8, "size": 100},
            ],
        }
        value = self.evaluate(layer, 1)
        self.assertAlmostEqual(value["x"], 0.5)
        self.assertAlmostEqual(value["y"], 0.5)
        self.assertAlmostEqual(value["size"], 70)

    def test_uses_selected_tween_and_holds_non_numeric_properties(self):
        layer = {
            "x": 0.0, "color": "#ffffff",
            "keyframes": [
                {"time": 0, "x": 0.0, "color": "#ffffff", "easing": "easeOut"},
                {"time": 1, "x": 1.0, "color": "#ff0000"},
            ],
        }
        value = self.evaluate(layer, 0.5)
        self.assertAlmostEqual(value["x"], 0.75)
        self.assertEqual(value["color"], "#ffffff")
        self.assertEqual(self.evaluate(layer, 1)["color"], "#ff0000")

    def test_clamps_before_first_and_after_last_keyframe(self):
        layer = {"x": 0.5, "keyframes": [{"time": 2, "x": 0.2}, {"time": 4, "x": 0.8}]}
        self.assertAlmostEqual(self.evaluate(layer, 0)["x"], 0.2)
        self.assertAlmostEqual(self.evaluate(layer, 9)["x"], 0.8)

    def test_duplicate_times_are_deduplicated_with_last_frame_winning(self):
        layer = {
            "x": 0.1,
            "keyframes": [
                {"time": 1, "x": 0.4, "px": 0.8},
                {"time": 1, "x": 0.6},
            ],
        }
        value = self.evaluate(layer, 1)
        self.assertAlmostEqual(value["x"], 0.6)
        self.assertNotIn("px", value)

    def test_layer_fades_are_combined_with_static_opacity(self):
        layer = {
            "inS": 1, "outS": 5, "fadeIn": 1, "fadeOut": 2, "opacity": 0.8,
        }
        self.assertAlmostEqual(self.opacity(layer, 1), 0)
        self.assertAlmostEqual(self.opacity(layer, 2), 0.8)
        self.assertAlmostEqual(self.opacity(layer, 4), 0.4)
        self.assertAlmostEqual(self.opacity(layer, 5), 0)

    def test_layer_fades_are_combined_with_keyframed_opacity(self):
        layer = {
            "inS": 0, "outS": 4, "fadeIn": 0, "fadeOut": 0, "opacity": 1,
            "keyframes": [
                {"time": 0, "opacity": 0.2, "easing": "linear"},
                {"time": 2, "opacity": 1},
            ],
        }
        self.assertAlmostEqual(self.opacity(layer, 0), 0.2)
        self.assertAlmostEqual(self.opacity(layer, 1), 0.6)
        self.assertAlmostEqual(self.opacity(layer, 2), 1)

    def test_zero_is_a_valid_layer_coordinate(self):
        self.assertNotIn("l.x || 0.5", OVERLAY_SOURCE)
        self.assertNotIn("l.y || 0.5", OVERLAY_SOURCE)
        self.assertNotIn("l.w || 0.35", OVERLAY_SOURCE)
        self.assertNotIn("l.h || 0.20", OVERLAY_SOURCE)

    def test_inserting_a_keyframe_captures_the_evaluated_playhead_state(self):
        self.assertIn("Keyframes.at(layer, time)", MAIN_SOURCE)
        self.assertIn("if (frames.length && animatedPatch)", MAIN_SOURCE)
        self.assertIn("Keyframes.patchedFrames(layer, patch, time", MAIN_SOURCE)

    def test_editing_an_animated_layer_creates_a_distinct_second_pose(self):
        layer = {
            "x": 0.2,
            "keyframes": [{"time": 0, "x": 0.2, "easing": "easeInOut"}],
        }
        frames = self.patched_frames(layer, {"x": 0.8}, 2, "easeOut")
        self.assertEqual(len(frames), 2)
        self.assertEqual(frames[0]["x"], 0.2)
        self.assertEqual(frames[1]["time"], 2)
        self.assertEqual(frames[1]["x"], 0.8)
        self.assertEqual(frames[1]["easing"], "easeOut")

    def test_export_evaluates_keyframed_opacity_per_frame(self):
        self.assertIn('animatedValue(layer, QStringLiteral("opacity"), 1.0)', ENGINE_SOURCE)
        self.assertIn("alpha(X,Y)*clip", ENGINE_SOURCE)

    def test_export_keeps_the_left_interval_at_exact_keyframe_boundaries(self):
        self.assertIn('expression = QStringLiteral("if(lte(t,%1),%2,%3)")', ENGINE_SOURCE)
        self.assertIn("!left.contains(programKey) && right.contains(programKey)", ENGINE_SOURCE)
        self.assertIn("i + 1 == frames.size() - 1 && left.contains(programKey) && !right.contains(programKey)", ENGINE_SOURCE)
        self.assertIn("boundarySwitches ? QStringLiteral(\"lt\") : QStringLiteral(\"lte\")", ENGINE_SOURCE)


if __name__ == "__main__":
    unittest.main()
