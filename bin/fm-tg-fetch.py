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
Prints nothing when the response carried no new message. Always exits 0; a
malformed or empty response is silently ignored, matching the two callers'
"absence of output means nothing new" contract.
"""
import json
import os
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
# Below this there is no point starting the call at all.
GETFILE_MIN = 3
DOWNLOAD_MIN = 4
ACK_MIN = 3

DEADLINE = None


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


def media_file_id(message):
    """The file id of whatever media this message carries, or None."""
    photos = message.get("photo") or []
    if photos:
        return sorted(photos, key=lambda p: p.get("file_size") or 0)[-1].get("file_id")
    for key in ("document", "video", "animation", "audio", "voice"):
        if message.get(key):
            return (message.get(key) or {}).get("file_id")
    return None


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


def ack_on_arrival(send_script):
    """Best-effort instant '...' so the captain knows the message landed.
    Returns True on a send that did not raise, so the caller can mark the
    record acked=1; fm-tg-drain.py retries later if this returns False."""
    ack_tmo = allot(ACK_MAX, ACK_MIN)
    if ack_tmo is None:
        return False
    try:
        import subprocess
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


def main():
    global DEADLINE
    mode, inbox, offset_file, send_script = sys.argv[1:5]
    budget = os.environ.get("FM_TG_FETCH_BUDGET") or ""
    if budget.strip().isdigit() and int(budget) > 0:
        DEADLINE = time.time() + int(budget)
    try:
        data = json.load(sys.stdin)
    except Exception:
        return 0
    if not data.get("ok"):
        return 0
    results = data.get("result") or []
    if not results:
        return 0

    media_dir = os.path.join(os.path.dirname(os.path.normpath(inbox)), "tg-media")
    tok = os.environ.get("TG_TOKEN") or ""

    new_texts = []
    for update in results:
        uid = update.get("update_id")
        message = update.get("message") or update.get("edited_message") or {}
        text = message.get("text") or message.get("caption") or ""
        # An image with no caption used to be dropped here, so every photo the
        # captain sent was silently discarded. Media presence is decided from
        # the update itself, before any download, so a message still counts as
        # real even when its bytes cannot be fetched right now.
        fid = media_file_id(message)
        if not text.strip() and not fid:
            write_offset(offset_file, uid)
            continue
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
            continue
        write_offset(offset_file, uid)

        if ack_on_arrival(send_script):
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
        return 0

    if mode == "poll":
        first = new_texts[0].replace("\n", " ")[:70]
        print("telegram: %d message(s) from the captain: %s" % (len(new_texts), first))
    else:
        for t in new_texts:
            print("CAPTAIN: " + t.replace("\n", " ")[:300])
    return 0


if __name__ == "__main__":
    sys.exit(main())
