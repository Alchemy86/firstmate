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
import urllib.request


def fetch_media(tok, message, media_dir):
    """Download a photo/document/video to media_dir and return its local path."""
    if not tok:
        return None
    fid = None
    photos = message.get("photo") or []
    if photos:
        fid = sorted(photos, key=lambda p: p.get("file_size") or 0)[-1].get("file_id")
    for key in ("document", "video", "animation", "audio", "voice"):
        if not fid and message.get(key):
            fid = (message.get(key) or {}).get("file_id")
    if not fid:
        return None
    os.makedirs(media_dir, exist_ok=True)
    try:
        api = "https://api.telegram.org/bot%s" % tok
        with urllib.request.urlopen("%s/getFile?file_id=%s" % (api, fid), timeout=30) as r:
            info = json.loads(r.read().decode())
        if not info.get("ok"):
            return None
        path = info["result"]["file_path"]
        dest = os.path.join(media_dir, "%s_%s" % (message.get("message_id"), os.path.basename(path)))
        with urllib.request.urlopen(
                "https://api.telegram.org/file/bot%s/%s" % (tok, path), timeout=120) as r:
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
    try:
        import subprocess
        result = subprocess.run(
            [send_script, "..."], timeout=25,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=dict(os.environ, FM_TG_ACK="1"))
        return result.returncode == 0
    except Exception:
        return False


def main():
    mode, inbox, offset_file, send_script = sys.argv[1:5]
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

    new_texts, last = [], None
    for update in results:
        uid = update.get("update_id")
        last = uid
        message = update.get("message") or update.get("edited_message") or {}
        text = message.get("text") or message.get("caption") or ""
        # An image with no caption used to be dropped here, so every photo the
        # captain sent was silently discarded. Fetch it instead and record the
        # local path; the text may legitimately be empty.
        media = fetch_media(tok, message, media_dir)
        if not text.strip() and not media:
            continue
        rec = {"update_id": uid,
               "chat_id": (message.get("chat") or {}).get("id"),
               "ts": message.get("date"),
               "text": text}
        if media:
            rec["media"] = media
            if not text.strip():
                text = "[image: %s]" % media
        path = os.path.join(inbox, "%s.json" % uid)
        if os.path.exists(path):
            continue
        if ack_on_arrival(send_script):
            rec["acked"] = 1
        with open(path, "w") as fh:
            json.dump(rec, fh, indent=2)
        new_texts.append(text)

    if last is not None:
        with open(offset_file, "w") as fh:
            fh.write(str(last + 1))

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
