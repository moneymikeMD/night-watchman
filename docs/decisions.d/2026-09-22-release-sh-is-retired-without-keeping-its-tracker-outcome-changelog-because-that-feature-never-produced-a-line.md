---
seq: 27
date: 2026-09-22
level: 3
slug: 2026-09-22-release-sh-is-retired-without-keeping-its-tracker-outcome-changelog-because-that-feature-never-produced-a-line
title: "release.sh is retired without keeping its tracker-outcome changelog, because that feature never produced a line"
---

NWM-124 asked, before deleting `scripts/release.sh`, whether the one thing
release-please cannot do — generating a CHANGELOG section from TRACKER
OUTCOMES rather than from Conventional Commit subjects — was worth keeping
as its own smaller tool.

It is not, and the reason is measurement rather than taste.

Three releases were ever cut with release.sh on this repo's history:
`v0.7.0` (48ca184), `v0.7.1` (e995591) and `v0.7.2` (aae4ffc). Every
section they wrote is hand-authored prose. None carries a ticket key, none
carries a `cost:` line, and the placeholder the script falls back to — `(no
tracker configured; add entries by hand)` — appears nowhere in
CHANGELOG.md. The tracker-outcome path produced no changelog line in any of
them. It could not have: the default path called the tracker `fetch` verb
with a since-tag while that verb takes an issue key, got HTTP 405, silenced
the error and degraded (the known issue
`release-sh-calls-the-tracker-fetch-verb-with-a-since-tag-...`).

The `cost:` lines in the pre-0.8.0 sections are not evidence to the
contrary: those sections arrived wholesale in `b765642`, the squashed
initial commit of the public repo, and 41 of the 43 `cost:` lines in the
file read `UNVERIFIED`.

What carries ticket provenance is the commit subject. This repo names the
ticket in the subject — `fix: count Workflow-tool subagent transcripts, not
just Agent-tool ones (NWM-152)` — so release-please's generated sections
already link each entry to its ticket and its commit.

So: no replacement tool, no release-notes fragment generator, nothing kept.
If ticket-outcome prose is wanted later it should be built against a
tracker verb that exists.
