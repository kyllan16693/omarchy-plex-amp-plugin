import QtQuick

// A small, original equalizer mark for Ampbar. It intentionally does not use
// Plex's chevron or other Plex brand iconography.
Item {
  id: root

  property color color: "white"

  implicitWidth: 14
  implicitHeight: 14

  Row {
    anchors.centerIn: parent
    spacing: Math.max(1, root.width * 0.1)

    Repeater {
      model: 3

      Rectangle {
        required property int index
        width: Math.max(1, root.width * 0.18)
        height: root.height * [0.48, 0.9, 0.66][index]
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        color: root.color
      }
    }
  }
}
