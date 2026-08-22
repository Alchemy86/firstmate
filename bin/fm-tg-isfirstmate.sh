#!/usr/bin/env bash
# Exit 0 if this session is the firstmate PRIMARY; non-zero for a crewmate.
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
# Two independent tests, either of which condemns a session as crew. Defaults
# to ALLOW when neither matches, because a false "not firstmate" would lose the
# captain's messages, which is the worse failure.
set -u

# 1. Crew agents are launched with their brief as a positional argument, which
#    always begins "You are a crewmate". Walk our ancestry looking for it, but
#    ONLY on processes that are actually the agent binary - an intermediate
#    shell's argv can contain that phrase merely by quoting it (this script's
#    own creation tripped exactly that), which would falsely condemn firstmate.
pid=$$
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$pid" = "1" ] && break
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
  case "$comm" in
    claude|node|*claude*)
      args=$(ps -o args= -p "$pid" 2>/dev/null)
      case "$args" in
        claude*"You are a crewmate"*|*/claude*"You are a crewmate"*) exit 1 ;;
      esac
      ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
  [ -z "$pid" ] && break
done

# 2. Crew sessions run inside a treehouse worktree; firstmate never does.
cwd=$(pwd -P 2>/dev/null || echo "")
case "$cwd" in
  "$HOME"/.treehouse/*) exit 1 ;;
esac

exit 0
