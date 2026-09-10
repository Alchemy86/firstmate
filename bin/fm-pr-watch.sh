#!/usr/bin/env bash
# fm-pr-watch.sh - report pull requests and review comments that need a review,
# and arm its own watcher polls.
#
# Usage:
#   fm-pr-watch.sh check <comments|new|ours>
#   fm-pr-watch.sh arm [mode...]
#   fm-pr-watch.sh disarm [mode...]
#   fm-pr-watch.sh --help
#
# Three modes, one per thing worth waking firstmate for:
#
#   comments  a new review comment landed on one of OUR open PRs.
#   new       someone else opened a non-draft PR, so it needs reviewing.
#   ours      we opened a non-draft PR, so it needs reviewing before a human is
#             asked to look at it.
#
# `check <mode>` prints one line when that mode has something to report and
# prints nothing at all otherwise, so it composes with the existing watcher
# state-check contract instead of needing a schedule of its own. `arm` writes
# state/pr-<mode>.check.sh and binds its bytes with fm-check-register.sh, so the
# watcher dispatches it on its normal FM_CHECK_INTERVAL cadence and turns its one
# line into a `check:` wake. `disarm` removes the shims, their trust bindings,
# their seen lists, and their report records.
#
# WHY THIS SCRIPT IS TRACKED. Its three checks previously existed only as
# hand-written state/*.check.sh files, and state/ is gitignored, so a reinstall
# lost all three silently: the watcher simply had nothing to dispatch and no
# component reported the absence. The durable logic is tracked here, and only the
# per-home shims, seen lists, and records stay local.
#
# WHY IT REFUSES RATHER THAN WATCHING NOTHING. Every per-machine value - the
# forge owner, the repositories, and the logins that count as ours - lives in
# local config/pr-watch.env. A check with no configuration would report nothing
# on every poll and be indistinguishable from a check with nothing to report,
# which is the exact failure this script exists to prevent. So a missing or
# incomplete config refuses to arm and names the requirement it is missing, and
# an armed check whose config later goes missing reports that as its one line
# instead of going quiet.
#
# WHY EVERY REMOVAL IS GUARDED. disarm deletes paths built from $STATE and a
# mode name. An empty or unset $STATE would put those deletions at the
# filesystem root, so the state directory and every id are proven before any rm
# runs, and a failure names the exact value that was not usable.
#
# WHAT IT NEVER DOES. It reports; it reviews, comments, approves, merges, and
# writes to a forge never. Every forge call it makes is a read.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_PR_WATCH_CONFIG_OVERRIDE:-${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/pr-watch.env}"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
GH_BIN=${FM_PR_WATCH_GH:-gh}
MODES='comments new ours'
# Wider than the digest default because one report line names several PRs across
# several repositories, each with an author and a title.
MAX_LINE=1000
# Newest review comments read per repository in one call, and open PRs listed per
# repository. Both bound one poll's work, and the newest entries are the ones a
# poll can still be seeing for the first time.
COMMENT_LIMIT=100
PR_LIMIT=40
# A seen list is trimmed back to its newest entries once it grows past this, so a
# long-lived home does not carry an unbounded file for a dedupe window that only
# ever needs the recent past.
SEEN_MAX=5000
SEEN_KEEP=2000

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-pr-watch.sh check <comments|new|ours>   report that mode (silent when there is nothing)
  fm-pr-watch.sh arm [mode...]               write and register state/pr-<mode>.check.sh
  fm-pr-watch.sh disarm [mode...]            remove the shims, bindings, seen lists, and records
  fm-pr-watch.sh --help                      print this help

Modes: comments (a new review comment on one of our open PRs), new (someone else
opened a non-draft PR), ours (we opened a non-draft PR). arm and disarm act on
all three when no mode is named.

Per-machine settings are read from config/pr-watch.env (local, gitignored).
See docs/configuration.md for the schema and docs/examples/pr-watch.env for a
starting point. How to review what these report is the pr-review skill's, not
this script's.
EOF
}

