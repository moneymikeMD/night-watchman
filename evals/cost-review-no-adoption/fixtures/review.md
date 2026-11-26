# review: dry run — wave 2026-w48 held in memory, evals/cost-review-no-adoption/fixtures/ledger.tsv not written
# compare: 2026-w47 -> 2026-w48
| metric | previous | current | delta | delta_pct | direction |
| --- | --- | --- | --- | --- | --- |
| turns | 185 | 230 | +45 | 24.32 | up |
| cost_usd | 22.4000 | 27.9000 | +5.5000 | 24.55 | up |
| orchestrator_turns | 46 | 58 | +12 | 26.09 | up |
| orchestrator_usd | 6.7200 | 8.4000 | +1.6800 | 25.00 | up |
| worker_turns | 139 | 172 | +33 | 23.74 | up |
| worker_usd | 15.6800 | 19.5000 | +3.8200 | 24.36 | up |
# spread: |delta_pct| of each earlier adjacent pair; outside_spread=yes only above the earlier max
| metric | earlier_pairs | median_abs_pct | max_abs_pct | current_abs_pct | outside_spread |
| --- | --- | --- | --- | --- | --- |
| turns | 2 | 3.67 | 5.11 | 24.32 | yes |
| cost_usd | 2 | 4.02 | 5.00 | 24.55 | yes |
| orchestrator_turns | 2 | 3.38 | 4.55 | 26.09 | yes |
| orchestrator_usd | 2 | 4.02 | 5.00 | 25.00 | yes |
| worker_turns | 2 | 3.76 | 5.30 | 23.74 | yes |
| worker_usd | 2 | 4.02 | 5.00 | 24.36 | yes |
# model-compare: wave '2026-w48' ran orchestrator_model 'claude-fable-5-2'; no EARLIER wave in evals/cost-review-no-adoption/fixtures/ledger.tsv used a different orchestrator_model — only one model has been measured so far, nothing to compare it against yet
