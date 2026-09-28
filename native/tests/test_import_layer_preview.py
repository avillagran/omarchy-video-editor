"""Imported cut-timeline layers appear in both previews of a trimmed source."""
import os
import json
import tempfile
import unittest
import warnings
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_BACKEND", "software")
from PySide6.QtCore import QObject, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlComponent, QQmlPropertyMap
from PySide6.QtQuick import QQuickView
from native.scripts.omashort_bridge import import_render, patch_project, read_project

APP = QGuiApplication.instance() or QGuiApplication([])
QML_DIR = Path(__file__).resolve().parents[1] / "qml"
MAIN = (QML_DIR / "main.qml").read_text()
OUTPUT = (QML_DIR / "OutputPreview.qml").read_text()


class ImportedLayerPreview(unittest.TestCase):
    def setUp(self):
        self.view = QQuickView()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            self.theme = QQmlPropertyMap()
        self.theme.insert("theme", {"magenta": "#aa44ff", "textDim": "#777777"})
        self.view.engine().rootContext().setContextProperty("engine", self.theme)
        self.component = QQmlComponent(self.view.engine())
        self.component.setData(('''import QtQuick
import "%s"
Item {
  width: 1080; height: 1920
  property real importedSourcePosition: overlay.layers.length ? overlay.layerSourcePosition(overlay.layers[0]) : 0
  OverlayLayers {
    id: overlay; objectName: "cutOverlay"; anchors.fill: parent; position: 6; sourceTrimIn: 5
    layers: [
      { type: "text", text: "Imported", timingSpace: "cut", inS: 0, outS: 3,
        fadeIn: 1, sourceIn: 0.5, keyframes: [{time: 0, x: 0.1}, {time: 3, x: 0.9}] },
      { type: "text", text: "Legacy", inS: 5, outS: 8 }
    ]
  }
}
''' % QML_DIR.as_uri()).encode(), QUrl())
        self.assertFalse(self.component.isError(), str(self.component.errors()))
        self.root = self.component.create()
        self.assertIsNotNone(self.root, str(self.component.errors()))
        self.view.setContent(QUrl(), self.component, self.root)
        APP.processEvents()
        self.overlay = self.root.findChild(QObject, "cutOverlay")

    def tearDown(self):
        self.overlay.setProperty("layers", [])
        APP.processEvents()
        self.view.close()
        self.view.deleteLater()
        APP.processEvents()

    def test_trimmed_source_maps_only_opted_in_layers_to_cut_time(self):
        self.assertTrue(self.overlay.property("sourceTrimIn") == 5)
        # QML probes actual delegate visibility, interpolated coordinates and fade.
        delegates = [item for item in self.overlay.childItems()
                     if item.property("modelData") is not None]
        self.assertEqual(len(delegates), 2)
        self.assertTrue(all(item.isVisible() for item in delegates))
        self.assertAlmostEqual(delegates[0].property("modelData").toVariant()["x"], 0.1 + 0.8 / 3)
        self.assertAlmostEqual(delegates[0].opacity(), 1)
        self.overlay.setProperty("position", 9)
        APP.processEvents()
        self.assertFalse(delegates[0].isVisible())
        self.assertFalse(delegates[1].isVisible())

    def test_cut_video_source_seek_uses_layer_local_time(self):
        # 6s source playhead -> 1s cut -> 1.5s in imported clip.
        self.assertAlmostEqual(self.root.property("importedSourcePosition"), 1.5)

    def test_bridge_imported_video_is_visible_at_trimmed_source_playhead(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project.json"
            clip = Path(directory) / "clip.mp4"
            clip.write_bytes(b"fixture")
            project.write_text(json.dumps({"app": "omashort", "version": 1,
                                           "video": "source.mp4", "trim": {"in": 5, "out": 10}}))
            layer = import_render(str(project), read_project(str(project))["sha256"],
                                  str(clip), 0, 3)["document"]["layers"][0]
            self.overlay.setProperty("active", False)  # no decoder for fixture bytes
            self.overlay.setProperty("layers", [layer])
            APP.processEvents()
            delegate = next(item for item in self.overlay.childItems()
                            if item.property("modelData") is not None)
            self.assertTrue(delegate.isVisible())  # source 6s -> cut 1s
            self.assertAlmostEqual(self.root.property("importedSourcePosition"), 1)
            self.assertEqual(delegate.property("modelData").toVariant()["timingSpace"], "cut")
            self.overlay.setProperty("position", 9)
            APP.processEvents()
            self.assertFalse(delegate.isVisible())  # source 9s -> cut 4s

    def test_bridge_text_layer_uses_cut_time_with_trimmed_source(self):
        with tempfile.TemporaryDirectory() as directory:
            project = Path(directory) / "project.json"
            project.write_text(json.dumps({"app": "omashort", "version": 1,
                                           "video": "source.mp4", "trim": {"in": 5, "out": 10}}))
            layer = patch_project(str(project), read_project(str(project))["sha256"],
                [{"op": "add_text_layer", "text": "MCP title", "in_seconds": 0,
                  "out_seconds": 3}])["document"]["layers"][0]
            self.overlay.setProperty("layers", [layer])
            APP.processEvents()
            delegate = next(item for item in self.overlay.childItems()
                            if item.property("modelData") is not None)
            self.assertTrue(delegate.isVisible())  # source 6s -> cut 1s
            self.assertEqual(layer["timingSpace"], "cut")
            self.overlay.setProperty("position", 9)
            APP.processEvents()
            self.assertFalse(delegate.isVisible())  # source 9s -> cut 4s

    def test_both_preview_hosts_forward_main_source_trim(self):
        self.assertIn("sourceTrimIn: win.trimIn", MAIN)
        self.assertIn("sourceTrimIn: op.sourceTrimIn", OUTPUT)
        self.assertIn("sourceTrimIn: win.trimIn", MAIN[MAIN.index("component ProgramContent"):])
        self.assertIn("sourceTrimIn: win.trimIn", MAIN[MAIN.index("component OutputContent"):])


if __name__ == "__main__":
    unittest.main()
