#!/usr/bin/env bash
# Shared helpers for the firstmate WhatsApp channel.
#
# The channel is inert until this home opts in by writing a non-empty
# FM_WA_CAPTAIN into its gitignored config/whatsapp.env. With no such file every
# entry point is a hard no-op, exactly as Relay is without a pairing token, so a
# home that never opts in sees no behaviour change at all.
#
# Sourced by bin/fm-wa-poll.sh, bin/fm-wa-listen.sh, bin/fm-wa-send.sh and
# bin/fm-wa-setup.sh. docs/whatsapp-channel.md owns the operator-facing setup,
# the one-connection-per-credential-folder constraint, and the opt-out path.

FM_WA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Capture the environment's own overrides BEFORE the defaults below clear them,
# so `FM_WA_DRY_RUN=1 fm-wa-send.sh ...` still works for a single command.
FM_WA_DRY_RUN_ENV="${FM_WA_DRY_RUN:-}"
FM_WA_BAILEYS_DIR_ENV="${FM_WA_BAILEYS_DIR:-}"

# Populated by fm_wa_load_config.
FM_WA_CAPTAIN=
FM_WA_ALLOW_DEVICES=
FM_WA_DRY_RUN=
FM_WA_BAILEYS_DIR=
FM_WA_HISTORY_HORIZON=
FM_WA_REANNOUNCE=
FM_WA_CONFIG_FILE=

# Consumers source this library and read these; shellcheck cannot see across
# that boundary.
# shellcheck disable=SC2034
fm_wa_paths() {
  FM_WA_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
  FM_WA_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
  FM_WA_INBOX="$FM_WA_STATE/wa-inbox"
  FM_WA_SEEN="$FM_WA_STATE/wa-seen"
  FM_WA_SENT="$FM_WA_STATE/wa-sent"
  FM_WA_OUTBOX="$FM_WA_STATE/wa-outbox"
  FM_WA_AUTH_DIR="$FM_WA_STATE/wa-auth"
  FM_WA_PIDFILE="$FM_WA_STATE/wa-listener.pid"
  FM_WA_PIDFILE_IDENTITY="$FM_WA_STATE/wa-listener.pid-identity"
  FM_WA_LOG="$FM_WA_STATE/wa-listener.log"
  FM_WA_OFFERED="$FM_WA_STATE/wa-poll.offered"
  FM_WA_ERROR="$FM_WA_STATE/wa-poll.error"
}

# Read one KEY=VALUE from an env-style file without sourcing it. The file is
# operator-written, but treating it as data rather than shell keeps a stray
# backtick or `$(...)` from becoming execution.
fm_wa_env_get() {
  local key=$1 file=$2 line value
  [ -f "$file" ] || return 1
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n 1) || return 1
  [ -n "$line" ] || return 1
  value=${line#*=}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  printf '%s' "$value"
}

