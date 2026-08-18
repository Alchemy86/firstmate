#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's memory guard.
#
# The guard runs before argument parsing, so most of these tests drive the real
# fm-spawn.sh with no arguments against an isolated firstmate home and read the
# process result. A refusal prints "refusing to spawn:" and exits 1; passing the
# guard falls through to the ordinary "--mode" argument error, so reaching that
# message is the positive signal that the guard allowed the spawn. The cases that
# depend on what the command line asks for - a relaunch, a remote secondmate -
# pass those arguments and read the ordinary handling they fall through to
# instead. No outcome starts a backend, so no endpoint or metadata is ever
# created, and the remote case runs against a stub transport.
#
# FM_SPAWN_NO_GUARD=1 skips the unrelated watcher guard only; the memory guard
# has no such skip and still runs, exactly as it does for each pair of a batch.
#
# The crew-count cases pin FM_MIN_FREE_MB=1 and the memory cases pin a high
# FM_MAX_CREWS so each test exercises one branch and never depends on how much
# memory the host running the suite happens to have free.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The refusal tells operators to export FM_SPAWN_FORCE=1, so a developer running
# this suite may well be carrying that or another tuning knob in their shell.
# Each case supplies its own values as a command prefix, so drop the ambient ones
# rather than letting them decide the result.
unset FM_SPAWN_FORCE FM_MAX_CREWS FM_MIN_FREE_MB FM_STATE_OVERRIDE

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-memory-guard)

REFUSAL='refusing to spawn:'
PASSED_GUARD='ship spawns require --mode'

# make_home <name> <live-crew-count> [secondmate-count]: isolated home with N
# live task metas and, optionally, M persistent secondmate metas.
make_home() {
  local home=$TMP_ROOT/$1 count=$2 secondmates=${3:-0} i
  mkdir -p "$home/state" "$home/data"
  for ((i = 1; i <= count; i++)); do
    : > "$home/state/task$i.meta"
  done
  for ((i = 1; i <= secondmates; i++)); do
    printf 'kind=secondmate\n' > "$home/state/sub$i.meta"
  done
  printf '%s\n' "$home"
}

# run_spawn <home>: run fm-spawn with the guard reachable, echo output, return code.
run_spawn() {
  run_spawn_args "$1"
}

# run_spawn_args <home> [arg...]: the same run with real spawn arguments, for the
# cases whose behaviour depends on what the command line asks for.
run_spawn_args() {
  local home=$1
  shift
  FM_SPAWN_NO_GUARD=1 FM_HOME="$home" bash "$SPAWN" "$@" 2>&1
}

test_cap_refuses_when_live_crews_reach_the_cap() {
  local home out rc
  home=$(make_home cap-at 8)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'cap at limit must refuse'
  assert_contains "$out" "$REFUSAL" 'cap at limit must refuse the spawn'
  assert_contains "$out" '8 crews already live (cap 8)' 'refusal must name the live count and cap'
  pass 'cap refuses when live crews reach the cap'
}

test_cap_refuses_above_the_cap() {
  local home out rc
  home=$(make_home cap-above 9)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'cap above limit must refuse'
  assert_contains "$out" '9 crews already live (cap 8)' 'refusal must count every live crew'
  pass 'cap refuses above the cap'
}

test_cap_allows_below_the_cap() {
  local home out
  home=$(make_home cap-below 7)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'a normal spawn below the cap must not be refused'
  assert_contains "$out" "$PASSED_GUARD" 'a normal spawn must reach ordinary argument handling'
  pass 'cap allows below the cap'
}

test_empty_home_is_unaffected() {
  local home out
  home=$(make_home cap-empty 0)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'a home with no live crews must not be refused'
  assert_contains "$out" "$PASSED_GUARD" 'a home with no live crews must reach ordinary argument handling'
  pass 'empty home is unaffected'
}

