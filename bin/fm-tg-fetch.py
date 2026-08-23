#!/usr/bin/env python3
"""Parse one Telegram getUpdates response (on stdin), record any new captain
messages, and acknowledge each on ARRIVAL - not at firstmate's turn end.

Shared by bin/fm-tg-poll.sh (single fetch, watcher check-cycle contract) and
bin/fm-tg-wait.sh (long-poll loop). Both used to embed a near-identical copy of
this logic as a python3 -c '...' single-quoted string; an apostrophe anywhere
in that block broke the enclosing shell script (hit in production 2026-08-22).
One real file, one owner of the parsing and media-fetch logic.

Captain, 2026-08-22: "i got a ... at the end of your DELAYED response". The ack
used to fire in fm-tg-drain.py, which only runs when firstmate's turn ends, so
during a long turn the captain got silence and then the "..." arrived beside
the finished answer instead of ahead of it. Firing it here, the moment a new
message is written to the inbox, is the only correct timing regardless of
which caller wins the race between the watcher's poll cycle and a blocked
fm-tg-wait.sh. Each record is marked acked=1 so fm-tg-drain.py knows not to
send a second one; it still re-tries the ack, best-effort, if this one failed.

THE CHECK BUDGET. When the poller calls this, it is running as a watcher
state check, and the watcher kills a check's whole process group at
FM_CHECK_TIMEOUT (default 30s). An unbounded media download - the old code
allowed 30s for getFile plus 120s for the file itself, per message - blew
straight through that, and a killed check has written neither the inbox record
nor the offset file, so the very same update is refetched and re-acknowledged
on every following cycle ("..." spam) and never recorded at all. So:

  * FM_TG_FETCH_BUDGET, when set, is a whole-second wall-clock budget for
    everything below. Every network call is bounded by what is left of it, and
    work that no longer fits is skipped rather than started.
  * The inbox record and the offset are written FIRST, before the ack and
    before any media download, so the durable "this update is handled" facts
    survive even a kill mid-download. The ack and the media path are folded
    into the record afterwards. Each of those writes is all-or-nothing, and
    owner-only: bin/fm_tg_records.py owns both properties for every script
    that touches a captain message.
  * A message whose media could not be fetched inside the budget is still
    recorded and still surfaces, carrying its file id, rather than being
    dropped as "no text and no media".

Usage: fm-tg-fetch.py <poll|wait> <inbox-dir> <offset-file> <send-script>
  poll - print at most one summary line: "telegram: N message(s) ...: <preview>"
  wait - print one "CAPTAIN: <text>" line per new message
Prints nothing when the response carried no new message.

EXIT STATUS. 0 means the response was a usable getUpdates payload, whether or
not it carried anything new; UNUSABLE (3) means it was not - malformed, or an
{"ok": false} error body. The distinction is what bin/fm-tg-wait.sh's backoff
keys on: Telegram answers a duplicate getUpdates on one token with an immediate
409, and a revoked token with a 401, both of which curl reports as a perfectly
successful transfer of an error body. Treating those as a good pass re-polled
with no delay at all, spinning that loop at ~16 calls a second for the whole
Stop-hook window. An unusable response also names itself on stderr, so
bin/fm-tg-poll.sh can report WHY the channel refused rather than leaving a
revoked token indistinguishable from a captain who has not written. Anything
else that goes wrong - an update carrying no usable update_id, or any
unexpected failure at all - takes the same route, because a bare traceback's
exit 1 reads to a caller exactly like a usable poll: the error record gets
cleared while the same unacknowledgeable payload is refetched for ever.

CHAT-ID FILTER (2026-08-22, a no-mistakes review finding, captain-approved).
Telegram bots accept a direct message from ANYONE who knows the bot's public
username - inbound updates were never checked against the configured
TG_CHAT_ID. Without this, a third party could message the bot and have it
recorded as a captain message, surfaced to firstmate as "CAPTAIN: <text>",
acknowledged, and used to force a blocking turn-end demanding a reply that
lands in the REAL captain's chat - a captain-impersonation hole. Every update
whose chat id does not match TG_CHAT_ID is now dropped before it is ever
recorded, with a visible line on stderr (never silent) so a legitimately
wrong-chat message from the captain himself is diagnosable rather than a
mystery. The cost, accepted deliberately: the captain must message from the
chat he originally paired.
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_tg_records as records          # noqa: E402

# Ceilings used when no budget is imposed (bin/fm-tg-wait.sh runs as its own
# tracked background task, not inside the watcher's per-check bound).
GETFILE_MAX = 30
DOWNLOAD_MAX = 120
ACK_MAX = 25
HARNESS_CHECK_MAX = 5
# Below this there is no point starting the call at all.
GETFILE_MIN = 3
DOWNLOAD_MIN = 4
ACK_MIN = 3
HARNESS_CHECK_MIN = 1

DEADLINE = None

# Exit status for a response this script could not use (see the module
# docstring): distinct from 0 so a caller can tell "nothing new" from "Telegram
# refused us" without parsing the body itself.
UNUSABLE = 3


def remaining():
    """Seconds left in the wall-clock budget, or None when unbounded."""
    if DEADLINE is None:
        return None
    return DEADLINE - time.time()


def allot(ceiling, floor):
    """Timeout for one call: the ceiling, cut to what the budget still allows.
    Returns None when what is left cannot cover the floor."""
    left = remaining()
    if left is None:
        return ceiling
    if left < floor:
        return None
    return max(floor, min(ceiling, int(left)))


# Every message kind that carries a downloadable file id. video_note (the round
# clip a phone records with one tap) and sticker were missing, so a message
# carrying only one of those had no text and no recognised file id, advanced the
# offset, and vanished without a record, an acknowledgement, or any trace on
# disk - a hole straight through the "no message is lost" guarantee, on exactly
# the phone-first path this feature exists to serve.
MEDIA_KEYS = ("document", "video", "video_note", "animation", "audio", "voice", "sticker")

# Envelope fields every message carries; anything left over names what the
# message actually is, which is what a contentless message is described by.
ENVELOPE_KEYS = frozenset((
    "message_id", "message_thread_id", "from", "sender_chat", "chat", "date",
    "edit_date", "reply_to_message", "entities", "caption_entities", "via_bot",
    "media_group_id", "link_preview_options", "has_protected_content",
    "is_topic_message", "is_automatic_forward", "author_signature",
    "forward_origin", "business_connection_id", "reply_markup",
))


def media_file_id(message):
    """The file id of whatever media this message carries, or None."""
    photos = message.get("photo") or []
    if photos:
        return sorted(photos, key=lambda p: p.get("file_size") or 0)[-1].get("file_id")
    for key in MEDIA_KEYS:
        if message.get(key):
            return (message.get(key) or {}).get("file_id")
    return None


def describe_contentless(message):
    """A stand-in body for a message with no text and no fetchable file.

    A contact, a location, a poll, a dice roll: something the captain sent that
    this script cannot render. Recording it as a placeholder still surfaces it,
    so he learns it arrived and can say what it was, instead of getting the
    total silence a dropped update produces.
    """
    kinds = sorted(k for k in message if k not in ENVELOPE_KEYS)
    return "[message with no text: %s]" % (", ".join(kinds) or "empty")


def fetch_media(tok, message, fid, media_dir):
    """Download a photo/document/video to media_dir and return its local path.
    Returns None when there is no budget left for it, or on any failure."""
    if not tok or not fid:
        return None
    getfile_tmo = allot(GETFILE_MAX, GETFILE_MIN)
    if getfile_tmo is None:
        return None
    try:
        os.makedirs(media_dir, exist_ok=True)
        api = "https://api.telegram.org/bot%s" % tok
        with urllib.request.urlopen(
                "%s/getFile?file_id=%s" % (api, fid), timeout=getfile_tmo) as r:
            info = json.loads(r.read().decode())
        if not info.get("ok"):
            return None
        path = info["result"]["file_path"]
        download_tmo = allot(DOWNLOAD_MAX, DOWNLOAD_MIN)
        if download_tmo is None:
            return None
        dest = os.path.join(media_dir, "%s_%s" % (message.get("message_id"), os.path.basename(path)))
        with urllib.request.urlopen(
                "https://api.telegram.org/file/bot%s/%s" % (tok, path),
                timeout=download_tmo) as r:
            data = r.read()
        with open(dest, "wb") as fh:
            fh.write(data)
        return dest
    except Exception:
        return None


def harness_can_surface():
    """Only Claude has the Stop-hook drain/guard pair that actually shows a
    captain message to the model and enforces a reply (docs/telegram.md
    "Inbound is Claude-only"). Acking a message on any other primary harness
    would tell the captain it landed and is being worked when nothing will
    ever surface it - a false promise, worse than no ack at all, and exactly
    the "ack then silence forever" failure the captain was angriest about
    (2026-08-23: "that is a FALSE PROMISE... we would be manufacturing it").

    Fails toward "no": an undetectable harness, a missing bin/fm-harness.sh,
    or a timed-out check all mean this returns False, so a message looks
    unhandled rather than falsely reassures. The watcher's own poll (running
    on every primary harness) is the caller that actually needs this - the
    long-poll path only ever runs from Claude's own Stop hook to begin with,
    so this check is a no-op there in practice, but it is applied
    unconditionally rather than keyed on `mode` so the guarantee holds even
    if that calling context ever changes."""
    tmo = allot(HARNESS_CHECK_MAX, HARNESS_CHECK_MIN)
    if tmo is None:
        return False
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-harness.sh")
    try:
        result = subprocess.run(
            [script], timeout=tmo,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return result.stdout.decode("utf-8", "replace").strip() == "claude"
    except Exception:
        return False


def ack_on_arrival(send_script):
    """Best-effort instant '...' so the captain knows the message landed.
    Returns True on a send that did not raise, so the caller can mark the
    record acked=1; fm-tg-drain.py retries later if this returns False.
    Caller must gate this on harness_can_surface() first - see there."""
    ack_tmo = allot(ACK_MAX, ACK_MIN)
    if ack_tmo is None:
        return False
    try:
        result = subprocess.run(
            [send_script, "..."], timeout=ack_tmo,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=dict(os.environ, FM_TG_ACK="1"))
        return result.returncode == 0
    except Exception:
        return False


def write_record(path, rec):
    return records.write_record(path, rec)


def write_offset(offset_file, last):
    records.write_atomic(offset_file, str(last + 1))


def describe_refusal(data):
    """Telegram's own words for why it refused, short enough for one line."""
    if not isinstance(data, dict):
        return "malformed reply"
    code = data.get("error_code")
    desc = data.get("description")
    if not isinstance(desc, str) or not desc.strip():
        desc = "no description"
    desc = " ".join(desc.split())[:120]
    if isinstance(code, int):
        return "%d %s" % (code, desc)
    return desc


