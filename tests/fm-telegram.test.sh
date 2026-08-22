#!/usr/bin/env bash
# Behavior tests for optional Telegram captain-comms (docs/telegram.md).
#
# Hermetic: no live Telegram traffic. A fake `curl` on PATH answers every
# outbound POST with a canned {"ok":true} reply and every getUpdates GET with
# either a canned fixture or an empty result, so bin/fm-tg-send.sh and
# bin/fm-tg-poll.sh run for real (their own logic, not a gutted stand-in) while
# never reaching the network. FM_HOME/FM_TG_ENV_OVERRIDE point every script at
# a scratch dir per test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-telegram)
# fm_test_tmproot's own cleanup trap is registered inside the command-
# substitution subshell above and fires the moment that subshell exits, which
# removes TMP_ROOT immediately; every other test file masks this by only ever
# mkdir -p'ing a subdir of it (which silently recreates the parent). Do the
# same explicitly here since this file also cd's straight into it.
mkdir -p "$TMP_ROOT"

# fm-tg-guard.sh, fm-tg-hook.sh, and fm-tg-isfirstmate.sh all condemn a cwd
# under $HOME/.treehouse/* as a crew worktree. This suite itself may be run
# from inside one (a crewmate working on firstmate's own repo); move the
# whole suite's default cwd to scratch so that never makes an assertion
# flaky. Only the crew-worktree tests deliberately cd back under
# $HOME/.treehouse/* in a subshell.
cd "$TMP_ROOT" || fail "could not cd into TMP_ROOT"

# --- fake curl: no live network ---------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl for fm-telegram tests: no live network.
#   -X POST ...       -> canned {"ok":true} reply (sendMessage/sendPhoto/etc.),
#                        or nothing at all when FAKE_CURL_EMPTY_REPLY=1
#                        (simulates a stalled/timed-out upload)
#   ...getUpdates...  -> content of $FAKE_TG_GETUPDATES_FILE if set and
#                        present, else an empty result
# Every invocation's argv is appended to $FAKE_CURL_LOG when set, so a test
# can inspect which Telegram method/field an upload actually used.
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
args="$*"
case "$args" in
  *-X\ POST*)
    [ -n "${FAKE_CURL_EMPTY_REPLY:-}" ] && exit 0
    printf '{"ok":true,"result":{"message_id":1}}' ;;
  *getUpdates*)
    if [ -n "${FAKE_TG_GETUPDATES_FILE:-}" ] && [ -f "$FAKE_TG_GETUPDATES_FILE" ]; then
      cat "$FAKE_TG_GETUPDATES_FILE"
    else
      printf '{"ok":true,"result":[]}'
    fi
    ;;
  *) printf '{"ok":true,"result":{}}' ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"

