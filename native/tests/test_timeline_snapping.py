#!/usr/bin/env python3
"""Real Qt mouse gestures against Timeline.qml (requires PySide6).

Run: QT_QPA_PLATFORM=offscreen python3 native/tests/test_timeline_snapping.py
"""
import os
import warnings
from pathlib import Path
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_BACKEND", "software")
warnings.filterwarnings("ignore", category=DeprecationWarning)
from PySide6.QtCore import QCoreApplication, QEvent, QObject, QPoint, QPointF, QUrl, Qt
from PySide6.QtGui import QGuiApplication, QMouseEvent
from PySide6.QtQml import QQmlComponent, QQmlPropertyMap
from PySide6.QtQuick import QQuickView
from PySide6.QtTest import QTest

APP = QGuiApplication.instance() or QGuiApplication([])
QML_DIR = Path(__file__).resolve().parents[1] / "qml"


class TimelineSnapping(unittest.TestCase):
    def setUp(self):
        warnings.simplefilter("ignore", DeprecationWarning)
        self.view = QQuickView()
        self.engine_context = QQmlPropertyMap()
        self.engine_context.insert("theme", {
            "panel": "#151515", "panelDeep": "#111111", "panelAlt": "#181818", "border": "#333333", "radius": 4,
            "text": "#ffffff", "textMuted": "#aaaaaa", "textDim": "#777777",
            "accent": "#55aaff", "accentSoft": "#223344", "magenta": "#dd66ff",
            "orange": "#ffaa44", "cyan": "#66ddff", "playhead": "#ff5577",
            "good": "#66dd88", "bad": "#ff5577", "warn": "#ddaa55", "fontMono": "monospace",
        })
        self.view.engine().rootContext().setContextProperty("engine", self.engine_context)
        self.component = QQmlComponent(self.view.engine())
        component = self.component
        component.setData(('''import QtQuick
import "%s"
Timeline {
    id: harness
    width: 1050; height: 260
    duration: 20; zoom: 50; position: 5
    trimIn: 1; trimOut: 18
    layers: [{inS: 2, outS: 4, text: "First"}, {inS: 8, outS: 10, text: "Second"}]
    videoPresent: false
    blocks: [{start: 12, end: 14, layout: "completa"}]
    property real lastA: -1
    property real lastB: -1
    property int deleteCount: 0
    property string trackLabel0: layerTrackLabel(0)
    property string trackLabel1: layerTrackLabel(1)
    property string trackLabel2: layerTrackLabel(2)
    property bool applyEdits: false
    onLayerEdited: function(i, a, b) {
        lastA = a; lastB = b
        if (applyEdits) {
            layers[i].inS = a; layers[i].outS = b
            if ("layersRev" in harness) harness.layersRev++
        }
    }
    onBlockEdited: function(i, patch) {
        lastA = patch.start === undefined ? blocks[i].start : patch.start
        lastB = patch.end === undefined ? blocks[i].end : patch.end
        if (applyEdits) {
            blocks[i].start = lastA; blocks[i].end = lastB
            if ("blocksRev" in harness) harness.blocksRev++
        }
    }
    onTrimEdited: function(a, b) { lastA = a; lastB = b }
    onDeleteVideoRequested: deleteCount++
}
''' % QML_DIR.as_uri()).encode(), QUrl())
        self.assertFalse(component.isError(), str(component.errors()))
        self.timeline = component.create()
        self.assertIsNotNone(self.timeline, str(component.errors()))
        self.view.setContent(QUrl(), component, self.timeline)
        self.view.show()
        QTest.qWait(30)

    def tearDown(self):
        self.view.close()
        self.timeline.deleteLater()
        self.view.deleteLater()
        APP.processEvents()
        QCoreApplication.sendPostedEvents(None, QEvent.DeferredDelete)

    def point(self, seconds, y):
        return QPoint(round(self.timeline.property("headW") + 1
                            + seconds * self.timeline.property("zoom")), y)

    def drag(self, start, end, button=Qt.LeftButton, modifiers=Qt.NoModifier):
        QTest.mousePress(self.view, button, modifiers, start)
        QTest.mouseMove(self.view, end, 20)
        QTest.mouseRelease(self.view, button, modifiers, end)
        APP.processEvents()

    def test_layer_move_snaps_to_other_clip_boundaries(self):
        for raw_start, expected in [(5.9, 6), (7.9, 8), (9.9, 10),
                                    (11.9, 12), (13.9, 14), (15.9, 16),
                                    (0.1, 0), (17.9, 18), (2.1, 2.1)]:
            with self.subTest(raw_start=raw_start):
                self.drag(self.point(3, 120), self.point(raw_start + 1, 120))
                self.assertAlmostEqual(self.timeline.property("lastA"), expected)
                self.assertAlmostEqual(self.timeline.property("lastB"), expected + 2)

    def test_snapping_toggle_is_clickable_and_keyboard_accessible(self):
        self.assertEqual(self.timeline.property("snappingEnabled"), True)
        QTest.mouseClick(self.view, Qt.LeftButton, Qt.NoModifier, QPoint(24, 94))
        self.assertEqual(self.timeline.property("snappingEnabled"), False)
        self.drag(self.point(3, 120), self.point(5.9, 120))
        self.assertAlmostEqual(self.timeline.property("lastA"), 4.9)
        QTest.mouseClick(self.view, Qt.LeftButton, Qt.NoModifier, QPoint(24, 94))
        self.assertEqual(self.timeline.property("snappingEnabled"), True)
        QTest.keyClick(self.view, Qt.Key_Space)
        self.assertEqual(self.timeline.property("snappingEnabled"), False)

    def test_video_track_trash_button_emits_delete_request(self):
        self.timeline.setProperty("videoPresent", True)
        button = self.timeline.findChild(QObject, "deleteVideoButton")
        self.assertIsNotNone(button)
        button.clicked.emit()
        self.assertEqual(self.timeline.property("deleteCount"), 1)

    def test_video_layers_are_numbered_after_main_v1_track(self):
        self.timeline.setProperty("layers", [
            {"type": "video", "inS": 0, "outS": 4},
            {"type": "text", "inS": 0, "outS": 4},
            {"type": "video", "inS": 4, "outS": 8},
        ])
        QTest.qWait(20)
        self.assertEqual(self.timeline.property("trackLabel0"), "V2")
        self.assertEqual(self.timeline.property("trackLabel1"), "T1")
        self.assertEqual(self.timeline.property("trackLabel2"), "V3")

    def test_alt_temporarily_bypasses_snapping_during_drag(self):
        start = self.point(3, 120)
        end = self.point(5.9, 120)
        QTest.mousePress(self.view, Qt.LeftButton, Qt.NoModifier, start)
        QTest.keyPress(self.view, Qt.Key_Alt)
        # QTest.mouseMove has no modifiers parameter and clears keyboard
        # modifiers. Deliver the actual modified pointer event to the window.
        APP.sendEvent(self.view, QMouseEvent(QEvent.MouseMove, QPointF(end),
                      QPointF(self.view.mapToGlobal(end)), Qt.NoButton,
                      Qt.LeftButton, Qt.AltModifier))
        self.assertAlmostEqual(self.timeline.property("lastA"), 4.9)
        QTest.keyRelease(self.view, Qt.Key_Alt)
        QTest.mouseMove(self.view, end + QPoint(1, 0), 20)
        self.assertAlmostEqual(self.timeline.property("lastA"), 5)
        QTest.mouseRelease(self.view, Qt.LeftButton, Qt.NoModifier, end)
        self.assertTrue(self.timeline.property("snappingEnabled"))

    def test_layer_resize_snaps_only_the_dragged_edge(self):
        for start, end, expected_a, expected_b in [
                (2.06, 1.1, 1, 4), (3.94, 4.9, 2, 5),
                (3.94, 7.9, 2, 8), (3.94, 11.9, 2, 12)]:
            with self.subTest(start=start, end=end):
                self.drag(self.point(start, 120), self.point(end, 120))
                self.assertAlmostEqual(self.timeline.property("lastA"), expected_a)
                self.assertAlmostEqual(self.timeline.property("lastB"), expected_b)

    def test_block_edits_snap_to_playhead_and_layer_boundaries(self):
        for start, end, expected_a, expected_b in [
                (13, 5.9, 5, 7), (13, 6.9, 6, 8),
                (12.06, 10.1, 10, 14), (13.94, 17.9, 12, 18),
                (13, 13.1, 12.1, 14.1)]:
            with self.subTest(start=start, end=end):
                self.drag(self.point(start, 38), self.point(end, 38))
                self.assertAlmostEqual(self.timeline.property("lastA"), expected_a)
                self.assertAlmostEqual(self.timeline.property("lastB"), expected_b)

    def test_trim_edits_snap_to_playhead_and_clip_boundaries(self):
        self.timeline.setProperty("trimIn", 4)
        self.timeline.setProperty("trimOut", 7)
        for start, end, button, expected_a, expected_b in [
                (6, 6.9, Qt.RightButton, 5, 8),
                (4, 4.9, Qt.RightButton, 5, 8),
                (7, 7.9, Qt.RightButton, 5, 8),
                (4, 1.9, Qt.LeftButton, 2, 7),
                (7, 7.9, Qt.LeftButton, 4, 8),
                (6, 6.3, Qt.RightButton, 4.3, 7.3)]:
            with self.subTest(start=start, button=button):
                self.drag(self.point(start, 78), self.point(end, 78), button)
                self.assertAlmostEqual(self.timeline.property("lastA"), expected_a)
                self.assertAlmostEqual(self.timeline.property("lastB"), expected_b)

    def descendants(self, item):
        for child in item.childItems():
            yield child
            yield from self.descendants(child)

    def test_continuous_layer_move_refreshes_the_same_delegate(self):
        self.timeline.setProperty("applyEdits", True)
        clip = next(item for item in self.descendants(self.timeline)
                    if item.x() == 101 and item.height() == 22)
        QTest.mousePress(self.view, Qt.LeftButton, Qt.NoModifier, self.point(3, 120))
        grabber = self.view.mouseGrabberItem()
        for mouse_time, expected in [(5.9, 5), (6.5, 5.5), (6.9, 6), (7.5, 6.5)]:
            QTest.mouseMove(self.view, self.point(mouse_time, 120), 20)
            APP.processEvents()
            self.assertIs(self.view.mouseGrabberItem(), grabber)
            self.assertAlmostEqual(self.timeline.property("lastA"), expected)
            self.assertAlmostEqual(clip.x(), expected * 50 + 1)
            self.assertAlmostEqual(clip.width(), 98)
        QTest.mouseRelease(self.view, Qt.LeftButton, Qt.NoModifier, self.point(7.5, 120))

    def test_layer_move_snaps_start_to_playhead(self):
        self.drag(self.point(3, 120), self.point(5.9, 120))
        self.assertAlmostEqual(self.timeline.property("lastA"), 5)
        self.assertAlmostEqual(self.timeline.property("lastB"), 7)

    def test_snap_threshold_stays_in_pixels_when_zoom_changes(self):
        self.timeline.setProperty("zoom", 100)
        self.drag(self.point(3, 120), self.point(5.9, 120))
        self.assertAlmostEqual(self.timeline.property("lastA"), 4.9)
        self.drag(self.point(3, 120), self.point(5.95, 120))
        self.assertAlmostEqual(self.timeline.property("lastA"), 5)

    def test_continuous_block_move_refreshes_the_same_delegate(self):
        self.timeline.setProperty("applyEdits", True)
        clip = next(item for item in self.descendants(self.timeline)
                    if item.x() == 600 and item.width() == 100 and item.height() == 26)
        QTest.mousePress(self.view, Qt.LeftButton, Qt.NoModifier, self.point(13, 38))
        grabber = self.view.mouseGrabberItem()
        for mouse_time, expected in [(5.9, 5), (6.5, 5.5), (6.9, 6)]:
            QTest.mouseMove(self.view, self.point(mouse_time, 38), 20)
            APP.processEvents()
            self.assertIs(self.view.mouseGrabberItem(), grabber)
            self.assertAlmostEqual(self.timeline.property("lastA"), expected)
            self.assertAlmostEqual(clip.x(), expected * 50)
            self.assertAlmostEqual(clip.width(), 100)
        QTest.mouseRelease(self.view, Qt.LeftButton, Qt.NoModifier, self.point(6.9, 38))


if __name__ == "__main__":
    unittest.main(verbosity=2)
