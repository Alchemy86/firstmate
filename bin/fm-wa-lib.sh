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

fm_wa_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

fm_wa_listener_pid() {
  local pid
  [ -f "$FM_WA_PIDFILE" ] || return 1
  pid=$(cat "$FM_WA_PIDFILE" 2>/dev/null) || return 1
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
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
