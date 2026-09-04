#!/usr/bin/env bash
# Behavioral regressions for the outbound-only Discord channel.
#
# Every check drives the real scripts. Network calls go to a local stub over
# FM_DC_API_OVERRIDE, so this runs with no credentials and no Discord.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEND="$ROOT/bin/fm-dc-send.sh"
EMBED="$ROOT/bin/fm-dc-embed.py"
TMP_ROOT=$(fm_test_tmproot fm-dc-send)

# A stub Discord: one python http server that records the last request body and
# answers like the real API. Started per test group so a failure cannot leak a
# listener into the next one.
stub_start() {
  local dir=$1 port
  mkdir -p "$dir"
  python3 - "$dir" >"$dir/port" 2>"$dir/stub.err" <<'PY' &
import http.server, json, os, sys, threading
d = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""
    def do_GET(self):
        # The channel list the resolver reads.
        if self.path.endswith("/channels"):
            out = [{"id": "900000000000000001", "name": "ready", "type": 0, "parent_id": None},
                   {"id": "900000000000000002", "name": "gallery", "type": 0, "parent_id": None}]
        else:
            out = {"id": "1", "name": "stub", "premium_tier": 0, "features": []}
        b = json.dumps(out).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_POST(self):
        raw = self._body()
        with open(os.path.join(d, "last-request"), "wb") as f:
            f.write(raw)
        with open(os.path.join(d, "last-ua"), "w") as f:
            f.write(self.headers.get("User-Agent") or "")
        b = json.dumps({"id": "555000111222333444"}).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
  echo $! > "$dir/pid"
  local tries=0
  while [ ! -s "$dir/port" ] && [ "$tries" -lt 100 ]; do sleep 0.05; tries=$((tries + 1)); done
  port=$(cat "$dir/port" 2>/dev/null)
  [ -n "$port" ] || fail "stub Discord never reported a port"
  printf 'http://127.0.0.1:%s\n' "$port"
}

stub_stop() {
  local dir=$1
  [ -f "$dir/pid" ] && kill "$(cat "$dir/pid")" 2>/dev/null
  return 0
}

# --- inertness --------------------------------------------------------------
# The promise is two-shaped: an explicit call must fail loudly so a caller
# learns its message did not go, while --if-configured must be silently
# harmless for anything automatic. One behaviour cannot serve both.
test_unconfigured_is_inert_but_loud() {
  local out rc missing="$TMP_ROOT/nope/discord.env"

  out=$(FM_DC_FORCE=1 FM_DC_ENV_OVERRIDE="$missing" \
        "$SEND" --kind note --plain hello 2>&1); rc=$?
  expect_code 1 "$rc" "an explicit send with no config must fail"
  assert_contains "$out" "not configured" \
    "an explicit send with no config must say so"

  out=$(FM_DC_FORCE=1 FM_DC_ENV_OVERRIDE="$missing" \
        "$SEND" --kind note --plain hello --if-configured 2>&1); rc=$?
  expect_code 0 "$rc" "--if-configured with no config must exit 0"
  assert_contains "|$out|" "||" \
    "--if-configured with no config must print nothing at all"

  # A file that exists but carries no token is not configuration either.
  mkdir -p "$TMP_ROOT/partial"
  echo 'DISCORD_CLIENT_ID=123' > "$TMP_ROOT/partial/discord.env"
  out=$(FM_DC_FORCE=1 FM_DC_ENV_OVERRIDE="$TMP_ROOT/partial/discord.env" \
        "$SEND" --kind note --plain hello 2>&1); rc=$?
  expect_code 1 "$rc" "a tokenless config file must not count as configured"
  assert_contains "$out" "DISCORD_BOT_TOKEN" \
    "a tokenless config file must name the missing field"

  pass "unconfigured is inert for automatic callers and loud for explicit ones"
}

