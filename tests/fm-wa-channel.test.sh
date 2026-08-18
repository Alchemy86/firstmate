#!/usr/bin/env bash
# Behavioral regressions for the inbound WhatsApp channel.
#
# Everything here runs without a live WhatsApp session: the listener's
# accept/reject rules are driven through its handle-fixture command, and the
# send path through FM_WA_DRY_RUN. Pairing itself needs the captain's phone and
# is out of scope for an automated test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-wa-poll.sh"
SETUP="$ROOT/bin/fm-wa-setup.sh"
SEND="$ROOT/bin/fm-wa-send.sh"
LISTENER="$ROOT/bin/fm-wa-listen.mjs"
LISTEN_SH="$ROOT/bin/fm-wa-listen.sh"
LIB="$ROOT/bin/fm-wa-lib.sh"
CAPTAIN=447700900123
TMP_ROOT=$(fm_test_tmproot fm-wa-channel)

new_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=0\n' "$CAPTAIN" > "$home/config/whatsapp.env"
}

stash_message() {
  local home=$1 id=$2
  mkdir -p "$home/state/wa-inbox"
  chmod 700 "$home/state/wa-inbox"
  printf '{"schema":"fm-wa-inbox-v1","id":"%s","text":"hello"}\n' "$id" \
    > "$home/state/wa-inbox/$id.json"
  chmod 600 "$home/state/wa-inbox/$id.json"
}

poll() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$POLL" 2>/dev/null
}

# A paired, running listener, so a test about the inbox is not answered by the
# liveness nudge instead. The pid is a disposable process rather than this test
# runner, because the poll repairs a wedged listener by stopping it.
FAKE_PIDS=
fake_listener() {
  local home=$1 pid
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  sleep 300 &
  pid=$!
  FAKE_PIDS="$FAKE_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/wa-listener.pid"
  # The poll refuses to signal a pid it cannot bind to the listener this home
  # started, so a stand-in has to carry the same identity record a real start
  # writes.
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_WA_STATE="$home/state" fm_wa_record_listener_identity "$pid" ) \
    >/dev/null 2>&1 || true
}

reap_fake_listeners() {
  local pid
  for pid in $FAKE_PIDS; do
    kill "$pid" 2>/dev/null || true
  done
  FAKE_PIDS=
}
trap 'reap_fake_listeners; fm_test_cleanup' EXIT

# --- the channel is inert until a home opts in ------------------------------

test_off_by_default() {
  local home out
  home="$TMP_ROOT/off"
  mkdir -p "$home/state" "$home/config"
  stash_message "$home" MSGOFF

  out=$(poll "$home")
  [ -z "$out" ] || fail "poll produced output with no config: $out"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) && \
    fail "arm succeeded with no config"
  assert_contains "$out" 'FM_WA_CAPTAIN' "arm did not name the missing configuration"
  assert_absent "$home/state/wa-watch.check.sh" "arm wrote a check shim with no config"

  pass "a home with no config/whatsapp.env polls nothing and arms nothing"
}

test_removing_config_reverts_to_silence() {
  local home out
  home="$TMP_ROOT/optout"
  new_home "$home"
  fake_listener "$home"
  stash_message "$home" MSGOPTOUT
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "armed home did not announce a pending message"

  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "poll still spoke after the config was removed: $out"

  pass "removing config/whatsapp.env reverts the home to no polling at all"
}

# --- the check contract -----------------------------------------------------

test_check_contract() {
  local home out
  home="$TMP_ROOT/check"
  new_home "$home"
  mkdir -p "$home/state/wa-inbox"
  chmod 700 "$home/state/wa-inbox"
  # A paired listener is faked so the liveness nudge stays quiet and only the
  # inbox contract is under test.
  fake_listener "$home"

  out=$(poll "$home")
  [ -z "$out" ] || fail "empty inbox produced output: $out"

  stash_message "$home" MSGA
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGA' "a new message was not announced"

  out=$(poll "$home")
  [ -z "$out" ] || fail "the same pending set was announced twice: $out"

  stash_message "$home" MSGB
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 2 pending' "a changed pending set was not announced"

  rm -f "$home/state/wa-inbox/"*.json
  out=$(poll "$home")
  [ -z "$out" ] || fail "a drained inbox produced output: $out"

  pass "the check speaks once per new pending set and is silent otherwise"
}

test_undrained_inbox_is_reannounced() {
  local home out
  home="$TMP_ROOT/reannounce"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_REANNOUNCE=0\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  fake_listener "$home"
  stash_message "$home" MSGSTUCK

  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "first announcement missing"
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "an undrained inbox was never re-announced"

  pass "a message firstmate failed to drain resurfaces rather than being lost"
}

test_an_unusable_entry_never_silences_the_rest() {
  local home out
  home="$TMP_ROOT/badname"
  new_home "$home"
  fake_listener "$home"
  stash_message "$home" MSGGOOD
  : > "$home/state/wa-inbox/not a usable id.json"
  chmod 600 "$home/state/wa-inbox/not a usable id.json"

  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGGOOD' \
    "one unusable filename silenced the real messages behind it"
  assert_not_contains "$out" 'wa-channel-error' \
    "the announcement was traded for a fault line the skill reads as do-not-read"

  # With nothing usable left there is nothing to announce, so the fault is the
  # right and only thing to say.
  rm -f "$home/state/wa-inbox/MSGGOOD.json" "$home/state/wa-poll.offered"
  out=$(poll "$home")
  assert_contains "$out" 'unusable message id' \
    "an inbox holding only an unusable entry reported nothing at all"

  pass "an unusable inbox entry is skipped, and never buries the messages behind it"
}

test_unpaired_listener_reports_once() {
  local home out
  home="$TMP_ROOT/unpaired"
  new_home "$home"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "an unpaired listener was not reported"
  assert_contains "$out" 'pair' "the unpaired report did not name the fix"

  out=$(poll "$home")
  [ -z "$out" ] || fail "the same listener fault was reported twice: $out"

  pass "a listener fault is reported once, not on every cycle"
}

test_channel_fault_and_inbox_never_share_a_cycle() {
  local home out
  home="$TMP_ROOT/onefault"
  new_home "$home"
  stash_message "$home" MSGFAULT

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "the listener fault was not reported"
  assert_not_contains "$out" 'wa-message' "a fault cycle also announced the inbox"

  # The fault is deduped, so the pending message is not starved behind it.
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGFAULT' \
    "pending messages stayed buried behind a reported fault"
  assert_not_contains "$out" 'wa-channel-error' "the same fault was reported twice"

  pass "a cycle reports either a channel fault or the inbox, never both"
}

test_logged_out_listener_is_reported() {
  local home out
  home="$TMP_ROOT/loggedout"
  new_home "$home"
  # Credentials survive a logout, so pairing alone cannot tell the difference.
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '{"state":"logged-out","at":1}\n' > "$home/state/wa-listener.status"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a logged-out listener was never surfaced"
  assert_contains "$out" 'logged out' "the report did not name the logout"
  assert_absent "$home/state/wa-listener.restart" "a logged-out listener was respawned anyway"

  pass "a logged-out device is reported instead of being restarted forever"
}

test_repeated_listener_exits_are_reported() {
  local home out
  home="$TMP_ROOT/flapping"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '3\n' > "$home/state/wa-listener.restarts"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a listener that keeps exiting was never surfaced"
  assert_contains "$out" 'will not stay healthy' "the report did not name the repeated exits"

  pass "a listener that dies on every restart is reported rather than respawned forever"
}

test_slow_flap_still_reaches_the_restart_limit() {
  local home
  home="$TMP_ROOT/slowflap"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  # A listener that dies on a period longer than the check interval: alive on
  # this cycle, restarted moments ago, and already twice down.
  printf '2\n' > "$home/state/wa-listener.restarts"
  : > "$home/state/wa-listener.restart"

  poll "$home" >/dev/null
  assert_grep '2' "$home/state/wa-listener.restarts" \
    "one live observation erased a flapping listener's restart history"

  # No restart has been needed for a long stretch, so the listener really is up.
  touch -t 200001010000 "$home/state/wa-listener.restart"
  poll "$home" >/dev/null
  assert_absent "$home/state/wa-listener.restarts" \
    "a listener that stayed up without a restart kept its stale restart history"

  pass "restart history survives a live cycle and clears only after a stable stretch"
}

test_a_refused_restart_says_why_in_the_log() {
  local home bindir waited
  home="$TMP_ROOT/spawnlog"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"

  # A listener wrapper that refuses before the listener can open its own log,
  # the way the real one does with no node or an unusable state directory. The
  # fault line the poll eventually prints names that log, so the reason has to
  # reach it.
  bindir="$TMP_ROOT/spawnlog-bin"
  mkdir -p "$bindir"
  cp "$POLL" "$LIB" "$bindir/"
  cat > "$bindir/fm-wa-listen.sh" <<'SH'
#!/usr/bin/env bash
echo "error: node is required for the WhatsApp listener" >&2
exit 1
SH
  chmod +x "$bindir/fm-wa-listen.sh"

  FM_HOME="$home" "$bindir/fm-wa-poll.sh" >/dev/null 2>&1

  waited=0
  while [ "$waited" -lt 25 ] \
    && ! grep -q 'node is required' "$home/state/wa-listener.log" 2>/dev/null; do
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  assert_grep 'node is required' "$home/state/wa-listener.log" \
    "a restart that never got off the ground left no reason in the log the fault line names"

  pass "a restart refused by the listener wrapper explains itself in the listener log"
}