# Load the channel configuration. Returns 1 when the channel is off, which every
# caller treats as "do nothing, say nothing".
fm_wa_load_config() {
  local file
  fm_wa_paths
  file="${FM_WA_ENV_FILE:-$FM_WA_CONFIG_DIR/whatsapp.env}"
  # shellcheck disable=SC2034  # read by sourcing scripts for their diagnostics.
  FM_WA_CONFIG_FILE=$file

  FM_WA_CAPTAIN=$(fm_wa_env_get FM_WA_CAPTAIN "$file" 2>/dev/null) || FM_WA_CAPTAIN=
  [ -n "${FM_WA_CAPTAIN_OVERRIDE:-}" ] && FM_WA_CAPTAIN=$FM_WA_CAPTAIN_OVERRIDE
  FM_WA_CAPTAIN=$(printf '%s' "$FM_WA_CAPTAIN" | tr -cd '0-9')
  [ -n "$FM_WA_CAPTAIN" ] || return 1

  FM_WA_ALLOW_DEVICES=$(fm_wa_env_get FM_WA_ALLOW_DEVICES "$file" 2>/dev/null) || FM_WA_ALLOW_DEVICES=
  case "$FM_WA_ALLOW_DEVICES" in
    ''|*[!0-9,*[:space:]]*) FM_WA_ALLOW_DEVICES=0 ;;
  esac

  FM_WA_DRY_RUN=${FM_WA_DRY_RUN_ENV:-$(fm_wa_env_get FM_WA_DRY_RUN "$file" 2>/dev/null || true)}
  case "$FM_WA_DRY_RUN" in
    1|true|yes|on) FM_WA_DRY_RUN=1 ;;
    *) FM_WA_DRY_RUN= ;;
  esac

  FM_WA_BAILEYS_DIR=${FM_WA_BAILEYS_DIR_ENV:-$(fm_wa_env_get FM_WA_BAILEYS_DIR "$file" 2>/dev/null || true)}

  FM_WA_HISTORY_HORIZON=$(fm_wa_env_get FM_WA_HISTORY_HORIZON "$file" 2>/dev/null) || FM_WA_HISTORY_HORIZON=
  case "$FM_WA_HISTORY_HORIZON" in
    ''|*[!0-9]*) FM_WA_HISTORY_HORIZON=0 ;;
  esac

  FM_WA_REANNOUNCE=$(fm_wa_env_get FM_WA_REANNOUNCE "$file" 2>/dev/null) || FM_WA_REANNOUNCE=
  case "$FM_WA_REANNOUNCE" in
    ''|*[!0-9]*) FM_WA_REANNOUNCE=1800 ;;
  esac
}