die_usage() {
  printf 'fm-pr-watch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

PROBE_SECS=${FM_PR_WATCH_PROBE_SECS:-8}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-watch: FM_PR_WATCH_PROBE_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$PROBE_SECS" -gt 30 ]; then
  printf 'fm-pr-watch: FM_PR_WATCH_PROBE_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

BUDGET_SECS=${FM_PR_WATCH_BUDGET_SECS:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-watch: FM_PR_WATCH_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -gt 120 ]; then
  printf 'fm-pr-watch: FM_PR_WATCH_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
  exit 2
fi

# How long the same report line stays suppressed after it has been reported once.
# A finding line never repeats, because the seen lists retire it; the line this
# gate actually governs is a standing problem - a config that went missing, or a
# sweep that keeps running out of budget - which must stay loud without waking
# firstmate on every poll.
REPEAT_SECS=${FM_PR_WATCH_REPEAT_SECS:-3600}
case "$REPEAT_SECS" in
  ''|*[!0-9]*)
    printf 'fm-pr-watch: FM_PR_WATCH_REPEAT_SECS must be a whole number of seconds\n' >&2
    exit 2
    ;;
esac

# The watcher's per check bound, read from this check's own environment, exactly
# as bin/fm-tool-update-check.sh reads it: the watcher runs the check as a direct
# child, so an operator who raised it is seen here too.
CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
# A call started with a second left still gets its whole bound, and the runner is
# asked for a kill grace of its own, so the sweep has to stop this far short of
# the watcher's bound. A run the watcher kills prints nothing and records
# nothing, and would then repeat that silence on every poll.
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_SECS - 2))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi

now_epoch() { date +%s; }

# --- path guards ------------------------------------------------------------
#
# Every path this script writes or removes is built from $STATE and a mode name.
# Neither is proven by construction: $STATE comes from the environment, and a
# mode reaches an action through an argument. So both are proven here, and a
# caller that cannot prove them is refused by name rather than allowed to build
# a path that would land at the filesystem root.