# --- the kind table ---------------------------------------------------------
test_kinds_drive_colour_and_routing() {
  local out
  out=$(python3 "$EMBED" --print-kinds)
  for k in ready blocked needs-decision broken landed milestone note gallery; do
    assert_contains "$out" "$k" "kind '$k' is missing from the kind table"
  done
  # THE DELIBERATE OMISSION. A `progress` kind would give routine no-change
  # chatter somewhere to land, which is the exact noise the channel exists to
  # stay free of. Its absence is a designed guarantee, so it is asserted.
  assert_not_contains "$out" "progress" \
    "a 'progress' kind appeared; routine progress must have nowhere to go"

  assert_contains "$(python3 "$EMBED" --print-channel ready)" "ready" \
    "kind 'ready' must route to #ready"
  assert_contains "$(python3 "$EMBED" --print-channel blocked)" "ready" \
    "a blocker must reach the captain in #ready"
  assert_contains "$(python3 "$EMBED" --print-channel broken)" "broken" \
    "kind 'broken' must route to #broken"
  assert_contains "$(python3 "$EMBED" --print-channel milestone)" "landed" \
    "a milestone must route to #landed"

  local rc
  python3 "$EMBED" --print-channel invented >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "an unknown kind must be refused, not routed somewhere"

  # Colours must actually differ, or the whole at-a-glance premise is void.
  local cg cr
  cg=$(python3 "$EMBED" --kind landed --title x | python3 -c 'import json,sys; print(json.load(sys.stdin)["embeds"][0]["color"])')
  cr=$(python3 "$EMBED" --kind broken --title x | python3 -c 'import json,sys; print(json.load(sys.stdin)["embeds"][0]["color"])')
  [ "$cg" != "$cr" ] || fail "landed and broken must not share a colour"
  pass "kinds drive distinct colours and the channel each one belongs in"
}

# --- payload safety ---------------------------------------------------------
# The reason the payload is built in Python at all. A title carrying quotes,
# a newline and a backslash must survive as DATA, and the result must still
# parse as JSON.
test_payload_survives_hostile_text() {
  local nasty payload
  nasty='O'"'"'Brien said "ship it" \ then <b>left</b>
second line; with a semicolon'
  payload=$(python3 "$EMBED" --kind ready --title "$nasty" --text "$nasty" \
              --field "Odd=a\"b'c" --url 'https://example.invalid/pr/1')
  printf '%s' "$payload" | python3 -c 'import json,sys; json.load(sys.stdin)' \
    || fail "a hostile title must still produce parseable JSON"
  # Round-trip the value rather than grepping the encoding, so the assertion is
  # about what Discord receives and not about how json.dumps escapes it.
  printf '%s' "$payload" | FM_EXP="$nasty" python3 -c '
import json, os, sys
d = json.load(sys.stdin)["embeds"][0]
want = os.environ["FM_EXP"]
assert want in d["title"] or d["title"].endswith("…"), "title lost its text"
assert d["description"] == want, "description was altered in transit"
' || fail "hostile text did not survive the round trip intact"

  # A malformed field is refused rather than posted half-built.
  local rc
  python3 "$EMBED" --kind ready --field 'novalue' >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a --field without name=value must be refused"
  pass "hostile captain-facing text round-trips as data, not as markup"
}

test_long_values_are_clipped_not_rejected() {
  local long payload len
  long=$(python3 -c 'print("x" * 9000)')
  payload=$(python3 "$EMBED" --kind note --title "$long" --text "$long")
  len=$(printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)["embeds"][0]
print("%d %d" % (len(d["title"]), len(d["description"])))')
  assert_contains "$len" "256 4096" \
    "an over-long title and body must be clipped to Discord's limits, not sent whole"
  pass "over-long text is clipped locally instead of failing the whole message"
}

