#!/usr/bin/env bash
# End-to-end tests for the Situation Room Claude Work bridge: that publish maps
# the backlog onto the board's data contract (including the derived held and
# blocked states and the exclusion of rows that are not tasks), and that a
# drained answer genuinely reaches the one keyed-answer intake rather than
# merely running without error.
#
# The OpenSearch boundary is faked at curl, so this runs with no cluster.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUBLISH="$ROOT/bin/fm-situationroom-publish.sh"
DRAIN="$ROOT/bin/fm-situationroom-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-situationroom)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  cat > "$home/sr.env" <<EOF
SR_OPENSEARCH_URL=http://127.0.0.1:9
SR_OPENSEARCH_USER=u
SR_OPENSEARCH_PASSWORD=p
EOF
  printf '%s\n' "$home"
}

tasks_in() {  # <home> <args...>
  local home=$1; shift
  (cd "$home" && FM_HOME="$home" tasks-axi "$@")
}

run_publish() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SR_ENV_OVERRIDE="$home/sr.env" \
    "$PUBLISH" "$@"
}

run_drain() {  # <home> <args...>
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SR_ENV_OVERRIDE="$home/sr.env" \
    "$DRAIN" "$@"
}

# A curl that serves the answers search and records every write it is handed.
install_fake_curl() {  # <home> <answers-json>
  local home=$1 answers=$2
  printf '%s' "$answers" > "$home/answers.json"
  cat > "$home/fakebin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) body=${2#@}; shift 2 ;;
    http*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$url" "$body" >> "$FAKE_CURL_LOG"
case "$url" in
  *_search*) cat "$FAKE_CURL_ANSWERS" > "$out" ;;
  *_update*) printf '{"result":"updated"}' > "$out"
             [ -n "$body" ] && cat "$body" >> "$FAKE_CURL_LOG" ;;
  *) printf '{"errors":false,"items":[]}' > "$out" ;;
esac
printf '200'
EOF
  chmod +x "$home/fakebin/curl"
}

# The wake drain hook: it must fire where it is wired, and a board outage must
# never change the drain's exit status, because supervision runs through it.
test_wake_drain_hook_fires_and_cannot_break_supervision() {
  local home out rc=0
  home=$(make_home drain-hook)
  # An endpoint that refuses connections stands in for a board outage.
  cat > "$home/sr.env" <<EOF
SR_OPENSEARCH_URL=http://127.0.0.1:1
SR_OPENSEARCH_USER=u
SR_OPENSEARCH_PASSWORD=p
EOF
  printf 'note: a bootstrap line\n' > "$home/state/task1.status"
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SR_ENV_OVERRIDE="$home/sr.env" \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1) || rc=$?
  assert_equals 0 "$rc" "a board outage must not fail the wake drain"
  assert_contains "$out" "situation room drain did not complete" \
    "the hook fires on a plain drain and reports the outage loudly"
  pass "the wake drain hook fires and an outage cannot break supervision"
}

test_wake_drain_hook_is_inert_without_config() {
  local home out rc=0
  home=$(make_home drain-hook-inert)
  printf 'note: a bootstrap line\n' > "$home/state/task1.status"
  out=$(PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SR_ENV_OVERRIDE="$home/absent.env" \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1) || rc=$?
  assert_equals 0 "$rc" "an unconfigured home drains normally"
  assert_not_contains "$out" "situation room" \
    "an unconfigured home makes no board call at all"
  pass "the integration is inert in a home that never opted in"
}

test_publish_maps_the_board_contract() {
  local home out
  home=$(make_home publish-contract)
  tasks_in "$home" add sr-ship "ship a thing" --kind ship --repo demo --start >/dev/null
  tasks_in "$home" add sr-dep "a blocker" --kind ship --repo demo >/dev/null
  tasks_in "$home" add sr-blocked "waits on dep" --kind ship --repo demo \
    --blocked-by sr-dep >/dev/null
  tasks_in "$home" add sr-review "a review row" --kind review --repo demo >/dev/null
  "$ROOT/bin/fm-captain-hold.sh" hold sr-ship --reason "needs a call" >/dev/null 2>&1 \
    || FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold sr-ship --reason "needs a call" >/dev/null

  out=$(run_publish "$home" --dry-run) || fail "publish --dry-run failed"
  assert_contains "$out" '"id":"sr-blocked"' "blocked task is published"
  assert_contains "$out" '"state":"blocked"' "an unresolved blocker derives state blocked"
  assert_contains "$out" '"blockedBy":["sr-dep"]' "blockedBy carries the blocker id"
  assert_contains "$out" '"kind":"task"' "a kind outside the board vocabulary collapses to task"
  assert_not_contains "$out" '"kind":"review"' "review is not a board kind"
  assert_contains "$out" '"_id":"sr-ship"' "documents are addressed by task id"
  pass "publish maps the backlog onto the board data contract"
}

