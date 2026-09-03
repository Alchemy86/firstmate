#!/usr/bin/env bash
# Converge the captain's Discord server onto a channel layout, idempotently,
# and generate the channel map bin/fm-dc-send.sh routes through.
#
#   fm-dc-setup.sh                     ensure the fleet channels exist
#   fm-dc-setup.sh --dry-run           report what it would change, change nothing
#   fm-dc-setup.sh --layout <file>     converge onto a wider layout (JSON)
#   fm-dc-setup.sh --map-only          regenerate config/discord-channels.env only
#   fm-dc-setup.sh --guild <id>        the guild to converge, first run only
#   fm-dc-setup.sh --enable-community  turn the server into a Community server
#   fm-dc-setup.sh --badges <file>     create or update the progression roles
#
# Idempotent by identity, not by bookkeeping: it lists the guild's real
# categories and channels and creates only what is genuinely missing, so a
# second run is a no-op and a half-finished first run completes cleanly. It
# never deletes, renames or reorders anything - removing a channel from the
# layout does NOT remove it from the server, because a destructive convergence
# is one bad layout file away from taking the captain's history with it.
#
# What it writes: config/discord-channels.env, holding DC_GUILD_ID, the
# measured DC_MAX_UPLOAD ceiling, and one DC_CHANNEL_<NAME> per resolved
# channel. That file is local and gitignored; it holds ids, never the token.
#
# Layout file format - see docs/examples/discord-layout.json:
#   {"categories": [{"name": "FLEET", "channels": [
#       {"name": "ready", "type": "text", "topic": "..."}]}]}
#
# Channel "type" is text (default), voice, announcement, or forum.
# ANNOUNCEMENT AND FORUM NEED THE GUILD TO BE A COMMUNITY SERVER. Discord
# rejects them otherwise, so this script checks the guild's own feature list
# first and names the missing prerequisite instead of forwarding an opaque API
# error. Enabling Community is a server-posture change (it adds a rules
# screen, sets discovery eligibility, and changes default notifications), so
# it is deliberately NOT done here - see docs/discord.md.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"

# shellcheck source=bin/fm-dc-lib.sh
. "$SCRIPT_DIR/fm-dc-lib.sh"

DRY=""; LAYOUT=""; MAP_ONLY=""; GUILD_ARG=""; ENABLE_COMMUNITY=""; BADGES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY=1; shift ;;
    --guild)    GUILD_ARG=${2:?--guild needs an id}; shift 2 ;;
    --enable-community) ENABLE_COMMUNITY=1; shift ;;
    --badges)   BADGES=${2:?--badges needs a file}; shift 2 ;;
    --layout)   LAYOUT=${2:?--layout needs a file}; shift 2 ;;
    --map-only) MAP_ONLY=1; shift ;;
    -h|--help)  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "fm-dc-setup: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

fm_dc_guard_crew
fm_dc_load || exit 1
# The guild id is an id, not a credential, so it lives in the generated map
# rather than in the credential file: --guild is needed once, and every later
# run reads it back from the map. That keeps discord.env credentials-only,
# which is the file most likely to be copied between machines by hand.
[ -n "$GUILD_ARG" ] && DC_GUILD_ID=$GUILD_ARG
[ -n "${DC_GUILD_ID:-}" ] || {
  echo "fm-dc-setup: no guild id yet. Pass it once with --guild <id>; later runs" >&2
  echo "  read it back from the generated map. See docs/discord.md." >&2
  exit 1
}

MAP="${FM_DC_CHANNELS_OVERRIDE:-$FM_HOME/config/discord-channels.env}"

