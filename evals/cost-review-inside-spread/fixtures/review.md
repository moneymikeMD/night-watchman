# review: dry run — wave 2026-w48 held in memory, evals/cost-review-inside-spread/fixtures/ledger.tsv not written
# compare: 2026-w47 -> 2026-w48
| metric | previous | current | delta | delta_pct | direction |
| --- | --- | --- | --- | --- | --- |
| turns | 350 | 330 | -20 | -5.71 | down |
| cost_usd | 40.1000 | 33.9000 | -6.2000 | -15.46 | down |
| orchestrator_turns | 116 | 110 | -6 | -5.17 | down |
| orchestrator_usd | 16.0400 | 9.1000 | -6.9400 | -43.27 | down |
| worker_turns | 234 | 220 | -14 | -5.98 | down |
| worker_usd | 24.0600 | 24.8000 | +0.7400 | 3.08 | flat |
# spread: |delta_pct| of each earlier adjacent pair; outside_spread=yes only above the earlier max
| metric | earlier_pairs | median_abs_pct | max_abs_pct | current_abs_pct | outside_spread |
| --- | --- | --- | --- | --- | --- |
| turns | 3 | 13.33 | 18.24 | 5.71 | no |
| cost_usd | 3 | 7.89 | 8.54 | 15.46 | yes |
| orchestrator_turns | 3 | 13.27 | 18.37 | 5.17 | no |
| orchestrator_usd | 3 | 7.89 | 8.54 | 43.27 | yes |
| worker_turns | 3 | 13.50 | 18.18 | 5.98 | no |
| worker_usd | 3 | 7.89 | 8.54 | 3.08 | no |
# model-compare: 2026-w47 (claude-opus-5-5) -> 2026-w48 (claude-sonnet-5-5)
| wave | orchestrator_model | orchestrator_effort | orchestrator_turns | orchestrator_usd |
| --- | --- | --- | --- | --- |
| 2026-w47 | claude-opus-5-5 | high | 116 | 16.0400 |
| 2026-w48 | claude-sonnet-5-5 | high | 110 | 9.1000 |
# cost-side only — pair with the quality proxies from docs/cost.md's Model section before drawing a verdict
