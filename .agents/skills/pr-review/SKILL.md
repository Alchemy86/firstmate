---
name: pr-review
description: >-
  Agent-only standard for reviewing a pull request and posting the review.
  Use before reviewing any pull request, ours or someone else's, and before posting review findings.
  Owns what counts as a finding, what is never worth reporting, how our own PRs are reviewed harder than other people's, and the rule that a review is posted on the PR rather than reported into chat.
  The voice a review is written in is not this skill's: it belongs to the home's own captain preferences.
user-invocable: false
metadata:
  internal: true
---

# pr-review

This skill is the single owner of what a firstmate PR review reports and where it goes.
`bin/fm-pr-watch.sh` decides which PRs and comments are worth waking for; this skill decides what to do with one once it has.

Two cases, and the difference between them is the whole point of separating them:

- **Someone else's PR.** They have context we do not, and a wrong finding costs them time.
- **Our own PR.** Nobody else has looked at it yet, and its author is a worker that has just convinced itself it was finished.
  Review our own harder, not softer.

## Report only

- A bug: wrong output, a crash, data loss, or a case the code does not handle.
- A money, security, or privacy fault.
- Behavior that contradicts what the PR says it does.
- Something that breaks another service or a consumer of this code.
- A test that asserts the mock, or that would still pass with the fix reverted.
- A missing test where the change is genuinely risky and an executable contract already exists.

On our own PR, check the PR description against the diff specifically.
A worker writing its own PR body is the most likely place for a claim to outrun the code.

## Never report

- Style, naming, formatting, ordering, or comment wording.
- "Consider extracting", "could be simpler", "might be worth".
- A preference dressed as a finding, or anything you would not stop a release for.
- Anything a linter or the build already covers.

## How to review

Read the diff, and enough of the surrounding code to know whether the finding is real.
State each finding in one or two sentences: what breaks, and the input or state that breaks it.
No preamble and no summary of what the PR does, because the author already knows.

A wrong finding costs more than a missed one: it wastes the author's time and teaches people to ignore us.
When you are uncertain, say so inside the finding or leave it out.

## Where the review goes

Post it on the PR as a GitHub review, with findings as inline comments on the exact lines.
Never post a verdict into chat instead; a review that only exists in a conversation has not been delivered.

- Someone else's PR: approve it when it is clean, and never approve one with an unaddressed fault.
- Our own PR: never approve it.
  A human still has to.
  When it is clean, say so in a comment and leave it there.

Addressing a review comment includes resolving its thread once the change is made; never resolve a thread whose finding still stands.

## Voice

Reviews are posted under the home's own forge account, so they are written in that account holder's voice, not an assistant's.
That voice is a per-home preference and is not stated here: read `data/captain.md` in this home for it, and follow what it says.
If you are not confident enough in a finding to state it plainly in that voice, that is a signal the finding is not solid enough to post.
Check it again or leave it out.
