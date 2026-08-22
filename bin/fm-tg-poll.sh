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
# Completely inert with no ~/.config/fm-telegram.env or an empty TG_TOKEN.
#
# Everything here has to finish inside the watcher's own per-check bound: the
# watcher kills a check's whole process group at FM_CHECK_TIMEOUT (default 30s,
# read from this check's own environment because the watcher runs it as a
# direct child), and a killed run has written neither the inbox record nor the
# offset, so it would refetch and re-acknowledge the same update on every
# following cycle. The fetch is therefore given an explicit wall-clock budget
# built from what this script has not already spent.
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
[ -n "${TG_TOKEN:-}" ] || exit 0

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

printf '%s' "$resp" \
  | FM_TG_FETCH_BUDGET="$FETCH_BUDGET" python3 "$SCRIPT_DIR/fm-tg-fetch.py" poll "$IN" "$OFF" "$SCRIPT_DIR/fm-tg-send.sh"
exit 0
