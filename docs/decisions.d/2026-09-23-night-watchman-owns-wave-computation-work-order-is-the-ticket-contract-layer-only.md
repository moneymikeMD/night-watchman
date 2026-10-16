---
date: 2026-09-23
slug: night-watchman-owns-wave-computation-work-order-is-the-ticket-contract-layer-only
title: "night-watchman owns wave computation; work-order is the ticket contract layer only"
---

# night-watchman owns wave computation; work-order is the ticket contract layer only

## Decision

Owner decision 2026-09-23: waves, preflight, _plan_waves and _claims belong in night-watchman as the dispatch owner. scripts/waves.py imports work-order's issues.py by path for loading only and duplicates those four functions as its own code, verified byte-identical to work-order v1.6.0 (NWM-174).

## Why

work-order is the ticket contract layer only; dispatch logic belongs to the dispatch owner.

## Cost

Duplicated wave code in two repos until pair ticket WO-73 removes the originals from work-order's issues.py.