test_outbound_digests_are_pruned() {
  local home
  home="$TMP_ROOT/sentjanitor"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  mkdir -p "$home/state/wa-sent"
  chmod 700 "$home/state/wa-sent"
  : > "$home/state/wa-sent/aaaa.sent"
  touch -t 200001010000 "$home/state/wa-sent/aaaa.sent"
  : > "$home/state/wa-sent/bbbb.sent"

  poll "$home" >/dev/null

  assert_absent "$home/state/wa-sent/aaaa.sent" \
    "an outbound digest long past the echo window was never pruned"
  assert_present "$home/state/wa-sent/bbbb.sent" \
    "pruning removed a digest that could still match a live echo"

  pass "outbound digests are bounded by the poll, not only by an inbound message"
}

test_dry_run_records_are_pruned() {
  local home
  home="$TMP_ROOT/outboxjanitor"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  mkdir -p "$home/state/wa-outbox"
  chmod 700 "$home/state/wa-outbox"
  : > "$home/state/wa-outbox/1000000000-1.json"
  touch -t 200001010000 "$home/state/wa-outbox/1000000000-1.json"
  : > "$home/state/wa-outbox/1000000001-2.json"

  poll "$home" >/dev/null

  assert_absent "$home/state/wa-outbox/1000000000-1.json" \
    "a long-dead dry-run record was never pruned"
  assert_present "$home/state/wa-outbox/1000000001-2.json" \
    "pruning removed a dry-run record still worth reading back"

  pass "a home standing in dry-run does not grow an unbounded outbox"
}

test_a_spent_restart_block_releases_itself_after_a_while() {
  local home out
  home="$TMP_ROOT/latch"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '3\n' > "$home/state/wa-listener.restarts"

  # A block that was spent moments ago still reports rather than respawning...
  out=$(poll "$home")
  assert_contains "$out" 'will not stay healthy' "a listener that keeps exiting was not reported"
  assert_contains "$out" 'bin/fm-wa-listen.sh restart' \
    "the report did not name the command that releases the block"

  # ...but an hour later the channel gets another chance on its own, so a
  # transient cause does not leave it off until someone happens to look.
  touch -t 200001010000 "$home/state/wa-listener.restarts"
  rm -f "$home/state/wa-listener.error.restart-latch"
  out=$(FM_WA_FORCE_SPAWN_FALLBACK=1 poll "$home")
  assert_not_contains "$out" 'will not stay healthy' \
    "the restart block never released, so the channel stayed off for good"
  assert_present "$home/state/wa-listener.restart" \
    "the released block did not actually retry the listener"

  pass "a spent restart block reports, then retries on its own an hour later"
}

test_a_hand_run_start_releases_the_restart_block() {
  local home fakebin pid
  home="$TMP_ROOT/handstart"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  fakebin=$(fm_fakebin "$TMP_ROOT/handstart")
  # A real listener's command names the program it is running, and the start
  # binds the pid to that command, so the stand-in has to keep it too.
  cat > "$fakebin/node" <<'SH'
#!/usr/bin/env bash
exec -a "node $*" sleep 30
SH
  chmod +x "$fakebin/node"

  # The poll's own restart must NOT clear the history, or a listener that dies
  # slowly would erase the very evidence that proves it is flapping.
  printf '3\n' > "$home/state/wa-listener.restarts"
  # A start publishes its pid file before the listener has claimed the status
  # file, so the predecessor's last word has to go with the process that said it.
  printf '{"state":"connected","me":"x","at":1,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_AUTOSTART=1 \
    "$LISTEN_SH" start >/dev/null 2>&1 || fail "the fake listener never started"
  assert_grep '3' "$home/state/wa-listener.restarts" \
    "an automatic restart erased the restart history that proves a flap"
  assert_absent "$home/state/wa-listener.status" \
    "a start left the previous listener's reported state for the new one to be judged by"
  pid=$(cat "$home/state/wa-listener.pid" 2>/dev/null) || pid=
  [ -n "$pid" ] && kill "$pid" 2>/dev/null
  rm -f "$home/state/wa-listener.pid"

  # A start run by hand is the operator's repair, and releases the block.
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$LISTEN_SH" start >/dev/null 2>&1 || fail "the hand-run listener never started"
  assert_absent "$home/state/wa-listener.restarts" \
    "a start run by hand left the restart block in place"

  # `restart` is what the fault line and the skill actually name, because it is
  # the one that repairs a listener still holding a pid. `start` would only
  # report that one already runs and change nothing.
  printf '3\n' > "$home/state/wa-listener.restarts"
  : > "$home/state/wa-listener.error.restart-latch"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$LISTEN_SH" start >/dev/null 2>&1
  assert_grep '3' "$home/state/wa-listener.restarts" \
    "start repaired a running listener instead of reporting it, so the named remedy is untested"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$LISTEN_SH" restart >/dev/null 2>&1 || fail "restart failed"
  assert_absent "$home/state/wa-listener.restarts" \
    "the remedy the fault line names left the restart block in place"
  assert_absent "$home/state/wa-listener.error.restart-latch" \
    "the remedy the fault line names left the reported fault in place"
  pid=$(cat "$home/state/wa-listener.pid" 2>/dev/null) || pid=
  [ -n "$pid" ] && kill "$pid" 2>/dev/null

  pass "the remedy the fault line names releases the block, and start alone does not"
}

# The watcher signals the whole process group of a check once it returns, so a
# listener spawned into that group is reaped seconds after it starts. Both
# detach paths are exercised, because the fallback is what a host without setsid
# depends on entirely.
assert_restart_survives_the_check_reap() {
  local home=$1 label=$2 bindir pid listener_pid waited
  bindir="$TMP_ROOT/$label-bin"
  mkdir -p "$bindir"
  cp "$POLL" "$LIB" "$bindir/"
  cat > "$bindir/fm-wa-listen.sh" <<SH
#!/usr/bin/env bash
echo \$\$ > "$home/state/fake-listener.pid"
exec sleep 60
SH
  chmod +x "$bindir/fm-wa-listen.sh"

  # Run the poll the way the watcher runs a check: in its own process group,
  # then signal that whole group once it has returned.
  # shellcheck disable=SC2016  # single quotes are deliberate: perl expands its own variables.
  perl -e 'setpgrp(0, 0); exec @ARGV' \
    env FM_HOME="$home" "FM_WA_FORCE_SPAWN_FALLBACK=${3:-0}" \
    bash "$bindir/fm-wa-poll.sh" >/dev/null 2>&1 &
  pid=$!
  wait "$pid" 2>/dev/null || true

  waited=0
  while [ "$waited" -lt 25 ] && [ ! -s "$home/state/fake-listener.pid" ]; do
    sleep 0.2
    waited=$(( waited + 1 ))
  done
  listener_pid=$(cat "$home/state/fake-listener.pid" 2>/dev/null) || listener_pid=
  [ -n "$listener_pid" ] || fail "$label: the poll never restarted the listener"

  kill -TERM -- "-$pid" 2>/dev/null || true
  sleep 0.3
  kill -KILL -- "-$pid" 2>/dev/null || true
  sleep 0.3

  kill -0 "$listener_pid" 2>/dev/null \
    || fail "$label: the watcher reaping the check took the listener with it"
  kill -9 "$listener_pid" 2>/dev/null || true
}

test_a_restarted_listener_survives_the_check_being_reaped() {
  command -v perl >/dev/null 2>&1 || { pass "detach test skipped: perl is unavailable"; return 0; }
  local home
  home="$TMP_ROOT/detach"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  assert_restart_survives_the_check_reap "$home" detach 1

  if command -v setsid >/dev/null 2>&1; then
    home="$TMP_ROOT/detach-setsid"
    new_home "$home"
    mkdir -p "$home/state/wa-auth"
    printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
    assert_restart_survives_the_check_reap "$home" detach-setsid 0
  fi

  pass "a restarted listener outlives the check that started it, with or without setsid"
}

test_stalled_listener_is_reported() {
  local home out pid
  home="$TMP_ROOT/stalled"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  # An alive process whose connection went away long ago.
  printf '1\n' > "$home/state/wa-listener.beat"
  touch -t 200001010000 "$home/state/wa-listener.beat"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a live listener with a dead connection looked healthy"
  assert_contains "$out" 'connection is down' "the report did not name the dead connection"

  pass "a running listener whose connection is down is reported, not trusted"
}

test_stalled_listener_is_replaced_not_only_reported() {
  local home out pid
  home="$TMP_ROOT/stallheal"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  printf '1\n' > "$home/state/wa-listener.beat"
  touch -t 200001010000 "$home/state/wa-listener.beat"

  out=$(poll "$home")
  assert_contains "$out" 'restarting it' \
    "a wedged listener was reported without saying it is being replaced"
  if kill -0 "$pid" 2>/dev/null; then
    fail "the wedged listener was left running, so nothing could bring the channel back"
  fi
  assert_absent "$home/state/wa-listener.pid" "the wedged listener's pid record outlived it"
  # The beat belongs to the process that wrote it: left behind, it would make
  # the replacement look wedged on its very first cycle and kill it again.
  assert_absent "$home/state/wa-listener.beat" "the wedged listener's beat outlived it"

  pass "a listener whose connection is down is replaced, not reported forever"
}

