"""Exercise layer editing and preview timing in real QML components."""
import os
import json
import re
import unittest
import warnings
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
os.environ.setdefault("QT_QUICK_BACKEND", "software")
from PySide6.QtCore import QObject, QUrl
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlComponent, QQmlExpression, QQmlEngine, QQmlPropertyMap
from PySide6.QtQuick import QQuickView

APP = QGuiApplication.instance() or QGuiApplication([])
QML = Path(__file__).resolve().parents[1] / "qml"
MAIN = (QML / "main.qml").read_text()


def main_function(name):
    """Load the actual main.qml function into a small, executable QML host."""
    match = re.search(r"  function " + name + r"\([^\n]*\) \{", MAIN)
    if not match:
        raise AssertionError("Missing main.qml function: " + name)
    depth = 1
    end = match.end()
    while depth:
        if MAIN[end] == "{":
            depth += 1
        elif MAIN[end] == "}":
            depth -= 1
        end += 1
    return MAIN[match.start():end]


class CutTimingQml(unittest.TestCase):
    def setUp(self):
        self.view = QQuickView()
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            theme = QQmlPropertyMap()
        theme.insert("theme", {"magenta": "#a4f", "textDim": "#777"})
        self.theme = theme
        self.view.engine().rootContext().setContextProperty("engine", theme)
        funcs = "\n".join(main_function(name) for name in
                          ("sourceToCutTime", "layerTimeAt", "patchLayer", "keyframeAt", "hasKeyframeAt"))
        source = '''import QtQuick
import "%s"
import "%s/Keyframes.js" as Keyframes
Item {
 id: win; width: 1080; height: 1920
 property var layers: []
 property int layersRev: 0
 property var blocks: []
 property int blocksRev: 0
 property real trimIn: 0
 property real playheadMs: 0
 property var playerRef: QtObject { property real position: win.playheadMs }
 property string keyframeEasing: "linear"
 function touchLayers() { layersRev++ }
 %s
 OverlayLayers {
   id: overlay; objectName: "overlay"; anchors.fill: parent
   position: win.playerRef.position / 1000
   sourceTrimIn: win.trimIn
   cutPosition: win.sourceToCutTime(position)
   layers: win.layers; rev: win.layersRev
 }
}''' % (QML.as_uri(), QML.as_uri(), funcs)
        self.component = QQmlComponent(self.view.engine())
        self.component.setData(source.encode(), QUrl())
        self.assertFalse(self.component.isError(), str(self.component.errors()))
        self.root = self.component.create()
        self.assertIsNotNone(self.root, str(self.component.errors()))
        self.view.setContent(QUrl(), self.component, self.root)
        APP.processEvents()
        self.overlay = self.root.findChild(QObject, "overlay")

    def tearDown(self):
        self.overlay.setProperty("layers", [])
        APP.processEvents()
        self.view.close()
        self.view.deleteLater()
        APP.processEvents()

    def evaluate(self, expression):
        result = QQmlExpression(QQmlEngine.contextForObject(self.root), self.root, expression)
        value, _undefined = result.evaluate()
        self.assertFalse(result.hasError(), str(result.error()))
        return value

    def set_layers(self, layers):
        self.evaluate("win.layers = " + json.dumps(layers))

    def test_skipped_block_cut_time_controls_preview_and_keyframe_creation(self):
        self.root.setProperty("trimIn", 5)
        self.root.setProperty("blocks", [
            {"start": 5, "end": 7, "visible": True},
            {"start": 7, "end": 10, "visible": False},
            {"start": 10, "end": 14, "visible": True}])
        self.set_layers([{"type": "text", "text": "Cut", "timingSpace": "cut",
                          "inS": 2, "outS": 4, "x": .2}])
        self.root.setProperty("playheadMs", 11000)
        APP.processEvents()
        self.assertAlmostEqual(self.overlay.property("cutPosition"), 3)
        delegate = next(item for item in self.overlay.childItems()
                        if item.property("modelData") is not None)
        self.assertTrue(delegate.isVisible())
        self.assertAlmostEqual(delegate.property("modelData").toVariant()["x"], .2)
        self.evaluate("keyframeAt(0, 11)")
        self.assertEqual(self.root.property("layers").toVariant()[0]["keyframes"][0]["time"], 3)
        self.assertTrue(self.evaluate("hasKeyframeAt(0, 11)"))

    def test_drag_writes_cut_time_and_legacy_writes_source_time(self):
        self.root.setProperty("trimIn", 5)
        self.root.setProperty("blocks", [{"start": 5, "end": 7}, {"start": 10, "end": 14}])
        self.set_layers([
            {"type": "text", "timingSpace": "cut", "x": .2,
             "keyframes": [{"time": 2, "x": .2}]},
            {"type": "text", "x": .2, "keyframes": [{"time": 10, "x": .2}]},
        ])
        self.root.setProperty("playheadMs", 11000)
        self.evaluate("patchLayer(0, {x: 0.8})")
        self.evaluate("patchLayer(1, {x: 0.8})")
        layers = self.root.property("layers").toVariant()
        self.assertEqual(layers[0]["keyframes"][-1]["time"], 3)
        self.assertEqual(layers[1]["keyframes"][-1]["time"], 11)

    def test_hidden_source_interval_cannot_create_a_cut_keyframe(self):
        self.root.setProperty("blocks", [{"start": 5, "end": 7},
                                         {"start": 7, "end": 10, "visible": False},
                                         {"start": 10, "end": 14}])
        self.set_layers([{"type": "text", "timingSpace": "cut", "x": .2,
                          "keyframes": [{"time": 1, "x": .2}]}])
        self.root.setProperty("playheadMs", 8000)
        APP.processEvents()
        self.assertEqual(self.overlay.property("cutPosition"), -1)
        self.evaluate("patchLayer(0, {x: 0.8})")
        self.evaluate("keyframeAt(0, 8)")
        self.assertEqual(len(self.root.property("layers").toVariant()[0]["keyframes"]), 1)

    def test_no_block_export_segment_starts_at_trim_in(self):
        funcs = "\n".join(main_function(name) for name in
                          ("buildRenderSegments", "sourceToCutTime"))
        source = '''import QtQuick
Item {
 id: win; property var blocks: []; property int blocksRev: 0
 property real trimIn: 5; property real trimOut: 10
 property string cutPath: ""; property var current: ({duration: 12})
 property real regionX: 0; property real regionY: 0
 property real regionW: 100; property real regionH: 100
 function durS() { return 12 }
 function layoutName() { return "completa" }
 %s
}''' % funcs
        comp = QQmlComponent(self.view.engine())
        comp.setData(source.encode(), QUrl())
        self.assertFalse(comp.isError(), str(comp.errors()))
        root = comp.create()
        self.assertIsNotNone(root, str(comp.errors()))
        ctx = QQmlEngine.contextForObject(root)
        start = QQmlExpression(ctx, root, "buildRenderSegments()[0].start").evaluate()[0]
        end = QQmlExpression(ctx, root, "buildRenderSegments()[0].end").evaluate()[0]
        self.assertEqual((start, end), (5, 10))
        root.deleteLater()

    def test_new_layer_duration_matches_visible_export_segments(self):
        source = '''import QtQuick
Item {
 id: win; property var blocks: [{start:5,end:7},
                                  {start:7,end:10,visible:false},
                                  {start:10,end:14}]
 property real trimIn: 5; property real trimOut: 14
 function durS() { return 14 }
 %s
}''' % main_function("cutDuration")
        comp = QQmlComponent(self.view.engine())
        comp.setData(source.encode(), QUrl())
        self.assertFalse(comp.isError(), str(comp.errors()))
        root = comp.create()
        self.assertIsNotNone(root, str(comp.errors()))
        value, undefined = QQmlExpression(QQmlEngine.contextForObject(root), root,
                                           "cutDuration()").evaluate()
        self.assertFalse(undefined)
        self.assertEqual(value, 6)
        root.deleteLater()

    def test_ui_created_text_keyframe_uses_cut_clock(self):
        funcs = "\n".join(main_function(name) for name in
                          ("sourceToCutTime", "layerTimeAt", "addLayer", "keyframeAt"))
        source = '''import QtQuick
import "%s/Keyframes.js" as Keyframes
Item {
 id: win; property var layers: []; property int layersRev: 0
 property int selectedLayer: -1
 property var blocks: []; property int blocksRev: 0
 property real trimIn: 5; property real trimOut: 10
 property string keyframeEasing: "linear"
 function touchLayers() { layersRev++ }
 function cutDuration() { return 5 }
 %s
}''' % (QML.as_uri(), funcs)
        comp = QQmlComponent(self.view.engine())
        comp.setData(source.encode(), QUrl())
        self.assertFalse(comp.isError(), str(comp.errors()))
        root = comp.create()
        self.assertIsNotNone(root, str(comp.errors()))
        ctx = QQmlEngine.contextForObject(root)
        for expression in ('addLayer("text", "")', 'keyframeAt(0, 6)'):
            result = QQmlExpression(ctx, root, expression)
            result.evaluate()
            self.assertFalse(result.hasError(), str(result.error()))
        layer = root.property("layers").toVariant()[0]
        self.assertEqual((layer["timingSpace"], layer["inS"], layer["outS"]),
                         ("cut", 0, 5))
        self.assertEqual(layer["keyframes"][0]["time"], 1)
        root.deleteLater()

    def test_render_probe_omits_hidden_blocks_like_editor(self):
        probe = (QML.parent / "tests" / "render_project_probe.cpp").read_text()
        self.assertIn('block.value("visible", true).toBool()', probe)

    def test_output_preview_forwards_cut_position(self):
        output = (QML / "OutputPreview.qml").read_text()
        self.assertIn("cutPosition: op.cutPosition", output)
        self.assertIn("cutPosition: win.sourceToCutTime", MAIN)
        self.assertIn("win.layerTimeAt(cardLayer", MAIN)


if __name__ == "__main__":
    unittest.main()
