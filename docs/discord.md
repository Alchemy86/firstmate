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

**A rate-limit reply is an object where a list was expected.**
Discord answers a burst with HTTP 429 and a JSON body carrying `retry_after`.
Code that parses that body as its own success shape reads it as "nothing exists" and duplicates everything it was converging; on the first real layout run this produced four duplicate categories and four duplicate channels before it was caught.
Two independent fixes hold it closed: `fm_dc_api` honours `retry_after` and backs off, and every channel lookup treats an unreadable list as a hard stop rather than as an empty one.
A created channel is now folded into the in-memory list instead of re-fetching the whole list per create, which is what provoked the limit to begin with.

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
**Announcement and forum channels require the server to be a Community server**, which is a server-posture change rather than a channel: enabling it adds a rules screen, raises the verification floor, forces the explicit-content filter on, sets discovery eligibility, and moves default notifications to mentions-only.
Because of that it happens only under the explicit `--enable-community` flag, never as a side effect of converging a layout.
Discord requires a rules channel and a moderator-updates channel to exist first, and requires every prerequisite to be set in the same request as the feature itself; `bin/fm-dc-setup.sh --enable-community` does all of that in one call and is a no-op once the feature is on.
When the server is not a Community server, a layout run reports and skips announcement and forum channels by name and creates the rest, instead of failing the whole run or forwarding an opaque API error.

## Progression badges: the eight gym badges

The ladder lives in [examples/discord-badges.json](examples/discord-badges.json), which is editable data rather than settings buried in a web UI.
Apply it with `bin/fm-dc-setup.sh --badges docs/examples/discord-badges.json`, which creates the roles and syncs their colours, and is a no-op on a second run.

| Badge | Gym | Colour | Level |
| --- | --- | --- | --- |
| Boulder | Pewter City | grey | 3 |
| Cascade | Cerulean City | blue | 7 |
| Thunder | Vermilion City | yellow | 12 |
| Rainbow | Celadon City | green | 18 |
| Soul | Fuchsia City | pink | 25 |
| Marsh | Saffron City | purple | 35 |
| Volcano | Cinnabar Island | red | 50 |
| Earth | Viridian City | teal | 70 |

Every badge role carries an empty permission set on purpose: a badge records what someone did, never what they may do.
Each is hoisted, so holders group together in the member list and the badge is actually visible.

### What is live in that file, and what is only intent

This distinction matters, because half the file is applied and half is not.

- **Live.** `name`, `colour`, and the order of the list. `bin/fm-dc-setup.sh --badges` creates and updates the real Discord roles from them.
- **Intent only.** `level` and everything under `earning_rules`. The levelling bot keeps the XP-to-role mapping in its own dashboard and does not read this file, so each number must be entered there once to take effect.

Keeping both in step is the reason the intent is recorded here at all: without it, the only record of what was meant lives in a web UI that nobody diffs.

### What a level actually costs

