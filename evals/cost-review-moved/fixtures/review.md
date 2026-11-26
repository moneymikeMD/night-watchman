# review: dry run — wave 2026-w48 held in memory, evals/cost-review-moved/fixtures/ledger.tsv not written
# compare: 2026-w47 -> 2026-w48
| metric | previous | current | delta | delta_pct | direction |
| --- | --- | --- | --- | --- | --- |
| turns | 318 | 296 | -22 | -6.92 | down |
| cost_usd | 41.2000 | 31.0000 | -10.2000 | -24.76 | down |
| orchestrator_turns | 106 | 98 | -8 | -7.55 | down |
| orchestrator_usd | 16.4800 | 12.4000 | -4.0800 | -24.76 | down |
| worker_turns | 212 | 198 | -14 | -6.60 | down |
| worker_usd | 24.7200 | 18.6000 | -6.1200 | -24.76 | down |
# spread: |delta_pct| of each earlier adjacent pair; outside_spread=yes only above the earlier max
| metric | earlier_pairs | median_abs_pct | max_abs_pct | current_abs_pct | outside_spread |
| --- | --- | --- | --- | --- | --- |
| turns | 3 | 4.84 | 6.15 | 6.92 | yes |
| cost_usd | 3 | 6.25 | 6.35 | 24.76 | yes |
| orchestrator_turns | 3 | 4.95 | 6.48 | 7.55 | yes |
| orchestrator_usd | 3 | 6.25 | 6.35 | 24.76 | yes |
| worker_turns | 3 | 4.83 | 5.99 | 6.60 | yes |
| worker_usd | 3 | 6.25 | 6.35 | 24.76 | yes |
# model-compare: wave '2026-w48' ran orchestrator_model 'claude-opus-5-5'; no EARLIER wave in evals/cost-review-moved/fixtures/ledger.tsv used a different orchestrator_model — only one model has been measured so far, nothing to compare it against yet
