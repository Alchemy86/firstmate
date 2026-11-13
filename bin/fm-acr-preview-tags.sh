#!/usr/bin/env bash
# Report which container images a preview-tag purge WOULD act on, and prove it
# matches nothing else. Read-only: it lists and it counts, it never deletes.
#
# The captain's rule for this: before a purge is allowed to delete anything, a
# script must find the same images and do something harmless instead, so the
# match set is proven rather than trusted.
#
#   fm-acr-preview-tags.sh                 report preview tags, and what a purge would spare
#   fm-acr-preview-tags.sh --older-than 48 only those older than N hours (default 48)
#   fm-acr-preview-tags.sh --pattern 'pr-' the tag prefix that marks a preview (default pr-)
set -uo pipefail
REG=${FM_ACR:-bluemountain}
HOURS=48
PAT='pr-'
while [ $# -gt 0 ]; do
  case $1 in
    --older-than) HOURS=${2:?}; shift 2 ;;
    --pattern) PAT=${2:?}; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "error: unrecognised argument: $1" >&2; exit 2 ;;
  esac
done
case "$PAT" in ''|'*'|'.'|'-') echo "error: refusing an unsafe pattern: '$PAT'" >&2; exit 2 ;; esac

command -v az >/dev/null || { echo "error: az is not installed" >&2; exit 2; }
az acr repository list -n "$REG" -o tsv >/dev/null 2>&1 || {
  echo "error: cannot read registry '$REG' - check az login" >&2; exit 2; }

printf 'registry %s   preview tag prefix %q   age threshold %sh\n\n' "$REG" "$PAT" "$HOURS"
cut=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.UTC)-datetime.timedelta(hours=int(sys.argv[1]))).isoformat())" "$HOURS")

TAGFILE=$(mktemp)
trap 'rm -f "$TAGFILE"' EXIT
while read -r repo; do
  [ -n "$repo" ] || continue
  # -o json, not tsv: an ACR manifest's "tags" field is an ARRAY, and Azure
  # CLI's tsv formatter renders an array field as its ELEMENT COUNT, not its
  # contents - "3" instead of the three tag strings. That silently broke every
  # earlier run of this script into reporting 0 matches regardless of what was
  # actually in the registry. json + python is what lets us see one row per
  # actual tag string, which is the only thing --pattern can honestly match.
  az acr manifest list-metadata -r "$REG" -n "$repo" -o json 2>/dev/null \
  | python3 -c "
import json, sys
repo = sys.argv[1]
for m in json.load(sys.stdin):
    created = m.get('createdTime', '')
    for tag in (m.get('tags') or []):
        print(f'{repo}\t{tag}\t{created}')
" "$repo"
done < <(az acr repository list -n "$REG" -o tsv 2>/dev/null) > "$TAGFILE"

match=0; spare=0; old=0
while IFS=$'\t' read -r repo tag created; do
  case "$tag" in
    # The prefix alone is not enough: "prod" starts with "pr" too, and this
    # registry has a real canvas-lms:prod tag that a bare prefix match would
    # have marked for deletion. The real convention (measured today) is
    # pr<number>-<buildnumber>, so a digit must follow the prefix immediately.
    "$PAT"[0-9]*)
      match=$((match+1))
      if [ "$created" \< "$cut" ]; then old=$((old+1)); printf '  WOULD PURGE  %-34s %-28s %s\n' "$repo" "$tag" "${created:0:16}"
      else printf '  too new      %-34s %-28s %s\n' "$repo" "$tag" "${created:0:16}"; fi ;;
    *) spare=$((spare+1)) ;;
  esac
done < "$TAGFILE"

printf '\n%s tag(s) match the preview prefix, %s of them older than %sh.\n' "$match" "$old" "$HOURS"
printf '%s tag(s) do NOT match and would be left alone.\n' "$spare"
[ "$match" = 0 ] && printf '\nNothing matches yet - expected until the PR build starts pushing preview tags.\n'
exit 0
