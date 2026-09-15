---
title: "issues.py lint accepts a comma-separated single-line touches field in jira mode; scope then reports every changed file UNDECLARED"
heading_raw: "issues.py lint accepts a comma-separated single-line touches field in jira mode; scope then reports every changed file UNDECLARED — LOW"
severity: LOW
status: open
qualifiers: []
note: "an owner-filed ticket had 'a, b, c' on one line; lint 0 errors, spec-review found all 5 files undeclared; fixed by rewriting the field one path per paragraph"
tickets: []
slug: issues-py-lint-accepts-a-comma-separated-single-line-touches-field-in-jira-mode-scope-then-reports-every-changed-file-undeclared
---

2026-09-14. issues.py _lines() splits a Jira textarea custom field on newlines only (one path per paragraph or hardBreak). A touches value written as one comma-separated line parses as a single bogus path, so lint sees a non-empty touches and passes, waves sees no collision, and scope reports every path the branch changed as UNDECLARED. Seen on tickets filed by hand via the Rovo connector, not jira-import.sh. Fix candidates: lint warns on a touches line containing ', ' or a path that does not exist and is not a glob; or _lines additionally splits on commas. Workaround: edit customfield_10043 so each path is its own paragraph.