# --- attachments ------------------------------------------------------------
test_attachment_declaration_and_inline_image() {
  local payload
  payload=$(python3 "$EMBED" --kind gallery --title shot --attach-name shot.png)
  # Discord answers "Invalid Form Body" with no field named if the attachments
  # array is missing, so its presence is pinned.
  printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["attachments"] == [{"id": 0, "filename": "shot.png"}], "attachments array missing"
assert d["embeds"][0]["image"]["url"] == "attachment://shot.png", "image not wired to the upload"
' || fail "an image upload must be declared and wired to the embed"

  payload=$(python3 "$EMBED" --kind gallery --title film --attach-name film.mp4)
  printf '%s' "$payload" | python3 -c '
import json, sys
d = json.load(sys.stdin)
assert d["attachments"], "a video upload must still be declared"
assert "image" not in d["embeds"][0], "a video must not be wired as an embed image"
' || fail "a video must not be given a broken inline image frame"
  pass "uploads are declared, and only still images become the inline image"
}

test_oversize_file_is_refused_before_upload() {
  local dir out rc big api
  dir="$TMP_ROOT/oversize"; mkdir -p "$dir"
  api=$(stub_start "$dir/stub")
  big="$dir/big.png"
  python3 -c 'open("'"$big"'","wb").write(b"\0" * (3 * 1024 * 1024))'

  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"
  printf 'DC_GUILD_ID=1\nDC_MAX_UPLOAD=1048576\nDC_CHANNEL_GALLERY=900000000000000002\n' \
    > "$dir/cfg/channels.env"

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SEND" --kind gallery --file "$big" 2>&1); rc=$?
  stub_stop "$dir/stub"
  expect_code 1 "$rc" "a file over the ceiling must be refused"
  assert_contains "$out" "over this server's" \
    "the refusal must name the server's own limit"
  assert_contains "$out" "30fps" \
    "the refusal must tell the caller how to make a film fit"
  assert_absent "$dir/stub/last-request" \
    "an oversize file must be refused BEFORE anything is uploaded"
  pass "an oversize attachment is refused up front, naming the limit and the way out"
}

# --- transport --------------------------------------------------------------
# The semicolon case is a regression, not a hypothetical: curl -F parses ';' in
# a field value as the start of a parameter, so a caption containing one used to
# corrupt the multipart body and Discord rejected the message naming no field.
test_semicolon_payload_survives_multipart_upload() {
  local dir api out rc img
  dir="$TMP_ROOT/semicolon"; mkdir -p "$dir"
  api=$(stub_start "$dir/stub")
  img="$dir/shot.png"
  python3 -c 'open("'"$img"'","wb").write(b"\0" * 64)'
  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"
  printf 'DC_GUILD_ID=1\nDC_CHANNEL_GALLERY=900000000000000002\n' > "$dir/cfg/channels.env"

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SEND" --kind gallery --title "Colour key" \
        --file "$img" "good or bad; act or not" 2>&1); rc=$?
  expect_code 0 "$rc" "an upload whose caption contains ';' must succeed: $out"
  assert_contains "$out" "555000111222333444" "the created message id must be printed"
  # The whole payload must arrive, semicolon and all - a truncated one is the
  # exact shape of the original defect.
  python3 - "$dir/stub/last-request" <<'PY' || fail "the multipart payload arrived truncated at the semicolon"
import re, sys
raw = open(sys.argv[1], "rb").read().decode("utf-8", "replace")
m = re.search(r'name="payload_json"\r?\n(?:[^\r\n]*\r?\n)*?\r?\n(\{.*?\})\r?\n--', raw, re.S)
assert m, "no payload_json part found in the request"
import json
d = json.loads(m.group(1))
desc = d["embeds"][0]["description"]
assert desc == "good or bad; act or not", "payload_json was corrupted: %r" % desc
PY
  assert_contains "$(cat "$dir/stub/last-ua")" "DiscordBot (" \
    "every request must carry the DiscordBot User-Agent Cloudflare demands"
  stub_stop "$dir/stub"
  pass "a semicolon in a caption survives the upload, and the UA is always sent"
}

