// FnField.qml - Tokyo Night styled TextField
import QtQuick
import QtQuick.Controls
import "Theme.js" as T

TextField {
  id: f
  color: engine.theme.text
  font.pixelSize: 11
  placeholderTextColor: engine.theme.textDim
  selectionColor: engine.theme.accentSoft
  background: Rectangle {
    color: f.activeFocus ? "#1a1e30" : engine.theme.panelDeep
    border.color: f.activeFocus ? engine.theme.accent : engine.theme.border
    border.width: 1; radius: engine.theme.radius
  }
}
