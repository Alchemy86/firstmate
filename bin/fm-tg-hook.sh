#!/usr/bin/env bash
# Stop hook wrapper. Two jobs, in this order:
#   1. Surface every pending captain message (bin/fm-tg-drain.py).
#   2. Only if none were pending, long-poll for a new one (bin/fm-tg-wait.sh).
# Exit 2 = blocking error, which wakes the model. Exit 0 = nothing to say.
#
# Both halves exist because of real losses on 2026-08-21: messages the watcher
# fetched mid-turn were skipped for ever by the waiter, and messages archived
# on first print vanished when the wake did not reach the model. See
# bin/fm-tg-drain.py for the surface-until-answered rule.
#
# The long poll is single-flight per home (state/.tg-hook.lock): the harness
# starts a fresh background firing on every stop and never dedupes them.
#
# Registered project-scoped in this repo's own .claude/settings.json
# (docs/telegram.md) so only a session actually running as firstmate loads
# this hook at all; bin/fm-tg-isfirstmate.sh is kept as defense in depth for
# a crewmate that happens to be working on firstmate's own repo, since it
# would otherwise check out this same tracked hook registration.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-tg-hook-lib.sh
. "$SCRIPT_DIR/fm-tg-hook-lib.sh"

fm_tg_hook_foreign_host && exit 0
# Nothing below may touch the filesystem on a machine with no Telegram config:
# an unconfigured home must stay byte-for-byte unchanged (docs/telegram.md), and
# an ungated mkdir here created state/tg-inbox and state/tg-processed on every
# turn end of every firstmate primary that had never configured Telegram.
fm_tg_configured || exit 0
"$SCRIPT_DIR/fm-tg-isfirstmate.sh" || exit 0

# The captain's message bodies are private state; whatever this hook creates is
# owner-only, matching bin/fm_tg_records.py and the two pollers.
umask 077
IN="$STATE/tg-inbox"
DONE="$STATE/tg-processed"
BUDGET_FILE="$STATE/.turnend-tg-hook-blocks"
mkdir -p "$IN" "$DONE"

# Bounded, but keyed on WHICH messages are pending, so a new or newly-answered
# message always gets a full budget and only an unchanged, unanswerable set
# ever runs out (bin/fm-tg-hook-lib.sh).
block_pending() {  # <surfaced-output>
  if ! fm_tg_budget_ok "$BUDGET_FILE" "$(fm_tg_pending_key "$IN")"; then
    echo "fm-tg-hook: the same captain message(s) are still pending after repeatedly holding the turn for them; standing down so the session is not wedged. They stay in $IN and surface again once anything changes." >&2
    exit 0
  fi
  printf '%s\n' "$1" >&2
  exit 2
}

if pending=$(python3 "$SCRIPT_DIR/fm-tg-drain.py" "$IN" "$DONE"); then
  block_pending "$pending"
fi
fm_tg_budget_clear "$BUDGET_FILE"

# --- single-flight waiter claim ----------------------------------------------
# Claude fires an asyncRewake Stop hook in the background on EVERY stop with no
# deduplication across firings (bin/fm-claude-stop-autoarm.sh records that
# contract, and carries state/.claude-autoarm.lock for exactly this reason).
# Each firing's long poll below lives for up to FM_TG_HOOK_MAX, so without a
# claim a session with frequent turns accumulates waiters that all call
# getUpdates on the one bot token - which Telegram answers by terminating the
# others' long poll with a 409, a tight ping-pong between accumulated waiters.
# Exactly one waiter per home: every other firing exits 0, having already
# surfaced anything pending in the drain above, and this home's live waiter
# remains free to wake the model when the next message lands.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
WAIT_LOCK="$STATE/.tg-hook.lock"
fm_lock_try_acquire "$WAIT_LOCK" || exit 0
trap 'fm_lock_release "$WAIT_LOCK"' EXIT

out=$(FM_TG_WAIT_MAX=${FM_TG_HOOK_MAX:-1800} "$SCRIPT_DIR/fm-tg-wait.sh" 2>/dev/null)
case "$out" in
  *CAPTAIN:*)
    # DELIBERATELY NOT marking these as surfaced beyond what fm-tg-wait.sh's
    # own delegation to fm-tg-drain.py already did. An earlier version called
    # a separate mark step here on the assumption that the waiter's own print
    # actually reached the model; when it did not, the message was already
    # counted once and the next drain retired it - so three of the captain's
    # messages were archived on 2026-08-21 without ever being seen. Seeing a
    # message an extra time is a trivial cost; losing one is not.
    block_pending "$out"
    ;;
esac
exit 0
