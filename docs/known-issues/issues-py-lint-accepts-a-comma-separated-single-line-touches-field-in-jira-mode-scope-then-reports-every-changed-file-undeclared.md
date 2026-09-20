---
title: "issues.py lint accepts a comma-separated single-line touches field in jira mode; scope then reports every changed file UNDECLARED"
heading_raw: "issues.py lint accepts a comma-separated single-line touches field in jira mode; scope then reports every changed file UNDECLARED — LOW"
severity: LOW
status: resolved
resolved: 2026-09-19
qualifiers: []
note: "fixed in work-order/reference/issues.py (WO-021): lint rejects a touches item holding two or more comma-separated paths; _lines() is unchanged because it also feeds human_steps, where commas are prose"
tickets: []
slug: issues-py-lint-accepts-a-comma-separated-single-line-touches-field-in-jira-mode-scope-then-reports-every-changed-file-undeclared
---

2026-09-14. issues.py _lines() splits a Jira textarea custom field on newlines only (one path per paragraph or hardBreak). A touches value written as one comma-separated line parses as a single bogus path, so lint sees a non-empty touches and passes, waves sees no collision, and scope reports every path the branch changed as UNDECLARED. Seen on tickets filed by hand via the Rovo connector, not jira-import.sh. Fix candidates: lint warns on a touches line containing ', ' or a path that does not exist and is not a glob; or _lines additionally splits on commas. Workaround: edit customfield_10043 so each path is its own paragraph.

Resolved 2026-09-19 by WO-021, in work-order/reference/issues.py — the reference implementation this file moved to under WO-004, not in night-watchman. night-watchman's own skills/to-issues/scripts/issues.py is still byte-identical to the pre-fix file and still carries this defect; WO-010 deletes it in favour of the work-order dependency.

lint now rejects a `touches` item that is two or more comma-separated PATHS on
one line. _lines() was deliberately left alone rather than made to split on
commas: it also feeds human_steps and appends, where a comma is ordinary prose.

The path-like test — a separator, a glob metacharacter, or a bare filename with
an extension — is what makes this safe. A naive "contains a comma" check was
written first and flagged WO-032's
`~/code/.claude/settings.json (untracked, outside every repo)`, one path with a
parenthetical annotation, turning lint on the live ticket set from 0 errors to 1.
That entry has one path-like piece, not two, so the shipped check leaves it
alone. A touches item that is not a path at all remains unflagged; that is the
other fix candidate this entry listed, and it is out of WO-021's scope.
