---
title: "memorygraph link rejects SUPERSEDES and RELATES_TO so a memory cannot be superseded by an edge"
heading_raw: "memorygraph link rejects SUPERSEDES and RELATES_TO so a memory cannot be superseded by an edge — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "use CONTRADICTS and name the superseded id in the new memory body"
tickets: ["WO-019"]
slug: memorygraph-link-rejects-supersedes-and-relates-to-so-a-memory-cannot-be-superseded-by-an-edge
---

`memorygraph link` (v0.14.0) accepts SOLVES, CAUSES and CONTRADICTS and
rejects SUPERSEDES and RELATES_TO with
`create relationship failed: Error: Invalid relationship type: <TYPE>` and
a stack trace; neither the error nor `memorygraph link --help` names the
valid set, so a validation failure reads as a backend fault. There is no
SUPERSEDES edge and no validity flag, so a memory cannot be superseded by
an edge.

Workaround: link the new memory to the old one with CONTRADICTS, name the
superseded id in the new memory's body, and read the edge back with
`memorygraph related`; the success line alone is not evidence that
anything persisted. The fix is upstream in memorygraph: a SUPERSEDES type,
or at least a CLI that prints the valid set on a rejected type.
