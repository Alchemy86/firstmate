#!/usr/bin/env bash
# fm-situationroom-publish.sh - publish fleet state to the shared Claude Work board.
#
# Reads the structured fleet contract (fm-fleet-snapshot.sh --json, the
# backlog.records array) and upserts every live work item into the
# situation-room-claude-work index, one document per task id.
#
# Idempotent: documents are upserted by task id, never appended, so re-running
# converges rather than duplicating.
#
# Stale clearing: a task that disappears from the backlog (torn down, removed)
# is swept to state "done" rather than deleted, so the board keeps its history
# and the UI filters it with the same state predicate it already applies to
# finished work. Nothing is ever destructively removed from a shared index.
#
# usage: fm-situationroom-publish.sh [--dry-run]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-situationroom-lib.sh
. "$SCRIPT_DIR/fm-situationroom-lib.sh"

DRY=0
case "${1:-}" in
  -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: fm-situationroom-publish.sh [--dry-run]" >&2; exit 2 ;;
esac

sr_load_env

# One home owns the board. Secondmate homes share $HOME, so they would
# otherwise each publish their own backlog and sweep the other homes' tasks to
# "done". SR_PUBLISH_HOME names the publishing home; an unset value suits a
# single-home install.
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
THIS_HOME="${FM_HOME:-$FM_ROOT}"
if [ -n "${SR_PUBLISH_HOME:-}" ] && [ "$SR_PUBLISH_HOME" != "$THIS_HOME" ]; then
  echo "not the publishing home ($THIS_HOME); nothing to do"
  exit 0
fi

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TMP="$(mktemp -d)" || sr_die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

"$SCRIPT_DIR/fm-fleet-snapshot.sh" --json > "$TMP/snap.json" \
  || sr_die "fleet snapshot failed"

# Only structured backlog rows are tasks: unstructured continuation lines carry
# no id and would otherwise be indexed under a fresh auto-id on every run.
# Map the backlog contract onto the board contract. Kinds outside the board's
# four-value vocabulary (docs, review, other) collapse to "task".
jq -r --arg now "$NOW" --arg idx "$SR_WORK_INDEX" '
  .backlog.records[]
  | select(.state != "done")
  | select(.structured == true and .id != null and .id != "")
  | . as $r
  | (if ($r.kind // "task") | IN("ship","scout","task","captain")
     then $r.kind else "task" end) as $kind
  | (($r.unresolved_blocker_ids // []) | length > 0) as $isblocked
  | ($r.hold_reason != null) as $held
  | (if $held then "held" elif $isblocked then "blocked" else $r.state end) as $state
  | ({index:{_index:$idx,_id:$r.id}} | tostring),
    ({ id: $r.id, title: ($r.title // $r.id), kind: $kind, state: $state,
       repo: $r.repo, blockedBy: ($r.blocked_by_ids // []), held: $held,
       holdReason: $r.hold_reason, holdKind: $r.hold_kind, pr: $r.pr_url,
       priority: $r.priority, notes: ($r.body_excerpt // $r.local_note),
       updatedAt: $now } | tostring)
' "$TMP/snap.json" > "$TMP/bulk.ndjson" || sr_die "mapping failed"

jq -r '.backlog.records[]
  | select(.state != "done")
  | select(.structured == true and .id != null and .id != "")
  | .id' "$TMP/snap.json" | LC_ALL=C sort -u > "$TMP/live.ids"
LIVE=$(wc -l < "$TMP/live.ids")
[ "$LIVE" -gt 0 ] || sr_die "no live tasks in snapshot - refusing to publish an empty board"

if [ "$DRY" = 1 ]; then
  echo "would publish $LIVE tasks to $SR_WORK_INDEX"
  cat "$TMP/bulk.ndjson"
  exit 0
fi

printf '\n' >> "$TMP/bulk.ndjson"
sr_request POST "/_bulk" "$TMP/bulk.ndjson" > "$TMP/bulk.out"
jq -e '.errors == false' "$TMP/bulk.out" >/dev/null \
  || { echo "fm-situationroom: bulk upsert reported item errors" >&2
       jq -r '[.items[]|.index|select(.error)|"\(._id): \(.error.reason)"][:5][]' "$TMP/bulk.out" >&2
       exit 1; }

# Sweep: anything still live on the board but gone from the backlog -> done.
sr_request GET "/$SR_WORK_INDEX/_search?size=10000&_source=false&q=NOT%20state:done" \
  > "$TMP/onboard.json"
jq -r '.hits.hits[]._id' "$TMP/onboard.json" | LC_ALL=C sort -u > "$TMP/board.ids"
LC_ALL=C comm -13 "$TMP/live.ids" "$TMP/board.ids" > "$TMP/stale.ids"
STALE=$(wc -l < "$TMP/stale.ids")
if [ "$STALE" -gt 0 ]; then
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    jq -cn --arg idx "$SR_WORK_INDEX" --arg id "$id" '{update:{_index:$idx,_id:$id}}'
    jq -cn --arg now "$NOW" '{doc:{state:"done",updatedAt:$now}}'
  done < "$TMP/stale.ids" > "$TMP/sweep.ndjson"
  printf '\n' >> "$TMP/sweep.ndjson"
  sr_request POST "/_bulk" "$TMP/sweep.ndjson" > "$TMP/sweep.out"
  jq -e '.errors == false' "$TMP/sweep.out" >/dev/null \
    || sr_die "stale sweep reported item errors"
fi

echo "published $LIVE tasks, swept $STALE stale to done ($SR_WORK_INDEX)"
