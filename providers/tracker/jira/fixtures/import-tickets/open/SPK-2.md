---
id: SPK-2
title: Document the health endpoint
created: 2026-01-06
updated: 2026-01-06
executor: agent
tags:
  - api
  - docs
blocked_by:
  - SPK-1
touches:
  - docs/api.md
appends:
  - docs/decisions.md
verify: |
  grep -q '/health' docs/api.md
human_steps: |
  Announce the new endpoint in #api-changes.
---

## Problem

The new endpoint is undocumented.

## Solution

Add a section to docs/api.md.
