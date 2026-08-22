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

# The identity gate condemns a cwd that git reports as a linked worktree
# (fm_dir_is_child_worktree, via bin/fm-tg-isfirstmate.sh), and bin/fm-tg-send.sh
# additionally condemns the literal $HOME/.treehouse/* lease path. This suite is
# routinely run from inside a linked worktree - a crewmate working on firstmate's
# own repo, or a validation worktree - so move the whole suite's default cwd to
# scratch, which is neither, so that never makes an assertion flaky. Only the
# crew-worktree tests deliberately cd back into a condemned location, in a
# subshell.
cd "$TMP_ROOT" || fail "could not cd into TMP_ROOT"

# --- fake curl: no live network ---------------------------------------------

FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl for fm-telegram tests: no live network.
#   -X POST ...       -> canned {"ok":true} reply (sendMessage/sendPhoto/etc.),
#                        or nothing at all when FAKE_CURL_EMPTY_REPLY=1
#                        (simulates a stalled/timed-out upload)
#                        or a canned {"ok":false,...} REJECTION when
#                        FAKE_CURL_REJECT=1 (a genuine bad request, never retried)
#                        or nothing for the first N calls, then success, when
#                        FAKE_CURL_FAIL_COUNTER points at a file holding N
#                        (simulates N transient network blips then recovery)
#   ...getUpdates...  -> content of $FAKE_TG_GETUPDATES_FILE if set and
#                        present, else an empty result
# Every invocation's argv is appended to $FAKE_CURL_LOG when set, so a test
# can inspect which Telegram method/field an upload actually used, or count
# retry attempts.
[ -n "${FAKE_CURL_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_CURL_LOG"
args="$*"
case "$args" in
  *-X\ POST*)
    [ -n "${FAKE_CURL_EMPTY_REPLY:-}" ] && exit 0
    if [ -n "${FAKE_CURL_REJECT:-}" ]; then
      printf '{"ok":false,"description":"Bad Request: fake rejection","error_code":400}'
      exit 0
    fi
    if [ -n "${FAKE_CURL_FAIL_COUNTER:-}" ] && [ -f "$FAKE_CURL_FAIL_COUNTER" ]; then
      remaining=$(cat "$FAKE_CURL_FAIL_COUNTER")
      if [ "$remaining" -gt 0 ]; then
        echo $(( remaining - 1 )) > "$FAKE_CURL_FAIL_COUNTER"
        exit 0
      fi
    fi
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
# the real bin/fm-tg-isfirstmate.sh first and no-op when it condemns the
# session. This suite is routinely run FROM a linked worktree (a crewmate
# working on firstmate's own repo, or a validation worktree), which that script
# correctly refuses, so testing the guard/hook's downstream logic at all needs
# that one dependency neutralized. The real bin/fm-tg-isfirstmate.sh is never
# modified; its own condemn/allow contract is tested directly, against the
# genuine script, in test_isfirstmate_direct below.
fm_tg_scratch_bin() {
  local dir=$1 sbin="$1/bin" f
  mkdir -p "$sbin"
  for f in "$ROOT"/bin/fm-tg-*.sh "$ROOT"/bin/fm-tg-*.py "$ROOT"/bin/fm_tg_records.py \
    "$ROOT"/bin/fm-primary-scope-lib.sh "$ROOT"/bin/fm-hook-host-lib.sh \
    "$ROOT"/bin/fm-timeout-lib.sh "$ROOT"/bin/fm-wake-lib.sh; do
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

# fm_tg_path_without_timeout <dir>: build a PATH that has every command this
# host offers EXCEPT `timeout` and `gtimeout`, and echo it. That is macOS's base
# install, which ships neither, and it is the only way to actually exercise what
# a bare `timeout` does there rather than assume it.
fm_tg_path_without_timeout() {
  local farm=$1/no-timeout-path d f b
  if [ ! -d "$farm" ]; then
    mkdir -p "$farm"
    for d in $(printf '%s' "$PATH" | tr ':' ' '); do
      [ -d "$d" ] || continue
      for f in "$d"/*; do
        b=${f##*/}
        case "$b" in timeout|gtimeout) continue ;; esac
        [ -e "$farm/$b" ] || ln -s "$f" "$farm/$b" 2>/dev/null || true
      done
    done
  fi
  printf '%s' "$FAKEBIN:$farm"
}

# fm_tg_file_mode <path>: the file's permission bits, portably (macOS stat has
# no -c). Echoes nothing when the path cannot be read.
fm_tg_file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# fm_tg_getupdates_fixture <dir> <json>: write a getUpdates result fixture and
# export FAKE_TG_GETUPDATES_FILE to it.
fm_tg_getupdates_fixture() {
  local dir=$1 json=$2 f="$1/getupdates.json"
  printf '%s' "$json" > "$f"
  export FAKE_TG_GETUPDATES_FILE="$f"
}

# --- bootstrap arms a shim the watcher will actually run --------------------

test_bootstrap_registers_poll_shim() {
  local home env

  home="$TMP_ROOT/arm-home"
  mkdir -p "$home/state" "$home/config"
  env=$(fm_tg_env "$home")

  # Only the local telegram_setup sweep is under test here. Without the skip the
  # run reaches bootstrap's network phase and calls `gh auth status` plus the
  # fleet-sync and secondmate sweeps against this host's real credentials.
  FM_BOOTSTRAP_NETWORK=skip FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" \
    "$ROOT/bin/fm-bootstrap.sh" >"$TMP_ROOT/arm-out" 2>&1
  assert_grep "TELEGRAM: on" "$TMP_ROOT/arm-out" "bootstrap did not arm Telegram for a configured home"
  assert_present "$home/state/tg-watch.check.sh" "bootstrap did not write the poll shim"
  assert_present "$home/config/tg-mode.env" "bootstrap did not write the cadence config"
  assert_grep "export FM_CHECK_INTERVAL=30" "$home/config/tg-mode.env" "cadence must be 30s"

  # The whole point: an unregistered shim is never executed by the watcher and
  # is reported as an unauthenticated check on every single cycle instead.
  # This is exactly the predicate bin/fm-watch.sh dispatches on.
  ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$home/state" tg-watch ) \
    || fail "the armed poll shim is not byte-registered, so the watcher would refuse to run it"

  # The shim must carry an ABSOLUTE FM_HOME: it runs from the watcher's cwd.
  assert_grep "export FM_HOME=/" "$home/state/tg-watch.check.sh" "the shim's FM_HOME must be absolute"

  # Opt-out clears the binding as well as the shim, so nothing stale is left
  # authorising an execution.
  printf 'TG_TOKEN=\nTG_CHAT_ID=\n' > "$env"
  FM_BOOTSTRAP_NETWORK=skip FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" \
    "$ROOT/bin/fm-bootstrap.sh" >"$TMP_ROOT/disarm-out" 2>&1
  assert_grep "TELEGRAM: off" "$TMP_ROOT/disarm-out" "bootstrap did not report the disarm"
  assert_absent "$home/state/tg-watch.check.sh" "opt-out must remove the poll shim"
  assert_absent "$home/state/tg-watch.check-trust" "opt-out must remove the shim's byte binding"
  assert_absent "$home/config/tg-mode.env" "opt-out must remove the cadence config"
  rm -f "$TMP_ROOT/arm-out" "$TMP_ROOT/disarm-out"
  pass "telegram: bootstrap arms AND registers state/tg-watch.check.sh, and opt-out clears the binding too"
}

