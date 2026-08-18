#!/usr/bin/env bash
# Send one WhatsApp reply to the captain from this home.
#
# Usage:
#   fm-wa-send.sh --text-file <path> [--to <number>]
#   fm-wa-send.sh --text '<message>' [--to <number>]
#
# Outbound rides mudslide's existing linked device, completely untouched by the
# inbound listener: the listener owns a SEPARATE credential folder precisely so
# arming it can never break sending. This script adds a dry-run and an echo
# marker on top of `mudslide send`; it changes nothing about how mudslide works.
#
# Message text is read from a file and handed to mudslide as a single argument
# vector element. It is never interpolated into a command string, never passed
# through eval or sh -c, and never used to build a path, so a reply quoting the
# captain's own words cannot become execution.
#
# FM_WA_DRY_RUN=1 (or FM_WA_DRY_RUN in config/whatsapp.env) records what WOULD
# be sent to state/wa-outbox/ and sends nothing, so the whole
# poll -> wake -> compose -> would-send loop can be exercised without live
# traffic.
#
# Every send also records a digest of its normalized text under state/wa-sent/.
# The listener consumes that marker if the same text arrives back, which is the
# second line of defence (behind the sender-device filter) against firstmate
# reading its own replies as new captain instructions. A dry run records the
# same marker so the loop behaves identically either way.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

# shellcheck source=bin/fm-wa-lib.sh
. "$SCRIPT_DIR/fm-wa-lib.sh"

usage() {
  echo "usage: fm-wa-send.sh --text-file <path> [--to <number>]" >&2
  echo "       fm-wa-send.sh --text '<message>' [--to <number>]" >&2
}

TEXT_FILE=
TEXT=
TO=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --text-file) TEXT_FILE=${2-}; shift 2 || { usage; exit 2; } ;;
    --text) TEXT=${2-}; shift 2 || { usage; exit 2; } ;;
    --to) TO=${2-}; shift 2 || { usage; exit 2; } ;;
    -h|--help) usage; exit 0 ;;
    *) usage; exit 2 ;;
  esac
done

if ! fm_wa_load_config; then
  echo "error: WhatsApp channel is off; no FM_WA_CAPTAIN in ${FM_WA_CONFIG_FILE:-config/whatsapp.env}" >&2
  exit 1
fi

if [ -n "$TEXT_FILE" ]; then
  [ -f "$TEXT_FILE" ] || { echo "error: message file is unavailable" >&2; exit 1; }
  TEXT=$(cat -- "$TEXT_FILE") || { echo "error: cannot read the message file" >&2; exit 1; }
fi
[ -n "$TEXT" ] || { usage; exit 2; }

TO=${TO:-$FM_WA_CAPTAIN}
TO=$(printf '%s' "$TO" | tr -cd '0-9')
[ -n "$TO" ] || { echo "error: recipient must be a number in international form" >&2; exit 1; }

# Normalized digest, matching what the listener computes on inbound text.
# The marker is short-lived by contract: the listener ignores and prunes any
# digest older than its echo window, so a reply the captain never echoes back
# cannot sit there forever waiting to swallow those exact words from him.
NORMALIZED=$(printf '%s' "$TEXT" | fm_wa_normalize_text)
DIGEST=$(printf '%s' "$NORMALIZED" | fm_wa_sha256) || DIGEST=
MARKER=
if [ -n "$DIGEST" ] && fm_wa_id_safe "$DIGEST"; then
  if : | fm_wa_publish_stdin "$FM_WA_SENT" "$DIGEST.sent" 2>/dev/null; then
    MARKER="$FM_WA_SENT/$DIGEST.sent"
  fi
fi

if [ -n "$FM_WA_DRY_RUN" ]; then
  STAMP=$(date +%s)
  BASE="$STAMP-$$.json"
  # Built with the library's own encoder rather than jq: the record is read back
  # as fm-wa-outbox-v1 JSON, so a host without jq must still produce valid JSON
  # instead of a .json file holding raw text.
  JSON_TEXT=$(printf '%s' "$TEXT" | fm_wa_json_string) || JSON_TEXT=
  if [ -n "$JSON_TEXT" ] && printf '{"schema":"fm-wa-outbox-v1","dry_run":true,"to":"%s","digest":"%s","text":%s}\n' \
    "$TO" "${DIGEST:-}" "$JSON_TEXT" \
    | fm_wa_publish_stdin "$FM_WA_OUTBOX" "$BASE"; then
    echo "dry-run: recorded state/wa-outbox/$BASE (nothing sent)"
    exit 0
  fi
  # Nothing was ever going to be sent, so the echo marker has nothing to guard
  # against and must not sit there swallowing those words from the captain.
  [ -z "$MARKER" ] || rm -f -- "$MARKER" 2>/dev/null || true
  echo "error: cannot record the dry-run reply" >&2
  exit 1
fi

command -v mudslide >/dev/null 2>&1 || { echo "error: mudslide is not installed" >&2; exit 1; }

# Single argv element: the shell never re-parses the captain's words.
if mudslide send "$TO" "$TEXT" >/dev/null 2>&1; then
  echo "sent to $TO"
else
  # Nothing went out, so nothing can echo back: drop the marker rather than
  # leaving it to suppress the captain saying those same words himself.
  [ -z "$MARKER" ] || rm -f -- "$MARKER" 2>/dev/null || true
  echo "error: mudslide could not send the reply" >&2
  exit 1
fi
