---
seq: 26
date: 2026-09-22
level: 3
slug: 2026-09-22-script-analytics-py-and-script-retire-sh-left-for-ai-toolkit-the-hook-resolves-them-and-pins-its-own-price-table-nwm-130
title: "script-analytics.py and script-retire.sh left for ai-toolkit; the hook resolves them and pins its own price table (NWM-130)"
---

The donate half of NWM-125. `script-analytics.py` and `script-retire.sh`
and their selftests live in moneymikeMD/ai-toolkit, consumed here through
`scripts/ai-toolkit-root.sh --script-analytics` and `--script-retire`,
which refuse rather than print a path a stale checkout does not hold.

`hooks/script-events-hook.sh` resolves the extractor through that resolver
as the last step of its chain. Without that step the hook fails open and
goes silently dark — no error, no event, nothing to notice — so it is
proved by observation rather than by reading: with no
`scripts/script-analytics.py` on disk, a SubagentStop payload through the
real hook against a real ai-toolkit checkout writes a real event.

The hook pins `--prices` explicitly, first of `$PROJECT_DIR/templates/`,
`$CLAUDE_PLUGIN_ROOT/templates/`, `../templates/`. The extractor's own
search resolves `<extractor>/../templates/` before
`$CLAUDE_PROJECT_DIR/templates/`, so with the extractor in ai-toolkit a
`claude-prices.tsv` appearing there would shadow this project's table and
produce plausible, wrong numbers. ai-toolkit ships none, which is a
convention, not a guarantee. Proved by planting a 100x decoy in
`ai-toolkit/templates/` against a 10x table in the project: the event
priced at the project's rate.

Running the moved script BY HAND with `$CLAUDE_PROJECT_DIR` unset finds no
price table and exits 2. Pass `--prices templates/claude-prices.tsv` or
export `$CLAUDE_PROJECT_DIR`.
