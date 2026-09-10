// FnSpin.qml - Tokyo Night styled SpinBox
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

SpinBox {
  id: s
  font.pixelSize: 11
  contentItem: TextInput {
    text: s.displayText
    color: T.text; font: s.font
    horizontalAlignment: Qt.AlignHCenter; verticalAlignment: Qt.AlignVCenter
    readOnly: !s.editable; validator: s.validator
    inputMethodHints: Qt.ImhFormattedNumbersOnly
    selectionColor: T.accentSoft; selectedTextColor: T.text
  }
  background: Rectangle {
    implicitWidth: 70
    color: s.activeFocus ? "#1a1e30" : T.panelDeep
    border.color: s.activeFocus ? T.accent : T.border
    radius: T.radius
  }
  up.indicator: Rectangle {
    x: s.mirrored ? 0 : parent.width - width; height: parent.height; width: 18
    color: s.up.pressed ? T.accentSoft : "transparent"
    Label { anchors.centerIn: parent; text: "+"; color: T.textMuted; font.pixelSize: 11 }
  }
  down.indicator: Rectangle {
    x: s.mirrored ? parent.width - width : 0; height: parent.height; width: 18
    color: s.down.pressed ? T.accentSoft : "transparent"
    Label { anchors.centerIn: parent; text: "−"; color: T.textMuted; font.pixelSize: 11 }
  }
}
