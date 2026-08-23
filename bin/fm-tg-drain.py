#!/usr/bin/env python3
"""Surface pending captain Telegram messages, retiring each only once a real
reply has been sent.

Why re-surface rather than retire on first showing: a message archived the
first time it is printed is lost for ever if the harness does not actually
show that output to the model. That happened repeatedly on 2026-08-21 and
forced the captain to send everything twice to get a reply. Re-surfacing an
unanswered message on every subsequent hook firing is self-correcting and
needs no discipline from the model.

Archival happens only in fm-tg-archive.py, when a real reply is actually sent.
Retiring on the second surfacing (an older rule) showed the captain's every
message to the model twice, which is what produced the duplicate replies he
objected to on 2026-08-22 - and it could still retire a message that was never
answered.

The acknowledgement is normally fired on ARRIVAL by fm-tg-fetch.py (used by
bin/fm-tg-poll.sh and bin/fm-tg-wait.sh), which marks the record acked=1. This
script only sends the "..." as a FALLBACK, on first surfacing, when that flag
is absent - covering a failed arrival-time send so no message goes fully
unacknowledged. Like the arrival ack, this fallback never fires on a
non-Claude primary (harness_can_surface() below) - only Claude's Stop hooks
ever actually surface a message to the model, so acking one anywhere else
would promise the captain his message is being handled when nothing will
ever show it to firstmate.

Usage: fm-tg-drain.py <inbox-dir> <processed-dir>
Prints nothing and exits 1 when there is nothing pending.
"""
import glob
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_tg_records as records          # noqa: E402

inbox, done = sys.argv[1], sys.argv[2]
os.makedirs(done, exist_ok=True)
state_dir = os.path.dirname(os.path.normpath(inbox))
bin_dir = os.path.dirname(os.path.abspath(__file__))


def harness_can_surface():
    """Duplicated from bin/fm-tg-fetch.py's function of the same name (a
    hyphenated bin/fm-tg-*.py filename is a script, not an importable
    module, so the two owners cannot share one definition) - keep both in
    sync on any change. Only Claude has the Stop-hook drain/guard pair that
    actually shows a captain message to the model and enforces a reply
    (docs/telegram.md "Inbound is Claude-only"). This script's own fallback
    ack below used to be reachable from bin/fm-tg-poll.sh's harness-agnostic
    watcher-poll path too (it now calls this script directly to stamp
    "surfaced" - see fm-tg-poll.sh), which meant a non-Claude primary's own
    ack, deliberately withheld by fm-tg-fetch.py, was un-withheld right back
    by this "fallback" - the same false promise the withholding exists to
    prevent. Fails toward "no": an undetectable harness or a missing
    bin/fm-harness.sh means no ack, not a false one."""
    script = os.path.join(bin_dir, "fm-harness.sh")
    try:
        result = subprocess.run(
            [script], timeout=5,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return result.stdout.decode("utf-8", "replace").strip() == "claude"
    except Exception:
        return False

rows = []
for path in glob.glob(os.path.join(inbox, "*.json")):
    try:
        rec = json.load(open(path))
    except Exception:
        continue
    # A record that parses as JSON but is not a dict (e.g. an interrupted
    # write that left a bare number or array) has no .get() - skip it rather
    # than crash the whole drain, the same non-dict tolerance every other
    # reader of these records already has (fm-tg-archive.py's load()).
    if not isinstance(rec, dict):
        continue
    rows.append((rec.get("ts") or 0, path, rec))
rows.sort(key=lambda r: r[0])

out = []
first_surface = False
for _ts, path, rec in rows:
    text = (rec.get("text") or "").strip()
    media = rec.get("media")
    if text:
        line = text.replace("\n", " ")[:4000]
    elif media:
        line = "[image] %s" % media
    elif rec.get("media_id"):
        # The captain sent media whose bytes could not be pulled down inside
        # the poll's budget (see bin/fm-tg-fetch.py). Surface it anyway: a
        # message he sent must never go unmentioned just because the
        # attachment is missing.
        line = "[media received; bytes not downloaded - file id %s]" % rec.get("media_id")
    else:
        line = None
    if line:
        if media and text:
            line += "  [image: %s]" % media
        out.append(line)
    seen = int(rec.get("surfaced") or 0) + 1
    if seen == 1 and not int(rec.get("acked") or 0):
        first_surface = True
    # NEVER archive here; see the module docstring.
    rec["surfaced"] = seen
    # All-or-nothing: a half-written record is skipped by every reader, and the
    # message it holds is then never surfaced, never retired and never refetched
    # (bin/fm_tg_records.py). This hook is interruptible mid-write.
    records.write_record(path, rec)

if not out:
    sys.exit(1)

# Stamp that a captain message was surfaced. fm-tg-guard.sh compares this
# against the last SEND and refuses to let the turn end quietly if a reply
# never went out. Mechanical, not remembered - the captain's instruction.
try:
    open(os.path.join(state_dir, ".tg-last-surfaced"), "w").close()
except Exception:
    pass

if first_surface and harness_can_surface():
    try:
        env = dict(os.environ, FM_TG_ACK="1")
        subprocess.run([os.path.join(bin_dir, "fm-tg-send.sh"), "..."],
                       timeout=25, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, env=env)
    except Exception:
        pass
# Lead with the count so a truncated wake is detectable.
print("%d captain message(s) pending:" % len(out))
for line in out:
    print("CAPTAIN: " + line)
