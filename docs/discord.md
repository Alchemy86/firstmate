# Discord fleet updates

Optional OUTBOUND-ONLY posting from the firstmate PRIMARY to the captain's Discord server, so fleet outcomes land somewhere glanceable and artefacts render inline.
Inert by construction: with no config file nothing here runs, and because nothing in firstmate ever calls it automatically, an unconfigured home is byte-for-byte unchanged with nothing needing to be gated off.

**Discord is outbound only, and that is a safety boundary rather than a missing feature.**
Telegram remains the only way the captain reaches firstmate ([telegram.md](telegram.md)).
There is deliberately no poller, no long-poll waiter, no Stop hook and no cadence file here.
A second inbound channel would mean two places a captain instruction can arrive, and the one that is not being watched at that moment is the one that loses an instruction.

## Setup

One credential file, outside this repo, one per machine:

```
~/.config/firstmate/discord.env
  DISCORD_BOT_TOKEN=<the bot token from the Discord developer portal>
```

Then create the channels and generate the channel map, once:

```
bin/fm-dc-setup.sh --guild <guild id> --dry-run   # report, change nothing
bin/fm-dc-setup.sh --guild <guild id>             # create what is missing
```

The guild id is an id, not a credential, so it is recorded in the generated map and `--guild` is needed only on the first run.
That keeps `discord.env` credentials-only, which matters because it is the file most likely to be copied between machines by hand.

To create the bot:

