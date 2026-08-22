#!/usr/bin/env bash
# Send a message to the captain on Telegram.
#   fm-tg-send.sh 'text'                      send text (auto-split if long)
#   fm-tg-send.sh --file <path> ['caption']   send a photo/video/document
#
# TWO BUGS THIS FIXES, both found 2026-08-21 after the captain had to chase
# repeatedly for answers he never received:
#
#   1. SILENT REJECTION. The old version piped curl to /dev/null and echoed
#      "sent" on curl's exit status. curl exits 0 whenever the HTTP request
#      succeeds, INCLUDING when Telegram replies {"ok":false,...}. So a
#      rejected message reported success. Now the response is parsed and a
#      non-ok reply is loud and exits non-zero.
#
#   2. THE 4096 LIMIT. Telegram's sendMessage caps text at 4096 characters and
#      returns "Bad Request: message is too long". Most detailed firstmate
#      answers exceed that, so they were all silently dropped. Text is now
#      split on paragraph, then line, then word boundaries and sent in order.
#
# Completely inert with no ~/.config/fm-telegram.env or missing TG_TOKEN /
# TG_CHAT_ID: see docs/telegram.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# ---- FIRSTMATE-ONLY GUARD (added 2026-08-22) ----------------------------
# Crewmates must NEVER address the captain; all crew communication flows
# through firstmate. Several briefs wrongly told crews to call this script
# directly and the captain received messages from crewmates. This refuses
# any call made from inside a crew worktree, so a stray brief cannot do it
# again. Crews report via their state/<id>.status file instead. The Stop
# hooks that drive this script are also now registered project-scoped
# (docs/telegram.md) rather than in the user's global settings, which fixes
# the same class of problem at the hook layer; this guard stays as defense
# in depth for direct/manual invocation.
if [ -n "${FM_TG_FORCE:-}" ]; then
  :
else
  _fmtg_cwd=$(pwd -P 2>/dev/null || echo "")
  case "$_fmtg_cwd" in
    "$HOME"/.treehouse/*)
      echo "fm-tg-send: REFUSED - crewmates must not contact the captain." >&2
      echo "  You are in a crew worktree. Report through your status file:" >&2
      echo "    echo 'done: <one line>' >> $STATE/<your-task-id>.status" >&2
      echo "  firstmate relays everything to the captain." >&2
      exit 3
      ;;
  esac
fi
# ------------------------------------------------------------------------

ENVF="${FM_TG_ENV_OVERRIDE:-$HOME/.config/fm-telegram.env}"
[ -f "$ENVF" ] || { echo "no telegram config" >&2; exit 1; }
set -a
# shellcheck source=/dev/null # ENVF is a resolved runtime path, not a repo file
. "$ENVF"
set +a
[ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ] || { echo "telegram not configured" >&2; exit 1; }
API="https://api.telegram.org/bot$TG_TOKEN"
LIMIT=${FM_TG_LIMIT:-3900}   # under 4096, leaving room for a part marker

# Parse a Telegram reply: silent on ok, loud and non-zero otherwise.
check() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    sys.stderr.write("telegram: unparseable reply: %s\n" % raw[:200]); sys.exit(1)
if not d.get("ok"):
    sys.stderr.write("telegram REJECTED: %s (%s)\n"
                     % (d.get("description"), d.get("error_code")))
    sys.exit(1)
'
}

# A real reply: stamp it, and retire the inbox messages it answers. FM_TG_ACK=1
# (the instant "..." acknowledgement) skips this entirely - it is not a reply.
mark_sent() {
  if [ -z "${FM_TG_ACK:-}" ]; then
    touch "$STATE/.tg-last-sent"
    python3 "$SCRIPT_DIR/fm-tg-archive.py" "$STATE/tg-inbox" "$STATE/tg-processed" >/dev/null 2>&1 || true
  fi
}

if [ "${1:-}" = "--file" ]; then
  f=${2:?path required}; cap=${3:-}
  sz0=$(stat -c %s "$f" 2>/dev/null || echo 0)
  case "${f##*.}" in
    png|jpg|jpeg|webp)
      # Telegram's sendPhoto re-encodes and rejects large or very large-
      # dimensioned images (width+height must be under 10000). A 13696x14048
      # atlas failed outright and a 3MB scaled copy timed out, both reported
      # only as "unparseable reply". Anything over 1MB goes as a DOCUMENT,
      # which preserves the original bytes and has a far higher ceiling.
      if [ "$sz0" -gt 1000000 ]; then
        meth=sendDocument; field=document
      else
        meth=sendPhoto; field=photo
      fi ;;
    mp4|mov|m4v|webm)      meth=sendVideo;    field=video ;;
    gif)                   meth=sendAnimation; field=animation ;;
    mp3|ogg|wav|m4a)       meth=sendAudio;    field=audio ;;
    *)                     meth=sendDocument; field=document ;;
  esac
  sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
  if [ "$sz" -gt 49000000 ]; then
    echo "file is $((sz/1048576))MB, over the 50MB Telegram limit" >&2; exit 1
  fi
  # Scale the timeout with the payload: a flat 180s was not enough for a few
  # MB on a slow connection, and the failure surfaced as an empty,
  # "unparseable reply" rather than anything actionable.
  tmo=$(( 180 + sz0 / 20000 ))
  [ "$tmo" -gt 900 ] && tmo=900
  resp=$(timeout "$tmo" curl -s --max-time "$tmo" -X POST "$API/$meth" \
      -F "chat_id=$TG_CHAT_ID" -F "$field=@$f" -F "caption=${cap:0:1000}")
  if [ -z "$resp" ]; then
    echo "telegram: no reply after ${tmo}s uploading $((sz0/1048576))MB via $meth - upload timed out" >&2
    exit 1
  fi
  printf '%s' "$resp" | check || exit 1
  mark_sent
  echo sent
  exit 0
fi

TEXT=${1:?text required}
# Split into <=LIMIT chunks on the nicest boundary available.
mapfile -d '' -t PARTS < <(FM_TG_TEXT="$TEXT" python3 - "$LIMIT" <<'PY'
import os, sys
limit = int(sys.argv[1])
text = os.environ["FM_TG_TEXT"]
chunks, cur = [], ""
for para in text.split("\n\n"):
    block = para if not cur else cur + "\n\n" + para
    if len(block) <= limit:
        cur = block; continue
    if cur: chunks.append(cur); cur = ""
    while len(para) > limit:
        cut = para.rfind("\n", 0, limit)
        if cut < limit // 2: cut = para.rfind(" ", 0, limit)
        if cut < limit // 2: cut = limit
        chunks.append(para[:cut]); para = para[cut:].lstrip()
    cur = para
if cur: chunks.append(cur)
for i, c in enumerate(chunks):
    tag = "" if len(chunks) == 1 else "(%d/%d)\n" % (i + 1, len(chunks))
    sys.stdout.write(tag + c + "\0")
PY
)
n=${#PARTS[@]}
for p in "${PARTS[@]}"; do
  [ -n "$p" ] || continue
  timeout 60 curl -s -X POST "$API/sendMessage" -d "chat_id=$TG_CHAT_ID" \
      --data-urlencode "text=$p" | check || { echo "FAILED mid-send" >&2; exit 1; }
done
mark_sent
echo "sent ($n part(s))"
