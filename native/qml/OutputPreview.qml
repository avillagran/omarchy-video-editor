// OutputPreview.qml - live WYSIWYG 9:16 output preview (mirrors ClipStudio paintVertical)
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtMultimedia
import QtQuick.Effects
import "Theme.js" as T

Item {
  id: op
  property string videoPath: ""
  property real position: 0            // seconds (sync target)
  property bool playing: true          // mirrors the main player
  property string layout: "completa"   // completa | apilar | pip | circulo
  property var mainRegion: ({ x: 0, y: 0, w: 100, h: 100 })
  property var topRegion: ({ x: 0, y: 0, w: 100, h: 50 })
  property var bottomRegion: ({ x: 0, y: 50, w: 100, h: 50 })
  property var fgRegion: ({ x: 25, y: 25, w: 50, h: 50 })
  property real pipFx: 0.5
  property real pipFy: 0.72
  property real splitFrac: 0.5
  property var layers: []
  property int layersRev: 0     // in-place layer edits bump this; previews refresh
  property int srcW: 1920
  property int srcH: 1080

  signal splitEdited(real f)
  signal layerMoved(int index, var patch)
  signal layerPressed(int index)

  readonly property bool isPip: layout === "pip" || layout === "circulo"

  // one shared player per view (created once, never destroyed — avoids load races)
  MediaPlayer { id: pMain; source: op.videoPath ? "file://" + op.videoPath : ""; videoOutput: vMain }
  MediaPlayer { id: pBot;  source: op.videoPath ? "file://" + op.videoPath : ""; videoOutput: vBot }
  MediaPlayer { id: pFg;   source: op.videoPath ? "file://" + op.videoPath : ""; videoOutput: vFg }

  function syncPlayer(pl) {
    if (pl.duration <= 0) return
    if (Math.abs(pl.position / 1000 - op.position) > 0.25) {
      pl.position = Math.round(op.position * 1000)
      // a seek while Stopped paints no frame (pipeline in Null): brief play,
      // the next sync tick pauses it again with the frame on screen
      if (pl.playbackState === MediaPlayer.StoppedState) pl.play()
    }
    if (op.playing) { if (pl.playbackState !== MediaPlayer.PlayingState) pl.play() }
    else if (pl.playbackState === MediaPlayer.PlayingState) {
      pl.pause()
      pl.position = pl.position + 1   // force preroll frame, like the main player
    }
  }
  Timer {
    interval: 120; running: op.visible && op.videoPath !== ""; repeat: true
    onTriggered: { op.syncPlayer(pMain); op.syncPlayer(pBot); op.syncPlayer(pFg) }
  }

  Item {
    anchors.fill: parent
    Rectangle {
      id: frame
      objectName: "outputFrame"
      anchors.centerIn: parent
      // Keep the monitor itself at 9:16. A ColumnLayout's independent preferred
      // width/height stretched it in narrow docks, making layers drift relative
      // to the image although their design coordinates had not changed.
      width: Math.max(2, Math.min(parent.width - 8, (parent.height - 8) * 9 / 16))
      height: width * 16 / 9
      color: "#000"; radius: 4; border.color: engine.theme.border; clip: true

      Item {
        id: stage; anchors.fill: parent

        // ---- zone A: main (completa/pip bg) or top (apilar) ----
        Item {
          id: zoneA; clip: true
          x: 0; width: stage.width
          y: 0
          height: op.layout === "apilar" ? op.splitFrac * stage.height : stage.height
          property var region: op.layout === "apilar" ? op.topRegion : op.mainRegion
          VideoOutput {
            id: vMain
            property real rw: Math.max(1, zoneA.region.w / 100 * op.srcW)
            property real rh: Math.max(1, zoneA.region.h / 100 * op.srcH)
            property real k: Math.max(zoneA.width / rw, zoneA.height / rh)
            // Same centered "cover" crop as Stream's clipFraming.drawCover().
            // The selected source region can be wider/taller than its output slot.
            property real visibleW: zoneA.width / k
            property real visibleH: zoneA.height / k
            width: op.srcW * k; height: op.srcH * k
            x: -((zoneA.region.x / 100 * op.srcW) + (rw - visibleW) / 2) * k
            y: -((zoneA.region.y / 100 * op.srcH) + (rh - visibleH) / 2) * k
          }
        }

        // ---- zone B: bottom (apilar only) ----
        Item {
          id: zoneB; clip: true
          visible: op.layout === "apilar"
          x: 0; width: stage.width
          y: op.splitFrac * stage.height
          height: (1 - op.splitFrac) * stage.height
          property var region: op.bottomRegion
          VideoOutput {
            id: vBot
            property real rw: Math.max(1, zoneB.region.w / 100 * op.srcW)
            property real rh: Math.max(1, zoneB.region.h / 100 * op.srcH)
            property real k: Math.max(zoneB.width / rw, zoneB.height / rh)
            // Same centered "cover" crop as Stream's clipFraming.drawCover().
            property real visibleW: zoneB.width / k
            property real visibleH: zoneB.height / k
            width: op.srcW * k; height: op.srcH * k
            x: -((zoneB.region.x / 100 * op.srcW) + (rw - visibleW) / 2) * k
            y: -((zoneB.region.y / 100 * op.srcH) + (rh - visibleH) / 2) * k
          }
        }

        // ---- pip / circulo foreground (MultiEffect = true circular crop) ----
        Rectangle {
          id: fgBox
          visible: op.isPip
          property real side: stage.width * 0.5
          width: side; height: side
          x: (op.pipFx * stage.width) - side / 2
          y: (op.pipFy * stage.height) - side / 2
          radius: op.layout === "circulo" ? side / 2 : 4
          color: "transparent"
          border.color: op.layout === "circulo" ? engine.theme.magenta : engine.theme.border
          border.width: op.layout === "circulo" ? 3 : 1
          // square mode: direct child with plain clip; circle mode: masked via MultiEffect
          Item {
            id: fgContent
            anchors.fill: parent
            visible: false   // rendered offscreen by MultiEffect
            VideoOutput {
              id: vFg
              property real rw: Math.max(1, op.fgRegion.w / 100 * op.srcW)
              property real rh: Math.max(1, op.fgRegion.h / 100 * op.srcH)
              property real k: Math.max(fgBox.width / rw, fgBox.height / rh)
              width: op.srcW * k; height: op.srcH * k
              x: -(op.fgRegion.x / 100 * op.srcW) * k
              y: -(op.fgRegion.y / 100 * op.srcH) * k
            }
          }
          Rectangle { id: fgMaskSquare; visible: false; width: fgBox.width; height: fgBox.height; radius: 4; color: "#fff" }
          Rectangle { id: fgMaskCircle; visible: false; width: fgBox.width; height: fgBox.height; radius: width / 2; color: "#fff" }
          MultiEffect {
            anchors.fill: parent
            source: fgContent
            maskEnabled: true
            autoPaddingEnabled: false
            maskSource: op.layout === "circulo" ? fgMaskCircle : fgMaskSquare
          }
        }

        // The output composition lives on an absolute 1080×1920 design canvas.
        // The editor only scales this canvas as one unit, so panel resizing never
        // changes a layer's output coordinates or lets it drift with the dock.
        Item {
          id: outputCanvas
          objectName: "outputCanvas"
          width: 1080; height: 1920
          readonly property real canvasScale: Math.min(stage.width / width, stage.height / height)
          scale: canvasScale
          x: (stage.width - width * canvasScale) / 2
          y: (stage.height - height * canvasScale) / 2
          transformOrigin: Item.TopLeft
          z: 10
          OverlayLayers {
            anchors.fill: parent; layers: op.layers; position: op.position; playing: op.playing
            space: "out"; refH: 1920; rev: op.layersRev
            onLayerMoved: function (i, patch) { op.layerMoved(i, patch) }
            onLayerPressed: function (i) { op.layerPressed(i) }
          }
        }

        // split divider (apilar)
        Rectangle {
          visible: op.layout === "apilar"
          y: op.splitFrac * stage.height - 6; width: stage.width; height: 12
          color: engine.theme.orange; z: 20
          Label { anchors.centerIn: parent; text: "⇕ split"; color: "#16161e"; font.pixelSize: 9; font.bold: true }
          MouseArea {
            anchors.fill: parent; cursorShape: Qt.SizeVerCursor
            onPositionChanged: if (pressed) op.splitEdited(Math.max(0.15, Math.min(0.85, mapToItem(stage, mouse.x, mouse.y).y / stage.height)))
          }
        }
      }
    }
  }
}
