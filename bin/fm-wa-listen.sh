#!/usr/bin/env bash
# Supervise the inbound WhatsApp listener for this home.
#
# Usage:
#   fm-wa-listen.sh start        launch the listener in the background (idempotent)
#   fm-wa-listen.sh stop         stop it
#   fm-wa-listen.sh restart      stop then start
#   fm-wa-listen.sh status       report pairing and liveness
#   fm-wa-listen.sh pair [num] [--rounds N]
#                                pair a NEW linked device and print the code the
#                                captain types into WhatsApp on his phone; each
#                                code lives a couple of minutes, so --rounds
#                                keeps issuing a fresh one when the last expires
#   fm-wa-listen.sh unpair       delete this listener's credentials only
#   fm-wa-listen.sh logs [n]     tail the listener log
#
# The listener holds its OWN linked-device credentials in state/wa-auth, which
# is deliberately NOT mudslide's folder: WhatsApp allows one live connection per
# credential folder, so sharing mudslide's would break `mudslide send`. Sending
# stays entirely on mudslide (bin/fm-wa-send.sh) and is never touched by this
# script. docs/whatsapp-channel.md owns that decision in full.
#
# Every subcommand is a hard no-op with a clear message when the channel is off.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wa-lib.sh
. "$SCRIPT_DIR/fm-wa-lib.sh"

LISTENER="$SCRIPT_DIR/fm-wa-listen.mjs"

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

require_config() {
  if ! fm_wa_load_config; then
    echo "WhatsApp channel is off: no FM_WA_CAPTAIN in ${FM_WA_CONFIG_FILE:-config/whatsapp.env}" >&2
    return 1
  fi
  command -v node >/dev/null 2>&1 || { echo "error: node is required for the WhatsApp listener" >&2; return 1; }
  [ -f "$LISTENER" ] && [ ! -L "$LISTENER" ] || { echo "error: listener program is unavailable" >&2; return 1; }
}

listener_env() {
  FM_WA_STATE="$FM_WA_STATE" \
  FM_WA_AUTH_DIR="$FM_WA_AUTH_DIR" \
  FM_WA_CAPTAIN="$FM_WA_CAPTAIN" \
  FM_WA_ALLOW_DEVICES="$FM_WA_ALLOW_DEVICES" \
  FM_WA_HISTORY_HORIZON="$FM_WA_HISTORY_HORIZON" \
  FM_WA_BAILEYS_DIR="${FM_WA_BAILEYS_DIR:-}" \
  node "$LISTENER" "$@"
}

# Pairing state changed, so every record of the OLD link's health is stale.
# Left behind, they make the poll report a fault that has just been repaired and
# suppress the restart that would bring the new link up.
clear_listener_health() {
  rm -f -- \
    "$FM_WA_STATE/wa-listener.status" \
    "$FM_WA_STATE/wa-listener.beat" \
    "$FM_WA_STATE/wa-listener.error" \
    "$FM_WA_STATE/wa-listener.restart" \
    "$FM_WA_STATE/wa-listener.restarts" 2>/dev/null || true
}

cmd_start() {
  require_config || return 1
  if fm_wa_listener_pid >/dev/null; then
    echo "listener already running (pid $(fm_wa_listener_pid))"
    return 0
  fi
  if ! fm_wa_paired; then
    echo "not paired: run bin/fm-wa-listen.sh pair and have the captain enter the code" >&2
    return 1
  fi
  fm_wa_private_dir "$FM_WA_STATE" || { echo "error: state directory is unavailable" >&2; return 1; }
  fm_wa_private_dir "$FM_WA_AUTH_DIR" || { echo "error: credential directory is unavailable" >&2; return 1; }
  # The beat belongs to the process that wrote it. Left behind, the previous
  # listener's last beat makes this one look wedged from its very first cycle,
  # and the poll would stop it again before it ever connected.
  rm -f -- "$FM_WA_STATE/wa-listener.beat" 2>/dev/null || true
  ( umask 077
    FM_WA_STATE="$FM_WA_STATE" \
    FM_WA_AUTH_DIR="$FM_WA_AUTH_DIR" \
    FM_WA_CAPTAIN="$FM_WA_CAPTAIN" \
    FM_WA_ALLOW_DEVICES="$FM_WA_ALLOW_DEVICES" \
    FM_WA_HISTORY_HORIZON="$FM_WA_HISTORY_HORIZON" \
    FM_WA_BAILEYS_DIR="${FM_WA_BAILEYS_DIR:-}" \
    nohup node "$LISTENER" listen >> "$FM_WA_LOG" 2>&1 &
    echo $! > "$FM_WA_PIDFILE"
  )
  chmod 600 "$FM_WA_PIDFILE" "$FM_WA_LOG" 2>/dev/null || true
  sleep 1
  if fm_wa_listener_pid >/dev/null; then
    # A start run by hand is the operator's own repair, so it releases the
    # poll's restart history and the block it holds. An automatic restart the
    # poll spawned must not, or a listener that dies slowly would erase the very
    # history that proves it is flapping.
    if [ -z "${FM_WA_AUTOSTART:-}" ]; then
      rm -f -- \
        "$FM_WA_STATE/wa-listener.restarts" \
        "$FM_WA_STATE/wa-listener.restart" \
        "$FM_WA_STATE/wa-listener.error" 2>/dev/null || true
    fi
    echo "listener started (pid $(fm_wa_listener_pid))"
  else
    echo "error: listener exited immediately; see state/wa-listener.log" >&2
    return 1
  fi
}

