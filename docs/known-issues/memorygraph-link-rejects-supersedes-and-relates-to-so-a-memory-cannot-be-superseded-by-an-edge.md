---
title: "memorygraph link rejects SUPERSEDES and RELATES_TO so a memory cannot be superseded by an edge"
heading_raw: "memorygraph link rejects SUPERSEDES and RELATES_TO so a memory cannot be superseded by an edge — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "Use CONTRADICTS and name the superseded id in the new memory body"
tickets: ["WO-019"]
slug: memorygraph-link-rejects-supersedes-and-relates-to-so-a-memory-cannot-be-superseded-by-an-edge
---

memorygraph link accepts SOLVES, CAUSES and CONTRADICTS, and rejects SUPERSEDES and RELATES_TO. A rejected type prints "Error: Invalid relationship type: <TYPE>" and then "An internal error occurred while performing create relationship" — the second line names no valid set, so a validation failure reads as a backend fault. Confirmed first-hand 2026-09-19 on two different real memory pairs.

This overturns a correction that was already in the graph. Memory 17d16701, written 2026-09-18, claimed a scratch-pair probe accepted every type and that the refusals were incidental. It was wrong; the original worker report carried in docs/handoffs/2026-09-19.md was right. A wrong correction is worse than the error it claims to fix, because it carries the authority of having been checked.

Consequence: the global CLAUDE.md instruction to "supersede the old memory (set its validity)" had no mechanism behind it. There is no SUPERSEDES edge, and link exposes no validity flag.

Workaround, used and read back: link the new memory to the old one with CONTRADICTS, and name the superseded id in the new memory's body so the replacement is legible without traversing the graph. Then read the edge back with memorygraph related — the success line alone is not evidence that anything persisted.

Fix is upstream in the memory-graph project: either a real SUPERSEDES type, or at minimum a CLI that prints the valid set on a rejected type instead of an internal-error line. Out of scope for this entry, which records the behaviour only.

First-hand record: memory 5f8bc0cf. Superseded correction: memory 17d16701.