1. At [discord.com/developers](https://discord.com/developers/applications), create an application, open **Bot**, and copy the token.
2. Under **OAuth2 > URL Generator**, tick `bot`, choose the permissions it needs (Manage Channels and Send Messages at minimum), open the generated URL, and invite it to the server.
3. Write the token into `~/.config/firstmate/discord.env` and run `bin/fm-dc-setup.sh --guild <id>`.

Never commit this file or its value.
Every script reads it fresh on each call, and none of them prints the token, echoes it into a status line, or writes it to a log.
The generated `config/discord-channels.env` holds channel ids only and is gitignored along with the rest of `config/`.

## What it does

- Posts a fleet outcome as a colour-coded embed whose colour says good-or-bad and whose channel says whether the captain must act.
- Sends an image or a video as a real attachment, which Discord renders inline - films and training montages are the point, not a nicety.
- Groups repeat reports for one work item under a single thread, when asked to.
- Prints the created message id, so a caller can cite exactly what it posted.

## Architecture

| File | Role |
| --- | --- |
| `bin/fm-dc-send.sh` | The only entry point. Resolves the channel from the kind, sizes and refuses oversize attachments, opens or reuses a thread, posts, and prints the message id. Refuses when run from a crew worktree. |
| `bin/fm-dc-embed.py` | Builds the payload and owns the kind table - colour, emoji, and which channel each kind belongs in. Makes no network call. |
| `bin/fm-dc-lib.sh` | Sourced core: config load, the mandatory User-Agent, the bounded authenticated call, the reply parser, channel-name resolution, and the crew guard. |
| `bin/fm-dc-setup.sh` | Converges the server onto a channel layout and generates `config/discord-channels.env`. Idempotent, and never deletes, renames or reorders anything. |

## Kinds: colour, and where each one lands

`bin/fm-dc-embed.py` is the single owner of this table; the rows below are its current contents.

| Kind | Colour | Channel | For |
| --- | --- | --- | --- |
| `ready` | blurple | `#ready` | Work ready for review, with the PR link |
| `blocked` | orange | `#ready` | Stuck, needs the captain |
| `needs-decision` | orange | `#ready` | A decision only the captain can make |
| `broken` | red | `#broken` | A red pipeline, a failed run, a wedged job |
| `landed` | green | `#landed` | Merged and done |
| `milestone` | gold | `#landed` | A result worth remembering |
| `note` | grey | `#landed` | Everything else worth a line |
| `gallery` | purple | `#gallery` | Films, montages, screenshots |

`--channel` overrides the routing for a one-off.

### There is no `progress` kind, and that is the design

The captain's standing rule is that a channel full of noise is one he stops reading.
Routine progress, empty polls, no-change updates and elapsed-time reports therefore have nowhere to land here by construction, rather than depending on whoever is composing the message showing restraint.
That absence is asserted in `tests/fm-dc-send.test.sh`, so re-adding one is a deliberate change to a guarantee and not a convenience.
Progress belongs in a task's own status record, which is what firstmate already reads.

## Upload sizing

The ceiling is a property of the server's boost tier, so `bin/fm-dc-setup.sh` measures it and records `DC_MAX_UPLOAD` in the generated map rather than every call site trusting a constant.

| Boost tier | Attachment ceiling |
| --- | --- |
| 0 (default) | 10MB |
| 2 | 50MB |
| 3 | 100MB |

An oversize file is refused before anything is uploaded, naming the file's size, the server's own limit, and the way out.
A film usually needs a mobile cut to fit: re-encode at 30fps and 720px wide and send that, keeping the 60fps original for local viewing.
Only a still image becomes an embed's inline image; Discord gives a video its own player, so wiring an embed at one would leave a broken image frame above a working video.

## Threads

`--thread <key>` opens a thread for that work item on first use and reuses it afterwards, so a task that reports four times occupies one collapsed line instead of four.
The thread id is cached under `state/discord-threads/`, which is what lets the second report find the first one's thread.
It is opt-in: without `--thread` nothing threads, and the ordinary one-shot post is unaffected.

## Guarantees

### Only firstmate posts

`bin/fm-dc-send.sh` refuses any call made from inside a crew worktree, identified by git's own linked-worktree shape rather than by where the directory happens to live.
This is not a theoretical boundary.
`bin/fm-tg-send.sh` had to be retrofitted with exactly this guard after briefs told crewmates to contact the captain directly and he received messages from them; a second outbound channel would have reopened that hole, so it is closed here from the first commit.

### Unconfigured is inert, but an explicit call is loud

Nothing in firstmate calls this automatically, so an unconfigured home runs none of it.
A direct call with no config still fails non-zero with one line on stderr, because a caller that explicitly asked to post deserves to know its message did not go.
`--if-configured` is the silent form, exiting 0 and printing nothing, for any future automatic path.
A config file that exists but carries no `DISCORD_BOT_TOKEN` is not configuration; it is simply inert, exactly like an absent one.

### Convergence is never destructive

`bin/fm-dc-setup.sh` lists the server's real categories and channels and creates only what is genuinely missing, so a second run is a no-op and a half-finished first run completes cleanly.
It never deletes, renames or reorders anything.
Removing a channel from a layout file does not remove it from the server, because a destructive convergence is one bad layout file away from taking the captain's history with it.

## Three traps already paid for

**Cloudflare 403 `error code: 1010` is not an auth failure.**
Discord sits behind Cloudflare, which rejects any request carrying no `User-Agent` before Discord's own API sees the token.
The reply is a 403 with an HTML body, so it reads exactly like bad credentials and sends you hunting a token that was never the problem.
Every call must carry a UA of the documented form `DiscordBot (<url>, <version>)`, and `fm_dc_api` is the only place that is spelled.

**`curl -F` parses `;` in a field value as the start of a parameter.**
A `payload_json` containing a semicolon is silently cut in half, and Discord answers `Invalid Form Body` (50035) naming neither the field nor the file.
A semicolon in captain-facing prose is completely ordinary - the caption that first hit this was "colour tells you good or bad; the channel tells you whether you must act" - so this is a routine input rather than an edge case.
The payload is therefore written to a private temporary file and passed as `-F name=<file`, which does no such parsing.

**An upload must be declared as well as sent.**
An embed referencing `attachment://<name>` with no matching entry in the payload's `attachments` array is rejected as `Invalid Form Body` (50035), again naming no field.
The file part alone is not enough.

## Server layout

`bin/fm-dc-setup.sh` defaults to the four fleet channels above.
A wider server layout is applied from a file:

```
bin/fm-dc-setup.sh --layout docs/examples/discord-layout.json --dry-run
```

Channel `type` is `text` (default), `voice`, `announcement`, or `forum`.
**Announcement and forum channels require the server to be a Community server**, which is a server-posture change rather than a channel: enabling it adds a rules screen, sets discovery eligibility, and changes default notification behaviour.
It is deliberately not done by any script here.
When the server is not a Community server, `bin/fm-dc-setup.sh` reports and skips those channels by name and creates the rest, instead of failing the whole run or forwarding an opaque API error.

## Rank roles, and what they actually cost

Progressive rank roles - awarded automatically as members take part - are two separate things, priced very differently, and it is worth not conflating them.

- **Role names and thresholds are free.** Any levelling bot that does role rewards can grant a named role at a chosen threshold, so eight custom rank names cost nothing. Role *colours* are free too, so eight visibly distinct ranks are achievable at no cost.
- **Role ICONS are behind Discord's own paywall, not a bot's.** A small badge image beside a member's name is a Level 2 Server Boost perk, which needs 7 boosts. Icons must be 64x64 and under 256kb, and if the server drops below Level 2 the uploaded icons stay but stop displaying.

A **Server Tag** is a different feature again and is often mistaken for a rank badge: it is a 4-character label plus a badge icon, unlocked with 3 boosts, and each member displays at most one at a time by their own choice of which server to represent.
That makes it a server-identity marker rather than a progression rank, so it cannot express a ladder of eight.

Standard anti-farming settings matter more than the bot choice: a per-message XP cooldown (60 seconds is the usual default), a minimum message length, no-XP channels for bot-command and off-topic rooms, and level-up announcements routed to one channel or disabled rather than fired into conversation.

## Not built, deliberately

- **No inbound anything.** See the top of this file.
- **No bootstrap step and no cadence file.** A cadence exists to make polling responsive, and outbound-only polls nothing. Adding a detection line would also mean extending the bootstrap diagnostics contract for no behavioral benefit.
- **No retry loop on a rejection.** A rejected message is a bad request; retrying it cannot help. A transient network failure surfaces as a non-zero exit with the reason.
