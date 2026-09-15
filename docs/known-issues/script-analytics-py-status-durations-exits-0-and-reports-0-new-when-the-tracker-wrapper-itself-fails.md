---
title: "script-analytics.py status-durations exits 0 and reports '0 new' when the tracker wrapper itself fails"
heading_raw: "script-analytics.py status-durations exits 0 and reports '0 new' when the tracker wrapper itself fails — LOW"
severity: LOW
status: open
qualifiers: []
note: "wrapper failure (no host, bad auth) is swallowed; caller cannot tell 'no transitions' from 'read failed'"
tickets: []
slug: script-analytics-py-status-durations-exits-0-and-reports-0-new-when-the-tracker-wrapper-itself-fails
---

Found 2026-09-14 while verifying a related fix. Running `scripts/script-analytics.py status-durations PROJ-1` with no Jira host configured prints the wrapper's 'Error: no Jira host configured' on stderr, then '# status-durations: 0 new, 0 updated, 0 already present' and exits 0. A cost-reviewer or cron caller reading the exit code sees success and an empty result. Fix: propagate the wrapper's non-zero exit (subprocess returncode) as a non-zero exit from status-durations, and print nothing that looks like a count on that path. Selftest should cover it with a wrapper stub that exits 1.