# The sender-device filter is the guard that keeps firstmate's own replies out
# of the inbox, and it is fed by a raw stanza hook. A listener that cannot
# attach that hook still connects and still beats, so nothing else in the poll
# would notice that every message from the captain is being thrown away.
# Reporting alone would leave it that way for as long as the socket holds,
# because the hook is only ever attached by a new connection.
test_a_listener_that_cannot_read_sender_devices_is_reported() {
  local home out pid
  home="$TMP_ROOT/nodevicehook"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  date +%s > "$home/state/wa-listener.beat"
  stash_message "$home" MSGHOOK

  printf '{"state":"connected","me":"x","at":1}\n' > "$home/state/wa-listener.status"
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGHOOK' \
    "a healthy listener did not reach the inbox announcement"

  printf '{"state":"connected","me":"x","at":2,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"
  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' \
    "a listener that rejects every message looked perfectly healthy"
  assert_contains "$out" 'sender devices' \
    "the report did not name what the listener cannot read"
  assert_contains "$out" 'restarting it' \
    "the fault was reported without saying the listener is being replaced"
  assert_present "$home/state/wa-listener.error.device-hook" \
    "the fault was announced without being recorded"
  if kill -0 "$pid" 2>/dev/null; then
    fail "the deaf listener was left running, so the hook could never be reattached"
  fi
  assert_absent "$home/state/wa-listener.pid" \
    "the deaf listener's pid record outlived it"

  # It clears itself the moment a replacement attaches the hook again, so the
  # captain is not left with a fault that outlives the problem.
  fake_listener "$home"
  date +%s > "$home/state/wa-listener.beat"
  printf '{"state":"connected","me":"x","at":3}\n' > "$home/state/wa-listener.status"
  poll "$home" >/dev/null
  assert_absent "$home/state/wa-listener.error.device-hook" \
    "the fault outlived the listener recovering its sender-device hook"

  pass "a listener that cannot read sender devices is reported and replaced"
}

# The pid file is written at spawn and removed only on a clean exit, so a crash
# leaves it behind and the number in it can later belong to anything this user
# runs. Both repair paths above signal that pid, so it has to be bound to the
# listener this home actually started before anything is sent to it.
test_a_recycled_pid_is_never_signalled() {
  local home out pid
  home="$TMP_ROOT/pidreuse"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # An unrelated process that happens to hold the number a dead listener left in
  # its pid file.
  sleep 300 &
  pid=$!
  FAKE_PIDS="$FAKE_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/wa-listener.pid"
  printf 'Sat Jan  1 00:00:00 2000\n' > "$home/state/wa-listener.pid-identity"
  # ...and everything that would otherwise make the poll stop it.
  printf '1\n' > "$home/state/wa-listener.beat"
  touch -t 200001010000 "$home/state/wa-listener.beat"
  printf '{"state":"connected","me":"x","at":1,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"
  # Spent, so the cycle reports instead of spawning a listener this test would
  # then have to chase.
  printf '3\n' > "$home/state/wa-listener.restarts"

  out=$(poll "$home")
  kill -0 "$pid" 2>/dev/null \
    || fail "the poll signalled a process it never proved was its own listener"
  assert_not_contains "$out" 'connection is down' \
    "a stranger's pid was reported as the listener's own wedged connection"

  pass "a pid the poll cannot bind to this home's listener is never signalled"
}

# The identity is written by whoever started the listener and read back by
# whoever later checks it, and those two run under whatever environment their
# own caller had. A false mismatch is worse here than a refused stop: the poll
# concludes there is no listener at all and starts a second one onto the single
# credential folder WhatsApp allows, which is the break the binding exists to
# prevent. Timezone, locale and COLUMNS each re-render the ps form of that
# identity, so all three are varied between the write and every read below.
test_a_listener_binding_survives_an_environment_change() {
  local home listener_pid long bound recorded reread no_proc
  home="$TMP_ROOT/identityenv"
  new_home "$home"
  # ps truncates the command column to COLUMNS, so the process this binds to
  # needs a command line long enough for that truncation to be visible at all.
  long="$home/$(printf 'x%.0s' $(seq 1 200))"
  ln -s "$(command -v sleep)" "$long"
  "$long" 300 &
  listener_pid=$!
  FAKE_PIDS="$FAKE_PIDS $listener_pid"
  printf '%s\n' "$listener_pid" > "$home/state/wa-listener.pid"
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    TZ=UTC LC_ALL=C COLUMNS=200 FM_WA_STATE="$home/state" \
      fm_wa_record_listener_identity "$listener_pid" ) >/dev/null 2>&1 \
    || fail "the identity of a running process was not recorded"
  recorded=$(cat "$home/state/wa-listener.pid-identity")

  reread=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 FM_WA_STATE="$home/state" \
      fm_wa_process_identity "$listener_pid" )
  [ "$reread" = "$recorded" ] \
    || fail "the same live process rendered a different identity under another environment"

  bound=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_HOME="$home"
    fm_wa_paths
    TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 fm_wa_listener_pid ) || bound=
  [ "$bound" = "$listener_pid" ] \
    || fail "a live listener stopped being its own recorded identity under another environment"

  # On a host without a readable /proc - macOS, which this channel supports -
  # the identity falls back to ps, which is the form that renders the date in
  # the caller's own zone and locale and cuts the command at the caller's
  # COLUMNS. Everything above passes on Linux without ever reaching it, so the
  # fallback is pinned here in its own right.
  no_proc="$home/no-proc"
  mkdir -p "$no_proc"
  rm -f "$home/state/wa-listener.pid-identity"
  ( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_PROC_ROOT_OVERRIDE="$no_proc" TZ=UTC LC_ALL=C COLUMNS=200 FM_WA_STATE="$home/state" \
      fm_wa_record_listener_identity "$listener_pid" ) >/dev/null 2>&1 \
    || fail "a host without /proc recorded no identity for a running process"
  grep -q 'starttime=' "$home/state/wa-listener.pid-identity" \
    && fail "the no-/proc case never exercised the ps fallback it exists to pin"
  recorded=$(cat "$home/state/wa-listener.pid-identity")
  case "$recorded" in
    *xxxxxxxxxx*) ;;
    *) fail "the recorded identity carries no command, so truncation could never show" ;;
  esac

  reread=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_PROC_ROOT_OVERRIDE="$no_proc" TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 \
      FM_WA_STATE="$home/state" fm_wa_process_identity "$listener_pid" )
  [ "$reread" = "$recorded" ] \
    || fail "without /proc, the environment changed how the same process renders its identity"

  bound=$( # shellcheck source=bin/fm-wa-lib.sh
    . "$LIB"
    FM_HOME="$home"
    fm_wa_paths
    FM_PROC_ROOT_OVERRIDE="$no_proc" TZ=America/New_York LC_ALL=en_US.UTF-8 COLUMNS=40 \
      fm_wa_listener_pid ) || bound=
  [ "$bound" = "$listener_pid" ] \
    || fail "without /proc, a live listener stopped being its own identity under another environment"

  pass "a listener stays bound to its own identity across an environment change"
}

# The pid file appears the instant a replacement forks, well before that process
# has loaded enough to claim the status file. A predecessor's last status left in
# place is then read as the replacement's own, and the replacement is killed for
# a fault it never had - burning a slot of the restart budget every time.
test_a_replacement_is_not_judged_by_its_predecessor() {
  local home pid
  home="$TMP_ROOT/staleclaim"
  new_home "$home"
  fake_listener "$home"
  date +%s > "$home/state/wa-listener.beat"
  printf '{"state":"connected","me":"x","at":1,"deviceHook":"unavailable"}\n' \
    > "$home/state/wa-listener.status"

  poll "$home" >/dev/null
  assert_absent "$home/state/wa-listener.status" \
    "the deaf listener's reported state outlived the process that wrote it"

  # A replacement that is up but has not written its own status yet.
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  date +%s > "$home/state/wa-listener.beat"
  poll "$home" >/dev/null
  kill -0 "$pid" 2>/dev/null \
    || fail "a healthy replacement was stopped for its predecessor's fault"

  pass "a replacement listener is never judged by its predecessor's record"
}

test_a_skipped_entry_is_reported_on_a_quiet_cycle() {
  local home out
  home="$TMP_ROOT/badnamesaid"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  stash_message "$home" MSGSAID
  : > "$home/state/wa-inbox/not a usable id.json"
  chmod 600 "$home/state/wa-inbox/not a usable id.json"

  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGSAID' \
    "the announcement did not win its own cycle"

  # The set is unchanged, so this cycle has nothing to announce and is where the
  # skipped entry gets said - once, not on every cycle after it.
  out=$(poll "$home")
  assert_contains "$out" 'unusable message id' \
    "a skipped inbox entry was never reported at all"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the skipped entry was reported again on the next cycle: $out"

  pass "an entry the poll had to skip is reported once, without burying the messages"
}

test_listener_that_never_connects_is_reported() {
  local home out
  home="$TMP_ROOT/nevercame"
  new_home "$home"
  fake_listener "$home"
  # No beat at all: a listener that started but never got a connection up. Its
  # own start time is how long the channel has been down.
  touch -t 200001010000 "$home/state/wa-listener.pid"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "a listener that never connected looked healthy"
  assert_contains "$out" 'never come up' "the report did not name the connection that never came up"

  # A listener started moments ago has no beat either, and must be given the
  # same grace a working one gets between beats.
  rm -f "$home/state/wa-listener.error"
  touch "$home/state/wa-listener.pid"
  out=$(poll "$home")
  [ -z "$out" ] || fail "a listener that has just started was reported as faulty: $out"

  pass "a listener whose connection never came up is reported, not trusted"
}

