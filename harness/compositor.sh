#!/usr/bin/env bash
# Contained Hyprland test compositor. See docs/ENVIRONMENT.required.md.
#
# Every rail here exists to guarantee the harness cannot touch the live session.
# Read that doc before changing any of this.
set -uo pipefail

HYPR_BUILD="${HYPR_BUILD:-$HOME/workspace/Hyprland-v0.56.2/build/Hyprland}"
TESTDIR="${TESTDIR:-/run/user/$(id -u)/hpt}"   # MUST stay <=25 chars (sockaddr_un)
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-$REPO/harness/probe.lua}"

# Absolute host socket, captured BEFORE we override XDG_RUNTIME_DIR.
HOST_WL="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/${WAYLAND_DISPLAY:-wayland-0}"
LIVE_SIG="${HYPRLAND_INSTANCE_SIGNATURE:-}"

die() { echo "harness: $*" >&2; exit 1; }

[ ${#TESTDIR} -le 25 ] || die "TESTDIR '$TESTDIR' is ${#TESTDIR} chars; must be <=25 (sockaddr_un limit)"
[ -x "$HYPR_BUILD" ]   || die "no compositor at $HYPR_BUILD (run 'make debug' in the worktree)"

sig() { local d; d=$(ls -d "$TESTDIR"/hypr/*/ 2>/dev/null | head -1) || return 1; [ -n "$d" ] && basename "$d"; }

# Refuse to address anything that is not our own instance.
guard() {
  local s="$1"
  [ -n "$s" ]            || die "no test instance running"
  [ "$s" != "$LIVE_SIG" ] || die "REFUSING: target signature is the LIVE session"
}

start() {
  [ -n "$(sig 2>/dev/null)" ] && die "an instance is already running (sig $(sig))"
  [ -S "$HOST_WL" ] || die "host wayland socket not found at $HOST_WL"
  rm -rf "$TESTDIR"; mkdir -p "$TESTDIR"; chmod 700 "$TESTDIR"

  # ulimit -c 0: a crash here must not deposit a core in the system coredump store.
  ( ulimit -c 0
    exec env -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
      XDG_RUNTIME_DIR="$TESTDIR" \
      WAYLAND_DISPLAY="$HOST_WL" \
      AQ_DRM_DEVICES=/nonexistent \
      HYPRLAND_NO_SD_NOTIFY=1 HYPRLAND_NO_SD_VARS=1 HYPRLAND_NO_CRASHREPORTER=1 \
      HYPRPLACE_DB="$TESTDIR/db.lua" \
      "$HYPR_BUILD" --config "$CONFIG"
  ) >"$TESTDIR/../hpt.log" 2>&1 &

  local s
  for _ in $(seq 1 60); do
    s=$(sig 2>/dev/null) && [ -n "$s" ] && [ -S "$TESTDIR/hypr/$s/.socket.sock" ] && break
    sleep 0.5
  done
  s=$(sig 2>/dev/null) || die "compositor did not come up; see $TESTDIR/../hpt.log"
  guard "$s"
  echo "started: $s"
}

cmd()  { local s; s=$(sig); guard "$s"; XDG_RUNTIME_DIR="$TESTDIR" hyprctl -i "$s" "$@"; }
repl() { cmd repl "$*"; }

stop() {
  local s; s=$(sig 2>/dev/null) || true
  if [ -n "${s:-}" ]; then guard "$s"; XDG_RUNTIME_DIR="$TESTDIR" hyprctl -i "$s" dispatch exit >/dev/null 2>&1; sleep 2; fi
  # Only ever signal a pid whose cmdline is unmistakably our build.
  for p in $(pgrep -f "$HYPR_BUILD --config" 2>/dev/null); do
    if tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q "$HYPR_BUILD"; then
      kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null
    fi
  done
  rm -rf "$TESTDIR"
  echo "stopped"
}

case "${1:-}" in
  start) start ;;
  stop)  stop ;;
  sig)   sig ;;
  cmd)   shift; cmd "$@" ;;
  repl)  shift; repl "$@" ;;
  *) echo "usage: $0 {start|stop|sig|cmd <hyprctl args>|repl <lua>}" >&2; exit 2 ;;
esac