# --- channel mentions --------------------------------------------------------
# A `{{name}}` token in --text/--plain must become a clickable channel mention
# through the same lookup --channel uses, which is what lets member- or
# captain-facing copy (the welcome message, above all) name a room instead of
# carrying a raw id.
test_channel_mentions_resolve_in_text() {
  local dir api out rc
  dir="$TMP_ROOT/mentions"; mkdir -p "$dir"
  api=$(stub_start "$dir/stub")
  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"
  printf 'DC_GUILD_ID=1\nDC_CHANNEL_READY=900000000000000001\nDC_CHANNEL_GALLERY=900000000000000002\n' \
    > "$dir/cfg/channels.env"

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SEND" --kind note --channel ready --plain "see {{ready}} and {{gallery}}" 2>&1); rc=$?
  stub_stop "$dir/stub"
  expect_code 0 "$rc" "a send with resolvable mentions must succeed: $out"
  python3 - "$dir/stub/last-request" <<'PY' || fail "the sent content did not carry resolved mentions"
import json, sys
d = json.loads(open(sys.argv[1]).read())
assert d["content"] == "see <#900000000000000001> and <#900000000000000002>", \
    "mentions were not resolved into the message: %r" % d["content"]
PY
  pass "{{name}} tokens in --text become real channel mentions"
}

test_unresolvable_mention_fails_loudly() {
  local dir api out rc
  dir="$TMP_ROOT/mentions-bad"; mkdir -p "$dir"
  api=$(stub_start "$dir/stub")
  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"
  printf 'DC_GUILD_ID=1\nDC_CHANNEL_READY=900000000000000001\n' > "$dir/cfg/channels.env"

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SEND" --kind note --channel ready --plain "see {{nonexistent-channel}}" 2>&1); rc=$?
  stub_stop "$dir/stub"
  expect_code 1 "$rc" "a mention naming no real channel must fail rather than post a dead literal"
  assert_contains "$out" "nonexistent-channel" \
    "the failure must name which mention could not resolve"
  pass "a mention that cannot resolve fails loudly instead of posting {{literal}} text"
}

# --- the crew boundary ------------------------------------------------------
# Crewmates must never address the captain (AGENTS.md hard rule 4). bin/fm-tg-send.sh
# had to be retrofitted with this after crews really did message him.
test_crew_worktree_is_refused() {
  local dir out rc
  dir="$TMP_ROOT/crew"; mkdir -p "$dir"
  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"

  # A real linked worktree is the shape the guard keys on, so build one rather
  # than a directory that merely looks like a crew location.
  ( cd "$dir" && git init -q main-repo && cd main-repo \
    && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
    && git worktree add -q ../child-wt HEAD ) >/dev/null 2>&1 \
    || { pass "git worktree unavailable in this sandbox; crew guard case skipped"; return 0; }

  out=$(cd "$dir/child-wt" && FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        "$SEND" --kind note --plain "from a crew" 2>&1); rc=$?
  expect_code 3 "$rc" "a send from inside a crew worktree must be refused"
  assert_contains "$out" "REFUSED" "the crew refusal must be unmistakable"
  assert_contains "$out" "status file" "the refusal must name the correct route"
  pass "a crewmate cannot address the captain through Discord"
}

