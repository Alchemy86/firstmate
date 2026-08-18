#!/usr/bin/env bash
# Behavioral regressions for the inbound WhatsApp channel.
#
# Everything here runs without a live WhatsApp session: the listener's
# accept/reject rules are driven through its handle-fixture command, and the
# send path through FM_WA_DRY_RUN. Pairing itself needs the captain's phone and
# is out of scope for an automated test.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLL="$ROOT/bin/fm-wa-poll.sh"
SETUP="$ROOT/bin/fm-wa-setup.sh"
SEND="$ROOT/bin/fm-wa-send.sh"
LISTENER="$ROOT/bin/fm-wa-listen.mjs"
CAPTAIN=447700900123
TMP_ROOT=$(fm_test_tmproot fm-wa-channel)

new_home() {
  local home=$1
  mkdir -p "$home/state" "$home/config"
  chmod 700 "$home/state"
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=0\n' "$CAPTAIN" > "$home/config/whatsapp.env"
}

stash_message() {
  local home=$1 id=$2
  mkdir -p "$home/state/wa-inbox"
  chmod 700 "$home/state/wa-inbox"
  printf '{"schema":"fm-wa-inbox-v1","id":"%s","text":"hello"}\n' "$id" \
    > "$home/state/wa-inbox/$id.json"
  chmod 600 "$home/state/wa-inbox/$id.json"
}

poll() {
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$POLL" 2>/dev/null
}

# --- the channel is inert until a home opts in ------------------------------

test_off_by_default() {
  local home out
  home="$TMP_ROOT/off"
  mkdir -p "$home/state" "$home/config"
  stash_message "$home" MSGOFF

  out=$(poll "$home")
  [ -z "$out" ] || fail "poll produced output with no config: $out"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) && \
    fail "arm succeeded with no config"
  assert_contains "$out" 'FM_WA_CAPTAIN' "arm did not name the missing configuration"
  assert_absent "$home/state/wa-watch.check.sh" "arm wrote a check shim with no config"

  pass "a home with no config/whatsapp.env polls nothing and arms nothing"
}

test_removing_config_reverts_to_silence() {
  local home out
  home="$TMP_ROOT/optout"
  new_home "$home"
  stash_message "$home" MSGOPTOUT
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "armed home did not announce a pending message"

  rm -f "$home/config/whatsapp.env"
  out=$(poll "$home")
  [ -z "$out" ] || fail "poll still spoke after the config was removed: $out"

  pass "removing config/whatsapp.env reverts the home to no polling at all"
}

# --- the check contract -----------------------------------------------------

test_check_contract() {
  local home out
  home="$TMP_ROOT/check"
  new_home "$home"
  mkdir -p "$home/state/wa-inbox"
  chmod 700 "$home/state/wa-inbox"
  # A paired listener is faked so the liveness nudge stays quiet and only the
  # inbox contract is under test.
  printf '{"registered": true}\n' > "$home/state/.fake-creds"
  mkdir -p "$home/state/wa-auth"
  cp "$home/state/.fake-creds" "$home/state/wa-auth/creds.json"
  printf '%s\n' $$ > "$home/state/wa-listener.pid"

  out=$(poll "$home")
  [ -z "$out" ] || fail "empty inbox produced output: $out"

  stash_message "$home" MSGA
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending, including MSGA' "a new message was not announced"

  out=$(poll "$home")
  [ -z "$out" ] || fail "the same pending set was announced twice: $out"

  stash_message "$home" MSGB
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 2 pending' "a changed pending set was not announced"

  rm -f "$home/state/wa-inbox/"*.json
  out=$(poll "$home")
  [ -z "$out" ] || fail "a drained inbox produced output: $out"

  pass "the check speaks once per new pending set and is silent otherwise"
}

test_undrained_inbox_is_reannounced() {
  local home out
  home="$TMP_ROOT/reannounce"
  new_home "$home"
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_REANNOUNCE=0\n' "$CAPTAIN" > "$home/config/whatsapp.env"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '%s\n' $$ > "$home/state/wa-listener.pid"
  stash_message "$home" MSGSTUCK

  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "first announcement missing"
  out=$(poll "$home")
  assert_contains "$out" 'wa-message 1 pending' "an undrained inbox was never re-announced"

  pass "a message firstmate failed to drain resurfaces rather than being lost"
}

