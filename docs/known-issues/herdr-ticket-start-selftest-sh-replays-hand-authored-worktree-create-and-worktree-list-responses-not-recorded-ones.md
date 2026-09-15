---
title: "herdr-ticket-start-selftest.sh replays hand-authored worktree create and worktree list responses, not recorded ones"
heading_raw: "herdr-ticket-start-selftest.sh replays hand-authored worktree create and worktree list responses, not recorded ones — LOW"
severity: LOW
status: resolved
resolved: 2026-09-14
qualifiers: []
note: "found by script-reviewer; predates the ticket that surfaced it. Every other herdr fixture under providers/dispatch/herdr/fixtures/ is recorded. Fix: capture one real herdr worktree create and worktree list response (redacted) and replay those"
tickets: []
slug: herdr-ticket-start-selftest-sh-replays-hand-authored-worktree-create-and-worktree-list-responses-not-recorded-ones
---

2026-09-14. providers/dispatch/herdr/herdr-ticket-start-selftest.sh defines CREATE_FIXTURE_JSON and LIST_FIXTURE_JSON inline as stand-ins (the file says so). Per the fixture rule (recorded, never authored) the selftest can only prove the script matches the author's guess of herdr's JSON shape. The start verb has run live many times, so recording is cheap: run one dispatch start with the herdr calls tee'd, redact, drop into fixtures/, and point the selftest at the files. Not a behaviour bug: every live dispatch this month parsed the real responses correctly.

Resolved 2026-09-14: recorded worktree-create.json and worktree-list.json from a live herdr worktree create/list on a throwaway branch (removed after); herdr-ticket-start-selftest.sh now reads them, rewriting only branch names for its noise cases. Selftest all assertions passed.
