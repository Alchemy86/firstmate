#!/usr/bin/env bash
# fm-dc-lib.sh - shared core for firstmate's OUTBOUND-ONLY Discord channel.
#
# Sourced, never executed. Provides the config load, the mandatory User-Agent,
# the bounded API call, the reply parser, and the channel-name resolver so no
# caller re-derives them.
#
#   fm_dc_load [--if-configured]
#       Loads ~/.config/firstmate/discord.env (FM_DC_ENV_OVERRIDE for tests).
#       Sets DISCORD_BOT_TOKEN, DC_GUILD_ID and the resolved channel map.
#       Unconfigured: returns 1 loudly by default; with --if-configured it
#       returns 2 silently for a caller that must not care.
#
#   fm_dc_api <method> <path> [curl args...]
#       One bounded, UA-carrying, authenticated call. Prints the response body.
#
#   fm_dc_check   (stdin: a response body)
#       Silent on success; loud and non-zero on a Discord rejection.
#
#   fm_dc_channel <name-or-id>
#       Prints a channel id, resolving a bare name through the generated map
#       and then through the live guild.
#
# DISCORD IS OUTBOUND ONLY. Telegram remains the only way the captain reaches
# firstmate; there is deliberately no poller, no cadence file, no Stop hook and
# no bootstrap step here, so an unconfigured home is byte-for-byte unchanged
# without needing anything gated off. See docs/discord.md.
#
# THE TRAP THIS FILE EXISTS TO CENTRALISE: Discord sits behind Cloudflare and
# answers a request with no User-Agent with `403 error code: 1010`, not a 401
# and not anything mentioning auth. A plain curl or urllib call is rejected
# before Discord's own API ever sees the token, so the failure looks like bad
# credentials and is not. Every call must carry a UA of the documented form
# `DiscordBot (<url>, <version>)`; fm_dc_api is the only place that is spelled.
set -u

FM_DC_UA='DiscordBot (https://github.com/Alchemy86/firstmate, 1.0)'
FM_DC_API_BASE="${FM_DC_API_OVERRIDE:-https://discord.com/api/v10}"

# Discord's free-guild attachment ceiling. A boosted guild raises it (tier 2 =
# 50MiB, tier 3 = 100MiB), which is why fm-dc-setup.sh records the measured
# value rather than every caller trusting this default.
FM_DC_UPLOAD_DEFAULT=10485760

_fm_dc_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-timeout-lib.sh
. "$_fm_dc_lib_dir/fm-timeout-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$_fm_dc_lib_dir/fm-primary-scope-lib.sh"

# ---- FIRSTMATE-ONLY GUARD ------------------------------------------------
# Crewmates must NEVER address the captain; all crew communication flows
# through firstmate (AGENTS.md hard rule 4). This is not a theoretical
# boundary: bin/fm-tg-send.sh had to be retrofitted with exactly this guard
# after briefs told crews to message the captain directly and he received
# messages from crewmates. A second outbound channel would reopen that hole,
# so it is closed here from the first commit rather than after the incident.
#
# A crew worktree is identified by git's own linked-worktree shape, not by
# where it happens to live, and the literal treehouse path is refused on top
# of that because a leased directory is a crew location either way.
fm_dc_refuse_crew() {
  echo "fm-dc: REFUSED - crewmates must not contact the captain." >&2
  echo "  You are in a crew worktree. Report through your status file:" >&2
  echo "    echo 'done: <one line>' >> \$FM_HOME/state/<your-task-id>.status" >&2
  echo "  firstmate relays everything to the captain." >&2
  exit 3
}

