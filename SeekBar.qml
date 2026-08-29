import QtQuick
import QtQuick.Layouts
import qs.Commons
import "PlexApi.js" as PlexApi

// Elapsed / waveform / remaining. Falls back to a plain progress line until
// the analyser has an envelope for this track (and for tracks it can't read).
Item {
  id: root

  property var plex: null
  property color foreground: Color.foreground
  property color accent: Color.accent
  property color dimmer: Qt.darker(foreground, 2.1)
  property string fontFamily: Style.font.family
  property real waveHeight: Style.space(34)

  readonly property var peaks: plex ? plex.waveform : []
  readonly property bool hasWave: peaks && peaks.length > 1
  readonly property real progress: plex ? plex.progress : 0

  implicitHeight: layout.implicitHeight

  function seekTo(fraction) {
    if (!plex || plex.duration <= 0) return
    plex.seek(plex.duration * Math.max(0, Math.min(1, fraction)))
  }

  RowLayout {
    id: layout
    anchors.fill: parent
    spacing: Style.space(8)

    Text {
      Layout.preferredWidth: Style.space(34)
      horizontalAlignment: Text.AlignRight
      text: PlexApi.formatTime(root.plex ? root.plex.position : 0)
      color: root.dimmer
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item {
      Layout.fillWidth: true
      Layout.preferredHeight: root.waveHeight

      Waveform {
        anchors.fill: parent
        visible: root.hasWave
        peaks: root.peaks
        progress: root.progress
        playedColor: root.accent
        pendingColor: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)
        onSeekRequested: function (fraction) { root.seekTo(fraction) }
      }

      Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        height: Style.space(3)
        radius: height / 2
        visible: !root.hasWave
        color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

        Rectangle {
          anchors.left: parent.left
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          width: parent.width * root.progress
          radius: parent.radius
          color: root.accent
          Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutQuad } }
        }
      }

      MouseArea {
        anchors.fill: parent
        visible: !root.hasWave
        enabled: !root.hasWave
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) { root.seekTo(mouse.x / width) }
      }
    }

    Text {
      Layout.preferredWidth: Style.space(34)
      text: PlexApi.formatTime(root.plex ? root.plex.duration : 0)
      color: root.dimmer
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