test_repairing_the_link_clears_stale_listener_health() {
  command -v node >/dev/null 2>&1 || { pass "re-pairing check skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/repair"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # The wreckage of the old link: logged out, and out of restart attempts.
  printf '{"state":"logged-out"}\n' > "$home/state/wa-listener.status"
  printf '3\n' > "$home/state/wa-listener.restarts"
  : > "$home/state/wa-listener.restart"
  printf 'stale\n' > "$home/state/wa-listener.error"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" unpair 2>&1) \
    || fail "unpair failed: $out"
  assert_absent "$home/state/wa-listener.status" "unpair left the old link's connection state behind"
  assert_absent "$home/state/wa-listener.restarts" "unpair left the old link's restart count behind"
  assert_absent "$home/state/wa-listener.restart" "unpair left the old link's restart marker behind"
  assert_absent "$home/state/wa-listener.error" "unpair left the old link's fault behind"

  out=$(poll "$home")
  assert_contains "$out" 'not paired' "the poll did not name the missing pairing after unpair"
  assert_not_contains "$out" 'logged out' "the poll still reported the removed link as logged out"
  assert_not_contains "$out" 'will not stay healthy' "the poll still reported the removed link's restart count"

  pass "unpairing clears the old link's health, so the poll names the real next step"
}

test_listener_state_growth_is_bounded() {
  local home before after i
  home="$TMP_ROOT/janitor"
  new_home "$home"
  fake_listener "$home"
  printf '1\n' > "$home/state/wa-listener.beat"
  mkdir -p "$home/state/wa-seen"
  chmod 700 "$home/state/wa-seen"
  printf 'handled long ago\n' > "$home/state/wa-seen/OLDMSG.seen"
  touch -t 200001010000 "$home/state/wa-seen/OLDMSG.seen"
  printf 'handled just now\n' > "$home/state/wa-seen/NEWMSG.seen"
  i=1
  while [ "$i" -le 6000 ]; do
    printf 'listener line %s padding padding padding padding padding padding\n' "$i"
    i=$(( i + 1 ))
  done > "$home/state/wa-listener.log"
  before=$(wc -c < "$home/state/wa-listener.log" | tr -d '[:space:]')

  poll "$home" >/dev/null

  after=$(wc -c < "$home/state/wa-listener.log" | tr -d '[:space:]')
  [ "$after" -lt "$before" ] || fail "the listener log grew past its cap unchecked ($after bytes)"
  assert_grep 'listener line 6000' "$home/state/wa-listener.log" "capping the log dropped its newest lines"
  assert_absent "$home/state/wa-seen/OLDMSG.seen" "a long-expired handled-message marker was never pruned"
  assert_present "$home/state/wa-seen/NEWMSG.seen" "pruning removed a marker that still guards against redelivery"

  pass "the listener log and its handled-message markers are both bounded"
}

# --- the check shim ---------------------------------------------------------

test_shim_arm_register_disarm() {
  local home out
  home="$TMP_ROOT/shim"
  new_home "$home"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) \
    || fail "arm failed: $out"
  assert_present "$home/state/wa-watch.check.sh" "arm did not write the check shim"
  assert_present "$home/state/wa-watch.check-trust" "arm did not register the check shim"

  # The watcher validates a custom check against its registration before running
  # it; prove the real validator accepts what arm produced.
  ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$home/state" wa-watch ) \
    || fail "the watcher's own validator rejected the armed check"

  # And that an edit disarms it until re-registered.
  printf '# tampered\n' >> "$home/state/wa-watch.check.sh"
  if ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
       fm_custom_check_registered "$home/state" wa-watch ); then
    fail "an edited check shim stayed trusted"
  fi

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "re-arm failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) \
    || fail "disarm failed: $out"
  assert_absent "$home/state/wa-watch.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/wa-watch.check-trust" "disarm left the registration behind"

  pass "the check shim arms through the ordinary registration and disarms cleanly"
}

test_arming_makes_an_idle_home_need_supervision() {
  local home
  home="$TMP_ROOT/supneed"
  new_home "$home"

  # An idle home with the channel off arms no watcher, and must keep behaving
  # exactly that way.
  ( . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" 300 ) \
    && fail "a home with the channel off was counted as needing supervision"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"

  # The captain messages precisely when nothing is running, so an armed channel
  # alone has to keep a watcher up or the poll never runs at all.
  ( . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" 300 ) \
    || fail "an armed inbound channel did not keep an idle home supervised"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm >/dev/null 2>&1 \
    || fail "disarm failed"
  ( . "$ROOT/bin/fm-supervision-lib.sh"
    fm_supervision_needed "$home/state" 300 ) \
    && fail "a disarmed home was still counted as needing supervision"

  pass "an armed channel keeps an idle home supervised, and only while it is armed"
}

# The primary harnesses that decide for themselves when to arm each carry their
# own copy of the "does this home need a watcher" question. An armed channel is
# a supervision reason in bin/fm-supervision-lib.sh, so a primary that misses it
# leaves the captain's messages sitting in the inbox with nothing to announce
# them.
test_every_primary_arms_for_an_armed_channel() {
  local home probe out
  home="$TMP_ROOT/primaryarm"
  new_home "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"

  if ! command -v node >/dev/null 2>&1; then
    pass "an armed channel is a supervision reason on every self-arming primary (skipped: no node)"
    return
  fi

  # The predicate is private to the plugin, so it is lifted out and answered
  # directly rather than by driving a whole OpenCode session.
  probe="$home/shouldarm.mjs"
  cat > "$probe" <<'PROBE'
import fs from 'node:fs'
const [file, state, config] = process.argv.slice(2)
const src = fs.readFileSync(file, 'utf8')
const body = src.match(/function shouldArm\(paths\) \{[\s\S]*?\n\}/)
if (!body) { process.stderr.write('no shouldArm in the OpenCode plugin\n'); process.exit(1) }
const shouldArm = new Function('existsSync', 'readdirSync', `${body[0]}; return shouldArm`)(fs.existsSync, fs.readdirSync)
process.stdout.write(String(shouldArm({ state, config })))
PROBE

  out=$(node "$probe" "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    "$home/state" "$home/config" 2>&1) \
    || fail "could not evaluate the OpenCode arm predicate: $out"
  [ "$out" = true ] \
    || fail "the OpenCode primary would not arm a watcher for an armed channel"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm >/dev/null 2>&1 \
    || fail "disarm failed"
  out=$(node "$probe" "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" \
    "$home/state" "$home/config" 2>&1) \
    || fail "could not evaluate the OpenCode arm predicate: $out"
  [ "$out" = false ] \
    || fail "the OpenCode primary would arm a watcher for a home with nothing to watch"

  pass "an armed channel is a supervision reason on every self-arming primary"
}

# The cadence is only worth generating if the process that launches the watcher
# actually inherits it, so every primary that builds its own arm command has to
# source it exactly as it sources Relay's.
test_every_primary_arm_command_sources_the_cadence() {
  local home cmd out
  home="$TMP_ROOT/primarycadence"
  mkdir -p "$home/config"
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/wa-mode.env"
  cat > "$home/arm.sh" <<'ARM'
#!/usr/bin/env bash
printf 'interval=%s\n' "${FM_CHECK_INTERVAL:-unset}"
ARM
  chmod +x "$home/arm.sh"

  for cmd in \
    "$(sed -n "s/.*spawn(\"bash\", \[\"-lc\", '\(config_dir=.*--restart\)'.*/\1/p" \
        "$ROOT/.opencode/plugins/fm-primary-watch-arm.js" | head -n 1)" \
    "$(sed -n 's/.*spawn("bash", \["-lc", "\(config_dir=.*--restart\)".*/\1/p' \
        "$ROOT/.pi/extensions/fm-primary-pi-watch.ts" | head -n 1 | sed 's/\\"/"/g')"
  do
    [ -n "$cmd" ] || fail "could not read a primary's arm command"
    cmd=${cmd//\"\$FM_ROOT_OVERRIDE\/bin\/fm-watch-arm.sh\"/\"\$FM_WATCH_ARM_SCRIPT\"}
    out=$(FM_CONFIG_OVERRIDE="$home/config" FM_HOME="$home" \
      FM_WATCH_ARM_SCRIPT="$home/arm.sh" bash -c "$cmd" 2>/dev/null)
    assert_contains "$out" 'interval=30' \
      "a primary's arm command did not source the generated cadence: $cmd"
  done

  pass "every primary's arm command inherits the generated cadence"
}

test_arming_writes_the_watcher_cadence() {
  local home out
  home="$TMP_ROOT/cadence"
  new_home "$home"
  assert_absent "$home/config/wa-mode.env" "a home that never armed already had a cadence file"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) || fail "arm failed: $out"
  assert_present "$home/config/wa-mode.env" "arm did not write the watcher cadence"
  assert_contains "$(cat "$home/config/wa-mode.env")" 'FM_CHECK_INTERVAL=30' \
    "the cadence file does not speed the watcher up"
  # Sourced, never executed, and private to this home.
  local mode
  mode=$(stat -c %a "$home/config/wa-mode.env" 2>/dev/null \
    || stat -f %Lp "$home/config/wa-mode.env" 2>/dev/null)
  [ "$mode" = 600 ] || fail "the cadence file is not private: $mode"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" status 2>&1)
  assert_contains "$out" 'cadence: present' "status did not report the armed cadence"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) || fail "disarm failed: $out"
  assert_absent "$home/config/wa-mode.env" "disarm left the cadence file behind"

  pass "arming writes the 30s watcher cadence and disarming removes it"
}

test_the_cadence_reaches_the_supervision_block() {
  local home out
  home="$TMP_ROOT/cadenceblock"
  new_home "$home"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex 2>&1)
  assert_not_contains "$out" "$home/config/wa-mode.env" \
    "an unarmed home was told to source a cadence file it does not have"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex 2>&1)
  assert_contains "$out" "$home/config/wa-mode.env" \
    "the emitted supervision block never names the generated cadence"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-supervision-instructions.sh" --harness codex --repair-line 2>&1)
  assert_contains "$out" "source '$home/config/wa-mode.env' first" \
    "the repair line does not carry the cadence into a re-armed watcher"

  pass "the generated cadence is sourced the same way Relay's is"
}

test_stop_says_the_armed_check_restarts_it() {
  local home out
  home="$TMP_ROOT/stopnote"
  new_home "$home"
  fake_listener "$home"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop 2>&1)
  assert_not_contains "$out" 'disarm' "an unarmed home was told to disarm something"

  fake_listener "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop 2>&1)
  assert_contains "$out" 'disarm' \
    "stop did not say the armed check brings the listener straight back"

  pass "stopping the listener says plainly that an armed check restarts it"
}