test_explicit_cap_is_honoured() {
  local home out rc
  home=$(make_home cap-explicit 2)
  out=$(FM_MIN_FREE_MB=1 FM_MAX_CREWS=1 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'explicit FM_MAX_CREWS must refuse'
  assert_contains "$out" '2 crews already live (cap 1)' 'refusal must report the explicit cap'
  pass 'explicit FM_MAX_CREWS is honoured'
}

test_raised_cap_allows_the_spawn() {
  local home out
  home=$(make_home cap-raised 9)
  out=$(FM_MIN_FREE_MB=1 FM_MAX_CREWS=50 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'a deliberately raised cap must allow the spawn'
  assert_contains "$out" "$PASSED_GUARD" 'a raised cap must reach ordinary argument handling'
  pass 'a raised cap allows the spawn'
}

test_memory_refusal_fires_below_the_threshold() {
  local home out rc
  home=$(make_home mem-low 0)
  out=$(FM_MAX_CREWS=99 FM_MIN_FREE_MB=99999999 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'memory below threshold must refuse'
  assert_contains "$out" "$REFUSAL" 'memory below threshold must refuse the spawn'
  assert_contains "$out" 'need 99999999' 'refusal must name the required free memory'
  pass 'memory refusal fires below the threshold'
}

test_memory_refusal_allows_above_the_threshold() {
  local home out
  home=$(make_home mem-ok 0)
  out=$(FM_MAX_CREWS=99 FM_MIN_FREE_MB=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'ample free memory must not be refused'
  assert_contains "$out" "$PASSED_GUARD" 'ample free memory must reach ordinary argument handling'
  pass 'memory refusal allows above the threshold'
}

test_force_overrides_the_cap() {
  local home out
  home=$(make_home force-cap 9)
  out=$(FM_MIN_FREE_MB=1 FM_SPAWN_FORCE=1 FM_MAX_CREWS=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'FM_SPAWN_FORCE must override the cap'
  assert_contains "$out" "$PASSED_GUARD" 'a forced spawn must reach ordinary argument handling'
  pass 'FM_SPAWN_FORCE overrides the cap'
}

test_force_overrides_the_memory_refusal() {
  local home out
  home=$(make_home force-mem 0)
  out=$(FM_SPAWN_FORCE=1 FM_MIN_FREE_MB=99999999 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'FM_SPAWN_FORCE must override the memory refusal'
  assert_contains "$out" "$PASSED_GUARD" 'a forced spawn must reach ordinary argument handling'
  pass 'FM_SPAWN_FORCE overrides the memory refusal'
}

# Regression for the typo that read an undefined variable instead of the resolved
# state directory. Under `set -u` that killed only the counting subshell, leaving
# the count empty so the cap silently never fired while the spawn continued.
test_crew_count_reads_the_resolved_state_directory() {
  local home out rc
  home=$(make_home regression 9)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home"); rc=$?
  assert_not_contains "$out" 'unbound variable' 'the crew count must not read an undefined variable'
  expect_code 1 "$rc" 'the cap must fire rather than being skipped by a failed count'
  pass 'crew count reads the resolved state directory'
}

# The state directory is overridable, so the count must follow the override
# rather than any other location.
test_crew_count_follows_the_state_override() {
  local home elsewhere out rc
  home=$(make_home override-home 0)
  elsewhere=$(make_home override-state 9)
  out=$(FM_MIN_FREE_MB=1 FM_STATE_OVERRIDE="$elsewhere/state" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$home" bash "$SPAWN" 2>&1); rc=$?
  expect_code 1 "$rc" 'the override state directory must be counted'
  assert_contains "$out" '9 crews already live (cap 8)' 'the count must follow FM_STATE_OVERRIDE'
  pass 'crew count follows the state override'
}

# A persistent secondmate holds a meta from provisioning until retirement, so
# counting them would refuse a spawn in a home with no live crews at all.
test_secondmate_metas_are_not_counted_as_live_crews() {
  local home out
  home=$(make_home cap-secondmates 2 8)
  out=$(FM_MIN_FREE_MB=1 run_spawn "$home")
  assert_not_contains "$out" "$REFUSAL" 'secondmate records must not be counted as live crews'
  assert_contains "$out" "$PASSED_GUARD" 'a home with two crews must reach ordinary argument handling'
  pass 'secondmate metas are not counted as live crews'
}

# A relaunch replaces a crew rather than adding one, and the control plane has
# already stopped the previous agent by the time this runs, so refusing here
# would leave the task with a recorded endpoint and no agent.
test_relaunch_is_not_refused_by_the_cap() {
  local home out
  home=$(make_home relaunch-cap 9)
  out=$(FM_MIN_FREE_MB=1 run_spawn_args "$home" nosuchtask --relaunch)
  assert_not_contains "$out" "$REFUSAL" 'the cap must not refuse a relaunch'
  assert_contains "$out" 'needs an existing task record' 'a relaunch must reach ordinary relaunch handling'
  pass 'a relaunch is not refused by the cap'
}

test_relaunch_still_honours_the_memory_refusal() {
  local home out rc
  home=$(make_home relaunch-mem 0)
  out=$(FM_MAX_CREWS=99 FM_MIN_FREE_MB=99999999 run_spawn_args "$home" nosuchtask --relaunch); rc=$?
  expect_code 1 "$rc" 'a relaunch below the memory threshold must refuse'
  assert_contains "$out" "$REFUSAL" 'a relaunch must still be refused when memory is short'
  pass 'a relaunch still honours the memory refusal'
}

# A remote secondmate's agent runs on its own host, so neither this machine's
# crew count nor its free memory describes what that spawn costs.
test_remote_secondmate_skips_the_guard() {
  local home out
  home=$(make_home remote-secondmate 9)
  printf -- '- rsm - remote helper (host: fixture.invalid; root: /srv/fm; home: /srv/fm/home; scope: things; projects: ; added 2026-08-18)\n' \
    > "$home/data/secondmates.md"
  out=$(FM_MIN_FREE_MB=99999999 FM_SSH_BIN=/bin/false run_spawn_args "$home" rsm --secondmate)
  assert_not_contains "$out" "$REFUSAL" 'a remote secondmate must not be refused by local resources'
  assert_contains "$out" 'is not ready for a remote second mate' \
    'a remote secondmate spawn must reach its own remote route handling'
  pass 'a remote secondmate skips the guard'
}

# The liveness sweep respawns a dead LOCAL secondmate with --secondmate, not
# --relaunch. Its record already exists, so the spawn replaces an agent that is
# already gone rather than adding one, and refusing it at cap would leave the
# secondmate down until an operator intervened.
test_local_secondmate_respawn_is_not_refused_by_the_cap() {
  local home out
  home=$(make_home secondmate-respawn 8)
  printf 'kind=secondmate\n' > "$home/state/sm.meta"
  out=$(FM_MIN_FREE_MB=1 run_spawn_args "$home" sm --secondmate)
  assert_not_contains "$out" "$REFUSAL" 'the cap must not refuse a respawn of a registered secondmate'
  assert_contains "$out" 'no firstmate home supplied or registered for sm' \
    'a secondmate respawn must reach ordinary secondmate handling'
  pass 'a local secondmate respawn is not refused by the cap'
}

# Provisioning a NEW secondmate has no record yet, so it adds a crew and stays
# capped like any other new work.
test_new_secondmate_provisioning_is_still_capped() {
  local home out rc
  home=$(make_home secondmate-new 8)
  out=$(FM_MIN_FREE_MB=1 run_spawn_args "$home" sm --secondmate); rc=$?
  expect_code 1 "$rc" 'new secondmate provisioning must be refused at cap'
  assert_contains "$out" '8 crews already live (cap 8)' 'the cap must still apply to new provisioning'
  pass 'new secondmate provisioning is still capped'
}

test_local_secondmate_respawn_still_honours_the_memory_refusal() {
  local home out rc
  home=$(make_home secondmate-respawn-mem 0)
  printf 'kind=secondmate\n' > "$home/state/sm.meta"
  out=$(FM_MAX_CREWS=99 FM_MIN_FREE_MB=99999999 run_spawn_args "$home" sm --secondmate); rc=$?
  expect_code 1 "$rc" 'a secondmate respawn below the memory threshold must refuse'
  assert_contains "$out" "$REFUSAL" 'a secondmate respawn must still be refused when memory is short'
  pass 'a local secondmate respawn still honours the memory refusal'
}

# A non-numeric knob used to make the comparison exit 2, which inside an `if` is
# merely false, silently disabling the branch the operator was widening.
test_non_numeric_cap_is_refused_by_name() {
  local home out rc
  home=$(make_home bad-cap 0)
  out=$(FM_MIN_FREE_MB=1 FM_MAX_CREWS=none run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'a non-numeric FM_MAX_CREWS must refuse'
  assert_contains "$out" 'FM_MAX_CREWS must be a whole number' 'the refusal must name the bad knob'
  pass 'a non-numeric cap is refused by name'
}

test_non_numeric_min_free_is_refused_by_name() {
  local home out rc
  home=$(make_home bad-minfree 0)
  out=$(FM_MIN_FREE_MB=8000MB run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'a non-numeric FM_MIN_FREE_MB must refuse'
  assert_contains "$out" 'FM_MIN_FREE_MB must be a whole number' 'the refusal must name the bad knob'
  pass 'a non-numeric memory floor is refused by name'
}

test_force_off_does_not_override_the_guard() {
  local home out rc
  home=$(make_home force-off 9)
  out=$(FM_MIN_FREE_MB=1 FM_SPAWN_FORCE=0 run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'FM_SPAWN_FORCE=0 must leave the guard on'
  assert_contains "$out" "$REFUSAL" 'FM_SPAWN_FORCE=0 must not override the cap'
  pass 'FM_SPAWN_FORCE=0 does not override the guard'
}

test_unrecognised_force_value_is_refused() {
  local home out rc
  home=$(make_home force-bogus 0)
  out=$(FM_MIN_FREE_MB=1 FM_SPAWN_FORCE=maybe run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'an unrecognised FM_SPAWN_FORCE must refuse'
  assert_contains "$out" 'FM_SPAWN_FORCE must be 1' 'the refusal must name the documented value'
  pass 'an unrecognised FM_SPAWN_FORCE value is refused'
}

# Only the documented value overrides. A spelling the header and the refusal
# both call invalid must not silently bypass the whole guard.
test_undocumented_force_spelling_is_refused() {
  local home out rc
  home=$(make_home force-true 9)
  out=$(FM_MIN_FREE_MB=1 FM_SPAWN_FORCE=true run_spawn "$home"); rc=$?
  expect_code 1 "$rc" 'an undocumented FM_SPAWN_FORCE spelling must refuse'
  assert_contains "$out" 'FM_SPAWN_FORCE must be 1' 'the refusal must name the documented value'
  assert_not_contains "$out" "$PASSED_GUARD" 'an undocumented spelling must not bypass the guard'
  pass 'an undocumented FM_SPAWN_FORCE spelling is refused'
}

test_cap_refuses_when_live_crews_reach_the_cap
test_cap_refuses_above_the_cap
test_cap_allows_below_the_cap
test_empty_home_is_unaffected
test_explicit_cap_is_honoured
test_raised_cap_allows_the_spawn
test_memory_refusal_fires_below_the_threshold
test_memory_refusal_allows_above_the_threshold
test_force_overrides_the_cap
test_force_overrides_the_memory_refusal
test_crew_count_reads_the_resolved_state_directory
test_crew_count_follows_the_state_override
test_secondmate_metas_are_not_counted_as_live_crews
test_relaunch_is_not_refused_by_the_cap
test_relaunch_still_honours_the_memory_refusal
test_remote_secondmate_skips_the_guard
test_local_secondmate_respawn_is_not_refused_by_the_cap
test_new_secondmate_provisioning_is_still_capped
test_local_secondmate_respawn_still_honours_the_memory_refusal
test_non_numeric_cap_is_refused_by_name
test_non_numeric_min_free_is_refused_by_name
test_force_off_does_not_override_the_guard
test_unrecognised_force_value_is_refused
test_undocumented_force_spelling_is_refused

echo "# all fm-spawn-memory-guard tests passed"
