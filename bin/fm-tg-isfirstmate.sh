#!/usr/bin/env bash
# Exit 0 if this session is the firstmate PRIMARY that owns the captain
# channel; non-zero for a crewmate, a scout, or a secondmate home.
#
# Why this exists (2026-08-22): the Telegram Stop hooks were originally
# registered in ~/.claude/settings.json, which is GLOBAL - so every Claude
# session on this machine ran them, crewmates included. A crew ending a turn
# would drain the captain's inbox into its OWN session, answer him directly,
# and race other sessions for the same message. That is the cause of the
# captain receiving replies from crewmates, of duplicate answers, and of
# messages vanishing before firstmate ever saw them.
#
# The hooks are now registered project-scoped in this repo's own tracked
# .claude/settings.json (docs/telegram.md), which fixes the fan-out by
# construction. This guard stays as defense in depth: firstmate is its own
# repo, so a crewmate sent to work on firstmate itself checks out this same
# tracked settings file inside its own worktree and would otherwise inherit
# these hooks too.
#
# The predicate is the repo's own shared one, fm_primary_scope_matches
# (bin/fm-primary-scope-lib.sh), the same test bin/fm-turnend-guard.sh and
# bin/fm-claude-stop-autoarm.sh scope themselves with. An earlier version
# hand-rolled its own process-ancestry grep plus a hardcoded ~/.treehouse cwd
# test, which missed every task worktree living anywhere else - including this
# repo's own validation worktrees, which it declared to be firstmate.
#
# One extra condition on top of the shared predicate: a secondmate home is a
# genuine firstmate primary for supervision purposes, but it is NOT the home
# that talks to the captain. There is one captain and one bot per machine
# (docs/telegram.md), and a secondmate reports through the main firstmate, so
# it is condemned here too.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"

fm_root_is_secondmate_home "$FM_ROOT" && exit 1
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 1

# The scope test above reads the checkout this script was invoked from. A
# crewmate can still be pointed at the primary's own copy while working from
# its own task worktree, so the working directory is condemned independently.
cwd=$(pwd -P 2>/dev/null || echo "")
[ -n "$cwd" ] && fm_dir_is_child_worktree "$cwd" && exit 1

exit 0
