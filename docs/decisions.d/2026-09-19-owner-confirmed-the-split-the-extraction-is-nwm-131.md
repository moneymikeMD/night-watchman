---
seq: 10
date: 2026-09-19
level: 3
slug: 2026-09-19-owner-confirmed-the-split-the-extraction-is-nwm-131
title: "owner confirmed the split; the extraction is NWM-131"
---

The entry above ended "Owner call needed: this recommends the split; it does
not start it." The owner confirmed it on 2026-09-19, so the outcome is final
rather than a recommendation, and the extraction is filed as **NWM-131**
against the five items that entry listed.

Nothing in the analysis changed between the recommendation and the
confirmation. In particular the weighting — "about a third generic, about half
lifecycle" — is still inferred from line ranges rather than measured, and
NWM-131 says so; it should not be treated as a number.

One correction to item 5 of that list. It reads "drop the trailer env vars
(NWM-115) before the move, not after", which reads as though NWM-115 is
outstanding. It is Completed: it made the trailers optional, so unset means no
trailer. But it did not remove them — `LAND_BRANCH_COAUTHOR` and
`LAND_BRANCH_SESSION` still exist at lines 68-71 and 446-449. Dropping them is
therefore inside NWM-131's scope, not a dependency on another ticket.

Sequencing: NWM-131 is blocked by NWM-120, which edits the same two files.
NWM-128, NWM-129 and NWM-130 are unaffected — each moves a different script and
none needs the land-branch core to exist first.
