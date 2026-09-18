---
title: "jira-workflow-apply-selftest 13b: assertion expects the phrase 'project key' but the script says 'PROJECT_KEY'"
heading_raw: "jira-workflow-apply-selftest 13b: assertion expects the phrase 'project key' but the script says 'PROJECT_KEY' — LOW"
severity: LOW
status: open
qualifiers: []
note: "one assertion; pre-existing on main, found while establishing a CI baseline"
tickets: []
slug: jira-workflow-apply-selftest-13b-assertion-expects-the-phrase-project-key-but-the-script-says-project-key
---

Found 2026-09-18 while running every selftest in the repo to establish a baseline before wiring CI. providers/tracker/jira/jira-workflow-apply-selftest.sh fails one assertion, "13b: message names the problem", which greps the script's stderr for the phrase "project key".

The script actually says: `Error: PROJECT_KEY must be A-Z0-9 only (starting with a letter), got 'not-a-key'` (reproduced directly). The refusal itself is correct — a lowercase key is rejected with a non-zero exit, which the neighbouring assertion 13b-rc confirms. Only the phrasing check fails, because the message spells the identifier as the variable name PROJECT_KEY rather than the prose "project key".

Whoever fixes this should decide which side is authoritative rather than making the grep pass mechanically: either the assertion should look for the identifier the script actually prints, or the message should be reworded to read as prose for the human who sees it. The second is the better fix if the error is meant for an operator rather than a caller, and it would need a sweep for the same variable-name-as-prose pattern in the sibling messages.

Nothing else in the suite fails: 30 of the repo's 32 real selftests pass, the other failure being the separately-filed config-selftest case-insensitivity finding.
