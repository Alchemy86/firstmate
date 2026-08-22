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

"$SCRIPT_DIR/fm-tg-isfirstmate.sh" || exit 0

IN="$STATE/tg-inbox"
DONE="$STATE/tg-processed"
mkdir -p "$IN" "$DONE"

if pending=$(python3 "$SCRIPT_DIR/fm-tg-drain.py" "$IN" "$DONE"); then
  printf '%s\n' "$pending" >&2
  exit 2
fi

out=$(FM_TG_WAIT_MAX=${FM_TG_HOOK_MAX:-1800} "$SCRIPT_DIR/fm-tg-wait.sh" 2>/dev/null)
case "$out" in
  *CAPTAIN:*)
    echo "$out" >&2
    # DELIBERATELY NOT marking these as surfaced beyond what fm-tg-wait.sh's
    # own delegation to fm-tg-drain.py already did. An earlier version called
    # a separate mark step here on the assumption that the waiter's own print
    # actually reached the model; when it did not, the message was already
    # counted once and the next drain retired it - so three of the captain's
    # messages were archived on 2026-08-21 without ever being seen. Seeing a
    # message an extra time is a trivial cost; losing one is not.
    exit 2
    ;;
esac
exit 0
