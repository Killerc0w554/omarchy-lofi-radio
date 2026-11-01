// The chill logo: a coffee mug, drawn from the live bar palette so it always
// matches the theme. Rendered as an inline data-URL SVG (same trick the
// chibi-maid plugin uses). The steam is animated separately in Steam.qml, so
// this SVG only contains the cup, handle, saucer and music note.
.pragma library

function url(document) {
  return "data:image/svg+xml;utf8," + encodeURIComponent(document)
}

// QML hands us colours as strings like "#AARRGGBB"; normalise to "#RRGGBB".
function hex(value, fallback) {
  var s = String(value || "")
  if (s.charAt(0) === "#") {
    if (s.length === 9) return "#" + s.substring(3)   // #AARRGGBB -> #RRGGBB
    if (s.length === 7) return s                      // #RRGGBB
    if (s.length === 4) return "#" + s.charAt(1) + s.charAt(1)
      + s.charAt(2) + s.charAt(2) + s.charAt(3) + s.charAt(3)
  }
  return fallback
}

// fg     – cup + saucer colour (bar foreground)
// accent – music note colour (theme accent)
function mug(fg, accent) {
  var cup = hex(fg, "#d4be98")
  var note = hex(accent, "#7daea3")
  return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" '
    + 'width="24" height="24">'
    // tiny floating music note, because it keeps the radio company
    + '<g fill="' + note + '">'
    + '<rect x="20.1" y="2.4" width="0.9" height="3.4" rx="0.45"/>'
    + '<circle cx="19.2" cy="5.9" r="1.15"/>'
    + '</g>'
    // cup body
    + '<path d="M4.2 9.4 H16.2 V13.2 C16.2 16.3 13.9 18.6 10.8 18.6 '
    + 'H9.6 C6.5 18.6 4.2 16.3 4.2 13.2 Z" fill="' + cup + '"/>'
    // handle
    + '<path d="M16.4 10.8 H17.4 C19 10.8 20.2 12 20.2 13.4 '
    + 'C20.2 14.8 19 16 17.4 16 H16.4" fill="none" stroke="' + cup
    + '" stroke-width="1.7" stroke-linecap="round"/>'
    // saucer
    + '<path d="M3.2 20.4 H17.2" stroke="' + cup + '" stroke-width="1.7" '
    + 'stroke-linecap="round"/>'
    + '</svg>'
}