test_cadence_config_is_actually_usable() {
  local home out

  # Sourcing the generated cadence ahead of an arm has to be an APPROVED setup
  # node, or the documented "source it before arming" instruction is denied by
  # the repo's own arm policy and the home silently stays on the 300s cadence.
  out=$("$ROOT/bin/fm-arm-pretool-check.sh" \
    --command 'source config/tg-mode.env; bin/fm-watch-arm.sh' --claude 2>&1 || true)
  assert_not_contains "$out" '"permissionDecision":"deny"' \
    "the arm policy must allow sourcing config/tg-mode.env before an arm"

  out=$("$ROOT/bin/fm-arm-pretool-check.sh" \
    --command "source '/tmp/not-this-home/config/tg-mode.env'; bin/fm-watch-arm.sh" --claude 2>&1 || true)
  assert_contains "$out" '"permissionDecision":"deny"' \
    "a cadence path outside the active home must still be denied"

  # And the emitted supervision block must name it, so the cadence is inherited
  # by whatever actually starts the watcher.
  home="$TMP_ROOT/cadence-home"
  mkdir -p "$home/state" "$home/config"
  : > "$home/config/tg-mode.env"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-supervision-instructions.sh" --harness claude --repair-line)
  assert_contains "$out" "source '$home/config/tg-mode.env' first" \
    "the repair line must source the Telegram cadence config"
  pass "telegram: config/tg-mode.env is sourceable under the arm policy and named by the supervision block"
}

# --- neither Stop hook can wedge the session --------------------------------

test_guard_block_budget_bounded() {
  local home env sbin rc i blocked=0

  home="$TMP_ROOT/wedge-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  env=$(fm_tg_env "$home")
  sbin=$(fm_tg_scratch_bin "$home/scratch")
  export FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env"

  # A message was surfaced and no reply has gone out - and, as when Telegram is
  # unreachable, none ever will. The guard must hold the turn a bounded number
  # of times and then stand down rather than blocking for ever.
  printf '{"update_id": 1, "ts": 1, "text": "unanswerable", "acked": 1}' \
    > "$home/state/tg-inbox/1.json"
  touch "$home/state/.tg-last-surfaced"
  i=0
  while [ "$i" -lt 6 ]; do
    rc=0
    "$sbin/fm-tg-guard.sh" >"$TMP_ROOT/wedge-out" 2>&1 </dev/null || rc=$?
    [ "$rc" -eq 2 ] && blocked=$((blocked + 1))
    i=$((i + 1))
  done
  [ "$blocked" -eq 3 ] || fail "guard blocked $blocked times for one unanswered message; expected the default budget of 3"
  assert_contains "$(cat "$TMP_ROOT/wedge-out")" "standing down" "an exhausted guard must say why it stopped holding the turn"

  # THE REGRESSION THIS PINS. The budget was originally keyed on the mtime of
  # state/.tg-last-surfaced, which bin/fm-tg-drain.py - the sibling Stop hook,
  # running on every single turn end - rewrites unconditionally. The key
  # therefore changed every turn, the count reset to 1 every turn, and the
  # guard blocked for ever on a message it could not send a reply for: the
  # exact wedge the budget exists to prevent. Interleave the drain exactly as
  # production does and the bound must still hold.
  rm -f "$home/state/.turnend-tg-guard-blocks"
  blocked=0
  i=0
  while [ "$i" -lt 6 ]; do
    rc=0
    python3 "$sbin/fm-tg-drain.py" "$home/state/tg-inbox" "$home/state/tg-processed" \
      >/dev/null 2>&1 || true
    "$sbin/fm-tg-guard.sh" >"$TMP_ROOT/wedge-out" 2>&1 </dev/null || rc=$?
    [ "$rc" -eq 2 ] && blocked=$((blocked + 1))
    i=$((i + 1))
  done
  [ "$blocked" -eq 3 ] || fail "guard blocked $blocked times with the drain re-stamping the surfacing marker every turn; the budget must bound the MESSAGE, not the surfacing time"

  # A NEW message is new information and gets a full budget again, so a
  # bounded guard never becomes a silently lost message.
  printf '{"update_id": 2, "ts": 2, "text": "a second question", "acked": 1}' \
    > "$home/state/tg-inbox/2.json"
  rc=0
  "$sbin/fm-tg-guard.sh" >"$TMP_ROOT/wedge-out" 2>&1 </dev/null || rc=$?
  [ "$rc" -eq 2 ] || fail "a newly arrived message must get a fresh budget, not inherit the exhausted one"

  # And a real reply clears the record outright.
  touch "$home/state/.tg-last-sent"
  rc=0
  "$sbin/fm-tg-guard.sh" >"$TMP_ROOT/wedge-out" 2>&1 </dev/null || rc=$?
  expect_code 0 "$rc" "guard must fall silent once a reply has gone out"
  assert_absent "$home/state/.turnend-tg-guard-blocks" "a reply must clear the block record"

  rm -f "$TMP_ROOT/wedge-out"
  unset FM_HOME FM_TG_ENV_OVERRIDE
  pass "telegram: an unanswerable message holds the turn a bounded number of times even as the drain re-stamps every turn, and a new message still gets a full budget"
}

# --- the poll stays inside the watcher's per-check bound ---------------------

test_poll_records_before_slow_work() {
  local home env inbox offset

  home="$TMP_ROOT/budget-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  mkdir -p "$inbox"

  # An ack script that outlives the whole check budget stands in for a stalled
  # Telegram: the record and the offset must ALREADY be on disk, because a
  # check the watcher kills mid-flight would otherwise refetch and re-ack the
  # same update on every following cycle and never record it.
  cat > "$TMP_ROOT/slow-send.sh" <<'SH'
#!/usr/bin/env bash
sleep 30
SH
  chmod +x "$TMP_ROOT/slow-send.sh"

  printf '{"ok":true,"result":[{"update_id":70,"message":{"chat":{"id":999},"date":500,"text":"budget me"}}]}' \
    | FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" TG_TOKEN=faketoken FM_TG_FETCH_BUDGET=3 \
      python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$TMP_ROOT/slow-send.sh" >/dev/null

  assert_present "$inbox/70.json" "the inbox record must be written before the ack is attempted"
  assert_present "$offset" "the offset must be advanced before the ack is attempted"
  assert_grep "71" "$offset" "the offset must point past the recorded update"
  assert_no_grep '"acked": 1' "$inbox/70.json" "an ack that could not complete must not be recorded as done"
  pass "telegram: a poll records the message and advances the offset before any slow, budgeted work"
}

test_undownloadable_media_still_surfaces() {
  local home inbox offset out

  home="$TMP_ROOT/media-budget-home"
  mkdir -p "$home/state"
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  mkdir -p "$inbox"

  # A captionless photo whose bytes cannot be fetched inside the budget. It
  # must still be recorded and still surface - a message the captain sent must
  # never go unmentioned just because its attachment is missing.
  printf '{"ok":true,"result":[{"update_id":80,"message":{"chat":{"id":999},"date":600,"photo":[{"file_id":"AAA","file_size":10}]}}]}' \
    | FM_TG_FETCH_BUDGET=1 python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" /bin/true >/dev/null

  assert_present "$inbox/80.json" "a captionless photo must be recorded even when its bytes cannot be fetched"
  assert_grep '"media_id": "AAA"' "$inbox/80.json" "the record must keep the file id of the media it could not fetch"
  out=$(python3 "$ROOT/bin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed")
  assert_contains "$out" "1 captain message(s) pending" "an undownloaded attachment must still surface as a pending message"
  assert_contains "$out" "AAA" "the surfaced line must name the media it could not download"
  pass "telegram: a message whose attachment could not be fetched in budget is still recorded and still surfaces"
}

# --- the unsurfaced-retirement notice is not swallowed ----------------------

