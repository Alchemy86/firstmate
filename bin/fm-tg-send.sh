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
#
# A crew worktree is identified by git's own linked-worktree shape
# (fm_dir_is_child_worktree, bin/fm-primary-scope-lib.sh), not by where it
# happens to live: an earlier version only recognised $HOME/.treehouse/*, so
# every task worktree created anywhere else walked straight past it. The
# literal treehouse path is still refused on top of that, because a leased
# directory is a crew location whether or not git reports it as a worktree.
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# fm_run_timed: the repo's single owner of bounded execution. A bare `timeout`
# does not exist on macOS, where every send would have failed to run curl at all
# and reported the misleading "unparseable reply" of an empty response.
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
_fmtg_refuse_crew() {
  echo "fm-tg-send: REFUSED - crewmates must not contact the captain." >&2
  echo "  You are in a crew worktree. Report through your status file:" >&2
  echo "    echo 'done: <one line>' >> $STATE/<your-task-id>.status" >&2
  echo "  firstmate relays everything to the captain." >&2
  exit 3
}
if [ -n "${FM_TG_FORCE:-}" ]; then
  :
else
  _fmtg_cwd=$(pwd -P 2>/dev/null || echo "")
  case "$_fmtg_cwd" in
    "$HOME"/.treehouse/*) _fmtg_refuse_crew ;;
  esac
  if [ -n "$_fmtg_cwd" ] && fm_dir_is_child_worktree "$_fmtg_cwd"; then
    _fmtg_refuse_crew
  fi
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

# Portable file size in bytes; macOS stat has no -c. A silent 0 here would send
# an oversized image through sendPhoto, skip the 50MB refusal, and flatten the
# size-scaled upload timeout, so an unreadable size is loud rather than 0.
file_size() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

# A real reply: stamp it, and retire the inbox messages it answers. FM_TG_ACK=1
# (the instant "..." acknowledgement) skips this entirely - it is not a reply.
# An unsurfaced retirement is the one outcome that can cost the captain an
# answer, and bin/fm-tg-archive.py records each one in state/.tg-archive.log
# itself, so this call does not need to capture its stdout - doing so logged
# every retirement twice and appended a no-op "archived 0" line per reply.
mark_sent() {
  if [ -z "${FM_TG_ACK:-}" ]; then
    touch "$STATE/.tg-last-sent"
    python3 "$SCRIPT_DIR/fm-tg-archive.py" "$STATE/tg-inbox" "$STATE/tg-processed" \
      >/dev/null 2>&1 || true
  fi
}

if [ "${1:-}" = "--file" ]; then
  f=${2:?path required}; cap=${3:-}
  sz=$(file_size "$f")
  case "$sz" in
    ''|*[!0-9]*)
      echo "telegram: cannot read the size of $f; refusing to guess how to upload it" >&2
      exit 1 ;;
  esac
  case "${f##*.}" in
    png|jpg|jpeg|webp)
      # Telegram's sendPhoto re-encodes and rejects large or very large-
      # dimensioned images (width+height must be under 10000). A 13696x14048
      # atlas failed outright and a 3MB scaled copy timed out, both reported
      # only as "unparseable reply". Anything over 1MB goes as a DOCUMENT,
      # which preserves the original bytes and has a far higher ceiling.
      if [ "$sz" -gt 1000000 ]; then
        meth=sendDocument; field=document
      else
        meth=sendPhoto; field=photo
      fi ;;
    mp4|mov|m4v|webm)      meth=sendVideo;    field=video ;;
    gif)                   meth=sendAnimation; field=animation ;;
    mp3|ogg|wav|m4a)       meth=sendAudio;    field=audio ;;
    *)                     meth=sendDocument; field=document ;;
  esac
  if [ "$sz" -gt 49000000 ]; then
    echo "file is $((sz/1048576))MB, over the 50MB Telegram limit" >&2; exit 1
  fi
  # Scale the timeout with the payload: a flat 180s was not enough for a few
  # MB on a slow connection, and the failure surfaced as an empty,
  # "unparseable reply" rather than anything actionable.
  tmo=$(( 180 + sz / 20000 ))
  [ "$tmo" -gt 900 ] && tmo=900
  resp=$(fm_run_timed "$tmo" curl -s --max-time "$tmo" -X POST "$API/$meth" \
      -F "chat_id=$TG_CHAT_ID" -F "$field=@$f" -F "caption=${cap:0:1000}")
  if [ -z "$resp" ]; then
    echo "telegram: no reply after ${tmo}s uploading $((sz/1048576))MB via $meth - upload timed out" >&2
    exit 1
  fi
  printf '%s' "$resp" | check || exit 1
  mark_sent
  echo sent
  exit 0
fi

TEXT=${1:?text required}
# Split into <=LIMIT chunks on the nicest boundary available.
# `mapfile -d ''` would be shorter but needs bash >= 4.4; macOS still ships
# /bin/bash 3.2, where it does not exist at all and the split silently
# produced no parts. Read the NUL-delimited chunks explicitly instead, and
# count them as they arrive rather than through ${#PARTS[@]}, which is itself
# an unbound-variable error for an empty array on those older shells.
PARTS=()
n=0
while IFS= read -r -d '' _part; do
  PARTS[n]=$_part
  n=$((n + 1))
done < <(FM_TG_TEXT="$TEXT" python3 - "$LIMIT" <<'PY'
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
if [ "$n" -eq 0 ]; then
  echo "telegram: could not split the message text into any sendable part" >&2
  exit 1
fi
# Retry a failed part automatically. Transient blips used to print "FAILED
# mid-send" and rely on firstmate NOTICING and re-running the whole command by
# hand - exactly the remembering-game the captain asked to be engineered out
# (2026-08-22). Three attempts with a short backoff; only a genuine, repeated
# failure is reported. A Telegram REJECTION (a bad request, not a network
# blip - "ok":false in the reply) is never retried, since retrying it cannot
# help.
send_part() {
  local body=$1 attempt=1 resp curl_rc rc
  while [ "$attempt" -le 3 ]; do
    resp=$(fm_run_timed 60 curl -s --max-time 60 -X POST "$API/sendMessage" \
        -d "chat_id=$TG_CHAT_ID" --data-urlencode "text=$body")
    curl_rc=$?
    if [ -n "$resp" ]; then
      printf '%s' "$resp" | check && return 0
      rc=$?
      case "$resp" in
        *'"ok":false'*) return "$rc" ;;   # rejected, not transient
      esac
    fi
    if [ "$attempt" -lt 3 ]; then
      # Distinguished only for the retry-notice wording (docs/telegram.md "No
      # message is answered twice"): a nonzero curl exit is a definite
      # non-send (connection refused, DNS failure - curl never reached
      # Telegram), while an empty reply from a curl that itself exited 0 is
      # ambiguous - Telegram may have already accepted and answered the send
      # too slowly for --max-time to see the reply. Both retry the same way.
      if [ "$curl_rc" -ne 0 ]; then
        echo "telegram: attempt $attempt failed (curl exit $curl_rc, definite non-send), retrying" >&2
      else
        echo "telegram: attempt $attempt failed (empty reply, ambiguous - may have already sent), retrying" >&2
      fi
      sleep 2
    fi
    attempt=$((attempt + 1))
  done
  return 1
}
i=0
while [ "$i" -lt "$n" ]; do
  p=${PARTS[i]}
  i=$((i + 1))
  [ -n "$p" ] || continue
  send_part "$p" || { echo "FAILED mid-send after 3 attempts" >&2; exit 1; }
done
mark_sent
echo "sent ($n part(s))"
