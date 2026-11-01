# Lofi Radio Player

A steaming coffee cup for the Omarchy Quattro bar that streams long-running
lofi radio. It bobs and glows while playing, animated steam drifts off the
mug, and a live spectrum visualizer reacts to the audio.

## Install

```sh
omarchy plugin add https://github.com/Killerc0w554/omarchy-lofi-radio.git --enable
```

## Usage

| Action | What it does |
| --- | --- |
| Left-click | Play / stop |
| Right-click | Stations, sleep timer, volume, mute, open-in-browser menu |
| Middle-click | Mute / unmute |
| Scroll | Volume ±5% |
| `SUPER + SHIFT + L` | Toggle playback (see below) |

The menu's sleep timer (`Off`, `15m`, `30m`, `60m`) stops playback when it
expires and shows the remaining minutes in the tooltip and menu.

## Configure

Move the widget to a different bar section:

```sh
omarchy bar move io.github.killerc0w554.lofi-radio --section center
```

Optional extras you can add yourself:

- **Keybinding** — add to `~/.config/hypr/bindings.lua`:
  `o.bind("SUPER + SHIFT + L", "Lofi radio", "omarchy-shell io.github.killerc0w554.lofi-radio toggle")`
  then run `hyprctl reload`.
- **Resume after login** — drop a hook at
  `~/.config/omarchy/hooks/post-boot.d/60-lofi-resume`:

  ```sh
  #!/bin/bash
  LOFI="$HOME/.config/omarchy/plugins/io.github.killerc0w554.lofi-radio/lofi.sh"
  STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lofi-radio/last-playing"
  [[ -x $LOFI ]] || exit 0
  [[ "$(cat "$STATE" 2>/dev/null)" == "1" ]] || exit 0
  sleep 4
  for _ in 1 2 3; do
    "$LOFI" status && exit 0
    "$LOFI" start
    sleep 6
  done
  exit 0
  ```

## Remove

```sh
omarchy plugin remove io.github.killerc0w554.lofi-radio
```

## Stations

Five long-running Lofi Girl / Chillhop streams ship as defaults: Lofi Hip Hop,
Sleep Lofi, Jazz Lofi, Synthwave, and Chillhop. Pick one from the right-click
menu. YouTube streams occasionally go down; if a station stops, pick another
or restart playback.

## Visualizer

While playing, `parec` captures the default audio monitor in small chunks
(`--latency-msec=20`) and `lofi-viz` (built on demand from `viz.c` with `gcc`)
runs an overlapping 1024-point FFT ~50 times a second. It folds the bins into
12 log-spaced bands (40 Hz–8 kHz), applies fast-attack / slow-release meter
ballistics plus a slow automatic gain control, and writes the result (and
overall energy) to `$XDG_RUNTIME_DIR/lofi-radio-levels` via an atomic rename.

The bar draws four reactive bars where the steam rises, the halo follows the
low-end energy, and the menu shows a 24-bar interpolated spectrum.

## IPC

```sh
omarchy-shell io.github.killerc0w554.lofi-radio toggle
omarchy-shell io.github.killerc0w554.lofi-radio status
omarchy-shell io.github.killerc0w554.lofi-radio nextStation
omarchy-shell io.github.killerc0w554.lofi-radio station 0        # 0-4
omarchy-shell io.github.killerc0w554.lofi-radio sleep 30         # minutes, 0 cancels
omarchy-shell io.github.killerc0w554.lofi-radio volumeUp
omarchy-shell io.github.killerc0w554.lofi-radio volumeDown
omarchy-shell io.github.killerc0w554.lofi-radio mute
omarchy-shell io.github.killerc0w554.lofi-radio popup
```

## Files

- `Lofi.qml` — bar widget, menu, steam/halo animation, visualizer, IPC.
- `Logo.js` — the coffee cup SVG, tinted from the live theme colours.
- `Steam.qml` — canvas animation layered over the cup.
- `viz.c` → `lofi-viz` — tiny FFT helper (compiled into the cache) that turns
  monitor audio into 12 bands.
- `lofi.sh` — detached `mpv` controller (start/stop/fade/volume/mute/resume)
  and manager for the `parec`/`lofi-viz` spectrum pipeline.

State lives in `$XDG_STATE_HOME/lofi-radio/` (`last-url`, `last-playing`,
`last-volume`) and the mpv IPC socket at `$XDG_RUNTIME_DIR/lofi-radio.sock`.
Playback is detached with `setsid`, so it survives shell reloads.

`mpv-mpris` exposes the stream to the normal media widget and hardware media
keys automatically.

## Dependencies

`mpv`, `yt-dlp`, `socat`, `mpv-mpris` are used for playback and control; the
visualizer additionally uses `parec` (PulseAudio/PipeWire) and `gcc` (compiled
once, into the cache). All are standard on Omarchy.

## License

[MIT](./LICENSE)
