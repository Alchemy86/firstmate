# Host memory

Why a firstmate host can run out of RAM while the fleet is idle, and what to set on a new install.

## The symptom

The desktop shows *"Device memory is nearly full. An application was using a lot of memory and was forced to stop."* Windows die. It happens while firstmate is open, which makes it look like the orchestrator or its agents are leaking, and it happens again minutes later even with no crew running and nothing being typed.

The agent is not the process that dies. Check before assuming:

```
journalctl --since "30 min ago" | grep -i "out of memory"
```

On an affected host the answer was:

```
Out of memory: Killed process 4388 (localsearch-3)
  total-vm:37705468kB, anon-rss:26483384kB
```

`localsearch-3` is GNOME's file indexer, formerly Tracker. It had grown to **26.5 GB resident**. Five minutes earlier it was 323 MB. It is a background daemon, so it respawns within seconds and does it again - which is why the crash repeats when nobody is doing anything.

## Why firstmate provokes it

The indexer is configured to crawl the whole home directory:

```
gsettings get org.freedesktop.Tracker3.Miner.Files index-recursive-directories
['$HOME']
```

It skips any directory containing a `.git`, so a *fresh crawl* of a repo tree reaches almost nothing. That guard is why this looks impossible at first glance, and it is also why it is misleading: **the guard only applies at crawl time.** Files created by `git clone`, `npm install`, `dotnet restore`, and `cargo build` are indexed through inotify as they are written, before any `.git` marker is relevant, and those entries then live in the database permanently.

firstmate is a machine for generating exactly that churn. A working install carries dozens of cloned repos under `projects/`, their `node_modules` and `target/` and `.angular/cache` trees, and a worktree per crewmate under `~/.treehouse`. On one affected host that was 25 GB / 387k files under `projects/` and 368 GB in `~/.treehouse`, and the indexer had accumulated:

```
Currently indexed: 6,680,068 files
~/.cache/tracker3    17 GB
```

It also mis-detects TypeScript declaration files as video. `.d.mts` is guessed as `video/mp2t`, so a video demuxer is started on every one of them - 769 recorded extraction failures, all from `node_modules`.

None of this is firstmate doing something wrong. It is an ordinary developer workload at a scale the desktop indexer does not expect.

## What to set on a new install

Exclude the churn, then reset the database so it stops carrying the stale entries. A `.trackerignore` file makes the indexer skip a directory outright:

```sh
touch ~/.treehouse/.trackerignore    # crewmate worktrees
touch ~/.local/.trackerignore
touch ~/.claude/.trackerignore       # agent transcripts
touch ~/Github/.trackerignore        # or wherever projects/ is cloned

localsearch reset -s                 # pre-rename hosts ship this as tracker3; check `tracker3 reset --help`
```

`localsearch reset -s` erases a rebuildable cache. It costs nothing but the re-crawl.

Ignoring the whole of `~/Github` also stops GNOME search finding your source by content. If you use that, ignore the build output instead of the tree - `node_modules`, `target`, `.angular`, `bin`, `obj` - which is where nearly all of the file count is anyway.

If you never search files from the desktop, skip all of it:

```sh
systemctl --user mask localsearch-3.service
```

## Verifying

Watch the resident size while it re-crawls. It should stay flat; the failure mode is unmistakable because it climbs into the tens of gigabytes.

```sh
watch -n5 'ps -eo rss,comm | grep localsearch-3'
localsearch status
```

Measured on an affected host, before and after:

| | before | after |
| --- | --- | --- |
| `localsearch-3` resident | 26.5 GB, OOM-killed twice | 44 MB, flat under load |
| files indexed | 6,680,068 | 970,974 |
| `~/.cache/tracker3` | 17 GB | 699 MB |

## Agent transcripts

A related, smaller cost. Long-running firstmate sessions produce very large transcripts under `~/.claude/projects/<slug>/`, because the orchestrator turn count is high and tool output is verbose. One session file had reached 260 MB across 78,170 records, with a single 1.9 MB line, and a plain `JSON.parse` of it peaks at 810 MB.

That is not what exhausts the host, but it does make resuming in that directory slow, so archive the big ones periodically:

```sh
du -sh ~/.claude/projects/*/ | sort -rh | head
```
