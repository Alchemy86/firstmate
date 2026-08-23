#!/usr/bin/env bash
# Poll Telegram once for captain messages (state/*.check.sh contract): prints
# ONE summary line only when something new arrived, otherwise nothing.
# Wired into the watcher via the generated state/tg-watch.check.sh shim
# (bin/fm-bootstrap.sh, docs/telegram.md); the config/tg-mode.env cadence file
# it also writes rides the watcher at the same 30s interval as X mode, since
# the default 300s check cycle left a message unfetched for up to five minutes.
#
# New messages are recorded to state/tg-inbox/<update_id>.json and acknowledged
# the moment they arrive, here - not at firstmate's turn end. See
# bin/fm-tg-fetch.py for why arrival time is the only correct moment.
# Completely inert with no ~/.config/fm-telegram.env, or with either of
# TG_TOKEN and TG_CHAT_ID empty.
#
# Everything here has to finish inside the watcher's own per-check bound: the
# watcher kills a check's whole process group at FM_CHECK_TIMEOUT (default 30s,
# read from this check's own environment because the watcher runs it as a
# direct child), and a killed run has written neither the inbox record nor the
# offset, so it would refetch and re-acknowledge the same update on every
# following cycle. The fetch is therefore given an explicit wall-clock budget
# built from what this script has not already spent.
#
# A channel that refuses us is reported, not mistaken for a quiet one: a
# revoked token, a lasting conflict with the Stop hook's long poll, and a rate
# limit all arrive as an error body curl transfers perfectly. state/.tg-poll-error
# holds the last reported reason so one standing failure is reported once
# rather than every cycle, and a usable poll clears it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENVF="${FM_TG_ENV_OVERRIDE:-$HOME/.config/fm-telegram.env}"

# fm_run_timed: the repo's single owner of bounded execution. A bare `timeout`
# is absent on macOS, where this check would have silently never polled.
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

# The captain's message bodies, the offset, and any downloaded media are
# private state, so everything this poll creates is owner-only (the same
# umask 077 bin/fm-check-register.sh uses for its trust records).
umask 077
IN="$STATE/tg-inbox"
OFF="$STATE/.tg-offset"
mkdir -p "$IN"
offset=$(cat "$OFF" 2>/dev/null || echo 0)

CHECK_BUDGET=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_BUDGET" in ''|*[!0-9]*|0) CHECK_BUDGET=30 ;; esac
# Reserve the tail of the budget so the fetch is never still running when the
# watcher's kill lands.
MARGIN=3
GETUPDATES_TMO=$(( CHECK_BUDGET / 4 ))
[ "$GETUPDATES_TMO" -lt 3 ] && GETUPDATES_TMO=3
[ "$GETUPDATES_TMO" -gt 10 ] && GETUPDATES_TMO=10

started=$(date +%s)
resp=$(fm_run_timed "$GETUPDATES_TMO" curl -s --max-time "$GETUPDATES_TMO" \
  "https://api.telegram.org/bot$TG_TOKEN/getUpdates?offset=$offset&timeout=0" 2>/dev/null) || exit 0
[ -n "$resp" ] || exit 0

FETCH_BUDGET=$(( CHECK_BUDGET - ( $(date +%s) - started ) - MARGIN ))
[ "$FETCH_BUDGET" -gt 0 ] || exit 0

err="$STATE/.tg-poll-error"
diag=$(mktemp "$STATE/.tg-poll-diag.XXXXXX" 2>/dev/null) || diag=/dev/null
printf '%s' "$resp" \
  | FM_TG_FETCH_BUDGET="$FETCH_BUDGET" python3 "$SCRIPT_DIR/fm-tg-fetch.py" \
      poll "$IN" "$OFF" "$SCRIPT_DIR/fm-tg-send.sh" 2>"$diag"
rc=$?
reason=$(head -n 1 "$diag" 2>/dev/null | tr -d '\r')
[ "$diag" = /dev/null ] || rm -f -- "$diag"

# fm-tg-fetch.py's own record write leaves "surfaced" at 0 - only
# fm-tg-drain.py increments it and stamps state/.tg-last-surfaced. This
# watcher path prints fetch.py's summary directly (the pipe above) without
# ever running the drain, the identical gap bin/fm-tg-wait.sh's own fetch
# success path had (see its comment) before it started delegating to the
# drain too. Without this, a message the watcher poll wins the getUpdates
# race for is recorded but never marked surfaced, so a reply composed more
# than 10s later finds it still pending under bin/fm-tg-archive.py's
# never-surfaced window and it re-surfaces forever. Run silently - the pipe
# above already produced this check's one wake line.
[ "$rc" -eq 0 ] && { python3 "$SCRIPT_DIR/fm-tg-drain.py" "$IN" "$STATE/tg-processed" >/dev/null 2>&1 || true; }

# A refusal has to be told apart from a quiet channel. A revoked token, a
# sustained rate limit, or a permanent conflict all return an error body that
# curl transfers perfectly, so without this the captain sees exactly what he
# sees when he simply has not written: nothing. Reported once per distinct
# reason - the record is what keeps one broken token from waking firstmate
# every 30 seconds - and cleared by the next usable poll so a recurrence is
# reported again (bin/fm-tool-update-check.sh's state/.tool-updates does the
# same for its own sweep).
record_refusal() {
  local line=$1
  [ "$line" != "$(cat "$err" 2>/dev/null || true)" ] || return 0
  printf '%s\n' "$line"
  if tmp=$(mktemp "$err.XXXXXX" 2>/dev/null); then
    if printf '%s\n' "$line" > "$tmp"; then
      mv -f -- "$tmp" "$err" || rm -f -- "$tmp"
    else
      rm -f -- "$tmp"
    fi
  fi
}

# rc==3 is fm-tg-fetch.py's own "the channel refused this poll" verdict
# (a revoked token, a rate limit, a lasting getUpdates conflict). Any OTHER
# nonzero rc used to fall into the same "else: clear the record" branch as a
# genuine success, on the false assumption that only rc==3 was ever possible -
# so python3 vanishing from PATH after bootstrap armed this shim (rc=127), or
# the watcher killing the check's process group mid-fetch (rc=137/143), each
# produced no output, no wake, AND silently erased any standing refusal
# record, making a permanently broken channel indistinguishable from a
# captain who simply has not written. Only a confirmed rc==0 poll (fetch.py
# actually ran to completion and judged the reply usable) clears the record;
# every other outcome, expected or not, is reported and remembered the same
# dedup'd way so one broken condition does not wake firstmate every cycle.
if [ "$rc" -eq 3 ]; then
  [ -n "$reason" ] || reason="unusable reply"
  record_refusal "telegram: the channel refused the poll ($reason)"
elif [ "$rc" -eq 0 ]; then
  rm -f -- "$err"
else
  [ -n "$reason" ] || reason="exit $rc"
  record_refusal "telegram: the poll failed unexpectedly ($reason)"
fi
exit 0
