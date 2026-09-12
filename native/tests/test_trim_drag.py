"""Real Qt Quick pointer regression tests. Run with PySide6 installed.

QT_QPA_PLATFORM=offscreen python -m unittest discover -s native/tests -v
"""
import os
from pathlib import Path
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_BACKEND", "software")

from PySide6.QtCore import QPoint, QUrl, Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtQuick import QQuickView
from PySide6.QtTest import QTest
from PySide6.QtQml import QQmlComponent


class TrimDragTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QGuiApplication.instance() or QGuiApplication([])

    def setUp(self):
        self.view = QQuickView()
        self.component = QQmlComponent(self.view.engine())
        qml_dir = Path(__file__).resolve().parents[1] / "qml"
        self.component.setData(b'''import QtQuick
import "../qml"
Timeline {
    width: 1048; height: 220
    duration: 20; zoom: 50; trimIn: 4; trimOut: 8
    onTrimEdited: function(a, b) { trimIn = a; trimOut = b }
}''', QUrl.fromLocalFile(str(qml_dir.parent / "tests" / "Harness.qml")))
        self.timeline = self.component.create()
        self.assertIsNotNone(self.timeline, str(self.component.errors()))
        # Disable snapping when testing raw drag geometry, if supported.
        if self.timeline.metaObject().indexOfProperty("snappingEnabled") >= 0:
            self.timeline.setProperty("snappingEnabled", False)
        self.view.setContent(QUrl(), self.component, self.timeline)
        self.view.show()
        QTest.qWait(50)

    def tearDown(self):
        self.view.close()
        self.view.deleteLater()
        self.app.processEvents()

    def drag(self, start_time, delta, button=Qt.RightButton):
        x = 47 + round(start_time * 50)
        y = 1 + 24 + 26 + 28
        QTest.mousePress(self.view, button, Qt.NoModifier, QPoint(x, y))
        for step in range(1, 6):
            QTest.mouseMove(self.view, QPoint(x + round(delta * 50 * step / 5), y), 20)
        QTest.mouseRelease(self.view, button, Qt.NoModifier, QPoint(x + round(delta * 50), y))
        self.app.processEvents()

    def test_right_drag_out_handle_preserves_offset(self):
        self.drag(8, 2)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 6, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 10, places=2)

    def test_right_drag_in_handle_preserves_length(self):
        self.drag(4, 2)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 6, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 10, places=2)

    def test_right_drag_band_preserves_length(self):
        self.drag(6, 2)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 6, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 10, places=2)

    def test_left_drag_out_handle_only_resizes(self):
        self.drag(8, 2, Qt.LeftButton)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 4, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 10, places=2)

    def test_left_drag_in_handle_only_resizes(self):
        self.drag(4, -2, Qt.LeftButton)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 2, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 8, places=2)

    def test_right_drag_clamps_at_start_without_changing_length(self):
        self.drag(8, -8)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 0, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 4, places=2)

    def test_right_drag_clamps_at_end_without_changing_length(self):
        self.drag(8, 12)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 16, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 20, places=2)

    def test_right_drag_returns_from_boundary_without_offset_drift(self):
        y = 79
        QTest.mousePress(self.view, Qt.RightButton, Qt.NoModifier, QPoint(447, y))
        for x in (647, 847, 1047, 747, 547):
            QTest.mouseMove(self.view, QPoint(x, y), 20)
        QTest.mouseRelease(self.view, Qt.RightButton, Qt.NoModifier, QPoint(547, y))
        self.assertAlmostEqual(self.timeline.property("trimIn"), 6, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 10, places=2)

    def test_left_resize_cannot_invert_the_selection(self):
        self.drag(8, -6, Qt.LeftButton)
        self.assertAlmostEqual(self.timeline.property("trimIn"), 4, places=2)
        self.assertAlmostEqual(self.timeline.property("trimOut"), 4.1, places=2)


if __name__ == "__main__":
    unittest.main()
