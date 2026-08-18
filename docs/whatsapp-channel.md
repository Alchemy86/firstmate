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

One thing differs from Relay by necessity. Relay's poll makes the network call itself; WhatsApp cannot work that way, because a WhatsApp connection takes tens of seconds to establish and re-establish. So `bin/fm-wa-listen.sh` runs one long-lived connection that stashes messages as they arrive, and `bin/fm-wa-poll.sh` is a local directory read that also nudges the listener back up if it died. The poll finishes in about 25 milliseconds, far inside `FM_CHECK_TIMEOUT`.

## The connection constraint, and what was chosen

**baileys allows one live connection per credential folder.** A listener holding mudslide's session fights `mudslide send` for it.

That is not theoretical. A listener pointed at mudslide's own folder at `/home/aaron/.local/share/mudslide` fails with `statusCode 405` on connect and loops reconnecting, and repeated 405 reconnects put the existing pairing at risk.

**This channel takes option (b): a second linked device with its own credential folder.**
WhatsApp permits up to four linked devices. The listener pairs its own, and keeps its credentials in `state/wa-auth/`, which is private to this home and gitignored.

The consequence that matters: **`mudslide send` is never touched.** Arming, disarming, restarting or breaking the listener cannot affect sending, because they do not share a credential folder, a process, or a device registration. Outbound stays exactly where it was.

The cost is one extra pairing, which only the captain can complete, because the code is entered on his phone.

The rejected alternative, option (a) - one process that both listens and sends, with firstmate handing it outbound work through a queue - would need no second pairing, but it puts the working send path behind a process that can crash, and a raw `mudslide send` typed at a shell would still collide with it. A channel addition should not be able to break something that already works.

## Which chat this is

The mudslide device is linked to the captain's own account (`447700900123`), so the channel is his **chat with himself** - "Message yourself" on his phone.
He types there, his linked devices see it, and firstmate's replies land in the same place. No group, no third party, nothing to route.

That does mean everything on this chat is `fromMe`, including firstmate's own replies coming back. Two independent guards stop firstmate reading its own words as new instructions:

1. **Sender device.** WhatsApp numbers devices: the captain's phone is device `0`, mudslide is a linked device, and the listener is another. Only device `0` is accepted by default. baileys drops the device from the message key, so the listener reads it from the raw stanza and correlates by message id.
2. **Outbound digest.** `bin/fm-wa-send.sh` records a digest of every message it sends under `state/wa-sent/`. If matching text arrives back, the listener consumes the marker and drops it.

If the captain also wants to command firstmate from WhatsApp Web or Desktop, add those device numbers to `FM_WA_ALLOW_DEVICES`. Do **not** add the device mudslide uses; that is firstmate's own outbound and would loop.

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

Success prints `PAIRED <jid>`.

### 3. Start the listener and arm the check

```sh
bin/fm-wa-listen.sh start
bin/fm-wa-setup.sh arm
```

`bin/fm-wa-poll.sh` restarts the listener by itself if it dies, at most once every two minutes, so a crash heals without anyone watching.

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

`unpair` never touches `/home/aaron/.local/share/mudslide`. Nothing in this channel ever reads or writes that folder.

## Dry-run

`FM_WA_DRY_RUN=1` lets the whole loop - poll, wake, compose, would-send - run end to end without live traffic. The reply is recorded to `state/wa-outbox/<epoch>-<pid>.json` and nothing is transmitted:

```sh
FM_WA_DRY_RUN=1 bin/fm-wa-send.sh --text-file /tmp/reply.txt
```

Set it in `config/whatsapp.env` to make it the standing mode for the home, or in the environment for one command.

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

To remove the artifacts too:

```sh
bin/fm-wa-setup.sh disarm       # removes the check shim and its registration
bin/fm-wa-listen.sh stop        # stops the listener
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
| `bin/fm-wa-setup.sh` | arm and disarm the check shim |
| `.agents/skills/wa-respond/SKILL.md` | what to do with a message once it lands |
| `state/wa-inbox/` | pending messages, one JSON file each |
| `state/wa-seen/` | durable per-message markers, outlive the inbox file |
| `state/wa-sent/` | outbound digests for the echo guard |
| `state/wa-outbox/` | dry-run records |
| `state/wa-auth/` | this listener's linked-device credentials |
| `state/wa-listener.log` | listener log, including every refusal and why |
