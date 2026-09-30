import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the Downloads widget. While downloads are active, the count
// itself IS the icon — big and bold, like omarchy.power's percentage text —
// instead of a small corner badge that's easy to miss. Falls back to a
// plain download-tray glyph when nothing's downloading.
Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color activeColor: Color.accent
  property int activeCount: 0

  width: iconSize
  height: iconSize

  Text {
    anchors.centerIn: parent
    visible: root.activeCount === 0
    textFormat: Text.PlainText
    text: "󰇚"
    color: root.color
    font.pixelSize: root.iconSize
  }

  Text {
    anchors.centerIn: parent
    visible: root.activeCount > 0
    textFormat: Text.PlainText
    text: root.activeCount > 9 ? "9+" : String(root.activeCount)
    color: root.activeColor
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: root.iconSize * 1.2
  }
}
