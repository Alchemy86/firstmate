#!/usr/bin/env bash
# Post a fleet update to the captain's Discord. OUTBOUND ONLY.
#
#   fm-dc-send.sh --kind <kind> --title 'T' [options]     post a rich embed
#   fm-dc-send.sh --kind <kind> --plain 'text'            post plain text
#   fm-dc-send.sh --kind gallery --file <path> ['caption'] post an artefact
#
# Options:
#   --kind <k>        required; sets the colour, the emoji and the channel.
#                     Run --list-kinds for the set. There is no `progress`
#                     kind and that is deliberate - see fm-dc-embed.py.
#   --title 'T'       embed title; defaults to the kind's own label.
#   --text 'T'        embed body (or the message, with --plain).
#   --url U           makes the title clickable - use it for the PR link.
#   --field 'k=v'     repeatable; short values render side by side.
#   --project P       footer, so a glance says which project this is.
#   --file <path>     attach an image or video; renders inline in the embed.
#   --channel <c>     override the kind's default channel (name or id).
#   --thread <key>    group repeat reports for one work item under one thread.
#                     Opt-in: without it nothing threads and the common
#                     one-shot case is untouched.
#   --if-configured   exit 0 silently when Discord is not configured.
#   --list-kinds      print the kinds and exit.
#
# Prints the created message id on success, so a caller can cite it.
#
# INERTNESS, THE TWO CASES. Nothing in firstmate calls this script
# automatically - no watcher shim, no cadence file, no Stop hook, no bootstrap
# step - so an unconfigured home is byte-for-byte unchanged with nothing
# needing to be gated off. A DIRECT call with no config still fails loudly and
# non-zero, because a caller that explicitly asked to post deserves to know it
# did not; --if-configured is the silent form for any future automatic path.
# See docs/discord.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-dc-lib.sh
. "$SCRIPT_DIR/fm-dc-lib.sh"

if [ "${1:-}" = "--list-kinds" ]; then
  python3 "$SCRIPT_DIR/fm-dc-embed.py" --print-kinds
  exit 0
fi

fm_dc_guard_crew

KIND=""; TITLE=""; TEXT=""; URL=""; PROJECT=""; FILE=""; CHANNEL=""; THREAD=""
PLAIN=""; IFCONF=""; FIELDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --kind)     KIND=${2:?--kind needs a value}; shift 2 ;;
    --title)    TITLE=${2:?--title needs a value}; shift 2 ;;
    --text)     TEXT=${2:?--text needs a value}; shift 2 ;;
    --url)      URL=${2:?--url needs a value}; shift 2 ;;
    --field)    FIELDS+=(--field "${2:?--field needs name=value}"); shift 2 ;;
    --project)  PROJECT=${2:?--project needs a value}; shift 2 ;;
    --file)     FILE=${2:?--file needs a path}; shift 2 ;;
    --channel)  CHANNEL=${2:?--channel needs a value}; shift 2 ;;
    --thread)   THREAD=${2:?--thread needs a key}; shift 2 ;;
    --plain)    PLAIN=1; shift
                # `--plain 'text'` reads naturally, so accept the text either
                # as the next bare word or from --text.
                if [ $# -gt 0 ]; then case "$1" in --*) : ;; *) TEXT=$1; shift ;; esac; fi ;;
    --if-configured) IFCONF=1; shift ;;
    -h|--help)  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)
      # A bare trailing word after --file is its caption.
      if [ -n "$FILE" ] && [ -z "$TEXT" ]; then TEXT=$1; shift
      else echo "fm-dc-send: unknown argument '$1'" >&2; exit 2; fi ;;
  esac
done

[ -n "$KIND" ] || { echo "fm-dc-send: --kind is required (--list-kinds to see them)" >&2; exit 2; }

if [ -n "$IFCONF" ]; then
  fm_dc_load --if-configured; rc=$?
  [ "$rc" -eq 2 ] && exit 0
  [ "$rc" -eq 0 ] || exit 1
else
  fm_dc_load || exit 1
fi

# Resolve the channel: an explicit override, else the kind's own home.
if [ -z "$CHANNEL" ]; then
  CHANNEL=$(python3 "$SCRIPT_DIR/fm-dc-embed.py" --print-channel "$KIND") || exit 2
fi
CH_ID=$(fm_dc_channel "$CHANNEL") || exit 1

# ---- attachment sizing -------------------------------------------------
# Refused BEFORE the upload, naming the size and the way out. Discord rejects
# an oversize attachment after the whole payload has gone up the wire, which
# on a slow link is a long wait for a failure that was knowable up front.
ATTACH_NAME=""
if [ -n "$FILE" ]; then
  [ -f "$FILE" ] || { echo "fm-dc-send: no such file: $FILE" >&2; exit 1; }
  if [ "$(uname)" = Darwin ]; then sz=$(stat -f %z "$FILE" 2>/dev/null)
  else sz=$(stat -c %s "$FILE" 2>/dev/null); fi
  case "$sz" in
    ''|*[!0-9]*)
      echo "fm-dc-send: cannot read the size of $FILE; refusing to guess how to upload it" >&2
      exit 1 ;;
  esac
  if [ "$sz" -gt "$FM_DC_MAX_UPLOAD" ]; then
    echo "fm-dc-send: $FILE is $((sz/1048576))MB, over this server's $((FM_DC_MAX_UPLOAD/1048576))MB attachment limit." >&2
    echo "  A film usually needs a mobile cut to fit - re-encode at 30fps and 720px wide" >&2
    echo "  and send that; the 60fps original is for local viewing." >&2
    echo "  (Boosting the server to level 2 raises the limit to 50MB.)" >&2
    exit 1
  fi
  ATTACH_NAME=$(basename "$FILE")