# Whether this home's channel configuration is CONFIRMED gone, as distinct from
# merely unreadable.
#
# fm_wa_load_config above answers one question - is the channel usable right now
# - and every reason it can answer no looks identical from the outside: the file
# deliberately removed, a permission failure, the instant an editor has
# truncated it to rewrite it. Acting destructively on all three means one
# unlucky read stops the listener and retires the poll, after which nothing
# polls this home again and the captain messages a home that will never answer
# without being able to tell that apart from being ignored.
#
# So the destructive answer gets its own question. Returns 0 only when the file
# is definitively not there AND this process could have seen it if it were.
# Present, a directory that cannot be listed, or an override in force are all 1,
# which every caller reads as "change nothing".
fm_wa_config_confirmed_absent() {
  local file dir
  fm_wa_paths
  [ -z "${FM_WA_CAPTAIN_OVERRIDE:-}" ] || return 1
  file="${FM_WA_ENV_FILE:-$FM_WA_CONFIG_DIR/whatsapp.env}"
  if [ -e "$file" ] || [ -L "$file" ]; then
    return 1
  fi
  dir=${file%/*}
  [ "$dir" != "$file" ] || dir=.
  [ -d "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ]
}

# Everything this home generated for the channel that holds the captain's own
# words, or points at them: the stashed messages themselves, the per-message
# markers, the outbound digests and dry-run records, the watermark, the poll's
# own markers, and the listener log and health records.
#
# Switching the channel off is meant to mean gone rather than mostly gone. His
# message text sits in state/wa-inbox/ as plain JSON, and everything beside it
# is a record of what he said and when, so a teardown that left it there would
# be claiming more than it did.
#
# Only this home's own generated WhatsApp state is ever removed, and only by
# explicit name - never a sweep, never anything else under state/ or config/.
# The linked-device credentials are deliberately NOT here: they are what
# bin/fm-wa-listen.sh unpair owns, and removing them costs a trip to the
# captain's phone. Idempotent and silent with nothing to remove.
fm_wa_purge_channel_state() {
  rm -rf -- \
    "$FM_WA_INBOX" \
    "$FM_WA_SEEN" \
    "$FM_WA_SENT" \
    "$FM_WA_OUTBOX" 2>/dev/null || true
  rm -f -- \
    "$FM_WA_STATE/wa-watermark" \
    "$FM_WA_OFFERED" \
    "$FM_WA_ERROR" \
    "$FM_WA_LOG" \
    "$FM_WA_STATE/wa-listener.status" \
    "$FM_WA_STATE/wa-listener.beat" \
    "$FM_WA_STATE/wa-listener.error" \
    "$FM_WA_STATE"/wa-listener.error.* \
    "$FM_WA_STATE/wa-listener.restart" \
    "$FM_WA_STATE/wa-listener.restarts" 2>/dev/null || true
}

# A private directory owned by this user, no symlink, no group or other access.
fm_wa_private_dir() {
  local dir=$1
  [ -n "$dir" ] || return 1
  if [ ! -d "$dir" ]; then
    (umask 077; mkdir -p -- "$dir") 2>/dev/null || return 1
  fi
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  chmod 700 -- "$dir" 2>/dev/null || return 1
}

# Write stdin to a private 0600 file, atomically. Never used for message text
# that a caller then re-executes: everything downstream reads these as data.
fm_wa_publish_stdin() {
  local dir=$1 base=$2 tmp dest
  case "$base" in
    ''|.*|*/*) return 1 ;;
  esac
  fm_wa_private_dir "$dir" || return 1
  dest="$dir/$base"
  tmp=$(umask 077; mktemp "$dir/.${base}.fm-wa.XXXXXX" 2>/dev/null) || return 1
  if ! cat > "$tmp" || ! chmod 600 -- "$tmp" 2>/dev/null; then
    rm -f -- "$tmp"
    return 1
  fi
  if { [ -e "$dest" ] || [ -L "$dest" ]; } && [ ! -f "$dest" ]; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$dest" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# Message ids and outbound digests both become path components, so both go
# through this before any path is built from them.
fm_wa_id_safe() {
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#id}" -le 128 ]
}

# Encode stdin as one complete JSON string, quotes included. A recorded reply is
# named .json and read back as JSON, so the encoding cannot depend on jq being
# installed: without it the record would be raw text wearing a .json name.
# Byte-oriented on purpose (LC_ALL=C), so UTF-8 passes through untouched.
fm_wa_json_string() {
  LC_ALL=C awk '
    BEGIN {
      for (i = 1; i < 256; i++) ord[sprintf("%c", i)] = i
      printf "\""
    }
    {
      if (NR > 1) printf "\\n"
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (c == "\\") printf "\\\\"
        else if (c == "\"") printf "\\\""
        else if (ord[c] < 32) printf "\\u%04x", ord[c]
        else printf "%s", c
      }
    }
    END { printf "\"" }
  '
}

# Collapse whitespace runs to one space and drop one space from each end, so
# the outbound digest survives the reformatting WhatsApp does to a message on
# its way back. The listener's normalizeText() in bin/fm-wa-listen.mjs must
# agree with this byte for byte or the echo guard silently stops matching, so
# both sides stay on the ASCII class LC_ALL=C gives here rather than
# JavaScript's Unicode-aware \s and trim().
fm_wa_normalize_text() {
  LC_ALL=C tr -s '[:space:]' ' ' | LC_ALL=C sed 's/^ //; s/ $//'
}

fm_wa_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

# The command a pid is running, which is also how a pid file written before an
# identity was recorded is judged. Empty output means this host will not say.
fm_wa_process_command() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  COLUMNS=10000 LC_ALL=C ps -p "$pid" -o command= 2>/dev/null | head -n 1
}

# True only when the pid is running this listener's own program. A pid still
# inside nohup's handoff to node names the wrapper rather than the listener, so
# the identity below must not be bound to it until this holds.
fm_wa_process_is_listener() {
  case "$(fm_wa_process_command "$1")" in
    *fm-wa-listen.mjs*) return 0 ;;
  esac
  return 1
}

