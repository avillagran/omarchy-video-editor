"""Exercise the production card drop handler with real Qt pointer events."""
import os
from pathlib import Path
import unittest

os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
os.environ.setdefault('QT_QUICK_BACKEND', 'software')
from PySide6.QtCore import QPoint, QUrl, Qt
from PySide6.QtGui import QGuiApplication
from PySide6.QtQml import QQmlComponent
from PySide6.QtQuick import QQuickView
from PySide6.QtTest import QTest

MAIN_SOURCE = (Path(__file__).resolve().parents[1] / 'qml/main.qml').read_text()
APP = QGuiApplication.instance() or QGuiApplication([])


class LayerCardReorder(unittest.TestCase):
    def test_dropping_in_internal_gaps_uses_adjacent_card(self):
        # Extract the actual production handler, not a reimplementation.
        start = MAIN_SOURCE.index('onReleased: function(mouse)', MAIN_SOURCE.index('id: layerList'))
        brace = MAIN_SOURCE.index('{', start)
        depth = 1
        end = brace + 1
        while depth:
            depth += (MAIN_SOURCE[end] == '{') - (MAIN_SOURCE[end] == '}')
            end += 1
        handler = MAIN_SOURCE[start:end]
        for y, expected in [(39, ['A', 'D', 'B', 'C']), (81, ['A', 'B', 'D', 'C'])]:
            with self.subTest(drop_y=y):
                view = QQuickView()
                component = QQmlComponent(view.engine())
                source = '''import QtQuick
Item {
 id: win; width: 200; height: 240
 property var layers: ["A", "B", "C", "D"]
 property int selectedLayer: -1
 ListView {
  id: layerList; anchors.fill: parent; spacing: 6; model: win.layers
  delegate: Rectangle {
   required property int index
   width: 200; height: 36
   MouseArea { anchors.fill: parent; preventStealing: true; %s }
  }
 }
}''' % handler
                component.setData(source.encode(), QUrl())
                root = component.create()
                self.assertIsNotNone(root, str(component.errors()))
                view.setContent(QUrl(), component, root)
                view.show()
                QTest.qWait(30)
                QTest.mousePress(view, Qt.LeftButton, Qt.NoModifier, QPoint(10, 144))
                QTest.mouseMove(view, QPoint(10, y), 20)
                QTest.mouseRelease(view, Qt.LeftButton, Qt.NoModifier, QPoint(10, y))
                actual = root.property('layers').toVariant()
                selected = root.property('selectedLayer')
                view.close()
                view.deleteLater()
                APP.processEvents()
                self.assertEqual(actual, expected)
                self.assertEqual(selected, expected.index('D'))


if __name__ == '__main__':
    unittest.main()