test_unsurfaced_retirement_is_recorded() {
  local home env inbox fresh_ts elapsed

  home="$TMP_ROOT/notice-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  # Under the corrected archive-window semantics (docs/telegram.md, "No message
  # is answered twice"), only a FRESH (<10s) never-surfaced record is eligible
  # for the same-turn-race retirement this notice covers; an old one now stays
  # pending instead (see test_archive_never_surfaced_old_stays_pending).
  fresh_ts=$(date +%s)

  printf '{"update_id": 60, "chat_id": 999, "ts": %s, "text": "fresh and unsurfaced"}' "$fresh_ts" > "$inbox/60.json"

  # Sent through fm-tg-send.sh, exactly as in production - where the archive
  # run's stdout used to go straight to /dev/null, making the one outcome that
  # can cost the captain an answer completely invisible.
  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-send.sh" 'a reply' >"$TMP_ROOT/notice-out" 2>&1
  expect_code 0 "$?" "fm-tg-send.sh failed: $(cat "$TMP_ROOT/notice-out")"
  rm -f "$TMP_ROOT/notice-out"

  # The record is only eligible while it is inside that 10s window, so this
  # assertion silently depends on the whole send finishing within it. Name that
  # dependency outright: a slower send path must fail as what it is, not as a
  # phantom defect in the notice path below.
  elapsed=$(( $(date +%s) - fresh_ts ))
  [ "$elapsed" -lt 10 ] || fail "the send took ${elapsed}s, outside the 10s same-turn window this test's fixture depends on"

  assert_present "$home/state/.tg-archive.log" "an unsurfaced retirement must be recorded somewhere durable"
  assert_grep "retired unsurfaced" "$home/state/.tg-archive.log" "the retirement notice must name what happened"
  assert_grep "60.json" "$home/state/.tg-archive.log" "the retirement notice must name the message it retired"
  pass "telegram: an unsurfaced retirement is recorded in state/.tg-archive.log instead of being swallowed"
}

# --- config absent: everything stays silent ---------------------------------

test_config_absent_hooks_silent() {
  local home sbin
  home="$TMP_ROOT/absent-home"
  mkdir -p "$home/state"
  # The identity gate is stubbed to ALLOW here on purpose. These scripts also
  # no-op for a crewmate, so running them through the real gate proved nothing
  # about the config gate whenever the suite happened to run from a worktree -
  # and it hid a real defect: the hook created state/tg-inbox and
  # state/tg-processed on every turn end of an unconfigured firstmate primary.
  # With identity allowed, absent config is the only thing left to keep this
  # home byte-for-byte unchanged.
  sbin=$(fm_tg_scratch_bin "$home/scratch")

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/does-not-exist.env" \
    "$sbin/fm-tg-guard.sh" >"$TMP_ROOT/absent-guard-out" 2>&1 </dev/null
  expect_code 0 "$?" "fm-tg-guard.sh with no config"
  [ ! -s "$TMP_ROOT/absent-guard-out" ] || fail "fm-tg-guard.sh printed output with no config: $(cat "$TMP_ROOT/absent-guard-out")"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/does-not-exist.env" FM_TG_WAIT_MAX=1 \
    "$sbin/fm-tg-hook.sh" >"$TMP_ROOT/absent-hook-out" 2>&1 </dev/null
  expect_code 0 "$?" "fm-tg-hook.sh with no config"
  [ ! -s "$TMP_ROOT/absent-hook-out" ] || fail "fm-tg-hook.sh printed output with no config: $(cat "$TMP_ROOT/absent-hook-out")"
  assert_absent "$home/state/tg-inbox" "fm-tg-hook.sh must not create state/tg-inbox before checking config"
  assert_absent "$home/state/tg-processed" "fm-tg-hook.sh must not create state/tg-processed before checking config"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/does-not-exist.env" \
    "$sbin/fm-tg-poll.sh" >"$TMP_ROOT/absent-poll-out" 2>&1
  expect_code 0 "$?" "fm-tg-poll.sh with no config"
  [ ! -s "$TMP_ROOT/absent-poll-out" ] || fail "fm-tg-poll.sh printed output with no config: $(cat "$TMP_ROOT/absent-poll-out")"

  # A half-configured file is not configuration either: a token with no chat id
  # cannot reach the captain, so it must stay just as inert.
  #
  # The two POLLERS matter most here, and used to gate on TG_TOKEN alone. A
  # token-only file left them fetching real inbound updates while
  # bin/fm-tg-fetch.py's captain-impersonation filter had no configured chat id
  # to compare against - so anyone who found the bot's public username was
  # recorded and surfaced as the captain. Both must now refuse outright.
  printf 'TG_TOKEN=faketoken\n' > "$home/half.env"
  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/half.env" FM_TG_WAIT_MAX=1 \
    "$sbin/fm-tg-hook.sh" >"$TMP_ROOT/absent-hook-out" 2>&1 </dev/null
  expect_code 0 "$?" "fm-tg-hook.sh with a chat-id-less config"
  [ ! -s "$TMP_ROOT/absent-hook-out" ] || fail "fm-tg-hook.sh printed output with a half config: $(cat "$TMP_ROOT/absent-hook-out")"

  # With a stranger's message genuinely waiting on the wire, so this is the real
  # hole and not merely a quiet channel.
  printf '{"ok":true,"result":[{"update_id":300,"message":{"chat":{"id":424242},"date":%s,"text":"i am not the captain"}}]}' \
    "$(date +%s)" > "$home/stranger.json"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/half.env" FAKE_TG_GETUPDATES_FILE="$home/stranger.json" \
    "$sbin/fm-tg-poll.sh" >"$TMP_ROOT/absent-poll-out" 2>&1
  expect_code 0 "$?" "fm-tg-poll.sh with a chat-id-less config"
  [ ! -s "$TMP_ROOT/absent-poll-out" ] \
    || fail "fm-tg-poll.sh polled with no chat id to filter inbound updates against: $(cat "$TMP_ROOT/absent-poll-out")"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/half.env" FM_TG_WAIT_MAX=1 \
    FAKE_TG_GETUPDATES_FILE="$home/stranger.json" \
    "$sbin/fm-tg-wait.sh" >"$TMP_ROOT/absent-wait-out" 2>&1 </dev/null
  expect_code 0 "$?" "fm-tg-wait.sh with a chat-id-less config"
  [ ! -s "$TMP_ROOT/absent-wait-out" ] \
    || fail "fm-tg-wait.sh long-polled with no chat id to filter inbound updates against: $(cat "$TMP_ROOT/absent-wait-out")"

  assert_absent "$home/state/tg-inbox" "no config must never create state/tg-inbox"
  assert_absent "$home/state/tg-processed" "no config must never create state/tg-processed"
  rm -f "$TMP_ROOT/absent-guard-out" "$TMP_ROOT/absent-hook-out" \
    "$TMP_ROOT/absent-poll-out" "$TMP_ROOT/absent-wait-out"
  pass "telegram: absent or half config -> guard, hook, poll, and the long-poll waiter all exit 0 silently, nothing created (identity-neutralized, so the config-absent path is actually exercised)"
}

# --- crew worktree: send refuses, hooks no-op -------------------------------

