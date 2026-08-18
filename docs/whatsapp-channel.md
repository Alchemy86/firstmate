# WhatsApp channel

Firstmate can already **send** the captain a WhatsApp message with `mudslide send`.
This document covers the other direction: the captain messages firstmate, firstmate wakes, reads it, and does the work he asked for.

The channel ships inert. A home that never opts in polls nothing, runs nothing, and behaves exactly as it did before.

## Shape

It is the same shape Relay uses for public mentions, for the same reasons:

| piece | Relay | WhatsApp |
| --- | --- | --- |
| poll | `bin/fm-x-poll.sh` | `bin/fm-wa-poll.sh` |
| stash | `state/x-inbox/<request_id>.json` | `state/wa-inbox/<message-id>.json` |
| check shim | `state/x-watch.check.sh` | `state/wa-watch.check.sh` |
| wake | `check:` wake carrying `x-mention ...` | `check:` wake carrying `wa-message ...` |
| skill | `fmx-respond` | `wa-respond` |

Nothing in `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh` or the away-mode daemon changes.
The check runs through the ordinary registered-custom-check path that firstmate already uses for a task's merge poll: `bin/fm-wa-setup.sh arm` writes the shim and binds it with `bin/fm-check-register.sh`, and the watcher hashes it against that binding before running it.

### An armed channel keeps a watcher running

An armed `state/wa-watch.check.sh` counts as a reason to supervise the home, exactly as Relay's `state/x-watch.check.sh` does.
Without that, an idle home with no work in flight arms no watcher at all, so the poll would never run and the captain's messages would pile up in `state/wa-inbox/` with nothing to announce them.
That is the normal case rather than the edge case: the captain messages from his phone precisely when nothing is running, to start something.

The predicate lives in `bin/fm-supervision-lib.sh` and is what the turn-end guards and the watcher-liveness warning already read.
A home that has not armed the channel has no such file and is unaffected.

### Cadence

Arming also writes `config/wa-mode.env`, the generated watcher cadence, the same way `bin/fm-bootstrap.sh` writes `config/x-mode.env` for Relay.
It exports `FM_CHECK_INTERVAL=30`, so a message is picked up within seconds instead of waiting up to the default five minutes for the next sweep.
It is the same value Relay uses, so a home running both cannot end up with two cadences that disagree.

Source it before launching a watcher process.
The emitted session-start supervision block names the file when it exists, and the arm paths that own their own launch (`bin/fm-claude-stop-autoarm.sh`, `bin/fm-turnend-guard-cursor.sh`, `.opencode/plugins/fm-primary-watch-arm.js`, `.pi/extensions/fm-primary-pi-watch.ts`) source it themselves.
`bin/fm-wa-setup.sh disarm` removes it again, and the home reverts to the default cadence on the next supervision cycle.

### Deliberately not reported at session start

Relay lists a pending public commitment in the session-start digest; this channel deliberately does not list a pending inbox there.
Reporting it would mean editing session-start code, and the whole point of the shape above is that the channel stays purely additive so it can never destabilise the supervision backbone.
After a restart an undrained inbox is resurfaced by `FM_WA_REANNOUNCE` instead: the announcement marker goes stale, the next poll cycle announces the pending set again, and the wake arrives through the same path every other message uses.

One thing differs from Relay by necessity. Relay's poll makes the network call itself; WhatsApp cannot work that way, because a WhatsApp connection takes tens of seconds to establish and re-establish. So `bin/fm-wa-listen.sh` runs one long-lived connection that stashes messages as they arrive, and `bin/fm-wa-poll.sh` is a local directory read that also nudges the listener back up if it died. The poll finishes in about 25 milliseconds, far inside `FM_CHECK_TIMEOUT`.

## The connection constraint, and what was chosen

**baileys allows one live connection per credential folder.** A listener holding mudslide's session fights `mudslide send` for it.

That is not theoretical. A listener pointed at mudslide's own folder at `~/.local/share/mudslide` fails with `statusCode 405` on connect and loops reconnecting, and repeated 405 reconnects put the existing pairing at risk.

**This channel takes option (b): a second linked device with its own credential folder.**
WhatsApp permits up to four linked devices. The listener pairs its own, and keeps its credentials in `state/wa-auth/`, which is private to this home and gitignored.

The consequence that matters: **`mudslide send` is never touched.** Arming, disarming, restarting or breaking the listener cannot affect sending, because they do not share a credential folder, a process, or a device registration. Outbound stays exactly where it was.

The cost is one extra pairing, which only the captain can complete, because the code is entered on his phone.

