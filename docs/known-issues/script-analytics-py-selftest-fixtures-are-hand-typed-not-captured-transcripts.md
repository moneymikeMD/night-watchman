---
title: "script-analytics.py selftest fixtures are hand-typed, not captured transcripts"
heading_raw: "script-analytics.py selftest fixtures are hand-typed, not captured transcripts — LOW"
severity: LOW
status: open
qualifiers: []
note: "extract path unverified against real Claude Code transcript shapes"
tickets: []
slug: script-analytics-py-selftest-fixtures-are-hand-typed-not-captured-transcripts
---

scripts/script-analytics-selftest.sh builds its JSONL transcript fixture
(author/reviewer/triage subagent shapes, tool_result shapes, resume/rework
text) by hand rather than capturing and redacting a real Claude Code
transcript under scripts/fixtures/. The 19 assertions prove the extractor
agrees with the author's guess about the transcript shape, not that it
agrees with what Claude Code actually emits.

Same gap pre-exists for scripts/fixtures/claude-cost-scan/*.jsonl, so this
is a known repo-wide pattern, not unique to this port.

Fix: capture at least one real script-author and one real script-reviewer
subagent transcript, redact, and save under scripts/fixtures/script-analytics/,
replayed by the selftest instead of (or alongside) the synthetic tree.
