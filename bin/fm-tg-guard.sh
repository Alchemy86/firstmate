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

"$SCRIPT_DIR/fm-tg-isfirstmate.sh" || exit 0

SENT="$STATE/.tg-last-sent"
SURF="$STATE/.tg-last-surfaced"

[ -f "$SURF" ] || exit 0
s=$(stat -c %Y "$SURF" 2>/dev/null || echo 0)
r=$(stat -c %Y "$SENT" 2>/dev/null || echo 0)

if [ "$s" -gt "$r" ]; then
  cat >&2 <<MSG
UNANSWERED CAPTAIN MESSAGE — you surfaced a message from the captain and have
not sent a reply to Telegram since. He reads Telegram, not this terminal; an
answer written here did not reach him.

Send it now:  $SCRIPT_DIR/fm-tg-send.sh 'your answer'

If it repeats a question you already answered, SEND IT ANYWAY and say it may be
a duplicate. A duplicate costs him nothing; silence costs him the answer.
MSG
  exit 2
fi
exit 0
