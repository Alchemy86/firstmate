#!/usr/bin/env python3
"""Retire captain messages that have been surfaced AND answered.

Archival used to happen on the second surfacing, which meant every message was
shown to the model twice - the direct cause of duplicate replies the captain
complained about (2026-08-22). It also meant a message could be retired
without ever being answered if the second showing was not acted on.

Tying archival to a real outbound reply instead gives both properties at once:
a message is never retired unanswered (no loss), and never re-shown after it
has been answered (no duplicates). The ack ("...") does not count - it is sent
with FM_TG_ACK=1, which skips this entirely (see bin/fm-tg-send.sh).

THE REPLY/SURFACE RACE (2026-08-22, seen live). A reply sent within seconds of
a surfacing could find the record still flagged unsurfaced (the drain that set
"surfaced" and the send that triggers this archive run close together), so it
was not retired and re-surfaced right afterwards - indistinguishable, to the
captain, from the duplicate-reply bug this file exists to end. A message that
had already arrived by the time the reply went out has had every chance to be
seen, so the reply is taken to cover it even if "surfaced" never got set;
retire it too, printing that unsurfaced retirement so it is never invisible.

THE WINDOW ITSELF WAS WRONG, TWICE (2026-08-22). A first fix used an invented
60s window off arrival time, and still let a ~50s-old message survive a reply
and come back. A second fix tried "arrived before the reply was sent, carved
out under 10s" as a blanket rule for EVERY record - but a no-mistakes review
caught that any non-ack send at all then retires every old record, including
one that arrived mid-turn and was never shown to the model, from a merely
PROACTIVE or unrelated send. That is a direct "no message is lost" violation.

THE FIX THE CAPTAIN CHOSE (his own design call). The arrival-time window now
applies ONLY to a record that has never been surfaced, and only within a
short, conservative 10-second window of arrival - the one case it exists for:
a message that arrived moments before a reply and has not yet had a surfacing
pass run. A record that HAS been surfaced at least once retires unconditionally
on any real reply, however much later - keyed on the fact that surfacing
already happened in the past, no window needed. A record that has never been
surfaced and is older than 10 seconds stays pending no matter what unrelated
reply goes out; a missing or malformed "ts" is unknown, so it is never
retired by the window at all - neither as ancient nor as fresh enough to
qualify.

An unsurfaced retirement is the one outcome here that can cost the captain an
answer, so it is recorded rather than merely printed: this script's stdout is
discarded by its only caller, which made that notice invisible in practice.
Every notice is appended to <state>/.tg-archive.log, next to the inbox, in
addition to being printed. ONLY notices go there - routing the whole stdout to
that file logged each retirement twice and grew the file by a no-op line on
every single reply - and the log is trimmed once it passes its byte cap, the
same bound state/.watch-triage.log carries.

RETENTION. Retiring a message moves it into <state>/tg-processed, and any
attachment stays in <state>/tg-media. Nothing used to prune either, so every
message the captain had ever sent, and every image, accumulated for the life of
the home - the one artifact here with no bound, next to a size-capped log and a
recent-history-capped backlog. The newest PROCESSED_KEEP retired records are
kept and the rest deleted, and a media file is deleted once nothing references
it - neither a pending inbox record nor a kept retired one - and it is old
enough that no download in flight could still be about to claim it.

Usage: fm-tg-archive.py <inbox-dir> <processed-dir>
"""
import glob
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_tg_records as records          # noqa: E402  (owner-only umask on import)

inbox, done = sys.argv[1], sys.argv[2]
os.makedirs(done, exist_ok=True)
log_path = os.path.join(os.path.dirname(os.path.normpath(inbox)), ".tg-archive.log")


LOG_MAX_BYTES = 262144
LOG_KEEP_LINES = 2000
# Retired messages worth keeping for a look back through the captain's history.
PROCESSED_KEEP = 500
# An unreferenced media file younger than this may simply be a download whose
# record has not been updated with its path yet (bin/fm-tg-fetch.py writes the
# record first, then downloads), so it is never a deletion candidate.
MEDIA_MIN_AGE = 86400


def notice(line):
    """Print, and durably record, something an operator must be able to find."""
    print(line)
    try:
        with open(log_path, "a") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), line))
        if os.path.getsize(log_path) >= LOG_MAX_BYTES:
            with open(log_path) as fh:
                kept = fh.readlines()[-LOG_KEEP_LINES:]
            records.write_atomic(log_path, "".join(kept))
    except Exception:
        pass


def load(path):
    try:
        with open(path) as fh:
            rec = json.load(fh)
        return rec if isinstance(rec, dict) else None
    except Exception:
        return None


def mtime(path):
    try:
        return os.path.getmtime(path)
    except OSError:
        return 0.0


def drop(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def prune(inbox_dir, done_dir, media_dir):
    """Hold tg-processed and tg-media to their documented caps."""
    retired = sorted(glob.glob(os.path.join(done_dir, "*.json")), key=mtime)
    for path in retired[:-PROCESSED_KEEP] if len(retired) > PROCESSED_KEEP else []:
        drop(path)

    if not os.path.isdir(media_dir):
        return
    referenced = set()
    for path in glob.glob(os.path.join(inbox_dir, "*.json")) \
            + glob.glob(os.path.join(done_dir, "*.json")):
        rec = load(path)
        media = (rec or {}).get("media")
        if media:
            referenced.add(os.path.abspath(media))
    cutoff = time.time() - MEDIA_MIN_AGE
    for name in os.listdir(media_dir):
        path = os.path.join(media_dir, name)
        if os.path.abspath(path) in referenced or not os.path.isfile(path):
            continue
        if mtime(path) < cutoff:
            drop(path)


now = time.time()
n = 0
for path in glob.glob(os.path.join(inbox, "*.json")):
    # Use the same non-dict-tolerant load() the rest of this file (prune())
    # already relies on. The raw json.load() this used to call here crashes
    # on a record that parses but is not a dict (e.g. a bare number or array
    # from an interrupted write), which - because this script's only caller
    # discards stderr and takes "|| true" - failed retirement AND pruning
    # silently on every run from then on.
    rec = load(path)
    if rec is None:
        continue
    seen = int(rec.get("surfaced") or 0) >= 1

    ts_raw = rec.get("ts")
    try:
        ts = float(ts_raw) if ts_raw else None
    except (TypeError, ValueError):
        ts = None

    if seen:
        retire = True
    else:
        # Never surfaced: only the genuine same-turn race - arrived WITHIN
        # the last 10s, off a real arrival timestamp. Anything older than
        # that and still never surfaced is left alone; it is not part of the
        # current exchange. An unknown arrival time (no ts, or a malformed
        # one) is never retired by this window: it is unknown, not "ancient"
        # (float(None or 0) == 0.0 would make it look infinitely old) and not
        # "fresh enough to qualify" either.
        retire = ts is not None and ts >= (now - 10)

    if retire:
        os.replace(path, os.path.join(done, os.path.basename(path)))
        n += 1
        if not seen:
            notice("retired unsurfaced (arrived %ds before reply): %s"
                   % (now - ts, os.path.basename(path)))
prune(inbox, done, os.path.join(os.path.dirname(os.path.normpath(inbox)), "tg-media"))
print("archived %d" % n)
