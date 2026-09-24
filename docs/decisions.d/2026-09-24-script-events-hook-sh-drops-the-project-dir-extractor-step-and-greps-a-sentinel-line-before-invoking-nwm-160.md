---
seq: 29
date: 2026-09-24
level: 3
slug: 2026-09-24-script-events-hook-sh-drops-the-project-dir-extractor-step-and-greps-a-sentinel-line-before-invoking-nwm-160
title: "script-events-hook.sh drops the project-dir extractor step and greps a sentinel line before invoking (NWM-160)"
---

Owner decision. The consuming project's own `scripts/script-analytics.py`
is not a candidate in `hooks/script-events-hook.sh`'s chain: this hook is
registered for every installer, so a repo carrying a same-named stranger
would otherwise have it run with the hook's argv. Whatever the chain
resolves is invoked only if the file carries the line
`# script-analytics-extractor-sentinel: v1`, which ai-toolkit's
`script-analytics.py` carries and its selftest asserts. The check is a grep
rather than "`--help` prints a marker", because executing an unknown file to
ask whether it is the extractor is the hazard the check exists to close.
Neither this checkout nor the installed plugin carries an extractor, so the
chain ends at ai-toolkit's for everyone.
