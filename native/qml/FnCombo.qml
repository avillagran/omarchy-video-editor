// FnCombo.qml - Tokyo Night styled ComboBox
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

ComboBox {
  id: c
  font.pixelSize: 11
  contentItem: Label {
    text: c.displayText; color: T.text; font: c.font
    verticalAlignment: Qt.AlignVCenter; elide: Text.ElideRight
    leftPadding: 10
  }
  indicator: Label {
    x: c.width - width - 8; anchors.verticalCenter: c.verticalCenter
    text: "▾"; color: T.textMuted
  }
  background: Rectangle {
    implicitWidth: 140; implicitHeight: 30
    color: c.pressed || c.popup.visible ? "#1a1e30" : T.panelDeep
    border.color: c.popup.visible ? T.accent : T.border
    radius: T.radius
  }
  delegate: ItemDelegate {
    width: c.width
    contentItem: Label { text: modelData; color: T.text; font.pixelSize: 11; verticalAlignment: Qt.AlignVCenter; leftPadding: 10 }
    background: Rectangle { color: highlighted ? T.accentSoft : T.panel }
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
    background: Rectangle { color: T.panel; border.color: T.border; radius: T.radius }
  }
}
