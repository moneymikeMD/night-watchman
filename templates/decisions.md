# Decisions — the "why" behind how things are

*Template. Copy this into your own repo as `docs/decisions.md`. Delete this
header comment once you do.*

One entry per decision. An entry states the decision and the reasoning that
still holds, as the current state of the world; a decision that no longer
holds is deleted, not annotated, and its replacement stands on its own. The
point is a fresh session (or a fresh agent) can read this file top-to-bottom
and see not just what was decided but why.

Newest entries at the bottom. Each entry: a date, one line naming the
decision, then the reasoning that led to it — the constraint, tradeoff, or
incident that made one option win. A decision with no reasoning is a
fact, not a decision, and belongs in a `docs/` topic file instead — see
`tickets-protocol`'s routing table.

Add an entry only when all three gates hold: costly to reverse, a future reader
would be surprised without it, and real alternatives were weighed.
Otherwise it is a fact for a topic file, or nothing. Rejected alternatives
worth remembering stay as cancelled tickets with an outcome, not an entry
here.

## Log

### 2026-08-01 — Ship the smaller, reversible option first

Chose a feature-flagged rollout over a full migration for the same
underlying change. The flag was removed within a week once the smaller
version was confirmed sufficient; the full migration was never needed.
Promoted to a standing default in `ethos.md`.
