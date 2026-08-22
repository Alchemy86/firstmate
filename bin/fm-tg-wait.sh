#!/usr/bin/env bash
# Block until the captain sends a Telegram message, then print it and exit.
# Run as a harness-tracked background task, or invoked from bin/fm-tg-hook.sh's
# Stop hook: its completion IS the ping. Completely inert with no
# ~/.config/fm-telegram.env, or with either of TG_TOKEN and TG_CHAT_ID empty.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENVF="${FM_TG_ENV_OVERRIDE:-$HOME/.config/fm-telegram.env}"

# fm_run_timed: the repo's single owner of bounded execution. A bare `timeout`
# is absent on macOS, where every long poll would have failed instantly and,
# together with the retry paths below, spun this loop at full CPU.
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

[ -f "$ENVF" ] || exit 0
set -a
# shellcheck source=/dev/null # ENVF is a resolved runtime path, not a repo file
. "$ENVF"
set +a
# Both values, exactly as fm_tg_configured requires (bin/fm-tg-hook-lib.sh).
# TG_CHAT_ID is not just addressing: bin/fm-tg-fetch.py's captain-impersonation
# filter compares every inbound update against it, and a token-only config left
# that filter with nothing to compare, so any stranger who knows the bot's
# public username was recorded and surfaced as the captain.
if [ -z "${TG_TOKEN:-}" ] || [ -z "${TG_CHAT_ID:-}" ]; then exit 0; fi

# The captain's message bodies and the offset are private state; keep whatever
# this waiter creates owner-only, matching bin/fm-tg-poll.sh.
umask 077
IN="$STATE/tg-inbox"
OFF="$STATE/.tg-offset"
DONE="$STATE/tg-processed"
mkdir -p "$IN"
MAX=${FM_TG_WAIT_MAX:-3600}    # give up after this long so the task never hangs forever
start=$(date +%s)

# Every pass that reaches no network spawns a python3 drain plus a curl. The
# happy path self-paces on Telegram's own 50s long poll, but a pass that gets no
# usable answer returns instantly, so without a backoff this loop burned CPU
# spawning processes for the whole FM_TG_HOOK_MAX window, on every turn end.
#
# A failed pass is NOT just a failed transfer. curl reports an HTTP error body
# as a perfectly successful transfer, and Telegram returns one instantly for the
# conditions this feature actually meets: a 409 when two getUpdates callers
# share a token (this waiter and the watcher's own poll shim by design), a 429
# rate limit, a 401 for a revoked token. Those are ~16 no-delay iterations a
# second, measured. So the pass is judged on whether the FETCH could use the
# response (bin/fm-tg-fetch.py exit 3 = unusable), not on whether curl ran.
BACKOFF_BASE=${FM_TG_WAIT_BACKOFF:-2}
case "$BACKOFF_BASE" in ''|*[!0-9]*|0) BACKOFF_BASE=2 ;; esac
BACKOFF_MAX=${FM_TG_WAIT_BACKOFF_MAX:-60}
case "$BACKOFF_MAX" in ''|*[!0-9]*|0) BACKOFF_MAX=60 ;; esac
fails=0
back_off() {
  fails=$(( fails + 1 ))
  local nap=$(( BACKOFF_BASE * fails ))
  [ "$nap" -gt "$BACKOFF_MAX" ] && nap=$BACKOFF_MAX
  local left=$(( MAX - ( $(date +%s) - start ) ))
  [ "$nap" -gt "$left" ] && nap=$left
  [ "$nap" -gt 0 ] && sleep "$nap"
  return 0
}

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
  resp=$(fm_run_timed 70 curl -s --max-time 70 \
    "https://api.telegram.org/bot$TG_TOKEN/getUpdates?offset=$offset&timeout=50" 2>/dev/null) \
    || { back_off; continue; }
  [ -n "$resp" ] || { back_off; continue; }
  # Bound the fetch by what is left of this waiter's own lifetime, so a slow
  # media download cannot outlive the Stop hook that is waiting on it.
  budget=$(( MAX - ( $(date +%s) - start ) ))
  [ "$budget" -gt 180 ] && budget=180
  [ "$budget" -gt 0 ] || continue
  out=$(printf '%s' "$resp" \
    | FM_TG_FETCH_BUDGET="$budget" python3 "$SCRIPT_DIR/fm-tg-fetch.py" wait "$IN" "$OFF" "$SCRIPT_DIR/fm-tg-send.sh")
  rc=$?
  # Only a response the fetch actually consumed counts as progress.
  [ "$rc" -eq 0 ] || { back_off; continue; }
  fails=0
  if [ -n "$out" ]; then
    printf '%s\n' "$out"
    exit 0
  fi
done
