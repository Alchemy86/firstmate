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
mkdir -p "$IN"
offset=$(cat "$OFF" 2>/dev/null || echo 0)

resp=$(timeout 20 curl -s "https://api.telegram.org/bot$TG_TOKEN/getUpdates?offset=$offset&timeout=0" 2>/dev/null) || exit 0
[ -n "$resp" ] || exit 0

printf '%s' "$resp" | python3 "$SCRIPT_DIR/fm-tg-fetch.py" poll "$IN" "$OFF" "$SCRIPT_DIR/fm-tg-send.sh"
exit 0
