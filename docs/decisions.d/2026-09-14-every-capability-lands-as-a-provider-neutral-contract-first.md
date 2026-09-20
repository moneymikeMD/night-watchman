---
seq: 1
date: 2026-09-14
level: 3
slug: 2026-09-14-every-capability-lands-as-a-provider-neutral-contract-first
title: "Every capability lands as a provider-neutral contract first"
---

Owner directive: "do everything homelab can do, but written in a generic
way so other tools can implement the interface." homelab (the source
project this plugin was extracted from) is the first *provider* of every
kind, never the shape of the contract itself.

Reasoning: a same-day audit that only diffed rows already in
`templates/parity-map.tsv` missed a real gap — `scripts/api/confluence-api.sh`,
`scripts/api/atlassian-graphql.sh`, and homelab's session-start "publish"
step were absent from both the map and `docs/parity/2026-09-13.md`. A same-day bottom-up sweep — enumerate every script, agent,
skill, and hook actually *referenced* from homelab's own CLAUDE.md,
`.claude/skills/*/SKILL.md`, `.claude/agents/*.md`, `.claude/settings*.json`,
`docs/scripts.md`, `docs/cost/README.md`, then classify each as
PORTED / PORTED-DRIFT / UNMAPPED GAP / SOURCE-SPECIFIC — found that gap
immediately and confirmed no other capability was unmapped. The map alone
was the audit's blind spot: it can only ever report drift on a row someone
already thought to add, never a capability nobody mapped in the first
place.

Decision: the map stays the classification *store* (drift/new/vanished are
still worth tracking there), but the *source of truth for what exists* is
the enumeration walk over the source project's own orchestration surface,
not the map. `scripts/parity-sweep.sh --source-root DIR`
implements this as a fourth pass, with an explicit SOURCE-SPECIFIC
allowlist (`templates/parity-allowlist.txt`) for lab-infra capabilities
(host/media/network ops, TrueNAS, Proxmox, Grafana, Caddy) so the sweep
stays quiet about scope this plugin does not intend to generalize.

Out of scope here: porting any individual gap the sweep finds — each is
its own ticket.
