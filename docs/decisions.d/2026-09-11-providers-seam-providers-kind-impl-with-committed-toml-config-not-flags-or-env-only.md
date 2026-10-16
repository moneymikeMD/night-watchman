---
date: 2026-09-11
slug: providers-seam-providers-kind-impl-with-committed-toml-config-not-flags-or-env-only
title: "Providers seam: providers/<kind>/<impl>/ with committed TOML config, not flags or env-only"
---

# Providers seam: providers/<kind>/<impl>/ with committed TOML config, not flags or env-only

## Decision

2026-09-11 grilling: every tool homelab uses ships as a default, pluggable implementation under providers/<kind>/<impl>/ (tracker jira, secrets op+env, dispatch herdr, memory memorygraph) with fixed verb sets. Selection is a committed .night-watchman/config.toml with env override, read by a bash-3.2 TOML reader. Rejected: --impl flags, env-only, a settings.json block.

## Why

Optimise for homelab hardening plus a second adopter (CHR); a pluggable seam lets other tools implement each interface.

## Cost

unrecorded in memory 48d925a1
