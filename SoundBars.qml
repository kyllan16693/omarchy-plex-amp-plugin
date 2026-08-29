import QtQuick

// Four bars that bounce while music plays and freeze mid-stride when it stops,
// so a paused player still reads as "loaded" rather than "idle".
Item {
  id: root

  property color color: "white"
  property bool active: true
  property int barCount: 4
  property real barWidth: 2
  property real barSpacing: 2
  property real minFraction: 0.22

  implicitWidth: barCount * barWidth + (barCount - 1) * barSpacing
  implicitHeight: 14

  Row {
    anchors.centerIn: parent
    spacing: root.barSpacing

    Repeater {
      model: root.barCount

      Rectangle {
        id: bar
        width: root.barWidth
        radius: root.barWidth / 2
        color: root.color
        anchors.verticalCenter: parent.verticalCenter

        readonly property real maxHeight: root.height
        readonly property real minHeight: Math.max(2, root.height * root.minFraction)

        height: minHeight

        // Prime numbers-ish durations keep the bars from resyncing into a
        // single pulsing block.
        readonly property int beat: 260 + (index % 4) * 85

        SequentialAnimation on height {
          running: true
          paused: !root.active
          loops: Animation.Infinite

          NumberAnimation {
            to: bar.maxHeight
            duration: bar.beat
            easing.type: Easing.InOutSine
          }
          NumberAnimation {
            to: bar.minHeight
            duration: bar.beat + 60
            easing.type: Easing.InOutSine
          }
          NumberAnimation {
            to: bar.maxHeight * 0.65
            duration: bar.beat - 40
            easing.type: Easing.InOutSine
          }
          NumberAnimation {
            to: bar.minHeight
            duration: bar.beat
            easing.type: Easing.InOutSine
          }
        }
      }
    }
  }
}
