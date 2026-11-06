#!/usr/bin/env bash
# Delete container images a preview raised and abandoned, and nothing else.
#
# This is the destructive twin of bin/fm-acr-preview-tags.sh, and it reuses
# that script's exact matching rule rather than restating it: a tag must
# start with the pattern immediately followed by a digit (the real observed
# convention is pr<number>-<buildnumber>), and it must be older than the
# age threshold. A bare prefix match is not enough - this registry has a
# real canvas-lms:prod tag that a bare "pr" prefix would have caught.
#
# SKIPS any tag a live agentic-preview references, read from the previews
# API, so a preview that has outlived the age threshold is never deleted
# out from under it - previews do not expire on this deployment, and
# deleting an image a live preview runs would leave it unable to restart.
#
#   fm-acr-preview-purge.sh                dry run: print what would be deleted, delete nothing
#   fm-acr-preview-purge.sh --commit       actually delete
#   fm-acr-preview-purge.sh --older-than 48 --pattern 'pr'   same knobs as the report script
set -uo pipefail
REG=${FM_ACR:-bluemountain}
HOURS=48
PAT='pr'
COMMIT=0
PREVIEW_URL=${FM_AGENTIC_PREVIEW_URL:-http://agentic-preview.ambassador.svc.cluster.local}
while [ $# -gt 0 ]; do
  case $1 in
    --older-than) HOURS=${2:?}; shift 2 ;;
    --pattern) PAT=${2:?}; shift 2 ;;
    --commit) COMMIT=1; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "error: unrecognised argument: $1" >&2; exit 2 ;;
  esac
done
case "$PAT" in ''|'*'|'.'|'-') echo "error: refusing an unsafe pattern: '$PAT'" >&2; exit 2 ;; esac

command -v az >/dev/null || { echo "error: az is not installed" >&2; exit 2; }
az acr repository list -n "$REG" -o tsv >/dev/null 2>&1 || {
  echo "error: cannot read registry '$REG' - check az login" >&2; exit 2; }

printf 'registry %s   preview tag prefix %q   age threshold %sh   mode %s\n\n' \
  "$REG" "$PAT" "$HOURS" "$([ "$COMMIT" = 1 ] && echo COMMIT || echo 'dry-run (pass --commit to delete)')"

cut=$(python3 -c "import datetime,sys; print((datetime.datetime.now(datetime.UTC)-datetime.timedelta(hours=int(sys.argv[1]))).isoformat())" "$HOURS")

# Live preview images, so a purge never touches one an agentic-preview still
# references regardless of age - read-only GET, same endpoint the worked
# example documents. A failed read refuses the whole run rather than risking
# a purge with no live-preview exclusion list.
SPARED=$(curl -sf "$PREVIEW_URL/previews" 2>/dev/null \
  | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
images = set()
for w in d.get('work', {}).values() if isinstance(d.get('work'), dict) else []:
    pass
def walk(o):
    if isinstance(o, dict):
        if 'image' in o and isinstance(o['image'], str):
            images.add(o['image'])
        for v in o.values():
            walk(v)
    elif isinstance(o, list):
        for v in o:
            walk(v)
walk(d)
for i in sorted(images):
    print(i)
") || { echo "error: could not read live previews from $PREVIEW_URL - refusing to purge without proof of what is live" >&2; exit 2; }

if [ -n "$SPARED" ]; then
  printf 'sparing %s live-preview image(s):\n' "$(printf '%s\n' "$SPARED" | grep -c .)"
  printf '%s\n' "$SPARED" | sed 's/^/  live: /'
  printf '\n'
fi

TAGFILE=$(mktemp)
trap 'rm -f "$TAGFILE"' EXIT
while read -r repo; do
  [ -n "$repo" ] || continue
  az acr manifest list-metadata -r "$REG" -n "$repo" -o json 2>/dev/null \
  | python3 -c "
import json, sys
repo = sys.argv[1]
for m in json.load(sys.stdin):
    created = m.get('createdTime', '')
    digest = m.get('digest', '')
    for tag in (m.get('tags') or []):
        print(f'{repo}\t{tag}\t{created}\t{digest}')
" "$repo"
done < <(az acr repository list -n "$REG" -o tsv 2>/dev/null) > "$TAGFILE"

deleted=0; skipped_live=0; too_new=0
while IFS=$'\t' read -r repo tag created digest; do
  case "$tag" in
    "$PAT"[0-9]*)
      [ "$created" \< "$cut" ] || { too_new=$((too_new+1)); continue; }
      image="$REG.azurecr.io/$repo:$tag"
      if printf '%s\n' "$SPARED" | grep -qxF "$image"; then
        skipped_live=$((skipped_live+1))
        printf '  SKIP (live)  %-34s %-28s %s\n' "$repo" "$tag" "${created:0:16}"
        continue
      fi
      deleted=$((deleted+1))
      if [ "$COMMIT" = 1 ]; then
        printf '  DELETING     %-34s %-28s %s\n' "$repo" "$tag" "${created:0:16}"
        az acr repository delete -n "$REG" --image "$repo@$digest" --yes >/dev/null 2>&1 \
          || echo "  error: delete failed for $repo@$digest" >&2
      else
        printf '  WOULD DELETE %-34s %-28s %s\n' "$repo" "$tag" "${created:0:16}"
      fi
      ;;
  esac
done < "$TAGFILE"

printf '\n%s image(s) %s, %s spared because a live preview references them, %s too new to qualify.\n' \
  "$deleted" "$([ "$COMMIT" = 1 ] && echo deleted || echo 'would be deleted')" "$skipped_live" "$too_new"
exit 0