The threshold is a **levelling level**, not a message count and not days active.
With Lurkr a member earns a random 15 to 40 XP for a message and then earns nothing for 60 seconds, so the practical unit is **one qualifying message per minute of real conversation**.
Reactions earn nothing, and voice time earns separately only if voice XP is switched on.
A level is a total-XP milestone whose message cost depends on the XP curve preset chosen in the bot, so use the [Lurkr level calculator](https://lurkr.gg/levels/calculator) to convert a level into an expected message count once the curve is set.

### Anti-farming, and why the Fleet channels are locked rather than excluded

`earning_rules.no_xp_channels` records the channels that must earn nothing.
The private Fleet channels are additionally locked so `@everyone` cannot view them at all, which makes "firstmate's automated posts earn no badges" a structural fact rather than a bot setting that can be switched off by accident.
Level-up announcements are recorded as `off`: a promotion notice on every level is the noise that makes a channel unread, and the role appearing beside the name is the reward.

### Turning on the icons later

`icon` is empty on every row because custom role icons are a **Boost Level 2** perk, needing **7 boosts**.
Names and colours work today with no boosts at all, so the ladder is fully functional without spending anything.

To add the images later: drop a 64x64 PNG under 256kb beside the badge file, put its path in that badge's `icon`, and re-run with `--badges`.
No role is recreated and no threshold moves.
Until the server reaches Level 2 the script says so and applies the colours alone, so running it early is harmless.

A **Server Tag** is a different feature that is often mistaken for a rank badge: a 4-character label plus a badge icon, unlocked with 3 boosts, of which each member displays at most one, chosen by which server they want to represent.
That makes it a server-identity marker rather than a progression rank, so it cannot express a ladder of eight.

### The one part that needs the captain

Creating the roles is done.
**Granting them automatically requires a levelling bot, and inviting a third-party bot needs an OAuth authorisation in a browser**, which no API token can perform.
The recommendation is [Lurkr](https://lurkr.gg): message XP, voice XP, leaderboards and role rewards are all on its free tier, where MEE6 paywalls role rewards - the one feature actually needed.
Self-hosting this on the existing bot was considered and rejected: it would mean rebuilding XP tracking, cooldowns, a leaderboard and a dashboard, and it needs a persistent gateway connection that this outbound-only integration deliberately does not have.

## Welcome experience: message, starting role, and auto-role

Discord's built-in join notice - one random line plus a wave button, no custom text, no channel pointers, no role - is the ceiling of what the system channel alone gives a new member.
Getting past it needs two separate things: our own wording posted somewhere a new member actually sees, and a starting role assigned without anyone remembering to do it by hand.

### The welcome message

A one-time post to `#welcome`, not an automated one: there is no cadence file or hook driving it, matching this integration's outbound-only design.
The canonical wording lives in [`examples/discord-welcome-message.md`](examples/discord-welcome-message.md), edited like any other tracked file rather than in a web UI.
Post or refresh it with:

```
bin/fm-dc-send.sh --kind note --channel welcome --plain "$(cat docs/examples/discord-welcome-message.md)"
```

`{{name}}` tokens in that file resolve to clickable channel mentions - `fm-dc-send.sh --text` and `--plain` run any `{{name}}` through the same channel lookup `--channel` uses, so wording can point at a room by name without anyone hand-typing a channel id.
Pin the result in `#welcome` so it survives being pushed down by later join notices; there is no upsert, so updating the wording means unpinning and deleting the old message by hand before posting the new one.

### The starting role

`Trainer` is the floor the eight gym badges promote from, defined in [`examples/discord-starting-role.json`](examples/discord-starting-role.json) with its own colour, distinct from all eight badge colours so it never reads as an earned rank.
Create or sync it with `bin/fm-dc-setup.sh --roles docs/examples/discord-starting-role.json`, the same idempotent role-sync machinery `--badges` uses under a name that fits a role outside the gym-badge ladder.
Its `icon` is empty for the identical Boost Level 2 reason as the badges - see "Turning on the icons later" above.

### Granting it automatically: the decision, and what still needs the captain

Creating the role is not the same as assigning it on join, and Discord gives exactly two ways to do the second part.

**Chosen: Lurkr's own "On Join Roles" feature.**
[Lurkr](https://lurkr.gg/docs/guides/automatically-added-roles-with-timeout) can assign one or more roles to a member automatically after joining, configured entirely in Lurkr's own dashboard and running on Lurkr's own persistent connection - never ours, so this asks nothing new of firstmate's outbound-only architecture or its uptime.
It piggybacks on the Lurkr invite already needed for badge role rewards above rather than adding a second captain-facing dependency.
**This still needs the captain**, in Lurkr's dashboard, after the invite: add `Trainer` as an on-join role, and confirm Lurkr's own role sits above `Trainer` in the role list so it is actually permitted to assign it - Lurkr's invite flow normally places its role near the top already, but it is worth a glance.

**Considered and not built: enabling Community mode for onboarding's default roles.**
Discord's own default-role assignment lives behind Community mode, which is a server-posture change - a rules screen, a raised verification floor, a forced explicit-content filter, discovery eligibility, and mentions-only default notifications - not a channel setting.
`bin/fm-dc-setup.sh --enable-community` already exists and already refuses to run implicitly for exactly this reason; this task does not invoke it, and doing so needs the captain's explicit say-so first.

**Considered and not built: a bot of ours listening for join events.**
That is the same persistent-gateway-connection cost already rejected for self-hosting XP tracking above, for the same reason: this integration is deliberately outbound-only, and a join listener is a process that must stay running, not a one-shot command.
Building it would be a real operational commitment the captain should see before it exists, not after, so it was not built.

**Does any of this need our bot running persistently? No.**
The welcome message is one send.
The role is one idempotent create.
The join-time assignment runs on Lurkr's process, not firstmate's.

## Not built, deliberately

- **No inbound anything.** See the top of this file.
- **No bootstrap step and no cadence file.** A cadence exists to make polling responsive, and outbound-only polls nothing. Adding a detection line would also mean extending the bootstrap diagnostics contract for no behavioral benefit.
- **No retry loop on a rejection.** A rejected message is a bad request; retrying it cannot help. A transient network failure surfaces as a non-zero exit with the reason.
