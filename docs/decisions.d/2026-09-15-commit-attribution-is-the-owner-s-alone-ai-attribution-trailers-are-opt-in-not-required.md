---
seq: 4
date: 2026-09-15
level: 3
slug: 2026-09-15-commit-attribution-is-the-owner-s-alone-ai-attribution-trailers-are-opt-in-not-required
title: "Commit attribution is the owner's alone; AI-attribution trailers are opt-in, not required"
---

Owner rule: every commit and PR, on every machine, is attributed to Mike
Garrett alone. `land-branch.sh` no longer refuses to land when
`LAND_BRANCH_COAUTHOR` / `LAND_BRANCH_SESSION` are unset — it just omits
the corresponding trailer. Setting either var still appends its trailer
exactly as before, for any future adopter who wants one.

Reasoning: the script's `stop2` guard treated the two vars as REQUIRED,
which blocked landing outright on a machine that had not provisioned them
rather than merely changing a trailer — and provisioning them there would
have run counter to the owner's attribution rule anyway. The trailer code
path itself is not removed, only the refusal; presence of the env var
remains the only switch, no new flag. homelab's copy of the same script
(`scripts/dev/land-branch.sh`) gets the identical diff
so the parity sweep sees one port, not two divergent fixes.
