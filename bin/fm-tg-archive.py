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
arrived more than a minute before the reply went out has had every chance to
be seen, so the reply is taken to cover it even if "surfaced" never got set;
retire it too, printing that unsurfaced retirement so it is never invisible.
Anything newer than that stays pending rather than being silently eaten.

An unsurfaced retirement is the one outcome here that can cost the captain an
answer, so it is recorded rather than merely printed: this script's stdout used
to be sent straight to /dev/null by its only caller, which made that notice
invisible in practice. Every notice is appended to <state>/.tg-archive.log,
next to the inbox, in addition to being printed.

Usage: fm-tg-archive.py <inbox-dir> <processed-dir>
"""
import glob
import json
import os
import sys
import time

inbox, done = sys.argv[1], sys.argv[2]
os.makedirs(done, exist_ok=True)
log_path = os.path.join(os.path.dirname(os.path.normpath(inbox)), ".tg-archive.log")


def notice(line):
    """Print, and durably record, something an operator must be able to find."""
    print(line)
    try:
        with open(log_path, "a") as fh:
            fh.write("%s %s\n" % (time.strftime("%Y-%m-%dT%H:%M:%S%z"), line))
    except Exception:
        pass


n = 0
for path in glob.glob(os.path.join(inbox, "*.json")):
    try:
        rec = json.load(open(path))
    except Exception:
        continue
    seen = int(rec.get("surfaced") or 0) >= 1
    old = float(rec.get("ts") or 0) < (time.time() - 60)
    if seen or old:
        os.replace(path, os.path.join(done, os.path.basename(path)))
        n += 1
        if not seen:
            notice("retired unsurfaced (arrived %ds before reply): %s"
                   % (time.time() - float(rec.get("ts") or 0), os.path.basename(path)))
print("archived %d" % n)