test_publish_excludes_rows_that_are_not_tasks() {
  local home out
  home=$(make_home publish-unstructured)
  tasks_in "$home" add sr-real "a real task" --kind ship --repo demo >/dev/null
  printf 'A continuation line that carries no task id.\n' >> "$home/data/backlog.md"
  out=$(run_publish "$home" --dry-run) || fail "publish --dry-run failed"
  assert_contains "$out" '"_id":"sr-real"' "the structured task is published"
  assert_not_contains "$out" '"_id":""' "an unstructured line never claims an empty id"
  assert_not_contains "$out" 'continuation line' "an unstructured line is not a board document"
  pass "publish excludes backlog rows that are not tasks"
}

test_publish_refuses_an_empty_board() {
  local home rc=0
  home=$(make_home publish-empty)
  run_publish "$home" --dry-run >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an empty snapshot must not publish an empty board"
  pass "publish refuses to blank the board from an empty snapshot"
}

test_drain_reaches_the_keyed_answer_intake() {
  local home out body
  home=$(make_home drain-intake)
  tasks_in "$home" add sr-call "should we do the thing" --kind captain >/dev/null
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" \
    "$ROOT/bin/fm-captain-hold.sh" hold sr-call --reason "captain must choose" >/dev/null \
    || fail "could not place the captain hold"

  install_fake_curl "$home" '{"hits":{"hits":[{"_id":"a1","_source":{"taskId":"sr-call","text":"yes, go ahead","author":"dana","consumed":false}}]}}'
  out=$(FAKE_CURL_LOG="$home/curl.log" FAKE_CURL_ANSWERS="$home/answers.json" \
    run_drain "$home") || fail "drain failed: $out"

  assert_contains "$out" "1 to captain calls" "the answer routed to a captain call"
  body=$(tasks_in "$home" show sr-call --full)
  assert_contains "$body" "yes, go ahead" "the captain's words are recorded on the task"
  assert_contains "$body" "situationroom" "the answer records its Situation Room provenance"
  assert_grep "_update/a1" "$home/curl.log" "the drained document is marked consumed"
  assert_grep '"consumed":true' "$home/curl.log" "consumed is set true after routing"
  pass "a drained answer reaches the keyed-answer intake and closes the call"
}

test_drain_files_a_general_note_to_the_backlog() {
  local home out before after
  home=$(make_home drain-note)
  before=$(tasks_in "$home" list --kind captain --limit 99 | head -1)
  install_fake_curl "$home" '{"hits":{"hits":[{"_id":"n1","_source":{"taskId":null,"text":"the dashboard looks wrong on mobile","author":"sam","consumed":false}}]}}'
  out=$(FAKE_CURL_LOG="$home/curl.log" FAKE_CURL_ANSWERS="$home/answers.json" \
    run_drain "$home") || fail "drain failed: $out"
  assert_contains "$out" "1 filed to backlog" "a general note becomes a durable captain-held item"
  after=$(tasks_in "$home" list --kind captain --limit 99)
  assert_contains "$after" "dashboard looks wrong" "the note's text reaches the backlog"
  assert_not_equals "$before" "$after" "the backlog gained the note"
  pass "a general note is filed to the backlog rather than lost"
}

test_publish_maps_the_board_contract
test_publish_excludes_rows_that_are_not_tasks
test_publish_refuses_an_empty_board
test_drain_reaches_the_keyed_answer_intake
test_drain_files_a_general_note_to_the_backlog
test_wake_drain_hook_fires_and_cannot_break_supervision
test_wake_drain_hook_is_inert_without_config