The rejected alternative, option (a) - one process that both listens and sends, with firstmate handing it outbound work through a queue - would need no second pairing, but it puts the working send path behind a process that can crash, and a raw `mudslide send` typed at a shell would still collide with it. A channel addition should not be able to break something that already works.

## Which chat this is

The mudslide device is linked to the captain's own account, so the channel is his **chat with himself** - "Message yourself" on his phone.
He types there, his linked devices see it, and firstmate's replies land in the same place. No group, no third party, nothing to route.

That does mean everything on this chat is `fromMe`, including firstmate's own replies coming back. Two independent guards stop firstmate reading its own words as new instructions:

1. **Sender device.** WhatsApp numbers devices: the captain's phone is device `0`, mudslide is a linked device, and the listener is another. Only device `0` is accepted by default. baileys drops the device from the message key, so the listener reads it from the raw stanza and correlates by message id.
2. **Outbound digest.** `bin/fm-wa-send.sh` records a digest of every message it sends under `state/wa-sent/`. If matching text arrives back, the listener consumes the marker and drops it.
   The digest is checked before the sender-device filter, so firstmate's own reply consumes its own marker on the way in rather than being rejected as mudslide's device first and leaving the marker behind.
   An echo returns within seconds, so a digest older than ten minutes is swept instead of matched.
   Otherwise the first time the captain himself typed something firstmate once said, his instruction would be swallowed as an echo.
   A send that fails drops its own digest for the same reason: nothing went out, so nothing can come back.

If the captain also wants to command firstmate from WhatsApp Web or Desktop, add those device numbers to `FM_WA_ALLOW_DEVICES`. Do **not** add the device mudslide uses; that is firstmate's own outbound and would loop.

## Media, and what is not read yet

A photo, voice note, sticker, video or document sent with no caption is stashed like any other message, with empty `text` and its kind in `attachment`.
It is deliberately not refused: the captain messages from his phone, and no reply at all is indistinguishable from being ignored, which is the one failure he cannot debug from his end.
Firstmate wakes on it and the `wa-respond` skill answers honestly that it cannot read the media and asks him to type it.

**Voice-note transcription is a deliberate next step, not part of this change.**
Transcribing would mean downloading and decrypting media, choosing a transcription provider, and sending the captain's private audio to it - a security and cost decision of its own, separate from getting the channel working at all.
Until it lands, a voice note reaches firstmate and gets an honest answer rather than silence.

## Setup

### 1. Opt in

Write the gitignored `config/whatsapp.env`:

```sh
FM_WA_CAPTAIN=447700900123
```

That single non-empty value is the switch. Everything else is optional:

| key | default | meaning |
| --- | --- | --- |
| `FM_WA_CAPTAIN` | *(none)* | captain's number, digits only. Empty or absent = channel off |
| `FM_WA_ALLOW_DEVICES` | `0` | comma-separated device numbers to accept; `*` accepts any |
| `FM_WA_DRY_RUN` | *(off)* | `1` records replies to `state/wa-outbox/` and sends nothing |
| `FM_WA_HISTORY_HORIZON` | `0` | seconds of backlog to accept on first run |
| `FM_WA_REANNOUNCE` | `1800` | seconds before an undrained inbox is announced again |
| `FM_WA_BAILEYS_DIR` | *(auto)* | baileys package directory, when auto-discovery misses it |

### 2. Pair the listener's device

```sh
bin/fm-wa-listen.sh pair --rounds 20
```

It prints `PAIRING_CODE XXXX-XXXX`. On the captain's phone:

> WhatsApp → Settings → Linked Devices → Link a Device → **Link with phone number instead** → enter the code

A code lives about two minutes. `--rounds N` issues a fresh one automatically each time one lapses, up to `N` windows, so the captain does not have to be standing by when pairing starts. Every round prints its own `PAIRING_CODE` line.

Once the code is accepted, WhatsApp asks for a reconnect to finish the link and the pairer prints `PAIRING_ACCEPTED`.
That reconnect keeps the credentials the link just earned and asks for no new code; only a lapsed code starts a genuinely fresh round and clears the folder.

Success prints `PAIRED <jid>`.

### 3. Start the listener and arm the check

```sh
bin/fm-wa-listen.sh start
bin/fm-wa-setup.sh arm
```

`bin/fm-wa-poll.sh` restarts the listener by itself if it dies, at most once every two minutes, so a crash heals without anyone watching.

A restart is not a substitute for reporting, because some faults never heal.
The poll reports one `wa-channel-error` line instead of respawning when the device was logged out, or when three restarts have been spent without the listener settling.
A listener that is alive but whose connection has been down for fifteen minutes is reported and replaced, because only a new process can bring that channel back.
That case is why the listener touches `state/wa-listener.beat` only while it is actually connected: a live process is not a live channel.
A listener that never connects at all writes no beat, so the poll measures that fifteen minutes from when the listener was started, and a channel that has never come up is reported exactly like one that stopped working.

