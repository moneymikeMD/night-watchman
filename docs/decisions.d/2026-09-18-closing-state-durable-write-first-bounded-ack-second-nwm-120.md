---
seq: 11
date: 2026-09-18
level: 3
slug: 2026-09-18-closing-state-durable-write-first-bounded-ack-second-nwm-120
title: "closing state: durable write first, bounded ack second (NWM-120)"
---

A worker's exit is a handoff. `land-branch.sh` with `HERDR_ENV=1` writes the
worker's closing state to the tracker and reads it back before it ends the
worker's session, and only then notifies the orchestrator.

**Durable write before orchestrator ack.** An orchestrator can be mid-turn,
compacted or closed, so making it the system of record reproduces the
failure where a durable write never happens. The tracker survives; the pane
message is a courtesy.

**A missing ack degrades, it does not block.** A hung worker must never
block landing. The notification waits `LAND_BRANCH_ACK_WAIT_S` (default 10)
for the ack file it names, and a miss is a warning. A failed durable write
is the opposite case: exit 1, the worker's pane and workspace are left in
place so its output survives, and the landing is not reverted.

**Missing run list is refused early.** A human- or mixed-executor ticket
with no `## Human run list` in the worker's
`.night-watchman/closing-state.md` stops the landing at exit 2 before
anything is mutated, because a promised-but-absent run list is the defect.
Only under `HERDR_ENV=1`; without it the script is unchanged.