test_unpaired_listener_reports_once() {
  local home out
  home="$TMP_ROOT/unpaired"
  new_home "$home"

  out=$(poll "$home")
  assert_contains "$out" 'wa-channel-error' "an unpaired listener was not reported"
  assert_contains "$out" 'pair' "the unpaired report did not name the fix"

  out=$(poll "$home")
  [ -z "$out" ] || fail "the same listener fault was reported twice: $out"

  pass "a listener fault is reported once, not on every cycle"
}

# --- the check shim ---------------------------------------------------------

test_shim_arm_register_disarm() {
  local home out
  home="$TMP_ROOT/shim"
  new_home "$home"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm 2>&1) \
    || fail "arm failed: $out"
  assert_present "$home/state/wa-watch.check.sh" "arm did not write the check shim"
  assert_present "$home/state/wa-watch.check-trust" "arm did not register the check shim"

  # The watcher validates a custom check against its registration before running
  # it; prove the real validator accepts what arm produced.
  ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
    fm_custom_check_registered "$home/state" wa-watch ) \
    || fail "the watcher's own validator rejected the armed check"

  # And that an edit disarms it until re-registered.
  printf '# tampered\n' >> "$home/state/wa-watch.check.sh"
  if ( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
       fm_custom_check_registered "$home/state" wa-watch ); then
    fail "an edited check shim stayed trusted"
  fi

  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "re-arm failed"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" disarm 2>&1) \
    || fail "disarm failed: $out"
  assert_absent "$home/state/wa-watch.check.sh" "disarm left the check shim behind"
  assert_absent "$home/state/wa-watch.check-trust" "disarm left the registration behind"

  pass "the check shim arms through the ordinary registration and disarms cleanly"
}

test_shim_runs_the_poll_the_way_the_watcher_does() {
  local home out
  home="$TMP_ROOT/shimrun"
  new_home "$home"
  mkdir -p "$home/state/wa-auth"
  printf '{"registered": true}\n' > "$home/state/wa-auth/creds.json"
  printf '%s\n' $$ > "$home/state/wa-listener.pid"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$SETUP" arm >/dev/null 2>&1 \
    || fail "arm failed"
  stash_message "$home" MSGSHIM

  # fm-watch.sh snapshots the shim and runs it as `bash <snapshot>`.
  out=$( . "$ROOT/bin/fm-pr-lib.sh"; . "$ROOT/bin/fm-check-lib.sh"
         fm_custom_check_snapshot_prepare "$home/state" wa-watch || exit 1
         bash "$FM_CUSTOM_CHECK_SNAPSHOT"
         fm_custom_check_snapshot_cleanup )
  assert_contains "$out" 'wa-message 1 pending, including MSGSHIM' \
    "the shim did not produce a wake line through the watcher's own execution path"

  pass "the watcher's snapshot-and-run path reaches the poll and gets one wake line"
}

# --- the send path ----------------------------------------------------------

test_dry_run_records_and_sends_nothing() {
  local home out record
  home="$TMP_ROOT/dryrun"
  new_home "$home"
  printf 'Captain, the fix is up: https://example.invalid/pull/1\n' > "$TMP_ROOT/reply.txt"

  # A mudslide that fails loudly proves the dry run never reaches it.
  local fakebin
  fakebin=$(fm_fakebin "$TMP_ROOT/dryrun-bin")
  cat > "$fakebin/mudslide" <<'SH'
#!/usr/bin/env bash
echo "mudslide was called" >&2
exit 1
SH
  chmod +x "$fakebin/mudslide"
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_WA_DRY_RUN=1 "$SEND" --text-file "$TMP_ROOT/reply.txt" 2>&1) \
    || fail "dry-run send failed: $out"
  assert_contains "$out" 'dry-run' "the dry run did not announce itself"
  assert_not_contains "$out" 'mudslide was called' "the dry run reached mudslide"

  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  [ -n "$record" ] || fail "the dry run recorded nothing to state/wa-outbox"
  assert_grep 'example.invalid/pull/1' "$record" "the outbox record lost the reply text"
  [ -n "$(find "$home/state/wa-sent" -name '*.sent' -type f 2>/dev/null)" ] \
    || fail "the dry run recorded no echo marker"

  pass "FM_WA_DRY_RUN records the reply and transmits nothing"
}