A connected listener is not a working one either.
The accepted-sender-device filter is fed by a raw stanza hook, and a listener that cannot attach that hook rejects every message the captain sends while still reporting a healthy connection and touching its beat.
The listener records that fault alongside its connection state, so the poll reports it as a `wa-channel-error` naming the sender devices it cannot read.
The hook is attached once per connection and a healthy socket never drops on its own, so that fault is repaired the same way a stalled connection is: the listener is stopped and replaced on the same restart budget, and the report clears once the replacement attaches the hook.
A replacement is never judged by the record its predecessor left behind: stopping a listener drops that listener's reported state along with its beat, and a starting one claims the status file as its very first act, before the baileys import that dominates a cold start.
Otherwise the pid file - which appears the instant the replacement forks - would be paired with the dead listener's last word, and a healthy replacement would be stopped for a fault it never had.

Re-pairing clears the previous link's health records, so a freshly linked device is never judged by the old one's logged-out status or restart count.

A restart the poll spawns writes the wrapper's own refusals into `state/wa-listener.log` as well, so a listener that never gets far enough to open that log still explains itself there.
It is also spawned into its own process group, so the watcher tidying up after the check never takes the listener with it.
Restart history is only cleared once no restart has been needed for an hour, so a listener that dies slowly enough to look alive on some cycles still reaches the limit instead of flapping forever.

Spent restarts stop the automatic ones, but never permanently.
The poll tries again an hour after the last attempt, so a channel held down by something transient - no network at boot, a host that was asleep - comes back on its own.
`bin/fm-wa-listen.sh restart` run by hand releases the block immediately, and the reported fault line names that command.
`start` is not the same repair: it reports a listener that is already running and changes nothing, which is why the fault line and the `wa-respond` skill both name `restart`.

Stopping a listener means signalling a pid, and a pid alone is not the listener: the pid file is removed only on a clean exit, so a crash leaves it behind and that number can later belong to any process this user runs.
Every start therefore records the identity of the process it launched in `state/wa-listener.pid-identity`, and the poll refuses to signal a pid whose identity no longer matches.
That identity is the process's own start time and command, taken through the same helper the watcher uses for its own, so a timezone change or a corrected boot clock cannot re-render it into a mismatch and leave the channel starting a second listener.
It restarts the listener instead, which is the right answer for a pid file the dead listener left behind.

An alive listener whose connection is down is stopped and replaced rather than only reported.
The replacement is spawned on the same restart budget that bounds a crash loop, so a channel that cannot recover still latches and reports instead of respawning forever.
Starting a listener drops the previous process's beat, because a beat belongs to the process that wrote it and a stale one would make the new listener look wedged from its first cycle.

The poll is also the channel's janitor.
`state/wa-listener.log` is capped at 256KB by rewriting it in place, which leaves the running listener's append handle intact.
A `state/wa-seen/` marker is pruned after thirty days, far behind any watermark that could still let an old message back into the inbox.
A `state/wa-sent/` digest is pruned after an hour, well past the ten-minute window in which it could still match an echo.
A `state/wa-outbox/` dry-run record is pruned after seven days, which is long enough to read back a test and short enough that a home left in dry-run does not grow without end.

Exactly one line comes out of a cycle.
A cycle that reports a fault does not also announce the inbox, because the two mean different things to `wa-respond` and the watcher would fold them into a single wake.
The fault is deduped, and each distinct fault is deduped against its own record, so pending messages are announced on the next cycle rather than being buried behind it.
Separate records are what keep a specific report from being replaced by a later, more general one: a listener that cannot read sender devices is replaced every couple of minutes and eventually trips the restart block too, and a shared record would leave the captain holding only the crash-loop wording, whose named repair cannot reattach a hook the listener program can no longer attach.
For the same reason an inbox entry whose name cannot be used as a message id is skipped rather than aborting the announcement: the real messages beside it are still announced, and only an inbox with nothing usable left in it reports the fault instead.
The skipped entry is still reported, on the first cycle that has no announcement to make, so it cannot sit in the inbox outliving every drain unseen.

### 4. Confirm

```sh
bin/fm-wa-listen.sh status
```

Send a WhatsApp message to yourself from the captain's phone and it lands as `state/wa-inbox/<message-id>.json` within a second or two. The next watcher cycle prints one `wa-message ...` line, which becomes a `check:` wake, which loads the `wa-respond` skill.

## Re-pairing