fi

# ---- thread routing ----------------------------------------------------
# Opt-in only. A work item that reports several times collapses into one
# thread instead of spraying the channel; the cache is what makes the second
# report find the first one's thread.
TARGET_CH=$CH_ID
if [ -n "$THREAD" ]; then
  tdir="$STATE/discord-threads"
  (umask 077; mkdir -p "$tdir") 2>/dev/null
  tkey=$(printf '%s' "$CH_ID:$THREAD" | tr -c 'A-Za-z0-9_.-' '_')
  tfile="$tdir/$tkey"
  if [ -f "$tfile" ] && [ -s "$tfile" ]; then
    TARGET_CH=$(cat "$tfile")
  else
    tresp=$(fm_dc_api POST "/channels/$CH_ID/threads" \
      -H 'Content-Type: application/json' \
      --data-binary @- <<JSON
{"name": $(python3 -c 'import json,sys; print(json.dumps(sys.argv[1][:100]))' "$THREAD"), "type": 11, "auto_archive_duration": 10080}
JSON
    )
    printf '%s' "$tresp" | fm_dc_check || { echo "fm-dc-send: could not open thread '$THREAD'" >&2; exit 1; }
    tid=$(printf '%s' "$tresp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
    if [ -n "$tid" ]; then (umask 077; printf '%s' "$tid" > "$tfile"); TARGET_CH=$tid; fi
  fi
fi

# ---- build and post ----------------------------------------------------
EMBED_ARGS=(--kind "$KIND")
[ -n "$TITLE" ]   && EMBED_ARGS+=(--title "$TITLE")
[ -n "$TEXT" ]    && EMBED_ARGS+=(--text "$TEXT")
[ -n "$URL" ]     && EMBED_ARGS+=(--url "$URL")
[ -n "$PROJECT" ] && EMBED_ARGS+=(--project "$PROJECT")
[ -n "$PLAIN" ]   && EMBED_ARGS+=(--plain)
[ ${#FIELDS[@]} -gt 0 ] && EMBED_ARGS+=("${FIELDS[@]}")
# Every upload is declared to the payload builder, which owns whether it also
# becomes the embed's inline image - one owner for that call, next to the kind
# table, rather than an extension list repeated in two languages.
[ -n "$ATTACH_NAME" ] && EMBED_ARGS+=(--attach-name "$ATTACH_NAME")

PAYLOAD=$(python3 "$SCRIPT_DIR/fm-dc-embed.py" "${EMBED_ARGS[@]}") || exit 2

if [ -n "$FILE" ]; then
  # Scale the bound with the payload: a flat timeout is either too short for a
  # 10MB film on a slow link or pointlessly long for a screenshot.
  tmo=$(( 120 + sz / 20000 )); [ "$tmo" -gt 900 ] && tmo=900
  # THE PAYLOAD GOES THROUGH A FILE, NOT AN ARGUMENT, AND MUST STAY THAT WAY.
  # curl's -F parses `;` in a field value as the start of a parameter
  # (`;type=`, `;filename=`), so a payload containing one is silently cut in
  # half and Discord answers "Invalid Form Body" (50035) naming no field. A
  # semicolon in captain-facing prose is completely ordinary - the caption
  # that first hit this was "colour tells you good or bad; the channel tells
  # you whether you must act" - so this is a routine input, not an edge case.
  # `-F name=<file` reads the value from the file with no such parsing.
  pf=$(mktemp "${TMPDIR:-/tmp}/fm-dc-payload.XXXXXX") || exit 1
  trap 'rm -f "$pf"' EXIT INT TERM
  (umask 077; printf '%s' "$PAYLOAD" > "$pf")
  RESP=$(fm_run_timed "$tmo" curl -sS --max-time "$tmo" \
    -X POST "$FM_DC_API_BASE/channels/$TARGET_CH/messages" \
    -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    -H "User-Agent: $FM_DC_UA" \
    -F "payload_json=<$pf;type=application/json" \
    -F "files[0]=@$FILE;filename=$ATTACH_NAME")
  if [ -z "$RESP" ]; then
    echo "fm-dc-send: no reply after ${tmo}s uploading $((sz/1048576))MB - upload timed out" >&2
    exit 1
  fi
else
  RESP=$(printf '%s' "$PAYLOAD" | fm_dc_api POST "/channels/$TARGET_CH/messages" \
    -H 'Content-Type: application/json' --data-binary @-)
fi

printf '%s' "$RESP" | fm_dc_check || exit 1
printf '%s' "$RESP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
