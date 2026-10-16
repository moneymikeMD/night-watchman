---
date: 2026-09-21
slug: a-script-invoked-by-a-plugin-s-own-hook-is-machine-applied-and-stays-in-the-plugin-nwm-129
title: "A script invoked by a plugin's own hook is machine-applied and stays in the plugin (NWM-129)"
---

# A script invoked by a plugin's own hook is machine-applied and stays in the plugin (NWM-129)

## Decision

night-watchman keeps scripts/claude-cost.py and claude-cost-scan.py; nothing moves to ai-toolkit (owner, 2026-09-21). A script called from a hook shipped in a plugin is machine-applied, not repo-consumed, because it fires for installers with no checkout.

## Why

The owner rejected publishing ai-toolkit as a plugin ('slippery slope', changes what the repo is) and vendoring its copies at release time ('an accident waiting to happen', silent drift). The pair is already reduced and dependency-free.

## Cost

NWM-130 is unblocked, NWM-152 becomes night-watchman's, and NWM-119's model-aware ledger lands in night-watchman, reversing the 2026-09-19 sequencing decision.
