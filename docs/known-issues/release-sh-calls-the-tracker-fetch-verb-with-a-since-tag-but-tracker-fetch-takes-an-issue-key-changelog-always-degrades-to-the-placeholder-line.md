---
title: "release.sh calls the tracker fetch verb with a since-tag, but tracker fetch takes an issue key — changelog always degrades to the placeholder line"
heading_raw: "release.sh calls the tracker fetch verb with a since-tag, but tracker fetch takes an issue key — changelog always degrades to the placeholder line — MEDIUM"
severity: MEDIUM
status: resolved
resolved: 2026-09-22
qualifiers: []
note: "v0.2.0 was cut with a --tracker-fetch scratch script built by hand; the default path 405s on GET /issue/"
tickets: []
slug: release-sh-calls-the-tracker-fetch-verb-with-a-since-tag-but-tracker-fetch-takes-an-issue-key-changelog-always-degrades-to-the-placeholder-line
---

Found 2026-09-14 cutting v0.2.0. release.sh runs the provider seam's tracker fetch with the last release tag as the argument and expects a JSON array of key, summary, outcome for tickets completed since that tag. The tracker/jira implementation's fetch verb takes one ISSUE KEY and returns one issue; called with an empty tag it issues GET /issue/ and gets HTTP 405. release.sh silences stderr on that call and treats the empty output as no tracker, so the changelog reads '(no tracker configured; add entries by hand)'. Fix options: (a) add a completed-since verb to the tracker contract (JQL status = Completed AND resolutiondate after the tag date, outcome = last comment) and point release.sh at it; (b) have release.sh derive the ticket list from git log subjects '<PREFIX>-nnn:' since the tag and call the existing fetch verb per key for the summary. Either way, surface the fetch failure on stderr instead of silencing it. Until fixed, cut releases with --tracker-fetch pointing at a script that prints the JSON array.

Resolved 2026-09-22 by retirement, not by repair (NWM-124). release.sh is gone: release-please has owned versioning and CHANGELOG.md since 2026-09-18 and has cut v0.8.0 through v1.4.0. The workaround line above is no longer an instruction anyone should follow, which is the point of resolving it — it was the only place in the repo still telling a reader to run the script. Measured while retiring it: the tracker-outcome path never produced a changelog line here. All three releases release.sh actually cut (v0.7.0, v0.7.1, v0.7.2) carry hand-written prose with no ticket key and no cost line, and the placeholder string this entry names appears nowhere in CHANGELOG.md.
