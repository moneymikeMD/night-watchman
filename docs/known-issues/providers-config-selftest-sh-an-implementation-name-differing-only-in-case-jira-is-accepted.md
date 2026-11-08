---
title: "providers/config-selftest.sh: an implementation name differing only in case ('Jira') is accepted"
heading_raw: "providers/config-selftest.sh: an implementation name differing only in case ('Jira') is accepted — LOW"
severity: LOW
status: resolved
resolved: 2026-11-08
qualifiers: []
note: "fixed; the selftest is a gating CI check"
tickets: ["NWM-112"]
slug: providers-config-selftest-sh-an-implementation-name-differing-only-in-case-jira-is-accepted
---

Resolved. providers/config-selftest.sh asserted that an implementation name
differing from a known one only in case ('Jira') is refused, and CI
quarantined it while it failed. Verified 2026-11-08: the suite passes 135/135
on bash 5.3 under LC_ALL=C, en_US.UTF-8 and C.utf8, and the selftest is no
longer quarantined. The refusal comes from nw_valid_impl in
providers/lib/provider.sh, which now spells the lowercase class out
(a-z written as letters) so a non-C locale cannot widen the range to match
uppercase, as bash 3.2 on macOS can. The earlier failure was not reproduced
on this machine with the old range.
