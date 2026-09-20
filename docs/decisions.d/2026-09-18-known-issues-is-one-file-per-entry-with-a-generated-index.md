---
seq: 6
date: 2026-09-18
level: 3
slug: 2026-09-18-known-issues-is-one-file-per-entry-with-a-generated-index
title: "known-issues is one file per entry with a GENERATED index"
---

`docs/known-issues/` holds one markdown file per finding, and
`docs/known-issues.md` is an index rendered from their frontmatter by
`scripts/known-issue.sh reindex`. Neither is hand-maintained as a pair.

Reasoning: a single hand-edited `known-issues.md` holding both the prose for
every finding and a hand-maintained index table linking into it has two
failure modes. First, two agents (or two people) editing different entries
collide on the same file. Second, and worse, the index drifts from the bodies
it summarises — a heading gets edited and its index row does not, or an entry
is added and its index row never gets written, so the entry becomes invisible
in the table with no error and nothing to notice it by. One project that ran
this way for a while found its source had a dozen more entries than its index
had rows for — silently.

That silent-invisibility mode is the argument for a generated index over a
hand-maintained one: once the table is derived from the entries themselves
rather than kept in sync by hand, an entry cannot go missing from it —
`reindex` either lists every entry file or it does not run at all. `lint` is
the guard that keeps it that way, failing when `docs/known-issues.md` is not
byte-identical to what `reindex` would produce right now.

Recorded here on 2026-09-18 during a comment audit of `scripts/`; the
reasoning previously lived only as a prose essay in that script's header.
