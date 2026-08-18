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
# It is also the channel's janitor, silently: the listener log is capped, and
# long-expired per-message markers and outbound digests are pruned on the way
# through.
#
# Exactly one line is ever printed. A cycle that reports a channel fault stops
# there rather than also announcing the inbox, because the two lines mean
# different things to the wa-respond skill and the watcher folds them into one
# wake. The fault is deduped, so the next cycle announces any pending messages.
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
LISTENER_STATUS="$FM_WA_STATE/wa-listener.status"
LISTENER_BEAT="$FM_WA_STATE/wa-listener.beat"
RESTART_FAILS="$FM_WA_STATE/wa-listener.restarts"
# A listener that dies this many times in a row is not going to heal itself.
RESTART_FAIL_LIMIT=3
# ...but "not going to heal itself" must not mean "off until a human notices".
# The restart history is refreshed on every attempt, so once it has gone this
# long untouched the poll tries once more. The channel therefore recovers on its
# own from a transient cause (no network at boot, a host that was asleep) while
# a genuinely broken one still reports rather than respawning every cycle.
LATCH_RETRY_INTERVAL=3600
# One live observation is not proof the channel is stable: a listener dying on a
# period longer than the check interval is seen alive on some cycles, which
# would zero the restart history before it ever reached the limit and let the
# channel flap forever while every cycle reported health. The history is only
# cleared once no restart has been needed for this long.
STABLE_INTERVAL=3600
# The listener touches its beat only while the connection is actually open, so a
# beat this stale means an alive process with a channel that is not working.
STALL_INTERVAL=900
# Housekeeping bounds. The listener logs a line per message and per reconnect,
# and keeps a durable marker per handled message, so both need a ceiling.
LOG_MAX_BYTES=262144
LOG_KEEP_LINES=2000
# Well behind any watermark a redelivery could still clear, so pruning a marker
# can never let an old message back into the inbox.
SEEN_TTL_DAYS=30
# Past the listener's ten-minute echo window an outbound digest is dead by
# definition, so nothing it could still suppress is lost by sweeping it.
SENT_TTL_MINUTES=60
# Dry-run records are evidence to read back, not durable state, and a home can
# run dry for good. Kept long enough to inspect a test, like Relay's contexts.
OUTBOX_TTL_DAYS=7

# Set when this cycle has already spoken, so the check keeps its one-line
# contract.
EMITTED=

# One diagnostic per distinct problem, not one per cycle. Listener faults and
# poll faults keep separate markers so clearing one never re-fires the other.
# Returns 0 when it printed, 1 when the same fault was already reported.
emit_error_once() {
  local marker=$1 base=$2 msg=$3
  if [ "$(cat "$marker" 2>/dev/null)" = "$msg" ] \
    && [ "$(fm_wa_age_of "$marker")" -lt 3600 ]; then
    return 1
  fi
  printf '%s\n' "$msg" | fm_wa_publish_stdin "$FM_WA_STATE" "$base" 2>/dev/null || true
  printf 'wa-channel-error %s\n' "$msg"
  EMITTED=1
  return 0
}

emit_listener_error() { emit_error_once "$LISTENER_ERROR" wa-listener.error "$1"; }
emit_poll_error() { emit_error_once "$FM_WA_ERROR" wa-poll.error "$1"; }

# The listener's own last reported connection state, or empty when it never
# wrote one. Read as data: the file is JSON this home wrote itself.
listener_state() {
  [ -f "$LISTENER_STATUS" ] || return 0
  sed -n 's/.*"state"[[:space:]]*:[[:space:]]*"\([A-Za-z-]*\)".*/\1/p' \
    "$LISTENER_STATUS" 2>/dev/null | tail -n 1
}

restart_failures() {
  local n
  n=$(cat "$RESTART_FAILS" 2>/dev/null) || n=0
  case "$n" in
    ''|*[!0-9]*) n=0 ;;
  esac
  printf '%s' "$n"
}

