// Panel.qml - dockable NLE panel: titled header, collapsible (40px strip), drag-to-reorder
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "Theme.js" as T

Rectangle {
  id: panel
  property string title: ""
  property string panelId: ""
  property bool collapsible: false
  property bool collapsed: false
  property bool closable: false
  signal collapseToggled()
  signal closeRequested()
  signal headerDragStart()
  signal headerDragMove(real gx, real gy)
  signal headerDragEnd(real gx, real gy)
  default property alias content: body.data
  color: engine.theme.panel; radius: engine.theme.radius; border.color: engine.theme.border

  // drag only starts after a 6px move, so clicks/double-clicks never reorder
  component HeaderDragArea: MouseArea {
    cursorShape: Qt.DragMoveCursor
    property bool dragging: false
    property real startX: 0
    property real startY: 0
    onPressed: { dragging = false; var g = mapToItem(null, mouse.x, mouse.y); startX = g.x; startY = g.y }
    onPositionChanged: if (pressed) {
      var g = mapToItem(null, mouse.x, mouse.y)
      if (!dragging && Math.abs(g.x - startX) + Math.abs(g.y - startY) > 6) {
        dragging = true
        panel.headerDragStart()
      }
      if (dragging) panel.headerDragMove(g.x, g.y)
    }
    onReleased: {
      var g = mapToItem(null, mouse.x, mouse.y)
      if (dragging) panel.headerDragEnd(g.x, g.y)
      dragging = false
    }
    onDoubleClicked: panel.collapseToggled()
  }

  ColumnLayout {
    anchors.fill: parent; spacing: 0

    // header (drag to reorder, double-click or ▸ to collapse, ✕ to close)
    Rectangle {
      Layout.fillWidth: true; Layout.preferredHeight: 26
      color: engine.theme.panelAlt; radius: engine.theme.radius
      Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: engine.theme.border }

      RowLayout {
        anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 4
        Label {
          text: "⠿"; color: engine.theme.textDim; font.pixelSize: 10
          HeaderDragArea { anchors.fill: parent }
        }
        Label {
          Layout.fillWidth: true
          text: panel.title.toUpperCase(); color: engine.theme.textMuted; font.pixelSize: 10; font.bold: true; font.letterSpacing: 1.2
          elide: Text.ElideRight
          HeaderDragArea { anchors.fill: parent }
        }
        Label {
          visible: panel.collapsible
          text: panel.collapsed ? "▾" : "▴"
          color: engine.theme.textMuted; font.pixelSize: 11
          MouseArea { anchors.fill: parent; onClicked: panel.collapseToggled() }
        }
        Label {
          visible: panel.closable
          text: "✕"; color: engine.theme.textDim; font.pixelSize: 10
          MouseArea {
            anchors.fill: parent; hoverEnabled: true
            onClicked: panel.closeRequested()
            onEntered: parent.color = engine.theme.bad
            onExited: parent.color = engine.theme.textDim
          }
        }
      }
    }

    Item { id: body; Layout.fillWidth: true; Layout.fillHeight: true; visible: !panel.collapsed; clip: true }
  }
}
