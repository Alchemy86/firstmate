#!/usr/bin/env bash
# Stop hook: refuse to end a turn that surfaced a captain message without
# sending a reply.
#
# The captain reads Telegram, not the terminal. On 2026-08-22 firstmate began
# treating repeat surfacings as "already answered" and replied in the terminal
# only, so several full answers never reached him and he saw silence. His
# instruction: "make it a system setup.. not a remembering game ffs".
#
# So this is mechanical. Every outbound send stamps state/.tg-last-sent. Every
# surfaced inbound stamps state/.tg-last-surfaced. If a message was surfaced
# more recently than the last reply was SENT, this exits 2 and the turn does
# not end quietly - it comes back with the reminder attached.
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
fm_tg_configured || exit 0
"$SCRIPT_DIR/fm-tg-isfirstmate.sh" || exit 0

SENT="$STATE/.tg-last-sent"
SURF="$STATE/.tg-last-surfaced"
BUDGET_FILE="$STATE/.turnend-tg-guard-blocks"

[ -f "$SURF" ] || exit 0
s=$(fm_tg_path_mtime "$SURF"); case "$s" in ''|*[!0-9]*) s=0 ;; esac
r=$(fm_tg_path_mtime "$SENT"); case "$r" in ''|*[!0-9]*) r=0 ;; esac

if [ "$s" -le "$r" ]; then
  fm_tg_budget_clear "$BUDGET_FILE"
  exit 0
fi

# Bounded: the same unanswered message set may hold the turn only so many
# times, so an unreachable Telegram cannot wedge the session
# (bin/fm-tg-hook-lib.sh).
#
# The key is WHICH messages are unanswered, never the surfacing time. Keying on
# the marker's mtime looked equivalent and was not: bin/fm-tg-drain.py rewrites
# that marker on every turn end, so the key changed every turn, the count reset
# to 1 every turn, and the budget never bounded anything - the guard blocked for
# ever, which is exactly the wedge it was added to prevent.
if ! fm_tg_budget_ok "$BUDGET_FILE" "$(fm_tg_pending_key "$STATE/tg-inbox")"; then
  echo "fm-tg-guard: no reply has gone out for the message surfaced at $s and the turn has already been held for it; standing down so the session is not wedged. Send it with $SCRIPT_DIR/fm-tg-send.sh once Telegram is reachable." >&2
  exit 0
fi

cat >&2 <<MSG
UNANSWERED CAPTAIN MESSAGE — you surfaced a message from the captain and have
not sent a reply to Telegram since. He reads Telegram, not this terminal; an
answer written here did not reach him.

Send it now:  $SCRIPT_DIR/fm-tg-send.sh 'your answer'

If it repeats a question you already answered, SEND IT ANYWAY and say it may be
a duplicate. A duplicate costs him nothing; silence costs him the answer.
MSG
exit 2
