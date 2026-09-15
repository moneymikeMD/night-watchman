---
title: "release.sh calls the tracker fetch verb with a since-tag, but tracker fetch takes an issue key — changelog always degrades to the placeholder line"
heading_raw: "release.sh calls the tracker fetch verb with a since-tag, but tracker fetch takes an issue key — changelog always degrades to the placeholder line — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "v0.2.0 was cut with a --tracker-fetch scratch script built by hand; the default path 405s on GET /issue/"
tickets: []
slug: release-sh-calls-the-tracker-fetch-verb-with-a-since-tag-but-tracker-fetch-takes-an-issue-key-changelog-always-degrades-to-the-placeholder-line
---

Found 2026-09-14 cutting v0.2.0. release.sh runs the provider seam's tracker fetch with the last release tag as the argument and expects a JSON array of key, summary, outcome for tickets completed since that tag. The tracker/jira implementation's fetch verb takes one ISSUE KEY and returns one issue; called with an empty tag it issues GET /issue/ and gets HTTP 405. release.sh silences stderr on that call and treats the empty output as no tracker, so the changelog reads '(no tracker configured; add entries by hand)'. Fix options: (a) add a completed-since verb to the tracker contract (JQL status = Completed AND resolutiondate after the tag date, outcome = last comment) and point release.sh at it; (b) have release.sh derive the ticket list from git log subjects '<PREFIX>-nnn:' since the tag and call the existing fetch verb per key for the summary. Either way, surface the fetch failure on stderr instead of silencing it. Until fixed, cut releases with --tracker-fetch pointing at a script that prints the JSON array.
