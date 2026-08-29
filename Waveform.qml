import QtQuick

// Plexamp-style waveform scrubber: a mirrored loudness envelope where the
// played part is drawn in the accent colour and the rest sits dim behind it.
//
// The two canvases paint the same bars in different colours; only the clip in
// front of the played one is bound to `progress`, so scrubbing never repaints.
Item {
  id: root

  property var peaks: []
  property real progress: 0
  property color playedColor: "white"
  property color pendingColor: "grey"
  property real minBarHeight: 2
  property real barGap: 1

  signal seekRequested(real fraction)

  readonly property bool hasPeaks: peaks && peaks.length > 1

  onPeaksChanged: repaint()
  onWidthChanged: repaint()
  onHeightChanged: repaint()
  onPlayedColorChanged: playedCanvas.requestPaint()
  onPendingColorChanged: pendingCanvas.requestPaint()

  function repaint() {
    pendingCanvas.requestPaint()
    playedCanvas.requestPaint()
  }

  function paintBars(ctx, color) {
    ctx.reset()
    if (!root.hasPeaks || root.width <= 0 || root.height <= 0)
      return
    var count = root.peaks.length
    var slot = root.width / count
    var barWidth = Math.max(1, slot - root.barGap)
    var middle = root.height / 2
    ctx.fillStyle = color
    for (var i = 0; i < count; i++) {
      var value = Math.max(0, Math.min(1, Number(root.peaks[i]) || 0))
      var h = Math.max(root.minBarHeight, value * root.height)
      ctx.fillRect(i * slot, middle - h / 2, barWidth, h)
    }
  }

  Canvas {
    id: pendingCanvas
    anchors.fill: parent
    onPaint: root.paintBars(getContext("2d"), root.pendingColor)
  }

  Item {
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    width: parent.width * Math.max(0, Math.min(1, root.progress))
    clip: true

    Canvas {
      id: playedCanvas
      width: root.width
      height: root.height
      onPaint: root.paintBars(getContext("2d"), root.playedColor)
    }
  }

  MouseArea {
    anchors.fill: parent
    cursorShape: Qt.PointingHandCursor
    onClicked: function (mouse) {
      if (root.width > 0) root.seekRequested(mouse.x / root.width)
    }
  }
}
