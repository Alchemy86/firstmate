#!/usr/bin/env bash
# Tests for fm-pr-watch.sh, the PR review triggers.
#
# The case that matters most is the one the script exists for: a home with no
# config must REFUSE, loudly and by name, rather than watch nothing. These three
# checks previously lived only in gitignored state/, so a reinstall lost them and
# nothing reported the loss - a check watching zero repositories reports nothing
# on every poll and looks exactly like a check with nothing to report. So
# test_missing_config_refuses_to_arm and test_missing_config_reports_itself pin
# both halves of that, and test_reinstall_rearms_every_trigger reproduces the
# reinstall by removing a scratch home's whole state directory.
#
# The forge is faked for every case: a stub gh answers from fixture files, so no
# case lists, reads, or comments on a real repository.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-pr-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-watch)

# A home with a state and config directory, and a fake gh on PATH whose answers
# this case writes into the home's own fixture directory.
make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/fixtures"
  cat > "$home/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh. Answers exactly the two shapes fm-pr-watch.sh asks for, from files
# named after the repository, and answers nothing for any other call. The
# repository is read from the argument that carries it - "-R <owner>/<repo>" for
# a listing, "repos/<owner>/<repo>/..." for the comments endpoint - so the jq
# program's own slashes are never mistaken for a path.
repo=
case "${1:-}" in
  pr)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -R ]; then repo=${2##*/}; break; fi
      shift
    done
    f="$FIXTURES/prs.$repo"
    ;;
  api)
    for arg in "$@"; do
      case "$arg" in
        repos/*)
          arg=${arg#repos/}
          arg=${arg#*/}
          repo=${arg%%/*}
          break
          ;;
      esac
    done
    f="$FIXTURES/comments.$repo"
    ;;
  *) exit 0 ;;
esac
[ -n "$repo" ] && [ -f "$f" ] && cat "$f"
exit 0
SH
  chmod +x "$home/gh"
  printf '%s\n' "$home"
}

write_config() {
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/pr-watch.env"
}

# run_check <home> <mode>: capture stdout, stderr, and status of one check.
run_check() {
  local home=$1 mode=$2
  OUT=$(FM_HOME="$home" FIXTURES="$home/fixtures" FM_PR_WATCH_GH="$home/gh" \
    "$WATCH" check "$mode" 2>"$TMP_ROOT/err")
  RC=$?
  ERR=$(cat "$TMP_ROOT/err")
}

run_arm() {
  local home=$1
  shift
  OUT=$(FM_HOME="$home" FM_PR_WATCH_GH="$home/gh" "$WATCH" arm "$@" 2>&1)
  RC=$?
}

# A PR line is what gh's own --jq produces for this script: number, author,
# title, tab separated. Drafts never reach it, because the query excludes them.
pr_line() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }
comment_line() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }

# --- the refusal this script exists for -------------------------------------

test_missing_config_refuses_to_arm() {
  local home
  home=$(make_home missing-arm)
  run_arm "$home"
  expect_code 1 "$RC" "arm with no config"
  assert_contains "$OUT" "FM_PR_WATCH_OWNER" "arm must name the missing owner"
  assert_contains "$OUT" "FM_PR_WATCH_REPOS" "arm must name the missing repositories"
  assert_contains "$OUT" "FM_PR_WATCH_OURS" "arm must name the missing logins"
  assert_absent "$home/state/pr-new.check.sh" "arm must not write a shim it cannot configure"
  assert_absent "$home/state/pr-ours.check.sh" "arm must not write a shim it cannot configure"
  assert_absent "$home/state/pr-comments.check.sh" "arm must not write a shim it cannot configure"
  pass "pr-watch: arm refuses without config, naming every missing requirement"
}

test_missing_config_reports_itself() {
  local home
  home=$(make_home missing-check)
  run_check "$home" new
  assert_contains "$OUT" "is not configured" "an unconfigured check must report itself, not go quiet"
  assert_contains "$OUT" "FM_PR_WATCH_OWNER" "the reported line must name the requirement"
  assert_contains "$ERR" "no PR watch config" "the problem must also reach an operator running it by hand"
  pass "pr-watch: an unconfigured check reports the problem instead of watching nothing"
}

test_incomplete_config_names_only_what_is_missing() {
  local home
  home=$(make_home incomplete)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"'
  run_arm "$home"
  expect_code 1 "$RC" "arm with an incomplete config"
  assert_contains "$OUT" "FM_PR_WATCH_OURS" "must name the value that is actually missing"
  assert_not_contains "$OUT" "FM_PR_WATCH_OWNER" "must not name a value that is present"
  pass "pr-watch: an incomplete config names exactly the missing value"
}

# --- the three modes --------------------------------------------------------

test_new_reports_other_peoples_prs_only() {
  local home
  home=$(make_home mode-new)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work us-personal"'
  {
    pr_line 11 outsider "a change from someone else"
    pr_line 12 us-work "our own work"
    pr_line 13 app/renovate "a bot bump"
  } > "$home/fixtures/prs.one"
  run_check "$home" new
  expect_code 0 "$RC" "check new"
  assert_contains "$OUT" "one #11 outsider" "must report the other person's PR"
  assert_not_contains "$OUT" "#12" "must not report our own PR as one to review for others"
  assert_not_contains "$OUT" "#13" "must not report a bot's PR"
  run_check "$home" new
  [ -z "$OUT" ] || fail "pr-watch: a second poll must be silent, got: $OUT"
  pass "pr-watch: new reports other people's PRs once, and skips ours and bots"
}

test_ours_reports_our_prs_only() {
  local home
  home=$(make_home mode-ours)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work us-personal"'
  {
    pr_line 21 outsider "not ours"
    pr_line 22 us-personal "ours, needs a review"
  } > "$home/fixtures/prs.one"
  run_check "$home" ours
  assert_contains "$OUT" "one #22" "must report our own PR"
  assert_not_contains "$OUT" "#21" "must not report someone else's PR as ours"
  run_check "$home" ours
  [ -z "$OUT" ] || fail "pr-watch: a second poll must be silent, got: $OUT"
  pass "pr-watch: ours reports our own PRs once"
}

test_comments_reports_other_peoples_comments_on_our_prs() {
  local home
  home=$(make_home mode-comments)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work"'
  {
    pr_line 31 us-work "our PR"
    pr_line 32 outsider "their PR"
  } > "$home/fixtures/prs.one"
  {
    comment_line 900 reviewer 31 "this drops a field when the input is blank"
    comment_line 901 "ci-bot[bot]" 31 "coverage report"
    comment_line 902 us-work 31 "our own reply"
    comment_line 903 reviewer 32 "a comment on someone else's PR"
  } > "$home/fixtures/comments.one"
  run_check "$home" comments
  assert_contains "$OUT" "reviewer: this drops a field" "must report a real review comment on our PR"
  assert_not_contains "$OUT" "coverage report" "must not report a bot's comment"
  assert_not_contains "$OUT" "our own reply" "must not report our own comment"
  assert_not_contains "$OUT" "#32" "must not report a comment on a PR that is not ours"
  run_check "$home" comments
  [ -z "$OUT" ] || fail "pr-watch: a second poll must be silent, got: $OUT"
  pass "pr-watch: comments reports other people's review comments on our own PRs only"
}

# A report too long for one line must HOLD the rest, not retire them. Retiring an
# item that never appeared in a line is the one way this check can lose a PR
# permanently, because the seen list would never offer it again.
test_a_cut_report_holds_the_rest_for_the_next_poll() {
  local home i first second
  home=$(make_home overflow)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work"'
  : > "$home/fixtures/prs.one"
  i=1
  while [ "$i" -le 40 ]; do
    pr_line "$i" us-work "a title long enough that forty of these cannot fit on one reported line" \
      >> "$home/fixtures/prs.one"
    i=$((i + 1))
  done
  run_check "$home" ours
  first=$OUT
  assert_contains "$first" "more held for the next poll" "a cut report must disclose what it held"
  run_check "$home" ours
  second=$OUT
  [ -n "$second" ] || fail "pr-watch: the held PRs must be reported on the next poll, not lost"
  assert_not_contains "$second" "#1:" "a PR already reported must not repeat"
  pass "pr-watch: a report too long for one line holds the rest instead of losing them"
}

# --- arming, trust, and reinstall -------------------------------------------

# The watcher runs a custom check only through its own trust binding, so that
# binding - not the file's presence - is what proves a check is really armed.
assert_watcher_accepts() {
  local home=$1 id=$2 msg=$3
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2/state" "$3"' _ "$ROOT" "$home" "$id" \
    || fail "$msg"
}

test_arm_registers_every_trigger() {
  local home
  home=$(make_home arming)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work"'
  run_arm "$home"
  expect_code 0 "$RC" "arm with a complete config"
  for id in pr-comments pr-new pr-ours; do
    assert_present "$home/state/$id.check.sh" "arm must write state/$id.check.sh"
    assert_watcher_accepts "$home" "$id" "the watcher must accept the armed $id"
  done
  pass "pr-watch: arm writes and registers all three triggers"
}

test_a_tampered_shim_loses_its_binding() {
  local home
  home=$(make_home tampered)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work"'
  run_arm "$home"
  printf '# changed\n' >> "$home/state/pr-new.check.sh"
  bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-check-lib.sh"
    fm_custom_check_registered "$2/state" pr-new' _ "$ROOT" "$home" \
    && fail "pr-watch: a changed shim must lose its binding"
  pass "pr-watch: a changed shim is no longer a registered check"
}

test_reinstall_rearms_every_trigger() {
  local home
  home=$(make_home reinstall)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work"'
  run_arm "$home"
  expect_code 0 "$RC" "first arm"
  # What a reinstall actually does: the tracked script and the local config
  # survive, and the whole gitignored state directory does not.
  rm -rf "$home/state"
  assert_absent "$home/state/pr-new.check.sh" "the reinstall must really remove the triggers"
  run_arm "$home"
  expect_code 0 "$RC" "re-arm after a reinstall"
  for id in pr-comments pr-new pr-ours; do
    assert_present "$home/state/$id.check.sh" "re-arm must restore state/$id.check.sh"
    assert_watcher_accepts "$home" "$id" "the watcher must accept the restored $id"
  done
  pass "pr-watch: one arm restores all three triggers after a reinstall"
}

test_disarm_removes_only_its_own_files() {
  local home
  home=$(make_home disarming)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work"'
  run_arm "$home"
  : > "$home/state/unrelated.check.sh"
  FM_HOME="$home" "$WATCH" disarm >/dev/null 2>&1 || fail "pr-watch: disarm must succeed"
  assert_absent "$home/state/pr-new.check.sh" "disarm must remove the shim"
  assert_absent "$home/state/pr-new.check-trust" "disarm must remove the binding"
  assert_present "$home/state/unrelated.check.sh" "disarm must not touch another check"
  pass "pr-watch: disarm removes its own shims and bindings and nothing else"
}

# Every path this script removes is built from the state directory and a mode
# name. A state directory it cannot prove would put those removals somewhere
# else entirely, so it has to refuse before the first rm rather than after.
test_disarm_refuses_an_unusable_state_directory() {
  local home out rc
  home=$(make_home unusable-state)
  : > "$home/not-a-directory"
  out=$(FM_STATE_OVERRIDE="$home/not-a-directory" "$WATCH" disarm new 2>&1)
  rc=$?
  expect_code 1 "$rc" "disarm with a state path that is not a directory"
  assert_contains "$out" "not a usable state directory" "the refusal must name the unusable path"
  out=$(FM_STATE_OVERRIDE="relative/state" "$WATCH" disarm new 2>&1)
  rc=$?
  expect_code 1 "$rc" "disarm with a relative state path"
  assert_contains "$out" "not an absolute path" "the refusal must name the relative path"
  # The refusal has to happen BEFORE the first removal, so a state directory the
  # script will not accept still has everything in it afterwards. A symlinked
  # state directory is refused for its own reasons and doubles as the decoy.
  mkdir -p "$home/real-state"
  ln -s "$home/real-state" "$home/linked-state"
  : > "$home/real-state/pr-new.check.sh"
  : > "$home/real-state/pr-new.check-trust"
  : > "$home/real-state/.pr-new-seen"
  out=$(FM_STATE_OVERRIDE="$home/linked-state" "$WATCH" disarm new 2>&1)
  rc=$?
  expect_code 1 "$rc" "disarm through a symlinked state directory"
  assert_present "$home/real-state/pr-new.check.sh" "a refused disarm must remove no shim"
  assert_present "$home/real-state/pr-new.check-trust" "a refused disarm must remove no binding"
  assert_present "$home/real-state/.pr-new-seen" "a refused disarm must remove no seen list"
  pass "pr-watch: disarm refuses an unusable state directory and removes nothing"
}

test_an_unknown_mode_refuses_the_whole_invocation() {
  local home out rc
  home=$(make_home unknown-mode)
  write_config "$home" 'FM_PR_WATCH_OWNER=acme' 'FM_PR_WATCH_REPOS="one"' \
    'FM_PR_WATCH_OURS="us-work"'
  out=$(FM_HOME="$home" "$WATCH" arm new nonsense 2>&1)
  rc=$?
  expect_code 2 "$rc" "arm with an unknown mode"
  assert_contains "$out" "unknown mode: nonsense" "must name the mode it does not own"
  assert_absent "$home/state/pr-new.check.sh" "a refused invocation must arm nothing at all"
  pass "pr-watch: an unknown mode refuses the whole invocation rather than half-arming"
}

test_missing_config_refuses_to_arm
test_missing_config_reports_itself
test_incomplete_config_names_only_what_is_missing
test_new_reports_other_peoples_prs_only
test_ours_reports_our_prs_only
test_comments_reports_other_peoples_comments_on_our_prs
test_a_cut_report_holds_the_rest_for_the_next_poll
test_arm_registers_every_trigger
test_a_tampered_shim_loses_its_binding
test_reinstall_rearms_every_trigger
test_disarm_removes_only_its_own_files
test_disarm_refuses_an_unusable_state_directory
test_an_unknown_mode_refuses_the_whole_invocation
