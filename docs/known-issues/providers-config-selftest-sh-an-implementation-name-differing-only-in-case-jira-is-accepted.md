---
title: "providers/config-selftest.sh: an implementation name differing only in case ('Jira') is accepted"
heading_raw: "providers/config-selftest.sh: an implementation name differing only in case ('Jira') is accepted — LOW"
severity: LOW
status: open
qualifiers: []
note: "pre-existing on main; found while verifying NWM-112, unrelated to it"
tickets: ["NWM-112"]
slug: providers-config-selftest-sh-an-implementation-name-differing-only-in-case-jira-is-accepted
---

Found 2026-09-18 while the NWM-112 worker ran providers/config-selftest.sh to cover its new [dispatch.brief] assertions. One assertion fails, named "implementation name 'Jira' was accepted": the config reader accepts a provider implementation name that differs from the canonical one only by capitalisation, where the selftest expects it to be rejected.

Measured on both sides before filing, so this is not NWM-112's doing: the branch run was 125 of 126 assertions passing with this one failure, and the same script on the main checkout at the time was 122 of 123 with the same failure. The delta between the two counts is exactly the three assertions NWM-112 added, all of which pass.

Not diagnosed further. The open question is which side is wrong — whether implementation names are meant to be case-insensitive (in which case the assertion is stale) or strictly lower-case (in which case the reader needs to reject, and every provider lookup should be audited for the same leniency). Whoever picks this up should answer that first rather than making the assertion pass.