cmd_stop() {
  require_config || return 1
  local pid
  if ! pid=$(fm_wa_listener_pid); then
    rm -f -- "$FM_WA_PIDFILE"
    echo "listener is not running"
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  local waited=0
  while [ "$waited" -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( waited + 1 ))
  done
  kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
  rm -f -- "$FM_WA_PIDFILE"
  echo "listener stopped"
  if [ -f "$FM_WA_STATE/wa-watch.check.sh" ]; then
    echo "note: the armed check restarts it within a couple of minutes;"
    echo "      run bin/fm-wa-setup.sh disarm first to keep it down"
  fi
}

cmd_status() {
  if ! fm_wa_load_config; then
    echo "channel: off (no FM_WA_CAPTAIN in ${FM_WA_CONFIG_FILE:-config/whatsapp.env})"
    return 0
  fi
  echo "channel: on (captain $FM_WA_CAPTAIN, accepted devices ${FM_WA_ALLOW_DEVICES})"
  if [ -n "$FM_WA_DRY_RUN" ]; then
    echo "dry-run: on"
  else
    echo "dry-run: off"
  fi
  if fm_wa_paired; then
    listener_env status
  else
    echo '{"paired": false}'
  fi
  if fm_wa_listener_pid >/dev/null; then
    echo "listener: running (pid $(fm_wa_listener_pid))"
  else
    echo "listener: not running"
  fi
  local pending=0
  if [ -d "$FM_WA_INBOX" ]; then
    pending=$(find "$FM_WA_INBOX" -maxdepth 1 -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  fi
  echo "inbox: $pending pending"
  if [ -f "$FM_WA_STATE/wa-listener.status" ]; then
    printf 'last connection event: '
    cat "$FM_WA_STATE/wa-listener.status"
  fi
  # A live pid is not a live channel, so say plainly when the connection has
  # never come up rather than leaving the beat line out.
  if [ -f "$FM_WA_STATE/wa-listener.beat" ]; then
    echo "last connected beat: $(fm_wa_age_of "$FM_WA_STATE/wa-listener.beat")s ago"
  else
    echo "last connected beat: never"
  fi
}

cmd_pair() {
  require_config || return 1
  local number='' rounds=1
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --rounds) rounds=${2-1}; shift 2 || return 2 ;;
      *) number=$1; shift ;;
    esac
  done
  case "$rounds" in
    ''|*[!0-9]*) rounds=1 ;;
  esac
  number=${number:-$FM_WA_CAPTAIN}
  if fm_wa_paired; then
    echo "already paired; run 'unpair' first to link a fresh device" >&2
    return 1
  fi
  fm_wa_private_dir "$FM_WA_AUTH_DIR" || { echo "error: credential directory is unavailable" >&2; return 1; }
  echo "Requesting a pairing code for +$number."
  echo "On the captain's phone: WhatsApp > Settings > Linked Devices >"
  echo "Link a Device > Link with phone number instead, then enter the code below."
  [ "$rounds" -gt 1 ] && echo "A fresh code is issued automatically for up to $rounds windows."
  listener_env pair "$number" "$rounds" || return 1
  clear_listener_health
}

cmd_unpair() {
  require_config || return 1
  cmd_stop >/dev/null 2>&1 || true
  clear_listener_health
  if [ -d "$FM_WA_AUTH_DIR" ] && [ ! -L "$FM_WA_AUTH_DIR" ]; then
    rm -rf -- "$FM_WA_AUTH_DIR"
    echo "removed this listener's credentials; mudslide's session is untouched"
  else
    echo "no listener credentials to remove"
  fi
}

cmd_logs() {
  require_config || return 1
  local n=${1:-40}
  case "$n" in
    ''|*[!0-9]*) n=40 ;;
  esac
  [ -f "$FM_WA_LOG" ] && tail -n "$n" "$FM_WA_LOG" || echo "no listener log yet"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  stop) shift; cmd_stop "$@" ;;
  restart) shift; cmd_stop >/dev/null 2>&1; cmd_start "$@" ;;
  status) shift; cmd_status "$@" ;;
  pair) shift; cmd_pair "$@" ;;
  unpair) shift; cmd_unpair "$@" ;;
  logs) shift; cmd_logs "$@" ;;
  ''|-h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
