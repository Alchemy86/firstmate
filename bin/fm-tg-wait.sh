#!/usr/bin/env bash
# Block until the captain sends a Telegram message, then print it and exit.
# Run as a harness-tracked background task, or invoked from bin/fm-tg-hook.sh's
# Stop hook: its completion IS the ping. Completely inert with no
# ~/.config/fm-telegram.env or an empty TG_TOKEN.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENVF="${FM_TG_ENV_OVERRIDE:-$HOME/.config/fm-telegram.env}"

[ -f "$ENVF" ] || exit 0
set -a
# shellcheck source=/dev/null # ENVF is a resolved runtime path, not a repo file
. "$ENVF"
set +a
[ -n "${TG_TOKEN:-}" ] || exit 0

IN="$STATE/tg-inbox"
OFF="$STATE/.tg-offset"
DONE="$STATE/tg-processed"
mkdir -p "$IN"
MAX=${FM_TG_WAIT_MAX:-3600}    # give up after this long so the task never hangs forever
start=$(date +%s)

while :; do
  now=$(date +%s)
  [ $(( now - start )) -ge "$MAX" ] && { echo "telegram: no message in ${MAX}s (re-arm)"; exit 0; }

  # THE RACE THIS FIXES (2026-08-22, the captain's fourth report of silence).
  # Two things poll Telegram: this waiter, and the watcher's own
  # tg-watch.check.sh -> fm-tg-poll.sh. Telegram hands an update to WHICHEVER
  # ASKS FIRST. When the poll shim wins, it files the message in
  # state/tg-inbox and this waiter - the only one that can WAKE the model -
  # keeps blocking for up to MAX seconds waiting for something that has
  # already been taken. The captain's message then sits unread until this
  # loop times out, which is why the silence was intermittent rather than
  # total. So: check the inbox every pass, not just the network. Delegate to
  # the drain so the inbox check MARKS and, when the poll shim's own
  # arrival-time ack did not land, ACKS what it prints.
  if out=$(python3 "$SCRIPT_DIR/fm-tg-drain.py" "$IN" "$DONE"); then
    printf '%s\n' "$out"
    exit 0
  fi

  offset=$(cat "$OFF" 2>/dev/null || echo 0)
  # long poll: returns as soon as a message arrives, else after 50s
  resp=$(timeout 70 curl -s "https://api.telegram.org/bot$TG_TOKEN/getUpdates?offset=$offset&timeout=50" 2>/dev/null) || continue
  [ -n "$resp" ] || continue
  out=$(printf '%s' "$resp" | python3 "$SCRIPT_DIR/fm-tg-fetch.py" wait "$IN" "$OFF" "$SCRIPT_DIR/fm-tg-send.sh")
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
  fi
done
