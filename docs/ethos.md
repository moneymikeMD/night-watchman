# Ethos — how this repo decides

Prune before adding: this table is capped at 10 rows. Before adding a new
row, check whether an existing row already covers it (fix that row's
evidence instead) or whether a row has gone stale and can be cut. A row
with no repo evidence does not belong here.

A profile of this project's decision preferences, built only from what has
actually happened in this repo's own history. The point is to ask fewer
questions over time: before asking a question this table plausibly already
answers, check here; if a default below covers the decision, apply it, say
which default you applied, and move on without asking.

Every entry cites the commit, ticket, or fixture it was inferred from. When
a new answer contradicts an existing default, the default is wrong — fix
it in place, don't bolt an exception onto it.

Before asking a "which approach" or "what should this do" question,
classify it first: if the answer is a fact you could observe by running
something (behavior, timing, output, whether an eval separates), it is not
the owner's to answer — go observe it instead of asking. Reserve questions
for a genuine preference or product call no experiment can settle.
Ported from pstack poteto-mode, 2026-09-14.

## Defaults that can be assumed

| Default | Evidence |
| --- | --- |
| **Ship the smaller, reversible option first.** When two designs solve the same problem, do the smaller/reversible one now and treat the larger option as a follow-up only if the first proves insufficient. | workflow-apply landed as an idempotent `create`-or-update path against an existing `To Do` status rather than a broader migration; merged as-is (`ab2c81d`). 2026-09-12, the script-author eval timed out 4/4 as a build task; owner chose to reshape it into a design-plan case graded on prose rather than raise the budget 4x. |
| **Prove a risky write on a scratch/throwaway target before the real one.** A live API write gets rehearsed against a disposable project first. | `providers/tracker/jira/fixtures/workflows.*.spk4*.txt` and `*.zzprobe*.txt`: workflow-apply's validation and bulkget behavior was captured live against scratch projects SPK4 and ZZPROBE before being trusted against a real workflow. |
| **A validation-endpoint HTTP 200 is not proof of write semantics.** Warnings-only or zero-error validation responses get treated as one step in a sequence, not as confirmation the write did what was intended. | `workflows.update.validation.spk4-warnings-only.txt`: HTTP 200 with six WARNINGs (`NO_INBOUND_TRANSITIONS_TO_STATUS`) was an expected intermediate state, resolved only by a later step — not treated as "done". |
| **A regenerated identifier is not evidence of an unintended change.** When comparing before/after state after a write, diff on the entity's real identity (e.g. `ruleKey` + `parameters`), not incidental ids Jira is free to regenerate. | `4a347ab`: post-write diff false-positived on a regenerated rule `id`; fixed by stripping `id` from rule comparisons since `ruleKey`/`parameters` are the rule's real identity. |
| **Read-only verification never marks a ticket done.** A verify pass that only reads/probes state reports MET/NOT MET/PARTIAL; only a `librarian`-style completion step moves the ticket. | `tickets-protocol` / session-start skill: awaiting-deployment verification is explicitly read-only and forbidden from deploying, restarting, or completing tickets itself. |
| **Prose stays generic; never name the deployment.** Headers, docs and templates say "a production deployment" or "the source project", not the repo, host, or stack that happened to be first, because the plugin already serves a homelab, a mobile app, and a local script. | 2026-09-13, owner generalized every adjacent-project mention before the public squash and set the wording rule ("night-watchman works for all things code"). |
| **A `mixed` ticket whose only human step is "run it in a Herdr pane" is `agent` when the wave itself is dispatched through Herdr.** The worker then sits in exactly that pane; flip the executor, clear `human_steps`, comment why, and keep owner approval of the recorded output at review time. | 2026-09-13, `herdr-ticket-start.sh` refused both as `mixed`; owner had approved running the whole backlog unattended, so both were flipped (comments 10343, 10367) and landed after script-reviewer rounds. |
| **Extract a shared core on a measured fork, or on a universal assumption no repo owns.** Either trigger is enough on its own. One real fork of the same code, not an anticipated one, turns "keep it here" into "split it". So does a contract every consumer already relies on while none owns it; that case costs more than duplication, because nothing drifts visibly — the thing simply is not there. Absent both triggers, the extraction is speculative work. | 2026-09-19, NWM-127: `land-branch.sh` splits because `~/code/homelab/scripts/dev/land-branch.sh` measurably exists as a 1402-line fork carrying the same classes of fix independently. Owner confirmed the split; filed as NWM-131. Second trigger, same day: the ticket contract extracts to `work-order` although no second copy exists, because five repos assume a tracker, tickets and a sprint and no repo owns that assumption. |
| **Generic code moves to the shared repo BEFORE it is changed, not after.** When a ticket would add generic behaviour to a script already on the migration list, migrate first and make the change in its new home. Writing generic code into a private repo to move it a ticket later is rework. | 2026-09-19, owner sequenced NWM-129 (migrate `claude-cost.py`) ahead of NWM-119 (make the ledger model-aware) and the Blocks link was reversed to match. Same mistake NWM-126 was filed to correct for `comment-lint.py`. |
| **Fix the path every other ticket runs through before fixing what that path carries.** When a tooling defect makes landings unreliable, it outranks a deeper defect in the code being landed, because every later ticket pays the tooling cost. | 2026-09-19, owner put NWM-120 (worker closing-state handoff in `land-branch.sh`) ahead of NWM-123 (the guard bypass), after NWM-113's landing died mid-flight on a push timeout and needed hand repair. |
| **Ticket status mirrors the real lifecycle; scripts move it, never hands.** In Progress at dispatch (or when a workspace/pane is opened for it), Awaiting Deployment before landing, Completed after landing. A skipped step is a script defect, not a reason to weaken a tracker gate. | 2026-09-14, the previous-status validator refused the first landing because land-branch jumped In Progress to Completed; owner ruled the validator right and the scripts wrong, cancelled that replacement (which would have relaxed the gate). |

## Still ask

Categories that stay a question regardless of how many defaults exist:

- Anything that deletes data with no backup or undo path.
- Spending money, or opening an account with an external provider.
- Rotating a credential the owner/user manages by hand, where the system
  doing the rotating can't also update the place that credential is used.
- Changing what a system is fundamentally *for* — repurposing a host,
  moving a service's role, anything that changes the answer to "what is
  this thing" rather than "how does this thing work."
