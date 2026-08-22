#!/usr/bin/env python3
"""fm_tg_records.py - how a captain's Telegram message is durably written.

Imported, never executed. Shared by bin/fm-tg-fetch.py (which creates the
record), bin/fm-tg-drain.py (which stamps the surfaced counter) and
bin/fm-tg-archive.py (which retires it), so all three agree on what a durable
write means for the ONLY copy of something the captain sent.

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

PRIVATE_UMASK = 0o077

os.umask(PRIVATE_UMASK)


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
