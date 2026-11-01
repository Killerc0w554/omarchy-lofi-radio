import QtQuick

// Animated steam rising from the mug. Drawn in the same 24x24 design space as
// Logo.js, in the theme accent colour. Two layers sell the motion: flowing
// S-curves plus a small puff travelling upward along each wisp.
Item {
  id: root

  property color color: "#ffffff"
  property bool active: false
  readonly property real intensity: active ? 1.0 : 0.55

  property real phase: 0

  NumberAnimation on phase {
    from: 0
    to: Math.PI * 2
    duration: root.active ? 2400 : 4600
    loops: Animation.Infinite
    running: true
  }

  Canvas {
    id: canvas
    anchors.fill: parent

    onPaint: {
      var ctx = getContext("2d")
      ctx.clearRect(0, 0, width, height)
      if (width <= 0 || height <= 0) return

      var scale = Math.min(width, height) / 24
      ctx.save()
      ctx.scale(scale, scale)
      ctx.lineWidth = 1.5
      ctx.lineCap = "round"
      ctx.lineJoin = "round"

      var r = root.color.r
      var g = root.color.g
      var b = root.color.b
      var baseAlpha = 0.92 * root.intensity

      for (var i = 0; i < 3; i++) {
        var baseX = 7.3 + i * 3.35

        var grad = ctx.createLinearGradient(0, 9.0, 0, 2.6)
        grad.addColorStop(0.0, Qt.rgba(r, g, b, baseAlpha))
        grad.addColorStop(0.55, Qt.rgba(r, g, b, baseAlpha * 0.5))
        grad.addColorStop(1.0, Qt.rgba(r, g, b, 0.0))
        ctx.strokeStyle = grad

        ctx.beginPath()
        for (var s = 0; s <= 12; s++) {
          var t = s / 12
          var sway = Math.sin(t * 4.4 + root.phase + i * 1.35) * (0.55 + t * 1.25)
          var x = baseX + sway
          var y = 9.0 - t * 6.4
          if (s === 0) ctx.moveTo(x, y)
          else ctx.lineTo(x, y)
        }
        ctx.stroke()

        // A small puff rises and fades along each wisp.
        var p = (root.phase / (Math.PI * 2) + i * 0.33) % 1
        var py = 8.6 - p * 6.0
        var px = baseX + Math.sin(p * 5.2 + i * 1.1) * (0.5 + p * 1.2)
        var pa = Math.sin(p * Math.PI) * 0.7 * root.intensity
        ctx.beginPath()
        ctx.fillStyle = Qt.rgba(r, g, b, pa)
        ctx.arc(px, py, 0.6, 0, Math.PI * 2)
        ctx.fill()
      }

      ctx.restore()
    }
  }

  onPhaseChanged: canvas.requestPaint()
  onColorChanged: canvas.requestPaint()
  onIntensityChanged: canvas.requestPaint()
}
