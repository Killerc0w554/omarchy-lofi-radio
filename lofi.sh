#!/usr/bin/env bash
# lofi-radio — controller for the lofi radio stream.
#
#   lofi.sh status            exit 0 while mpv is streaming
#   lofi.sh start  [url]      (re)start playback
#   lofi.sh stop              stop playback (fades out)
#   lofi.sh toggle [url]      play if stopped, stop if playing
#   lofi.sh volume <+N|-N>    nudge volume, print the new level
#   lofi.sh mute              toggle mute, print true/false
#   lofi.sh resume            start again if it was playing last session
#
# Playback is detached with setsid + nohup so it keeps going even if the shell
# or the script's parent process goes away.
# A per-player IPC socket lets volume/mute/fade talk to the right mpv.
set -uo pipefail

URL_DEFAULT="https://www.youtube.com/watch?v=rFZHOHl-L8A"
RUNTIME="${XDG_RUNTIME_DIR:-/tmp}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/lofi-radio"
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/lofi-radio"
SOCK="$RUNTIME/lofi-radio.sock"
SOCK_ARG="--input-ipc-server=$SOCK"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VIZ="$CACHE/lofi-viz"
LEVELS="$RUNTIME/lofi-radio-levels"
VIZPID="$RUNTIME/lofi-radio-viz.pid"

mkdir -p "$STATE" "$CACHE" "$RUNTIME"

zero_levels() {
  printf '0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000 0.000\n' >"$LEVELS"
}

# Compile the tiny FFT helper on demand; skipping it only loses the bars.
ensure_viz() {
  [[ -x $VIZ && $VIZ -nt $DIR/viz.c ]] && return 0
  command -v gcc >/dev/null 2>&1 || return 1
  mkdir -p "$CACHE"
  gcc -O2 -o "$VIZ.tmp" "$DIR/viz.c" -lm 2>/dev/null && mv "$VIZ.tmp" "$VIZ"
}

stop_viz() {
  local pgid
  if [[ -r $VIZPID ]]; then
    pgid=$(cat "$VIZPID" 2>/dev/null || true)
    if [[ $pgid =~ ^[0-9]+$ ]]; then
      kill -TERM -- "-$pgid" 2>/dev/null || true
    fi
    rm -f "$VIZPID"
  fi
  # Leave the meter flat, so a shell reload while idle never shows stale bars.
  rm -f "$LEVELS.tmp"
  zero_levels
}

start_viz() {
  stop_viz
  ensure_viz || return 0
  command -v parec >/dev/null 2>&1 || return 0
  # Capture the default monitor (the mix everything plays through) and turn it
  # into 12 bands + overall energy. The session leader writes its own PID so
  # stop_viz can kill the whole parec|viz group in one go.
  setsid bash -c 'echo $$ >"$3"; parec --device=@DEFAULT_MONITOR@ --format=s16le --rate=44100 --channels=1 --latency-msec=20 --process-time-msec=10 2>/dev/null | "$1" "$2"' \
    _ "$VIZ" "$LEVELS" "$VIZPID" >/dev/null 2>&1 </dev/null &
}

# Find our mpv by inspecting the command line of actual mpv processes only.
# (A `pgrep -f` pattern can also match the calling shell, which would make
# `stop` kill its own caller.)
player_pids() {
  local pid
  for pid in $(pgrep -x mpv 2>/dev/null); do
    if tr '\0' '\n' <"/proc/$pid/cmdline" 2>/dev/null | grep -qxF -- "$SOCK_ARG"; then
      printf '%s\n' "$pid"
    fi
  done
}

is_playing() {
  [[ -n $(player_pids) ]]
}

ipc() {
  [[ -S $SOCK ]] || return 1
  printf '%s\n' "$1" | socat -t 1 - UNIX-CONNECT:"$SOCK" 2>/dev/null
}