# What makes a pid an identity: a recycled pid is a different process with a
# different start time, and carrying the command with it keeps a reuse inside
# the same start-time tick a mismatch too. bin/fm-wake-lib.sh already solved
# this for the watcher and prefers /proc's starttime over ps lstart, because a
# timezone change or a boot-time correction re-renders that date and would
# evict a live process, so its helper is reused here rather than restated in a
# weaker form.
#
# Borrowing it is not free: sourcing that library defines its whole function set
# into the caller, assigns its own FM_ROOT, FM_HOME, STATE, wake-queue and
# FM_WAKE_*/FM_WATCHER_* globals, and creates STATE. A subshell, not a list of
# local declarations, is what keeps all of that out of the scripts that source
# this library, so the source and the one call it exists for happen inside one.
# STATE is pinned to this channel's own directory so that creation cannot land
# anywhere else, and every environment input that can re-render the ps fallback
# taken on a host without /proc is pinned with it: TZ, because lstart prints the
# date in the caller's zone; LC_ALL, because the month name and field order are
# locale-dependent; and COLUMNS, because both procps and BSD ps truncate the
# command column to it, which is why fm_wa_process_command above pins the same
# value. An identity recorded by a start under one environment and read back by
# the poll under another would otherwise mismatch, and the poll would answer
# that by starting a second listener onto the single credential folder WhatsApp
# allows.
#
# Empty output means this host will not say, never that the process is a
# different one.
fm_wa_process_identity() {
  local pid=$1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  (
    export TZ=UTC LC_ALL=C COLUMNS=10000
    STATE="$FM_WA_STATE"
    # shellcheck source=bin/fm-wake-lib.sh
    . "$FM_WA_LIB_DIR/fm-wake-lib.sh" || exit 1
    fm_pid_identity "$pid"
  )
}

# Bind the pid file that was just written to the process it names, so anything
# that later signals that pid can prove it is signalling this home's own
# listener. Called right after the spawn, while the pid cannot yet have been
# recycled, and only once fm_wa_process_is_listener holds: the identity carries
# the command, so binding it mid-handoff would record the wrapper's own and
# reject the live listener from the very next check.
fm_wa_record_listener_identity() {
  local pid=$1 identity
  identity=$(fm_wa_process_identity "$pid") || return 1
  [ -n "$identity" ] || return 1
  printf '%s\n' "$identity" \
    | fm_wa_publish_stdin "$FM_WA_STATE" wa-listener.pid-identity
}

# A pid on its own is not the listener. The pid file is written at spawn and
# removed only on a clean exit, so a SIGKILL, an OOM kill or a host crash leaves
# it behind, and the number in it can then be recycled by any process this user
# owns. Every caller that trusts the pid comes through here - the poll's stalled
# and deaf-listener repairs both signal exactly what this returns - so the
# binding is proved once, in this one place, rather than at each kill site.
#
# The identity recorded at spawn is the strong form. A pid file written before
# one was recorded falls back to the command naming this listener's program, as
# bin/fm-afk-start.sh does for its own daemon. A host whose ps reports nothing
# at all leaves the pid accepted: not knowing is not proof of a mismatch, and
# refusing there would spawn a second listener onto the one credential folder
# WhatsApp allows, which takes the channel down rather than protecting it.
fm_wa_listener_pid() {
  local pid recorded current cmdline
  [ -f "$FM_WA_PIDFILE" ] || return 1
  pid=$(cat "$FM_WA_PIDFILE" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  recorded=$(cat "$FM_WA_PIDFILE_IDENTITY" 2>/dev/null) || recorded=
  if [ -n "$recorded" ]; then
    current=$(fm_wa_process_identity "$pid") || current=
    [ -z "$current" ] || [ "$current" = "$recorded" ] || return 1
  else
    cmdline=$(fm_wa_process_command "$pid") || cmdline=
    case "$cmdline" in
      ''|*fm-wa-listen.mjs*) ;;
      *) return 1 ;;
    esac
  fi
  printf '%s' "$pid"
}

