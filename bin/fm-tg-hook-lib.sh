#!/usr/bin/env bash
# Shared block budget for the two Telegram Stop hooks (bin/fm-tg-guard.sh and
# bin/fm-tg-hook.sh). This file is sourced by hook entrypoints and has no side
# effects on source.
#
# Why it exists: both hooks refuse a turn end with exit 2 until their condition
# clears - a reply has been sent, or nothing is pending. When the condition
# CANNOT clear (Telegram unreachable, a revoked token, no network), the model
# has no way to satisfy either one, so every turn end re-blocked for ever and
# the session was wedged. bin/fm-turnend-guard.sh solved the same problem with
# FM_CLAUDE_TURNEND_BLOCK_BUDGET plus state/.turnend-claude-blocks; this is the
# same bound in the shape these two hooks need.
#
# The budget is keyed on the CONDITION, not on the session, and that is
# load-bearing. A plain "at most N blocks" counter would stop surfacing a
# captain message that is still genuinely unanswered, which is the loss this
# whole feature exists to prevent. Instead, each block records a key
# describing exactly what it is blocking about - which messages are pending,
# or which surfacing is unanswered. Any change to that key is progress and
# resets the count, so a new or newly-answered message always gets a full
# budget. Only the same unchanged condition, blocking over and over, runs out.
#
# An exhausted budget is not permanent silence either: the record is left
# untouched on exhaustion, so FM_TG_TURNEND_BLOCK_TTL (default 3600s) after the
# last block the same condition is allowed to speak up again.
#
# Deliberately NOT a stop_hook_active one-shot allow. bin/fm-tg-hook.sh is
# registered with asyncRewake, and Claude Code marks EVERY stop after ANY
# stop-hook-driven continuation stop_hook_active=true (the 2026-07-21 incident
# recorded in docs/turnend-guard.md), so honouring that field here would
# disable both hooks permanently after their first block instead of bounding
# them.

# shellcheck source=bin/fm-hook-host-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-hook-host-lib.sh"

# fm_tg_budget_ok <record-file> <condition-key>
# Exit 0 when this block is still within budget (and record it), 1 when the
# same unchanged condition has already used the budget up.
fm_tg_budget_ok() {
  local file=$1 key=$2 budget ttl now skey scount sstamp tmp
  budget=${FM_TG_TURNEND_BLOCK_BUDGET:-3}
  case "$budget" in ''|*[!0-9]*|0) budget=3 ;; esac
  ttl=${FM_TG_TURNEND_BLOCK_TTL:-3600}
  case "$ttl" in ''|*[!0-9]*|0) ttl=3600 ;; esac
  now=$(date +%s)

  skey=
  scount=0
  sstamp=0
  if [ -f "$file" ]; then
    skey=$(sed -n '1s/^key=//p' "$file" 2>/dev/null || true)
    scount=$(sed -n '2s/^count=//p' "$file" 2>/dev/null || true)
    sstamp=$(sed -n '3s/^stamp=//p' "$file" 2>/dev/null || true)
  fi
  case "$scount" in ''|*[!0-9]*) scount=0 ;; esac
  case "$sstamp" in ''|*[!0-9]*) sstamp=0 ;; esac

  if [ "$skey" != "$key" ] || [ "$(( now - sstamp ))" -ge "$ttl" ]; then
    scount=0
  fi
  scount=$(( scount + 1 ))
  # Leave the record alone once the budget is gone: the stamp then dates the
  # last real block, which is what the TTL above measures from.
  [ "$scount" -le "$budget" ] || return 1

  tmp="$file.tmp.$$"
  if printf 'key=%s\ncount=%s\nstamp=%s\n' "$key" "$scount" "$now" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  else
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# fm_tg_budget_clear <record-file>
# The condition cleared on its own; forget the block history entirely.
fm_tg_budget_clear() {
  rm -f "$1" 2>/dev/null || true
}

# fm_tg_pending_key <inbox-dir>
# A stable description of exactly which messages are pending right now.
fm_tg_pending_key() {
  local inbox=$1 f names=
  for f in "$inbox"/*.json; do
    [ -e "$f" ] || continue
    names="$names$(basename "$f"),"
  done
  printf 'pending:%s' "$names"
}

# fm_tg_configured
# 0 when this machine has usable Telegram captain-comms configuration. The
# hooks must be completely inert without it (docs/telegram.md), including
# creating no state directories, so this is checked before any mkdir. Sourced
# in a subshell so a hook never leaks TG_TOKEN into its own environment.
fm_tg_configured() {
  local envf
  envf=${FM_TG_ENV_OVERRIDE:-$HOME/.config/fm-telegram.env}
  [ -f "$envf" ] || return 1
  (
    set -a
    # shellcheck source=/dev/null # a resolved runtime path, not a repo file
    . "$envf" || exit 1
    set +a
    [ -n "${TG_TOKEN:-}" ] && [ -n "${TG_CHAT_ID:-}" ]
  ) >/dev/null 2>&1
}

# fm_tg_path_mtime <path>
# Portable mtime in epoch seconds, empty when the path cannot be read. macOS
# stat has no -c, and a bare `stat -c %Y ... || echo 0` made both sides of the
# guard's comparison 0 there, which silently disabled it.
fm_tg_path_mtime() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

# fm_tg_hook_foreign_host
# 0 when this Stop event was delivered by a foreign host whose own tracked
# registration already owns the turn boundary. Cursor loads this repo's
# .claude/settings.json as well as its own hooks, and has no asyncRewake, so an
# unguarded bin/fm-tg-hook.sh would run synchronously inside Cursor's stop step
# and hold that turn for its whole declared timeout (docs/turnend-guard.md
# "Harness integrations"). A terminal stdin is never read: a hook always pipes
# its payload and a hand-run must not block on a read.
fm_tg_hook_foreign_host() {
  local payload=
  [ -t 0 ] || payload=$(cat 2>/dev/null || true)
  [ -n "$payload" ] || return 1
  fm_hook_payload_is_foreign_host "$payload"
}