def refuse(reason):
    """Name the refusal on stderr so a caller can report it, not just count it.

    The exit status alone tells a caller that the response was unusable; only
    the body says whether that is a revoked token, a duplicate poller, or a
    rate limit, which is the difference between something the captain must fix
    and something that clears itself.
    """
    sys.stderr.write("%s\n" % reason)
    return UNUSABLE


def main():
    global DEADLINE
    mode, inbox, offset_file, send_script = sys.argv[1:5]
    budget = os.environ.get("FM_TG_FETCH_BUDGET") or ""
    if budget.strip().isdigit() and int(budget) > 0:
        DEADLINE = time.time() + int(budget)
    try:
        data = json.load(sys.stdin)
    except Exception:
        return refuse("malformed reply")
    if not isinstance(data, dict) or not data.get("ok"):
        return refuse(describe_refusal(data))
    results = data.get("result") or []
    if not results:
        return 0

    media_dir = os.path.join(os.path.dirname(os.path.normpath(inbox)), "tg-media")
    tok = os.environ.get("TG_TOKEN") or ""
    configured_chat_id = os.environ.get("TG_CHAT_ID") or ""

    new_texts = []
    unusable_updates = 0
    write_failures = 0
    # Computed at most once per fetch, not per message (the harness cannot
    # change mid-batch and a batch can carry several new messages), and only
    # when actually needed - a batch of all-duplicate or all-unusable updates
    # never reaches the ack point at all.
    can_surface = None
    for update in results:
        uid = update.get("update_id")
        # Every acknowledgement offset is uid + 1, so an update carrying no
        # usable update_id cannot be acknowledged and must not be allowed to
        # abort the batch: an uncaught TypeError here left the offset behind
        # this payload, so the very next poll refetched it and crashed again -
        # a permanent stall of the captain channel, invisible because the
        # traceback's exit 1 is not the UNUSABLE the pollers report on.
        if isinstance(uid, bool) or not isinstance(uid, int):
            sys.stderr.write(
                "telegram: skipped an update with no usable update_id (%r)\n" % (uid,))
            unusable_updates += 1
            continue
        message = update.get("message") or update.get("edited_message") or {}
        if not message:
            # Not a captain message at all - a chat-member change, a poll
            # answer, some other update kind. Nothing was sent to record, and
            # deciding that before the chat filter keeps an ordinary update
            # kind out of the drop notice an operator reads while chasing an
            # impersonation report.
            write_offset(offset_file, uid)
            continue
        msg_chat_id = (message.get("chat") or {}).get("id")
        if configured_chat_id and str(msg_chat_id) != str(configured_chat_id):
            sys.stderr.write(
                "telegram: dropped update %s from chat_id=%s (configured chat is %s)\n"
                % (uid, msg_chat_id, configured_chat_id))
            write_offset(offset_file, uid)
            continue
        text = message.get("text") or message.get("caption") or ""
        # An image with no caption used to be dropped here, so every photo the
        # captain sent was silently discarded. Media presence is decided from
        # the update itself, before any download, so a message still counts as
        # real even when its bytes cannot be fetched right now.
        fid = media_file_id(message)
        if not text.strip() and not fid:
            text = describe_contentless(message)
        path = os.path.join(inbox, "%s.json" % uid)
        if os.path.exists(path):
            write_offset(offset_file, uid)
            continue
        rec = {"update_id": uid,
               "chat_id": (message.get("chat") or {}).get("id"),
               "ts": message.get("date"),
               "text": text}
        if fid:
            rec["media_id"] = fid
        # Durable first: the record suppresses a duplicate refetch and the
        # offset advances past this update, both before anything slow runs.
        if not write_record(path, rec):
            # write_offset() only ever writes uid + 1, with no memory of which
            # uids actually got recorded - so `continue`ing to the next update
            # in this batch and letting IT succeed would advance the offset
            # PAST this failed one, and Telegram never re-sends an
            # already-acknowledged offset. That silently lost the update
            # forever on any write failure (full disk, a permission change).
            # Stop the whole batch here instead: nothing after this point gets
            # acknowledged, so everything from here, including this update,
            # is refetched and retried on the next poll.
            write_failures += 1
            break
        write_offset(offset_file, uid)

        if can_surface is None:
            can_surface = harness_can_surface()
        if can_surface and ack_on_arrival(send_script):
            rec["acked"] = 1
            write_record(path, rec)

        media = fetch_media(tok, message, fid, media_dir)
        if media:
            rec["media"] = media
            write_record(path, rec)
        if not text.strip():
            if media:
                text = "[image: %s]" % media
            else:
                text = "[media received; bytes not downloaded]"
        new_texts.append(text)

    if not new_texts:
        if write_failures:
            # Same reasoning as the unusable-update_id case: nothing in this
            # payload was durably recorded, so it must not read as "the
            # captain has not written" - that hides a real, ongoing write
            # failure (full disk, a permission change) behind total silence.
            return refuse("could not durably record %d update(s)" % write_failures)
        if unusable_updates and unusable_updates == len(results):
            # Nothing in this payload could be acknowledged, so Telegram hands
            # back the same bytes next time. Report it as a refusal instead of
            # letting it read as a quiet channel and retry unbounded in silence.
            return refuse("no usable update_id in %d update(s)" % unusable_updates)
        return 0

    if mode == "poll":
        first = new_texts[0].replace("\n", " ")[:70]
        print("telegram: %d message(s) from the captain: %s" % (len(new_texts), first))
    else:
        for t in new_texts:
            print("CAPTAIN: " + t.replace("\n", " ")[:300])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        # Any unexpected failure on one update is a refusal a caller can see and
        # report, never a bare traceback: bin/fm-tg-poll.sh keys on UNUSABLE, so
        # an exit 1 here was indistinguishable from a usable poll and quietly
        # cleared the error record while the same payload retried forever.
        sys.exit(refuse("fetch failed: %s: %s" % (type(exc).__name__, exc)))