# A pid file naming a process that is alive but that this home cannot claim as
# its own listener. It is deliberately distinct from a stale pid file: a stale
# one is cleaned up without a word, while a live stranger must never be
# signalled and must be said out loud instead.
fm_wa_listener_pid_foreign() {
  local pid
  [ -f "$FM_WA_PIDFILE" ] || return 1
  pid=$(cat "$FM_WA_PIDFILE" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  fm_wa_listener_pid >/dev/null 2>&1 && return 1
  return 0
}

# Wait, bounded, for a pid that has been signalled to actually leave the process
# table. The bound is in tenths of a second.
#
# A kill returns once the signal is delivered, not once the target is gone: even
# SIGKILL only schedules the teardown, and a child of this shell stays visible as
# a zombie until it is reaped. Reading `kill -0` in the very next command
# therefore reports a process that is already dead as alive - measurably, on
# every attempt against a detached process - so deciding a SIGKILL failed from
# that one read is a false negative rather than an observation.
#
# Every caller here is a repair path whose whole point is a listener that stopped
# behaving, so this waits rather than concluding, and returns the instant the pid
# goes so a cooperative process costs nothing. The wait is bounded because a
# check cycle cannot hang; a host without fractional sleep polls once a second
# for the same span rather than sleeping a full second per tenth.
fm_wa_await_exit() {
  local pid=$1 limit=${2:-20} waited=0 fine=1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  sleep 0.1 2>/dev/null || fine=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$fine" -eq 1 ]; then
      waited=$(( waited + 1 ))
    else
      waited=$(( waited + 10 ))
    fi
    [ "$waited" -ge "$limit" ] && return 1
    if [ "$fine" -eq 1 ]; then
      sleep 0.1
    else
      sleep 1
    fi
  done
  return 0
}

# Stop the listener this home started, and only that one.
#
# Every path that takes the channel down comes through here - the operator's own
# stop and unpair, the disarm that retires the check, and the cycle that finds
# the channel switched off - so ownership is proved in one place rather than at
# each kill site, and the channel cleans itself up however it is switched off. A
# listener left running holds a linked device on the captain's own account with
# nothing watching it, so this must not be reachable only by an operator who read
# the documentation and did the steps in the right order.
#
# Outcomes, because callers word them differently: 0 nothing left running,
# 1 alive but not provably ours so nothing was signalled, 2 still alive after
# SIGKILL. The grace argument bounds the wait, because a poll cycle has far less
# room than a command typed by hand.
fm_wa_stop_listener() {
  local grace=${1:-10} pid waited=0
  if ! pid=$(fm_wa_listener_pid 2>/dev/null); then
    fm_wa_listener_pid_foreign && return 1
    rm -f -- "$FM_WA_PIDFILE" "$FM_WA_PIDFILE_IDENTITY" 2>/dev/null || true
    return 0
  fi
  kill "$pid" 2>/dev/null || true
  while [ "$waited" -lt "$grace" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$(( waited + 1 ))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null || true
    fm_wa_await_exit "$pid" 20 || return 2
  fi
  rm -f -- "$FM_WA_PIDFILE" "$FM_WA_PIDFILE_IDENTITY" 2>/dev/null || true
  return 0
}

# Credentials exist AND the device completed its link. A half-written folder
# from an abandoned pairing attempt is not paired, and must not block a retry.
fm_wa_paired() {
  local creds="$FM_WA_AUTH_DIR/creds.json"
  [ -f "$creds" ] || return 1
  grep -q '"registered"[[:space:]]*:[[:space:]]*true' "$creds" 2>/dev/null
}

fm_wa_age_of() {
  local file=$1 mtime now
  [ -f "$file" ] || { printf '%s' 999999; return 0; }
  mtime=$(stat -c %Y "$file" 2>/dev/null || stat -f %m "$file" 2>/dev/null) || mtime=0
  now=$(date +%s)
  printf '%s' "$(( now - mtime ))"
}
