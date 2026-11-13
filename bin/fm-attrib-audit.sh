#!/usr/bin/env bash
# Audit every registered project for AI attribution, LOCAL and PUBLISHED.
#
# Checking local history alone is the hole that let attributed commits reach two
# published repos on 2026-08-15: the strip was done and never pushed. This checks
# origin, because "landed" means landed where the captain can see it.
set -uo pipefail
FM_ROOT=${FM_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
PAT='co-authored-by:.*(claude|anthropic)|noreply@anthropic\.com|generated with \[?claude'
rc=0
for d in "$FM_ROOT"/projects/*/; do
  [ -d "$d/.git" ] || continue
  name=$(basename "$d")
  git -C "$d" remote get-url origin >/dev/null 2>&1 || continue
  git -C "$d" fetch -q origin 2>/dev/null
  br=$(git -C "$d" symbolic-ref -q --short HEAD 2>/dev/null || echo main)
  loc=$(git -C "$d" log "$br" --format='%B' 2>/dev/null | grep -ciE "$PAT")
  pub=$(git -C "$d" log "origin/$br" --format='%B' 2>/dev/null | grep -ciE "$PAT")
  if [ "${loc:-0}" -gt 0 ] || [ "${pub:-0}" -gt 0 ]; then
    printf 'ATTRIBUTION %-14s local=%s published=%s\n' "$name" "$loc" "$pub"
    rc=1
  fi
done
[ $rc -eq 0 ] && echo "clean: no AI attribution in any project, local or published"
exit $rc