test_shim_runs_the_poll_the_way_the_watcher_does() {
  local home out
  home="$TMP_ROOT/shimrun"
  new_home "$home"
  fake_listener "$home"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"
  stash_message "$home" MSGSHIM

  # fm-watch.sh snapshots the shim and runs it as `bash <snapshot>`.
  out=$( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
         fm_custom_check_snapshot_prepare "$home/state" wa-watch || exit 1
         bash "$FM_CUSTOM_CHECK_SNAPSHOT"
         fm_custom_check_snapshot_cleanup )
  assert_contains "$out" 'wa-message 1 pending, including MSGSHIM' \
    "the shim did not produce a wake line through the watcher's own execution path"

  pass "the watcher's snapshot-and-run path reaches the poll and gets one wake line"
}

# --- the send path ----------------------------------------------------------

test_dry_run_records_and_sends_nothing() {
  local home out record
  home="$TMP_ROOT/dryrun"
  new_home "$home"
  printf 'Captain, the fix is up: https://example.invalid/pull/1\n' > "$TMP_ROOT/reply.txt"

  # A mudslide that fails loudly proves the dry run never reaches it.
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/dryrun-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
echo "mudslide was called" >&2
exit 1
SH
  chmod +x "$fakebin/mudslide"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_WA_DRY_RUN=1 "$SEND" --text-file "$TMP_ROOT/reply.txt" 2>&1) \
    || fail "dry-run send failed: $out"
  assert_contains "$out" 'dry-run' "the dry run did not announce itself"
  assert_not_contains "$out" 'mudslide was called' "the dry run reached mudslide"

  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  [ -n "$record" ] || fail "the dry run recorded nothing to state/wa-outbox"
  assert_grep 'example.invalid/pull/1' "$record" "the outbox record lost the reply text"
  [ -n "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "the dry run recorded no echo marker"

  pass "FM_WA_DRY_RUN records the reply and transmits nothing"
}