test_message_text_is_never_executed() {
  local home out record
  home="$TMP_ROOT/injection"
  new_home "$home"
  # Text a naive implementation would let the shell re-parse.
  # shellcheck disable=SC2016  # the unexpanded expression IS the payload.
  printf '%s\n' 'hi $(touch '"$TMP_ROOT"'/pwned) `touch '"$TMP_ROOT"'/pwned2` ; rm -rf /' \
    > "$TMP_ROOT/hostile.txt"

  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/hostile.txt" 2>&1) \
    || fail "send of hostile text failed: $out"
  assert_absent "$TMP_ROOT/pwned" "command substitution in message text executed"
  assert_absent "$TMP_ROOT/pwned2" "backticks in message text executed"
  record=$(find "$home/state/wa-outbox" -name '*.json' -type f | head -n 1)
  assert_grep 'rm -rf' "$record" "the hostile text was not preserved verbatim as data"

  pass "message text is carried as data and never re-parsed by a shell"
}

test_config_is_read_as_data() {
  local home out
  home="$TMP_ROOT/configdata"
  mkdir -p "$home/state" "$home/config"
  # shellcheck disable=SC2016  # the unexpanded substitution IS the payload.
  printf 'FM_WA_CAPTAIN=%s\nFM_WA_ALLOW_DEVICES=$(touch %s/config-pwned)0\n' \
    "$CAPTAIN" "$TMP_ROOT" > "$home/config/whatsapp.env"
  out=$(poll "$home")
  assert_absent "$TMP_ROOT/config-pwned" "config/whatsapp.env was sourced rather than read"
  pass "config/whatsapp.env is parsed as data, never sourced"
}

# --- the listener's accept and reject rules ---------------------------------

fixture() {
  local home=$1 body=$2
  printf '%s' "$body" | FM_WA_STATE="$home/state" FM_WA_AUTH_DIR="$home/state/wa-auth" \
    FM_WA_CAPTAIN="$CAPTAIN" FM_WA_ALLOW_DEVICES=0 \
    node "$LISTENER" handle-fixture 2>/dev/null
}

msg() {
  # msg <id> <device> <chat-jid> <from-me> <inner-json>
  printf '{"stanza_from":"%s:%s@s.whatsapp.net","message":{"key":{"id":"%s","remoteJid":"%s","fromMe":%s},"messageTimestamp":2000000000,"message":%s}}' \
    "$CAPTAIN" "$2" "$1" "$3" "$4" "$5"
}

