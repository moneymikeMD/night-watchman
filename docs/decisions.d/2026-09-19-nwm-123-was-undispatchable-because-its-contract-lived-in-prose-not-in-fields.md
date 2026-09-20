---
seq: 8
date: 2026-09-19
level: 3
slug: 2026-09-19-nwm-123-was-undispatchable-because-its-contract-lived-in-prose-not-in-fields
title: "NWM-123 was undispatchable because its contract lived in prose, not in fields"
---

NWM-123 (the guard hook blocks `git` inside an agent's own worktree, and is
bypassable with `/usr/bin/git`) was excluded from `issues.py next` and from
every wave, and could never be dispatched. The cause was not a missing
decision: the ticket's description ended with `verify:` and `executor: agent`
written as prose in the body, while the structured fields those names refer
to were both empty. `issues.py` reads the fields, so the ticket looked
contract-less.

Lifting both into their fields made it startable. This is worth naming as a
failure mode rather than a one-off typo: a ticket captured from a
conversation — here, reported across from homelab LAB-241 — carries its
contract as sentences, and nothing rejects it. `issues.py lint` reported the
project clean while one ticket in it was permanently undispatchable, because
an empty field is not a lint error. The tool-side net that does exist (no
executor means never startable) prevents a bad dispatch but is silent about
the ticket being stranded.

The verify clause was also strengthened while it was open. It now asserts
stderr as well as exit codes, and adds a PATH-shadowing shim case, so the
fix cannot pass by refusing everything — the failure mode a guard fix is
most likely to have.

Sequencing: NWM-113, NWM-123 and NWM-122 all edit `hooks/guard-fs-writes.sh`.
They were chained `113 → 123 → 122` rather than left parallel. NWM-123 is
placed second, ahead of NWM-122's frame-stack refactor decision, because a
guard a subagent can route around is the highest-severity item in the set and
should not wait behind a refactor.