test_json_encoder_round_trips_hostile_text() {
  command -v node >/dev/null 2>&1 || { pass "JSON encoder check skipped: node is unavailable"; return 0; }
  local encoded decoded
  # Every character class a JSON string has to escape, plus multi-byte UTF-8
  # that must survive untouched.
  printf 'quote " backslash \\ tab\tcontrol \001 caf\xc3\xa9\nsecond line' \
    > "$TMP_ROOT/encoder-input.txt"

  # shellcheck source=bin/fm-wa-lib.sh
  encoded=$( . "$LIB"; fm_wa_json_string < "$TMP_ROOT/encoder-input.txt" )
  decoded=$(printf '%s' "$encoded" | node -e '
    const chunks = []
    process.stdin.on("data", (c) => chunks.push(c))
    process.stdin.on("end", () => {
      const value = JSON.parse(Buffer.concat(chunks).toString("utf8"))
      if (typeof value !== "string") { process.stderr.write("not a JSON string\n"); process.exit(1) }
      process.stdout.write(value)
    })
  ') || fail "bin/fm-wa-lib.sh produced text that is not a JSON string"
  [ "$decoded" = "$(cat "$TMP_ROOT/encoder-input.txt")" ] \
    || fail "the JSON encoder did not round-trip the text it was given"

  pass "the JSON encoder in bin/fm-wa-lib.sh escapes what JSON requires and nothing else"
}

test_dry_run_record_is_valid_json() {
  command -v node >/dev/null 2>&1 || { pass "dry-run JSON check skipped: node is unavailable"; return 0; }
  local home record decoded fakebin
  home="$TMP_ROOT/dryrunjson"
  new_home "$home"
  # Quotes, a backslash, a tab, a line break and non-ASCII: everything a record
  # named .json has to survive.
  printf 'he said "go" \\ now\tstill\nsecond line caf\xc3\xa9\n' > "$TMP_ROOT/tricky.txt"

  # A jq that fails proves the encoding never depended on it.
  fakebin=$(fm_fakebin "$TMP_ROOT/dryrunjson-bin")
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/jq"

  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/tricky.txt" >/dev/null 2>&1 \
    || fail "the dry-run send failed"

  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  [ -n "$record" ] || fail "the dry run recorded nothing to state/wa-outbox"
  decoded=$(node -e '
    const fs = require("fs")
    const r = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    if (r.schema !== "fm-wa-outbox-v1") { process.stderr.write("wrong schema\n"); process.exit(1) }
    if (r.dry_run !== true) { process.stderr.write("not marked dry-run\n"); process.exit(1) }
    process.stdout.write(r.text)
  ' "$record") || fail "the dry-run record is not valid fm-wa-outbox-v1 JSON"
  [ "$decoded" = "$(cat "$TMP_ROOT/tricky.txt")" ] \
    || fail "the dry-run record did not carry the reply text back unchanged"

  pass "a dry-run record is valid JSON that round-trips the reply, with or without jq"
}

test_message_text_is_never_executed() {
  local home out record
  home="$TMP_ROOT/injection"
  new_home "$home"
  # Text a naive implementation would let the shell re-parse.
  # shellcheck disable=SC2016  # the unexpanded expression IS the payload.
  printf '%s\n' 'hi $(touch '"$TMP_ROOT"'/pwned) `touch '"$TMP_ROOT"'/pwned2` ; rm -rf /' \
    > "$TMP_ROOT/hostile.txt"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/hostile.txt" 2>&1) \
    || fail "send of hostile text failed: $out"
  assert_absent "$TMP_ROOT/pwned" "command substitution in message text executed"
  assert_absent "$TMP_ROOT/pwned2" "backticks in message text executed"
  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  assert_grep 'rm -rf' "$record" "the hostile text was not preserved verbatim as data"

  pass "message text is carried as data and never re-parsed by a shell"
}

test_config_is_read_as_data() {
  local home out
  home="$TMP_ROOT/configdata"
  mkdir -p "$home/state" "$home/config"
  # shellcheck disable=SC2016  # the unexpanded substitution IS the payload.
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=$(touch %s/config-pwned)0\n' \
    "$CAPTAIN" "$TMP_ROOT" > "$home/config/whatsapp.env"
  out=$(poll "$home")
  assert_absent "$TMP_ROOT/config-pwned" "config/whatsapp.env was sourced rather than read"
  pass "config/whatsapp.env is parsed as data, never sourced"
}

# --- the listener's accept and reject rules ---------------------------------

fixture() {
  local home=$1 body=$2
  printf '%s' "$body" | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth" \
    FM_WA_CAPTAIN="$CAPTAIN" FM_WA_ALLOW_DEVICES=0 \
    node "$LISTENER" handle-fixture 2>/dev/null
}

# Every fixture gets its own later timestamp. A shared one would let the history
# watermark short-circuit each case before the rule it names is ever reached, so
# the assertions below would pass for the wrong reason.
# The counter lives in a file because msg() is called inside a command
# substitution, and a shell variable bumped there would never reach the caller.
FIXTURE_TS_FILE="$TMP_ROOT/fixture-ts"
printf '2000000000\n' > "$FIXTURE_TS_FILE"
next_ts() {
  local n
  n=$(cat "$FIXTURE_TS_FILE" 2>/dev/null) || n=2000000000
  n=$(( n + 1 ))
  printf '%s\n' "$n" > "$FIXTURE_TS_FILE"
  printf '%s' "$n"
}

msg() {
  # msg <id> <device> <chat-jid> <from-me> <inner-json> [<timestamp>]
  printf '{"stanza_from":"%s:%s@s.whatsapp.net","message":{"key":{"id":"%s","remoteJid":"%s","fromMe":%s},"messageTimestamp":%s,"message":%s}}' \
    "$CAPTAIN" "$2" "$1" "$3" "$4" "${6:-$(next_ts)}" "$5"
}

# The listener logs its reason on the same stream as the verdict, so a refusal
# can be pinned to the rule that produced it rather than to REJECTED alone.
assert_refused() {
  local out=$1 reason=$2 what=$3
  assert_contains "$out" 'REJECTED' "$what"
  assert_contains "$out" "ignored ($reason)" \
    "$what: refused for the wrong reason, output was: $out"
}

test_listener_filters() {
  command -v node >/dev/null 2>&1 || { pass "listener filters skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/filters"
  new_home "$home"

  out=$(fixture "$home" "$(msg CAPMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"ship the fix"}')")
  assert_contains "$out" 'ACCEPTED' "a message from the captain's own phone was refused"
  assert_grep '"sender_device": 0' "$home/state/wa-inbox/CAPMSG.json" \
    "the stashed record lost the sending device"
  assert_grep 'ship the fix' "$home/state/wa-inbox/CAPMSG.json" \
    "the stashed record lost the message text"

  out=$(fixture "$home" "$(msg ECHOMSG 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the PR is up"}')")
  assert_refused "$out" 'device 2 is not an accepted captain device' \
    "firstmate's own outbound echo was ingested as an instruction"

  out=$(fixture "$home" "$(msg GRPMSG 0 '99-88@g.us' true '{"conversation":"in a group"}')")
  assert_refused "$out" "not the captain's direct chat" "a group message was ingested"

  out=$(fixture "$home" "$(msg FWDMSG 0 "$CAPTAIN@s.whatsapp.net" true \
    '{"extendedTextMessage":{"text":"do this","contextInfo":{"isForwarded":true,"forwardingScore":3}}}')")
  assert_refused "$out" 'forwarded message' "a forwarded message was ingested"

  out=$(fixture "$home" "$(printf '{"stanza_from":"447111111111:0@s.whatsapp.net","message":{"key":{"id":"OTHERMSG","remoteJid":"447111111111@s.whatsapp.net","fromMe":false},"messageTimestamp":%s,"message":{"conversation":"hi"}}}' "$(next_ts)")")
  assert_refused "$out" "not the captain's direct chat" \
    "a message from someone other than the captain was ingested"

  out=$(fixture "$home" "$(msg EMPTYMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"   "}')")
  assert_refused "$out" 'no text to act on' "an empty message was stashed"

  # A voice note with no caption is still the captain reaching out, and silence
  # on his phone reads as being ignored.
  out=$(fixture "$home" "$(msg VOICEMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"audioMessage":{"ptt":true,"seconds":7}}')")
  assert_contains "$out" 'ACCEPTED' "a caption-less voice note was silently discarded"
  assert_grep '"attachment": "audio"' "$home/state/wa-inbox/VOICEMSG.json" \
    "the stashed voice note did not name what kind of attachment it was"
  assert_grep '"text": ""' "$home/state/wa-inbox/VOICEMSG.json" \
    "the stashed voice note did not record that it carried no text"

  # Only history is older than the watermark; a second message in the same
  # second as an accepted one is a new instruction, not a redelivery.
  local same_second
  same_second=$(next_ts)
  out=$(fixture "$home" "$(msg SAMESEC1 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"first"}' "$same_second")")
  assert_contains "$out" 'ACCEPTED' "a fresh message was refused"
  out=$(fixture "$home" "$(msg SAMESEC2 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"and also this"}' "$same_second")")
  assert_contains "$out" 'ACCEPTED' "a second message in the same second was silently dropped"

  out=$(fixture "$home" "$(msg OLDMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"ancient"}' 1000000000)")
  assert_refused "$out" 'older than the history watermark' "backlog older than the watermark was ingested"

  pass "the listener accepts only the captain's own device on his own direct chat"
}

test_listener_is_idempotent() {
  command -v node >/dev/null 2>&1 || { pass "listener idempotence skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/idempotent"
  new_home "$home"

  local repeat_ts
  repeat_ts=$(next_ts)
  out=$(fixture "$home" "$(msg REPEATMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"once"}' "$repeat_ts")")
  assert_contains "$out" 'ACCEPTED' "the first delivery was refused"

  # Firstmate drains it, then WhatsApp redelivers the same message. The refusal
  # must come from the durable marker, not from the history watermark.
  rm -f "$home/state/wa-inbox/REPEATMSG.json"
  out=$(fixture "$home" "$(msg REPEATMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"once"}' "$repeat_ts")")
  assert_refused "$out" 'already handled' "a drained message was offered a second time"
  assert_absent "$home/state/wa-inbox/REPEATMSG.json" "a drained message was rebuilt in the inbox"

  pass "a handled message is never re-offered, even after the inbox entry is cleared"
}

test_listener_captures_quoted_context() {
  command -v node >/dev/null 2>&1 || { pass "quoted context skipped: node is unavailable"; return 0; }
  local home out record
  home="$TMP_ROOT/quoted"
  new_home "$home"

  out=$(fixture "$home" "$(msg QUOTEMSG 0 "$CAPTAIN@s.whatsapp.net" true \
    '{"extendedTextMessage":{"text":"yes do that","contextInfo":{"stanzaId":"EARLIER","quotedMessage":{"conversation":"shall I merge it?"}}}}')")
  assert_contains "$out" 'ACCEPTED' "a reply with quoted context was refused"
  record="$home/state/wa-inbox/QUOTEMSG.json"
  assert_grep 'shall I merge it' "$record" "the quoted message was dropped"
  assert_grep 'EARLIER' "$record" "the quoted message id was dropped"

  pass "a reply carries the message it replied to"
}

test_stale_echo_marker_does_not_swallow_the_captain() {
  command -v node >/dev/null 2>&1 || { pass "stale echo guard skipped: node is unavailable"; return 0; }
  local home out marker
  home="$TMP_ROOT/staleecho"
  new_home "$home"
  printf 'on it\n' > "$TMP_ROOT/stale-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/stale-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"
  marker=$(find "$home/state/wa-sent" -name '*.sent' -type f | head -n 1)
  [ -n "$marker" ] || fail "no echo marker was recorded"

  # An echo comes back in seconds. This one never did, so it is not an echo and
  # must not swallow the captain typing those same words much later.
  touch -t 200001010000 "$marker"
  out=$(fixture "$home" "$(msg STALEECHO 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"on it"}')")
  assert_contains "$out" 'ACCEPTED' "a stale outbound digest swallowed the captain's own words"
  assert_absent "$marker" "the stale digest was left behind to trap those words again"

  pass "an outbound digest the captain never echoed expires instead of trapping his words"
}

test_failed_send_leaves_no_echo_trap() {
  local home out
  home="$TMP_ROOT/failedsend"
  new_home "$home"
  printf 'this never left the building\n' > "$TMP_ROOT/failed-reply.txt"
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/failedsend-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/mudslide"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/failed-reply.txt" 2>&1) \
    && fail "a failing mudslide reported success: $out"

  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "a send that never went out left an echo marker behind"

  pass "a failed send leaves no digest to suppress the captain saying the same thing"
}

# mudslide parses its own arguments with commander, so a reply that opens with
# a dash is read as an unknown option and never reaches the captain unless
# option parsing is ended first.
test_a_dash_leading_reply_still_reaches_the_send() {
  local home out argv fakebin
  home="$TMP_ROOT/dashsend"
  new_home "$home"
  printf -- '- PR is up: https://example.invalid/pr/1\n' > "$TMP_ROOT/dash-reply.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/dashsend-bin")
  argv="$TMP_ROOT/dashsend-argv"
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
# Stands in for mudslide's commander parser: a dash-leading argument is an
# option until `--` ends option parsing.
ended=0
args=()
for a in "$@"; do
  if [ "$ended" -eq 0 ] && [ "$a" = "--" ]; then ended=1; continue; fi
  if [ "$ended" -eq 0 ]; then
    case "$a" in
      -*) echo "error: unknown option '$a'" >&2; exit 1 ;;
    esac
  fi
  args+=("$a")
done
printf '%s\n' "${args[@]}" > "$FAKE_MUDSLIDE_ARGV"
SH
  chmod +x "$fakebin/mudslide"

  out=$(PATH="$fakebin:$PATH" FAKE_MUDSLIDE_ARGV="$argv" FM_HOME="$home" \
    FM_ROOT_OVERRIDE="$ROOT" "$SEND" --text-file "$TMP_ROOT/dash-reply.txt" 2>&1) \
    || fail "a reply beginning with a dash was never sent: $out"

  [ -f "$argv" ] || fail "the send never reached mudslide"
  assert_contains "$(tail -n 1 "$argv")" '- PR is up: https://example.invalid/pr/1' \
    "the dash-leading reply did not arrive as message text"

  pass "a reply beginning with a dash reaches the send instead of being read as an option"
}

# A reply that never arrives is the one failure this channel cannot afford, so
# the send must say what mudslide said rather than only that it failed.
test_a_failed_send_says_why() {
  local home out fakebin
  home="$TMP_ROOT/sendwhy"
  new_home "$home"
  printf 'this never left the building\n' > "$TMP_ROOT/sendwhy-reply.txt"
  fakebin=$(fm_fakebin "$TMP_ROOT/sendwhy-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
echo "error: not logged in, run mudslide login" >&2
exit 1
SH
  chmod +x "$fakebin/mudslide"

  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SEND" --text-file "$TMP_ROOT/sendwhy-reply.txt" 2>&1) \
    && fail "a failing mudslide reported success: $out"

  assert_contains "$out" 'not logged in' "the failed send discarded the reason it failed"

  pass "a failed reply reports what mudslide said, not just that it failed"
}

test_failed_dry_run_leaves_no_echo_trap() {
  local home out
  home="$TMP_ROOT/faileddry"
  new_home "$home"
  printf 'this was never even going to be sent\n' > "$TMP_ROOT/faileddry-reply.txt"
  # An outbox that cannot be written to: nothing is recorded, so nothing can
  # echo back, and the marker must not survive to swallow those exact words.
  : > "$home/state/wa-outbox"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/faileddry-reply.txt" 2>&1) \
    && fail "a dry run that recorded nothing reported success: $out"

  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "a dry run that recorded nothing left an echo marker behind"

  pass "a dry run that could not record leaves no digest to swallow the captain"
}

test_echo_digest_guard() {
  command -v node >/dev/null 2>&1 || { pass "echo guard skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echoguard"
  new_home "$home"
  printf 'Captain, that is done.\n' > "$TMP_ROOT/echo-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echo-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  # Same text arriving back on an otherwise-accepted device must still be
  # recognised as firstmate's own words.
  out=$(fixture "$home" "$(msg ECHODIGEST 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, that is done."}')")
  assert_refused "$out" 'matches firstmate outbound' \
    "firstmate's own reply came back as a new instruction"

  # The marker is consumed, so the captain may genuinely say the same words next.
  out=$(fixture "$home" "$(msg ECHOAGAIN 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, that is done."}')")
  assert_contains "$out" 'ACCEPTED' "the echo guard permanently swallowed that wording"

  pass "an outbound reply coming back is dropped once, and only once"
}

# The echo firstmate's own reply produces arrives on mudslide's device, which
# the default sender-device filter rejects. If that rejection came first the
# digest marker would never be consumed by the echo it was written for, and it
# would sit out its whole ten-minute life waiting to swallow the captain typing
# those same words himself.
test_the_real_echo_consumes_its_own_marker() {
  command -v node >/dev/null 2>&1 || { pass "echo consumption skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echoconsume"
  new_home "$home"
  printf 'Captain, the PR is up.\n' > "$TMP_ROOT/echoconsume-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echoconsume-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  # Device 2 is mudslide: firstmate's own words coming back.
  out=$(fixture "$home" "$(msg REALECHO 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the PR is up."}')")
  assert_contains "$out" 'REJECTED' "firstmate's own reply came back as a new instruction"
  [ -z "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "the echo was dropped without consuming the digest it was written for"

  # So the captain saying the same thing straight afterwards is still heard.
  out=$(fixture "$home" "$(msg CAPSAME 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the PR is up."}')")
  assert_contains "$out" 'ACCEPTED' \
    "the captain's own words were swallowed by a digest his echo should have cleared"

  pass "firstmate's echo clears its own digest instead of leaving it as a trap"
}

# A stalled listener is reported AND repaired in the same cycle, so the poll
# carries on to the restart budget after speaking. Two fault lines in one cycle
# would break the one-line check contract, and a shared record would leave the
# specific report replaced by the generic one that came after it: the captain
# would be left holding a remedy that cannot fix what he was originally told
# about, and the dedupe that keeps a known fault quiet would be defeated.
test_two_faults_in_one_cycle_still_speak_once() {
  local home out lines first second
  home="$TMP_ROOT/doublefault"
  new_home "$home"
  fake_listener "$home"
  # Alive, but a connection that never came up: no beat, and a pid record old
  # enough to count as stalled.
  touch -t 200001010000 "$home/state/wa-listener.pid"
  # And a restart budget already spent, which is the next thing the cycle finds.
  printf '3\n' > "$home/state/wa-listener.restarts"

  out=$(poll "$home")
  lines=$(printf '%s' "$out" | grep -c . || true)
  [ "$lines" = 1 ] || fail "the cycle printed $lines lines instead of one: $out"
  first=$out
  assert_contains "$first" 'wa-channel-error' "the stalled listener was not reported"
  [ "$(cat "$home/state/wa-listener.error.never-up" 2>/dev/null)" = "${first#wa-channel-error }" ] \
    || fail "the recorded fault does not match the one that was reported"

  # The fault that lost the race is not lost: it is what the next cycle finds.
  second=$(poll "$home")
  lines=$(printf '%s' "$second" | grep -c . || true)
  [ "$lines" = 1 ] || fail "the following cycle printed $lines lines instead of one: $second"
  assert_contains "$second" 'will not stay healthy after restart' \
    "the spent restart budget was never reported"

  # Each fault keeps its own record, so the second one does not overwrite the
  # first: the specific report survives the generic one that followed it.
  [ "$(cat "$home/state/wa-listener.error.never-up" 2>/dev/null)" = "${first#wa-channel-error }" ] \
    || fail "the second fault overwrote the record of the first"
  [ "$(cat "$home/state/wa-listener.error.restart-latch" 2>/dev/null)" = "${second#wa-channel-error }" ] \
    || fail "the second fault was reported without being recorded in its own right"

  # And having been recorded truthfully, it is said once rather than every cycle.
  [ -z "$(poll "$home")" ] \
    || fail "the same fault was reported again instead of being deduped"

  pass "a cycle that finds two faults reports one, records it, and reports the other next"
}

# The digest is computed once in the shell and once in the listener, so the two
# normalizations have to agree on exactly which characters count as whitespace.
# A reply carrying a non-breaking space used to hash differently on each side,
# which left the echo unrecognised and the reply stashed as a fresh instruction.
test_echo_digest_normalization_matches() {
  command -v node >/dev/null 2>&1 || { pass "digest normalization skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echonorm"
  new_home "$home"
  printf 'Captain,\xc2\xa0that is done.\n' > "$TMP_ROOT/echo-nbsp.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echo-nbsp.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  out=$(fixture "$home" "$(msg ECHONBSP 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain,\u00a0that is done."}')")
  assert_refused "$out" 'matches firstmate outbound' \
    "a reply containing a non-breaking space came back as a new instruction"

  pass "the outbound digest matches the listener's on non-ASCII whitespace"
}

# A home snapshot that is sensitive to any file appearing, disappearing, or
# changing content: path plus mode plus a content digest for every regular file.
snapshot_home() {
  local home=$1
  ( cd "$home" && find . -mindepth 1 \( -type f -o -type d \) -print0 \
      | LC_ALL=C sort -z \
      | while IFS= read -r -d '' entry; do
          if [ -d "$entry" ]; then
            printf 'd %s\n' "$entry"
          else
            printf 'f %s %s\n' "$entry" "$(cksum < "$entry" | awk '{print $1"-"$2}')"
          fi
        done )
}

test_removing_the_config_restores_the_home_exactly() {
  local home before after out
  home="$TMP_ROOT/selfdisarm"
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  # A neighbouring home artifact that must survive: self-disarm removes only the
  # three files the channel generates, never anything else.
  printf 'export FM_CHECK_INTERVAL=30\n' > "$home/config/x-mode.env"
  printf 'unrelated\n' > "$home/state/keepme"

  before=$(snapshot_home "$home")

  printf 'FM_WA_CAPTAIN=%s\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"
  assert_present "$home/state/wa-watch.check.sh" "arm wrote no check shim"
  assert_present "$home/config/wa-mode.env" "arm wrote no cadence file"
  ( . "$ROOT/bin/fm-supervision-lib.sh"; fm_supervision_status "$home/state" >/dev/null 2>&1
    [ -n "${FM_SUP_NEEDED:-}" ] ) || fail "an armed home was not counted as needing supervision"

  # The documented opt-out, and one poll cycle to act on it.
  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the retiring cycle spoke: $out"

  assert_absent "$home/state/wa-watch.check.sh" "the check shim outlived the config"
  assert_absent "$home/state/wa-watch.check-trust" "the registration outlived the config"
  assert_absent "$home/config/wa-mode.env" "the cadence file outlived the config"
  assert_present "$home/config/x-mode.env" "self-disarm removed Relay's cadence file"
  assert_present "$home/state/keepme" "self-disarm removed an unrelated state file"

  after=$(snapshot_home "$home")
  [ "$before" = "$after" ] || {
    printf 'before/after differ:\n%s\n' "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") || true)" >&2
    fail "the home is not byte-identical to before the channel was armed"
  }

  # Idempotent: with everything already gone it does nothing and says nothing.
  out=$(poll "$home")
  [ -z "$out" ] || fail "a second retiring cycle spoke: $out"
  [ "$(snapshot_home "$home")" = "$before" ] || fail "a second retiring cycle changed the home"

  pass "removing config/whatsapp.env restores the home byte-for-byte and repeats safely"
}

# The captain's account has two identities and WhatsApp uses both: some
# deliveries of his self-chat are addressed to his phone number, others to his
# LID. Reproduced live - every real message he sent arrived under his LID and
# was refused as a non-direct chat, so state/wa-inbox stayed empty while he
# believed he was messaging firstmate.
#
# A LID is a real per-account WhatsApp identifier, so this one is invented for
# the tests, exactly as the number above is. A home's own LID is never
# configured: the listener reads it from its own pairing credentials.
CAPTAIN_LID=100000000000001

lid_fixture() {
  local home=$1 body=$2
  printf '%s' "$body" | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth" \
    FM_WA_CAPTAIN="$CAPTAIN" FM_WA_ALLOW_DEVICES=0 FM_WA_SELF_LID="$CAPTAIN_LID" \
    node "$LISTENER" handle-fixture 2>/dev/null
}

lid_msg() {
  # lid_msg <id> <chat-jid> <inner-json>
  printf '{"stanza_from":"%s:0@lid","message":{"key":{"id":"%s","remoteJid":"%s","fromMe":true},"messageTimestamp":%s,"message":%s}}' \
    "$CAPTAIN_LID" "$1" "$2" "$(next_ts)" "$3"
}

test_captain_reaches_us_under_either_identity() {
  command -v node >/dev/null 2>&1 || { pass "LID identity skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lid"
  new_home "$home"

  out=$(lid_fixture "$home" "$(lid_msg LIDMSG "$CAPTAIN_LID@lid" '{"conversation":"testing from the road"}')")
  assert_contains "$out" 'ACCEPTED' "the captain's LID self-chat was refused, so his real messages are dropped"
  assert_grep '"sender": "'"$CAPTAIN"'"' "$home/state/wa-inbox/LIDMSG.json"     "a LID-addressed message did not record the captain's number as the sender"
  assert_grep '"chat_identity": "lid"' "$home/state/wa-inbox/LIDMSG.json"     "the stashed record does not say which identity the chat used"

  # The same message under his phone-number identity must still work.
  out=$(fixture "$home" "$(msg PNMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"and from the desk"}')")
  assert_contains "$out" 'ACCEPTED' "the phone-number form regressed while adding the LID form"

  pass "the captain reaches firstmate under either of his two WhatsApp identities"
}

test_lid_acceptance_is_not_a_hole() {
  command -v node >/dev/null 2>&1 || { pass "LID security skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/lidsec"
  new_home "$home"

  out=$(lid_fixture "$home" "$(lid_msg LIDGRP '445566@g.us' '{"conversation":"group message"}')")
  assert_contains "$out" 'REJECTED' "a group message was accepted once LID chats were allowed"

  out=$(lid_fixture "$home" "$(lid_msg LIDSTRANGER '999888777666@lid' '{"conversation":"not the captain"}')")
  assert_contains "$out" 'REJECTED' "another user's LID was accepted as the captain"

  out=$(lid_fixture "$home" "$(lid_msg LIDCAST '1234@broadcast' '{"conversation":"broadcast"}')")
  assert_contains "$out" 'REJECTED' "a broadcast was accepted"

  # With no LID established from our own credentials there is nothing proving a
  # LID chat is his, so it must fail closed rather than be assumed.
  out=$(printf '%s' "$(lid_msg LIDNOSELF "$CAPTAIN_LID@lid" '{"conversation":"no identity known"}')"     | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth"       FM_WA_CAPTAIN="$CAPTAIN" FM_WA_ALLOW_DEVICES=0       node "$LISTENER" handle-fixture 2>/dev/null)
  assert_contains "$out" 'REJECTED' "a LID chat was accepted with no LID identity established"

  pass "accepting the captain's LID admits only him, never a group, broadcast or stranger"
}

test_off_by_default
test_removing_config_reverts_to_silence
test_check_contract
test_undrained_inbox_is_reannounced
test_an_unusable_entry_never_silences_the_rest
test_unpaired_listener_reports_once
test_channel_fault_and_inbox_never_share_a_cycle
test_logged_out_listener_is_reported
test_repeated_listener_exits_are_reported
test_stalled_listener_is_reported
test_stalled_listener_is_replaced_not_only_reported
test_a_listener_that_cannot_read_sender_devices_is_reported
test_a_skipped_entry_is_reported_on_a_quiet_cycle
test_slow_flap_still_reaches_the_restart_limit
test_outbound_digests_are_pruned
test_dry_run_records_are_pruned
test_a_spent_restart_block_releases_itself_after_a_while
test_a_hand_run_start_releases_the_restart_block
test_a_recycled_pid_is_never_signalled
test_a_listener_binding_survives_an_environment_change
test_a_replacement_is_not_judged_by_its_predecessor
test_a_restarted_listener_survives_the_check_being_reaped
test_a_refused_restart_says_why_in_the_log
test_listener_that_never_connects_is_reported
test_repairing_the_link_clears_stale_listener_health
test_listener_state_growth_is_bounded
test_shim_arm_register_disarm
test_removing_the_config_restores_the_home_exactly
test_arming_makes_an_idle_home_need_supervision
test_every_primary_arms_for_an_armed_channel
test_every_primary_arm_command_sources_the_cadence
test_arming_writes_the_watcher_cadence
test_the_cadence_reaches_the_supervision_block
test_stop_says_the_armed_check_restarts_it
test_shim_runs_the_poll_the_way_the_watcher_does
test_dry_run_records_and_sends_nothing
test_json_encoder_round_trips_hostile_text
test_dry_run_record_is_valid_json
test_message_text_is_never_executed
test_config_is_read_as_data
test_listener_filters
test_captain_reaches_us_under_either_identity
test_lid_acceptance_is_not_a_hole
test_listener_is_idempotent
test_listener_captures_quoted_context
test_echo_digest_guard
test_the_real_echo_consumes_its_own_marker
test_two_faults_in_one_cycle_still_speak_once
test_echo_digest_normalization_matches
test_stale_echo_marker_does_not_swallow_the_captain
test_failed_send_leaves_no_echo_trap
test_a_dash_leading_reply_still_reaches_the_send
test_a_failed_send_says_why
test_failed_dry_run_leaves_no_echo_trap

# --- switching the channel off cleans up after itself ------------------------

# The home-is-byte-identical test above never starts a listener, so it proves
# nothing about the thing that actually matters here: a listener left running is
# a live linked device on the captain's own personal account with nothing
# watching it. Every test below starts one first.

test_stopping_works_after_the_config_is_gone() {
  local home out pid
  home="$TMP_ROOT/optoutstop"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")

  # The documented opt-out done in the worst order: config first, commands after.
  rm -f "$home/config/whatsapp.env"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop 2>&1) \
    || fail "stop refused once the config it is tearing down was gone: $out"
  assert_contains "$out" 'listener stopped' "stop did not report stopping the listener"
  if kill -0 "$pid" 2>/dev/null; then
    fail "the listener survived a stop run after the config was removed"
  fi
  assert_absent "$home/state/wa-listener.pid" "stop left the pid file behind"

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" logs 5 >/dev/null 2>&1 \
    || fail "logs refused to read a listener log with the config gone"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" unpair 2>&1) \
    || fail "unpair refused once the config was gone: $out"
  assert_absent "$home/state/wa-auth" "unpair left this listener's credentials behind"

  pass "stop, logs and unpair still tear the channel down after the config is gone"
}

test_the_retiring_cycle_stops_the_listener() {
  local home out pid
  home="$TMP_ROOT/optoutpoll"
  new_home "$home"
  fake_listener "$home"
  pid=$(cat "$home/state/wa-listener.pid")
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  # No command is run at all. The config simply goes, which is the whole switch.
  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "the retiring cycle spoke while cleaning up normally: $out"

  if kill -0 "$pid" 2>/dev/null; then
    fail "the retiring cycle left the listener holding a linked device"
  fi
  assert_absent "$home/state/wa-listener.pid" "the retiring cycle left the pid file behind"
  assert_absent "$home/state/wa-watch.check.sh" "the retiring cycle left the check shim armed"

  pass "removing the config alone stops the listener as well as retiring the shim"
}

test_status_reports_a_stranded_listener() {
  local home out
  home="$TMP_ROOT/optoutstatus"
  new_home "$home"
  fake_listener "$home"

  rm -f "$home/config/whatsapp.env"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" status 2>&1)
  assert_contains "$out" 'channel: off' "status did not say the channel is off"
  assert_contains "$out" 'listener: running' \
    "status hid a listener that is still running, so a stranded one is invisible"

  pass "status still reports a running listener once the channel is off"
}

test_a_listener_this_home_does_not_own_is_never_signalled() {
  local home out pid
  home="$TMP_ROOT/optoutforeign"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  # An unrelated process holding the number a dead listener left behind, with an
  # identity that cannot be its own.
  sleep 300 &
  pid=$!
  FAKE_PIDS="$FAKE_PIDS $pid"
  printf '%s\n' "$pid" > "$home/state/wa-listener.pid"
  printf 'Sat Jan  1 00:00:00 2000\n' > "$home/state/wa-listener.pid-identity"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 || fail "arm failed"

  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  kill -0 "$pid" 2>/dev/null \
    || fail "the retiring cycle killed a process it never proved was its own listener"
  assert_contains "$out" 'wa-channel-error' \
    "the retiring cycle left an unclaimable listener record without saying so"
  assert_contains "$out" 'cannot prove' "the report did not name why nothing was signalled"
  assert_present "$home/state/wa-listener.pid" \
    "the retiring cycle discarded the record of a process it refused to signal"
  assert_absent "$home/state/wa-watch.check.sh" "the retiring cycle left the check shim armed"

  # The command path refuses for the same reason rather than guessing.
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$LISTEN_SH" stop >/dev/null 2>&1 \
    && fail "stop signalled a process it could not prove was this home's listener"
  kill -0 "$pid" 2>/dev/null \
    || fail "stop killed a process it could not prove was this home's listener"

  pass "a live process this home cannot claim is reported, never signalled"
}

# The listener and the shell library both decide whether a message id may become
# a path, and they have to decide it identically. When the listener was the more
# permissive of the two, a dot-leading id was stashed as a dotfile that `find`
# still lists and the drain's own glob never does, so the captain's message was
# dropped behind a fault line that could not even name it.
test_a_dot_leading_id_is_never_stashed() {
  command -v node >/dev/null 2>&1 || { pass "id rule agreement skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/dotid"
  new_home "$home"

  bash -c '. "$1"; fm_wa_id_safe ".HIDDEN"' _ "$LIB" \
    && fail "the shell library accepted a dot-leading id, so this test proves nothing"

  out=$(fixture "$home" "$(msg .HIDDEN 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"hidden"}')")
  assert_refused "$out" 'unsafe or missing message id' \
    "the listener stashed an id the poll would then refuse to use"
  assert_absent "$home/state/wa-inbox/.HIDDEN.json" \
    "a message record the drain's own glob can never see was created"

  pass "the listener and the shell library agree on which message ids are usable"
}

# A PATH holding every command this host has EXCEPT the two the digest helper
# knows about, so the poll runs for real on a host that cannot hash. Building it
# from the real PATH rather than a hand-picked list is what keeps the assertion
# honest: the poll has to get all the way to the digest to say anything at all.
path_without_sha256() {
  local dir=$1 entry name part
  mkdir -p "$dir"
  # shellcheck disable=SC2086 # PATH is a colon-separated list and is split on purpose.
  ( IFS=:; printf '%s\n' $PATH ) | while IFS= read -r part; do
    [ -n "$part" ] && [ -d "$part" ] || continue
    for entry in "$part"/*; do
      [ -f "$entry" ] && [ -x "$entry" ] || continue
      name=${entry##*/}
      case "$name" in
        sha256sum|shasum) continue ;;
      esac
      [ -e "$dir/$name" ] || ln -s "$entry" "$dir/$name" 2>/dev/null || true
    done
  done
}

# Total silence with the captain's messages sitting in the inbox is the one
# outcome this channel exists to prevent, so a host that cannot digest the
# pending set has to say why instead of exiting quietly forever.
test_a_host_that_cannot_hash_says_so() {
  local home out bin
  home="$TMP_ROOT/nosha"
  new_home "$home"
  fake_listener "$home"
  stash_message "$home" MSGNOSHA
  bin="$TMP_ROOT/nosha-bin"
  path_without_sha256 "$bin"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 \
    || { pass "digest failure skipped: this host has no digest tool to remove"; return 0; }

  out=$(PATH="$bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$POLL" 2>/dev/null)
  assert_contains "$out" 'wa-channel-error' \
    "a host that cannot digest the inbox went silent with a message pending"
  assert_contains "$out" 'sha256sum' "the report did not name what is missing"

  # ...and it is still deduped, so it is said once rather than every cycle.
  out=$(PATH="$bin" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$POLL" 2>/dev/null)
  [ -z "$out" ] || fail "the same digest fault was reported again instead of being deduped"

  pass "a host with no digest tool reports why instead of losing the inbox silently"
}

test_stopping_works_after_the_config_is_gone
test_the_retiring_cycle_stops_the_listener
test_status_reports_a_stranded_listener
test_a_listener_this_home_does_not_own_is_never_signalled
test_a_dot_leading_id_is_never_stashed
test_a_host_that_cannot_hash_says_so
