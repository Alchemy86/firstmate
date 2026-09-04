#!/usr/bin/env bash
# Behavioral regressions for bin/fm-dc-setup.sh's role sync (--badges/--roles).
#
# Every check drives the real script. Network calls go to a local stub over
# FM_DC_API_OVERRIDE, so this runs with no credentials and no Discord.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SETUP="$ROOT/bin/fm-dc-setup.sh"
TMP_ROOT=$(fm_test_tmproot fm-dc-setup)

# A stub Discord: channels and guild are fixed, and the role list is read
# fresh from $rolesfile on every GET, so a test can rewrite it between calls to
# simulate "the role fm-dc-setup.sh just created now exists".
stub_start() {
  local dir=$1 rolesfile=$2
  mkdir -p "$dir"
  python3 - "$dir" "$rolesfile" >"$dir/port" 2>"$dir/stub.err" <<'PY' &
import http.server, json, os, sys
d, rolesfile = sys.argv[1], sys.argv[2]
counter = [1000]

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(n) if n else b""

    def _reply(self, obj, code=200):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)

    def do_GET(self):
        if self.path.endswith("/channels"):
            self._reply([])
        elif self.path.endswith("/roles"):
            try:
                roles = json.load(open(rolesfile))
            except Exception:
                roles = []
            self._reply(roles)
        else:
            self._reply({"id": "1", "name": "stub", "premium_tier": 0, "features": []})

    def do_POST(self):
        raw = self._body()
        with open(os.path.join(d, "last-request"), "wb") as f:
            f.write(raw)
        counter[0] += 1
        role = dict(json.loads(raw)); role["id"] = str(counter[0])
        self._reply(role)

    def do_PATCH(self):
        raw = self._body()
        with open(os.path.join(d, "last-request"), "wb") as f:
            f.write(raw)
        rid = self.path.rsplit("/", 1)[-1]
        role = dict(json.loads(raw)); role["id"] = rid
        self._reply(role)

srv = http.server.HTTPServer(("127.0.0.1", 0), H)
print(srv.server_address[1], flush=True)
srv.serve_forever()
PY
  echo $! > "$dir/pid"
  local tries=0
  while [ ! -s "$dir/port" ] && [ "$tries" -lt 100 ]; do sleep 0.05; tries=$((tries + 1)); done
  local port; port=$(cat "$dir/port" 2>/dev/null)
  [ -n "$port" ] || fail "stub Discord never reported a port"
  printf 'http://127.0.0.1:%s\n' "$port"
}

stub_stop() {
  local dir=$1
  [ -f "$dir/pid" ] && kill "$(cat "$dir/pid")" 2>/dev/null
  return 0
}

# --- --roles: dry run, create, then idempotent update ------------------------
# The starting role is the shipped fixture, exercised as it will actually be
# run rather than a synthetic stand-in, so a schema drift in the real file
# would fail here before it fails against the live server.
test_roles_dry_run_creates_nothing() {
  local dir api rolesfile out rc
  dir="$TMP_ROOT/roles-dry"; mkdir -p "$dir"
  rolesfile="$dir/roles.json"; echo '[]' > "$rolesfile"
  api=$(stub_start "$dir/stub" "$rolesfile")
  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"
  echo 'DC_GUILD_ID=1' > "$dir/cfg/channels.env"

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SETUP" --dry-run --roles "$ROOT/docs/examples/discord-starting-role.json" 2>&1); rc=$?
  stub_stop "$dir/stub"
  expect_code 0 "$rc" "a dry run over --roles must succeed: $out"
  assert_contains "$out" "would create role: Trainer" \
    "a dry run must report what it would create"
  assert_absent "$dir/stub/last-request" "a dry run must send no write to Discord"
  pass "--roles --dry-run reports the create and changes nothing"
}

test_roles_creates_then_updates_idempotently() {
  local dir api rolesfile out rc created_id
  dir="$TMP_ROOT/roles-live"; mkdir -p "$dir"
  rolesfile="$dir/roles.json"; echo '[]' > "$rolesfile"
  api=$(stub_start "$dir/stub" "$rolesfile")
  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"
  echo 'DC_GUILD_ID=1' > "$dir/cfg/channels.env"

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SETUP" --roles "$ROOT/docs/examples/discord-starting-role.json" 2>&1); rc=$?
  expect_code 0 "$rc" "creating the starting role must succeed: $out"
  assert_contains "$out" "created role: Trainer" "the first run must create the role"
  assert_contains "$out" "roles: 1 created, 0 already present" "the summary must count one create"
  created_id=$(python3 -c 'import json; print(json.load(open("'"$dir/stub/last-request"'"))["name"])')
  assert_contains "$created_id" "Trainer" "the created role must be named Trainer"

  # Simulate the role now existing, exactly as the second real run would see
  # it, and confirm the same command updates rather than duplicating it.
  python3 -c 'import json; open("'"$rolesfile"'", "w").write(json.dumps([{"id": "1001", "name": "Trainer", "color": 8359053}]))'

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SETUP" --roles "$ROOT/docs/examples/discord-starting-role.json" 2>&1); rc=$?
  stub_stop "$dir/stub"
  expect_code 0 "$rc" "re-running over an existing role must succeed: $out"
  assert_contains "$out" "role present, colour synced: Trainer" \
    "a second run must update the existing role, not create a duplicate"
  assert_contains "$out" "roles: 0 created, 1 already present" \
    "the summary must count zero creates on the idempotent run"
  pass "--roles creates the starting role once, then updates it in place"
}

# --- backward compatibility: --badges still reads a "badges"-keyed file -----
test_badges_flag_still_works_after_generalisation() {
  local dir api rolesfile out rc
  dir="$TMP_ROOT/badges-compat"; mkdir -p "$dir"
  rolesfile="$dir/roles.json"; echo '[]' > "$rolesfile"
  api=$(stub_start "$dir/stub" "$rolesfile")
  mkdir -p "$dir/cfg"
  echo 'DISCORD_BOT_TOKEN=stub-token-not-a-secret' > "$dir/cfg/discord.env"
  echo 'DC_GUILD_ID=1' > "$dir/cfg/channels.env"

  out=$(FM_DC_FORCE=1 FM_DC_API_OVERRIDE="$api" \
        FM_DC_ENV_OVERRIDE="$dir/cfg/discord.env" \
        FM_DC_CHANNELS_OVERRIDE="$dir/cfg/channels.env" \
        "$SETUP" --dry-run --badges "$ROOT/docs/examples/discord-badges.json" 2>&1); rc=$?
  stub_stop "$dir/stub"
  expect_code 0 "$rc" "--badges must still work once its machinery is shared with --roles: $out"
  assert_contains "$out" "would create role: Boulder Badge" \
    "--badges must still read a \"badges\"-keyed file after the generalisation"
  pass "--badges keeps working unchanged after sharing its machinery with --roles"
}

test_roles_dry_run_creates_nothing
test_roles_creates_then_updates_idempotently
test_badges_flag_still_works_after_generalisation