# --quiet is for the best-effort report record, whose failure is not itself worth
# a line; every path that removes or writes something an operator depends on
# leaves it off and gets the refusal by name.
state_dir_usable() {
  local quiet=
  [ "${1:-}" = --quiet ] && quiet=1
  if [ -z "$STATE" ]; then
    [ -n "$quiet" ] || printf 'fm-pr-watch: the state directory is unset (FM_STATE_OVERRIDE or FM_HOME/state)\n' >&2
    return 1
  fi
  case "$STATE" in
    /*) : ;;
    *)
      [ -n "$quiet" ] || printf 'fm-pr-watch: the state directory is not an absolute path: %s\n' "$STATE" >&2
      return 1
      ;;
  esac
  if [ ! -d "$STATE" ] || [ -L "$STATE" ]; then
    [ -n "$quiet" ] || printf 'fm-pr-watch: not a usable state directory: %s\n' "$STATE" >&2
    return 1
  fi
  return 0
}

mode_valid() {
  case " $MODES " in
    *" ${1-} "*) return 0 ;;
  esac
  return 1
}

# The check id a mode owns. Refused unless the mode is one of this script's own
# and the id it builds is still a path-safe single segment, which is the same
# rule fm-check-register.sh applies before it will bind anything.
check_id_for_mode() {
  local mode=${1-} id
  if ! mode_valid "$mode"; then
    printf 'fm-pr-watch: not a mode this script owns: %s\n' "${mode:-<empty>}" >&2
    return 1
  fi
  id="pr-$mode"
  if ! fm_pr_task_id_valid "$id"; then
    printf 'fm-pr-watch: not a usable check id: %s\n' "$id" >&2
    return 1
  fi
  printf '%s\n' "$id"
}

# --- configuration ----------------------------------------------------------

CONFIG_PROBLEM=

# A per-machine value is a repository, owner, or login name, and every one of
# them is pasted into a forge argument. Anything outside that character set is
# refused by name rather than sent, so a stray quote or space in a hand-edited
# config cannot become an argument of its own.
token_valid() {
  case "${1-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

list_valid() {
  local item
  for item in $1; do
    token_valid "$item" || return 1
  done
  return 0
}

# Sets CONFIG_PROBLEM and returns 1 when this home cannot watch anything. The
# problem text names the exact missing requirement, because "watching nothing"
# and "nothing to report" look identical from the outside.
config_load() {
  local missing=
  CONFIG_PROBLEM=
  if [ ! -f "$CONFIG" ]; then
    CONFIG_PROBLEM="no PR watch config at $CONFIG (needs FM_PR_WATCH_OWNER, FM_PR_WATCH_REPOS, FM_PR_WATCH_OURS)"
    return 1
  fi
  set -a
  # shellcheck source=/dev/null # a resolved runtime path, not a repo file
  . "$CONFIG" || {
    set +a
    CONFIG_PROBLEM="cannot read $CONFIG"
    return 1
  }
  set +a
  [ -n "${FM_PR_WATCH_OWNER:-}" ] || missing="$missing, FM_PR_WATCH_OWNER"
  [ -n "${FM_PR_WATCH_REPOS:-}" ] || missing="$missing, FM_PR_WATCH_REPOS"
  [ -n "${FM_PR_WATCH_OURS:-}" ] || missing="$missing, FM_PR_WATCH_OURS"
  if [ -n "$missing" ]; then
    CONFIG_PROBLEM="$CONFIG is missing ${missing#, }"
    return 1
  fi
  if ! token_valid "$FM_PR_WATCH_OWNER"; then
    CONFIG_PROBLEM="FM_PR_WATCH_OWNER in $CONFIG is not a forge owner name"
    return 1
  fi
  if ! list_valid "$FM_PR_WATCH_REPOS" \
    || ! list_valid "${FM_PR_WATCH_REPOS_COMMENTS:-placeholder}" \
    || ! list_valid "${FM_PR_WATCH_REPOS_NEW:-placeholder}" \
    || ! list_valid "${FM_PR_WATCH_REPOS_OURS:-placeholder}"; then
    CONFIG_PROBLEM="a repository name in $CONFIG is not a repository name"
    return 1
  fi
  if ! list_valid "$FM_PR_WATCH_OURS"; then
    CONFIG_PROBLEM="a login in FM_PR_WATCH_OURS in $CONFIG is not an account login"
    return 1
  fi
  return 0
}

# Each mode may name its own repository list, because a home does not always want
# the same breadth for every trigger: watching our own PRs across every
# repository we push to is cheap, while reviewing everyone else's is a choice.
repos_for_mode() {
  case "$1" in
    comments) printf '%s\n' "${FM_PR_WATCH_REPOS_COMMENTS:-$FM_PR_WATCH_REPOS}" ;;
    new) printf '%s\n' "${FM_PR_WATCH_REPOS_NEW:-$FM_PR_WATCH_REPOS}" ;;
    ours) printf '%s\n' "${FM_PR_WATCH_REPOS_OURS:-$FM_PR_WATCH_REPOS}" ;;
  esac
}

is_ours() {
  local login=$1 ours
  for ours in $FM_PR_WATCH_OURS; do
    [ "$login" = "$ours" ] && return 0
  done
  return 1
}

# A forge app or automation is never a reviewer worth waking for, and never an
# author worth reviewing. gh spells an app author "app/<name>"; the REST comment
# author carries the "[bot]" suffix instead.
is_bot() {
  case "$1" in
    ''|app/*|*'[bot]'|github-actions*) return 0 ;;
  esac
  return 1
}

# --- bounded forge calls ----------------------------------------------------

DEADLINE=0
INCOMPLETE=

budget_spent() {
  [ "$(now_epoch)" -ge "$DEADLINE" ]
}

# Every forge call is bounded, and the whole sweep is bounded, so a slow or
# unreachable forge costs one poll rather than the watcher's own bound.
gh_run() {
  fm_run_timed "$PROBE_SECS" "$GH_BIN" "$@" 2>/dev/null
}

# --- report record ----------------------------------------------------------
#
# The record holds the epoch and the exact line last reported for this mode. A
# line identical to the last one is reported again only after REPEAT_SECS, so a
# standing problem stays visible without waking firstmate every poll, and a
# changed line is always reported at once.

record_path() {
  local mode=$1
  state_dir_usable --quiet || return 1
  mode_valid "$mode" || return 1
  printf '%s\n' "$STATE/.pr-watch-$mode"
}

record_should_report() {
  local mode=$1 line=$2 path last_epoch last_line now
  path=$(record_path "$mode") || return 0
  [ -f "$path" ] || return 0
  IFS=$(printf '\t') read -r last_epoch last_line < "$path" 2>/dev/null || return 0
  [ "$last_line" = "$line" ] || return 0
  case "$last_epoch" in ''|*[!0-9]*) return 0 ;; esac
  now=$(now_epoch)
  [ "$((now - last_epoch))" -ge "$REPEAT_SECS" ]
}

record_write() {
  local mode=$1 line=$2 path tmp
  path=$(record_path "$mode") || return 0
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-watch-record.XXXXXX" 2>/dev/null) || return 0
  printf '%s\t%s\n' "$(now_epoch)" "$line" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
  mv -f -- "$tmp" "$path" 2>/dev/null || rm -f -- "$tmp"
  return 0
}

# --- seen lists -------------------------------------------------------------
#
# Per-machine runtime state, never tracked: the whole point of the list is what
# THIS home has already reported. An entry is recorded before the item is
# filtered, so a bot's comment is retired the first time it is read rather than
# re-read on every poll.

seen_path() {
  local mode=$1
  state_dir_usable || return 1
  mode_valid "$mode" || { printf 'fm-pr-watch: not a mode this script owns: %s\n' "$mode" >&2; return 1; }
  printf '%s\n' "$STATE/.pr-$mode-seen"
}

SEEN_FILE=
SEEN_NEW=

seen_open() {
  SEEN_NEW=
  SEEN_FILE=$(seen_path "$1") || return 1
  # Private like the rest of state/: the list records which of this home's PRs
  # and comments have already been reported.
  [ -e "$SEEN_FILE" ] || (umask 077; : > "$SEEN_FILE") 2>/dev/null || return 1
  return 0
}

# 0 when this key has not been retired yet, either in the durable list or
# earlier in this same sweep.
seen_has() {
  local key=$1
  grep -qxF -- "$key" "$SEEN_FILE" 2>/dev/null && return 0
  case "$SEEN_NEW" in
    *"|$key|"*) return 0 ;;
  esac
  return 1
}

# Retire a key. Called for an item the moment it is decided against reporting,
# and for a reported item only once it is actually in the line that goes out, so
# nothing is retired by a report it never appeared in.
seen_mark() {
  local key=$1
  seen_has "$key" && return 0
  SEEN_NEW="$SEEN_NEW|$key|"
  printf '%s\n' "$key" >> "$SEEN_FILE" 2>/dev/null || return 1
  return 0
}

seen_trim() {
  local lines tmp
  lines=$(wc -l < "$SEEN_FILE" 2>/dev/null | tr -d ' ') || return 0
  case "$lines" in ''|*[!0-9]*) return 0 ;; esac
  [ "$lines" -gt "$SEEN_MAX" ] || return 0
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-watch-seen.XXXXXX" 2>/dev/null) || return 0
  tail -n "$SEEN_KEEP" "$SEEN_FILE" > "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 0; }
  mv -f -- "$tmp" "$SEEN_FILE" 2>/dev/null || rm -f -- "$tmp"
  return 0
}

# --- the three modes --------------------------------------------------------

FINDINGS=
PENDING=
DEFERRED=0

# A candidate report, held with the key that retires it. Nothing is retired here,
# because a line that has to be cut would otherwise retire items it never
# carried, and they would never be reported at all. queue_finding is the only
# way an item reaches a report.
queue_finding() {
  PENDING="$PENDING$1"$'\t'"$2"$'\n'
}

# Build the report from the queue, retiring each item as it is accepted and
# leaving the rest queued for the next poll. The reserve leaves room for the
# trailing budget notes, which are appended after this runs.
REPORT_RESERVE=160

build_report() {
  local limit key text candidate
  limit=$((MAX_LINE - REPORT_RESERVE))
  [ "$limit" -ge 80 ] || limit=80
  while IFS=$(printf '\t') read -r key text; do
    [ -n "$key" ] || continue
    if [ -z "$FINDINGS" ]; then
      candidate=$text
    else
      candidate="$FINDINGS; $text"
    fi
    if [ "${#candidate}" -gt "$limit" ] && [ -n "$FINDINGS" ]; then
      DEFERRED=$((DEFERRED + 1))
      continue
    fi
    FINDINGS=$candidate
    seen_mark "$key"
  done <<< "$PENDING"
}

# One short field, flattened and cut, so the whole report stays one line.
field() {
  local text=$1 width=$2
  text=$(printf '%s' "$text" | tr '\n\r\t' '   ')
  printf '%s' "${text:0:$width}"
}

# Open PRs in one repository, as "<number><TAB><login><TAB><title>". Draft PRs
# are excluded here rather than by every caller, because a draft is by definition
# not asking to be reviewed yet.
pr_list() {
  local repo=$1
  gh_run pr list -R "$FM_PR_WATCH_OWNER/$repo" --state open --limit "$PR_LIMIT" \
    --json number,author,title,isDraft \
    --jq '.[]|select(.isDraft==false)|"\(.number)\t\(.author.login)\t\(.title)"'
}

mode_new() {
  local repo number login title
  for repo in $(repos_for_mode new); do
    if budget_spent; then INCOMPLETE=$repo; return 0; fi
    while IFS=$(printf '\t') read -r number login title; do
      [ -n "$number" ] || continue
      seen_has "$repo/$number" && continue
      if is_bot "$login" || is_ours "$login"; then
        seen_mark "$repo/$number"
        continue
      fi
      queue_finding "$repo/$number" "$repo #$number $login: $(field "$title" 80)"
    done < <(pr_list "$repo")
  done
  return 0
}

mode_ours() {
  local repo number login title
  for repo in $(repos_for_mode ours); do
    if budget_spent; then INCOMPLETE=$repo; return 0; fi
    while IFS=$(printf '\t') read -r number login title; do
      [ -n "$number" ] || continue
      seen_has "$repo/$number" && continue
      if ! is_ours "$login"; then
        seen_mark "$repo/$number"
        continue
      fi
      queue_finding "$repo/$number" "$repo #$number: $(field "$title" 80)"
    done < <(pr_list "$repo")
  done
  return 0
}

# Review comments are read per REPOSITORY, not per PR. The endpoint returns a
# repository's newest review comments across all of its PRs in one call, so a
# sweep costs two calls per repository instead of one per open PR, which is what
# keeps this mode inside the watcher's bound on a home with many open PRs.
mode_comments() {
  local repo ours_prs number id login pr body
  for repo in $(repos_for_mode comments); do
    if budget_spent; then INCOMPLETE=$repo; return 0; fi
    ours_prs=
    while IFS=$(printf '\t') read -r number login _; do
      [ -n "$number" ] || continue
      is_ours "$login" || continue
      ours_prs="$ours_prs $number "
    done < <(pr_list "$repo")
    [ -n "$ours_prs" ] || continue
    if budget_spent; then INCOMPLETE=$repo; return 0; fi
    while IFS=$(printf '\t') read -r id login pr body; do
      [ -n "$id" ] || continue
      case "$ours_prs" in
        *" $pr "*) : ;;
        *) continue ;;
      esac
      seen_has "$repo/$pr/$id" && continue
      if is_bot "$login" || is_ours "$login"; then
        seen_mark "$repo/$pr/$id"
        continue
      fi
      queue_finding "$repo/$pr/$id" "$repo #$pr $login: $(field "$body" 90)"
    done < <(gh_run api \
      "repos/$FM_PR_WATCH_OWNER/$repo/pulls/comments?sort=updated&direction=desc&per_page=$COMMENT_LIMIT" \
      --jq '.[]|"\(.id)\t\(.user.login)\t\(.pull_request_url|split("/")|.[-1])\t\(.body|gsub("[\n\r\t]+";" "))"')
  done
  return 0
}

headline() {
  case "$1" in
    comments) printf '%s\n' 'new review comments on our PRs' ;;
    new) printf '%s\n' 'new PR(s) from others, review needed' ;;
    ours) printf '%s\n' 'OUR new PR(s), review them' ;;
  esac
}

# --- actions ----------------------------------------------------------------

# One line out, and only when it is worth waking firstmate for. A problem is
# always written to stderr as well, so an operator running this by hand sees it
# even on a poll the repeat gate is holding quiet.
emit() {
  local mode=$1 line=$2
  fm_cap_line_var "$line" "$MAX_LINE"
  line=$FM_LINE_CAP_LINE
  if record_should_report "$mode" "$line"; then
    printf '%s\n' "$line"
  fi
  record_write "$mode" "$line"
}

action_check() {
  local mode=$1 line
  mkdir -p "$STATE" 2>/dev/null || true
  if ! config_load; then
    printf 'fm-pr-watch: %s\n' "$CONFIG_PROBLEM" >&2
    emit "$mode" "pr watch ($mode) is not configured: $CONFIG_PROBLEM"
    return 2
  fi
  seen_open "$mode" || return 1
  DEADLINE=$(( $(now_epoch) + BUDGET_SECS ))
  INCOMPLETE=
  "mode_$mode"
  build_report
  seen_trim
  line=
  [ -z "$FINDINGS" ] || line="$(headline "$mode"): $FINDINGS"
  if [ -n "$line" ] && [ "$DEFERRED" -gt 0 ]; then
    line="$line; $DEFERRED more held for the next poll"
  fi
  if [ -n "$INCOMPLETE" ]; then
    if [ -n "$line" ]; then
      line="$line; budget spent, $INCOMPLETE and later not checked"
    else
      line="pr watch ($mode) ran out of budget before $INCOMPLETE"
    fi
  fi
  if [ -n "$BUDGET_CUT_FROM" ] && [ -n "$line" ]; then
    line="$line; sweep budget cut from ${BUDGET_CUT_FROM}s to ${BUDGET_SECS}s by FM_CHECK_TIMEOUT"
  fi
  [ -n "$line" ] || return 0
  emit "$mode" "$line"
  return 0
}

# The home is embedded already resolved, because the watcher runs the shim from
# its own working directory and a relative spelling would send the check to a
# different home, or to none at all.
shim_content() {
  local home=$1 mode=$2
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-pr-watch.sh - PR review trigger poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pr-watch.sh") check $mode"
}

# Written the way this repo writes its other trusted check shims: the guards run
# before anything is written, so a symlink at the shim path is refused instead of
# followed, and the bytes arrive by rename so the watcher never reads a
# half-written shim and rejects it as unauthenticated.
SHIM_WRITE_TMP=

shim_write() {
  local path=$1 want=$2 device tmp
  state_dir_usable || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$path" "$device" || return 1
  if [ -e "$path" ] && [ "$(fm_pr_file_mode "$path")" = 700 ] \
    && [ "$(cat "$path" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-watch-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$path" "$device" \
    || ! mv -f -- "$tmp" "$path"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$path" 700 "$device"
}

# Keep a byte copy of a shim already in place, so a failed arm puts back the shim
# a working home was using rather than an equivalent rewrite.
shim_backup() {
  local path=$1 device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-watch-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$path" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=
ARM_ID=
ARM_PATH=

# An unregistered shim is not inert: the watcher rejects it on every cycle and
# wakes firstmate about unauthenticated state checks. So the rule after a failed
# or interrupted arm is that the home never holds a shim without a matching trust
# binding. The shim a working home had is put back and kept only when it is still
# bound; otherwise the shim goes, so the home is plainly not armed and the
# failure is the only thing the operator has to act on.
arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  [ -n "$ARM_PATH" ] || return 0
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$ARM_PATH" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$ARM_ID"; then
      return 0
    fi
  fi
  rm -f -- "$ARM_PATH"
}

# shellcheck disable=SC2329  # Registered by arm_one's signal trap.
arm_interrupted() {
  arm_rollback
  printf 'fm-pr-watch: arming was interrupted, so state/%s.check.sh is not armed\n' "$ARM_ID" >&2
  exit 1
}

arm_one() {
  local mode=$1 home=$2 id path want
  id=$(check_id_for_mode "$mode") || return 1
  path="$STATE/$id.check.sh"
  ARM_ID=$id
  ARM_PATH=$path
  ARM_BACKUP=
  want=$(shim_content "$home" "$mode")
  if [ -f "$path" ] && [ ! -L "$path" ]; then
    ARM_BACKUP=$(shim_backup "$path") || {
      printf 'fm-pr-watch: could not save the existing %s\n' "$path" >&2
      return 1
    }
  fi
  # The shim exists unbound from the rename until the register returns, so a
  # signal in that window rolls back the same way a failure does.
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$path" "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-pr-watch: could not write %s\n' "$path" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$id" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-pr-watch: could not register %s\n' "$path" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  ARM_PATH=
  printf 'armed: state/%s.check.sh\n' "$id"
  return 0
}

resolve_home() {
  case "$FM_HOME" in
    /*) printf '%s\n' "$FM_HOME" ;;
    *)
      (CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-pr-watch: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
}

action_arm() {
  local home mode rc=0
  # Arming a check that cannot watch anything is the failure this script exists
  # to prevent, so the configuration is proven before a single shim is written.
  if ! config_load; then
    printf 'fm-pr-watch: %s\n' "$CONFIG_PROBLEM" >&2
    return 1
  fi
  home=$(resolve_home) || return 1
  mkdir -p "$STATE" || return 1
  state_dir_usable || return 1
  for mode in "$@"; do
    arm_one "$mode" "$home" || rc=1
  done
  return "$rc"
}

# Removal is the one action that can destroy something outside this home if a
# path is built from an empty value, so nothing is removed until the state
# directory and this mode's own id and paths have each been proven.
action_disarm() {
  local mode id shim trust seen record rc=0
  state_dir_usable || return 1
  for mode in "$@"; do
    if ! id=$(check_id_for_mode "$mode"); then
      rc=1
      continue
    fi
    if ! seen=$(seen_path "$mode") || ! record=$(record_path "$mode"); then
      rc=1
      continue
    fi
    shim="$STATE/$id.check.sh"
    trust="$STATE/$id.check-trust"
    rm -f -- "$shim" "$trust" "$seen" "$record"
    printf 'disarmed: state/%s.check.sh\n' "$id"
  done
  return "$rc"
}

MODE_LIST=

# Resolve the modes an action will act on, refusing the whole invocation on the
# first name this script does not own, so a typo never leaves half the triggers
# armed and the rest refused. Deliberately NOT called through a command
# substitution: die_usage inside a subshell would exit only that subshell and
# leave the caller running with an empty list, which is a silent no-op rather
# than a refusal.
resolve_modes() {
  local m
  if [ "$#" -eq 0 ]; then
    MODE_LIST=$MODES
    return 0
  fi
  MODE_LIST=
  for m in "$@"; do
    mode_valid "$m" || die_usage "unknown mode: $m"
    MODE_LIST="$MODE_LIST $m"
  done
}

ACTION=${1:-}
[ "$#" -eq 0 ] || shift
case "$ACTION" in
  check)
    [ "$#" -eq 1 ] || die_usage "check needs exactly one mode"
    mode_valid "$1" || die_usage "unknown mode: $1"
    action_check "$1"
    ;;
  arm)
    resolve_modes "$@"
    # shellcheck disable=SC2086  # deliberate word split of the validated mode list
    action_arm $MODE_LIST
    ;;
  disarm)
    resolve_modes "$@"
    # shellcheck disable=SC2086  # deliberate word split of the validated mode list
    action_disarm $MODE_LIST
    ;;
  -h|--help) usage ;;
  '') die_usage "no action given" ;;
  *) die_usage "unknown action: $ACTION" ;;
esac