test_listener_filters() {
  command -v node >/dev/null 2>&1 || { pass "listener filters skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/filters"
  new_home "$home"

  out=$(fixture "$home" "$(msg CAPMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"ship the fix"}')")
  assert_contains "$out" 'ACCEPTED' "a message from the captain's own phone was refused"
  assert_grep '"sender_device": 0' "$home/state/wa-inbox/CAPMSG.json" \
    "the stashed record lost the sending device"
  assert_grep 'ship the fix' "$home/state/wa-inbox/CAPMSG.json" \
    "the stashed record lost the message text"

  out=$(fixture "$home" "$(msg ECHOMSG 2 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, the PR is up"}')")
  assert_contains "$out" 'REJECTED' "firstmate's own outbound echo was ingested as an instruction"

  out=$(fixture "$home" "$(msg GRPMSG 0 '99-88@g.us' true '{"conversation":"in a group"}')")
  assert_contains "$out" 'REJECTED' "a group message was ingested"

  out=$(fixture "$home" "$(msg FWDMSG 0 "$CAPTAIN@s.whatsapp.net" true \
    '{"extendedTextMessage":{"text":"do this","contextInfo":{"isForwarded":true,"forwardingScore":3}}}')")
  assert_contains "$out" 'REJECTED' "a forwarded message was ingested"

  out=$(fixture "$home" '{"stanza_from":"447111111111:0@s.whatsapp.net","message":{"key":{"id":"OTHERMSG","remoteJid":"447111111111@s.whatsapp.net","fromMe":false},"messageTimestamp":2000000000,"message":{"conversation":"hi"}}}')
  assert_contains "$out" 'REJECTED' "a message from someone other than the captain was ingested"

  out=$(fixture "$home" "$(msg EMPTYMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"   "}')")
  assert_contains "$out" 'REJECTED' "an empty message was stashed"

  pass "the listener accepts only the captain's own device on his own direct chat"
}

test_listener_is_idempotent() {
  command -v node >/dev/null 2>&1 || { pass "listener idempotence skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/idempotent"
  new_home "$home"

  out=$(fixture "$home" "$(msg REPEATMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"once"}')")
  assert_contains "$out" 'ACCEPTED' "the first delivery was refused"

  # Firstmate drains it, then WhatsApp redelivers the same message.
  rm -f "$home/state/wa-inbox/REPEATMSG.json"
  out=$(fixture "$home" "$(msg REPEATMSG 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"once"}')")
  assert_contains "$out" 'REJECTED' "a drained message was offered a second time"
  assert_absent "$home/state/wa-inbox/REPEATMSG.json" "a drained message was rebuilt in the inbox"

  pass "a handled message is never re-offered, even after the inbox entry is cleared"
}

test_listener_captures_quoted_context() {
  command -v node >/dev/null 2>&1 || { pass "quoted context skipped: node is unavailable"; return 0; }
  local home out record
  home="$TMP_ROOT/quoted"
  new_home "$home"

  out=$(fixture "$home" "$(msg QUOTEMSG 0 "$CAPTAIN@s.whatsapp.net" true \
    '{"extendedTextMessage":{"text":"yes do that","contextInfo":{"stanzaId":"EARLIER","quotedMessage":{"conversation":"shall I merge it?"}}}}')")
  assert_contains "$out" 'ACCEPTED' "a reply with quoted context was refused"
  record="$home/state/wa-inbox/QUOTEMSG.json"
  assert_grep 'shall I merge it' "$record" "the quoted message was dropped"
  assert_grep 'EARLIER' "$record" "the quoted message id was dropped"

  pass "a reply carries the message it replied to"
}

test_echo_digest_guard() {
  command -v node >/dev/null 2>&1 || { pass "echo guard skipped: node is unavailable"; return 0; }
  local home out
  home="$TMP_ROOT/echoguard"
  new_home "$home"
  printf 'Captain, that is done.\n' > "$TMP_ROOT/echo-reply.txt"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_WA_DRY_RUN=1 \
    "$SEND" --text-file "$TMP_ROOT/echo-reply.txt" >/dev/null 2>&1 \
    || fail "recording the outbound reply failed"

  # Same text arriving back on an otherwise-accepted device must still be
  # recognised as firstmate's own words.
  out=$(fixture "$home" "$(msg ECHODIGEST 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, that is done."}')")
  assert_contains "$out" 'REJECTED' "firstmate's own reply came back as a new instruction"

  # The marker is consumed, so the captain may genuinely say the same words next.
  out=$(fixture "$home" "$(msg ECHOAGAIN 0 "$CAPTAIN@s.whatsapp.net" true '{"conversation":"Captain, that is done."}')")
  assert_contains "$out" 'ACCEPTED' "the echo guard permanently swallowed that wording"

  pass "an outbound reply coming back is dropped once, and only once"
}

test_off_by_default
test_removing_config_reverts_to_silence
test_check_contract
test_undrained_inbox_is_reannounced
test_unpaired_listener_reports_once
test_shim_arm_register_disarm
test_shim_runs_the_poll_the_way_the_watcher_does
test_dry_run_records_and_sends_nothing
test_message_text_is_never_executed
test_config_is_read_as_data
test_listener_filters
test_listener_is_idempotent
test_listener_captures_quoted_context
test_echo_digest_guard