save_url() { printf '%s\n' "$1" >"$STATE/last-url"; }
save_playing() { printf '%s\n' "$1" >"$STATE/last-playing"; }

last_url() {
  local u
  u=$(cat "$STATE/last-url" 2>/dev/null || true)
  [[ -n $u ]] || u="$URL_DEFAULT"
  printf '%s\n' "$u"
}

last_volume() {
  local v
  v=$(cat "$STATE/last-volume" 2>/dev/null || true)
  [[ $v =~ ^[0-9]+$ ]] || v=65
  printf '%s\n' "$v"
}

get_prop() {
  ipc "{\"command\":[\"get_property\",\"$1\"]}" \
    | sed -n 's/.*"data":\([^,}]*\).*/\1/p' | tr -d '"'
}

stop() {
  local pids pid
  stop_viz
  pids=$(player_pids)
  if [[ -n $pids ]]; then
    # Quick fade-out so it never cuts abruptly.
    for _ in 1 2 3 4; do
      ipc '{"command":["add","volume",-20]}' >/dev/null
      sleep 0.05
    done
    for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  fi
  save_playing 0
}

start() {
  local url="${1:-$(last_url)}"
  if ! command -v mpv >/dev/null 2>&1; then
    echo "lofi-radio: mpv is not installed" >&2
    return 1
  fi
  stop

  local vol
  vol=$(last_volume)
  rm -f "$SOCK"

  # setsid puts mpv in its own session/process group so neither the calling
  # shell nor the QML Process that spawned it can reap it on exit.
  setsid nohup mpv \
    --no-video \
    --force-window=no \
    --no-terminal \
    --really-quiet \
    --input-ipc-server="$SOCK" \
    --ytdl-format=bestaudio/best \
    --volume="$vol" \
    --af=afade=t=in:st=0:d=2 \
    "$url" >/dev/null 2>&1 </dev/null &

  save_url "$url"
  save_playing 1
  start_viz
}

adjust_volume() {
  local delta="${1:-0}"
  is_playing || return 1
  local cur new
  cur=$(get_prop volume)
  cur=${cur%.*}
  [[ $cur =~ ^[0-9]+$ ]] || cur=$(last_volume)
  new=$((cur + delta))
  (( new < 0 )) && new=0
  (( new > 100 )) && new=100
  ipc "{\"command\":[\"set_property\",\"volume\",$new]}" >/dev/null
  printf '%s\n' "$new" >"$STATE/last-volume"
  printf '%s\n' "$new"
}

mute_toggle() {
  is_playing || return 1
  ipc '{"command":["cycle","mute"]}' >/dev/null
  get_prop mute
}

resume() {
  [[ "$(cat "$STATE/last-playing" 2>/dev/null || true)" == "1" ]] || return 0
  is_playing && return 0
  start
}

case "${1:-toggle}" in
  status)
    if is_playing; then
      exit 0
    fi
    # No player: if we previously thought it was live, it died on its own.
    # Clear the resume flag so a login does not resurrect a dead stream.
    if [[ "$(cat "$STATE/last-playing" 2>/dev/null || true)" == "1" ]]; then
      save_playing 0
    fi
    stop_viz
    exit 1
    ;;
  start | play) start "${2:-}" ;;
  stop) stop ;;
  toggle) if is_playing; then stop; else start "${2:-}"; fi ;;
  volume) adjust_volume "${2:-0}" ;;
  mute) mute_toggle ;;
  resume) resume ;;
  lasturl) last_url ;;
  getvolume) last_volume ;;
  getmute)
    if is_playing; then
      m=$(get_prop mute)
      [[ $m == true || $m == false ]] || m=false
      printf '%s\n' "$m"
    else
      printf 'false\n'
    fi
    ;;
  *)
    echo "usage: $0 [status|start|stop|toggle|volume <delta>|mute|resume|lasturl|getvolume|getmute] [url]" >&2
    exit 2
    ;;
esac
