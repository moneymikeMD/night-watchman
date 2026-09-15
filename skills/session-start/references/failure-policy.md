# Dispatched-agent failure policy

Referenced from `session-start`'s step 3 ("Fan out startable work"). Two
retries then abandon and replan.

| Failure | Action |
| --- | --- |
| Cap hit / OOM | respawn with smaller scope |
| Network drop | retry as-is |
| Tool error | retry on a different model |
| Unknown | retry once |
| Second failure, any mode | abandon the unit, replan around it |

Ported from pstack orchestrate playbook, 2026-09-14.
