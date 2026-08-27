---
name: human-writeups
description: Write technical prose a person would actually want to read - blog posts, project pages, reports, release notes, documentation with an audience. Use before writing or revising any writing meant for a human reader rather than for an agent. Owns the standard for tone, what to include, and the specific failures that make technical writing read like a machine defending its homework.
---

# Human write-ups

Technical writing produced by an agent fails in a characteristic way: it reads
like someone proving they did the work rather than telling you what they found.
This skill is the standard for anything a person will read for pleasure or
information - a blog post, a project page, a report, release notes.

The test for every sentence: **would a person who knows this subject say this
out loud to another person?** If not, cut it or rewrite it.

## The failures that matter most

**1. Showing your working.** The reader does not care how you counted.

> Bad: "Counted from the atlas's own source of truth. AtlasGB ships no images
> of its own, so this chart was built from the data: reading
> `atlases/pokemon-rb/data/atlas.tsv` with Python's `csv.DictReader` and
> tallying the `verify` column with `collections.Counter` gives rom,live 1,419
> · live 1,239 · rom 141..."
>
> Good: "1,419 entries are verified against both the ROM and a live run. A
> further 1,239 are live-only, 141 ROM-only."

State the finding. The method belongs in the repo, not on the page. The one
exception is when the method **is** the story - "we proved it by running it,
not by reading it" is worth a sentence, because it is the interesting part.

**2. Meta-commentary about the writing itself.** Never describe your own
editorial decisions.

> Bad: "Two figures that used to sit on the project's own front page are out of
> date and are marked as such rather than quietly deleted."

Nobody wants to read about what you chose to delete. Worse, this one points at
a real failure: **a stale number in a repo should be corrected in the repo.**
Do not annotate staleness on a page - go and fix the source, then write the
current number as if it were always the current number.

**3. Defending yourself in the prose.** Hedges, disclaimers and
justifications-in-advance are for a reviewer, not a reader. If a number needs a
condition, give the condition in a few words ("across 3,000 attempts"), not a
paragraph on why you measured it that way.

**4. Throat-clearing.** Delete openings that describe what the page is about
before saying anything. Start with the thing itself.

## Structure

**Project pages lead with what it IS and what it DOES.** Features and current
test scores up front, where someone deciding whether to care can see them.
Nothing else earns that space.

**Stories go in the writing section, one per piece.** The bug that took three
days, the hypothesis that got refuted, the discovery - each is its own post, not
a paragraph on a project page.

If you find yourself writing a narrative on a project page, that is a post
trying to escape. Move it.

## Voice

- Short sentences. Concrete nouns. Active voice.
- Say the interesting thing first. Context after, only what is needed.
- One idea per paragraph.
- Numbers are facts, not decoration - carry the condition that makes a number
  mean something (sample size, which build), and nothing more.
- Never pad to sound thorough. A short true page beats a long careful one.

## Honesty still applies, and is not the same as hedging

Everything published must be true and traceable. But honesty is in **choosing
what to print**, not in wrapping each claim in caveats. If a figure cannot be
stood behind, leave it out and say what is known instead. If something is
unmeasured, one plain sentence says so.

## Before you publish

Read it aloud. Every sentence you would not say to a person, rewrite. Then
check: does any sentence exist to show the reader how hard you worked? Delete it.
