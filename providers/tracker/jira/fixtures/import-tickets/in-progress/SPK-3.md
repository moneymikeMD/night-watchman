---
id: SPK-3
title: Load-test the health endpoint
created: 2026-01-07
updated: 2026-01-08
executor: agent
tags: []
blocked_by:
  - SPK-1
touches:
  - scripts/loadtest.sh
defer_until: 2026-03-01
verify: |
  scripts/loadtest.sh --target http://example.atlassian.net/health
  # p99 < 50ms
---

## Problem

Endpoint throughput is unknown.

## Solution

Run a short load test and record p99 latency.
