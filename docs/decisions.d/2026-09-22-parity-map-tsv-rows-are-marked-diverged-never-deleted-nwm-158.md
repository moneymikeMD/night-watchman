---
seq: 25
date: 2026-09-22
level: 3
slug: 2026-09-22-parity-map-tsv-rows-are-marked-diverged-never-deleted-nwm-158
title: "parity-map.tsv rows are marked diverged, never deleted (NWM-158)"
---

A pair that is known not to converge — two files sharing a name that an
owner decision settled as two different programs — gets a third
tab-separated column `diverged:<TICKET>` on its `templates/parity-map.tsv`
row, and `parity-sweep.sh` reports it in its own section, out of `drift` and
out of the exit code.

Deleting the row instead does not work, and this is the part worth
remembering because it is invisible from the map file. `parity-sweep.sh`
registers a row's source path as mapped BEFORE it compares anything, and its
`new` bucket is "files under a mapped source directory with no row at all".
Every path in this map lives under a mapped directory. So a deleted row's
source reappears immediately under `new`, which sets exit 1 exactly as
`drift` does: the false positive moves, it does not go away. Measured
against `../homelab`, not reasoned about.

Three edge cases are decided rather than left to the reader. A marker on a
row whose local column is `-` is a malformed map: `-` already claims the
file was never ported. A marked pair whose local file is MISSING stays in
`drift` and keeps setting exit 1, because deliberately different is not
deliberately absent. A marked pair whose files turn out IDENTICAL is flagged
in the diverged section as a possibly stale marker, visibly but without
changing the exit code — `drift`, `new`, `vanished` and `unmapped` keep the
contract that LAB-228's and NWM-125's verify blocks read.

Four rows carry a marker today: the two claude-cost rows (NWM-129, settled)
and the two rows mapping different homelab selftests onto one
`providers/publish/atlassian/selftest.sh` (NWM-161, an interim — that one is
a gap in the map's format, not a decision). The full 61-row audit found
nothing else. land-branch.sh is NOT marked: NWM-131 splits it behind a hook
contract rather than forking it permanently.
