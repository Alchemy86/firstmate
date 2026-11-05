#!/usr/bin/env bash
# fm-situationroom-lib.sh - shared config and transport for the Claude Work board.
#
# Sourced by fm-situationroom-publish.sh and fm-situationroom-drain.sh.
# Owns exactly two things: resolving the OpenSearch endpoint from the
# operator's private env file, and issuing a request that fails loudly.
#
# Config file (gitignored, captain-private), default ~/.config/fm-situationroom.env,
# override with FM_SR_ENV_OVERRIDE:
#   SR_OPENSEARCH_URL=https://opensearch.example
#   SR_OPENSEARCH_USER=admin
#   SR_OPENSEARCH_PASSWORD=...
# Optional: SR_WORK_INDEX, SR_ANSWERS_INDEX override the two index names.
# Optional: SR_PUBLISH_HOME pins which FM_HOME publishes the board, so sibling
# secondmate homes sharing one $HOME cannot sweep each other's tasks away.
#
# Every failure here is fatal and named. There is no degraded mode: a board
# that silently stops publishing is worse than one that stops loudly.

SR_WORK_INDEX_DEFAULT=situation-room-claude-work
SR_ANSWERS_INDEX_DEFAULT=situation-room-claude-answers

sr_die() { echo "fm-situationroom: $*" >&2; exit 1; }

sr_load_env() {
  local envf="${FM_SR_ENV_OVERRIDE:-$HOME/.config/fm-situationroom.env}"
  [ -f "$envf" ] || sr_die "no config at $envf (see this script's header)"
  set -a
  # shellcheck source=/dev/null # resolved runtime path, not a repo file
  . "$envf"
  set +a
  [ -n "${SR_OPENSEARCH_URL:-}" ] || sr_die "SR_OPENSEARCH_URL unset in $envf"
  [ -n "${SR_OPENSEARCH_USER:-}" ] || sr_die "SR_OPENSEARCH_USER unset in $envf"
  [ -n "${SR_OPENSEARCH_PASSWORD:-}" ] || sr_die "SR_OPENSEARCH_PASSWORD unset in $envf"
  SR_WORK_INDEX="${SR_WORK_INDEX:-$SR_WORK_INDEX_DEFAULT}"
  SR_ANSWERS_INDEX="${SR_ANSWERS_INDEX:-$SR_ANSWERS_INDEX_DEFAULT}"
  command -v jq >/dev/null 2>&1 || sr_die "jq not found"
  command -v curl >/dev/null 2>&1 || sr_die "curl not found"
}

# sr_request METHOD PATH [BODY-FILE] [CONTENT-TYPE] -> body on stdout; named fatal error otherwise.
sr_request() {
  local method="$1" path="$2" body="${3:-}" ctype="${4:-application/x-ndjson}" out code
  out="$(mktemp)" || sr_die "mktemp failed"
  if [ -n "$body" ]; then
    code=$(curl -sS -m "${SR_TIMEOUT:-30}" -o "$out" -w '%{http_code}' \
      -u "$SR_OPENSEARCH_USER:$SR_OPENSEARCH_PASSWORD" \
      -X "$method" "$SR_OPENSEARCH_URL$path" \
      -H "Content-Type: $ctype" --data-binary "@$body") || code=000
  else
    code=$(curl -sS -m "${SR_TIMEOUT:-30}" -o "$out" -w '%{http_code}' \
      -u "$SR_OPENSEARCH_USER:$SR_OPENSEARCH_PASSWORD" \
      -X "$method" "$SR_OPENSEARCH_URL$path") || code=000
  fi
  case "$code" in
    2??) cat "$out"; rm -f "$out"; return 0 ;;
    000) rm -f "$out"; sr_die "$method $path unreachable (network/auth failure)" ;;
    *) echo "fm-situationroom: $method $path failed HTTP $code" >&2
       head -c 500 "$out" >&2; echo >&2; rm -f "$out"; exit 1 ;;
  esac
}
