# Decisions — dated append log of "why"

*Template. Copy this into your own repo as `docs/decisions.md`. Delete this
header comment once you do.*

Append-only. Never rewrite or delete an entry — if a decision changes,
append a new entry that names the old one it supersedes. The point is a
fresh session (or a fresh agent) can read this file top-to-bottom and see
not just what was decided but why, and whether that reasoning still holds.

Newest entries at the bottom. Each entry: a date, one line naming the
decision, then the reasoning that led to it — the constraint, tradeoff, or
incident that made one option win. A decision with no reasoning is a
fact, not a decision, and belongs in a `docs/` topic file instead — see
`tickets-protocol`'s routing table.

Append only when all three gates hold: costly to reverse, a future reader
would be surprised without it, and real alternatives were weighed.
Otherwise it is a fact for a topic file, or nothing. Rejected alternatives
worth remembering stay as cancelled tickets with an outcome, not an entry
here. Adapted from mattpocock/skills domain-modeling, 2026-09-14.

## Log

### 2026-08-01 — Ship the smaller, reversible option first

Chose a feature-flagged rollout over a full migration for the same
underlying change. The flag was removed within a week once the smaller
version was confirmed sufficient; the full migration was never needed.
Promoted to a standing default in `ethos.md`.
