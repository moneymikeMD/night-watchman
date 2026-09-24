---
seq: 6
date: 2026-09-18
level: 3
slug: 2026-09-18-known-issues-is-one-file-per-entry-with-a-generated-index
title: "known-issues is one file per entry with a GENERATED index"
---

`docs/known-issues/` holds one markdown file per finding, and
`docs/known-issues.md` is an index rendered from their frontmatter by
ai-toolkit's `known-issue.sh reindex` (resolved through
`scripts/ai-toolkit-root.sh --known-issue`). Neither is hand-maintained as a
pair.

Reasoning: a single hand-edited `known-issues.md` holding both the prose for
every finding and a hand-maintained index table has two failure modes. Two
agents editing different entries collide on the same file. Worse, the index
drifts from the bodies it summarises — a heading gets edited and its index
row does not, or an entry is added and its row never written, so the entry
becomes invisible in the table with no error and nothing to notice it by.

A generated index cannot lose an entry: `reindex` either lists every entry
file or does not run at all, and `lint` fails when `docs/known-issues.md` is
not byte-identical to what `reindex` would produce right now.
