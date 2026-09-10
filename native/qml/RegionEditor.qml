// RegionEditor.qml - visual crop-region editor over the preview (completa/apilar)
// Drag boxes to move, corner handle to resize, dim outside. Optional 9:16 lock.
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

Item {
  id: re
  // geometry bound externally (pin to the video content rect)
  // bound externally:
  property int mode: 0                 // 0 = one box, 1 = two boxes (A/B)
  property bool showSplit: false       // apilar: draggable divider
  property var boxA: ({ x: 0, y: 0, w: 100, h: 100 })     // completa: main | apilar: top
  property var boxB: ({ x: 0, y: 50, w: 100, h: 50 })     // apilar: bottom
  property real splitFrac: 0.5
  property bool lock916: false
  property real srcW: 1920
  property real srcH: 1080

  signal boxAEdited(var b)
  signal boxBEdited(var b)
  signal splitEdited(real f)

  function clampB(b) {
    b.w = Math.max(5, Math.min(100 - b.x, b.w))
    b.h = Math.max(5, Math.min(100 - b.y, b.h))
    return b
  }
  function applyLock(b) {
    if (!re.lock916) return b
    // keep 9:16 in SOURCE pixels: (w%*srcW)/(h%*srcH) = 9/16  ->  h = w*srcW*16/(9*srcH)
    b.h = Math.max(5, Math.min(100 - b.y, b.w * re.srcW * 16 / (9 * re.srcH)))
    return b
  }

  // ---------- completa: single box ----------
  Item {
    visible: re.mode === 0
    anchors.fill: parent
    // dim outside
    Rectangle { x: 0; y: 0; width: parent.width; height: boxA.y / 100 * parent.height; color: "#000"; opacity: 0.55 }
    Rectangle { x: 0; y: (boxA.y + boxA.h) / 100 * parent.height; width: parent.width; height: parent.height - y; color: "#000"; opacity: 0.55 }
    Rectangle { x: 0; y: boxA.y / 100 * parent.height; width: boxA.x / 100 * parent.width; height: boxA.h / 100 * parent.height; color: "#000"; opacity: 0.55 }
    Rectangle { x: (boxA.x + boxA.w) / 100 * parent.width; y: boxA.y / 100 * parent.height; width: parent.width - x; height: boxA.h / 100 * parent.height; color: "#000"; opacity: 0.55 }

    Rectangle {
      id: boxRect
      x: boxA.x / 100 * re.width; y: boxA.y / 100 * re.height
      width: boxA.w / 100 * re.width; height: boxA.h / 100 * re.height
      color: "transparent"; border.color: T.accent; border.width: 2
      // center crosshair
      Label { anchors.centerIn: parent; text: "✛"; color: T.accent; opacity: 0.7 }
      MouseArea {
        anchors.fill: parent; cursorShape: Qt.DragMoveCursor
        property real sx: 0; property real sy: 0
        onPressed: { sx = mouse.x; sy = mouse.y }
        onPositionChanged: if (pressed) {
          var b = { x: boxA.x + (mouse.x - sx) / re.width * 100, y: boxA.y + (mouse.y - sy) / re.height * 100, w: boxA.w, h: boxA.h }
          b.x = Math.max(0, Math.min(100 - b.w, b.x)); b.y = Math.max(0, Math.min(100 - b.h, b.y))
          re.boxAEdited(b)
        }
      }
      // resize handles (4 corners: nw, ne, sw, se)
      Repeater {
        model: ["nw", "ne", "sw", "se"]
        delegate: Rectangle {
          required property string modelData
          x: (modelData.endsWith("w") ? 0 : boxRect.width) - 8
          y: (modelData.startsWith("n") ? 0 : boxRect.height) - 8
          width: 16; height: 16; color: T.accent; radius: 3
          z: 10
          MouseArea {
            anchors.fill: parent
            cursorShape: modelData === "nw" || modelData === "se" ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
            onPositionChanged: if (pressed) {
              var gx = mapToItem(re, mouse.x, mouse.y).x / re.width * 100
              var gy = mapToItem(re, mouse.x, mouse.y).y / re.height * 100
              var b = { x: boxA.x, y: boxA.y, w: boxA.w, h: boxA.h }
              if (modelData.endsWith("w")) { var nx = Math.min(gx, b.x + b.w - 5); b.w += b.x - nx; b.x = nx }
              else b.w = Math.max(5, gx - b.x)
              if (modelData.startsWith("n")) { var ny = Math.min(gy, b.y + b.h - 5); b.h += b.y - ny; b.y = ny }
              else b.h = Math.max(5, gy - b.y)
              b = re.applyLock(re.clampB(b))
              re.boxAEdited(b)
            }
          }
        }
      }
    }
  }

  // ---------- apilar: two boxes + split divider ----------
  Item {
    visible: re.mode === 1
    anchors.fill: parent
    Repeater {
      model: ["A", "B"]
      delegate: Rectangle {
        id: apBox
        required property string modelData
        property var bx: modelData === "A" ? re.boxA : re.boxB
        x: bx.x / 100 * re.width; y: bx.y / 100 * re.height
        width: bx.w / 100 * re.width; height: bx.h / 100 * re.height
        color: "transparent"; border.color: modelData === "A" ? T.cyan : T.magenta; border.width: 2
        Label { anchors.top: parent.top; anchors.left: parent.left; anchors.margins: 3; text: modelData === "A" ? "TOP" : "BOT"; color: modelData === "A" ? T.cyan : T.magenta; font.pixelSize: 9; font.bold: true }
        MouseArea {
          anchors.fill: parent; cursorShape: Qt.DragMoveCursor
          property real sx: 0; property real sy: 0
          onPressed: { sx = mouse.x; sy = mouse.y }
          onPositionChanged: if (pressed) {
            var cur = apBox.bx
            var b = { x: cur.x + (mouse.x - sx) / re.width * 100, y: cur.y + (mouse.y - sy) / re.height * 100, w: cur.w, h: cur.h }
            b.x = Math.max(0, Math.min(100 - b.w, b.x)); b.y = Math.max(0, Math.min(100 - b.h, b.y))
            if (apBox.modelData === "A") re.boxAEdited(b); else re.boxBEdited(b)
          }
        }
        Repeater {
          model: ["nw", "ne", "sw", "se"]
          delegate: Rectangle {
            required property string modelData
            x: (modelData.endsWith("w") ? 0 : apBox.width) - 7
            y: (modelData.startsWith("n") ? 0 : apBox.height) - 7
            width: 14; height: 14; color: apBox.border.color; radius: 3; z: 10
            MouseArea {
              anchors.fill: parent
              cursorShape: modelData === "nw" || modelData === "se" ? Qt.SizeFDiagCursor : Qt.SizeBDiagCursor
              onPositionChanged: if (pressed) {
                var cur = apBox.bx
                var gx = mapToItem(re, mouse.x, mouse.y).x / re.width * 100
                var gy = mapToItem(re, mouse.x, mouse.y).y / re.height * 100
                var b = { x: cur.x, y: cur.y, w: cur.w, h: cur.h }
                if (modelData.endsWith("w")) { var nx = Math.min(gx, b.x + b.w - 5); b.w += b.x - nx; b.x = nx }
                else b.w = Math.max(5, gx - b.x)
                if (modelData.startsWith("n")) { var ny = Math.min(gy, b.y + b.h - 5); b.h += b.y - ny; b.y = ny }
                else b.h = Math.max(5, gy - b.y)
                b = re.clampB(b)
                if (apBox.modelData === "A") re.boxAEdited(b); else re.boxBEdited(b)
              }
            }
          }
        }
      }
    }
    // split divider (output-space, apilar only)
    Rectangle {
      visible: re.mode === 1 && re.showSplit
      y: re.splitFrac * re.height - 3; width: re.width; height: 6
      color: T.orange; opacity: 0.85
      Label { anchors.centerIn: parent; text: "⇕"; color: "#16161e"; font.pixelSize: 9 }
      MouseArea {
        anchors.fill: parent; cursorShape: Qt.SizeVerCursor
        onPositionChanged: if (pressed) re.splitEdited(Math.max(0.15, Math.min(0.85, (mapToItem(re, mouse.x, mouse.y).y) / re.height)))
      }
    }
  }
}
