---
title: "jira-workflow-apply-selftest 13b: assertion expects the phrase 'project key' but the script says 'PROJECT_KEY'"
heading_raw: "jira-workflow-apply-selftest 13b: assertion expects the phrase 'project key' but the script says 'PROJECT_KEY' — LOW"
severity: LOW
status: open
qualifiers: []
note: "one assertion; the selftest is quarantined in .github/workflows/ci.yml"
tickets: []
slug: jira-workflow-apply-selftest-13b-assertion-expects-the-phrase-project-key-but-the-script-says-project-key
---

providers/tracker/jira/jira-workflow-apply-selftest.sh fails one assertion,
"13b: message names the problem", which greps the script's stderr for the
phrase "project key". The script prints `Error: PROJECT_KEY must be A-Z0-9
only (starting with a letter), got 'not-a-key'`; the refusal itself is
correct and 13b-rc confirms the non-zero exit. CI quarantines this selftest
by exact path and re-runs it with continue-on-error.

Open question: is the assertion authoritative (the message should read as
prose for the operator, with a sweep for the same variable-name-as-prose
pattern in sibling messages) or the script (the grep should look for the
identifier it prints)?
