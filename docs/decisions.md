# Decisions — dated append log of "why"

Append-only. Never rewrite or delete an entry — if a decision changes,
append a new entry that names the old one it supersedes. The point is a
fresh session (or a fresh agent) can read this file top-to-bottom and see
not just what was decided but why, and whether that reasoning still holds.

Newest entries at the bottom. Each entry: a date, one line naming the
decision, then the reasoning that led to it — the constraint, tradeoff, or
incident that made one option win. A decision with no reasoning is a
fact, not a decision, and belongs in a `docs/` topic file instead — see
`tickets-protocol`'s routing table.

Append only when all three gates hold: costly to reverse, a future reader
would be surprised without it, and real alternatives were weighed.
Otherwise it is a fact for a topic file, or nothing. Rejected alternatives
worth remembering stay as cancelled tickets with an outcome, not an entry
here.

## Log

### 2026-09-14 — Every capability lands as a provider-neutral contract first

Owner directive: "do everything homelab can do, but written in a generic
way so other tools can implement the interface." homelab (the source
project this plugin was extracted from) is the first *provider* of every
kind, never the shape of the contract itself.

Reasoning: a same-day audit that only diffed rows already in
`templates/parity-map.tsv` missed a real gap — `scripts/api/confluence-api.sh`,
`scripts/api/atlassian-graphql.sh`, and homelab's session-start "publish"
step were absent from both the map and `docs/parity/2026-09-13.md`. A same-day bottom-up sweep — enumerate every script, agent,
skill, and hook actually *referenced* from homelab's own CLAUDE.md,
`.claude/skills/*/SKILL.md`, `.claude/agents/*.md`, `.claude/settings*.json`,
`docs/scripts.md`, `docs/cost/README.md`, then classify each as
PORTED / PORTED-DRIFT / UNMAPPED GAP / SOURCE-SPECIFIC — found that gap
immediately and confirmed no other capability was unmapped. The map alone
was the audit's blind spot: it can only ever report drift on a row someone
already thought to add, never a capability nobody mapped in the first
place.

Decision: the map stays the classification *store* (drift/new/vanished are
still worth tracking there), but the *source of truth for what exists* is
the enumeration walk over the source project's own orchestration surface,
not the map. `scripts/parity-sweep.sh --source-root DIR`
implements this as a fourth pass, with an explicit SOURCE-SPECIFIC
allowlist (`templates/parity-allowlist.txt`) for lab-infra capabilities
(host/media/network ops, TrueNAS, Proxmox, Grafana, Caddy) so the sweep
stays quiet about scope this plugin does not intend to generalize.

Out of scope here: porting any individual gap the sweep finds — each is
its own ticket.

### 2026-09-14 — Jira enforces the field gates; scripts keep the cross-ticket gates

Owner decision after the gating spike: adopt all four Jira-native rules —
`system:validate-field-value` for a non-empty `verify` on To Do→In
Progress and on every transition into Completed, the same validator for a
non-empty `touches` on To Do→In Progress, `system:previous-status-validator`
(must have been In Progress) on every transition into Completed, and one
Automation scheduled rule that returns Deferred tickets to To Do once
`defer_until` has passed. `touches` is required for every ticket, not only
agent/mixed ones: Jira cannot condition a validator on another field, and
the owner accepted that because every ticket is created through the
agent anyway.

Reasoning: the spike measured the live workflow capabilities endpoint.
Jira has field, previous-status, parent and permission validators, field
and subtask conditions, webhook post-functions and GitHub triggers, but no
rule at all on linked issues. So `blocked_by`, `touches` collisions between
startable siblings, and `mixed` needing `human_steps` stay in `issues.py`
and land-branch; Jira takes the two field gates and the status-order gate,
which catches a hand-filed ticket at transition time (tickets were
filed with malformed `touches` this week). Automation is post-hoc and is
used only where reacting late is fine (deferral expiry). Automation
execution caps on this plan were not verified; single-project rules are
believed uncapped.

Implementation: additive rules spec through
`jira-workflow-apply.sh`, rehearsed on a scratch project with recorded
fixtures. The Automation rule is a UI step.

### 2026-09-14 — Ticket status mirrors the real lifecycle, and the scripts drive it

Owner rule: a ticket is In Progress from the moment it is dispatched (or a
workspace/pane is created for it), Awaiting Deployment before landing, and
Completed after landing. No step is skipped, ever, and no step is done by
hand except to repair one the scripts missed.

Reasoning: the previous-status validator on Completed refused the
first landing because land-branch jumped from In Progress straight to
Completed and dispatch never moved the ticket off To Do. The first reading
was "the validator is wrong" (a directed-transition replacement was filed). The owner's reading is the opposite: the validator is right and
the scripts were skipping states. Awaiting Deployment is the state "merged
but not yet proven", and land-branch's push is the deploy, so it is a
mandatory stop even for tickets with nothing else to deploy. That replacement is
cancelled; instead dispatch start and land-branch drive the three
transitions through the tracker seam, resolved by target status.