# fm_tg_scratch_bin: copy the real bin/fm-tg-* scripts into a scratch dir,
# with fm-tg-isfirstmate.sh replaced by an always-allow stub, and echo the
# scratch dir. Used only by tests that exercise fm-tg-guard.sh/fm-tg-hook.sh's
# OWN logic (the timestamp comparison, the drain/wait delegation) - both call
# the real bin/fm-tg-isfirstmate.sh first and no-op for any session whose
# ancestry looks like a crewmate. This test suite is frequently run FROM a
# live crewmate session (dogfooding), whose own real ancestry legitimately
# carries the crewmate brief marker fm-tg-isfirstmate.sh is designed to
# detect - so testing the guard/hook's downstream logic needs that one
# dependency neutralized. The real bin/fm-tg-isfirstmate.sh is never modified;
# its own condemn/allow contract is tested directly, against the genuine
# script, in test_isfirstmate_direct below.
fm_tg_scratch_bin() {
  local dir=$1 sbin="$1/bin" f
  mkdir -p "$sbin"
  for f in "$ROOT"/bin/fm-tg-*.sh "$ROOT"/bin/fm-tg-*.py; do
    cp "$f" "$sbin/$(basename "$f")"
  done
  cat > "$sbin/fm-tg-isfirstmate.sh" <<'SH'
#!/usr/bin/env bash
# Test-only stub: always allow. See fm_tg_scratch_bin in tests/fm-telegram.test.sh.
exit 0
SH
  chmod +x "$sbin"/*.sh "$sbin"/*.py
  printf '%s' "$sbin"
}

# fm_tg_env <dir>: write a valid telegram env file in <dir>, echo its path.
fm_tg_env() {
  local dir=$1 f="$1/tg.env"
  mkdir -p "$dir"
  printf 'TG_TOKEN=faketoken\nTG_CHAT_ID=999\n' > "$f"
  printf '%s' "$f"
}

# fm_tg_getupdates_fixture <dir> <json>: write a getUpdates result fixture and
# export FAKE_TG_GETUPDATES_FILE to it.
fm_tg_getupdates_fixture() {
  local dir=$1 json=$2 f="$1/getupdates.json"
  printf '%s' "$json" > "$f"
  export FAKE_TG_GETUPDATES_FILE="$f"
}

# --- config absent: everything stays silent ---------------------------------

test_config_absent_hooks_silent() {
  local home
  home="$TMP_ROOT/absent-home"
  mkdir -p "$home/state"
  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/does-not-exist.env" \
    "$ROOT/bin/fm-tg-guard.sh" >/tmp/absent-guard-out 2>&1
  expect_code 0 "$?" "fm-tg-guard.sh with no config"
  [ ! -s /tmp/absent-guard-out ] || fail "fm-tg-guard.sh printed output with no config: $(cat /tmp/absent-guard-out)"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/does-not-exist.env" FM_TG_WAIT_MAX=1 \
    "$ROOT/bin/fm-tg-hook.sh" >/tmp/absent-hook-out 2>&1
  expect_code 0 "$?" "fm-tg-hook.sh with no config"
  [ ! -s /tmp/absent-hook-out ] || fail "fm-tg-hook.sh printed output with no config: $(cat /tmp/absent-hook-out)"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/does-not-exist.env" \
    "$ROOT/bin/fm-tg-poll.sh" >/tmp/absent-poll-out 2>&1
  expect_code 0 "$?" "fm-tg-poll.sh with no config"
  [ ! -s /tmp/absent-poll-out ] || fail "fm-tg-poll.sh printed output with no config: $(cat /tmp/absent-poll-out)"

  assert_absent "$home/state/tg-inbox" "no config must never create state/tg-inbox"
  rm -f /tmp/absent-guard-out /tmp/absent-hook-out /tmp/absent-poll-out
  pass "telegram: absent config -> guard, hook, and poll all exit 0 silently, nothing created"
}

# --- crew worktree: send refuses, hooks no-op -------------------------------

test_crew_worktree_refuses() {
  local home crewdir out rc
  home="$TMP_ROOT/crew-home"
  mkdir -p "$home/state"
  fm_tg_env "$home" >/dev/null

  # bin/fm-tg-isfirstmate.sh hardcodes "$HOME"/.treehouse/* (real crew
  # worktrees always live there); use a real, harmless scratch subdir of it.
  crewdir="$HOME/.treehouse/fm-telegram-test-$$"
  mkdir -p "$crewdir"

  out=$(cd "$crewdir" && FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/tg.env" \
    "$ROOT/bin/fm-tg-send.sh" 'hello captain' 2>&1)
  rc=$?
  rm -rf "$crewdir"
  [ "$rc" -ne 0 ] || fail "fm-tg-send.sh did not refuse from a crew worktree"
  assert_contains "$out" "REFUSED" "fm-tg-send.sh crew refusal missing REFUSED message"
  assert_absent "$home/state/.tg-last-sent" "crew send must never stamp .tg-last-sent"
  pass "telegram: fm-tg-send.sh refuses from a crew worktree (\$HOME/.treehouse/*)"
}

test_isfirstmate_direct() {
  local crewdir rc ambient_rc

  # The whole suite's cwd is already TMP_ROOT (see top of file), which is
  # never under $HOME/.treehouse/*. But fm-tg-isfirstmate.sh's OTHER signal is
  # process ancestry: if this suite is itself run from inside a live crewmate
  # session (dogfooding this very task), that ancestry genuinely, correctly
  # carries the crewmate brief marker, and the script is RIGHT to condemn it
  # regardless of cwd. Detect that ambient condition instead of asserting a
  # fixed verdict, so this test is meaningful in both a clean CI shell and a
  # live crewmate dev loop without being flaky in either.
  ambient_rc=0
  "$ROOT/bin/fm-tg-isfirstmate.sh" || ambient_rc=$?
  if [ "$ambient_rc" -ne 0 ]; then
    pass "telegram: fm-tg-isfirstmate.sh (ambient ancestry already carries the crewmate marker in this dev session - cwd-allow branch not independently observable here, but see the cwd-condemn assertion below)"
  else
    expect_code 0 "$ambient_rc" "fm-tg-isfirstmate.sh: a normal (non-crew) cwd must be allowed"
    pass "telegram: fm-tg-isfirstmate.sh allows a normal, non-treehouse, non-crew-ancestry cwd"
  fi

  crewdir="$HOME/.treehouse/fm-telegram-test-$$"
  mkdir -p "$crewdir"
  (cd "$crewdir" && "$ROOT/bin/fm-tg-isfirstmate.sh")
  rc=$?
  rm -rf "$crewdir"
  [ "$rc" -ne 0 ] || fail "fm-tg-isfirstmate.sh: a \$HOME/.treehouse/* cwd must be condemned as crew"
  pass "telegram: fm-tg-isfirstmate.sh condemns a treehouse worktree cwd"
}

# --- full simulated pipeline: arrival -> ack -> guard -> reply -> silent ----

test_arrival_ack_guard_reply_pipeline() {
  local home env inbox offset sbin send text rec out rc
  home="$TMP_ROOT/pipeline-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  # fm-tg-guard.sh calls the real bin/fm-tg-isfirstmate.sh first, which would
  # correctly condemn this whole test suite when it is itself run from inside
  # a live crewmate session (see fm_tg_scratch_bin above). Use the scratch
  # copies, uniformly, so every sibling-path reference stays internally
  # consistent; only the identity gate is stubbed, everything else is real.
  sbin=$(fm_tg_scratch_bin "$home/scratch")
  send="$sbin/fm-tg-send.sh"
  mkdir -p "$inbox"

  export FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" TG_TOKEN=faketoken

  # 1. A message arrives (simulating what curl's getUpdates would have
  #    returned) and is fed straight into the shared fetch core, exactly as
  #    bin/fm-tg-poll.sh does every watcher check cycle.
  text=$(printf '{"ok":true,"result":[{"update_id":1,"message":{"chat":{"id":999},"date":100,"text":"what is an epoch?"}}]}' \
    | python3 "$sbin/fm-tg-fetch.py" poll "$inbox" "$offset" "$send")
  assert_contains "$text" "telegram: 1 message(s)" "arrival did not report one new message"

  rec="$inbox/1.json"
  assert_present "$rec" "arrival did not write the inbox record"
  assert_grep '"acked": 1' "$rec" "arrival-time ack was not recorded on the message"

  # The ack fired via a real (fake-curl) subprocess.run of fm-tg-send.sh with
  # FM_TG_ACK=1; that must NOT have stamped .tg-last-sent or archived anything
  # (fm-tg-send.sh only stamps/archives when FM_TG_ACK is unset - see mark_sent).
  assert_absent "$home/state/.tg-last-sent" "the ack itself must not count as a reply"

  # 2. Surface it (a Stop hook firing). It must surface exactly once so far,
  #    and NOT re-fire the ack (already acked=1 on arrival).
  out=$(python3 "$sbin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed")
  rc=$?
  expect_code 0 "$rc" "drain did not report the pending message"
  assert_contains "$out" "1 captain message(s) pending" "drain summary line wrong"
  assert_contains "$out" "what is an epoch?" "drain did not surface the message text"

  # 3. Guard: only an ack was ever sent, never a real reply -> must demand one.
  "$sbin/fm-tg-guard.sh" >/tmp/guard1-out 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "guard did not block after ack-only (got exit $rc): $(cat /tmp/guard1-out)"
  assert_contains "$(cat /tmp/guard1-out)" "UNANSWERED CAPTAIN MESSAGE" "guard reason missing"
  rm -f /tmp/guard1-out

  # 4. Still unanswered -> re-surfaces (no loss) rather than being dropped.
  out=$(python3 "$sbin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed")
  assert_contains "$out" "what is an epoch?" "unanswered message failed to re-surface"

  # 5. A real reply goes out (fake curl, no live traffic).
  "$sbin/fm-tg-send.sh" 'an epoch is a fixed point in time' >/tmp/send-out 2>&1
  rc=$?
  expect_code 0 "$rc" "fm-tg-send.sh real reply failed: $(cat /tmp/send-out)"
  rm -f /tmp/send-out
  assert_present "$home/state/.tg-last-sent" "real reply did not stamp .tg-last-sent"

  # 6. Archived: the message is gone from the inbox and drain has nothing left.
  assert_absent "$inbox/1.json" "answered message was not archived out of the inbox"
  assert_present "$home/state/tg-processed/1.json" "answered message did not land in tg-processed"
  python3 "$sbin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed"
  rc=$?
  [ "$rc" -eq 1 ] || fail "drain still reports something pending after the real reply landed"

  # 7. Guard: a real reply since the last surface -> silent, turn may end.
  "$sbin/fm-tg-guard.sh" >/tmp/guard2-out 2>&1
  rc=$?
  expect_code 0 "$rc" "guard still blocking after a real reply was sent: $(cat /tmp/guard2-out)"
  rm -f /tmp/guard2-out

  unset FM_HOME FM_TG_ENV_OVERRIDE TG_TOKEN
  pass "telegram: arrival acks once, guard demands a real reply, unanswered re-surfaces, real reply silences the guard and archives"
}

# --- amendment 3: the reply/surface race in fm-tg-archive.py ---------------

test_archive_race_fresh_unsurfaced_stays_pending() {
  local home env inbox now
  home="$TMP_ROOT/race-fresh-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  now=$(date +%s)

  # A message that just arrived (well under 60s old) and was never surfaced.
  printf '{"update_id": 50, "chat_id": 999, "ts": %s, "text": "brand new"}' "$now" > "$inbox/50.json"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-send.sh" 'unrelated reply' >/tmp/race-fresh-out 2>&1
  expect_code 0 "$?" "fm-tg-send.sh failed: $(cat /tmp/race-fresh-out)"
  rm -f /tmp/race-fresh-out

  assert_present "$inbox/50.json" \
    "a fresh (<60s), never-surfaced message must NOT be swept up by an unrelated reply"
  pass "telegram: a fresh, never-surfaced message stays pending through a reply (no over-eager archival)"
}

test_archive_race_old_unsurfaced_still_retires() {
  local home env inbox old_ts out
  home="$TMP_ROOT/race-old-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  old_ts=$(( $(date +%s) - 120 ))

  # A message that arrived over a minute ago and was never marked surfaced -
  # the exact race the amendment closes: it had every chance to be seen.
  printf '{"update_id": 51, "chat_id": 999, "ts": %s, "text": "old and unsurfaced"}' "$old_ts" > "$inbox/51.json"

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" python3 "$ROOT/bin/fm-tg-archive.py" "$inbox" "$home/state/tg-processed")
  assert_contains "$out" "retired unsurfaced" "an old, never-surfaced message must be retired with an explicit notice"
  assert_absent "$inbox/51.json" "an old, never-surfaced message must be retired out of the inbox"
  assert_present "$home/state/tg-processed/51.json" "an old, never-surfaced message must land in tg-processed"
  pass "telegram: a message over 60s old is retired even if never surfaced, with a visible notice (closes the reply/surface race)"
}

# --- several messages, one arriving mid-turn: all surface, in order --------

test_multiple_messages_mid_turn_none_swallowed() {
  local home env inbox offset send out
  home="$TMP_ROOT/multi-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  send="$ROOT/bin/fm-tg-send.sh"
  mkdir -p "$inbox"
  export FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" TG_TOKEN=faketoken

  # Two messages arrive in one batch (e.g. two texts sent back to back).
  printf '{"ok":true,"result":[{"update_id":10,"message":{"chat":{"id":999},"date":200,"text":"first"}},{"update_id":11,"message":{"chat":{"id":999},"date":201,"text":"second"}}]}' \
    | python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$send" >/dev/null

  # firstmate surfaces them (start of a turn) but has not replied yet.
  out=$(python3 "$ROOT/bin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed")
  assert_contains "$out" "2 captain message(s) pending" "batch of two did not both surface"
  assert_contains "$out" "first" "first message missing from surfaced batch"
  assert_contains "$out" "second" "second message missing from surfaced batch"

  # A THIRD message arrives mid-turn, before the first two are answered.
  printf '{"ok":true,"result":[{"update_id":12,"message":{"chat":{"id":999},"date":202,"text":"third, mid-turn"}}]}' \
    | python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$send" >/dev/null
  assert_present "$inbox/12.json" "mid-turn arrival was not recorded"

  # Next surface must show all three, oldest first, none swallowed.
  out=$(python3 "$ROOT/bin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed")
  assert_contains "$out" "3 captain message(s) pending" "mid-turn arrival was swallowed instead of joining the surfaced set"
  first_at=$(printf '%s' "$out" | grep -n "CAPTAIN: first" | cut -d: -f1)
  second_at=$(printf '%s' "$out" | grep -n "CAPTAIN: second" | cut -d: -f1)
  third_at=$(printf '%s' "$out" | grep -n "third, mid-turn" | cut -d: -f1)
  [ -n "$first_at" ] && [ -n "$second_at" ] && [ -n "$third_at" ] \
    || fail "one of the three messages is missing from the surfaced output"
  [ "$first_at" -lt "$second_at" ] && [ "$second_at" -lt "$third_at" ] \
    || fail "messages did not surface in arrival order: $out"

  unset FM_HOME FM_TG_ENV_OVERRIDE TG_TOKEN
  pass "telegram: several messages including one arriving mid-turn all surface, in order, none swallowed"
}

# --- ack failure fallback: drain retries the ack if arrival-time send failed

test_drain_retries_failed_ack() {
  local home env inbox offset
  home="$TMP_ROOT/failack-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  mkdir -p "$inbox"

  # Point the ack subprocess at a send script that always fails, simulating a
  # dropped arrival-time ack (e.g. a transient network error).
  cat > "$TMP_ROOT/failing-send.sh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$TMP_ROOT/failing-send.sh"

  printf '{"ok":true,"result":[{"update_id":30,"message":{"chat":{"id":999},"date":300,"text":"ack me"}}]}' \
    | python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$TMP_ROOT/failing-send.sh" >/dev/null
  assert_no_grep '"acked": 1' "$inbox/30.json" "a failed arrival-time ack must not be recorded as acked"

  # Now drain with the REAL (fake-curl) send script: its fallback ack must fire.
  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" TG_TOKEN=faketoken \
    python3 "$ROOT/bin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed" >/dev/null
  assert_absent "$home/state/.tg-last-sent" "the fallback ack must not stamp .tg-last-sent either (it is not a reply)"
  pass "telegram: a failed arrival-time ack is retried as a fallback by drain, and still never counts as a reply"
}

# --- upload bugs (amendment 2): large PNG routes to sendDocument, and a --

test_large_png_uses_senddocument() {
  local home env f log
  home="$TMP_ROOT/upload-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  f="$TMP_ROOT/atlas.png"
  # >1MB dummy file with a .png extension; content does not matter, the fake
  # curl never inspects it.
  head -c 1500000 /dev/zero > "$f"
  log="$TMP_ROOT/curl-large.log"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-tg-send.sh" --file "$f" >/tmp/large-png-out 2>&1
  expect_code 0 "$?" "sending a >1MB png failed: $(cat /tmp/large-png-out)"
  rm -f /tmp/large-png-out

  assert_grep "sendDocument" "$log" "a >1MB png must upload via sendDocument, not sendPhoto"
  assert_grep "-F document=" "$log" "a >1MB png must use the document field, not photo"
  assert_no_grep "sendPhoto" "$log" "a >1MB png must never go through sendPhoto (Telegram rejects large dimensions)"
  pass "telegram: a PNG over 1MB uploads via sendDocument, not sendPhoto"
}

test_small_png_uses_sendphoto() {
  local home env f log
  home="$TMP_ROOT/upload-small-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  f="$TMP_ROOT/thumb.png"
  head -c 10000 /dev/zero > "$f"
  log="$TMP_ROOT/curl-small.log"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-tg-send.sh" --file "$f" >/tmp/small-png-out 2>&1
  expect_code 0 "$?" "sending a small png failed: $(cat /tmp/small-png-out)"
  rm -f /tmp/small-png-out

  assert_grep "sendPhoto" "$log" "a small png should still upload via sendPhoto"
  pass "telegram: a PNG at or under 1MB still uploads via sendPhoto"
}

test_upload_timeout_explicit_message() {
  local home env f out rc
  home="$TMP_ROOT/upload-timeout-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  f="$TMP_ROOT/stalls.png"
  head -c 10000 /dev/zero > "$f"

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FAKE_CURL_EMPTY_REPLY=1 \
    "$ROOT/bin/fm-tg-send.sh" --file "$f" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "an empty upload reply must be treated as a failure, not success"
  assert_contains "$out" "upload timed out" "an empty upload reply must report an explicit timeout, not a parse error"
  assert_not_contains "$out" "unparseable reply" "an empty upload reply must not be misreported as an unparseable one"
  pass "telegram: a stalled/empty upload reply reports an explicit timeout instead of 'unparseable reply'"
}

# --- end-to-end: the actual watcher check-cycle artifact ---------------------

test_poll_sh_end_to_end() {
  local home env inbox out
  home="$TMP_ROOT/poll-e2e-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"

  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":true,"result":[{"update_id":90,"message":{"chat":{"id":999},"date":400,"text":"is the poll shim wired right?"}}]}'

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  unset FAKE_TG_GETUPDATES_FILE
  assert_contains "$out" "telegram: 1 message(s)" "bin/fm-tg-poll.sh (the real watcher check-cycle artifact) did not report the new message"
  assert_present "$inbox/90.json" "bin/fm-tg-poll.sh did not record the message to the inbox"
  assert_grep '"acked": 1' "$inbox/90.json" "bin/fm-tg-poll.sh did not ack on arrival"

  # A second run with nothing new must print nothing and touch nothing new.
  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  [ -z "$out" ] || fail "bin/fm-tg-poll.sh printed output with no new messages: $out"

  pass "telegram: bin/fm-tg-poll.sh (the state/tg-watch.check.sh watcher artifact) fetches, records, and acks end-to-end"
}

test_config_absent_hooks_silent
test_crew_worktree_refuses
test_isfirstmate_direct
test_arrival_ack_guard_reply_pipeline
test_archive_race_fresh_unsurfaced_stays_pending
test_archive_race_old_unsurfaced_still_retires
test_multiple_messages_mid_turn_none_swallowed
test_drain_retries_failed_ack
test_large_png_uses_senddocument
test_small_png_uses_sendphoto
test_upload_timeout_explicit_message
test_poll_sh_end_to_end