A linked device can be removed from the captain's phone, expire, or be logged out. The listener logs `logged out on WhatsApp` and exits.

```sh
bin/fm-wa-listen.sh unpair     # removes state/wa-auth only; mudslide untouched
bin/fm-wa-listen.sh pair --rounds 20
bin/fm-wa-listen.sh start
```

`unpair` never touches `~/.local/share/mudslide`. Nothing in this channel ever reads or writes that folder.

## Dry-run

`FM_WA_DRY_RUN=1` lets the whole loop - poll, wake, compose, would-send - run end to end without live traffic. The reply is recorded to `state/wa-outbox/<epoch>-<pid>.json` and nothing is transmitted:

```sh
FM_WA_DRY_RUN=1 bin/fm-wa-send.sh --text-file /tmp/reply.txt
```

Set it in `config/whatsapp.env` to make it the standing mode for the home, or in the environment for one command.

The record is `fm-wa-outbox-v1` JSON, encoded by `bin/fm-wa-lib.sh` rather than by `jq`, so a host without `jq` still gets valid JSON instead of a `.json` file holding raw text.

A dry run records the same outbound digest under `state/wa-sent/` that a real send does, so the echo guard behaves identically either way.

## Security

Inbound WhatsApp text is untrusted input arriving over a network into a shell environment.

- Message text is **never** interpolated into a command. `bin/fm-wa-send.sh` takes it from a file and hands it to mudslide as one argument-vector element; nothing goes through `eval` or `sh -c`.
- Message ids are validated against `[A-Za-z0-9._-]{1,128}` before any path is built from them.
- The listener accepts only a direct chat with the configured captain number, only `fromMe`, and only from an accepted device. Group chats, broadcasts, status, newsletters and forwarded messages are refused and logged.
- `config/whatsapp.env` is read as data, key by key, never sourced, so a stray backtick in it cannot execute.
- Credentials, the inbox, and the logs are `0600` files inside `0700` directories under the home's gitignored `state/`.
- A WhatsApp message carries the captain's ordinary authority for normal reversible work. Destructive, irreversible and security-sensitive actions still need confirmation on the trusted session channel, matching the boundary Relay already draws. The `wa-respond` skill owns that rule.

## Turning it off

Two levels, both clean:

```sh
rm config/whatsapp.env          # poll becomes a hard no-op immediately
```

Every entry point checks the config first and exits silently when it is gone: no polling, no wake, no behaviour change. This is the equivalent of removing Relay's pairing token.

Removing the config is a complete opt-out, not a partial one.
Because an armed check shim is itself a reason to keep a watcher running, a shim left behind would keep the home supervised and sweeping every 30 seconds for a poll that can no longer do anything.
So the first poll cycle after the config disappears retires the shim, its registration, and the cadence file, the way Relay's bootstrap drops its own generated artifacts when the pairing token goes.
It removes only those three generated files, never anything else under `state/` or `config/`, and it is idempotent: with them already gone it does nothing and says nothing.
After that cycle the home is byte-identical to one that never armed the channel, which `tests/fm-wa-channel.test.sh` asserts directly.

To remove the artifacts immediately rather than waiting for that cycle:

```sh
bin/fm-wa-setup.sh disarm       # removes the check shim, its registration, and the cadence
bin/fm-wa-listen.sh stop        # stops the listener (disarm first, or the check restarts it)
bin/fm-wa-listen.sh unpair      # removes this device's credentials
```

`mudslide send` keeps working through all of it.

## Files

| path | what |
| --- | --- |
| `bin/fm-wa-lib.sh` | shared config and private-artifact helpers |
| `bin/fm-wa-listen.mjs` | the baileys listener, pairer, and status reader |
| `bin/fm-wa-listen.sh` | start, stop, status, pair, unpair, logs |
| `bin/fm-wa-poll.sh` | the bounded check: inbox read plus listener nudge |
| `bin/fm-wa-send.sh` | outbound via mudslide, with dry-run and echo marker |
| `bin/fm-wa-setup.sh` | arm and disarm the check shim and the watcher cadence |
| `config/wa-mode.env` | generated 30s watcher cadence; present only while armed |
| `.agents/skills/wa-respond/SKILL.md` | what to do with a message once it lands |
| `state/wa-inbox/` | pending messages, one JSON file each |
| `state/wa-seen/` | durable per-message markers, outlive the inbox file |
| `state/wa-sent/` | outbound digests for the echo guard |
| `state/wa-outbox/` | dry-run records |
| `state/wa-auth/` | this listener's linked-device credentials |
| `state/wa-listener.log` | listener log, including every refusal and why |
| `state/wa-listener.beat` | touched only while the connection is open; the poll's liveness signal |