# The restart MUST leave this check's process group, because the watcher signals
# the whole group once the check returns and would otherwise reap the listener it
# just started. setsid does that; macOS has no setsid, so fall back to perl's own
# setpgrp exactly as bin/fm-watch.sh does for the same reason. nohup is not a
# substitute: it only ignores SIGHUP and leaves the process in this group.
# The wrapper's own refusals - no node, not paired, an unusable state directory,
# an immediate exit - are raised before the listener ever opens its log, so they
# go to that same log rather than to /dev/null. The fault line this poll prints
# after three failed restarts names that log, and it must actually answer why.
# FM_WA_FORCE_SPAWN_FALLBACK=1 drives the fallback on a host that has setsid, so
# the branch a macOS host depends on is testable here, as FM_CHECK_FORCE_FALLBACK
# does for the watcher's own timeout path.
spawn_listener() {
  if [ ! -e "$FM_WA_LOG" ]; then
    ( umask 077; : >> "$FM_WA_LOG" ) 2>/dev/null || true
  fi
  if [ "${FM_WA_FORCE_SPAWN_FALLBACK:-0}" != 1 ] && command -v setsid >/dev/null 2>&1; then
    FM_HOME="$FM_HOME" FM_WA_AUTOSTART=1 setsid \
      "$SCRIPT_DIR/fm-wa-listen.sh" start >>"$FM_WA_LOG" 2>&1 </dev/null &
  elif command -v perl >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # single quotes are deliberate: perl expands its own variables.
    FM_HOME="$FM_HOME" FM_WA_AUTOSTART=1 perl -e 'setpgrp(0, 0); exec @ARGV' \
      "$SCRIPT_DIR/fm-wa-listen.sh" start >>"$FM_WA_LOG" 2>&1 </dev/null &
  else
    # Spawning into this group would only feed the listener to the watcher's
    # own tidy-up, so refuse and say so rather than burning the restart budget.
    return 1
  fi
  disown 2>/dev/null || true
}

# This poll is the channel's only regular janitor, and it must stay silent while
# it works: neither branch below ever prints. The log is rewritten in place so
# the running listener's append handle keeps writing to the same file.
prune_state() {
  local size
  if [ -f "$FM_WA_LOG" ]; then
    size=$(wc -c < "$FM_WA_LOG" 2>/dev/null | tr -d '[:space:]') || size=0
    case "$size" in
      ''|*[!0-9]*) size=0 ;;
    esac
    if [ "$size" -ge "$LOG_MAX_BYTES" ]; then
      if ( umask 077; tail -n "$LOG_KEEP_LINES" "$FM_WA_LOG" > "$FM_WA_LOG.trim" ) 2>/dev/null; then
        cat "$FM_WA_LOG.trim" > "$FM_WA_LOG" 2>/dev/null || true
      fi
      rm -f -- "$FM_WA_LOG.trim" 2>/dev/null || true
    fi
  fi
  if [ -d "$FM_WA_SEEN" ]; then
    find "$FM_WA_SEEN" -maxdepth 1 -name '*.seen' -type f -mtime "+$SEEN_TTL_DAYS" \
      -exec rm -f -- {} + 2>/dev/null || true
  fi
  # The listener only sweeps outbound digests while handling an inbound message,
  # so a home that replies and hears nothing back never sweeps at all. This is
  # the third growth surface and it is bounded here with the other two.
  if [ -d "$FM_WA_OUTBOX" ]; then
    find "$FM_WA_OUTBOX" -maxdepth 1 -name '*.json' -type f -mtime "+$OUTBOX_TTL_DAYS" \
      -exec rm -f -- {} + 2>/dev/null || true
  fi
  if [ -d "$FM_WA_SENT" ]; then
    find "$FM_WA_SENT" -maxdepth 1 -name '*.sent' -type f -mmin "+$SENT_TTL_MINUTES" \
      -exec rm -f -- {} + 2>/dev/null || true
  fi
  # A standing dry-run home records a reply per send and never reads most of
  # them back, so the outbox is the fourth growth surface and is bounded here
  # with the rest rather than being the one the janitor skips.
}

# The beat is the listener's proof that its connection is up, so its age is how
# long the channel has been down. A listener that has never connected writes no
# beat at all, which is the same fault seen from the start rather than from a
# working connection, so the pid file's own age stands in for it.
listener_down_age() {
  if [ -f "$LISTENER_BEAT" ]; then
    fm_wa_age_of "$LISTENER_BEAT"
  else
    fm_wa_age_of "$FM_WA_PIDFILE"
  fi
}

