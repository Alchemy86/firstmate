#!/usr/bin/env bash
# fm-situationroom-drain.sh - drain team responses from the Claude Work board.
#
# Reads undrained (consumed:false) documents from situation-room-claude-answers
# and routes each one, then marks it consumed. Nothing is ever dropped: an
# answer either resolves a captain call or becomes a durable backlog item.
#
# Routing, in order:
#   taskId names a task that is still an open captain call  -> the one keyed
#     answer intake, bin/fm-captain-hold.sh answers --source situationroom.
#     Close mode is "done" for a captain-kind question task and "release" for
#     a held work item, so answering resumes work instead of closing it.
#   anything else (null taskId, unknown task, call already closed) -> a new
#     task held for the captain, created through the same fm-captain-hold.sh
#     entry point, so a general note still reaches the captain rather than
#     being dropped. Its id is minted from the document id, so a replayed
#     delivery re-holds the same row instead of creating a second one.
#
# A document is marked consumed only after its routing succeeded.
#
# usage: fm-situationroom-drain.sh [--dry-run]
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-situationroom-lib.sh
. "$SCRIPT_DIR/fm-situationroom-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

DRY=0
case "${1:-}" in
  -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
  --dry-run) DRY=1 ;;
  "") ;;
  *) echo "usage: fm-situationroom-drain.sh [--dry-run]" >&2; exit 2 ;;
esac

sr_load_env

# The board belongs to one home; see fm-situationroom-publish.sh. A sibling
# home sharing this $HOME must not route the board's answers into its backlog.
if [ -n "${SR_PUBLISH_HOME:-}" ] && [ "$SR_PUBLISH_HOME" != "$FM_HOME" ]; then
  echo "not the publishing home ($FM_HOME); nothing to do"
  exit 0
fi

TMP="$(mktemp -d)" || sr_die "mktemp failed"
trap 'rm -rf "$TMP"' EXIT

sr_request GET "/$SR_ANSWERS_INDEX/_search?size=500&q=consumed:false" > "$TMP/ans.json"
# taskId is emitted as "-" when null: a tab-delimited empty field would be
# collapsed by read's IFS handling and silently shift every later field.
jq -r '.hits.hits[] | [._id, (._source.taskId // "-"), (._source.author // "unknown"),
       ((._source.text // "") | gsub("[\t\n\r]+"; " "))] | @tsv' \
  "$TMP/ans.json" > "$TMP/ans.tsv"

COUNT=$(wc -l < "$TMP/ans.tsv")
if [ "$COUNT" -eq 0 ]; then echo "no undrained answers"; exit 0; fi
if [ "$DRY" = 1 ]; then echo "would drain $COUNT answers"; cat "$TMP/ans.tsv"; exit 0; fi

# tasks-axi resolves its backlog from the working directory, never from
# FM_HOME, so every read goes through the same resolution the rest of the
# repo uses rather than inheriting whatever directory the drain was run in.
tasks_axi() {
  local data root backend file
  data=$(fm_backlog_data_absolute "$DATA") || sr_die "data directory cannot be resolved: $DATA"
  root=$(fm_backlog_root "$data") || sr_die "$FM_BACKLOG_TRANSITION_ERROR"
  backend=$(fm_tasks_axi_backend "$root") || return 2
  if [ "$backend" = markdown ]; then
    file=$(fm_backlog_file "$data") || sr_die "$FM_BACKLOG_TRANSITION_ERROR"
    (cd "$root" && tasks-axi "$@" --file "$file")
  else
    (cd "$root" && tasks-axi "$@")
  fi
}

# A captain-kind task is a question minted to be asked, so answering completes
# it; any other held task is real work, so answering only lifts the hold.
close_mode() {  # <task-id>
  if tasks_axi show "$1" 2>/dev/null | grep -qE '^[[:space:]]*kind:[[:space:]]*captain$'
  then printf 'done'; else printf 'release'; fi
}

handled=0; filed=0; reason=; title=
while IFS=$'\t' read -r docid taskid author text; do
  [ -n "$docid" ] || continue
  routed=0
  if [ "$taskid" != "-" ] && "$SCRIPT_DIR/fm-captain-hold.sh" open "$taskid" >/dev/null 2>&1; then
    mode=$(close_mode "$taskid")
    if printf '%s\t%s\t%s\t%s\n' "$taskid" "$text" "Situation Room ($author)" "$mode" \
         | "$SCRIPT_DIR/fm-captain-hold.sh" answers --any-origin --source situationroom; then
      routed=1; handled=$((handled + 1))
    else
      echo "fm-situationroom: answer intake refused $docid (task $taskid)" >&2
    fi
  else
    note="Situation Room note from $author"
    [ "$taskid" != "-" ] && note="$note, re $taskid with no open call"
    # tasks-axi refuses parentheses in a hold reason; the verbatim answer path
    # above is untouched, only this summary line is normalised.
    reason=$(printf '%s: %s' "$note" "$text" | tr '()' '[]')
    title=$(printf '%s' "${text:0:80}" | tr '()' '[]')
    [ -n "$title" ] || title="Situation Room note from $author"
    # Minting the id from the document id keeps a replayed delivery idempotent.
    if "$SCRIPT_DIR/fm-captain-hold.sh" hold "sr-note-$docid" \
         --title "$title" \
         --reason "$reason" >/dev/null; then
      routed=1; filed=$((filed + 1))
    else
      echo "fm-situationroom: could not file $docid for the captain" >&2
    fi
  fi
  if [ "$routed" = 1 ]; then
    jq -cn '{doc:{consumed:true}}' > "$TMP/c.json"
    sr_request POST "/$SR_ANSWERS_INDEX/_update/$docid" "$TMP/c.json" application/json >/dev/null
  fi
done < "$TMP/ans.tsv"

echo "drained $COUNT answers: $handled to captain calls, $filed filed to backlog"
[ $((handled + filed)) -eq "$COUNT" ] || exit 1
