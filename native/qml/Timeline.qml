// Timeline.qml - NLE timeline: zoom, ruler, track headers, filmstrip, trim, layer clips, playhead
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

Item {
  id: tl
  property real duration: 1
  property real position: 0
  property real trimIn: 0
  property real trimOut: 1
  property var stripUrls: []
  property var layers: []
  property var blocks: []
  property int selectedBlock: -1
  property int selectedLayer: -1
  property real zoom: 0          // px/sec; 0 = fit whole duration

  signal seek(real t)
  signal trimEdited(real a, real b)
  signal layerEdited(int index, real inS, real outS)
  signal layerClicked(int index)
  signal blockClicked(int index)
  signal blockEdited(int index, var patch)
  signal layerMoved(int from, int to)
  property int dragHeaderFrom: -1
  property int dragHeaderOver: -1

  function fmt(t) {
    var m = Math.floor(t / 60), s = Math.floor(t % 60), ds = Math.floor((t % 1) * 10)
    return String(m).padStart(2, "0") + ":" + String(s).padStart(2, "0") + "." + ds
  }
  function fitPps() { return Math.max(1, (flick.width - 2) / duration) }
  function pps() { return zoom > 0 ? zoom : fitPps() }
  function t2x(t) { return t * pps() }
  function x2t(x) { return Math.max(0, Math.min(duration, x / pps())) }
  function zoomBy(factor, anchorT) {
    var cur = pps()
    var next = Math.max(fitPps(), Math.min(400, cur * factor))
    zoom = (next <= fitPps() + 0.01) ? 0 : next
    // keep anchorT under the mouse
    var ax = anchorT * cur - flick.contentX
    flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, anchorT * pps() - ax))
  }

  readonly property int headW: 46
  readonly property int rulerH: 24
  readonly property int stripH: 56
  readonly property int layerH: 28
  readonly property int blockH: 26

  Rectangle { anchors.fill: parent; color: T.panelDeep; radius: T.radius; border.color: T.border }

  // ---------- header column (fixed) ----------
  Item {
    id: headers
    x: 1; y: 1; width: tl.headW; height: tl.height - 2; z: 5
    Rectangle { anchors.fill: parent; color: "transparent" }
    // ruler corner with zoom controls
    Rectangle {
      x: 0; y: 0; width: parent.width; height: tl.rulerH; color: T.panel
      Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: T.border }
      Row {
        anchors.centerIn: parent; spacing: 0
        Label { text: "−"; color: T.textMuted; font.pixelSize: 11; width: 16; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; onClicked: tl.zoomBy(1/1.5, tl.position) } }
        Label { text: "+"; color: T.textMuted; font.pixelSize: 11; width: 16; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; onClicked: tl.zoomBy(1.5, tl.position) } }
      }
    }
    Rectangle {  // B (blocks)
      x: 0; y: tl.rulerH; width: parent.width; height: tl.blockH; color: T.panelAlt
      Label { anchors.centerIn: parent; text: "B"; color: T.orange; font.bold: true; font.pixelSize: 11 }
      Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: T.border }
    }
    Rectangle {  // V1
      x: 0; y: tl.rulerH + tl.blockH; width: parent.width; height: tl.stripH; color: T.panelAlt
      Label { anchors.centerIn: parent; text: "V1"; color: T.textMuted; font.bold: true; font.pixelSize: 11 }
      Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: T.border }
    }
    Item {
      x: 0; y: tl.rulerH + tl.blockH + tl.stripH; width: parent.width
      height: tl.layers.length * tl.layerH
      Repeater {
        model: tl.layers
        delegate: Rectangle {
          required property int index
          x: 0; y: index * tl.layerH
          width: headers.width; height: tl.layerH
          color: tl.dragHeaderOver === index && tl.dragHeaderFrom !== index ? T.accentSoft : T.panelAlt
          border.color: tl.dragHeaderOver === index && tl.dragHeaderFrom !== index ? T.accent : "transparent"
          Label { anchors.centerIn: parent; text: "T" + (index + 1); color: tl.selectedLayer === index ? T.good : T.textDim; font.bold: true; font.pixelSize: 10 }
          Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: T.border }
          // drag vertically to reorder the layer track
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.SizeVerCursor
            onPressed: { tl.dragHeaderFrom = index; tl.layerClicked(index) }
            onPositionChanged: if (pressed && tl.dragHeaderFrom >= 0) {
              var over = Math.floor(mapToItem(headers, mouse.x, mouse.y).y / tl.layerH - (tl.rulerH + tl.blockH + tl.stripH) / tl.layerH)
              over = Math.max(0, Math.min(tl.layers.length - 1, over))
              tl.dragHeaderOver = over
            }
            onReleased: {
              if (tl.dragHeaderFrom >= 0 && tl.dragHeaderOver >= 0 && tl.dragHeaderOver !== tl.dragHeaderFrom)
                tl.layerMoved(tl.dragHeaderFrom, tl.dragHeaderOver)
              tl.dragHeaderFrom = -1; tl.dragHeaderOver = -1
            }
          }
        }
      }
    }
    // headers scroll with content vertically is unneeded (fixed heights)
  }

  // ---------- scrollable tracks ----------
  Flickable {
    id: flick
    x: tl.headW + 1; y: 1; width: tl.width - tl.headW - 2; height: tl.height - 2
    contentWidth: tl.t2x(tl.duration) + 2
    contentHeight: tl.rulerH + tl.blockH + tl.stripH + tl.layers.length * tl.layerH
    clip: true
    boundsBehavior: Flickable.StopAtBounds
    flickableDirection: Flickable.HorizontalFlick

    // Ctrl+wheel zoom
    WheelHandler {
      acceptedModifiers: Qt.ControlModifier
      onWheel: function (wheel) {
        var anchorT = (flick.contentX + wheel.x) / tl.pps()
        tl.zoomBy(wheel.angleDelta.y > 0 ? 1.25 : 0.8, anchorT)
      }
    }
    // plain wheel = horizontal scroll
    WheelHandler {
      onWheel: function (wheel) {
        flick.contentX = Math.max(0, Math.min(flick.contentWidth - flick.width, flick.contentX - wheel.angleDelta.y))
      }
    }

    Item {
      id: tracks
      width: flick.contentWidth; height: flick.contentHeight

      // ruler
      Item {
        id: ruler; x: 0; y: 0; width: tracks.width; height: tl.rulerH
        Rectangle { anchors.fill: parent; color: T.panel }
        Repeater {
          id: tickRep
          model: Math.floor(tl.duration / tickRep.step) + 1
          property real step: {
            var target = 110 / tl.pps()   // seconds per ~110px
            var cand = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
            for (var i = 0; i < cand.length; i++) if (cand[i] >= target) return cand[i]
            return 600
          }
          delegate: Item {
            required property int index
            x: tl.t2x(index * tickRep.step); height: ruler.height
            Rectangle { width: 1; height: 7; color: T.textDim; anchors.bottom: parent.bottom }
            Label {
              anchors.bottom: parent.bottom; anchors.bottomMargin: 7; anchors.left: parent.left; anchors.leftMargin: 3
              text: tl.fmt(index * tickRep.step); color: T.textMuted; font.pixelSize: 9; font.family: T.fontMono
              visible: x + width < ruler.width
            }
          }
        }
        MouseArea {
          anchors.fill: parent
          onPressed: tl.seek(tl.x2t(mouse.x))
          onPositionChanged: if (pressed) tl.seek(tl.x2t(mouse.x))
        }
      }


      // blocks row (B): per-range layouts
      Item {
        id: blockRow; x: 0; y: tl.rulerH; width: tracks.width; height: tl.blockH
        Rectangle { anchors.fill: parent; color: T.panelDeep }
        Label {
          visible: tl.blocks.length === 0
          anchors.centerIn: parent
          text: "✂B = split block at playhead"; color: T.textDim; font.pixelSize: 9
        }
        Repeater {
          model: tl.blocks
          delegate: Item {
            id: bb
            required property int index
            required property var modelData
            function lc() { return modelData.layout === "apilar" ? T.orange : (modelData.layout === "pip" ? T.cyan : (modelData.layout === "circulo" ? T.magenta : T.accent)) }
            x: tl.t2x(modelData.start); width: Math.max(14, tl.t2x(modelData.end - modelData.start)); height: tl.blockH
            Rectangle {
              anchors.fill: parent; anchors.margins: 1; radius: 4
              color: bb.lc(); opacity: tl.selectedBlock === index ? 0.85 : 0.45
              border.color: tl.selectedBlock === index ? "#fff" : bb.lc(); border.width: tl.selectedBlock === index ? 2 : 1
              Label {
                anchors.centerIn: parent
                text: (index + 1) + " " + modelData.layout
                color: "#16161e"; font.pixelSize: 9; font.bold: true
                elide: Text.ElideRight; width: parent.width - 6; horizontalAlignment: Text.AlignHCenter
              }
            }
            MouseArea {
              anchors.fill: parent
              property real grabT: 0
              onPressed: { tl.blockClicked(index); grabT = tl.x2t(mapToItem(blockRow, mouse.x, 0).x) - modelData.start }
              onPositionChanged: if (pressed) {
                var t = tl.x2t(mapToItem(blockRow, mouse.x, 0).x) - grabT
                var len = modelData.end - modelData.start
                t = Math.max(0, Math.min(tl.duration - len, t))
                tl.blockEdited(index, { start: t, end: t + len })
              }
            }
            Rectangle {
              anchors.right: parent.right; width: 7; height: parent.height; radius: 3; color: "#ffffff40"; z: 2
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeHorCursor
                onPressed: tl.blockClicked(index)
                onPositionChanged: if (pressed) {
                  var t = tl.x2t(mapToItem(blockRow, mouse.x, 0).x)
                  tl.blockEdited(index, { end: Math.max(modelData.start + 0.2, Math.min(tl.duration, t)) })
                }
              }
            }
          }
        }
        // boundaries: click-through seek
        MouseArea {
          anchors.fill: parent; z: -1
          onPressed: tl.seek(tl.x2t(mouse.x))
          onPositionChanged: if (pressed) tl.seek(tl.x2t(mouse.x))
        }
      }

      // filmstrip (V1)
      Item {
        id: strip; x: 0; y: tl.rulerH + tl.blockH; width: tracks.width; height: tl.stripH
        Rectangle { anchors.fill: parent; color: T.panelDeep }
        Row {
          x: 2; y: 2; height: tl.stripH - 4; spacing: 1
          Repeater {
            model: tl.stripUrls
            delegate: Image {
              required property string modelData
              width: Math.max(8, tl.t2x(tl.duration) / Math.max(1, tl.stripUrls.length) - 1); height: tl.stripH - 4
              source: modelData; fillMode: Image.PreserveAspectCrop; asynchronous: true
            }
          }
        }
        Rectangle { x: 0; width: tl.t2x(tl.trimIn); height: parent.height; color: "#000"; opacity: 0.78 }
        Rectangle { x: tl.t2x(tl.trimOut); width: strip.width - x; height: parent.height; color: "#000"; opacity: 0.78 }
        Item {
          x: tl.t2x(tl.trimIn); width: tl.t2x(tl.trimOut - tl.trimIn); height: parent.height
          Rectangle { anchors.fill: parent; color: T.accent; opacity: 0.08 }
          Rectangle { anchors.top: parent.top; width: parent.width; height: 2; color: T.accent }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: T.accent }
        }
        Rectangle {  // in handle
          x: tl.t2x(tl.trimIn) - 5; width: 10; height: parent.height
          color: T.accent; radius: 2
          Label { anchors.centerIn: parent; text: "▮"; color: "#16161e"; font.pixelSize: 8 }
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.SizeHorCursor
            onPositionChanged: if (pressed) tl.trimEdited(Math.min(tl.x2t(mapToItem(strip, mouse.x, 0).x), tl.trimOut - 0.1), tl.trimOut)
          }
        }
        Rectangle {  // out handle
          x: tl.t2x(tl.trimOut) - 5; width: 10; height: parent.height
          color: T.accent; radius: 2
          Label { anchors.centerIn: parent; text: "▮"; color: "#16161e"; font.pixelSize: 8 }
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.SizeHorCursor
            onPositionChanged: if (pressed) tl.trimEdited(tl.trimIn, Math.max(tl.x2t(mapToItem(strip, mouse.x, 0).x), tl.trimIn + 0.1))
          }
        }
        MouseArea {
          anchors.fill: parent; z: -1
          onPressed: tl.seek(tl.x2t(mouse.x))
          onPositionChanged: if (pressed) tl.seek(tl.x2t(mouse.x))
        }
      }

      // text layer tracks
      Repeater {
        model: tl.layers
        delegate: Item {
          id: track
          required property int index
          required property var modelData
          x: 0; y: tl.rulerH + tl.blockH + tl.stripH + index * tl.layerH
          width: tracks.width; height: tl.layerH
          Rectangle { anchors.fill: parent; color: index % 2 ? T.panelDeep : T.panelAlt; opacity: 0.6 }
          Rectangle {
            id: block
            x: tl.t2x(modelData.inS) + 1
            width: Math.max(16, tl.t2x(modelData.outS - modelData.inS) - 2)
            height: 22; anchors.verticalCenter: parent.verticalCenter
            radius: 4
            gradient: Gradient {
              GradientStop { position: 0; color: tl.selectedLayer === index ? "#5d8a4a" : "#3d4d68" }
              GradientStop { position: 1; color: tl.selectedLayer === index ? "#496b3a" : "#2f3c55" }
            }
            border.color: tl.selectedLayer === index ? T.good : T.border
            border.width: tl.selectedLayer === index ? 2 : 1
            Label {
              anchors.left: parent.left; anchors.leftMargin: 7; anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 14
              text: modelData.text || "—"; elide: Text.ElideRight
              color: T.text; font.pixelSize: 10
            }
            MouseArea {
              anchors.fill: parent
              property real grabT: 0
              onPressed: { tl.layerClicked(index); grabT = tl.x2t(mapToItem(track, mouse.x, 0).x) - modelData.inS }
              onPositionChanged: if (pressed) {
                var t = tl.x2t(mapToItem(track, mouse.x, 0).x) - grabT
                var len = modelData.outS - modelData.inS
                t = Math.max(0, Math.min(tl.duration - len, t))
                tl.layerEdited(index, t, t + len)
              }
            }
            Rectangle {
              anchors.right: parent.right; width: 7; height: parent.height; radius: 3; color: "#ffffff30"
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeHorCursor
                onPressed: tl.layerClicked(index)
                onPositionChanged: if (pressed) {
                  var t = tl.x2t(mapToItem(track, mouse.x, 0).x)
                  tl.layerEdited(index, modelData.inS, Math.max(modelData.inS + 0.2, Math.min(tl.duration, t)))
                }
              }
            }
          }
        }
      }

      // playhead (inside content, scrolls with it)
      Rectangle {
        id: ph
        x: tl.t2x(tl.position); width: 2; height: tracks.height; y: 0
        color: T.playhead; z: 10
        Canvas {
          anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
          width: 11; height: 8
          onPaint: { var c = getContext("2d"); c.fillStyle = T.playhead; c.beginPath(); c.moveTo(0,0); c.lineTo(width,0); c.lineTo(width/2,height); c.closePath(); c.fill() }
        }
        MouseArea {
          anchors.verticalCenter: parent.verticalCenter; anchors.horizontalCenter: parent.horizontalCenter
          width: 16; height: parent.height; cursorShape: Qt.SizeHorCursor
          onPositionChanged: if (pressed) tl.seek(tl.x2t(mapToItem(tracks, mouse.x, 0).x))
        }
      }
    }
  }
}
