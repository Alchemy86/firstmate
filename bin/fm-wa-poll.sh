#!/usr/bin/env bash
# One bounded poll of the inbound WhatsApp inbox for this home.
#
# Inert by default: a HARD no-op (exit 0, no output) unless the channel is
# configured via a non-empty FM_WA_CAPTAIN in config/whatsapp.env. The watcher
# runs it through the ordinary registered-custom-check path
# (state/wa-watch.check.sh, bound by bin/fm-check-register.sh), so nothing in
# the supervision loop itself changes: its contract is "output => wake
# firstmate, silence => keep sleeping", and the no-op keeps a home that never
# opted in behaving exactly as before.
#
# This poll never talks to WhatsApp. bin/fm-wa-listen.sh runs the one long-lived
# connection that stashes messages; this is a local directory read plus a
# liveness nudge, so it finishes in milliseconds, far inside FM_CHECK_TIMEOUT.
#
# Behavior when the channel is on:
#   empty inbox                      -> print nothing, exit 0 (no wake)
#   an inbox set already announced   -> print nothing, exit 0
#   a new or changed inbox set       -> print one line
#                                       "wa-message <n> pending, including <id>"
#   an inbox that stayed pending past FM_WA_REANNOUNCE seconds
#                                    -> re-announce once, so a message firstmate
#                                       failed to drain is not lost silently
#   listener down but paired         -> restart it in the background, rate-limited
#   a configuration or listener fault -> one rate-limited "wa-channel-error ..."
#
# The announcement marker is a digest of the pending id set, not a per-message
# claim: one wake covers everything waiting, and draining the inbox is what
# clears it. A check that printed on every cycle would wake firstmate constantly.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wa-lib.sh
. "$SCRIPT_DIR/fm-wa-lib.sh"

# Hard no-op when the channel is off: this is what keeps the check shim inert.
fm_wa_load_config || exit 0

RESTART_MARKER="$FM_WA_STATE/wa-listener.restart"
RESTART_INTERVAL=120
LISTENER_ERROR="$FM_WA_STATE/wa-listener.error"

# One diagnostic per distinct problem, not one per cycle. Listener faults and
# poll faults keep separate markers so clearing one never re-fires the other.
emit_error_once() {
  local marker=$1 base=$2 msg=$3
  if [ "$(cat "$marker" 2>/dev/null)" = "$msg" ] \
    && [ "$(fm_wa_age_of "$marker")" -lt 3600 ]; then
    return 0
  fi
  printf '%s\n' "$msg" | fm_wa_publish_stdin "$FM_WA_STATE" "$base" 2>/dev/null || true
  printf 'wa-channel-error %s\n' "$msg"
}

emit_listener_error() { emit_error_once "$LISTENER_ERROR" wa-listener.error "$1"; }
emit_poll_error() { emit_error_once "$FM_WA_ERROR" wa-poll.error "$1"; }

# Keep the one long-lived connection up without ever blocking this check: the
# start is a detached background spawn and its outcome is reported next cycle.
ensure_listener() {
  if fm_wa_listener_pid >/dev/null 2>&1; then
    return 0
  fi
  if ! fm_wa_paired; then
    emit_listener_error "WhatsApp listener is not paired; run bin/fm-wa-listen.sh pair"
    return 1
  fi
  if [ "$(fm_wa_age_of "$RESTART_MARKER")" -lt "$RESTART_INTERVAL" ]; then
    return 1
  fi
  : | fm_wa_publish_stdin "$FM_WA_STATE" "wa-listener.restart" 2>/dev/null || true
  FM_HOME="$FM_HOME" setsid "$SCRIPT_DIR/fm-wa-listen.sh" start >/dev/null 2>&1 </dev/null &
  return 1
}

if ensure_listener; then
  rm -f -- "$LISTENER_ERROR" 2>/dev/null || true
fi

[ -d "$FM_WA_INBOX" ] || exit 0

# Sorted so the digest depends on the pending set, not on readdir order. The
# named id is just the first in that order - WhatsApp ids are not chronological,
# so the wake line names one for traceability and the skill drains them all.
PENDING=$(find "$FM_WA_INBOX" -maxdepth 1 -name '*.json' -type f -printf '%f\n' 2>/dev/null | LC_ALL=C sort) || exit 0
[ -n "$PENDING" ] || { rm -f -- "$FM_WA_ERROR" "$FM_WA_OFFERED" 2>/dev/null; exit 0; }

COUNT=$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')
FIRST=$(printf '%s\n' "$PENDING" | head -n 1)
FIRST=${FIRST%.json}
fm_wa_id_safe "$FIRST" || { emit_poll_error "inbox holds an unusable message id"; exit 0; }

SIG=$(printf '%s\n' "$PENDING" | fm_wa_sha256) || exit 0
[ -n "$SIG" ] || exit 0

# Same pending set as the last announcement, and not yet stale enough to repeat.
if [ "$(cat "$FM_WA_OFFERED" 2>/dev/null)" = "$SIG" ] \
  && [ "$(fm_wa_age_of "$FM_WA_OFFERED")" -lt "$FM_WA_REANNOUNCE" ]; then
  exit 0
fi

printf '%s\n' "$SIG" | fm_wa_publish_stdin "$FM_WA_STATE" "wa-poll.offered" 2>/dev/null \
  || { emit_poll_error "cannot record the WhatsApp inbox announcement"; exit 0; }

rm -f -- "$FM_WA_ERROR" 2>/dev/null || true
printf 'wa-message %s pending, including %s\n' "$COUNT" "$FIRST"