# Keep the one long-lived connection up without ever blocking this check: the
# start is a detached background spawn and its outcome is reported next cycle.
# A pid alone is not health, so a live listener is still judged by the state it
# reports and by its beat.
ensure_listener() {
  local state fails
  state=$(listener_state)
  if fm_wa_listener_pid >/dev/null 2>&1; then
    if [ "$(listener_down_age)" -ge "$STALL_INTERVAL" ]; then
      if [ -f "$LISTENER_BEAT" ]; then
        emit_listener_error "WhatsApp listener is running but its connection is down; see state/wa-listener.log"
      else
        emit_listener_error "WhatsApp listener is running but its connection has never come up; see state/wa-listener.log"
      fi
      return 1
    fi
    return 0
  fi
  if [ "$state" = "logged-out" ]; then
    emit_listener_error "WhatsApp listener was logged out; re-pair with bin/fm-wa-listen.sh unpair then pair"
    return 1
  fi
  if ! fm_wa_paired; then
    emit_listener_error "WhatsApp listener is not paired; run bin/fm-wa-listen.sh pair"
    return 1
  fi
  fails=$(restart_failures)
  if [ "$fails" -ge "$RESTART_FAIL_LIMIT" ] \
    && [ "$(fm_wa_age_of "$RESTART_FAILS")" -lt "$LATCH_RETRY_INTERVAL" ]; then
    emit_listener_error "WhatsApp listener keeps exiting after restart; see state/wa-listener.log, then run bin/fm-wa-listen.sh start"
    return 1
  fi
  if [ "$(fm_wa_age_of "$RESTART_MARKER")" -lt "$RESTART_INTERVAL" ]; then
    return 1
  fi
  if ! spawn_listener; then
    emit_listener_error "WhatsApp listener cannot be restarted: this host has neither setsid nor perl to detach it"
    return 1
  fi
  : | fm_wa_publish_stdin "$FM_WA_STATE" "wa-listener.restart" 2>/dev/null || true
  printf '%s\n' "$(( fails + 1 ))" \
    | fm_wa_publish_stdin "$FM_WA_STATE" "wa-listener.restarts" 2>/dev/null || true
  return 1
}

prune_state

if ensure_listener; then
  rm -f -- "$LISTENER_ERROR" 2>/dev/null || true
  if [ "$(fm_wa_age_of "$RESTART_MARKER")" -ge "$STABLE_INTERVAL" ]; then
    rm -f -- "$RESTART_FAILS" 2>/dev/null || true
  fi
fi

# A fault line and an inbox line mean different things to wa-respond, and the
# watcher would fold both into one wake, so a cycle that reported a fault stops.
[ -z "$EMITTED" ] || exit 0

[ -d "$FM_WA_INBOX" ] || exit 0

# Sorted so the digest depends on the pending set, not on readdir order. The
# named id is just the first in that order - WhatsApp ids are not chronological,
# so the wake line names one for traceability and the skill drains them all.
# `find -printf` is a GNU extension, so the basename is taken with sed instead.
FOUND=$(find "$FM_WA_INBOX" -maxdepth 1 -name '*.json' -type f 2>/dev/null \
  | sed 's#.*/##' | LC_ALL=C sort) || exit 0

# An entry whose stem cannot be used as an id is dropped from the set rather
# than aborting the announcement: total silence is the one outcome this channel
# exists to prevent, and the messages behind it are real. The listener's own id
# check keeps this unreachable through the normal path.
PENDING=
UNUSABLE=
while IFS= read -r entry; do
  [ -n "$entry" ] || continue
  if fm_wa_id_safe "${entry%.json}"; then
    PENDING=${PENDING}${entry}$'\n'
  else
    UNUSABLE=1
  fi
done <<EOF
$FOUND
EOF
PENDING=${PENDING%$'\n'}

if [ -z "$PENDING" ]; then
  if [ -n "$UNUSABLE" ]; then
    emit_poll_error "inbox holds an unusable message id"
  else
    rm -f -- "$FM_WA_ERROR" "$FM_WA_OFFERED" 2>/dev/null
  fi
  exit 0
fi

COUNT=$(printf '%s\n' "$PENDING" | wc -l | tr -d ' ')
FIRST=$(printf '%s\n' "$PENDING" | head -n 1)
FIRST=${FIRST%.json}

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
