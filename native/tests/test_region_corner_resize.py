"""Real pointer regression for RegionEditor corner-resize drift."""
import os
import warnings
from pathlib import Path
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_BACKEND", "software")
warnings.filterwarnings("ignore", category=DeprecationWarning)
from PySide6.QtCore import QPoint, QPointF, QUrl, Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlComponent, QQmlPropertyMap
from PySide6.QtQuick import QQuickItem, QQuickView
from PySide6.QtTest import QTest

APP = QGuiApplication.instance() or QGuiApplication([])
QML_DIR = Path(__file__).resolve().parents[1] / "qml"


class RegionCornerResize(unittest.TestCase):
    def make_view(self):
        warnings.simplefilter("ignore", DeprecationWarning)
        view = QQuickView()
        engine = QQmlPropertyMap()
        engine.insert("theme", {"accent": "#ffffff", "cyan": "#00ffff", "magenta": "#ff00ff", "orange": "#ffaa00"})
        view.engine().rootContext().setContextProperty("engine", engine)
        component = QQmlComponent(view.engine())
        component.setData((f'''import QtQuick
import "{QML_DIR.as_uri()}"
import "{(QML_DIR / 'CropGeometry.js').as_uri()}" as Crop
Item {{
  id: root; width: 500; height: 281.25
  property var a: ({{ x: 20, y: 10, w: 20, h: 63.2098765432 }})
  property var b: ({{ x: 65, y: 10, w: 20, h: 63.2098765432 }})
  RegionEditor {{
    anchors.fill: parent; mode: 1; boxA: root.a; boxB: root.b
    aspectA: 9 / 16; aspectB: 9 / 16; srcW: 1920; srcH: 1080
    onBoxAEdited: function(value) {{ root.a = Crop.fit(value, 9 / 16, 1920, 1080) }}
  }}
}}''').encode(), QUrl())
        root = component.create()
        self.assertIsNotNone(root, str(component.errors()))
        view.setContent(QUrl(), component, root)
        view.show()
        QTest.qWait(30)
        return view, root, engine, component

    def test_southeast_resize_keeps_northwest_corner_fixed_through_many_moves(self):
        view, root, engine, component = self.make_view()
        try:
            before = root.property("a").toVariant()
            p = QPoint(round((before["x"] + before["w"]) / 100 * root.width()),
                       round((before["y"] + before["h"]) / 100 * root.height()))
            QTest.mousePress(view, Qt.LeftButton, Qt.NoModifier, p)
            for step in range(1, 7):
                QTest.mouseMove(view, p + QPoint(step * 9, step * 5), 15)
            QTest.mouseRelease(view, Qt.LeftButton, Qt.NoModifier, p + QPoint(54, 30))
            after = root.property("a").toVariant()
            self.assertAlmostEqual(after["x"], before["x"], places=5)
            self.assertAlmostEqual(after["y"], before["y"], places=5)
            self.assertGreater(after["w"], before["w"])
        finally:
            view.close()
            view.deleteLater()
            engine.deleteLater()
            component.deleteLater()
            APP.processEvents()


if __name__ == "__main__":
    unittest.main()
