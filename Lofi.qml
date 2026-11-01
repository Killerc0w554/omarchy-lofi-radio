import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Logo.js" as Logo

// A steaming coffee cup in the bar that streams lofi radio. The cup bobs and
// glows while playing; the steam drifts always and speeds up when live.
//
//   left-click    play / stop
//   right-click   station + sleep + volume menu
//   middle-click  mute
//   scroll        volume
//
// IPC (also handy for keybindings):
//   omarchy-shell io.github.killerc0w554.lofi-radio toggle | status | nextStation
//   omarchy-shell io.github.killerc0w554.lofi-radio sleep <minutes> | volumeUp | ...
BarWidget {
  id: root
  moduleName: "io.github.killerc0w554.lofi-radio"

  // Five long-running Lofi Girl / Chillhop streams (checked live).
  readonly property var stations: [
    { name: "Lofi Hip Hop", url: "https://www.youtube.com/watch?v=rFZHOHl-L8A" },
    { name: "Sleep Lofi", url: "https://www.youtube.com/watch?v=JD-kMIpDfnY" },
    { name: "Jazz Lofi", url: "https://www.youtube.com/watch?v=E2vONfzoyRI" },
    { name: "Synthwave", url: "https://www.youtube.com/watch?v=4xDzrJKXOOY" },
    { name: "Chillhop", url: "https://www.youtube.com/watch?v=5yx6BWlEVcY" }
  ]

  property int stationIndex: 0
  readonly property string streamUrl: stations[stationIndex].url
  readonly property string stationName: stations[stationIndex].name

  property bool playing: false
  property bool hovered: false
  property bool popupOpen: false
  property bool muted: false
  property int volume: 65

  // Sleep timer counts down only while the radio is actually playing.
  property int sleepSeconds: 0
  // The preset the user picked (0 = off), kept separate from the countdown so
  // the menu highlights the chosen duration rather than the nearest preset.
  property int sleepPreset: 0
  readonly property int sleepMinutesLeft: Math.ceil(sleepSeconds / 60)

  // 12 live spectrum bands + overall energy, fed by lofi.sh's FFT helper.
  property var levels: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  readonly property real energy: levels.length > 12 ? levels[12] : 0
  readonly property string levelsPath: {
    var d = Quickshell.env("XDG_RUNTIME_DIR")
    return (d && d.length ? d : "/tmp") + "/lofi-radio-levels"
  }

  property int pendingVolumeStep: 0

  readonly property color fg: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property color accent: Commons.Color.accent
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property string logoUrl: Logo.url(Logo.mug(fg, accent))

  implicitWidth: root.vertical ? Style.bar.sizeVertical : Style.bar.iconSlot
  implicitHeight: root.vertical ? Style.bar.iconSlot : Style.bar.sizeHorizontal

  // Plugin QML loads from the custom `qs://` scheme, so strip any scheme
  // (`qs://` or `file://`) to get a real filesystem path for `bash`.
  function scriptPath() {
    return String(Qt.resolvedUrl("lofi.sh")).replace(/^[a-zA-Z]+:\/\//, "")
  }

  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }

  // ---------------------------------------------------------------- actions

  function startPlayback(url) {
    if (startProc.running) return
    startProc.url = String(url || root.streamUrl)
    startProc.running = true
  }

  function stopPlayback(quiet) {
    root.sleepSeconds = 0
    root.sleepPreset = 0
    stopProc.quiet = !!quiet
    if (!stopProc.running) stopProc.running = true
  }

  function toggle() {
    if (root.playing) root.stopPlayback()
    else root.startPlayback()
  }

  function selectStation(index) {
    var i = ((Number(index) || 0) % stations.length + stations.length) % stations.length
    root.stationIndex = i
    root.startPlayback(stations[i].url)
  }

  function nextStation() {
    root.selectStation(root.stationIndex + 1)
  }

  function setSleep(minutes) {
    var m = Math.max(0, Number(minutes) || 0)
    root.sleepPreset = m
    root.sleepSeconds = Math.round(m * 60)
    root.showOsd(m > 0 ? ("Sleep in " + m + " min") : "Sleep timer off", "media")
  }

  function nudgeVolume(delta) {
    if (!root.playing) return
    if (volProc.running) {
      root.pendingVolumeStep += delta
      return
    }
    volProc.delta = delta
    volProc.running = true
  }

  function volumeUp() { root.nudgeVolume(5) }
  function volumeDown() { root.nudgeVolume(-5) }

  function toggleMute() {
    if (!root.playing || muteProc.running) return
    muteProc.running = true
  }

  function close() { root.popupOpen = false }

  function togglePopup() { root.popupOpen = !root.popupOpen }

  // Reuse the shell's OSD so volume/toggle feedback matches the rest of the
  // desktop. The CLI path is used because a third-party widget's bar facade
  // may not be allowed to summon other plugins.
  function showOsd(message, icon, value, max) {
    var payload = { icon: String(icon || "media"), message: String(message || ""), duration: 1400 }
    if (value !== undefined && value !== null) {
      payload.value = Number(value)
      payload.max = Number(max || 100)
    }
    var json = JSON.stringify(payload)
    if (root.bar && root.bar.shell && typeof root.bar.shell.summon === "function") {
      if (root.bar.shell.summon("omarchy.osd", json)) return
    }
    Quickshell.execDetached(["/usr/share/omarchy/bin/omarchy-shell", "shell", "summon", "omarchy.osd", json])
  }

  function applyLevels(raw) {
    var parts = String(raw || "").trim().split(/\s+/)
    if (parts.length !== 13) return
    var next = []
    for (var i = 0; i < 13; i++) {
      var value = parseFloat(parts[i])
      next.push(isNaN(value) ? 0 : Math.max(0, Math.min(1, value)))
    }
    root.levels = next
  }

  // Linear interpolation across the 12 bands, for smoother wide spectra.
  function bandAt(pos) {
    if (root.levels.length < 12) return 0
    var lo = Math.max(0, Math.min(11, Math.floor(pos)))
    var hi = Math.min(11, lo + 1)
    var f = Math.max(0, Math.min(1, pos - lo))
    return root.levels[lo] * (1 - f) + root.levels[hi] * f
  }

  function tooltipText() {
    var bits = [root.stationName + (root.playing ? " — playing" : " — paused")]
    if (root.playing) bits.push(root.muted ? "muted" : (root.volume + "%"))
    if (root.sleepSeconds > 0) bits.push("sleep " + root.sleepMinutesLeft + "m")
    bits.push(root.playing ? "left-click stop · right-click menu" : "left-click play · right-click menu")
    return bits.join(" · ")
  }

  // ---------------------------------------------------------------- backends

  Process {
    id: statusProc
    command: ["bash", root.scriptPath(), "status"]
    onExited: function(code) { root.playing = (code === 0) }
  }

  Process {
    id: startProc
    property string url: ""
    command: ["bash", root.scriptPath(), "start", startProc.url]
    onExited: function(code) {
      root.refreshStatus()
      if (code === 0) root.showOsd(root.stationName, "media")
    }
  }

  Process {
    id: stopProc
    property bool quiet: false
    command: ["bash", root.scriptPath(), "stop"]
    onExited: function(code) {
      root.refreshStatus()
      if (!stopProc.quiet) root.showOsd("Lofi off", "media")
    }
  }

  Process {
    id: volProc
    property int delta: 0
    command: ["bash", root.scriptPath(), "volume", (volProc.delta >= 0 ? "+" : "") + volProc.delta]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var level = parseInt(String(text).trim(), 10)
        if (!isNaN(level)) {
          root.volume = level
          root.showOsd("Volume " + level + "%", root.muted ? "volume-mute" : "volume", level, 100)
        }
      }
    }
    onExited: function(code) {
      if (root.pendingVolumeStep !== 0) {
        var step = root.pendingVolumeStep
        root.pendingVolumeStep = 0
        root.nudgeVolume(step)
      }
    }
  }

  Process {
    id: muteProc
    command: ["bash", root.scriptPath(), "mute"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var state = String(text).trim() === "true"
        root.muted = state
        root.showOsd(state ? "Muted" : "Unmuted", state ? "volume-mute" : "volume",
          root.volume, 100)
      }
    }
  }

  Process {
    id: openProc
    command: ["xdg-open", root.streamUrl]
  }

  // Restore the station that was playing last session.
  Process {
    id: lastUrlProc
    command: ["bash", root.scriptPath(), "lasturl"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var url = String(text).trim()
        for (var i = 0; i < root.stations.length; i++) {
          if (root.stations[i].url === url) { root.stationIndex = i; break }
        }
      }
    }
  }

  // Hydrate the saved volume and mute state so the menu starts truthful even
  // after a shell reload.
  Process {
    id: volumeStateProc
    command: ["bash", root.scriptPath(), "getvolume"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var level = parseInt(String(text).trim(), 10)
        if (!isNaN(level)) root.volume = level
      }
    }
  }

  Process {
    id: muteStateProc
    command: ["bash", root.scriptPath(), "getmute"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.muted = String(text).trim() === "true"
    }
  }

  // The helper rewrites this tiny file ~50 times a second, atomically via
  // rename. watchChanges + onFileChanged → reload() is the delivery path that
  // actually works here (polling `text()` or calling `reload()` from a bare
  // timer does not). A slow fallback reload recovers if the watcher ever goes
  // quiet, which omarchy has seen happen under rapid change storms.
  FileView {
    id: levelsFile
    path: root.levelsPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyLevels(text())
    onLoadFailed: root.levels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  }

  Timer {
    interval: 500
    repeat: true
    running: root.playing
    onTriggered: levelsFile.reload()
  }

  Timer {
    interval: 2000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  Timer {
    interval: 1000
    repeat: true
    running: root.sleepSeconds > 0 && root.playing
    onTriggered: {
      if (root.sleepSeconds > 0) {
        root.sleepSeconds = root.sleepSeconds - 1
        if (root.sleepSeconds === 0) {
          root.sleepPreset = 0
          root.stopPlayback(true)
          root.showOsd("Sleep timer done", "media")
        }
      }
    }
  }

  // ---------------------------------------------------------------- the logo

  Item {
    id: art
    anchors.centerIn: parent
    width: Style.bar.iconCanvas
    height: width
    y: root.playing ? Math.sin(bobPhase) * 1.2 : 0
    scale: root.hovered ? 1.08 : 1.0

    property real bobPhase: 0

    Behavior on scale {
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }

    NumberAnimation on bobPhase {
      from: 0
      to: Math.PI * 2
      duration: 2600
      loops: Animation.Infinite
      running: root.playing
    }

    // Halo driven by the actual low-end energy of the stream.
    Rectangle {
      anchors.centerIn: parent
      width: parent.width * 1.6
      height: width
      radius: width / 2
      color: root.accent
      opacity: root.playing ? 0.10 + 0.35 * root.energy : 0

      Behavior on opacity {
        NumberAnimation { duration: 120; easing.type: Easing.OutQuad }
      }
    }

    Image {
      anchors.fill: parent
      source: root.logoUrl
      smooth: true
      opacity: root.playing ? 1.0 : 0.55

      Behavior on opacity {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
      }
    }

    // Steam drawn above the cup, always drifting; livelier while playing.
    Steam {
      anchors.fill: parent
      color: root.accent
      active: root.playing
      // Fade back while the spectrum bars occupy the same space.
      opacity: root.playing ? 0.45 : 1.0

      Behavior on opacity {
        NumberAnimation { duration: 200; easing.type: Easing.OutQuad }
      }
    }

    // Live spectrum rising from the cup rim, in the strip the steam occupies.
    Item {
      id: eq
      x: art.width * 5.2 / 24
      y: art.height * 1.6 / 24
      width: art.width * 13.8 / 24
      height: art.height * 6.9 / 24
      visible: root.playing
      opacity: root.playing ? 1 : 0

      readonly property int bars: 4
      readonly property real barGap: Math.max(1, Math.round(width * 0.09))
      readonly property real barWidth: (width - barGap * (bars - 1)) / bars

      Behavior on opacity {
        NumberAnimation { duration: 180; easing.type: Easing.OutQuad }
      }

      Row {
        anchors.fill: parent
        spacing: eq.barGap

        Repeater {
          model: eq.bars

          delegate: Rectangle {
            required property int index

            // Spread the four bars across the musical range.
            readonly property int band: Math.min(11, index * 2 + 2)
            readonly property real value: root.levels.length > band ? root.levels[band] : 0

            width: eq.barWidth
            height: Math.max(1, value * eq.height)
            anchors.bottom: parent.bottom
            radius: width / 2
            color: root.accent
            opacity: 0.92

            Behavior on height {
              NumberAnimation { duration: 50; easing.type: Easing.OutQuad }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- interaction

  MouseArea {
    id: mouse
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    cursorShape: Qt.PointingHandCursor

    onEntered: {
      root.hovered = true
      if (root.bar) root.bar.showTooltip(root, root.tooltipText())
    }
    onExited: {
      root.hovered = false
      if (root.bar) root.bar.hideTooltip(root)
    }
    onClicked: function(event) {
      if (event.button === Qt.RightButton) {
        root.togglePopup()
      } else if (event.button === Qt.MiddleButton) {
        root.toggleMute()
      } else {
        root.toggle()
      }
    }
    onWheel: function(event) {
      if (event.angleDelta.y > 0) root.volumeUp()
      else if (event.angleDelta.y < 0) root.volumeDown()
      event.accepted = true
    }
  }

  // -------------------------------------------------------------- right-click

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(264))
    contentHeight: popup.fittedContentHeight(menu.implicitHeight)

    Column {
      id: menu
      anchors.fill: parent
      spacing: Style.space(4)

      Text {
        width: parent.width
        text: root.stationName
        color: root.fg
        font.family: root.fontFamily
        font.pixelSize: Style.font.subtitle
        font.bold: true
        elide: Text.ElideRight
      }

      Text {
        width: parent.width
        text: root.playing
          ? (root.muted ? "Playing · muted" : "Playing · " + root.volume + "%") +
            (root.sleepSeconds > 0 ? " · sleep " + root.sleepMinutesLeft + "m" : "")
          : "Paused" + (root.sleepSeconds > 0 ? " · sleep " + root.sleepMinutesLeft + "m" : "")
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.7)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }

      // Bigger version of the bar spectrum, so the visualizer is readable.
      Item {
        width: parent.width
        height: Style.space(30)

        Row {
          anchors.fill: parent
          spacing: Math.max(2, Math.round(width * 0.012))

          Repeater {
            model: 24

            delegate: Rectangle {
              required property int index

              readonly property real value: root.bandAt(index * 11 / 23)

              width: (parent.width - parent.spacing * 23) / 24
              height: Math.max(1, value * parent.height)
              anchors.bottom: parent.bottom
              radius: Math.min(1.5, width / 2)
              color: root.accent
              opacity: 0.9

              Behavior on height {
                NumberAnimation { duration: 50; easing.type: Easing.OutQuad }
              }
            }
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
      }

      Repeater {
        model: root.stations

        delegate: Button {
          required property var modelData
          required property int index

          width: menu.width
          text: (index === root.stationIndex ? "● " : "○ ") + modelData.name
          leftAlign: true
          selected: index === root.stationIndex
          bordered: false
          fontSize: Style.font.bodySmall
          fontFamily: root.fontFamily
          foreground: root.fg
          accent: root.accent
          horizontalPadding: Style.space(8)
          verticalPadding: Style.space(4)
          onClicked: {
            root.selectStation(index)
            root.popupOpen = false
          }
        }
      }

      Rectangle {
        width: parent.width
        height: 1
        color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.18)
      }

      Row {
        width: menu.width
        spacing: Style.space(3)

        Text {
          width: menu.width * 0.28
          anchors.verticalCenter: parent.verticalCenter
          text: "Sleep"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Repeater {
          model: [0, 15, 30, 60]

          delegate: Button {
            required property int modelData

            text: modelData === 0 ? "Off" : modelData + "m"
            selected: modelData === root.sleepPreset
            bordered: false
            fontSize: Style.font.caption
            fontFamily: root.fontFamily
            foreground: root.fg
            accent: root.accent
            horizontalPadding: Style.space(6)
            verticalPadding: Style.space(3)
            onClicked: root.setSleep(modelData)
          }
        }
      }

      Row {
        width: menu.width
        spacing: Style.space(3)

        Text {
          width: menu.width * 0.28
          anchors.verticalCenter: parent.verticalCenter
          text: "Volume"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          text: "−"
          bordered: false
          fontSize: Style.font.body
          fontFamily: root.fontFamily
          foreground: root.fg
          accent: root.accent
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(3)
          onClicked: root.volumeDown()
        }

        Text {
          width: Style.space(38)
          anchors.verticalCenter: parent.verticalCenter
          horizontalAlignment: Text.AlignHCenter
          text: root.muted ? "muted" : root.volume + "%"
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        Button {
          text: "+"
          bordered: false
          fontSize: Style.font.body
          fontFamily: root.fontFamily
          foreground: root.fg
          accent: root.accent
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(3)
          onClicked: root.volumeUp()
        }

        Button {
          text: root.muted ? "Unmute" : "Mute"
          selected: root.muted
          bordered: false
          fontSize: Style.font.caption
          fontFamily: root.fontFamily
          foreground: root.fg
          accent: root.accent
          horizontalPadding: Style.space(6)
          verticalPadding: Style.space(3)
          onClicked: root.toggleMute()
        }
      }

      Button {
        width: menu.width
        text: "Open in browser"
        leftAlign: true
        bordered: false
        fontSize: Style.font.caption
        fontFamily: root.fontFamily
        foreground: root.fg
        accent: root.accent
        horizontalPadding: Style.space(8)
        verticalPadding: Style.space(4)
        onClicked: {
          if (!openProc.running) openProc.running = true
          root.popupOpen = false
        }
      }
    }
  }

  // --------------------------------------------------------------------- IPC

  IpcHandler {
    target: "io.github.killerc0w554.lofi-radio"

    function toggle(): void { root.toggle() }
    function status(): string { return root.playing ? "playing" : "idle" }
    function nextStation(): string { root.nextStation(); return root.stationName }
    function station(index: int): string {
      root.selectStation(index)
      return root.stationName
    }
    function sleep(minutes: int): void { root.setSleep(minutes) }
    function volumeUp(): void { root.volumeUp() }
    function volumeDown(): void { root.volumeDown() }
    function mute(): void { root.toggleMute() }
    function popup(): void { root.togglePopup() }
  }

  Component.onCompleted: {
    root.refreshStatus()
    lastUrlProc.running = true
    volumeStateProc.running = true
    muteStateProc.running = true
  }

  onPlayingChanged: {
    if (!root.playing) root.levels = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  }
}
