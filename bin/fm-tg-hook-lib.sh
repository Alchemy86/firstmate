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
