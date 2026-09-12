// FnSpin.qml - Tokyo Night styled SpinBox
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

SpinBox {
  id: s
  font.pixelSize: 11
  contentItem: TextInput {
    text: s.displayText
    color: engine.theme.text; font: s.font
    horizontalAlignment: Qt.AlignHCenter; verticalAlignment: Qt.AlignVCenter
    readOnly: !s.editable; validator: s.validator
    inputMethodHints: Qt.ImhFormattedNumbersOnly
    selectionColor: engine.theme.accentSoft; selectedTextColor: engine.theme.text
  }
  background: Rectangle {
    implicitWidth: 70
    color: s.activeFocus ? "#1a1e30" : engine.theme.panelDeep
    border.color: s.activeFocus ? engine.theme.accent : engine.theme.border
    radius: engine.theme.radius
  }
  up.indicator: Rectangle {
    x: s.mirrored ? 0 : parent.width - width; height: parent.height; width: 18
    color: s.up.pressed ? engine.theme.accentSoft : "transparent"
    Label { anchors.centerIn: parent; text: "+"; color: engine.theme.textMuted; font.pixelSize: 11 }
  }
  down.indicator: Rectangle {
    x: s.mirrored ? parent.width - width : 0; height: parent.height; width: 18
    color: s.down.pressed ? engine.theme.accentSoft : "transparent"
    Label { anchors.centerIn: parent; text: "−"; color: engine.theme.textMuted; font.pixelSize: 11 }
  }
}
