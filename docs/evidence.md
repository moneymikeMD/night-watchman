## Evidence before pitch

This plugin was extracted from a production system that has been measuring
its own cost, so the claims below are measured, not projected.

**A tool-result-filtering hook cut subagent spend on the wave it landed.**
One operating wave ran with a PreToolUse hook in place that filters
subagent tool-result payloads before they reach the calling model, cutting
down redundant context the main thread would otherwise re-read. Comparing
that wave to the one immediately before it, on the same ledger:

| metric | before | after | change |
| --- | --- | --- | --- |
| subagent share of spend | 27.11% | 3.32% | -87.75% relative |
| wave cost | $69.88 | $50.74 | -27.4% |
| wave duration | 3.59h | 2.50h | -30.4% |
| cost per hour | $19.45/h | $20.29/h | +4.3% |

Read that honestly, not triumphantly: cost per hour actually *rose* — the
wave got cheaper only because it got shorter, not because it got cheaper to
run per hour of work. The same wave also shifted much of its work onto
worktree-dispatched worker processes rather than direct main-thread
subagent calls (worker share of spend rose from 47.16% to 72.17%). The
review that produced this comparison flagged its own result, verbatim:
"consistent with the shunt working, but it is also exactly what a wave
with almost no direct subagent fan-out would produce regardless of the
hook." The causal claim was never fully isolated from that confound. The
subagent-share number is real and the direction is the one you'd want; the
attribution is not yet proven, and this README says so instead of quietly
rounding up.

**Status as of 2026-09-11: still not isolated.** Six waves have run since,
and `subagent_pct` has moved between 27% and 70% without settling below the
40% target the source project treats as a clean read (`docs/cost/ledger.tsv`,
`docs/cost/reviews/2026-09-11-{am,early,morning,overnight}.md`). A
`2026-09-11-quiet` wave was deliberately run to get a clean measurement
point — zero diff to the filtering hook itself, checked by
`git log -- scripts/dev/bash-result-shunt.sh` over the window — but its
9-hour ledger window still spanned unrelated script-authorship work landed
in an earlier sprint, so the ticket-load leg of "clean" wasn't met either
(`docs/cost/reviews/2026-09-11-quiet.md`). The 27.11% → 3.32% comparison
above remains the only clean-looking data point on record; it has not been
reproduced since, and this README is not going to claim otherwise until it
is.

**A self-check that can't fail is not a self-check.** A migration script's
"did this work" check once shared the exact heading matcher its write path
used, so it printed `Migration OK` on an entry actually split across a
markdown fence — the check couldn't disagree with the bug it was meant to
catch. That incident is why this plugin ships a **name-the-oracle** rule as a
first-class part of script review; see `agents/script-reviewer.md` item 12
for the full story and the rule.

**A wave trail is evidence of process, not evidence of deploy state.**
`skills/wave-trail/SKILL.md` records what an unattended wave decided and on
what evidence, then audits that record against the run's own transcript.
That shows the wave reasoned the way it claims to have reasoned — it does
not show the target system is in the state the wave believes it is in.
Deploy-state claims still route through the same re-verification this
document already argues for above; a clean wave trail is not a substitute
for running a ticket's `verify` block against the live system.

Ported from pstack show-me-your-work, 2026-09-14.