# --- the badge ladder -------------------------------------------------------
# The shipped badge file is a contract with the captain: eight Kanto badges in
# game order, strictly increasing thresholds, distinct colours, and no
# privileges. A silent edit breaking any of those would stay invisible until
# somebody earned the wrong thing.
test_badge_ladder_is_wellformed() {
  local f="$ROOT/docs/examples/discord-badges.json"
  assert_present "$f" "the badge ladder file must ship with the repo"
  python3 - "$f" <<'BADGEPY' || fail "the badge ladder is malformed"
import json, sys
d = json.load(open(sys.argv[1]))
b = d["badges"]
order = ["Boulder", "Cascade", "Thunder", "Rainbow", "Soul", "Marsh", "Volcano", "Earth"]
assert len(b) == 8, "expected 8 badges, got %d" % len(b)
assert [x["name"].split()[0] for x in b] == order, "badges are not in Kanto gym order"
levels = [x["level"] for x in b]
assert levels == sorted(levels) and len(set(levels)) == 8, \
    "thresholds must strictly increase: %r" % levels
cols = [x["colour"].lower() for x in b]
assert len(set(cols)) == 8, "two badges share a colour, defeating the at-a-glance point"
for x in b:
    int(x["colour"].lstrip("#"), 16)
    assert "icon" in x, "%s has no icon field to fill in later" % x["name"]
r = d["earning_rules"]
assert r["cooldown_seconds"] >= 30, "a short cooldown lets messages be farmed"
assert r["level_up_announcement"] == "off", "promotion announcements must default off"
for ch in ("ready", "broken", "landed", "gallery"):
    assert ch in r["no_xp_channels"], "%s must earn no points; it is automated output" % ch
BADGEPY
  pass "the badge ladder is eight ordered gym badges with rising thresholds and no farming"
}

# --- the welcome message and starting role -----------------------------------
# The welcome message's {{name}} tokens must all resolve against the real
# layout, and the starting role must exist with a colour no badge shares -
# a drifted channel name or a badge-colour clash would only surface at send
# time otherwise, against the live server.
test_welcome_message_mentions_are_real_channels() {
  local msg="$ROOT/docs/examples/discord-welcome-message.md"
  local layout="$ROOT/docs/examples/discord-layout.json"
  assert_present "$msg" "the welcome message must ship with the repo"
  assert_present "$layout" "the reference layout must ship with the repo"
  python3 - "$msg" "$layout" <<'WELCOMEPY' || fail "the welcome message mentions a channel the layout does not define"
import json, re, sys
msg = open(sys.argv[1]).read()
layout = json.load(open(sys.argv[2]))
names = set()
for ch in layout.get("channels", []):
    names.add(ch["name"])
for cat in layout.get("categories", []):
    for ch in cat.get("channels") or []:
        names.add(ch["name"])
tokens = set(re.findall(r"\{\{([a-z0-9-]+)\}\}", msg))
assert tokens, "the welcome message names no channels at all"
missing = tokens - names
assert not missing, "welcome message mentions channels missing from the layout: %r" % missing
WELCOMEPY
  pass "every {{name}} in the welcome message is a real channel in the reference layout"
}

test_starting_role_is_wellformed_and_distinct() {
  local f="$ROOT/docs/examples/discord-starting-role.json"
  local badges="$ROOT/docs/examples/discord-badges.json"
  assert_present "$f" "the starting-role file must ship with the repo"
  python3 - "$f" "$badges" <<'ROLEPY' || fail "the starting role is malformed or clashes with a badge"
import json, sys
d = json.load(open(sys.argv[1]))
roles = d.get("roles") or d.get("badges") or []
assert len(roles) == 1, "expected exactly one starting role, got %d" % len(roles)
r = roles[0]
assert r["name"], "the starting role needs a name"
colour = r["colour"].lower()
int(colour.lstrip("#"), 16)
badge_cols = {b["colour"].lower() for b in json.load(open(sys.argv[2]))["badges"]}
assert colour not in badge_cols, \
    "the starting role's colour must not match any badge, or it reads as an earned rank"
ROLEPY
  pass "the starting role is one well-formed role with a colour no badge shares"
}

test_unconfigured_is_inert_but_loud
test_badge_ladder_is_wellformed
test_welcome_message_mentions_are_real_channels
test_starting_role_is_wellformed_and_distinct
test_kinds_drive_colour_and_routing
test_payload_survives_hostile_text
test_long_values_are_clipped_not_rejected
test_attachment_declaration_and_inline_image
test_oversize_file_is_refused_before_upload
test_semicolon_payload_survives_multipart_upload
test_channel_mentions_resolve_in_text
test_unresolvable_mention_fails_loudly
test_crew_worktree_is_refused
