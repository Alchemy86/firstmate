---
name: no-mistakes-supervision
description: >-
  Agent-only procedure for supervising a no-mistakes validation run from the firstmate side.
  Use when a no-mistakes ship reaches validation, on every wake from a task with a no-mistakes run under way, when an ask-user finding returns as needs-decision, and when a current explicit captain instruction completely invalidates work a run is validating.
  This skill is the single owner of the validation trigger, pipeline-ownership boundary, mid-task intent changes, run-state judgement, the ask-user steer, and the abort-and-revalidate supersession sequence.
user-invocable: false
metadata:
  internal: true
---

# no-mistakes-supervision

A no-mistakes run owns its branch and drives its own pipeline.
Everything here exists to keep exactly one owner on that branch and one authoritative validated head.
`AGENTS.md` section 7 owns the delivery path, the merge authority, and the rule that firstmate never invokes `no-mistakes axi respond` for a crew-owned run.

## Starting the run

For a no-mistakes ship, trigger validation on the same worker after its implementation commit, using the harness invocation owned by `harness-adapters`.
The task worker that starts the run drives the pipeline and owns every `no-mistakes axi run` and `no-mistakes axi respond` call through the next gate or outcome.

## Judging where a run is

Judge validation by the currently attributed run step through `bin/fm-crew-state.sh`, not by shell liveness and not by the last status event.

- Running, fixing, or CI states remain working.
- Parked approval or fix-review states require the worker to follow the active gate help.
- Passed or checks-passed is done.
- Failed or cancelled is failed, exactly as `bin/fm-crew-state.sh` prints it.

Only that state line reclassifies an orphaned ci monitor after green checks as held-for-merge done, or a terminal failed record with the daemon unreachable as unknown; never read those from the raw run record.
The worker reports the PR when CI first becomes green rather than waiting for merge monitoring to finish.

## Scope changes while a run is live

When the captain adds or changes an ask mid-task, append the captain's words to that brief's `## Captain's intent` and steer the worker; Firstmate build constraints stay in `## Firstmate spec` or the steer.
`bin/fm-dod-lib.sh` owns the worker-side `--intent` contract.

Once validation starts, route new requirements to follow-up work rather than expanding the current task, unless a new requirement completely invalidates the work being validated.
Three things are not new requirements and stay in the current task even when they touch files not named at intake: the smallest downstream changes that keep already accepted product or engineering behavior correct, behavioral tests where an executable contract exists, and documentation kept accurate.
Corrections required to satisfy already accepted intent are likewise not new requirements.

## Ask-user findings

An ask-user finding returns as `needs-decision`.
Load `ask-user-authority` and either decide or escalate per that skill; the implementation worker never answers its own finding.

Send the same worker one exact decision naming the decision key, step, action, affected finding IDs, instructions where needed, and the exact response command, passing `--resolve-key` so the worker's open decision record closes at answer time.
Require the matching `resolved` event, forbid `--yes`, and require the worker to process every synchronous return until completion or a genuinely new escalation.
Resume fleet supervision immediately after the decision lands.

## Superseding work already inside a run

This applies only when a current, explicit captain instruction completely invalidates the work being validated.
Anything less goes to follow-up work under the scope rules above.
It also applies when a worker has already hand-edited, committed, aborted, or restarted during an active run: that worker has duplicated pipeline ownership, so settle custody with this sequence before it touches the branch again.

Run it on the same worker, in this order.

1. **Abort.** The worker cancels the active run through no-mistakes axi's supported abort command, and confirms through axi status that the run has stopped, before changing any code.
2. **Settle custody.** The worker follows `branch_sync.next_action` from structured axi status.
   Use axi sync's supported guarded recovery only when its code is `recover_custody`.
   Otherwise proceed only when structured status confirms branch ownership is already returned and no recovery is required.
3. **Replace from the right base.** Custody recovery settles branch ownership, not content.
   The worker replaces the obsolete work from the correct pre-invalidation base rather than building on the recovered-but-obsolete head, keeping the obsolete run's own pipeline-fix commits out of what gets validated and shipped.
4. **Validate once.** Once ownership is settled, validate exactly once against that final head, so no obsolete or intermediate head is ever treated as authoritative.

Apart from the single supported abort in step 1, do not hand-edit, commit, restart, or start a second validation run while the obsolete run still owns the branch.
