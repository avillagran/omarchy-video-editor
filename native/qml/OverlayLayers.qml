// OverlayLayers.qml - live compositing of layers over a preview
// Each layer carries TWO coordinate sets so one project edits two formats at once:
//   x, y, w, h   -> output space (fractions of the 1080x1920 vertical canvas)
//   px, py, pw, ph -> program/source space (fractions of the source video frame)
// space = "out" | "prog" selects which set this instance renders/drags.
//
// `rev` must be bumped by the owner whenever a layer is edited IN PLACE
// (text, position, size, timing). The array identity then stays stable so
// editors keep focus, and these bindings re-run because they depend on `rev`.
import QtQuick
import QtQuick.Controls
import QtMultimedia
import Qt5Compat.GraphicalEffects
import "Theme.js" as T

Item {
  id: ov
  property var layers: []
  property int rev: 0           // in-place edit revision (see header)
  property real position: 0      // seconds
  property bool playing: true    // mirrors the main player; layers pause with the timeline
  property string space: "out"   // "out" = 1080x1920 fractions | "prog" = source frame fractions
  property real refH: 1920       // pixel height the fraction space refers to (font scaling)

  signal layerMoved(int index, var patch)
  signal layerPressed(int index)

  function inRange(l) { return position >= (l.inS || 0) && position <= (l.outS || 1e9) }

  // dual-space accessors: program coords default to the output coords (and vice versa)
  function gx(l) { return ov.space === "prog" ? (l.px !== undefined ? l.px : (l.x || 0.5)) : (l.x || 0.5) }
  function gy(l) { return ov.space === "prog" ? (l.py !== undefined ? l.py : (l.y || 0.5)) : (l.y || 0.5) }
  function gw(l) { return ov.space === "prog" ? (l.pw !== undefined ? l.pw : (l.w || 0.35)) : (l.w || 0.35) }
  function gh(l) { return ov.space === "prog" ? (l.ph !== undefined ? l.ph : (l.h || 0.20)) : (l.h || 0.20) }

  // identification frame: the layer's own color wins over the theme default
  function frameColor(l, fallback) { return l.color ? l.color : fallback }

  // shared drag logic: grab offset so the element doesn't jump to the cursor.
  // Writes to the coordinate set of the space this instance is showing.
  component DragArea: MouseArea {
    property int layerIndex: -1
    anchors.fill: parent
    property real grabDx: 0
    property real grabDy: 0
    onPressed: { grabDx = mouse.x - parent.width / 2; grabDy = mouse.y - parent.height / 2; if (layerIndex >= 0) ov.layerPressed(layerIndex) }
    onPositionChanged: if (pressed && layerIndex >= 0) {
      var pt = mapToItem(ov, mouse.x, mouse.y)
      var fx = Math.max(0, Math.min(1, (pt.x - grabDx) / ov.width))
      var fy = Math.max(0, Math.min(1, (pt.y - grabDy) / ov.height))
      ov.layerMoved(layerIndex, ov.space === "prog" ? { px: fx, py: fy } : { x: fx, y: fy })
    }
  }

  Repeater {
    model: ov.layers
    delegate: Item {
      id: ld
      required property int index
      required property var modelData
      visible: { ov.rev; return ov.inRange(modelData) }
      z: index

      // text layer
      Text {
        visible: { ov.rev; return modelData.type === "text" || !modelData.type }
        text: { ov.rev; return modelData.text || "" }
        color: { ov.rev; return modelData.color || "#ffffff" }
        font.bold: true
        font.pixelSize: { ov.rev; return (modelData.size || 90) * ov.height / ov.refH }
        style: Text.Outline; styleColor: "#000"
        x: { ov.rev; return ov.gx(modelData) * ov.width - width / 2 }
        y: { ov.rev; return ov.gy(modelData) * ov.height - height / 2 }
        DragArea { layerIndex: ld.index }
      }

      // gif layer
      AnimatedImage {
        visible: { ov.rev; return modelData.type === "gif" }
        source: { ov.rev; return modelData.type === "gif" && modelData.path ? "file://" + modelData.path : "" }
        width: { ov.rev; return ov.gw(modelData) * ov.width }
        height: { ov.rev; return ov.gh(modelData) * ov.height }
        x: { ov.rev; return ov.gx(modelData) * ov.width - width / 2 }
        y: { ov.rev; return ov.gy(modelData) * ov.height - height / 2 }
        playing: ld.visible && ov.playing
        fillMode: Image.PreserveAspectFit
        // identification frame: layer color wins over the theme default
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          border.width: 2
          border.color: { ov.rev; return ov.frameColor(ld.modelData, T.textDim) }
          radius: 3
        }
        DragArea { layerIndex: ld.index }
      }

      // image layer
      Image {
        visible: { ov.rev; return modelData.type === "image" }
        source: { ov.rev; return modelData.type === "image" && modelData.path ? "file://" + modelData.path : "" }
        width: { ov.rev; return ov.gw(modelData) * ov.width }
        height: { ov.rev; return ov.gh(modelData) * ov.height }
        x: { ov.rev; return ov.gx(modelData) * ov.width - width / 2 }
        y: { ov.rev; return ov.gy(modelData) * ov.height - height / 2 }
        fillMode: Image.PreserveAspectFit
        Rectangle {
          anchors.fill: parent
          color: "transparent"
          border.width: 2
          border.color: { ov.rev; return ov.frameColor(ld.modelData, T.textDim) }
          radius: 3
        }
        DragArea { layerIndex: ld.index }
      }

      // video layer (PiP) — plays only while the timeline plays; stays in sync
      Rectangle {
        visible: { ov.rev; return modelData.type === "video" }
        width: { ov.rev; return ov.gw(modelData) * ov.width }
        height: { ov.rev; return ov.gh(modelData) * ov.height }
        x: { ov.rev; return ov.gx(modelData) * ov.width - width / 2 }
        y: { ov.rev; return ov.gy(modelData) * ov.height - height / 2 }
        color: "transparent"
        border.width: 2
        border.color: { ov.rev; return ov.frameColor(ld.modelData, T.magenta) }
        // shape: rect | rounded | circle (mask via OpacityMask)
        Item {
          id: lvContent
          anchors.fill: parent
          visible: false   // rendered offscreen by OpacityMask
          VideoOutput { id: lvOut; anchors.fill: parent }
        }
        Rectangle { id: lvMaskRect; visible: false; width: parent.width; height: parent.height; radius: 4; color: "#fff" }
        Rectangle { id: lvMaskRound; visible: false; width: parent.width; height: parent.height; radius: Math.min(width, height) * 0.12; color: "#fff" }
        Rectangle { id: lvMaskCircle; visible: false; width: parent.width; height: parent.height; radius: Math.min(width, height) / 2; color: "#fff" }
        OpacityMask {
          anchors.fill: parent
          source: lvContent
          maskSource: { ov.rev; return (modelData.shape || "rect") === "circle" ? lvMaskCircle
                    : (modelData.shape === "rounded" ? lvMaskRound : lvMaskRect) }
        }
        MediaPlayer {
          id: lvPlayer
          videoOutput: lvOut
          source: { ov.rev; return modelData.type === "video" && modelData.path ? "file://" + modelData.path : "" }
          loops: MediaPlayer.Infinite
        }
        Timer {
          interval: 120; running: ld.visible; repeat: true
          onTriggered: {
            if (lvPlayer.duration <= 0) return
            var target = Math.max(0, ov.position - (modelData.inS || 0))
            if (Math.abs(lvPlayer.position / 1000 - target) > 0.3)
              lvPlayer.position = Math.round(target * 1000)
            if (ov.playing) { if (lvPlayer.playbackState !== MediaPlayer.PlayingState) lvPlayer.play() }
            else lvPlayer.pause()
          }
        }
        DragArea { layerIndex: ld.index }
      }
    }
  }
}