# The fleet layout: the four channels the update pipeline routes to. Kept in
# step with fm-dc-embed.py's kind table, which is the single owner of which
# kind lands where.
DEFAULT_LAYOUT=$(cat <<'JSON'
{"categories": [{"name": "FLEET", "channels": [
  {"name": "ready",   "topic": "Needs the captain: work ready for review, a decision, a credential. Read this one."},
  {"name": "broken",  "topic": "Failures only: a red pipeline, a failed payment run, a wedged job."},
  {"name": "landed",  "topic": "Merged, done, and milestones. Catch up here when you feel like it."},
  {"name": "gallery", "topic": "Artefacts: films, training montages, screenshots."}
]}]}
JSON
)

if [ -n "$LAYOUT" ]; then
  [ -f "$LAYOUT" ] || { echo "fm-dc-setup: no such layout file: $LAYOUT" >&2; exit 1; }
  SPEC=$(cat "$LAYOUT")
else
  SPEC=$DEFAULT_LAYOUT
fi
printf '%s' "$SPEC" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null || {
  echo "fm-dc-setup: the layout is not valid JSON" >&2; exit 1; }

# Live guild state, fetched once.
CHANS=$(fm_dc_api GET "/guilds/$DC_GUILD_ID/channels") || exit 1
printf '%s' "$CHANS" | fm_dc_check || exit 1
fm_dc_is_list "$CHANS" || {
  echo "fm-dc-setup: the guild channel list did not come back as a list; refusing to converge blind" >&2
  exit 1; }
GUILD=$(fm_dc_api GET "/guilds/$DC_GUILD_ID") || exit 1
printf '%s' "$GUILD" | fm_dc_check || exit 1

# Discord's attachment ceiling is a property of the guild's boost tier, so it
# is measured here rather than hardcoded at each call site: a boost silently
# raises it and a stale constant would keep refusing files that now fit.
TIER=$(printf '%s' "$GUILD" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("premium_tier",0))')
IS_COMMUNITY=$(printf '%s' "$GUILD" | python3 -c '
import json, sys
print("1" if "COMMUNITY" in (json.load(sys.stdin).get("features") or []) else "")')
case "$TIER" in
  2) UPLOAD=52428800 ;;
  3) UPLOAD=104857600 ;;
  *) UPLOAD=10485760 ;;
esac

# ---- Community enablement (explicit opt-in only) -----------------------
# NEVER implicit. Turning a server into a Community server is a posture
# change, not a channel: it adds a rules screen, sets discovery eligibility,
# raises the verification floor, and forces the explicit-content filter on.
# It therefore happens only when --enable-community is passed, and is a no-op
# when the server already has the feature.
#
# Discord's own prerequisites, all of which must be satisfied IN THE SAME
# PATCH as the feature itself, because it rejects a guild that would be left
# in an invalid state:
#   - verification_level at LOW or above
#   - explicit_content_filter scanning ALL_MEMBERS
#   - a rules channel and a moderator-updates channel, which must already exist
enable_community() {
  local rules_id updates_id body resp
  if [ -n "$IS_COMMUNITY" ]; then
    echo "community: already enabled"
    return 0
  fi
  rules_id=$(find_channel rules 0) || return 1
  updates_id=$(find_channel moderator-updates 0) || return 1
  if [ -z "$rules_id" ] || [ -z "$updates_id" ]; then
    echo "fm-dc-setup: enabling Community needs both #rules and #moderator-updates to exist first." >&2
    echo "  They are in docs/examples/discord-layout.json; run the layout, then re-run with --enable-community." >&2
    return 1
  fi
  if [ -n "$DRY" ]; then
    echo "would enable Community (rules=$rules_id, moderator-updates=$updates_id)"
    return 0
  fi
  body=$(FM_R="$rules_id" FM_U="$updates_id" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "features": ["COMMUNITY"],
    "rules_channel_id": os.environ["FM_R"],
    "public_updates_channel_id": os.environ["FM_U"],
    "verification_level": 1,
    "explicit_content_filter": 2,
    # A community server that notifies every member of every message is a
    # server people mute; mentions-only is the Discord community default.
    "default_message_notifications": 1,
}))')
  resp=$(printf '%s' "$body" | fm_dc_api PATCH "/guilds/$DC_GUILD_ID" \
    -H 'Content-Type: application/json' --data-binary @-)
  printf '%s' "$resp" | fm_dc_check || {
    echo "fm-dc-setup: Discord refused to enable Community; see docs/discord.md" >&2
    return 1; }
  printf '%s' "$resp" | python3 -c '
