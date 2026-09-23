---
id: PF-001
title: rename-the-exporter, and a line in the shared decision log
created: 2026-01-01
updated: 2026-01-01
executor: agent
touches:
  - reference/a.py
appends:
  - docs/decisions.md
verify: |
  test -f reference/a.py
---

## Problem

Fixture for `issues.py preflight` and `--landing`. Three tickets that touch
three different files and all append one shared `docs/decisions.md`: benign
under serialized landing, a conflict generator under parallel landing.
