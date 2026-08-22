# Telegram captain-comms

Optional two-way chat between the captain and the firstmate PRIMARY over Telegram, so the captain can read and answer from a phone instead of a terminal.
Inert by construction: with no config file, every script in this file exits cleanly on its first line and nothing about firstmate's behavior changes.

## Setup

One file, outside this repo, one per machine (there is one captain and one bot regardless of how many firstmate homes exist on that machine):

```
~/.config/fm-telegram.env
  TG_TOKEN=<bot token from BotFather>
  TG_CHAT_ID=<the captain's chat id>
```

To create the bot:

1. Message [@BotFather](https://t.me/BotFather) on Telegram, send `/newbot`, and follow its prompts (name, username).
   BotFather returns a token that looks like `123456789:AAbecd...` - that is `TG_TOKEN`.
2. Send the new bot any message from the captain's own Telegram account, so it has something in its update queue.
3. Fetch `https://api.telegram.org/bot<TG_TOKEN>/getUpdates` in a browser or with `curl`, and read `result[0].message.chat.id` - that is `TG_CHAT_ID`.
   (A dedicated ID-lookup bot such as [@userinfobot](https://t.me/userinfobot) works too, but reads the wrong chat if the captain uses it from a different account than the one talking to the firstmate bot.)
4. Write both values into `~/.config/fm-telegram.env`. Nothing else to configure; the next bootstrap picks it up (see "Bootstrap and the watcher" below).

Never commit this file or its values anywhere. `bin/fm-tg-send.sh` and friends read it fresh on every call; no script ever prints `TG_TOKEN` or `TG_CHAT_ID`, and bootstrap's own report line never repeats the chat id back.

### Local privacy of the token and the records

Everything these scripts create under `state/` - the inbox records holding the captain's own words, the poll offset, downloaded media, and the archive log - is written owner-only.
`bin/fm_tg_records.py` applies `umask 077` on import, covering all three Python scripts, and the poller, the waiter and the Stop hook set the same umask before creating any directory - the bound `bin/fm-check-register.sh` puts on its own private records.
Without it those files landed at the ambient umask, which leaves the captain's message bodies world-readable on a default-umask host.

**Known, accepted tradeoff: the bot token appears in process arguments.**
Telegram's Bot API authenticates by putting the token in the request *path* (`https://api.telegram.org/bot<token>/<method>`); it has no header-based scheme, so there is nothing for `curl`'s `--url-query`, `-u`, or an `Authorization` header to carry instead.
Every `curl` call therefore has the token in its argv, readable with `ps auxww` by any other local user for the duration of that call.
This is accepted rather than fixed: it is a property of the vendor API, the exposure is local-only, and the token already sits in a file on the same machine.
A host where other local users are not trusted should not hold `~/.config/fm-telegram.env` at all.

## What it does

- The captain sends the bot a Telegram message at any time, including mid-turn.
- Firstmate's Stop hooks surface it, acknowledge it instantly with a bare `...`, and demand a real reply before the turn is allowed to end quietly.
- Long or multi-thousand-character answers auto-split into a numbered thread; images, documents, and other files send as attachments.
- The captain can send images too; captionless ones still land (with their local path recorded) instead of being silently dropped.

## Architecture

| File | Role |
| --- | --- |
| `bin/fm-tg-send.sh` | Outbound. Auto-splits text over ~3900 chars into a numbered thread; `--file <path> [caption]` sends media. Parses Telegram's JSON reply so a rejection is loud and non-zero instead of a silently-swallowed `curl` success. Refuses when run from a crew worktree. |
| `bin/fm-tg-poll.sh` | Single fetch, run each watcher check cycle via the generated `state/tg-watch.check.sh` shim. Fetches new messages, records them to `state/tg-inbox/<id>.json`, and acknowledges each on arrival. |
| `bin/fm-tg-wait.sh` | Long-poll used by the Stop hook when nothing is already pending; blocks up to `FM_TG_WAIT_MAX` seconds (default 3600, or `FM_TG_HOOK_MAX` when invoked from the hook) for the next message. |
| `bin/fm-tg-fetch.py` | Shared parsing core for the poller and the waiter: turns one Telegram `getUpdates` response into inbox records, fetches media, and fires the arrival-time acknowledgement. One owner of that logic - see "Defect: single-quoted embedded Python" below. |
| `bin/fm-tg-drain.py` | Surfaces every pending message on a Stop hook firing; re-surfaces an unanswered one on every subsequent firing instead of losing it. Fires the `...` ack only as a fallback, when the arrival-time ack did not land. |
| `bin/fm-tg-archive.py` | Retires a message once a real reply has actually been sent (`bin/fm-tg-send.sh` calls it after every non-ack send) - either because it was surfaced, or because it is over 60s old (closes the reply/surface race - see "No message is answered twice" below). |
| `bin/fm-tg-guard.sh` | Stop hook. Refuses to end a turn that surfaced a captain message without a reply having gone out since. |
| `bin/fm-tg-hook.sh` | Stop hook. Drains pending messages; if none, long-polls via `fm-tg-wait.sh`. |
| `bin/fm-tg-hook-lib.sh` | The two Stop hooks' shared block budget - see "A hook can never wedge the session" below. |
| `bin/fm-tg-isfirstmate.sh` | Identity check; exits non-zero for a crewmate session. Defense in depth - see "Only firstmate talks to the captain" below. |

Runtime state - `state/tg-inbox/`, `state/tg-processed/`, `state/tg-media/`, `state/.tg-last-sent`, `state/.tg-last-surfaced`, `state/.tg-offset`, `state/.tg-archive.log`, the `state/.tg-poll-error` refusal record, the two `state/.turnend-tg-*-blocks` budget records, the `state/.tg-hook.lock` single-flight claim, and the generated `state/tg-watch.check.sh` with its `state/tg-watch.check-trust` binding - lives in gitignored `state/`, same as every other task and watcher artifact.
Nothing under this feature is ever tracked in git except the `bin/fm-tg-*` scripts themselves and the two Stop hook registrations in `.claude/settings.json`.

### Bootstrap and the watcher

`bin/fm-bootstrap.sh` detects `~/.config/fm-telegram.env` the same way it detects X mode's `.env` token (`AGENTS.md` section 14): presence-gated, nothing written or printed when unconfigured.
When both `TG_TOKEN` and `TG_CHAT_ID` are set and `curl`/`python3` are available, it writes three idempotent, gitignored artifacts and prints `TELEGRAM: on (chat configured) - ...`:

- `state/tg-watch.check.sh` - a generated shim that `exec`s `bin/fm-tg-poll.sh`; the watcher's own `*.check.sh` sweep (`AGENTS.md` section 8) picks it up with no changes to the watcher itself.
- `state/tg-watch.check-trust` - the shim's byte binding, written by `bin/fm-check-register.sh`. The watcher runs a custom state check only against a current binding; an unregistered shim is never executed at all and is reported as an unauthenticated check on every single cycle instead, so arming and registering are one step (the same contract `bin/fm-tool-update-check.sh arm` follows).
- `config/tg-mode.env` - exports `FM_CHECK_INTERVAL=30`. The default watcher cadence is 300s, which used to leave a captain message unfetched for up to five minutes; source this before arming so a Telegram-configured instance polls every 30s instead, exactly as `config/x-mode.env` does for X mode.

The cadence is wired the same way X mode's is, so it actually takes effect: the Stop-owned auto-arm (`bin/fm-claude-stop-autoarm.sh`) and the Cursor park (`bin/fm-turnend-guard-cursor.sh`) source it before arming, the emitted supervision block names it in its arm command and repair line (`bin/fm-supervision-instructions.sh`), and the arm command policy (`bin/fm-arm-command-policy.mjs`) accepts `source config/tg-mode.env` ahead of an arm as an approved setup node.

On opt-out (config removed, or either value cleared) bootstrap removes all three artifacts and reports `TELEGRAM: off - ...` only when it actually removed something.
If both X mode and Telegram are configured at once, both cadence files export the same `FM_CHECK_INTERVAL=30`, so sourcing both before arming is harmless regardless of order.

The poll also has to finish inside the watcher's per-check bound (`FM_CHECK_TIMEOUT`, default 30s), because a check killed part way through has written neither the inbox record nor the offset and would refetch and re-acknowledge the same update on every following cycle.
`bin/fm-tg-poll.sh` therefore bounds its own `getUpdates` call and hands `bin/fm-tg-fetch.py` an explicit wall-clock budget for the rest; the fetch writes the inbox record and the offset before it acknowledges anything or downloads any media, and skips a media download that no longer fits rather than starting one.
A message whose attachment could not be pulled down in time is still recorded and still surfaces, carrying its Telegram file id.

A refused channel is reported rather than mistaken for a quiet one.
A revoked token (401), a lasting conflict with the Stop hook's own long poll (409), and a sustained rate limit (429) all come back as an error body that `curl` transfers perfectly, so without this they looked exactly like a captain who had not written: no output, no wake, no trace.
`bin/fm-tg-fetch.py` names the refusal on stderr, and the poll prints one `telegram: the channel refused the poll (...)` line carrying Telegram's own reason.
That line is recorded in `state/.tg-poll-error` and reported once per distinct reason, so one standing failure does not wake firstmate every 30 seconds; the next usable poll clears the record, so a recurrence is reported again (the same shape `bin/fm-tool-update-check.sh` uses for `state/.tool-updates`).

### Stop hook registration

The two Stop hooks are registered in this repository's own tracked `.claude/settings.json`, project-scoped rather than in the user's global `~/.claude/settings.json`.
That is the fix for the crew-fan-out defect below; see that section for why it matters and why `bin/fm-tg-isfirstmate.sh` still exists on top of it.

Both entries stand down on a foreign-host payload through `fm_hook_payload_is_foreign_host` in `bin/fm-hook-host-lib.sh`, like every other tracked Claude-shaped entrypoint.
Cursor loads `<project>/.claude/settings.json` as well as its own registration and has no `asyncRewake`, so an unguarded `bin/fm-tg-hook.sh` would run its long poll synchronously inside Cursor's stop step and hold that turn for the whole of `FM_TG_HOOK_MAX` ([turnend-guard.md](turnend-guard.md) "Harness integrations").

Both also check for usable configuration before they touch the filesystem at all.
An ungated `mkdir` in `bin/fm-tg-hook.sh` used to create `state/tg-inbox` and `state/tg-processed` on every turn end of every firstmate primary, including one that had never configured Telegram, which broke this file's opening promise that an unconfigured home is left byte-for-byte unchanged.

## Guarantees

Each of these was a real, captain-visible failure before the fix that now guarantees it cannot recur.

### Only firstmate talks to the captain

**Defect (2026-08-22).** The Stop hooks were registered in the user's *global* `~/.claude/settings.json`, so every Claude Code session on the machine ran them - every crewmate included.
A crew ending a turn would drain the captain's inbox into its own session, answer him directly, and race other sessions (including the real firstmate) for the same message.
That is the direct cause of the captain receiving replies from crewmates, of duplicate answers, and of messages vanishing before firstmate itself ever saw them.

**Fix.** The hooks now live in this repo's tracked, project-scoped `.claude/settings.json`, so only a Claude Code session actually running with this repo as its project loads them at all - a crewmate working on some other project never does.
`bin/fm-tg-isfirstmate.sh` stays in place as defense in depth for the one case project-scoping cannot rule out on its own: a crewmate sent to work on firstmate's own repo checks out this same tracked `.claude/settings.json` inside its own worktree.
It uses the repo's own shared scoping predicate, `fm_primary_scope_matches` in `bin/fm-primary-scope-lib.sh` - the same test `bin/fm-turnend-guard.sh` and `bin/fm-claude-stop-autoarm.sh` scope themselves with - so a linked task worktree is condemned wherever it lives.
An earlier version hand-rolled a process-ancestry grep plus a hardcoded `~/.treehouse/` path test, which declared every worktree outside that one directory (this repo's own validation worktrees included) to be firstmate.
A secondmate home passes the shared predicate but is condemned here too: there is one captain and one bot per machine, and a secondmate reports through the main firstmate rather than to the captain directly.
`bin/fm-tg-send.sh` independently refuses any direct invocation whose working directory is a crew worktree - identified by git's own linked-worktree shape, not by location - so a brief that wrongly tells a crewmate to call it directly still cannot reach the captain.

### No message is lost

**Defect (2026-08-21).** An earlier version archived a captain message the moment it was first printed to the model.
If the harness did not actually surface that print - which happened repeatedly - the message was gone forever with no trace.

**Fix.** `bin/fm-tg-archive.py` retires a message ONLY after a real reply has actually been sent (`bin/fm-tg-send.sh` calls it on every send that is not an ack).
An unanswered message re-surfaces on every subsequent Stop hook firing via `bin/fm-tg-drain.py` instead of disappearing, so a wake the model missed simply tries again next turn.

Every write to a record is also all-or-nothing, through `bin/fm_tg_records.py`.
A record is the only copy of what the captain sent, and a plain truncating write leaves invalid JSON behind if the process dies mid-write - which every reader then skips for ever, while the offset file has already advanced past that update id, so it is never refetched either.
Being killed mid-write is routine here, not hypothetical: the watcher terminates a check's whole process group at `FM_CHECK_TIMEOUT`, and the drain runs inside a Stop hook a turn interrupt can end.
Each update is therefore staged to a sibling temp file and swapped into place, so a record is either its previous contents or its new ones and never a half-written one.

### No message is answered twice

**Defect (2026-08-22).** The fix above's first version retired a message on its *second* surfacing instead of on a real reply, so every captain message was shown to the model twice on the way to being handled - which is what produced the duplicate replies the captain then received.

**Fix.** Retirement is tied only to a real outbound reply (see above), never to a surfacing count.
A message surfaces exactly as many times as it takes to get answered, no more and no fewer.

**Defect (2026-08-22, seen live) - the reply/surface race.** Tying retirement to "surfaced AND replied" has its own race: a reply sent within seconds of a surfacing could find the record still flagged unsurfaced (the drain that sets `surfaced` and the send that triggers `bin/fm-tg-archive.py` run close together), so it was not retired and re-surfaced right afterwards - indistinguishable, to the captain, from the duplicate-reply bug this file exists to end.

**Fix.** `bin/fm-tg-archive.py` retires a message when it has been surfaced, OR when it arrived more than 60 seconds before the reply went out.
A message that old has had every chance to be seen, so the reply is taken to cover it even if `surfaced` never got set in time; that unsurfaced retirement is recorded so it is never invisible.
A message newer than 60 seconds and never surfaced stays pending rather than being silently eaten.
The notice is appended to `state/.tg-archive.log` as well as printed, because the only caller runs the archive as a subprocess whose output it discards - printing alone made the one outcome that can cost the captain an answer completely silent in practice.
Only notices go to that log; routing the archive run's whole stdout there instead recorded every retirement twice and appended a no-op line on every single reply.
The log is trimmed to its last lines once it passes its byte cap, the same bound `state/.watch-triage.log` carries.

Retirement is also bounded.
A retired message moves into `state/tg-processed/` and its attachment stays in `state/tg-media/`, and nothing used to prune either, so every message the captain had ever sent and every image accumulated for the life of the home - the one artifact here with no cap, next to a size-capped log and a recent-history-capped backlog.
`bin/fm-tg-archive.py` keeps the newest 500 retired records and deletes the rest, and deletes a media file once nothing references it - neither a pending inbox record nor a kept retired one - and it is more than a day old, so a download whose record has not been updated with its path yet is never swept.

### The `...` acknowledgement is not a reply

**Defect risk.** Without an explicit signal, the instant `...` acknowledgement firstmate sends the moment a message arrives could itself satisfy "a reply was sent" and let a message be marked answered - and therefore stop re-surfacing - without ever actually being answered.

**Fix.** The ack is sent with `FM_TG_ACK=1`, which `bin/fm-tg-send.sh` checks before it stamps `state/.tg-last-sent` or calls `bin/fm-tg-archive.py`.
An ack alone never satisfies `bin/fm-tg-guard.sh`'s "you surfaced a message and have not sent a reply since" check, and never retires the message it acknowledged.

### The acknowledgement fires on arrival, not at turn end

**Defect (2026-08-22).** The `...` ack originally fired inside `bin/fm-tg-drain.py`, which only runs when firstmate's own turn ends.
During a long turn the captain got silence the whole time and then the `...` arrived alongside the finished answer instead of ahead of it - "i got a `...` at the end of your DELAYED response".

**Fix.** The ack now fires inside `bin/fm-tg-fetch.py`, the moment a message is written to the inbox - whichever of the poller or the long-poll waiter wins the race to fetch it (see "poller/waiter race" below).
The record is marked `acked: 1`; `bin/fm-tg-drain.py` only re-sends the ack as a fallback when that flag is absent, which covers a failed arrival-time send without ever double-acking a healthy one.

### A hook can never wedge the session

**Defect risk.** Both Stop hooks refuse a turn end with a blocking exit until their condition clears - a reply was sent, or nothing is pending.
When the condition *cannot* clear (Telegram unreachable, a revoked token, no network) the model has no way to satisfy either one, so every turn end would re-block for ever.

**Fix.** `bin/fm-tg-hook-lib.sh` gives both hooks the same bounded block budget `bin/fm-turnend-guard.sh` already uses, with one difference that is load-bearing: the budget is keyed on the *condition*, not on the session.
Each block records exactly what it is blocking about - which messages are pending - and any change to that key is progress and resets the count.
Keying the reply guard on the *surfacing time* instead looked equivalent and was not: `bin/fm-tg-drain.py`, the sibling Stop hook that runs on every single turn end, rewrites `state/.tg-last-surfaced` unconditionally, so the key changed every turn, the count reset to 1 every turn, and the guard blocked for ever on a message it could not send a reply for.
Both hooks therefore key on the pending-message set.
A new or newly-answered message therefore always gets a full budget, and only the same unchanged, unanswerable condition ever runs out.
Exhaustion is not permanent silence either: the record is left untouched at that point, so `FM_TG_TURNEND_BLOCK_TTL` (default 3600s) after the last block the same condition may speak up again.
`FM_TG_TURNEND_BLOCK_BUDGET` (default 3) sets the count.

Deliberately not a `stop_hook_active` one-shot allow: `bin/fm-tg-hook.sh` is registered with `asyncRewake`, and Claude Code marks every stop after any stop-hook-driven continuation `stop_hook_active=true` (the incident recorded in [docs/turnend-guard.md](turnend-guard.md)), so honouring that field here would disable both hooks permanently after their first block instead of bounding them.

## Other defects worth knowing about

These do not each map to one of the guarantees above, but explain choices in the code that would otherwise look arbitrary.

- **Silent rejection.** An early version piped `curl` to `/dev/null` and reported "sent" on `curl`'s own exit status, which is 0 whenever the HTTP request merely succeeded - including when Telegram's JSON body said `{"ok": false, ...}"`.
  `bin/fm-tg-send.sh` now parses every reply and exits non-zero with the real error on a rejection.
- **The 4096-character limit.** Telegram's `sendMessage` rejects anything over 4096 characters outright.
  Most detailed firstmate answers exceed that, so they were silently dropped.
  Text is now split on paragraph, then line, then word boundaries and sent as a numbered thread.
- **Captionless media dropped.** An image sent with no caption used to have empty `text`, which the poller treated as "nothing to record" and discarded entirely.
  `fetch_media()` in `bin/fm-tg-fetch.py` downloads it to `state/tg-media/` and records the local path even when there is no caption.
- **Poller/waiter race (2026-08-22).** Two things poll Telegram: the watcher's `state/tg-watch.check.sh` shim, and `bin/fm-tg-wait.sh`'s own long-poll when a Stop hook blocks on it.
  Telegram hands an update to whichever asks first; if the poll shim wins, the message is filed into `state/tg-inbox` and the blocked waiter - the only one of the two that can actually wake the model - keeps waiting for something that has already been taken, for up to `FM_TG_WAIT_MAX` seconds.
  `bin/fm-tg-wait.sh` therefore checks the inbox via `bin/fm-tg-drain.py` on every loop pass, not just the network, so a message filed by the other side is picked up within one pass instead of after a timeout.
- **`mapfile -d` and bash 3.2.** The outbound text splitter read its NUL-delimited chunks with `mapfile -d ''`, which needs bash >= 4.4.
  macOS still ships `/bin/bash` 3.2, where `mapfile` does not exist at all, so the array stayed unset and the very next line aborted under `set -u` - every text send would have failed there.
  It now reads the chunks with a portable `while IFS= read -r -d ''` loop and counts them as they arrive, because `${#PARTS[@]}` on an empty array is itself an unbound-variable error on those shells.
- **Bare `timeout` and macOS.** The poller, the waiter and both send paths bounded their `curl` calls with a bare `timeout`, which macOS does not ship.
  There every send failed before reaching `curl` and reported the misleading `telegram: unparseable reply` of an empty response, the watcher's poll silently never ran, and the waiter's long poll made no network call at all.
  All four now go through `fm_run_timed` from `bin/fm-timeout-lib.sh`, this repo's single owner of bounded execution, which selects `timeout`, `gtimeout`, `perl` or a pure-Bash watchdog per host.
- **The waiter spun when the network was down.** `bin/fm-tg-wait.sh`'s retry paths went straight back to the top of the loop with no delay.
  The happy path self-paces on Telegram's own 50s long poll, but a call that fails instantly - offline, no route, DNS failure, connection refused - does not, and each pass spawns a `python3` drain plus another `curl`.
  An offline machine therefore burned CPU spawning processes for the whole `FM_TG_HOOK_MAX` window on every single turn end.
  Consecutive failures now back off (`FM_TG_WAIT_BACKOFF`, default 2s per consecutive failure, capped by `FM_TG_WAIT_BACKOFF_MAX`, default 60s), and the first successful call resets the count.
- **The waiter also spun when Telegram *answered*.** The backoff above only covered a failed transfer, and `curl` reports an HTTP error body as a completely successful one.
  Telegram returns such a body instantly for conditions this feature genuinely meets: a `409` when two callers share one token (the poll shim and the waiter, by design - see the poller/waiter race above), a `429` rate limit, a `401` for a revoked token.
  Each of those reset the failure count and re-polled with no delay at all, measured at ~16 `curl` + `python3` spawn pairs a second for the whole window.
  A pass is now judged on whether `bin/fm-tg-fetch.py` could *use* the response - it exits `3` for a malformed body or an `{"ok": false}` one - rather than on whether `curl` ran, so any answer that produced nothing backs the loop off.
- **Every Stop firing started its own long poll.** The harness starts a fresh background firing of `bin/fm-tg-hook.sh` on every stop and never deduplicates them, and each firing's long poll lives up to `FM_TG_HOOK_MAX`.
  A session with frequent turns therefore accumulated waiters, all calling `getUpdates` on the one bot token - which is itself what produces the `409` above, so two accumulated waiters terminated each other's long poll in a tight ping-pong.
  The long poll now takes a home-scoped claim (`state/.tg-hook.lock`), the same single-flight shape `bin/fm-claude-stop-autoarm.sh` uses for the same harness contract: at most one waiter per home, and every other firing exits 0 having already surfaced anything pending through the drain that runs before the claim.
- **Message kinds with no text and no recognised file.** `media_file_id()` did not recognise `video_note` (the round clip a phone records with one tap) or `sticker`, so a message carrying only one of those had no text and no file id, advanced the offset, and vanished - no record, no acknowledgement, no trace on disk, and no way to refetch it.
  Both are now recognised media, and any remaining message with no text and no fetchable file is recorded as a placeholder naming what it was (a contact, a location, a poll) rather than dropped.
  An update that carries no message at all - a chat-member change, a poll answer - is still skipped silently: it is not something the captain sent.
- **Single-quoted embedded Python.** Earlier versions of the poller and waiter each embedded a near-identical parsing block as a `python3 -c '...'` single-quoted shell string.
  An apostrophe anywhere in that block - in a code comment, in captain text reflected back into it - broke the enclosing shell script.
  That logic is now the one real file `bin/fm-tg-fetch.py`, imported by argv rather than interpolated into a shell string, shared by both callers.
- **Large images rejected or timed out.** Telegram's `sendPhoto` re-encodes an image and rejects one whose width+height exceeds 10000; a large screenshot or asset atlas failed outright, and a manually scaled-down copy of one still timed out on the upload.
  Both failures surfaced only as `telegram: unparseable reply`, which reads like a corrupt response rather than what actually happened.
  `bin/fm-tg-send.sh --file` now sends anything over 1MB via `sendDocument` instead (original bytes, no re-encoding, a far higher ceiling), and scales the upload timeout with payload size (`180 + size/20000` seconds, capped at 900) instead of a flat 180s, reporting an explicit "upload timed out" when the connection stalls rather than falling through to the JSON parser.

## Upload sizing (`bin/fm-tg-send.sh --file`)

Routing is by extension first, then by size:

| Extension | Method |
| --- | --- |
| `png` `jpg` `jpeg` `webp` at or under 1MB | `sendPhoto` (Telegram-side inline preview, but re-encoded and dimension-limited) |
| `png` `jpg` `jpeg` `webp` over 1MB | `sendDocument` (original bytes preserved, no re-encoding, a far higher ceiling) |
| `mp4` `mov` `m4v` `webm` | `sendVideo` |
| `gif` | `sendAnimation` |
| `mp3` `ogg` `wav` `m4a` | `sendAudio` |
| anything else | `sendDocument` |
- Anything over 50MB is refused before ever calling `curl`, with the file's size reported.
- The upload timeout scales with payload size (`180 + size/20000` seconds, capped at 900s / 15 minutes) instead of a flat value that was too short for a multi-MB upload on a slow connection.

## `fm-tg-digest.sh` was dropped

An earlier, separate script sent a periodic "what's every crew up to" digest to the captain whenever something changed.
It was never wired into the watcher's `*.check.sh` sweep, a cron job, or anything else that would actually run it, so it was dead code with no live behavior.
It did not ship with this productionization; if a periodic fleet digest is wanted, it should be re-added deliberately with real wiring (a `state/*.check.sh` shim, bootstrap-managed like the poll shim above) rather than left as an orphaned script.