import json, sys
f = json.load(sys.stdin).get("features") or []
print("community: enabled" if "COMMUNITY" in f else "community: PATCH accepted but the feature is not set")
'
  IS_COMMUNITY=1
  return 0
}

# find_channel <name> <type> [parent_id] -> prints the id, empty if absent.
# Returns 2 when the channel list is UNREADABLE, which is a different answer
# from "absent" and must never be collapsed into it: treating an error body as
# an empty list is what created duplicates of an entire layout.
find_channel() {
  fm_dc_is_list "$CHANS" || return 2
  printf '%s' "$CHANS" | FM_N="$1" FM_T="$2" FM_P="${3:-}" python3 -c '
import json, os, sys
name, typ, parent = os.environ["FM_N"], int(os.environ["FM_T"]), os.environ.get("FM_P") or None
for c in json.load(sys.stdin):
    if c.get("name") == name and c.get("type") == typ:
        if parent and str(c.get("parent_id") or "") != parent:
            continue
        sys.stdout.write(str(c["id"])); break
'
}

create_channel() {
  local name=$1 typ=$2 parent=$3 topic=$4 body resp
  body=$(FM_N="$name" FM_T="$typ" FM_P="$parent" FM_TOP="$topic" python3 -c '
import json, os, sys
d = {"name": os.environ["FM_N"], "type": int(os.environ["FM_T"])}
if os.environ.get("FM_P"): d["parent_id"] = os.environ["FM_P"]
# A voice channel takes no topic; sending one is rejected outright.
if os.environ.get("FM_TOP") and d["type"] != 2: d["topic"] = os.environ["FM_TOP"][:1024]
sys.stdout.write(json.dumps(d))
')
  resp=$(printf '%s' "$body" | fm_dc_api POST "/guilds/$DC_GUILD_ID/channels" \
    -H 'Content-Type: application/json' --data-binary @-)
  printf '%s' "$resp" | fm_dc_check || return 1
  # Fold the new channel into the in-memory list rather than re-fetching it.
  # A GET per create is what tripped the rate limit in the first place, and
  # the created object is authoritative anyway.
  CHANS=$(FM_NEW="$resp" FM_CUR="$CHANS" python3 -c '
import json, os, sys
cur = json.loads(os.environ["FM_CUR"])
new = json.loads(os.environ["FM_NEW"])
if isinstance(cur, list) and isinstance(new, dict) and new.get("id"):
    cur.append(new)
sys.stdout.write(json.dumps(cur))
')
  printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

if [ -n "$ENABLE_COMMUNITY" ]; then
  enable_community || exit 1
fi

# ---- progression roles from the badge file -----------------------------
# The file owns name, colour and ladder order, and those are applied here for
# real. It does NOT own the XP threshold: the levelling bot keeps that in its
# own dashboard, so `level` is recorded intent that a human enters once. The
# doc says so plainly rather than letting the file look live when it is not.
apply_badges() {
  local file=$1 roles resp created=0 updated=0
  [ -f "$file" ] || { echo "fm-dc-setup: no such badge file: $file" >&2; return 1; }
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" 2>/dev/null \
    || { echo "fm-dc-setup: the badge file is not valid JSON" >&2; return 1; }

  roles=$(fm_dc_api GET "/guilds/$DC_GUILD_ID/roles") || return 1
  fm_dc_is_list "$roles" || {
    echo "fm-dc-setup: could not read the guild roles; refusing to create roles blind" >&2
    return 1; }

  local has_icons=""
  case "$(printf '%s' "$GUILD" | python3 -c '
import json, sys
print(",".join(json.load(sys.stdin).get("features") or []))')" in
    *ROLE_ICONS*) has_icons=1 ;;
  esac

  # Walk the ladder lowest-first so Discord positions come out in game order.
  while IFS=$'\t' read -r bname bcolour bicon; do
    [ -n "$bname" ] || continue
    local existing body
    existing=$(printf '%s' "$roles" | FM_N="$bname" python3 -c '
import json, os, sys
want = os.environ["FM_N"]
for r in json.load(sys.stdin):
    if r.get("name") == want:
        sys.stdout.write("%s %s" % (r["id"], r.get("color", 0))); break
')
    body=$(FM_N="$bname" FM_C="$bcolour" python3 -c '
import json, os, sys
sys.stdout.write(json.dumps({
    "name": os.environ["FM_N"],
    "color": int(os.environ["FM_C"].lstrip("#"), 16),
    # hoist groups holders together in the member list, which is what makes a
    # badge visible at all rather than hidden behind a name.
    "hoist": True,
    "mentionable": False,
    # A cosmetic rank must carry NO privileges. An empty permission set is the
    # whole point: the badge says what you did, not what you may do.
    "permissions": "0",
}))')
    if [ -n "$DRY" ]; then
      if [ -n "$existing" ]; then echo "would update role: $bname"
      else echo "would create role: $bname ($bcolour)"; fi
      continue
    fi
    if [ -n "$existing" ]; then
      local rid=${existing%% *}
      resp=$(printf '%s' "$body" | fm_dc_api PATCH "/guilds/$DC_GUILD_ID/roles/$rid" \
        -H 'Content-Type: application/json' --data-binary @-)
      printf '%s' "$resp" | fm_dc_check || return 1
      echo "role present, colour synced: $bname"
      updated=$((updated + 1))
    else
      resp=$(printf '%s' "$body" | fm_dc_api POST "/guilds/$DC_GUILD_ID/roles" \
        -H 'Content-Type: application/json' --data-binary @-)
      printf '%s' "$resp" | fm_dc_check || return 1
      echo "created role: $bname ($bcolour)"
      created=$((created + 1))
    fi
    if [ -n "$bicon" ] && [ -z "$has_icons" ]; then
      echo "  note: an icon is set for $bname but this server is not at Boost Level 2, so colours only" >&2
    fi
  done < <(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for b in d.get("badges", []):
    sys.stdout.write("%s\t%s\t%s\n" % (b["name"], b["colour"], b.get("icon", "")))
' "$file")
  [ -n "$DRY" ] && return 0
  echo "badges: $created created, $updated already present"
  if [ -z "$has_icons" ]; then
    echo "badges: role ICONS need Boost Level 2 (7 boosts); names and colours are live now"
  fi
  return 0
}

if [ -n "$BADGES" ]; then
  apply_badges "$BADGES" || exit 1
  [ -z "$LAYOUT" ] && [ -z "$ENABLE_COMMUNITY" ] && exit 0
fi

CREATED=0
MAP_LINES=""
ANNOUNCED=""
# Walk the spec: category first, then its channels beneath it.
# shellcheck disable=SC2016 # the %s templates in the heredoc'd Python are its own
while IFS=$'\t' read -r cat chname chtype topic; do
  # An empty category is not a malformed row: a top-level "channels" list sits
  # above every category, which is where a voice channel usually belongs.
  cat_id=""
  if [ -n "$cat" ] && [ "$cat" != "-" ]; then
  cat_id=$(find_channel "$cat" 4) || {
    echo "fm-dc-setup: the channel list became unreadable; stopping rather than risking duplicates" >&2
    exit 1; }
  if [ -z "$cat_id" ]; then
    if [ -n "$DRY" ]; then
      # A dry run creates nothing, so the category still looks absent on the
      # next row of the same category; announce it once rather than per child.
      case " $ANNOUNCED " in
        *" $cat "*) : ;;
        *) echo "would create category: $cat"; ANNOUNCED="$ANNOUNCED $cat" ;;
      esac
      cat_id="(pending)"
    else
      cat_id=$(create_channel "$cat" 4 "" "") || exit 1
      echo "created category: $cat ($cat_id)"
      CREATED=$((CREATED + 1))
    fi
  fi
  fi
  [ -n "$chname" ] || continue
  case "$chtype" in
    ''|text)       tnum=0 ;;
    voice)         tnum=2 ;;
    announcement)  tnum=5 ;;
    forum)         tnum=15 ;;
    *) echo "fm-dc-setup: unknown channel type '$chtype' for #$chname" >&2; exit 2 ;;
  esac
  if [ -z "$IS_COMMUNITY" ]; then
    case "$tnum" in
      5|15)
        echo "skipped: #$chname is an $chtype channel, which requires the server to be a Community server (it is not yet)" >&2
        continue ;;
    esac
  fi
  ch_id=$(find_channel "$chname" "$tnum") || {
    echo "fm-dc-setup: the channel list became unreadable; stopping rather than risking duplicates" >&2
    exit 1; }
  if [ -z "$ch_id" ]; then
    if [ -n "$DRY" ]; then
      if [ "$cat" = "-" ]; then echo "would create channel: #$chname (top level)"
      else echo "would create channel: #$chname under $cat"; fi
      continue
    fi
    if [ -n "$MAP_ONLY" ]; then
      echo "fm-dc-setup: #$chname does not exist; run without --map-only to create it" >&2
      continue
    fi
    ch_id=$(create_channel "$chname" "$tnum" "$cat_id" "$topic") || exit 1
    echo "created channel: #$chname ($ch_id)"
    CREATED=$((CREATED + 1))
  else
    echo "present: #$chname ($ch_id)"
  fi
  # Only a text-shaped channel is a send target, so only those enter the map;
  # a voice channel id would just be a trap for --channel.
  if [ "$tnum" = 0 ] || [ "$tnum" = 5 ]; then
    var="DC_CHANNEL_$(printf '%s' "$chname" | tr '[:lower:]-' '[:upper:]_')"
    MAP_LINES="$MAP_LINES$var=$ch_id
