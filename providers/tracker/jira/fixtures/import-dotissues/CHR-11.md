---
id: CHR-11
title: Rotate the backup credential
created: 2026-02-01
updated: 2026-02-01
executor: human
tags:
  - security
blocked_by: []
touches: []
verify: |
  op item get "backup-cred" --fields last-rotated | grep 2026-02-01
---

## Problem

The backup credential is past its rotation window.