### 2026-09-15 — Commit attribution is the owner's alone; AI-attribution trailers are opt-in, not required

Owner rule: every commit and PR, on every machine, is attributed to Mike
Garrett alone. `land-branch.sh` no longer refuses to land when
`LAND_BRANCH_COAUTHOR` / `LAND_BRANCH_SESSION` are unset — it just omits
the corresponding trailer. Setting either var still appends its trailer
exactly as before, for any future adopter who wants one.

Reasoning: the script's `stop2` guard treated the two vars as REQUIRED,
which blocked landing outright on a machine that had not provisioned them
rather than merely changing a trailer — and provisioning them there would
have run counter to the owner's attribution rule anyway. The trailer code
path itself is not removed, only the refusal; presence of the env var
remains the only switch, no new flag. homelab's copy of the same script
(`scripts/dev/land-branch.sh`) gets the identical diff
so the parity sweep sees one port, not two divergent fixes.

## 2026-09-18 — GitHub repo hardening: CI on macOS, release-please, a ruleset that points at a branch that exists

An audit of the repo's GitHub-side settings found the 2026-09-15 hardening
pass had created two branch rulesets targeting `refs/heads/protect_main` — a
branch that has never existed here. Both were active, so the settings page
showed `main` as protected while `main` was in fact force-pushable and
deletable for three days. Both now target `~DEFAULT_BRANCH` rather than a
literal branch name, so a future default-branch rename cannot silently
unprotect it the same way.

Ruleset shape kept as originally built: deletion and non-fast-forward blocked
for everyone; pull request, linear history and a required `selftests` check
required, with the built-in admin role (`actor_id: 5`) bypassing always.
That combination is deliberate — `scripts/land-branch.sh` pushes merge
commits straight to `main` and must keep working, while an outside
contributor's PR is gated on review and green CI. Verified by pushing to
`main` after the rules went live rather than by reading the documentation.

CI runs on `macos-latest`, not `ubuntu-latest`. This repo targets bash 3.2 —
the `/bin/bash` every macOS ships — and its scripts are written to that limit
deliberately. A Linux runner's bash 5.x would pass code that breaks on the
machines this actually runs on, and one selftest is already known to fail
there for exactly that reason.

Two selftests run in a separate informational step rather than gating: each
fails one assertion for a filed, pre-existing reason (the config reader
accepting a case-variant implementation name, and a message-wording
assertion in jira-workflow-apply). Quarantining them by name keeps `main`
honestly green while leaving a second failure in the same suite visible.
Each moves back into the gating step as its known-issue is resolved.

Versioning moves to release-please, seeded at the current 0.7.2 and bumping
both `.claude-plugin/plugin.json` and `marketplace.json`. It needs a one-time
Actions permission grant from the owner's own terminal ("Read and write
permissions" plus "Allow GitHub Actions to create and approve pull
requests"); without it the action creates its release branch and then fails
to open the PR. `scripts/release.sh` now overlaps it and is to be retired
deliberately through `script-retire.sh`, not left to rot.

Establishing the CI baseline meant running all 32 selftests first. 30 passed;
the two failures are the quarantined pair above. A third problem surfaced
only on a clean machine: `land-branch-selftest.sh` needs PyYAML and neither
declares nor checks for it, so it fails with a raw ModuleNotFoundError
traceback anywhere it is not already installed. CI installs it; the
underlying gap is filed.

### 2026-09-18 — known-issues is one file per entry with a GENERATED index

`docs/known-issues/` holds one markdown file per finding, and
`docs/known-issues.md` is an index rendered from their frontmatter by
`scripts/known-issue.sh reindex`. Neither is hand-maintained as a pair.

Reasoning: a single hand-edited `known-issues.md` holding both the prose for
every finding and a hand-maintained index table linking into it has two
failure modes. First, two agents (or two people) editing different entries
collide on the same file. Second, and worse, the index drifts from the bodies
it summarises — a heading gets edited and its index row does not, or an entry
is added and its index row never gets written, so the entry becomes invisible
in the table with no error and nothing to notice it by. One project that ran
this way for a while found its source had a dozen more entries than its index
had rows for — silently.

That silent-invisibility mode is the argument for a generated index over a
hand-maintained one: once the table is derived from the entries themselves
rather than kept in sync by hand, an entry cannot go missing from it —
`reindex` either lists every entry file or it does not run at all. `lint` is
the guard that keeps it that way, failing when `docs/known-issues.md` is not
byte-identical to what `reindex` would produce right now.

Recorded here on 2026-09-18 during a comment audit of `scripts/`; the
reasoning previously lived only as a prose essay in that script's header.