"
  fi
done < <(printf '%s' "$SPEC" | python3 -c '
import json, sys
spec = json.load(sys.stdin)
# "-" marks a top-level channel. An EMPTY first column cannot be used: `read`
# with a whitespace IFS strips leading separators, so the row silently shifts
# left and the channel name is parsed as a category name.
for ch in spec.get("channels", []):
    sys.stdout.write("-\t%s\t%s\t%s\n"
                     % (ch["name"], ch.get("type", "text"), ch.get("topic", "")))
for cat in spec.get("categories", []):
    chans = cat.get("channels") or []
    if not chans:
        sys.stdout.write("%s\t\t\t\n" % cat["name"])
    for ch in chans:
        sys.stdout.write("%s\t%s\t%s\t%s\n"
                         % (cat["name"], ch["name"], ch.get("type", "text"),
                            ch.get("topic", "")))
')

if [ -n "$DRY" ]; then
  echo "dry run: nothing was changed"
  exit 0
fi

# The map is local operating state holding ids, never the token. Owner-only,
# same as every other private record this repo generates.
(umask 077; mkdir -p "$(dirname "$MAP")")
(umask 077; cat > "$MAP" <<MAPEOF
# Generated by bin/fm-dc-setup.sh - safe to delete and regenerate.
# Channel ids for the captain's Discord. Local, gitignored, no credentials.
DC_GUILD_ID=$DC_GUILD_ID
DC_MAX_UPLOAD=$UPLOAD
$MAP_LINES
MAPEOF
)
echo "wrote $MAP (upload ceiling $((UPLOAD/1048576))MB, boost tier $TIER)"
[ "$CREATED" -eq 0 ] && echo "nothing to create; the layout was already in place"
exit 0
