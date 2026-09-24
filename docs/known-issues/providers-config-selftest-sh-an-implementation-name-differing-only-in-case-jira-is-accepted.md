---
title: "providers/config-selftest.sh: an implementation name differing only in case ('Jira') is accepted"
heading_raw: "providers/config-selftest.sh: an implementation name differing only in case ('Jira') is accepted — LOW"
severity: LOW
status: open
qualifiers: []
note: "one assertion; the selftest is quarantined in .github/workflows/ci.yml"
tickets: ["NWM-112"]
slug: providers-config-selftest-sh-an-implementation-name-differing-only-in-case-jira-is-accepted
---

providers/config-selftest.sh fails one of its 126 assertions,
"implementation name 'Jira' was accepted": the config reader accepts a
provider implementation name that differs from the canonical one only by
capitalisation, where the selftest expects a refusal. CI quarantines this
selftest by exact path and re-runs it with continue-on-error.

Open question: are implementation names case-insensitive (the assertion is
wrong) or strictly lower-case (the reader must reject, and every provider
lookup needs the same audit)? Answer that before making the assertion pass.
