// FnField.qml - Tokyo Night styled TextField
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

TextField {
  id: f
  color: T.text
  font.pixelSize: 11
  placeholderTextColor: T.textDim
  selectionColor: T.accentSoft
  background: Rectangle {
    color: f.activeFocus ? "#1a1e30" : T.panelDeep
    border.color: f.activeFocus ? T.accent : T.border
    border.width: 1; radius: T.radius
  }
}
