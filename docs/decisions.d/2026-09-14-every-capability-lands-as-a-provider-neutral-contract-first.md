---
seq: 1
date: 2026-09-14
level: 3
slug: 2026-09-14-every-capability-lands-as-a-provider-neutral-contract-first
title: "Every capability lands as a provider-neutral contract first"
---

Owner directive: "do everything homelab can do, but written in a generic
way so other tools can implement the interface." homelab, the project this
plugin was extracted from, is the first *provider* of every kind, never the
shape of the contract itself.

Reasoning: a parity audit that only diffs rows already in
`templates/parity-map.tsv` can report drift on a row someone thought to
add, never a capability nobody mapped. A bottom-up walk over the source
project's own orchestration surface (every script, agent, skill and hook
referenced from its CLAUDE.md, skills, agents, settings and docs),
classified as PORTED / PORTED-DRIFT / UNMAPPED GAP / SOURCE-SPECIFIC, is
what finds the unmapped ones.

Decision: the map is the classification *store*; the source of truth for
what exists is the enumeration walk. `scripts/parity-sweep.sh --source-root
DIR` runs it as a fourth pass, with `templates/parity-allowlist.txt` naming
the SOURCE-SPECIFIC lab-infra capabilities (host/media/network ops, TrueNAS,
Proxmox, Grafana, Caddy) this plugin does not generalise. Porting any gap the
sweep finds is its own ticket.
