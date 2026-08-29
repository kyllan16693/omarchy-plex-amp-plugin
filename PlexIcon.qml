import QtQuick

// The Plex chevron, drawn rather than shipped as an asset so it always picks up
// the current bar foreground colour.
Item {
  id: root

  property color color: "white"
  property real thickness: 0.34   // stroke width as a fraction of the width

  implicitWidth: 14
  implicitHeight: 14

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    renderStrategy: Canvas.Cooperative

    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()

      var w = width
      var h = height
      // Keep the mark square and centred whatever box we're given.
      var size = Math.min(w, h)
      var ox = (w - size) / 2
      var oy = (h - size) / 2

      function px(nx, ny) { return [ox + nx * size, oy + ny * size] }

      var t = root.thickness
      var tip = 0.86          // x of the chevron point
      var back = 0.16         // x of the flat back edge
      var inner = tip - t     // x of the inner notch point

      ctx.beginPath()
      var p = px(back, 0.02);        ctx.moveTo(p[0], p[1])
      p = px(back + t, 0.02);        ctx.lineTo(p[0], p[1])
      p = px(tip, 0.5);              ctx.lineTo(p[0], p[1])
      p = px(back + t, 0.98);        ctx.lineTo(p[0], p[1])
      p = px(back, 0.98);            ctx.lineTo(p[0], p[1])
      p = px(inner, 0.5);            ctx.lineTo(p[0], p[1])
      ctx.closePath()

      ctx.fillStyle = root.color
      ctx.fill()
    }
  }

  onColorChanged: canvas.requestPaint()
  onWidthChanged: canvas.requestPaint()
  onHeightChanged: canvas.requestPaint()
}
