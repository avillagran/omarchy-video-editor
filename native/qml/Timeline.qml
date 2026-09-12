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
  property int layersRev: 0
  property var blocks: []
  property int blocksRev: 0
  property int selectedBlock: -1
  property int selectedLayer: -1
  property real zoom: 0          // px/sec; 0 = fit whole duration
  property bool snappingEnabled: true
  property string snappingLabel: "Magnetic snapping"
  property string snappingTip: "Snap clip edges to the playhead and other boundaries. Hold Alt to bypass."

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
  // Snap the nearest valid edge in screen pixels, independent of zoom.
  function snapTime(value, offsets, kind, index, minimum, maximum, modifiers) {
    value = Math.max(minimum, Math.min(maximum, value))
    if (!snappingEnabled || (modifiers & Qt.AltModifier)) return value
    var targets = [position, 0, duration]
    if (kind !== "trim") targets.push(trimIn, trimOut)
    for (var l = 0; l < layers.length; l++) {
      if (kind !== "layer" || l !== index) targets.push(layers[l].inS, layers[l].outS)
    }
    for (var b = 0; b < blocks.length; b++) {
      if (kind !== "block" || b !== index) targets.push(blocks[b].start, blocks[b].end)
    }
    var best = value, distance = 8 / pps()
    for (var i = 0; i < targets.length; i++) {
      for (var j = 0; j < offsets.length; j++) {
        var candidate = targets[i] - offsets[j]
        var delta = Math.abs(candidate - value)
        if (candidate >= minimum && candidate <= maximum && delta <= distance) {
          best = candidate
          distance = delta
        }
      }
    }
    return best
  }

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

  Rectangle { anchors.fill: parent; color: engine.theme.panelDeep; radius: engine.theme.radius; border.color: engine.theme.border }

  // ---------- header column (fixed) ----------
  Item {
    id: headers
    x: 1; y: 1; width: tl.headW; height: tl.height - 2; z: 5
    Rectangle { anchors.fill: parent; color: "transparent" }
    // ruler corner with zoom controls
    Rectangle {
      x: 0; y: 0; width: parent.width; height: tl.rulerH; color: engine.theme.panel
      Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: engine.theme.border }
      Row {
        anchors.centerIn: parent; spacing: 0
        Label { text: "−"; color: engine.theme.textMuted; font.pixelSize: 11; width: 16; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; onClicked: tl.zoomBy(1/1.5, tl.position) } }
        Label { text: "+"; color: engine.theme.textMuted; font.pixelSize: 11; width: 16; horizontalAlignment: Text.AlignHCenter; MouseArea { anchors.fill: parent; onClicked: tl.zoomBy(1.5, tl.position) } }
      }
    }
    Rectangle {  // B (blocks)
      x: 0; y: tl.rulerH; width: parent.width; height: tl.blockH; color: engine.theme.panelAlt
      Label { anchors.centerIn: parent; text: "B"; color: engine.theme.orange; font.bold: true; font.pixelSize: 11 }
      Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: engine.theme.border }
    }
    Rectangle {  // V1
      x: 0; y: tl.rulerH + tl.blockH; width: parent.width; height: tl.stripH; color: engine.theme.panelAlt
      Label { anchors.horizontalCenter: parent.horizontalCenter; y: 5; text: "V1"; color: engine.theme.textMuted; font.bold: true; font.pixelSize: 11 }
      ToolButton {
        id: snapButton
        objectName: "snappingToggle"
        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter
        width: 44; height: 27
        text: "Snap"; font.pixelSize: 10
        checkable: true; checked: tl.snappingEnabled
        focusPolicy: Qt.StrongFocus
        Accessible.name: tl.snappingLabel
        Accessible.description: tl.snappingTip
        ToolTip.visible: hovered
        ToolTip.text: tl.snappingTip
        contentItem: Text {
          text: snapButton.text; font: snapButton.font
          horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
          color: snapButton.checked ? engine.theme.accent : engine.theme.textMuted
        }
        background: Rectangle {
          radius: 3
          color: snapButton.checked ? engine.theme.accentSoft : engine.theme.panelDeep
          border.color: snapButton.activeFocus || snapButton.checked ? engine.theme.accent : engine.theme.border
        }
        onToggled: tl.snappingEnabled = checked
      }
      Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: engine.theme.border }
    }
    Item {
      x: 0; y: tl.rulerH + tl.blockH + tl.stripH; width: parent.width
      height: tl.layers.length * tl.layerH
      Repeater {
        model: tl.layers.length
        delegate: Rectangle {
          required property int index
          x: 0; y: index * tl.layerH
          width: headers.width; height: tl.layerH
          color: tl.dragHeaderOver === index && tl.dragHeaderFrom !== index ? engine.theme.accentSoft : engine.theme.panelAlt
          border.color: tl.dragHeaderOver === index && tl.dragHeaderFrom !== index ? engine.theme.accent : "transparent"
          Label { anchors.centerIn: parent; text: "T" + (index + 1); color: tl.selectedLayer === index ? engine.theme.good : engine.theme.textDim; font.bold: true; font.pixelSize: 10 }
          Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: engine.theme.border }
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
        Rectangle { anchors.fill: parent; color: engine.theme.panel }
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
            Rectangle { width: 1; height: 7; color: engine.theme.textDim; anchors.bottom: parent.bottom }
            Label {
              anchors.bottom: parent.bottom; anchors.bottomMargin: 7; anchors.left: parent.left; anchors.leftMargin: 3
              text: tl.fmt(index * tickRep.step); color: engine.theme.textMuted; font.pixelSize: 9; font.family: engine.theme.fontMono
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
        Rectangle { anchors.fill: parent; color: engine.theme.panelDeep }
        Label {
          visible: tl.blocks.length === 0
          anchors.centerIn: parent
          text: "✂B = split block at playhead"; color: engine.theme.textDim; font.pixelSize: 9
        }
        Repeater {
          model: tl.blocks.length
          delegate: Item {
            id: bb
            required property int index
            readonly property var clipData: { tl.blocksRev; return Object.assign({}, tl.blocks[index]) }
            function lc() { return clipData.layout === "apilar" ? engine.theme.orange : (clipData.layout === "pip" ? engine.theme.cyan : (clipData.layout === "circulo" ? engine.theme.magenta : engine.theme.accent)) }
            x: tl.t2x(clipData.start); width: Math.max(14, tl.t2x(clipData.end - clipData.start)); height: tl.blockH
            Rectangle {
              anchors.fill: parent; anchors.margins: 1; radius: 4
              color: bb.lc(); opacity: tl.selectedBlock === index ? 0.85 : 0.45
              border.color: tl.selectedBlock === index ? "#fff" : bb.lc(); border.width: tl.selectedBlock === index ? 2 : 1
              Label {
                anchors.centerIn: parent
                text: (index + 1) + " " + bb.clipData.layout
                color: "#16161e"; font.pixelSize: 9; font.bold: true
                elide: Text.ElideRight; width: parent.width - 6; horizontalAlignment: Text.AlignHCenter
              }
            }
            MouseArea {
              anchors.fill: parent; preventStealing: true
              property real grabT: 0
              onPressed: function(mouse) { tl.blockClicked(index); grabT = tl.x2t(mapToItem(blockRow, mouse.x, 0).x) - bb.clipData.start }
              onPositionChanged: function(mouse) { if (pressed) {
                var t = tl.x2t(mapToItem(blockRow, mouse.x, 0).x) - grabT
                var len = bb.clipData.end - bb.clipData.start
                t = tl.snapTime(t, [0, len], "block", index, 0, tl.duration - len, mouse.modifiers)
                tl.blockEdited(index, { start: t, end: t + len })
              } }
            }
            Rectangle {
              anchors.left: parent.left; width: 7; height: parent.height; radius: 3; color: "#ffffff40"; z: 2
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeHorCursor; preventStealing: true
                onPressed: tl.blockClicked(index)
                onPositionChanged: function(mouse) { if (pressed) {
                  var t = tl.x2t(mapToItem(blockRow, mouse.x, 0).x)
                  tl.blockEdited(index, { start: tl.snapTime(t, [0], "block", index, 0, bb.clipData.end - 0.2, mouse.modifiers) })
                } }
              }
            }
            Rectangle {
              anchors.right: parent.right; width: 7; height: parent.height; radius: 3; color: "#ffffff40"; z: 2
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeHorCursor; preventStealing: true
                onPressed: tl.blockClicked(index)
                onPositionChanged: function(mouse) { if (pressed) {
                  var t = tl.x2t(mapToItem(blockRow, mouse.x, 0).x)
                  tl.blockEdited(index, { end: tl.snapTime(t, [0], "block", index, bb.clipData.start + 0.2, tl.duration, mouse.modifiers) })
                } }
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
        Rectangle { anchors.fill: parent; color: engine.theme.panelDeep }
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
          Rectangle { anchors.fill: parent; color: engine.theme.accent; opacity: 0.08 }
          Rectangle { anchors.top: parent.top; width: parent.width; height: 2; color: engine.theme.accent }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 2; color: engine.theme.accent }
          // right-drag anywhere inside the range MOVES the whole trim selection
          MouseArea {
            anchors.fill: parent; preventStealing: true
            acceptedButtons: Qt.RightButton
            cursorShape: Qt.DragMoveCursor
            property real grabDt: 0
            onPressed: function(mouse) { grabDt = tl.x2t(mapToItem(strip, mouse.x, 0).x) - tl.trimIn }
            onPositionChanged: function(mouse) { if (pressed) {
              var len = tl.trimOut - tl.trimIn
              var t = tl.x2t(mapToItem(strip, mouse.x, 0).x) - grabDt
              t = tl.snapTime(t, [0, len], "trim", -1, 0, tl.duration - len, mouse.modifiers)
              tl.trimEdited(t, t + len)
            } }
          }
        }
        Rectangle {  // in handle
          x: tl.t2x(tl.trimIn) - 5; width: 10; height: parent.height
          color: engine.theme.accent; radius: 2
          Label { anchors.centerIn: parent; text: "▮"; color: "#16161e"; font.pixelSize: 8 }
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.SizeHorCursor; preventStealing: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            property real grabDt: 0
            onPressed: function(mouse) { grabDt = tl.x2t(mapToItem(strip, mouse.x, 0).x) - tl.trimIn }
            onPositionChanged: function(mouse) { if (pressed) {
              if (mouse.buttons & Qt.RightButton) {
                // right-drag: move the whole selection, keep its length
                var lenR = tl.trimOut - tl.trimIn
                var tR = tl.x2t(mapToItem(strip, mouse.x, 0).x) - grabDt
                tR = tl.snapTime(tR, [0, lenR], "trim", -1, 0, tl.duration - lenR, mouse.modifiers)
                tl.trimEdited(tR, tR + lenR)
              } else {
                tl.trimEdited(tl.snapTime(tl.x2t(mapToItem(strip, mouse.x, 0).x), [0], "trim", -1, 0, tl.trimOut - 0.1, mouse.modifiers), tl.trimOut)
              }
            } }
          }
        }
        Rectangle {  // out handle
          x: tl.t2x(tl.trimOut) - 5; width: 10; height: parent.height
          color: engine.theme.accent; radius: 2
          Label { anchors.centerIn: parent; text: "▮"; color: "#16161e"; font.pixelSize: 8 }
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.SizeHorCursor; preventStealing: true
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            property real grabDt: 0
            onPressed: function(mouse) { grabDt = tl.x2t(mapToItem(strip, mouse.x, 0).x) - tl.trimIn }
            onPositionChanged: function(mouse) { if (pressed) {
              if (mouse.buttons & Qt.RightButton) {
                var lenR = tl.trimOut - tl.trimIn
                var tR = tl.x2t(mapToItem(strip, mouse.x, 0).x) - grabDt
                tR = tl.snapTime(tR, [0, lenR], "trim", -1, 0, tl.duration - lenR, mouse.modifiers)
                tl.trimEdited(tR, tR + lenR)
              } else {
                tl.trimEdited(tl.trimIn, tl.snapTime(tl.x2t(mapToItem(strip, mouse.x, 0).x), [0], "trim", -1, tl.trimIn + 0.1, tl.duration, mouse.modifiers))
              }
            } }
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
        model: tl.layers.length
        delegate: Item {
          id: track
          required property int index
          readonly property var clipData: { tl.layersRev; return Object.assign({}, tl.layers[index]) }
          x: 0; y: tl.rulerH + tl.blockH + tl.stripH + index * tl.layerH
          width: tracks.width; height: tl.layerH
          Rectangle { anchors.fill: parent; color: index % 2 ? engine.theme.panelDeep : engine.theme.panelAlt; opacity: 0.6 }
          Rectangle {
            id: block
            x: tl.t2x(track.clipData.inS) + 1
            width: Math.max(16, tl.t2x(track.clipData.outS - track.clipData.inS) - 2)
            height: 22; anchors.verticalCenter: parent.verticalCenter
            radius: 4
            gradient: Gradient {
              GradientStop { position: 0; color: tl.selectedLayer === index ? "#5d8a4a" : "#3d4d68" }
              GradientStop { position: 1; color: tl.selectedLayer === index ? "#496b3a" : "#2f3c55" }
            }
            border.color: tl.selectedLayer === index ? engine.theme.good : engine.theme.border
            border.width: tl.selectedLayer === index ? 2 : 1
            Label {
              anchors.left: parent.left; anchors.leftMargin: 7; anchors.verticalCenter: parent.verticalCenter
              width: parent.width - 14
              text: track.clipData.text || "—"
              elide: Text.ElideRight
              color: engine.theme.text; font.pixelSize: 10
            }
            MouseArea {
              anchors.fill: parent; preventStealing: true
              property real grabT: 0
              onPressed: function(mouse) { tl.layerClicked(index); grabT = tl.x2t(mapToItem(track, mouse.x, 0).x) - track.clipData.inS }
              onPositionChanged: function(mouse) { if (pressed) {
                var t = tl.x2t(mapToItem(track, mouse.x, 0).x) - grabT
                var len = track.clipData.outS - track.clipData.inS
                t = tl.snapTime(t, [0, len], "layer", index, 0, tl.duration - len, mouse.modifiers)
                tl.layerEdited(index, t, t + len)
              } }
            }
            Rectangle {
              anchors.left: parent.left; width: 7; height: parent.height; radius: 3; color: "#ffffff30"
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeHorCursor; preventStealing: true
                onPressed: tl.layerClicked(index)
                onPositionChanged: function(mouse) { if (pressed) {
                  var t = tl.x2t(mapToItem(track, mouse.x, 0).x)
                  tl.layerEdited(index, tl.snapTime(t, [0], "layer", index, 0, track.clipData.outS - 0.2, mouse.modifiers), track.clipData.outS)
                } }
              }
            }
            Rectangle {
              anchors.right: parent.right; width: 7; height: parent.height; radius: 3; color: "#ffffff30"
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.SizeHorCursor; preventStealing: true
                onPressed: tl.layerClicked(index)
                onPositionChanged: function(mouse) { if (pressed) {
                  var t = tl.x2t(mapToItem(track, mouse.x, 0).x)
                  tl.layerEdited(index, track.clipData.inS, tl.snapTime(t, [0], "layer", index, track.clipData.inS + 0.2, tl.duration, mouse.modifiers))
                } }
              }
            }
          }
        }
      }

      // playhead (inside content, scrolls with it)
      Rectangle {
        id: ph
        x: tl.t2x(tl.position); width: 2; height: tracks.height; y: 0
        color: engine.theme.playhead; z: 10
        Canvas {
          anchors.top: parent.top; anchors.horizontalCenter: parent.horizontalCenter
          width: 11; height: 8
          onPaint: { var c = getContext("2d"); c.fillStyle = engine.theme.playhead; c.beginPath(); c.moveTo(0,0); c.lineTo(width,0); c.lineTo(width/2,height); c.closePath(); c.fill() }
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
