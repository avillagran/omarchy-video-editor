"""Output uses a fixed 1080x1920 scene, independent of panel resize."""
import os
import warnings
from pathlib import Path
import unittest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_BACKEND", "software")
warnings.filterwarnings("ignore", category=DeprecationWarning)
from PySide6.QtCore import QCoreApplication, QEvent, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlComponent, QQmlPropertyMap
from PySide6.QtQuick import QQuickView

APP = QGuiApplication.instance() or QGuiApplication([])
QML_DIR = Path(__file__).resolve().parents[1] / "qml"


class OutputCanvasCoordinates(unittest.TestCase):
    def setUp(self):
        warnings.simplefilter("ignore", DeprecationWarning)
        self.view = QQuickView()
        self.theme = QQmlPropertyMap()
        self.theme.insert("theme", {"border": "#222222", "magenta": "#aa44ff", "orange": "#ffaa44", "textDim": "#777777"})
        self.view.engine().rootContext().setContextProperty("engine", self.theme)
        self.component = QQmlComponent(self.view.engine())
        self.component.setData(("""import QtQuick
import \"%s\"
OutputPreview { width: 270; height: 480; layers: [{ type: \"text\", text: \"Fixed\", x: 0.5, y: 0.5, size: 90, inS: 0, outS: 10 }] }
""" % QML_DIR.as_uri()).encode(), QUrl())
        self.assertFalse(self.component.isError(), str(self.component.errors()))
        self.root = self.component.create()
        self.assertIsNotNone(self.root, str(self.component.errors()))
        self.view.setContent(QUrl(), self.component, self.root)
        self.view.show()
        APP.processEvents()

    def tearDown(self):
        self.view.close()
        self.root.deleteLater()
        self.view.deleteLater()
        APP.processEvents()
        QCoreApplication.sendPostedEvents(None, QEvent.DeferredDelete)

    def test_virtual_canvas_keeps_design_dimensions_across_resize(self):
        canvas = self.root.findChild(type(self.root), "outputCanvas")
        frame = self.root.findChild(type(self.root), "outputFrame")
        self.assertIsNotNone(canvas, "Output preview needs a named fixed virtual canvas")
        self.assertIsNotNone(frame)
        self.assertEqual(canvas.width(), 1080)
        self.assertEqual(canvas.height(), 1920)
        self.assertAlmostEqual(frame.height() / frame.width(), 16 / 9)
        initial_scale = canvas.scale()
        self.root.setWidth(180)
        self.root.setHeight(320)
        APP.processEvents()
        self.assertEqual(canvas.width(), 1080)
        self.assertEqual(canvas.height(), 1920)
        self.assertAlmostEqual(frame.height() / frame.width(), 16 / 9)
        self.assertLess(canvas.scale(), initial_scale)


if __name__ == "__main__":
    unittest.main()