test_crew_worktree_refuses() {
  local home fakehome crewdir out rc
  home="$TMP_ROOT/crew-home"
  mkdir -p "$home/state"
  fm_tg_env "$home" >/dev/null

  # bin/fm-tg-send.sh condemns a cwd under "$HOME"/.treehouse/* (real crew
  # leases always live there). $HOME is read at runtime, so point it at scratch
  # rather than building the path under the operator's real home, where the
  # .treehouse parent would be left behind on a machine that has none.
  fakehome="$TMP_ROOT/crew-fakehome"
  crewdir="$fakehome/.treehouse/task"
  mkdir -p "$crewdir"

  out=$(cd "$crewdir" && HOME="$fakehome" FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/tg.env" \
    "$ROOT/bin/fm-tg-send.sh" 'hello captain' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-tg-send.sh did not refuse from a crew worktree"
  assert_contains "$out" "REFUSED" "fm-tg-send.sh crew refusal missing REFUSED message"
  assert_absent "$home/state/.tg-last-sent" "crew send must never stamp .tg-last-sent"

  # A task worktree that does NOT live under $HOME/.treehouse must be refused
  # just the same: the predicate is git's linked-worktree shape, not a path.
  fm_git_worktree "$TMP_ROOT/crew-repo" "$TMP_ROOT/crew-elsewhere" fm/crew
  out=$(cd "$TMP_ROOT/crew-elsewhere" && FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/tg.env" \
    "$ROOT/bin/fm-tg-send.sh" 'hello captain' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "fm-tg-send.sh did not refuse from a task worktree outside \$HOME/.treehouse"
  assert_contains "$out" "REFUSED" "fm-tg-send.sh worktree refusal missing REFUSED message"
  assert_absent "$home/state/.tg-last-sent" "crew send must never stamp .tg-last-sent"

  # Both Stop hooks must also no-op from a crew worktree cwd - this uses the
  # REAL (non-scratch) fm-tg-isfirstmate.sh, which is fine here: "must
  # condemn" holds regardless of whether the cwd signal, ambient ancestry, or
  # both are what actually trips it (isfirstmate.sh's own contract is "either
  # signal condemns").
  (cd "$crewdir" && HOME="$fakehome" FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/tg.env" \
    "$ROOT/bin/fm-tg-guard.sh" >"$TMP_ROOT/crew-guard-out" 2>&1 </dev/null)
  expect_code 0 "$?" "fm-tg-guard.sh must no-op (exit 0) from a crew worktree"
  [ ! -s "$TMP_ROOT/crew-guard-out" ] || fail "fm-tg-guard.sh printed output from a crew worktree: $(cat "$TMP_ROOT/crew-guard-out")"

  (cd "$crewdir" && HOME="$fakehome" FM_HOME="$home" FM_TG_ENV_OVERRIDE="$home/tg.env" FM_TG_WAIT_MAX=1 \
    "$ROOT/bin/fm-tg-hook.sh" >"$TMP_ROOT/crew-hook-out" 2>&1 </dev/null)
  expect_code 0 "$?" "fm-tg-hook.sh must no-op (exit 0) from a crew worktree"
  [ ! -s "$TMP_ROOT/crew-hook-out" ] || fail "fm-tg-hook.sh printed output from a crew worktree: $(cat "$TMP_ROOT/crew-hook-out")"

  rm -f "$TMP_ROOT/crew-guard-out" "$TMP_ROOT/crew-hook-out"
  pass "telegram: fm-tg-send.sh refuses from a crew worktree, in \$HOME/.treehouse or anywhere else, and both Stop hooks no-op"
}

# fm_tg_fake_home <dir> [marker-id]: a directory shaped like a firstmate home
# (AGENTS.md + bin/ + state/) holding the real identity check and the shared
# scope lib it uses, so fm-tg-isfirstmate.sh can be run against it directly.
fm_tg_fake_home() {
  local dir=$1 marker=${2:-}
  mkdir -p "$dir/bin" "$dir/state"
  : > "$dir/AGENTS.md"
  cp "$ROOT/bin/fm-tg-isfirstmate.sh" "$ROOT/bin/fm-primary-scope-lib.sh" "$dir/bin/"
  chmod +x "$dir/bin/fm-tg-isfirstmate.sh"
  [ -z "$marker" ] || printf '%s\n' "$marker" > "$dir/.fm-secondmate-home"
}

test_isfirstmate_direct() {
  local base plain wt rc

  # A plain checkout of a firstmate-shaped home is the one thing that IS
  # firstmate. Everything below is a variation that must be condemned.
  base="$TMP_ROOT/identity"
  plain="$base/primary"
  fm_git_init_commit "$plain"
  fm_tg_fake_home "$plain"
  git -C "$plain" add -A >/dev/null 2>&1
  git -C "$plain" -c user.name=t -c user.email=t@example.invalid commit -qm home
  rc=0
  (cd "$plain" && "$plain/bin/fm-tg-isfirstmate.sh") || rc=$?
  expect_code 0 "$rc" "a plain firstmate checkout must be recognised as the primary"

  # A LINKED worktree of that same repo - a crewmate or scout task worktree, or
  # one of this repo's own validation worktrees. The predecessor of this check
  # only looked for $HOME/.treehouse/*, so every worktree living anywhere else
  # was declared to be firstmate and drained the captain's inbox into a crew
  # session. Location must not matter; git's linked-worktree shape must.
  wt="$base/task-worktree"
  git -C "$plain" worktree add --quiet -b fm/task "$wt"
  mkdir -p "$wt/state"
  rc=0
  (cd "$wt" && "$wt/bin/fm-tg-isfirstmate.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a linked task worktree must be condemned as crew wherever it lives"

  # ...and the primary's own copy, invoked while the working directory is that
  # task worktree, is condemned too.
  rc=0
  (cd "$wt" && "$plain/bin/fm-tg-isfirstmate.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a crew cwd must be condemned even when the primary's own copy is invoked"

  # A secondmate home passes the shared primary predicate, but it is not the
  # home that talks to the captain: one captain, one bot per machine.
  fm_tg_fake_home "$base/secondmate" fm-second
  rc=0
  (cd "$base/secondmate" && "$base/secondmate/bin/fm-tg-isfirstmate.sh") || rc=$?
  [ "$rc" -ne 0 ] || fail "a secondmate home must not address the captain directly"

  pass "telegram: fm-tg-isfirstmate.sh allows only a plain primary checkout - linked worktrees (anywhere) and secondmate homes are condemned"
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
  "$sbin/fm-tg-guard.sh" >"$TMP_ROOT/guard1-out" 2>&1 </dev/null
  rc=$?
  [ "$rc" -eq 2 ] || fail "guard did not block after ack-only (got exit $rc): $(cat "$TMP_ROOT/guard1-out")"
  assert_contains "$(cat "$TMP_ROOT/guard1-out")" "UNANSWERED CAPTAIN MESSAGE" "guard reason missing"
  rm -f "$TMP_ROOT/guard1-out"

  # 4. Still unanswered -> re-surfaces (no loss) rather than being dropped.
  out=$(python3 "$sbin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed")
  assert_contains "$out" "what is an epoch?" "unanswered message failed to re-surface"

  # 5. A real reply goes out (fake curl, no live traffic).
  "$sbin/fm-tg-send.sh" 'an epoch is a fixed point in time' >"$TMP_ROOT/send-out" 2>&1
  rc=$?
  expect_code 0 "$rc" "fm-tg-send.sh real reply failed: $(cat "$TMP_ROOT/send-out")"
  rm -f "$TMP_ROOT/send-out"
  assert_present "$home/state/.tg-last-sent" "real reply did not stamp .tg-last-sent"

  # 6. Archived: the message is gone from the inbox and drain has nothing left.
  assert_absent "$inbox/1.json" "answered message was not archived out of the inbox"
  assert_present "$home/state/tg-processed/1.json" "answered message did not land in tg-processed"
  python3 "$sbin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed"
  rc=$?
  [ "$rc" -eq 1 ] || fail "drain still reports something pending after the real reply landed"

  # 7. Guard: a real reply since the last surface -> silent, turn may end.
  "$sbin/fm-tg-guard.sh" >"$TMP_ROOT/guard2-out" 2>&1 </dev/null
  rc=$?
  expect_code 0 "$rc" "guard still blocking after a real reply was sent: $(cat "$TMP_ROOT/guard2-out")"
  rm -f "$TMP_ROOT/guard2-out"

  unset FM_HOME FM_TG_ENV_OVERRIDE TG_TOKEN
  pass "telegram: arrival acks once, guard demands a real reply, unanswered re-surfaces, real reply silences the guard and archives"
}

# --- the reply/surface race in fm-tg-archive.py, and its own review-caught -
# --- bug: any window keyed on arrival time let an unrelated/proactive send -
# --- sweep up an old message that was never actually shown to the model. --
#
# Final, captain-approved semantics (a no-mistakes review finding on this
# branch, captain's own design calls for both parts):
#   - SURFACED at least once (bin/fm-tg-drain.py counts each surfacing in the
#     record's "surfaced" field, which is the whole of what the retirement
#     rule reads): ALWAYS retire on any real reply, however much later.
#   - NEVER surfaced: retire ONLY within a short (10s) window of arrival - the
#     genuine same-turn race, where a message that will imminently be shown
#     has not yet had a surfacing pass run. Older than that and still never
#     surfaced: stays pending, no matter what unrelated reply goes out - this
#     is the actual "no message is lost" fix; a proactive/unrelated send must
#     never retire a message the model has not genuinely had a chance to see.
#   - A missing or malformed ts is "unknown", never "infinitely old": it must
#     never be swept up by the never-surfaced window.

test_archive_never_surfaced_same_turn_retires() {
  local home env inbox now
  home="$TMP_ROOT/race-fresh-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  now=$(date +%s)

  # A message that just arrived (well under 10s old) and was never surfaced -
  # the genuine same-turn race the window exists to cover.
  printf '{"update_id": 50, "chat_id": 999, "ts": %s, "text": "brand new"}' "$now" > "$inbox/50.json"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-send.sh" 'unrelated reply' >"$TMP_ROOT/race-fresh-out" 2>&1
  expect_code 0 "$?" "fm-tg-send.sh failed: $(cat "$TMP_ROOT/race-fresh-out")"
  rm -f "$TMP_ROOT/race-fresh-out"

  assert_absent "$inbox/50.json" \
    "a fresh (<10s), never-surfaced message must retire as the same-turn-race courtesy the window exists for"
  pass "telegram: a fresh (<10s), never-surfaced message is swept in by any reply - the intended same-turn-race coverage"
}

test_archive_never_surfaced_old_stays_pending() {
  local home env inbox old_ts out
  home="$TMP_ROOT/race-old-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  old_ts=$(( $(date +%s) - 120 ))

  # A message that arrived over a minute ago and was never marked surfaced.
  # This is the exact review finding: an unrelated/proactive send must NOT
  # sweep up a message the model has genuinely never had a chance to see.
  printf '{"update_id": 51, "chat_id": 999, "ts": %s, "text": "old and unsurfaced"}' "$old_ts" > "$inbox/51.json"

  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-send.sh" 'unrelated proactive update' >"$TMP_ROOT/race-old-out" 2>&1
  expect_code 0 "$?" "fm-tg-send.sh failed: $(cat "$TMP_ROOT/race-old-out")"
  rm -f "$TMP_ROOT/race-old-out"

  assert_present "$inbox/51.json" \
    "an old (>10s), never-surfaced message must NOT be retired by an unrelated reply - this is the 'no message lost' fix"
  pass "telegram: an old, never-surfaced message survives an unrelated reply (closes the review-caught proactive-send-sweep bug)"
}

test_archive_never_surfaced_boundary() {
  local home ts_in ts_out out
  home="$TMP_ROOT/archive-boundary-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  ts_in=$(( $(date +%s) - 9 ))    # just inside the 10s same-turn window
  ts_out=$(( $(date +%s) - 11 ))  # just outside it

  printf '{"update_id": 62, "chat_id": 999, "ts": %s, "text": "nine seconds old"}' "$ts_in" > "$home/state/tg-inbox/62.json"
  printf '{"update_id": 63, "chat_id": 999, "ts": %s, "text": "eleven seconds old"}' "$ts_out" > "$home/state/tg-inbox/63.json"

  out=$(python3 "$ROOT/bin/fm-tg-archive.py" "$home/state/tg-inbox" "$home/state/tg-processed")

  assert_absent "$home/state/tg-inbox/62.json" "a 9s-old never-surfaced message (inside the window) must retire"
  assert_contains "$out" "retired unsurfaced" "the same-turn retirement must print a visible notice"
  assert_present "$home/state/tg-inbox/63.json" "an 11s-old never-surfaced message (outside the window) must stay pending"
  pass "telegram: the never-surfaced window's boundary is exactly 10s - 9s retires, 11s stays pending"
}

test_archive_surfaced_always_retires_regardless_of_age() {
  local home old_ts
  home="$TMP_ROOT/archive-surfaced-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  old_ts=$(( $(date +%s) - 3600 ))   # arrived an hour ago

  # Surfaced (drain already ran on it), but the reply happens to come a long
  # time after that surfacing. Having been surfaced at all is the whole test -
  # there is no window for a record the model has genuinely already been shown,
  # so an old arrival time must not save it.
  printf '{"update_id": 64, "chat_id": 999, "ts": %s, "text": "old but surfaced", "surfaced": 1}' \
    "$old_ts" > "$home/state/tg-inbox/64.json"

  python3 "$ROOT/bin/fm-tg-archive.py" "$home/state/tg-inbox" "$home/state/tg-processed" >/dev/null
  assert_absent "$home/state/tg-inbox/64.json" "a surfaced record must always retire on a real reply, however much later"
  assert_present "$home/state/tg-processed/64.json" "a surfaced-and-answered record must land in tg-processed"
  pass "telegram: a surfaced record retires unconditionally, regardless of how long ago it arrived or was surfaced"
}

test_archive_missing_ts_never_retired() {
  local home out
  home="$TMP_ROOT/archive-missing-ts-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"

  # No "ts" field at all: must be treated as unknown/brand-new, never as
  # infinitely old (the review-caught bug: float(None or 0) == 0.0, which
  # made a missing ts look ancient and retired the record on the very first
  # send, sight unseen).
  printf '{"update_id": 65, "chat_id": 999, "text": "no timestamp at all"}' > "$home/state/tg-inbox/65.json"

  out=$(python3 "$ROOT/bin/fm-tg-archive.py" "$home/state/tg-inbox" "$home/state/tg-processed")
  assert_present "$home/state/tg-inbox/65.json" "a record with a missing ts must never be treated as infinitely old and retired"
  assert_contains "$out" "archived 0" "nothing should have been archived"
  pass "telegram: a record with a missing/malformed ts is never retired via the never-surfaced window"
}

# --- chat_id filter (a no-mistakes review finding, captain-approved fix) ---
# --- drop any update whose chat is not the configured TG_CHAT_ID, before ---
# --- it is ever recorded - otherwise anyone who finds the bot's public   ---
# --- username can message it and be treated as the captain.             ---

test_fetch_drops_mismatched_chat_id() {
  local home env inbox offset send out err
  home="$TMP_ROOT/chatfilter-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")   # TG_CHAT_ID=999
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  send="$ROOT/bin/fm-tg-send.sh"
  mkdir -p "$inbox"

  set -a
  # shellcheck source=/dev/null
  . "$env"
  set +a

  out=$(printf '{"ok":true,"result":[{"update_id":70,"message":{"chat":{"id":424242},"date":%s,"text":"i am not the captain"}}]}' "$(date +%s)" \
    | python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$send" 2>"$TMP_ROOT/chatfilter-err")
  err=$(cat "$TMP_ROOT/chatfilter-err"); rm -f "$TMP_ROOT/chatfilter-err"

  assert_absent "$inbox/70.json" "an update from a mismatched chat_id must never be recorded as a captain message"
  [ -z "$out" ] || fail "a dropped update must not report a new message: $out"
  assert_contains "$err" "dropped update" "a dropped update must be visible (never silent)"
  assert_contains "$err" "424242" "the drop notice must name the offending chat_id"
  assert_contains "$err" "999" "the drop notice must name the configured chat_id for comparison"
  [ "$(cat "$offset")" = "71" ] || fail "the offset must still advance past a dropped update, or it refetches forever: got $(cat "$offset" 2>/dev/null)"

  unset TG_TOKEN TG_CHAT_ID
  pass "telegram: an update from a chat_id other than TG_CHAT_ID is dropped before recording, with a visible (non-silent) log line"
}

test_fetch_accepts_matching_chat_id() {
  local home env inbox offset send out
  home="$TMP_ROOT/chatfilter-match-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")   # TG_CHAT_ID=999
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  send="$ROOT/bin/fm-tg-send.sh"
  mkdir -p "$inbox"

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" TG_TOKEN=faketoken TG_CHAT_ID=999 bash -c '
    printf "{\"ok\":true,\"result\":[{\"update_id\":71,\"message\":{\"chat\":{\"id\":999},\"date\":%s,\"text\":\"the real captain\"}}]}" "$(date +%s)" \
      | python3 "'"$ROOT"'/bin/fm-tg-fetch.py" poll "'"$inbox"'" "'"$offset"'" "'"$send"'"
  ')
  assert_present "$inbox/71.json" "a matching chat_id must still be recorded normally"
  assert_contains "$out" "telegram: 1 message(s)" "a matching chat_id must still report as a new message"
  pass "telegram: an update whose chat_id matches TG_CHAT_ID is recorded normally (the filter is not over-broad)"
}

# --- a malformed update must not stall the channel -------------------------
# --- Every acknowledgement offset is update_id + 1, so an update with no  ---
# --- usable update_id used to raise an uncaught TypeError that aborted    ---
# --- the batch: nothing recorded, the offset left behind the payload, the ---
# --- same bytes refetched and crashed on for ever - and silently, because ---
# --- a traceback's exit 1 reads to the poller exactly like a good poll.   ---

test_fetch_survives_unusable_update_id() {
  local home env inbox offset send out rc err
  home="$TMP_ROOT/badid-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")   # TG_CHAT_ID=999
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  send="$ROOT/bin/fm-tg-send.sh"
  mkdir -p "$inbox"

  set -a
  # shellcheck source=/dev/null
  . "$env"
  set +a

  # A whole payload of unacknowledgeable updates: reported as a refusal, which
  # is what bin/fm-tg-poll.sh surfaces, rather than passing for a quiet channel.
  out=$(printf '{"ok":true,"result":[{"message":{"chat":{"id":999},"date":%s,"text":"no id at all"}}]}' "$(date +%s)" \
    | python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$send" 2>"$TMP_ROOT/badid-err")
  rc=$?
  err=$(cat "$TMP_ROOT/badid-err"); rm -f "$TMP_ROOT/badid-err"

  expect_code 3 "$rc" "an unacknowledgeable payload must be reported as a refusal, not crash or pass for a quiet channel"
  assert_contains "$err" "update_id" "the refusal must name what was wrong with the update"
  [ -z "$out" ] || fail "a malformed update must not be reported as a captain message: $out"
  assert_absent "$offset" "an update that cannot be acknowledged must not move the offset"

  # A malformed update alongside a real one must not cost the real one: it is
  # skipped, the good message is still recorded, and the offset still advances.
  out=$(printf '{"ok":true,"result":[{"update_id":"not-a-number","message":{"chat":{"id":999},"date":%s,"text":"junk"}},{"update_id":73,"message":{"chat":{"id":999},"date":%s,"text":"the real one"}}]}' "$(date +%s)" "$(date +%s)" \
    | python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$send" 2>/dev/null)
  rc=$?

  expect_code 0 "$rc" "one malformed update must not abort the rest of the batch"
  assert_contains "$out" "the real one" "the good message in a part-malformed batch must still be reported"
  assert_present "$inbox/73.json" "the good message in a part-malformed batch must still be recorded"
  [ "$(cat "$offset")" = "74" ] || fail "the offset must advance past the good update: got $(cat "$offset" 2>/dev/null)"

  unset TG_TOKEN TG_CHAT_ID
  pass "telegram: an update with no usable update_id is skipped and reported, never a crash that stalls the channel"
}

test_fetch_nonmessage_update_is_not_a_chat_mismatch() {
  local home env inbox offset send err
  home="$TMP_ROOT/nonmessage-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")   # TG_CHAT_ID=999
  inbox="$home/state/tg-inbox"
  offset="$home/state/.tg-offset"
  send="$ROOT/bin/fm-tg-send.sh"
  mkdir -p "$inbox"

  set -a
  # shellcheck source=/dev/null
  . "$env"
  set +a

  # An ordinary non-message update kind. It carries no chat to compare, so
  # deciding the chat filter first described it as a wrong-chat sender - the
  # one line an operator reads while chasing an impersonation report.
  printf '{"ok":true,"result":[{"update_id":75,"my_chat_member":{"chat":{"id":999}}}]}' \
    | python3 "$ROOT/bin/fm-tg-fetch.py" poll "$inbox" "$offset" "$send" \
      >/dev/null 2>"$TMP_ROOT/nonmessage-err"
  err=$(cat "$TMP_ROOT/nonmessage-err"); rm -f "$TMP_ROOT/nonmessage-err"

  assert_not_contains "$err" "dropped update" \
    "an ordinary non-message update must never be reported as a wrong-chat sender"
  assert_absent "$inbox/75.json" "a non-message update carries nothing to record"
  [ "$(cat "$offset")" = "76" ] || fail "the offset must still advance past a non-message update: got $(cat "$offset" 2>/dev/null)"

  unset TG_TOKEN TG_CHAT_ID
  pass "telegram: an ordinary non-message update advances the offset without being blamed on a wrong chat_id"
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
    "$ROOT/bin/fm-tg-send.sh" --file "$f" >"$TMP_ROOT/large-png-out" 2>&1
  expect_code 0 "$?" "sending a >1MB png failed: $(cat "$TMP_ROOT/large-png-out")"
  rm -f "$TMP_ROOT/large-png-out"

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
    "$ROOT/bin/fm-tg-send.sh" --file "$f" >"$TMP_ROOT/small-png-out" 2>&1
  expect_code 0 "$?" "sending a small png failed: $(cat "$TMP_ROOT/small-png-out")"
  rm -f "$TMP_ROOT/small-png-out"

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

# --- portability and durability of the records the captain's words live in ---

test_poll_without_a_timeout_binary() {
  local home env inbox out nopath
  home="$TMP_ROOT/no-timeout-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"
  nopath=$(fm_tg_path_without_timeout "$TMP_ROOT")

  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":true,"result":[{"update_id":120,"message":{"chat":{"id":999},"date":500,"text":"no timeout binary here"}}]}'

  # With a bare `timeout` these scripts never invoked curl at all on such a
  # host: the check exited 0 having silently polled nothing, and every text
  # reply to the captain died reporting "unparseable reply" for an empty
  # response. bin/fm-timeout-lib.sh picks a mechanism that exists instead.
  out=$(PATH="$nopath" FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  unset FAKE_TG_GETUPDATES_FILE
  assert_contains "$out" "telegram: 1 message(s)" "the poll did not reach curl on a host with no timeout binary"
  assert_present "$inbox/120.json" "the poll recorded nothing on a host with no timeout binary"

  out=$(cd "$TMP_ROOT" && PATH="$nopath" FM_TG_FORCE=1 FM_HOME="$home" \
    FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-send.sh" 'a real reply' 2>&1)
  assert_contains "$out" "sent" "a text send did not reach curl on a host with no timeout binary"
  assert_not_contains "$out" "unparseable reply" "a send with no timeout binary must not report a parse error"

  pass "telegram: the poll and a text send still reach curl on a host with no timeout binary"
}

test_records_are_private_and_left_whole() {
  local home env inbox out mode stray f
  home="$TMP_ROOT/private-records-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"

  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":true,"result":[{"update_id":130,"message":{"chat":{"id":999},"date":600,"text":"private words"}}]}'
  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  unset FAKE_TG_GETUPDATES_FILE
  assert_contains "$out" "telegram: 1 message(s)" "the poll did not record the message"

  # The captain's own words, and the offset that decides what is refetched, are
  # owner-only; at the ambient umask they were world-readable.
  for f in "$inbox/130.json" "$home/state/.tg-offset"; do
    mode=$(fm_tg_file_mode "$f")
    case "$mode" in
      600|0600) ;;
      *) fail "$f is mode $mode, not owner-only" ;;
    esac
  done

  # Every record update is staged and swapped, so nothing half-written is ever
  # visible under the name a reader globs.
  out=$(python3 "$ROOT/bin/fm-tg-drain.py" "$inbox" "$home/state/tg-processed") \
    || fail "the drain did not surface the recorded message"
  assert_grep '"surfaced": 1' "$inbox/130.json" "the drain did not stamp the surfaced counter"
  stray=$(find "$home/state" -name '*.tmp*' | wc -l | tr -d ' ')
  [ "$stray" = 0 ] || fail "a staged write was left behind in state/ ($stray file(s))"

  pass "telegram: records and the offset are owner-only, and every update is swapped into place whole"
}

# --- amendment 5: fm-tg-send.sh auto-retries a transient text-send failure --

test_send_retries_transient_failure_then_succeeds() {
  local home env counter out log
  home="$TMP_ROOT/retry-succeed-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  counter="$TMP_ROOT/retry-counter-succeed"
  log="$TMP_ROOT/retry-succeed.log"
  printf '2' > "$counter"   # first two attempts return empty (transient), third succeeds

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" \
    FAKE_CURL_FAIL_COUNTER="$counter" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-tg-send.sh" 'will succeed on the third attempt' 2>&1)
  expect_code 0 "$?" "fm-tg-send.sh must succeed once a retry lands, not surface the earlier transient failures: $out"
  assert_contains "$out" "sent" "a message that succeeds on retry must still report sent"
  [ "$(grep -c 'sendMessage' "$log")" -eq 3 ] || fail "expected exactly 3 curl attempts (2 transient failures + 1 success), got: $(grep -c sendMessage "$log")"
  assert_present "$home/state/.tg-last-sent" "a message that eventually succeeds must still count as a real reply"
  pass "telegram: fm-tg-send.sh retries a transient failure automatically and succeeds without the caller noticing"
}

test_send_does_not_retry_a_real_rejection() {
  local home env log out rc
  home="$TMP_ROOT/retry-reject-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  log="$TMP_ROOT/retry-reject.log"

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FAKE_CURL_REJECT=1 FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-tg-send.sh" 'this will be rejected' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a genuine Telegram rejection must still fail, not be swallowed by the retry loop"
  assert_contains "$out" "REJECTED" "a rejection must still be reported loudly"
  [ "$(grep -c 'sendMessage' "$log")" -eq 1 ] || fail "a genuine rejection must NOT be retried (retrying a bad request cannot help); expected 1 curl attempt, got: $(grep -c sendMessage "$log")"
  assert_absent "$home/state/.tg-last-sent" "a rejected send must never count as a real reply"
  pass "telegram: fm-tg-send.sh never retries a genuine Telegram rejection (only transient failures)"
}

test_send_gives_up_after_3_transient_failures() {
  local home env counter log out rc
  home="$TMP_ROOT/retry-giveup-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  counter="$TMP_ROOT/retry-counter-giveup"
  log="$TMP_ROOT/retry-giveup.log"
  printf '99' > "$counter"   # persistently transient - never recovers

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" \
    FAKE_CURL_FAIL_COUNTER="$counter" FAKE_CURL_LOG="$log" \
    "$ROOT/bin/fm-tg-send.sh" 'this will never get through' 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a persistently failing send must eventually give up and fail, not hang or succeed"
  assert_contains "$out" "FAILED mid-send after 3 attempts" "a persistent transient failure must report the exact give-up message"
  [ "$(grep -c 'sendMessage' "$log")" -eq 3 ] || fail "must attempt exactly 3 times before giving up, got: $(grep -c sendMessage "$log")"
  assert_absent "$home/state/.tg-last-sent" "a send that never got through must never count as a real reply"
  pass "telegram: fm-tg-send.sh gives up after exactly 3 attempts on a persistent transient failure"
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

test_poll_reports_a_refusal_once() {
  local home env out

  home="$TMP_ROOT/poll-refusal-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")

  # A revoked token, a duplicate poller and a rate limit all come back as an
  # error body curl transfers perfectly, which used to look exactly like a
  # captain who had not written: no output, no wake, no trace anywhere.
  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":false,"error_code":401,"description":"Unauthorized"}'

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  assert_contains "$out" "refused the poll" "a Telegram refusal must be reported, not swallowed as a quiet channel"
  assert_contains "$out" "401" "the report must carry Telegram's own reason so the captain can tell a revoked token from a rate limit"
  assert_present "$home/state/.tg-poll-error" "the refusal must be recorded so the same failure is not reported on every poll"

  # Every 30s for as long as the token stays revoked is not a wake; report once.
  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  [ -z "$out" ] || fail "the same standing refusal was reported again: $out"

  # A different refusal is news again.
  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":false,"error_code":429,"description":"Too Many Requests: retry after 30"}'
  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  assert_contains "$out" "429" "a different refusal must be reported rather than suppressed by the previous one"

  # A usable poll clears the record, so a recurrence is reported again.
  fm_tg_getupdates_fixture "$TMP_ROOT" '{"ok":true,"result":[]}'
  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  [ -z "$out" ] || fail "a healthy quiet poll printed output: $out"
  assert_absent "$home/state/.tg-poll-error" "a usable poll must clear the refusal record"

  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":false,"error_code":401,"description":"Unauthorized"}'
  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  assert_contains "$out" "401" "a refusal recurring after a healthy poll must be reported again"

  unset FAKE_TG_GETUPDATES_FILE
  pass "telegram: the watcher poll reports a refused channel once per distinct reason instead of looking quiet"
}

# --- an unusable answer is not a good pass -----------------------------------

test_wait_backs_off_on_error_body() {
  local home env fixture calls rc

  home="$TMP_ROOT/spin-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")

  # Telegram answers a duplicate getUpdates on one token with an immediate 409,
  # a revoked token with a 401, and a rate limit with a 429. curl reports every
  # one of those as a completely successful transfer of a NON-EMPTY body, so a
  # backoff that only covers transport failure never fires: the loop re-polled
  # with zero delay, measured at ~16 curl+python3 spawn pairs a second for the
  # whole FM_TG_HOOK_MAX window, on every single turn end.
  fixture="$TMP_ROOT/spin-fixture.json"
  printf '{"ok":false,"error_code":409,"description":"terminated by other getUpdates request"}' > "$fixture"
  export FAKE_TG_GETUPDATES_FILE="$fixture"
  export FAKE_CURL_LOG="$TMP_ROOT/spin-curl.log"
  : > "$FAKE_CURL_LOG"

  rc=0
  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FM_TG_WAIT_MAX=6 \
    "$ROOT/bin/fm-tg-wait.sh" >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "the waiter must still time out cleanly when Telegram only ever refuses"

  calls=$(grep -c getUpdates "$FAKE_CURL_LOG" || true)
  [ "$calls" -le 5 ] \
    || fail "the waiter made $calls getUpdates calls in 6s against a {\"ok\":false} body; an unusable answer must back off, not re-poll immediately"

  unset FAKE_TG_GETUPDATES_FILE FAKE_CURL_LOG
  pass "telegram: an {\"ok\":false} error body is a failed pass and backs the long poll off, not a free full-speed retry"
}

# --- one long-poll waiter per home ------------------------------------------

test_hook_long_poll_is_single_flight() {
  local home env sbin calls i

  home="$TMP_ROOT/singleflight-home"
  mkdir -p "$home/state/tg-inbox" "$home/state/tg-processed"
  env=$(fm_tg_env "$home")
  sbin=$(fm_tg_scratch_bin "$home/scratch")

  # The harness starts a fresh background firing of this hook on EVERY stop and
  # never dedupes them, and each firing's long poll lives for up to
  # FM_TG_HOOK_MAX. Without a claim, a busy session accumulates waiters that all
  # call getUpdates on the one bot token - which is itself what produces the 409
  # the case above backs off from.
  export FAKE_CURL_LOG="$TMP_ROOT/singleflight-curl.log"
  : > "$FAKE_CURL_LOG"

  i=0
  while [ "$i" -lt 4 ]; do
    ( FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FM_TG_HOOK_MAX=4 \
      "$sbin/fm-tg-hook.sh" >/dev/null 2>&1 </dev/null ) &
    i=$((i + 1))
  done
  wait

  # Four concurrent firings, one waiter: the empty-result fixture returns at
  # once, so a single waiter loops a handful of times in its 4s window while
  # four would multiply that by four. Bound it well under the four-waiter mark.
  calls=$(grep -c getUpdates "$FAKE_CURL_LOG" || true)
  [ "$calls" -gt 0 ] || fail "no firing ran the long poll at all"
  assert_absent "$home/state/.tg-hook.lock" "the waiter claim must be released when the hook exits"

  # And with a waiter already holding the claim, another firing stands down
  # immediately instead of starting a second poll.
  : > "$FAKE_CURL_LOG"
  ( FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FM_TG_HOOK_MAX=4 \
    "$sbin/fm-tg-hook.sh" >/dev/null 2>&1 </dev/null ) &
  local held=$!
  local waited=0
  while [ ! -e "$home/state/.tg-hook.lock" ] && [ "$waited" -lt 40 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$home/state/.tg-hook.lock" ] || fail "the live waiter never published its claim"
  local rc=0
  FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" FM_TG_HOOK_MAX=4 \
    "$sbin/fm-tg-hook.sh" >/dev/null 2>&1 </dev/null || rc=$?
  expect_code 0 "$rc" "a firing that cannot claim the waiter must exit 0, not block the turn"
  wait "$held" 2>/dev/null || true

  unset FAKE_CURL_LOG
  pass "telegram: at most one long-poll waiter is ever live per home, and its claim is released on exit"
}

# --- every kind of message the captain can send is recorded ------------------

test_video_note_and_sticker_are_not_dropped() {
  local home env inbox out

  home="$TMP_ROOT/videonote-home"
  mkdir -p "$home/state"
  env=$(fm_tg_env "$home")
  inbox="$home/state/tg-inbox"

  # A video_note is the round clip a phone records with one tap, and it carries
  # no text and no caption. It was not in the recognised-media list, so the
  # update advanced the offset and vanished: no record, no acknowledgement, no
  # trace on disk, and no way to refetch it. The captain saw his message
  # delivered and then total silence.
  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":true,"result":[{"update_id":300,"message":{"chat":{"id":999},"date":600,"video_note":{"file_id":"vn-1"}}},{"update_id":301,"message":{"chat":{"id":999},"date":601,"sticker":{"file_id":"st-1"}}},{"update_id":302,"message":{"chat":{"id":999},"date":602,"contact":{"phone_number":"1"}}}]}'

  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  unset FAKE_TG_GETUPDATES_FILE
  assert_contains "$out" "telegram: 3 message(s)" "a video_note, a sticker and a contact must all count as messages"
  assert_grep '"media_id": "vn-1"' "$inbox/300.json" "a video_note must be recorded with its file id"
  assert_grep '"media_id": "st-1"' "$inbox/301.json" "a sticker must be recorded with its file id"
  # Something with no text and no fetchable file still has to leave a trace, or
  # it is silence to the captain.
  assert_grep 'contact' "$inbox/302.json" "a message with no text and no file must still be recorded, naming what it was"

  # An update that carries no message at all is not something the captain sent,
  # and must not litter the inbox.
  fm_tg_getupdates_fixture "$TMP_ROOT" \
    '{"ok":true,"result":[{"update_id":303,"my_chat_member":{"chat":{"id":999}}}]}'
  out=$(FM_HOME="$home" FM_TG_ENV_OVERRIDE="$env" "$ROOT/bin/fm-tg-poll.sh")
  unset FAKE_TG_GETUPDATES_FILE
  [ -z "$out" ] || fail "a non-message update must be skipped silently, not surfaced: $out"
  assert_absent "$inbox/303.json" "a non-message update must not be recorded as a captain message"

  pass "telegram: a video_note, a sticker, or any other contentless message is recorded and surfaced instead of silently dropped"
}

# --- retired messages and media do not grow without bound --------------------

test_retired_records_and_media_are_capped() {
  local home inbox done_dir media i kept

  home="$TMP_ROOT/retention-home"
  inbox="$home/state/tg-inbox"
  done_dir="$home/state/tg-processed"
  media="$home/state/tg-media"
  mkdir -p "$inbox" "$done_dir" "$media"

  # Every message the captain has ever sent, and every image, used to be kept
  # for the life of the home - the one artifact here with no bound.
  i=0
  while [ "$i" -lt 620 ]; do
    printf '{"update_id": %d, "ts": %d, "text": "old", "media": "%s/%d.bin"}' \
      "$i" "$i" "$media" "$i" > "$done_dir/$i.json"
    touch -t 202001010000 "$done_dir/$i.json"
    : > "$media/$i.bin"
    touch -t 202001010000 "$media/$i.bin"
    i=$((i + 1))
  done
  # An orphan too young to be sure of: a download whose record has not been
  # updated with its path yet must never be swept.
  : > "$media/in-flight.bin"

  python3 "$ROOT/bin/fm-tg-archive.py" "$inbox" "$done_dir" >/dev/null

  kept=$(find "$done_dir" -name '*.json' | wc -l | tr -d ' ')
  [ "$kept" -eq 500 ] || fail "tg-processed holds $kept retired records; the documented cap is 500"
  assert_present "$media/in-flight.bin" "a media file too young to be provably orphaned must be left alone"

  # Media follows its record: everything a kept record still points at survives,
  # and the media of every pruned record goes with it. Checked as a property
  # rather than by naming files, since which records fall outside the cap is
  # decided by mtime.
  local f id
  for f in "$done_dir"/*.json; do
    id=$(basename "$f" .json)
    assert_present "$media/$id.bin" "media referenced by a kept retired record must not be pruned"
  done
  kept=$(find "$media" -name '*.bin' | wc -l | tr -d ' ')
  [ "$kept" -eq 501 ] || fail "tg-media holds $kept files; expected the 500 still referenced plus the one in-flight orphan"

  pass "telegram: retired messages and downloaded media are held to a documented cap instead of growing for ever"
}

test_wait_backs_off_on_error_body
test_hook_long_poll_is_single_flight
test_video_note_and_sticker_are_not_dropped
test_retired_records_and_media_are_capped
test_bootstrap_registers_poll_shim
test_cadence_config_is_actually_usable
test_guard_block_budget_bounded
test_poll_records_before_slow_work
test_undownloadable_media_still_surfaces
test_unsurfaced_retirement_is_recorded
test_config_absent_hooks_silent
test_crew_worktree_refuses
test_isfirstmate_direct
test_arrival_ack_guard_reply_pipeline
test_archive_never_surfaced_same_turn_retires
test_archive_never_surfaced_old_stays_pending
test_archive_never_surfaced_boundary
test_archive_surfaced_always_retires_regardless_of_age
test_archive_missing_ts_never_retired
test_fetch_drops_mismatched_chat_id
test_fetch_accepts_matching_chat_id
test_fetch_survives_unusable_update_id
test_fetch_nonmessage_update_is_not_a_chat_mismatch
test_multiple_messages_mid_turn_none_swallowed
test_drain_retries_failed_ack
test_large_png_uses_senddocument
test_small_png_uses_sendphoto
test_upload_timeout_explicit_message
test_send_retries_transient_failure_then_succeeds
test_send_does_not_retry_a_real_rejection
test_send_gives_up_after_3_transient_failures
test_poll_sh_end_to_end
test_poll_reports_a_refusal_once
test_poll_without_a_timeout_binary
test_records_are_private_and_left_whole
