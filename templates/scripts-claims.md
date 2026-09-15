# Scripts claims — doc claims vs. verified reality

*Template. Copy this into your own repo as `docs/scripts-claims.md`. Delete
this header comment once you do.*

A script's header comment is a claim about what it does, written once at
authoring time. This file is the running record of which claims have
actually been checked against the script's real behavior, and when. A
claim that has never been checked is not wrong, but it is not verified
either — don't let one quietly stand in for the other.

Update the row in place when a script is re-verified or its behavior
changes; never delete a row for a script that still exists, even if the
finding was "claim confirmed" — the check itself, and when it last
happened, is the useful part. A claim that turns out false becomes a
`known-issues` entry (see `tickets-protocol`'s routing table), linked from
the `Reality` column here rather than duplicated.

| Script | Claim (from header) | Verified reality | Checked |
| --- | --- | --- | --- |
| `scripts/known-issue.sh` | `reindex` never runs against a live host — repo-docs only, touches nothing outside `docs/known-issues/` | Confirmed: no network calls, no credential reads in the script | 2026-09-11 |
