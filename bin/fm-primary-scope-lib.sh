#!/usr/bin/env bash
# Shared marker-or-plain-checkout predicate for tracked hooks that must act only
# in a genuine firstmate primary home.
# This file is sourced by hook entrypoints and has no side effects on source.

# Return 0 when $1 carries a genuine secondmate-home marker.
fm_root_is_secondmate_home() {
  local marker="$1/.fm-secondmate-home" id LC_ALL=C
  [ -L "$marker" ] && return 1
  [ -f "$marker" ] || return 1
  IFS= read -r id < "$marker" 2>/dev/null || return 1
  id=${id//[[:space:]]/}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# Canonicalize a path git rev-parse returned for $1 (--git-dir or
# --git-common-dir), which git resolves RELATIVE TO $1, not to the caller's
# cwd. Comparing the two raw strings breaks from a plain checkout's own
# SUBDIRECTORY: --git-dir there is already absolute (/repo/.git) while
# --git-common-dir is relative (../.git), so a raw string compare never
# matches and every such subdirectory misclassifies as a linked worktree.
# Resolves via cd+pwd -P (POSIX, no realpath/readlink -f dependency).
fm__git_dir_abs() {
  local dir=$1 rel=$2 abs
  [ -n "$rel" ] || return 1
  case "$rel" in
    /*) abs=$rel ;;
    *) abs=$(cd "$dir/$rel" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  printf '%s\n' "$abs"
}

# Return 0 when $1 is a genuine primary root whose effective state dir is $2.
# A valid secondmate marker force-includes a linked secondmate home.
# Otherwise only a plain checkout is primary, never a linked task worktree.
fm_primary_scope_matches() {
  local root=$1 state=$2 raw_git_dir raw_common_dir git_dir git_common_dir
  if ! fm_root_is_secondmate_home "$root"; then
    raw_git_dir=$(git -C "$root" rev-parse --git-dir 2>/dev/null) || return 1
    raw_common_dir=$(git -C "$root" rev-parse --git-common-dir 2>/dev/null) || return 1
    git_dir=$(fm__git_dir_abs "$root" "$raw_git_dir") || return 1
    git_common_dir=$(fm__git_dir_abs "$root" "$raw_common_dir") || return 1
    [ "$git_dir" = "$git_common_dir" ] || return 1
  fi
  [ -f "$root/AGENTS.md" ] || return 1
  [ -d "$root/bin" ] || return 1
  [ -d "$state" ] || return 1
}

# Return 0 when $1 sits inside a linked git worktree that carries no valid
# secondmate marker - a crewmate or scout task worktree. Location-independent:
# a task worktree is identified by git's own linked-worktree shape, not by
# living under any particular parent directory.
fm_dir_is_child_worktree() {
  local dir=$1 top raw_git_dir raw_common_dir git_dir git_common_dir
  [ -d "$dir" ] || return 1
  raw_git_dir=$(git -C "$dir" rev-parse --git-dir 2>/dev/null) || return 1
  raw_common_dir=$(git -C "$dir" rev-parse --git-common-dir 2>/dev/null) || return 1
  git_dir=$(fm__git_dir_abs "$dir" "$raw_git_dir") || return 1
  git_common_dir=$(fm__git_dir_abs "$dir" "$raw_common_dir") || return 1
  [ "$git_dir" != "$git_common_dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || return 0
  fm_root_is_secondmate_home "$top" && return 1
  return 0
}
