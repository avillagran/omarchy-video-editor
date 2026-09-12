// FnCombo.qml - Tokyo Night styled ComboBox
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

ComboBox {
  id: c
  font.pixelSize: 11
  contentItem: Label {
    text: c.displayText; color: engine.theme.text; font: c.font
    verticalAlignment: Qt.AlignVCenter; elide: Text.ElideRight
    leftPadding: 10
  }
  indicator: Label {
    x: c.width - width - 8; anchors.verticalCenter: c.verticalCenter
    text: "▾"; color: engine.theme.textMuted
  }
  background: Rectangle {
    implicitWidth: 140; implicitHeight: 30
    color: c.pressed || c.popup.visible ? "#1a1e30" : engine.theme.panelDeep
    border.color: c.popup.visible ? engine.theme.accent : engine.theme.border
    radius: engine.theme.radius
  }
  delegate: ItemDelegate {
    width: c.width
    contentItem: Label { text: modelData; color: engine.theme.text; font.pixelSize: 11; verticalAlignment: Qt.AlignVCenter; leftPadding: 10 }
    background: Rectangle { color: highlighted ? engine.theme.accentSoft : engine.theme.panel }
    highlighted: c.highlightedIndex === index
  }
  popup: Popup {
    y: c.height + 2; width: c.width
    padding: 1
    contentItem: ListView {
      clip: true; implicitHeight: contentHeight
      model: c.popup.visible ? c.delegateModel : null
      currentIndex: c.highlightedIndex
    }
    background: Rectangle { color: engine.theme.panel; border.color: engine.theme.border; radius: engine.theme.radius }
  }
}
