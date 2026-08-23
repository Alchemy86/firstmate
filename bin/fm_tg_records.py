#!/usr/bin/env python3
"""fm_tg_records.py - how a captain's Telegram message is durably written.

Imported, never executed. Shared by bin/fm-tg-fetch.py (which creates the
record), bin/fm-tg-drain.py (which stamps the surfaced counter) and
bin/fm-tg-archive.py (which retires it), so all three agree on what a durable
write means for the ONLY copy of something the captain sent. Also the shared
owner of harness_can_surface() (below), which fm-tg-fetch.py and
fm-tg-drain.py both consult before ever sending the captain an
acknowledgement.

WHY THIS IS NOT A PLAIN open(path, "w"). A truncating open leaves an invalid,
half-written record behind if the process dies between the truncate and the
flush, and every reader here skips a record it cannot parse. The message would
then never surface, never retire, and never be refetched either - the offset
file has already advanced past its update id. That is silent loss, against this
feature's one guarantee. The kill is routine rather than hypothetical: the
watcher terminates a check's whole process group at FM_CHECK_TIMEOUT, and the
drain runs inside a Stop hook that a turn interrupt or a session exit can end
mid-write. Writing a sibling temp file and os.replace()ing it makes every
update all-or-nothing.

WHY THE UMASK. The captain's message bodies, the poll offset and any downloaded
media are private state, held to the same owner-only bound
bin/fm-check-register.sh applies to its own private records. Importing this
module applies it, so no caller has to remember.
"""
import json
import os
import subprocess

PRIVATE_UMASK = 0o077

os.umask(PRIVATE_UMASK)

# Default ceiling for harness_can_surface() below, used by any caller that
# does not have (or has exhausted) a wall-clock budget of its own to derive a
# tighter one from - bin/fm-tg-drain.py has no such budget at all.
HARNESS_CHECK_DEFAULT_TIMEOUT = 5


def harness_can_surface(timeout=HARNESS_CHECK_DEFAULT_TIMEOUT):
    """Only Claude has the Stop-hook drain/guard pair that actually shows a
    captain message to the model and enforces a reply (docs/telegram.md
    "Inbound is Claude-only"). Sending the arrival "..." acknowledgement, or
    a fallback one, on any other primary harness would tell the captain his
    message landed and is being worked when nothing will ever surface it - a
    false promise, worse than no ack at all (the captain's ruling,
    2026-08-23: "that is a FALSE PROMISE... we would be manufacturing it").

    One shared owner for bin/fm-tg-fetch.py's arrival ack and
    bin/fm-tg-drain.py's fallback ack - both used to carry hand-synced copies
    of this function (a no-mistakes review finding, 2026-08-23), which is
    exactly the drift risk this module exists to close for everything else a
    captain message touches.

    Fails toward "no": an undetectable harness, a missing bin/fm-harness.sh,
    or a timed-out check all mean this returns False, so a message looks
    unhandled rather than falsely reassures. Pass a tighter `timeout` when
    the caller has its own wall-clock budget to fit inside (see
    bin/fm-tg-fetch.py's HARNESS_CHECK_MAX/MIN via allot()); the default
    here is for a caller with no such budget at all.
    """
    if timeout is None or timeout <= 0:
        return False
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-harness.sh")
    try:
        result = subprocess.run(
            [script], timeout=timeout,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        return result.stdout.decode("utf-8", "replace").strip() == "claude"
    except Exception:
        return False


def write_atomic(path, text):
    """Replace path's contents in one step. True when the new contents landed."""
    tmp = "%s.tmp.%d" % (path, os.getpid())
    try:
        with open(tmp, "w") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
        return True
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return False


def write_record(path, rec):
    """Persist one inbox record. True when it landed."""
    return write_atomic(path, json.dumps(rec, indent=2))
