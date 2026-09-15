---
id: SPK-1
title: Add health check endpoint
created: 2026-01-05
updated: 2026-01-05
executor: agent
tags:
  - api
blocked_by: []
touches:
  - src/health.py
verify: |
  curl -sf http://example.atlassian.net/health | grep -q ok
---

## Problem

No liveness endpoint exists.

## Solution

Add `/health` returning 200 OK.
