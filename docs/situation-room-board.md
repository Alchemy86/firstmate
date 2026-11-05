# Situation Room Claude Work board

Firstmate publishes its current work to a shared OpenSearch board that the
Situation Room dashboard renders, and drains the team's written responses back
out of it.
The dashboard is a separate application; this document covers only the
Firstmate half.

The integration ships inert.
A home with no operator config file makes no network call and behaves exactly
as it did before.

## Operator setup

Create `~/.config/fm-situationroom.env`, readable only by you:

```
SR_OPENSEARCH_URL=https://opensearch.example
SR_OPENSEARCH_USER=admin
SR_OPENSEARCH_PASSWORD=...
SR_PUBLISH_HOME=/path/to/the/publishing/firstmate/home
```

`SR_PUBLISH_HOME` names the one home that owns the board.
Secondmate homes share a `$HOME` and therefore share this config file, so
without that pin every home would publish its own backlog and sweep the other
homes' tasks away.
A single-home install may leave it unset.
`SR_WORK_INDEX` and `SR_ANSWERS_INDEX` override the two index names; the
defaults are `situation-room-claude-work` and `situation-room-claude-answers`.

Quote any value containing shell metacharacters.
The file is sourced, so an unquoted password is a syntax error rather than a
login failure.

## The two commands

`bin/fm-situationroom-publish.sh` upserts every live backlog task into the work
index, one document per task id.
Re-running converges rather than duplicating.
A task that leaves the backlog is swept to `state: "done"` rather than deleted,
so the board keeps its history and the dashboard filters it with the state
predicate it already applies to finished work; nothing is ever destructively
removed from a shared index.
`--dry-run` prints the exact documents and makes no network call.

`bin/fm-situationroom-drain.sh` reads undrained responses and routes each one.
A response naming a task that is still an open captain call feeds the one
keyed-answer intake, `bin/fm-captain-hold.sh answers`, which records the
author's exact words.
Anything else - a general note, an unknown task, a call already closed -
becomes a new task held for the captain, so a response is never silently lost.
A document is marked consumed only after its routing succeeded.

Each script's own `--help` and header own its exact flags and mechanics.

## Cadence

Both are wired into `bin/fm-wake-drain.sh` rather than any new daemon.
The answers drain runs at the top of a wake-handling turn, before the queue
lock, so a network call never holds it.
The board publish runs at the end of the acknowledgement step, the point where
fleet state has just finished changing.
Neither hook can change the drain's exit status: supervision must survive an
OpenSearch outage, so a failure is reported loudly and the turn continues.

## Data contract

The dashboard is built against these fields independently, so changing one
breaks the other half.

`situation-room-claude-work`: `id`, `title`, `kind`, `state`, `repo`,
`blockedBy`, `held`, `holdReason`, `holdKind`, `pr`, `priority`, `notes`,
`updatedAt`.

`situation-room-claude-answers`: `id`, `taskId`, `text`, `author`, `createdAt`,
`consumed`.

Two values are derived rather than stored in the backlog.
`state` is `held` when the task carries a hold reason, `blocked` when it has an
unresolved blocker, and otherwise the backlog's own state.
`kind` collapses to `task` for any backlog kind outside the board's four-value
vocabulary.