fm_dc_guard_crew() {
  [ -n "${FM_DC_FORCE:-}" ] && return 0
  local cwd
  cwd=$(pwd -P 2>/dev/null || echo "")
  case "$cwd" in
    "$HOME"/.treehouse/*) fm_dc_refuse_crew ;;
  esac
  if [ -n "$cwd" ] && fm_dir_is_child_worktree "$cwd"; then
    fm_dc_refuse_crew
  fi
  return 0
}
# ------------------------------------------------------------------------

fm_dc_load() {
  local quiet=""
  [ "${1:-}" = "--if-configured" ] && quiet=1
  local envf="${FM_DC_ENV_OVERRIDE:-$HOME/.config/firstmate/discord.env}"
  if [ ! -f "$envf" ]; then
    [ -n "$quiet" ] && return 2
    echo "discord: not configured (no $envf); see docs/discord.md" >&2
    return 1
  fi
  set -a
  # shellcheck source=/dev/null # a resolved runtime path, not a repo file
  . "$envf"
  set +a
  if [ -z "${DISCORD_BOT_TOKEN:-}" ]; then
    [ -n "$quiet" ] && return 2
    echo "discord: $envf has no DISCORD_BOT_TOKEN; see docs/discord.md" >&2
    return 1
  fi
  # The generated channel map is optional: a home that has run fm-dc-setup.sh
  # gets name routing, one that has not can still post to an explicit id.
  local map="${FM_DC_CHANNELS_OVERRIDE:-${FM_HOME:-$_fm_dc_lib_dir/..}/config/discord-channels.env}"
  if [ -f "$map" ]; then
    set -a
    # shellcheck source=/dev/null # a resolved runtime path, not a repo file
    . "$map"
    set +a
  fi
  FM_DC_MAX_UPLOAD="${FM_DC_MAX_UPLOAD:-${DC_MAX_UPLOAD:-$FM_DC_UPLOAD_DEFAULT}}"
  return 0
}

# Parse a Discord reply: silent on success, loud and non-zero otherwise.
# Exit 2 is a genuine parsed rejection, 1 anything unparseable - callers branch
# retries on that distinction rather than re-inspecting the raw body, which is
# the bug bin/fm-tg-send.sh's own header documents having paid for.
fm_dc_check() {
  python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    sys.stderr.write("discord: empty reply\n"); sys.exit(1)
try:
    d = json.loads(raw)
except Exception:
    # Cloudflares 1010 arrives as an HTML body, not JSON. Say so, because the
    # bare status alone reads as an auth failure and sends you hunting a token
    # that was never the problem.
    if "1010" in raw:
        sys.stderr.write("discord REJECTED by Cloudflare (error 1010): the "
                         "request carried no usable User-Agent. This is not a "
                         "token problem; see docs/discord.md\n")
        sys.exit(2)
    sys.stderr.write("discord: unparseable reply: %s\n" % raw[:200]); sys.exit(1)
if isinstance(d, dict) and d.get("code") and not d.get("id"):
    sys.stderr.write("discord REJECTED: %s (code %s)\n"
                     % (d.get("message"), d.get("code")))
    sys.exit(2)
'
}

# One bounded, authenticated, UA-carrying call, with Discord's rate limit
# honoured rather than discovered.
#
# WHY THE RETRY IS NOT OPTIONAL: Discord answers a burst with HTTP 429 and a
# JSON body carrying retry_after. That body is an OBJECT where a list was
# expected, so a caller that parses it as its own success shape silently reads
# "no channels exist" and creates duplicates of everything it was converging.
# That is not hypothetical - it produced four duplicate categories and four
# duplicate channels on the first real layout run. Backing off here, and
# failing loudly in the callers, are the two halves of that fix.
fm_dc_api() {
  local method=$1 path=$2 attempt=1 resp wait
  shift 2
  while [ "$attempt" -le 6 ]; do
    resp=$(fm_run_timed 60 curl -sS --max-time 60 \
      -X "$method" "$FM_DC_API_BASE$path" \
      -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
      -H "User-Agent: $FM_DC_UA" \
      "$@")
    case "$resp" in
      *'"retry_after"'*)
        wait=$(printf '%s' "$resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    print(max(1, int(float(d.get("retry_after", 2)) + 1)))
except Exception:
    print(3)
' 2>/dev/null || echo 3)
        [ "$attempt" -ge 6 ] && { printf '%s' "$resp"; return 0; }
        echo "discord: rate limited, waiting ${wait}s (attempt $attempt)" >&2
        sleep "$wait"
        attempt=$((attempt + 1))
        continue ;;
    esac
    printf '%s' "$resp"
    return 0
  done
  return 1
}

# Assert a response really is the JSON array the caller expects. An error
# object must never be mistaken for an empty collection.
fm_dc_is_list() {
  printf '%s' "$1" | python3 -c '
import json, sys
try:
    sys.exit(0 if isinstance(json.load(sys.stdin), list) else 1)
except Exception:
    sys.exit(1)
' 2>/dev/null
}

# Resolve a channel name or id to an id. A bare numeric string is already an
# id. A name is looked up in the generated map first (no network), then in the
# live guild, so a home that never ran setup still works.
fm_dc_channel() {
  local want=$1 var val resp
  case "$want" in
    ''|*[!0-9]*) : ;;
    *) printf '%s\n' "$want"; return 0 ;;
  esac
  want=${want#\#}
  var="DC_CHANNEL_$(printf '%s' "$want" | tr '[:lower:]-' '[:upper:]_')"
  eval "val=\${$var:-}"
  if [ -n "$val" ]; then printf '%s\n' "$val"; return 0; fi
  if [ -z "${DC_GUILD_ID:-}" ]; then
    echo "discord: cannot resolve channel '$want' - no DC_GUILD_ID and no generated map" >&2
    return 1
  fi
  resp=$(fm_dc_api GET "/guilds/$DC_GUILD_ID/channels") || return 1
  val=$(printf '%s' "$resp" | FM_DC_WANT="$want" python3 -c '
import json, os, sys
want = os.environ["FM_DC_WANT"]
try:
    chans = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not isinstance(chans, list):
    sys.exit(1)
for c in chans:
    if c.get("name") == want and c.get("type") == 0:
        sys.stdout.write(str(c["id"])); break
')
  if [ -z "$val" ]; then
    echo "discord: no text channel named '$want' in the guild; run bin/fm-dc-setup.sh" >&2
    return 1
  fi
  printf '%s\n' "$val"
}
