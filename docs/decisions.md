# Decisions — dated append log of "why"

**GENERATED — do not hand-edit.** Produced by `scripts/decisions.sh index`
from the frontmatter and body of every file in `docs/decisions.d/`. Add an
entry with `scripts/decisions.sh add --title T --body B`, which writes the
file there and reindexes for you. `scripts/decisions.sh lint` fails if this
file ever drifts from what `index` would produce.

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

## 2026-09-19 — E6 sequencing: migrate the cost scripts first, then make them model-aware in ai-toolkit

NWM-119 (record the orchestrator's model and effort per wave, so the ledger
shows what Fable costs against Opus-at-high-effort) and NWM-129 (move
`claude-cost.py` and `claude-cost-scan.py` to the public `ai-toolkit`) both
change the same file. Yesterday's handoff flagged the sequencing as unmade
and warned against running them in parallel.

Owner decision: migrate first. NWM-129 lands, and NWM-119's change is then
made in `ai-toolkit` against the migrated script. The `Blocks` link was
reversed to match — NWM-129 now blocks NWM-119, where it previously ran the
other way.

The reasoning is that NWM-119's change is to the generic half. Reading a
transcript's model and effort metadata and splitting spend per model is
something any repo running Claude Code sessions wants; it is not a
night-watchman feature. Doing it here first would mean writing generic code
into a private repo and then moving it a ticket later, which is the same
mistake NWM-126 was filed to correct for `comment-lint.py`. What stays here
is the product half: the ledger file, `docs/cost.md`'s prose, and the
`cost-reviewer` agent.

NWM-119's `touches` was corrected while making this change. It listed
`scripts/claude-cost.py` (about to leave the repo) plus `docs/cost/README.md`
and `docs/cost/reviews/`, neither of which exists — the real layout is a
single `docs/cost.md`. It now names only what this repo will still own.

### 2026-09-19 — NWM-123 was undispatchable because its contract lived in prose, not in fields

NWM-123 (the guard hook blocks `git` inside an agent's own worktree, and is
bypassable with `/usr/bin/git`) was excluded from `issues.py next` and from
every wave, and could never be dispatched. The cause was not a missing
decision: the ticket's description ended with `verify:` and `executor: agent`
written as prose in the body, while the structured fields those names refer
to were both empty. `issues.py` reads the fields, so the ticket looked
contract-less.

Lifting both into their fields made it startable. This is worth naming as a
failure mode rather than a one-off typo: a ticket captured from a
conversation — here, reported across from homelab LAB-241 — carries its
contract as sentences, and nothing rejects it. `issues.py lint` reported the
project clean while one ticket in it was permanently undispatchable, because
an empty field is not a lint error. The tool-side net that does exist (no
executor means never startable) prevents a bad dispatch but is silent about
the ticket being stranded.

The verify clause was also strengthened while it was open. It now asserts
stderr as well as exit codes, and adds a PATH-shadowing shim case, so the
fix cannot pass by refusing everything — the failure mode a guard fix is
most likely to have.

Sequencing: NWM-113, NWM-123 and NWM-122 all edit `hooks/guard-fs-writes.sh`.
They were chained `113 → 123 → 122` rather than left parallel. NWM-123 is
placed second, ahead of NWM-122's frame-stack refactor decision, because a
guard a subagent can route around is the highest-severity item in the set and
should not wait behind a refactor.

## 2026-09-19 — land-branch.sh splits: a git merge-and-push core moves to ai-toolkit, the lifecycle stays as a night-watchman wrapper

NWM-127 asked whether `scripts/land-branch.sh` (973 lines) is generic enough
to move to `ai-toolkit`. Outcome: **split**. A generic core moves; the ticket
lifecycle, both tracker backends and the herdr teardown stay here as a wrapper
that calls it. The split itself is a follow-up ticket, not this one.

Two premises in the ticket body did not survive reading the script. It does
not call the tracker provider seam: it takes a wrapper path (`--jira-api`,
`ISSUES_JIRA_API`) and never invokes `providers/lib/provider.sh` (measured:
`grep provider.sh` matches only a help string, line 257). It has no
`issues.py lint` hook: the lint step runs `--lint-cmd` or `./scripts/lint.sh`
in the target repo (line 699), and `grep issues.py` matches one comment.
This repo has no `scripts/lint.sh`, so here the step is skipped with a warning.
The hook is already generic, which shrinks the extraction work.

### Assumption inventory

Line numbers are `scripts/land-branch.sh` at `18a5981`. Classes: **generic**
(moves as written), **param** (generic once a flag or env var names it),
**extract** (separable, but only behind a hook contract), **product**
(night-watchman's operating model, stays).

| # | Assumption | Lines | Class |
| --- | --- | --- | --- |
| 1 | Integration worktree at `<parent>/<repo>-land`, reset to `origin/<target>`, `--reset-land` for a dirty one | 525-582 | generic |
| 2 | Lock file, stale-pid reclaim, never waits | 118-176 | generic |
| 3 | `merge --no-ff`, conflict abort, ORIG_HEAD revert on any later failure, exit 1/2 contract | 646-668, 98-116 | generic |
| 4 | Lint gate on the merged tree, `--lint-cmd` or `./scripts/lint.sh` | 699-711 | generic (default path is a repo convention; word-splitting bug carries over, see known-issue) |
| 5 | `git push origin HEAD:<target>`, main worktree not fast-forwarded | 837-855 | generic |
| 6 | Branch's own worktree must be clean; `git branch -d` afterwards | 293-306, 951-955 | generic |
| 7 | Optional Co-Authored-By / Claude-Session trailers | 443-450 | param (NWM-115 removes it; drop rather than move) |
| 8 | `TARGET_BRANCH` default `main`, ticket id shape `PREFIX-nnn` | 83, 267-271 | param (id shape is only a tracker concern; core takes an opaque label) |
| 9 | Lifecycle: Awaiting Deployment before merge, Completed after push, In Progress required on entry | 584-645, 860-882 | product |
| 10 | File tracker: `issues/{open,in-progress,awaiting-deployment,completed,cancelled}/`, `outcome:`/`updated:` frontmatter rewrite, `.notes.md`, staged-rename assertions, completion commit inside the pushed history | 321-361, 672-697, 713-800 | extract (needs a pre-push hook that may add commits) |
| 11 | Jira tracker: transition resolved by target status id, read-back, comment via wrapper, three required status ids | 363-440, 824-835, 860-882 | extract (pre-merge and post-push hooks) |
| 12 | `--no-complete` and `--note`: land without finishing the ticket | 180-250, 713-800 | extract (meaningless without a ticket) |
| 13 | herdr teardown: `/exit` the worker pane, poll, `herdr worktree remove`, gated on `HERDR_ENV=1` | 884-950 | extract (post-landing hook); product in content (NWM-117) |
| 14 | `--dry-run` plan text narrates lifecycle steps | 471-523 | extract (core prints its own plan, hooks append theirs) |
| 15 | `lib/kit.sh` (`die`, `warn`, `need`, `show_help`, `tmpfile`; 56 lines), shared with other scripts here | 80-81 | param (vendor a copy into the core, or ai-toolkit gains a lib) |

Rough weight, inferred from the ranges: rows 1-6 and 8 are about a third of
the file; rows 9-14 are about half. The lifecycle is the larger half.

### Why split, not the other two

**Move whole, parameterised.** Rejected. Making rows 9-14 configurable means
three Jira status ids, a five-directory file layout, a frontmatter schema and a
herdr teardown all become flags of a public tool. `ai-toolkit`'s rule is that a
repo calls it; nothing here stops that, but the operating model would ride in
as configuration, which is the outcome the ticket set out to avoid. Every
consumer would carry flags for trackers it does not have.

**Keep here, strike from the migration list.** Rejected on measured evidence of
a second consumer. `~/code/homelab/scripts/dev/land-branch.sh` is a 1402-line
fork of the same skeleton (integration worktree, lock, merge, Jira window,
herdr exit); `diff` against this file reports 1719 differing lines. Both carry
the same class of fix independently (SIGPIPE under pipefail, exit codes on
pre-flight refusals; see each repo's `docs/known-issues/`). That is the
duplication a shared core removes. Keeping the script here leaves the fork
diverging.

**Split.** Wins because the seams already exist in the control flow: the
script has exactly four points where tracker or dispatch code runs (before the
merge, after the merge, before the push, after the push), and the failure
semantics at each are already different and well defined (nothing to revert;
revert the merge; landing stands, report exit 1).

### What the follow-up ticket must settle

1. The hook contract: four points, each hook's exit code mapped to the core's
   existing semantics. The pre-push hook is the hard one, because the file
   tracker's completion commit must land inside the pushed history and inside
   the integration worktree.
2. Where the lifecycle wrapper lives (this repo, `scripts/`) and whether the
   core is consumed by path, by a pinned checkout, or vendored. `ai-toolkit`'s
   README defines consumption as CI actions and repo-scoped calls; a script a
   local orchestrator runs is new ground for it.
3. `land-branch-selftest.sh` (916 lines) and `land-branch-jira-selftest.sh`
   split along the same line; the core's selftest uses local bare repos only.
4. Whether homelab's fork is retired onto the core (its own ticket).
5. Drop the trailer env vars (NWM-115) before the move, not after.

Owner call needed: this recommends the split; it does not start it. The move is
the more expensive path in engineering time, and the decision above rests on
one measured second consumer.

### 2026-09-19 — owner confirmed the split; the extraction is NWM-131

The entry above ended "Owner call needed: this recommends the split; it does
not start it." The owner confirmed it on 2026-09-19, so the outcome is final
rather than a recommendation, and the extraction is filed as **NWM-131**
against the five items that entry listed.

Nothing in the analysis changed between the recommendation and the
confirmation. In particular the weighting — "about a third generic, about half
lifecycle" — is still inferred from line ranges rather than measured, and
NWM-131 says so; it should not be treated as a number.

One correction to item 5 of that list. It reads "drop the trailer env vars
(NWM-115) before the move, not after", which reads as though NWM-115 is
outstanding. It is Completed: it made the trailers optional, so unset means no
trailer. But it did not remove them — `LAND_BRANCH_COAUTHOR` and
`LAND_BRANCH_SESSION` still exist at lines 68-71 and 446-449. Dropping them is
therefore inside NWM-131's scope, not a dependency on another ticket.

Sequencing: NWM-131 is blocked by NWM-120, which edits the same two files.
NWM-128, NWM-129 and NWM-130 are unaffected — each moves a different script and
none needs the land-branch core to exist first.

### 2026-09-18 — closing state: durable write first, bounded ack second (NWM-120)

A worker's exit is a handoff. `land-branch.sh` with `HERDR_ENV=1` writes the
worker's closing state to the tracker and reads it back before it ends the
worker's session, and only then notifies the orchestrator.

**Durable write before orchestrator ack.** The LAB-234 failure was a durable
write that never happened, not a message lost between two live processes. An
orchestrator can be mid-turn, compacted or closed, so making it the system of
record would reproduce that failure. The tracker survives; the pane message is
a courtesy.

**A missing ack degrades, it does not block.** NWM-117 established that a hung
worker must never block landing. The notification waits `LAND_BRANCH_ACK_WAIT_S`
(default 10) for the ack file it names, and a miss is a warning. A failed
durable write is the opposite case: exit 1, the worker's pane and workspace are
left in place so its output survives, and the landing is not reverted.

**Missing run list is refused early.** A human- or mixed-executor ticket with no
`## Human run list` in the worker's `.night-watchman/closing-state.md` stops the
landing at exit 2 before anything is mutated, because a promised-but-absent run
list is the defect. Only under `HERDR_ENV=1`; without it the script is unchanged.

Assumptions not measured: the ack is a file the orchestrator is asked to
`touch` (no consumer exists yet, which the ticket puts out of scope), and
`herdr pane send-text` followed by `send-keys enter` is taken from the NWM-117
usage rather than exercised against a live orchestrator pane. The homelab port
needs its own entry; it was not folded into LAB-241.

### 2026-09-19 — the extraction bar has two triggers, not one, and the ticket contract leaves for `work-order`

`docs/ethos.md`'s extraction default read "a measured second consumer is the
bar for extracting a shared core": one real fork of the same code, not an
anticipated one, or the extraction is speculative work. Applied to the
ticket-contract layer on 2026-09-19 it gave the wrong answer. Per the ethos
file's own rule the row is fixed in place; no exception is bolted onto it.

**Why the original misfired.** It was written for de-duplication — two copies
of the same code drifting apart — and de-duplication is the only signal it can
see. switchtender has no `issues.py` and no ticket tooling at all, so by the
letter of the rule the extraction was speculative and should have waited. The
owner supplied the fact that reverses it: every repo he works in already
assumes a tracker space, tickets, and a sprint wrapping bounded work, and none
of them owns that assumption. Working a switchtender ticket from inside the
night-watchman checkout follows the protocol by accident, not by design. That
is the inverse of duplication and it costs more, because nothing drifts
visibly — the thing simply is not there, and no diff shows an absence. A rule
that answers a whole class of cases wrongly is worse than no rule, because it
carries authority.

**The corrected rule.** Either trigger is enough on its own: a measured fork,
or a universal assumption no repo owns. NWM-127's evidence (`land-branch.sh`
against homelab's 1402-line fork) is untouched and still carries the first
trigger; the `work-order` extraction is the second trigger's evidence beside
it. Absent both, an extraction is still speculative work.

**The decision set.** Five rounds of grilling on 2026-09-19 settled 16
decisions, recorded in memory-graph as `96a41a7a-3044-428c-aa0e-66644fd3aa2f`
and filed as the WO ticket set under `~/code/issues/`. Repeated here because
memory-graph fails closed off the LAN:

1. Extract now, and rewrite the ethos default that said otherwise.
2. The deliverable is a specification — schema and protocol. `issues.py` is
   the reference implementation, not the product.
3. The name is `work-order`.
4. Its own public repository, MIT throughout.
5. The sprint mechanism is an optional documented extension, not core.
6. It ships spec, reference implementation, runnable conformance validator and
   fixtures. The validator is the teeth.
7. One repository, Claude Code plugin included. No package registry until an
   outsider asks for one.
8. The core is tracker-agnostic, with normative bindings: a file binding and a
   Jira binding. The six Jira custom fields become the Jira binding.
9. The Jira binding is a separately versioned package in the same repository,
   and it owns provisioning, because "provision me a conforming Space" is what
   makes a standard adoptable rather than admirable.
10. The spec versions independently of both packages — three version lines from
    one repository, so "conforms to work-order spec 1.0" stays stable while the
    implementations churn.
11. Conformance is MUST/SHOULD levels plus named profiles: minimal, full,
    unattended. The profiles map onto the layer split.
12. night-watchman depends on `work-order` and deletes its copies. No vendored
    fork. It keeps layer 2 only: dispatch, waves, session-start, the
    land-branch lifecycle, closing-state handoff, wave-trail.
13. `work-order` defines the profile names, including `unattended`, under a
    hard test: `unattended` must be writable purely as what a ticket needs to
    start cold with no human. If it cannot be written without naming
    night-watchman behaviour, it does not belong in the spec.
14. `to-issues` splits in two. The seam is a documented structured decision
    list: night-watchman mines the conversation and emits it, `work-order`
    consumes it and emits conforming tickets. Testable from both sides.
15. No retroactive conformance. New and touched tickets conform; existing LAB,
    NWM and CMB tickets are grandfathered under the touched-ticket and
    active-sprint lint scoping decided 2026-09-18.
16. All three repositories convert in one wave.

The reframing that produced this is three layers: a ticket is a contract an
agent can execute (tracker-agnostic, the reusable idea, becomes `work-order`);
a session runs unattended (the differentiator, becomes what night-watchman
actually is); the provider and plugin system (the extension mechanism).

UNVERIFIED and load-bearing for decision 12: that `plugin.json` supports a
`dependencies` field with semver constraints, that installing a plugin
auto-installs its dependencies, and that one repository can publish several
independently versioned plugins through one `marketplace.json`. This is
agent-reported and is spiked before the design leans on it. If it is false the
fallback is vendoring, which changes decision 12's mechanism only.

**The boundary rule does not apply to `work-order`, deliberately.** homelab's
LAB-275 (2026-09-18) sorts shared tooling by one test: does a machine apply it,
or does a repo call it? Machine-applied goes to the private dotfiles repo;
repo-consumed goes to the public `ai-toolkit`. Read literally, a spec plus a
reference implementation that repos consume is repo-consumed, and `work-order`
would land in `ai-toolkit`.

It does not, and this is recorded so nobody re-litigates it on the next read of
LAB-275. That rule sorts internal shared plumbing by where it is applied from,
and its audience is this owner's own repositories. `work-order` is a public
product aimed at strangers: a different audience, a different cadence, its own
independently versioned spec, and a conformance validator outsiders run against
implementations that are not ours. Folding it into `ai-toolkit` would tie a
product's release line to a plumbing repository's moving `@v1` major tag, which
is exactly what decision 10 exists to prevent. LAB-275 is unchanged for
everything it was written for — `comment-lint.py`, the composite action, the
five migrating scripts — and `ai-toolkit` remains the default for shared
tooling. `work-order` is the documented exception, not a precedent for moving
plumbing out of `ai-toolkit`.

Still open, left unguessed: whether `work-order` gets its own tracker space.
Every other active repo has one.

### 2026-09-19 — WO-002 spike: plugin dependencies are real and enforced, but a clean exit code does not prove the pin held

Supersedes the `UNVERIFIED and load-bearing for decision 12` paragraph in the
entry above. That paragraph flagged three agent-reported claims as unspiked.
All three were measured first-hand on the Mac against Claude Code 2.1.278,
using two throwaway local-folder marketplaces and four scratch plugins. No real
marketplace was touched and night-watchman's own `plugin.json` was not
modified. Both scratch marketplaces were removed afterwards and the plugin
registry diffs clean against its pre-spike state.

**All three claims hold.** `.claude-plugin/plugin.json` takes a `dependencies`
array whose entries are either a bare plugin name or an object of `name`,
`version` and `marketplace`. Installing a dependent plugin alone does install
its dependency: `claude plugin install wo-spike-binding` reported
`(+ 1 dependency: wo-spike-core)`. One repository does publish several plugins
on independent version lines through one `marketplace.json`, tagged
`{plugin-name}--v{version}`; `claude plugin tag` derives the tag from the
manifest and refuses when `plugin.json` and the marketplace entry disagree,
reporting that `plugin.json` wins at install time.

**The semver constraint is enforced, not decorative.** This was the question
most likely to have been assumed wrong, so it was measured against a case where
enforcement and convenience disagree. The scratch marketplace's current entry
for `wo-spike-core` said `2.0.0`, and tags existed at `1.0.0`, `1.1.0` and
`2.0.0`. The dependent plugin pinned `^1.0`. The install resolved to `1.1.0` —
the highest tag satisfying the range — and skipped the newer copy the
marketplace was advertising. The recorded version carried a commit-SHA suffix
(`1.1.0-767ec7e66eeb`), so a force-moved tag gets a fresh cache directory
rather than stale content.

**Disable is refused, and the refusal is machine-readable.** Disabling
`wo-spike-core` while `wo-spike-binding` was enabled failed with exit 1,
`failureCode: "required_by_dependents"`, a `reverseDependents` array, and a
chained command that disables the pair in the correct order. Nothing was
mutated by the attempt. Enabling is symmetric: enabling the dependent alone
re-enabled the dependency and said so. `claude plugin prune` tracks
auto-install provenance, lists only orphans, and leaves manually installed
plugins alone.

**The trap, and the reason this spike earned its keep.** An unsatisfiable
constraint does not reliably fail the install. There are two distinct paths and
only one of them is loud.

When another *installed* plugin already constrains the same dependency and the
ranges do not intersect, the install hard-fails: exit 1,
`failureCode: "dependency_version_conflict"`, message naming both ranges.

When nothing else constrains it and no tag satisfies the range, a plugin the
marketplace references by relative path installs the marketplace's *current
copy* instead and reports `outcome: "ok"` with exit 0. Pinning `^9.0` against
tags of `1.0.0`, `1.1.0` and `2.0.0` produced a successful install of `2.0.0`.
The violation appeared nowhere in the install result — only in the `errors`
field of `claude plugin list --json`:
`Requires "wo-spike-core@wo-002-spike" ^9.0, installed 2.0.0`.

The same pattern holds for a blocked cross-marketplace dependency: install
returned `outcome: "ok"` and exit 0 while simply not installing the dependency,
with `dependency-unsatisfied` visible only in the `errors` field.

So a zero exit from `claude plugin install` is not evidence that a version pin
was honoured or that a dependency arrived. Anything gating on dependency
resolution must assert on the `errors` field, not on the exit code. A failed
install also leaves an entry behind with `enabled: true` and `errors`
populated; `enabled` is the configured flag, not the effective load state.

**Cross-marketplace dependencies need an allowlist, which decision 12 will
hit.** night-watchman and `work-order` will ship from different repositories and
therefore different marketplaces, so the dependency in decision 12 is a
cross-marketplace one. By default it is blocked. It works only when the root
marketplace — the one hosting the plugin being installed, so night-watchman's —
carries `allowCrossMarketplaceDependenciesOn` naming the target marketplace.
Measured both ways: without the field the dependency silently did not install;
with `"allowCrossMarketplaceDependenciesOn": ["wo-002-spike-b"]` the
cross-marketplace dependency installed cleanly with no errors. The field passes
`claude plugin validate --strict`.

**Two validator limits worth knowing.** `claude plugin validate --strict` does
recognise `dependencies` — it proposes it as the correction for a typo'd field
name, which is how the field's existence was confirmed independently of the
docs. It does *not* check that a `version` string is valid semver: a range of
`"not a semver range !!"` passed strict validation without comment. Range
syntax errors surface at install or load, not in CI.

**WO-002's own verify command is wrong and must not be copied.** It asserts on
`[.[].name]`, but `claude plugin list --json` has no `name` field; entries key
on `.id`, formatted `plugin@marketplace`. As written the assertion returns
`false` and exit 1 even when the dependency installed correctly — a false
negative that would have read as the mechanism not existing. The working form
is:

```bash
claude plugin list --json | jq -e '[.[].id | split("@")[0]] | contains(["wo-spike-core"])'
```

**Not measured, and left open for WO-010.** Whether a plugin carrying a
dependency error actually fails to load in a live session — the docs say it is
disabled at load, but that is a session-start behaviour this spike did not
exercise, and the `enabled` flag stays `true` meanwhile. Also untested:
dependency resolution from a real remote GitHub marketplace, as both scratch
marketplaces were local folders. Local-folder marketplaces resolve tags only
when the folder is a git repository, which is why both scratch marketplaces
were initialised as one.

**Consequence for decision 12: it stands, and vendoring is not needed.** The
mechanism exists and enforces what it claims. WO-005, WO-008 and WO-010 are
unblocked, with two obligations: night-watchman's `marketplace.json` must carry
`allowCrossMarketplaceDependenciesOn` for the `work-order` marketplace, and any
check that "the dependency resolved correctly" must read the `errors` field
rather than trust an exit code.

## 2026-09-19 — WO-026: the Workflow tool becomes the default `dispatch` implementation, herdr becomes the fallback

`providers/dispatch/` was a provider-neutral contract with exactly one
implementation. herdr was not the default so much as the only thing there,
which made the seam an argument rather than a tested design. Meanwhile the
platform grew a dispatcher: Claude Code's Workflow tool runs subagents
in-process under a deterministic script, and the 2026-09-19 work-order wave
ran that way — seven tickets, fourteen agents, nothing above the dispatch
seam changed, and zero dispatch failures against three standing herdr
dispatch bugs on the other path (the cold-boot brief swallow, the
reached-working wait failing on back-to-back starts, the folder-trust dialog
in a fresh worktree). WO-026 turns that into `providers/dispatch/workflow/`
and flips the built-in default to it.

**herdr is demoted, not deleted.** It serves what the Workflow tool does
not: a human-visible pane during a supervised run, a session that outlives
the orchestrating turn, and anything needing a real terminal. Removing it
would trade one single-implementation contract for another, and the value of
this ticket is precisely that the seam now carries two.

**The three herdr dispatch known-issues are deliberately not fixed here.**
Once herdr is the fallback they leave the critical path, and what the
fallback is worth is a separate decision. Re-rank them after this, not
before.

**The verbs do not map one-to-one, and the difference is declared rather
than approximated.** A subprocess cannot call an in-process tool, so the new
provider owns the deterministic half — compose, record, report — and the
orchestrating turn owns the Workflow launch and the `TaskStop`. `start`
composes the brief and records the launch request; it opens no pane, creates
no worktree (the brief tells the agent to make its own, as the wave did),
and writes nothing to the tracker. `stop` records a stop request and names
the `TaskStop` to issue. `watch` is the verb that genuinely does not map:
herdr's is a live pane plus a blocking wait, and the Workflow tool's
equivalents — a task notification and a journal — are delivered to the turn
holding the tool, never to a subprocess it spawned. So `watch` promises
exactly one thing, the state recorded in the run journal at the moment it is
asked, and `--until`/`--timeout` are refused by name. Accepting them would
have produced a wait that could only ever time out, since nothing in that
process's lifetime writes the state being waited on. A provider that
silently means something different is worse than one that declares a gap;
the gap is written down in `providers/README.md` next to the contract.

**The run journal lives outside the repo** (`$XDG_STATE_HOME/night-watchman/
dispatch-workflow` by default). An untracked file inside a worktree dirties
it, and `land-branch.sh` then refuses before reading anything — that
deadlock has already cost one landing.

**Two files the flip forced, both outside the ticket's `touches`.**
`templates/night-watchman.config.toml` had to follow, because
`providers/config-selftest.sh` asserts the template's selection for every
kind equals the built-in default — the flip would otherwise have failed the
selftest it was required to pass. This repo's own
`.night-watchman/config.toml` was flipped for a different reason: it is the
reviewed answer for night-watchman itself, and leaving it pinned to herdr
would have made the flip invisible even to a fresh clone.

**What the flip does not change on the owner's machine.** Resolution is env
| config | default, and `~/.config/night-watchman/nwm.toml` — machine
config, not repo content — still pins `dispatch = "herdr"`. So
`providers/lib/provider.sh origin dispatch` reports `config` and `resolve`
still answers `herdr` wherever `NW_CONFIG` points there. That file was left
alone deliberately; it is the operator's to change, and a flip nobody can
observe is the failure mode this ticket was most likely to ship, so it is
recorded here rather than quietly worked around.

## 2026-09-19 — Bare `cd <repo> &&`/`;` Bash prefixes replaced with `-C`/`--repo` (WO-034)

Baseline measured over the full transcript corpus on 2026-09-19 (WO-033,
memory `c3a3f04e`): 3,561 Bash calls carried a leading `cd` that no tool
needed — `cd .../homelab && …` (2,349 calls, avg 682 chars), `cd
.../homelab; …` (1,212 calls, avg 580 chars), and `cd .../night-watchman &&
…` (425 calls, avg 892 chars). 199 `git -C …` calls already existed in the
same corpus, so the alternative was in use, just not by default.

`dot_claude/CLAUDE.md` now states a substitution table (`git -C`, `gh
--repo`, a script's own path argument, or `( cd … )` as the catch-all
subshell) instead of a bare prohibition — a prohibition with no named
alternative gets ignored — and states the cost inline: a bare `cd` mutates
the session's cwd for every later call, and that drift causes
`guard-fs-writes.sh` false positives on writes that resolve outside the
current worktree.

Recorded here rather than in the ticket body, per the tickets protocol, so a
re-run of WO-033's report is a comparison against this baseline rather than a
fresh impression. A PreToolUse hook that rewrote the `cd` prefix
automatically was considered and deliberately deferred: it would sit beside
`rtk-rewrite.sh`, which already rewrites every Bash command, and WO-023 has
just spent real time on guard false positives from a rewriter on that same
seam. A second rewriter there is something to earn with evidence from the
re-run, not assume up front.

### 2026-09-19 — WO-035: memorygraph gets a typed MCP dispatcher, not a bundled server

`memorygraph` is the second-highest-volume Bash family in the corpus — 744
`recall` calls averaging 124 characters, 622 `store` calls averaging 1,427
characters (WO-033, memory `c3a3f04e`) — every one a long shell string
wrapping a payload that is already structured data. Two failure modes come
directly from that shape: a multi-word `recall` silently returns nothing
(`--query "jira api auth"` finds zero; `--query "jira"` finds six, held only
as a `CLAUDE.md` prose rule until now), and a `store` call with a
1,400+-character payload through `--content` failed once with an internal
error and succeeded on a bare retry of the same content — a shell-quoting
failure, not a logic one.

Decision: `dotfiles/dot_claude/mcp/memory/` is a thin MCP server dispatching
`recall`/`store`/`link`/`related`/`briefing` to the `memorygraph` CLI as
argv arrays, never a shell string, and holding no graph logic of its own.
`recall` rejects a multi-word `noun` outright instead of returning an empty
result set; `store` validates `type` against the CLI's real 13-value enum
and `link` against the three relationship types that actually work
(`SOLVES`, `CAUSES`, `CONTRADICTS`), both before the CLI is invoked.
Registered per project through that project's own `.mcp.json`, never in
`~/.claude/settings.json`.

Reasoning: this does not reverse memorygraph's own v0.14 decision to drop
its bundled MCP server for shell invocation — that removed a coupling
*inside the product*; a thin local dispatcher over the published CLI
reintroduces none of it, since the CLI stays the interface and deleting the
server leaves every existing call site working. The guards are the point,
not the typing: converting the multi-word-recall rule from prose a caller
has to remember every call into something that cannot be got wrong is the
enforcement ladder's top rung applied to a rule that was sitting on its
bottom rung. `store` gains no convenience beyond the schema — no
auto-tagging, no inferred type — because guessing metadata is how a graph
fills with entries nobody trusts. The server never reaches FalkorDB
directly: backend selection, credentials and the off-LAN fail-closed
behaviour all live in the CLI's own environment contract, and duplicating
that here is how the two diverge.

Out of scope, deliberately: changing `memorygraph` itself, or upstreaming
the multi-word-recall behaviour as a fix there — worth doing, separately.
Auto-recall on session start.

### 2026-09-19 — MCP sits beside rung 1 as a surface, not a fourth rung (WO-030)

Added to `skills/capability-ladder/SKILL.md`: a script can carry a typed,
callable MCP surface without becoming a new rung. Placed beside rung 1, not
above or below it — above would say MCP holds judgement, which it doesn't;
below would say it replaces the script, which it must not, since a server
that owns behaviour can't be retired without a rewrite. The script stays
the artifact; MCP is only its signature — schema-validated parameters, call
by name, a distinct `tool_name` in tool analytics.

Two premises that used to close this question off are stale. An MCP server
needs no deployed backend — a local stdio process shelling out to `gh`,
`git`, or `docker` is ordinary. And tool schemas are no longer a per-turn
context cost in this harness: they're deferred, so an unused tool costs one
name in a list, not a schema. A 2026-09-19 measurement found roughly 230
deferred tool names in a live session, about 100 of them `tokensave_*`, of
which only five carried eager schemas — so the dominant cost of a crowded
tool list is choosing the wrong tool, not token count.

Breakeven test written into the skill: reach for the surface only when a
coherent family of operations shares a domain model *and* the `Bash` bucket
genuinely isn't enough — analytics need tool-level granularity a shell
command can't produce, or a curated API would replace repeated,
near-identical invocations. Either alone stays a script. One server per
domain, scoped per project via its own registration, never installed
globally, since a global server puts every project's tools in every other
project's name list.

The server holds no logic — every tool is a thin dispatcher over a script
that already works standalone, so exposing it stays reversible. The
laundering hazard is named in the skill itself, not only in memory: a tool
that reaches an action its script can't, or carries a flag bypassing a
check the script enforces, is a permission bypass wearing an interface.
Building the server itself is WO-029's territory, out of scope here.

### 2026-09-19 — WO-037: ship About/Learning/Risk/Decision as four named verbs, not a `mutate` passthrough

`townsquare.sh` shipped `whoami`/`projects`/`update` only, by its own header's
admission — the fields that carry the *reasoning* behind a status (Learning,
Decision, Risk, About) had no verb, though Home Projects has no REST fallback
for them (memory `8238ce2c`). That left the most informative half of the
capability unbuilt on purpose, for a workspace whose whole operating model
produces exactly those artifacts (`docs/decisions.md` entries, known-issue
resolutions, per-wave learnings) with no route to the project feed a human
reads.

Four named verbs (`about`, `learning`, `decision`, `risk`), each mirroring
`update`'s own read/write discipline, rather than one free-form `mutate`
passthrough: a passthrough would make every future field free but also make
an arbitrary GraphQL mutation against the live site one typo away — the
shipped script's discipline is the thing worth preserving. `mutate` stays
unshipped.

`learning`/`decision`/`risk` take only `<project-ari> -`, unlike homelab's
`atlassian-graphql.sh` (LAB-180) which also takes a separate `<summary>`
shell argument. The short plain-text `summary` these three mutations require
is instead derived from the first line of stdin, with the whole text
ADF-encoded into `description` — one input channel instead of two, at the
cost of the summary and the body's first line always matching.

Every mutation ships with a fixture recorded from a real call, per the
existing rule that a guessed GraphQL shape is worse than no entry: rather
than spike these live again, `fixtures/townsquare/{learning,risk,decision,
about}.*.json` reuse the LAB-180 spike's already-verified recordings from
`homelab/scripts/fixtures/atlassian-graphql/` (same throwaway
`ZZPROBE-tabs-fixtures-2026-09-11` project, never the real Homelab project),
the same sourcing `update`'s own fixtures used. That spike also confirmed,
live, two facts this implementation depends on: `description` requires ADF
the same as `update`'s `summary` does (a plain string is rejected, naming the
field), while `summary` on Learning/Risk/Decision is the one exception and is
sent as plain text; and Risk/Decision's created id carries the ARI type
segment `learning` regardless — the server's own inconsistency, not a bug.

### 2026-09-19 — WO-039: check known-issues and memory-graph before reporting broken — shipped as prose, which the trace-flag rule already showed can fail

Twice on 2026-09-19, an agent reported something as broken, denied, or
unexplained when the answer was already on disk — a known-issues entry in
night-watchman's own `docs/known-issues/`, and separately a merge status
disproved by the primary source. Neither failure was a diagnosis problem;
both were a lookup-before-reporting problem, and the lookup is one `grep`
and one `memorygraph recall` away. `CLAUDE.md` already told agents to
recall before telling the user something is impossible, unsupported, or
not there, but that trigger list never named `docs/known-issues/`, and no
dispatched agent's brief mentioned either store at all.

Added one precondition, phrased on reporting rather than diagnosing since
the diagnosis was never what failed, to the three places an agent's
working contract actually comes from: `templates/dispatch-brief.md` (the
only one of the three that reaches a dispatched wave worker's own prompt),
`templates/CLAUDE.md` (for sessions that never go through dispatch), and
the owner's dotfiles `CLAUDE.md` (extending its existing memory-graph
trigger list to name `docs/known-issues/` beside it).

This ships as prose, and that is a known-weak choice, not an oversight.
The trace-flag prohibition is the same shape of rule — capitalized, in a
brief, with its exact consequence spelled out — and it failed the same day
this ticket was filed: WO-042's agent had that exact paragraph in its own
brief and ran `zsh -x` anyway while debugging a verify line, leaking
`OP_SERVICE_ACCOUNT_TOKEN` and `MEMORY_FALKORDB_PASSWORD` into the
transcript for the third recorded time (memory-graph, tag `wo-042`). A rule
an agent had read minutes earlier did not survive contact with a debugging
shortcut under time pressure. There is no reason to expect this rule to
fare better for being written more emphatically.

A structural version is the stronger option and is not built here. The
nearest precedent is `guard-fs-writes.sh`, which stops an out-of-worktree
write mechanically rather than asking an agent to remember not to make
one — a hook on the report/hand-back path could `grep docs/known-issues/`
for the reported symptom before a BLOCKED or "reporting broken" status is
accepted, the same shape of guarantee. It is not proposed as a change here
because there is no reliable machine signal yet for "this text is
reporting a failure" comparable to the redirect-target signal
`guard-fs-writes.sh` checks; building that detector well enough to avoid
false positives is its own piece of work. Revisit this decision — including
possibly reverting the prose version — if repeated recurrence shows prose
does not hold here either.

### 2026-09-20 — WO-010 stays undone: the published work-order plugin does not carry issues.py, and a dependent locates a dependency through claude plugin list --json

WO-010 is to delete this repository's own copy of `issues.py`, under
`skills/to-issues/scripts/`, and depend on work-order for it instead. WO-002
cleared the dependency mechanism and WO-004 moved the implementation, so the
ticket looked unblocked. It is not. Measured 2026-09-20 against Claude Code
2.1.278. (This entry deliberately never spells the doomed path as one string,
because WO-010's own verify block greps the tree for it and an append-only
decision log would make that check unsatisfiable forever.)

**A marketplace plugin installs its `source` subtree and nothing else.** The
`claude-plugins-official` marketplace publishes `typescript-lsp` from
`./plugins/typescript-lsp`. That marketplace repository holds 39 plugin
directories plus a root `LICENSE` and `README.md`; the installed copy under
`~/.claude/plugins/cache/claude-plugins-official/typescript-lsp/1.0.0/` holds
exactly the two files that one subdirectory holds, and nothing from the
repository root. `caveman` (source `./`) and `datadog` (source a whole
separate repository URL) each get their entire tree, which is the same rule
seen from the other side. Files outside the `source` path never arrive on the
installing machine.

**So the published work-order plugin does not carry the reference
implementation.** work-order's `marketplace.json` publishes the `work-order`
plugin from `./plugins/work-order`. At `work-order--v0.2.0` (origin/main
3282e90) that directory is five regular files — `.claude-plugin/plugin.json`,
`CHANGELOG.md`, `README.md`, `skills/emit-tickets/SKILL.md`,
`skills/emit-tickets/emit.py` — with no symlink. `reference/issues.py` sits at
the repository root, outside the published subtree. The plugin's own README
already advertises "its reference implementation (`issues.py`)": WO-008
packaged the directory, WO-004 landed the implementation beside it rather than
into it, and nothing has failed loudly because nothing yet depends on it.
Declaring the dependency and deleting the local copy today would delete
working behaviour and put nothing in its place, which is the one outcome
WO-010 exists to avoid.

**The runtime-location question is answered, and it was never the blocker.**
WO-002 proved dependencies resolve and are semver-enforced but never measured
how a dependent's *script* finds a dependency's files. `claude plugin list
--json` returns one object per installed plugin carrying `id`
(`plugin@marketplace`), `version` and `installPath`, and
`~/.claude/plugins/installed_plugins.json` records the same `installPath`
under the same key. A dependent resolves a dependency's root by selecting on
`.id` — there is no `.name` field — and reading `.installPath`.
`${CLAUDE_PLUGIN_ROOT}` names only the plugin currently executing, so it
cannot reach a sibling. One caveat: a plugin loaded from a local checkout
rather than installed from a marketplace has no entry at all, so anything
built on this needs a fallback for development.

**WO-010's caller inventory was wrong, in a way that makes the migration
smaller than it looked.** Neither `scripts/land-branch.sh` nor
`hooks/bash-result-shunt.sh` executes the script; each mentions it only in a
comment, and `hooks/bash-result-shunt-selftest.sh` passes the path as hook
*input text* being classified, not as a command it runs.
`scripts/land-branch-selftest.sh` copies the file into fixture repositories,
so it needs a real file on disk and a dependency reference would not serve it.
The live callers are four Markdown instruction files — `agents/librarian.md`,
`skills/tickets-protocol/SKILL.md`, `skills/session-start/SKILL.md` and
`skills/to-issues/SKILL.md` — each invoking it under `${CLAUDE_PLUGIN_ROOT}`.

WO-010 stays open with the deletion undone. It unblocks when work-order
publishes `issues.py` inside `plugins/work-order/`, or moves that plugin's
`source` to the repository root, and cuts a release carrying it — only then
can a pin here resolve to something that actually holds the file. That is a
work-order change and outside this ticket's declared `touches`, so it is left
for a new ticket rather than taken here.

### 2026-09-20 — WO-010: night-watchman depends on work-order v1.3.0 and deletes its own ticket-contract copies

night-watchman no longer carries the ticket contract. `.claude-plugin/plugin.json`
declares `work-order ^1.3.0` from the `work-order` marketplace, its own
`marketplace.json` carries `allowCrossMarketplaceDependenciesOn: ["work-order"]`
— without that field WO-002 measured the dependency silently not installing —
and this repo's copies of `issues.py` and the frontmatter reference under
`skills/to-issues/` are deleted.

Two blockers had to clear first, and both were checked against the remote
rather than assumed. The published work-order plugin now ships from the
repository root (WO-048), so its installed tree carries `reference/issues.py`;
and the pin is the repository release **v1.3.0**, not the retired
`work-order--vX.Y.Z` per-plugin tag line.

**How a dependent finds a dependency's files.** `${CLAUDE_PLUGIN_ROOT}` names
only the plugin that is executing and cannot reach a sibling, so
`scripts/work-order-root.sh` resolves the location at runtime:
`$WORK_ORDER_ROOT`, then the `.installPath` of the `claude plugin list --json`
entry whose `.id` is `work-order@work-order` (there is no `.name` field to key
on), then a work-order checkout beside the plugin. The third is not a nicety —
a plugin loaded from a local checkout has no plugin-list entry at all, so
without it every instruction file here breaks for anyone running from a
checkout. Each candidate must actually hold `reference/issues.py`, so a stale
`installPath` is not trusted.

**Measured, not assumed.** In an isolated `CLAUDE_CONFIG_DIR` with two
local-folder marketplaces, `claude plugin install night-watchman@night-watchman`
reported `(+ 1 dependency: work-order)`, and `claude plugin list --json` showed
`work-order@work-order` at 1.3.0 with `errors: null`. The installed tree
carries `reference/issues.py`, which lints work-order's own file-binding
examples at 6 tickets, 0 errors. Exit 0 was deliberately not the evidence:
WO-002 measured that a blocked cross-marketplace dependency still reports `ok`
and exits 0, recording the violation only in `errors`. CI clones the newest
`v1.*` tag resolved at run time rather than pinning a literal that would go
stale, and `scripts/land-branch-selftest.sh` now takes its `issues.py` from the
same resolver instead of from a path inside this repo.

Not deleted: `skills/to-issues/assets/ticket-template.md`. work-order v1.3.0
ships `SPEC.md`, `bindings/file/BINDING.md` and example tickets, but no bare
template, so deleting it would remove something the dependency does not
replace. It stays until work-order carries an equivalent.

### 2026-09-21 — WebFetch results are cached and reused only on an HTTP 304 revalidation (NWM-142)

The mechanism, adopted from `addyosmani/agent-skills` (`hooks/sdd-cache-pre.sh`
and `sdd-cache-post.sh`, audited 2026-09-20): a PreToolUse hook matching
WebFetch looks the URL up in a local cache. If an entry exists, it issues a
conditional HEAD carrying `If-None-Match` and `If-Modified-Since`. On a 304 it
blocks the fetch (exit 2) and hands the model the cached reading through
stderr; on anything else it allows the real fetch. A PostToolUse hook stores
the reading together with the validators the origin is advertising.

Shipped here as `hooks/webfetch-cache-pre.sh` and `hooks/webfetch-cache-post.sh`
because the ownership table gives the cheap-reader hooks to night-watchman, and
the whole point is not paying twice for a body the model has already read.

There is deliberately no TTL and the prompt is not part of the cache key.
Freshness is delegated entirely to the origin, so a reuse is a fresh
verification rather than a memory read — which is what keeps this compatible
with the standing rule that anything carrying a version or a release cadence is
looked up, not recalled. A hit asserts only what the origin just asserted: the
bytes have not changed since the reading was taken.

The cached body is not raw HTML. It is one agent's model-processed reading of
the page under its own prompt, so the originating prompt is stored alongside and
printed on every hit; the next agent has to judge whether that reading answers
its question. There is no "ask twice and it passes through" escape hatch of the
kind `read-shunt.sh` has, because a second WebFetch of the same URL in one
session is exactly the case this hook exists to serve. The escape hatch is a
plain `curl` in Bash, which the hook never matches.

Three consequences of delegating freshness that the implementation had to
absorb. An origin advertising no ETag and no Last-Modified is never cached at
all, since without a TTL there would be nothing to revalidate against. Claude
Code does not hand a hook the tool's response headers, so the post hook issues
its own HEAD to observe them, and skips the write unless that HEAD is a clean
200. And a credentialed URL — userinfo before the host, or a
token/secret/signature-shaped query parameter — is never stored or served,
checked before the URL is hashed so it leaves no trace in the cache directory.

Having no TTL creates one failure mode that is not a refetch, and the post
hook is where it has to be stopped. Not every successful WebFetch carries page
content: a cross-host redirect comes back as a short notice asking the model to
fetch the target instead, and a robots.txt or 403 refusal comes back as error
prose, both reported as success. Cached, either one would be served forever,
because the pre hook would keep revalidating against a validator that keeps
matching and keep printing the notice under a banner asserting the content is
current. Three gates refuse it: the tool's own `.tool_response.code` must be
200 when the payload carries one, the validator HEAD does not follow redirects
so a redirecting URL answers 3xx and fails the 200 gate rather than being keyed
under the target's validators, and a reading under `NW_WEBFETCH_MIN_BYTES`
(200) is refused because the notice shapes are short and a page reading is not.

Both hooks fail open on every ambiguity: no cache directory, an unwritable one,
a missing `jq` or `curl`, a HEAD that errors or times out, a malformed entry, an
empty body. A needless refetch costs tokens; serving a stale body would be a
correctness bug. The credentialed-URL match is over-broad on purpose — the
substrings are looked for anywhere in the query string, so `author=` and
`session_type=` also opt a URL out — because a false positive costs one refetch
and a false negative puts a credential on disk.

### 2026-09-21 — NWM-122: bash `local` replaces the hand-rolled frame stack in guard-fs-writes.sh

NWM-118 made guard-fs-writes.sh's scanner re-entrant with a hand-rolled
frame stack — `_frame_push` / `_frame_pop` / `_FRAME_STACK`, four
hand-maintained `_*_FRAME_VARS` / `_*_FRAME_ARRAYS` name lists, and a
wrapper/`_body` split on each of the three mutually recursive functions.
NWM-122 asked whether bash's own `local` already does that job. It does,
and the frame stack is gone.

**What replaced it.** Each of `scan_command_text`, `scan_segment` and
`scan_dollar_parens_in_word` now declares its own per-call state with
`local` at the top of the function, and the `_body` wrapper pair is
deleted. `local` in bash is DYNAMICALLY scoped, not lexical: a helper
called from the declaring function sees and writes the declaring
function's copy, and a recursive re-entry gets a fresh copy with the
outer one restored on return. That is exactly the property the frame
stack was built to provide. Net −74 lines in the hook (1328 → 1254;
19 insertions, 93 deletions).

**The specific risk, hunted and cleared.** `local` would be wrong if a
helper called from one of these bodies relied on a global outliving the
declaring function's return. A whole-file scan for every name in the
four frame lists found exactly four cross-function uses, all of them
inside the declaring function's dynamic extent, so all four are correct
under `local`:

- `tokenize_quoted` writes `_ss_words`; called only from `scan_segment`.
- `split_unquoted_segments` writes `_sct_seglist`; called only from
  `scan_command_text`, which reads it on the next line.
- `_ss_opaque_push` / `_ss_opaque_pop` read and write `_ss_opaque`;
  reached only through `scan_segment`.

`_AC_NAMES` / `_AC_VALUES` are the case the ticket flagged as most
likely to break, since `collect_same_command_assignments` appends to
them and `substitute_same_command_vars` reads them across nested
`scan_command_text` calls. They are genuinely append-only across the
whole invocation — and they were never in any frame list, so the frame
stack never saved them either. Nothing about this change touches them.

**Evidence.** Both shapes were kept side by side and run against the
same oracles.

- Selftest, and the reason it was not enough on its own: the 135
  behavioural assertions pass on both shapes, so the verify's "no fewer
  assertions than NWM-118 left it at" holds at equality — but equality
  is also the defect. Every one of those 135 passes against the parent
  commit unchanged, so not one of them can tell the two shapes apart,
  and a verify made only of them would have proved nothing about this
  change. Three assertions were added that do discriminate (136–138).
  They audit the source statically: every `_ss_` / `_sct_` / `_sdp_`
  variable assigned anywhere in the hook is declared `local` in its
  owning scanner, none is assigned at file scope, and `tokenize_quoted`
  / `split_unquoted_segments` are called only from the scanner whose
  `local` they write. Against the parent commit's hook, through the
  selftest's own `GUARD_SH` override: 135 passed, 3 failed, exit 1.
  Against this one: 138 passed, exit 0.
- Four bypass shapes plus controls, re-run explicitly on the `local`
  shape: assertions 82–89 (`bash -c "true" rm -rf <outside>`,
  `sh -c "x" mv`, `eval true rm -rf`, a second `find -exec rm -rf`
  after a harmless first, `xargs bash -c`, nested `$( $( ) )`,
  `find -exec bash -c`, `find -exec sh -c`) all block; controls 90–94
  (the same shapes with harmless trailing commands, and an in-worktree
  `rm -rf`) all allow, so the mechanism is not simply refusing
  everything.
- Stderr: assertions 95–97 pass — an allowed `echo hello` and an
  allowed nested command each write zero bytes to stderr, and a
  blocked nested command writes only the block message. Measured
  directly as well: `ls -la`, `bash -c "echo hi; ls"` and
  `echo "$(ls -l)"` each produce 0 stderr bytes under both shapes. The
  `${#arr[@]}`-on-a-never-declared-name unbound-variable noise the
  ticket describes was already absent from the landed NWM-118 version
  (its three arrays are pre-declared), so that cost is historical, not
  a live defect this change fixes.
- Differential: 84 commands (every literal `run_guard` command in the
  selftest with paths substituted, plus 18 hand-built deep-nesting,
  heredoc, assignment-substitution and opaque-command cases; 37 block
  and 47 allow under the baseline) produced ZERO differences in exit
  code or stderr between the two shapes.
- Negative control, which is what makes the above non-vacuous: a copy
  of the `local` shape with the 12 `local` declarations stripped and
  nothing else changed fails 8 of the 135 behavioural assertions — 82,
  83, 85, 86, 87, 88, 89 and the nested-stderr oracle 97 — plus the new
  136, and diverges from the baseline on 8 of the 84 differential
  commands. The oracles do discriminate; they are not passing because
  they cannot fail.
- Drift control, which is the failure this change actually has to
  survive: a copy with `_ss_fp=""` removed from one `local` line and
  nothing else changed — one forgotten name, the exact shape of the
  frame-list drift argued against below. All 135 behavioural assertions
  still pass. Only 136 fails. Nothing in this repo but that assertion
  notices.

**Timing, measured on this Mac, bash 3.2.57, arm64.** Mean wall time
per invocation over 3x40 runs of an ordinary allowed command (`ls -la`):
frame stack 48.7–49.6 ms, `local` 48.3–50.6 ms — indistinguishable,
because both are dominated by the `jq` and `git` subprocess startups,
exactly as the ticket predicted. Over 3x15 runs of a deliberately
pathological four-deep nesting of `bash -c` / `eval` / `find -exec` /
`$( )`: frame stack 107.8–111.0 ms, `local` 87.5–89.2 ms — about 20 ms
and 19% faster, because the frame stack's per-call save/restore loops
over ~34 names in indirect expansion and `eval` are the one part of the
scanner that is not subprocess-bound. So: no measurable cost on the
common path, a real saving on the deep path, and no case where the
frame stack is faster.

**Why it is the frame stack that loses, and not a tie.** The
measurements above are close enough on the common path that speed alone
would not decide it. What decides it is that the frame stack's variable
lists are maintained by hand and the compiler cannot check them. Two
drifts already existed: `_ss_fp` (the `for _ss_fp in
"${_ss_find_paths[@]}"` loop variable) was never in `_SS_FRAME_VARS`,
and the ticket records `_sct_seg` having been missing from
`_SCT_FRAME_VARS` before it was added.

`_ss_fp`'s omission was latent, not live, and the distinction is worth
being exact about because a reader who checks will find it. Its loop
body reaches only `check_and_block_target`, which reaches
`target_is_outside` and `block` and re-enters no scanner, and bash
snapshots a `for` list at loop entry, so no current call path could
have observed the omission. That does not weaken the argument, it is
the argument: nothing in the repo distinguished the latent omission
from a live one, the difference is decided by call paths that later
edits move, and a name is silently reclassified from harmless to
load-bearing the day someone adds a re-entrant call under that loop.
With `local`, the declaration sits at the top of the function it
belongs to, one screen from the body, and bash enforces it. There is
no list to drift — and since this change,
`hooks/guard-fs-writes-selftest.sh` assertion 136 fails if a scanner
variable ever goes undeclared again.

**Left in place deliberately.** The `_SS_OPAQUE_STACK` push/pop pair is
now redundant: a nested `scan_segment` gets its own `local _ss_opaque`,
so it can no longer clobber the outer frame's value, which is the only
thing that stack defends against. It stays anyway. The known issue
`guard-fs-writes-sh-trailing-words-after-a-re-execution-context-in-the-same-segment-bypass-local-rules`
records that no probe can isolate that stack's behaviour, and removing
an unfalsifiable guard inside a redesign of the same mechanism is how a
regression ships unnoticed. Removing it is a separate ticket with its
own oracle, or it does not happen.

### 2026-09-22 — script-analytics.py vendors its cost helpers instead of importing them (NWM-156)

The 85 lines script-analytics.py needed from claude-cost.py and
claude-cost-scan.py are now copies inside it, not `importlib` loads of two
siblings at import time. The file is self-contained and runs from any
directory in any repo, which is what NWM-130 needs and what NWM-129 made
permanent by fixing the two claude-cost files in this repo for good.

A third shared module was rejected because it renames the coupling rather
than removing it, and because `hooks/session-cost.sh` runs for every
installer under `SessionEnd`, so the plugin cannot depend on an ai-toolkit
checkout to satisfy it. Environment-supplied paths were rejected because
they turn a build-time coupling into a runtime dependency on the repo the
script is leaving. The price of vendoring is two copies of three renderers
and four price helpers living in this repo permanently;
`scripts/script-analytics-selftest.sh` carries a drift guard that compares
the two implementations' behaviour so the copies cannot diverge unnoticed,
and that guard leaves with the originals.

`templates/claude-prices.tsv` stopped being one fixed relative path and
became a search: `$CLAUDE_PRICES_TSV`, `../templates/`, beside the script,
then the same two under `$CLAUDE_PROJECT_DIR`, with a validation error
naming every path tried when none exists.

`hooks/script-events-hook.sh` held a hardcoded
`$PROJECT_DIR/scripts/script-analytics.py` and failed open when it was
absent. That was already broken, not merely about to break: `plugin.json`
registers the hook for every installer, but it looked in the CONSUMING
project's `scripts/`, so it had only ever worked in this checkout and in
homelab, which happens to keep its own copy. It now resolves through a
chain and names every path it tried when nothing resolves. The general
lesson, third instance in one week: a migration must count `$PROJECT_DIR`
paths as a consumer surface alongside `${CLAUDE_PLUGIN_ROOT}` ones, and the
`$PROJECT_DIR` kind is worse, because it fails for consumers rather than
installers and a fail-open hook leaves no error behind.

**Provenance.** Decided and landed by an unattended session on 2026-09-22,
under NWM-156. Verified red-then-green and through the full CI set, but not
reviewed by the owner. Superseding it needs a later entry, not an edit here
(NWM-167).

### 2026-09-22 — parity-map.tsv rows are marked diverged, never deleted (NWM-158)

A pair that is known not to converge — two files sharing a name that an
owner decision settled as two different programs — gets a third
tab-separated column `diverged:<TICKET>` on its `templates/parity-map.tsv`
row, and `parity-sweep.sh` reports it in its own section, out of `drift` and
out of the exit code.

Deleting the row instead does not work, and this is the part worth
remembering because it is invisible from the map file. `parity-sweep.sh`
registers a row's source path as mapped BEFORE it compares anything, and its
`new` bucket is "files under a mapped source directory with no row at all".
Every path in this map lives under a mapped directory. So a deleted row's
source reappears immediately under `new`, which sets exit 1 exactly as
`drift` does: the false positive moves, it does not go away. Measured
against `../homelab`, not reasoned about.

Three edge cases are decided rather than left to the reader. A marker on a
row whose local column is `-` is a malformed map: `-` already claims the
file was never ported. A marked pair whose local file is MISSING stays in
`drift` and keeps setting exit 1, because deliberately different is not
deliberately absent. A marked pair whose files turn out IDENTICAL is flagged
in the diverged section as a possibly stale marker, visibly but without
changing the exit code — `drift`, `new`, `vanished` and `unmapped` keep the
contract that LAB-228's and NWM-125's verify blocks read.

Four rows carry a marker today: the two claude-cost rows (NWM-129, settled)
and the two rows mapping different homelab selftests onto one
`providers/publish/atlassian/selftest.sh` (NWM-161, an interim — that one is
a gap in the map's format, not a decision). The full 61-row audit found
nothing else. land-branch.sh is NOT marked: NWM-131 splits it behind a hook
contract rather than forking it permanently.

**Provenance.** Decided and landed by an unattended session on 2026-09-22,
under NWM-158. Verified red-then-green and through the full CI set, but not
reviewed by the owner. Superseding it needs a later entry, not an edit here
(NWM-167).

### 2026-09-22 — script-analytics.py and script-retire.sh left for ai-toolkit; the hook resolves them and pins its own price table (NWM-130)

The donate half of NWM-125. Both scripts and both selftests are deleted here
and consumed from moneymikeMD/ai-toolkit through two new modes on
`scripts/ai-toolkit-root.sh`, `--script-analytics` and `--script-retire`,
which now refuse rather than print a path a stale checkout does not hold.

`hooks/script-events-hook.sh` gained a fifth resolution step that asks that
resolver, because the four path candidates NWM-156 added all point inside
this repo and now find nothing. Without it the hook fails open and goes
silently dark — no error, no event, nothing to notice. That is the third
instance of this class in two days, so it is proved by observation rather
than by reading: with `scripts/script-analytics.py` absent from disk, a
SubagentStop payload through the real hook against a real ai-toolkit
checkout wrote a real event.

The hook also pins `--prices` explicitly, first of `$PROJECT_DIR/templates/`,
`$CLAUDE_PLUGIN_ROOT/templates/`, `../templates/`. The extractor's own search
resolves `<extractor>/../templates/` before `$CLAUDE_PROJECT_DIR/templates/`,
so with the extractor in ai-toolkit a `claude-prices.tsv` appearing there
would shadow this project's table and produce plausible, wrong numbers.
ai-toolkit deliberately ships none today, which is a convention, not a
guarantee. Proved by planting a 100x decoy in `ai-toolkit/templates/` against
a 10x table in the project: the event priced at the project's rate.

One consequence to know when running the moved script BY HAND: with
`$CLAUDE_PROJECT_DIR` unset the search finds nothing and it exits 2. Pass
`--prices templates/claude-prices.tsv` or export `$CLAUDE_PROJECT_DIR`.

**Provenance.** Decided and landed by an unattended session on 2026-09-22,
under NWM-130. Verified red-then-green and through the full CI set, but not
reviewed by the owner. Superseding it needs a later entry, not an edit here
(NWM-167).

### 2026-09-22 — release.sh is retired without keeping its tracker-outcome changelog, because that feature never produced a line

NWM-124 asked, before deleting `scripts/release.sh`, whether the one thing release-please cannot do — generating a CHANGELOG section from TRACKER OUTCOMES rather than from Conventional Commit subjects — was worth keeping as its own smaller tool.

It is not, and the reason is measurement rather than taste.

Three releases were ever cut with release.sh on this repo's history: `v0.7.0` (48ca184), `v0.7.1` (e995591) and `v0.7.2` (aae4ffc). Every section they wrote is hand-authored prose. None carries a ticket key, none carries a `cost:` line, and the placeholder the script falls back to — `(no tracker configured; add entries by hand)` — appears nowhere in CHANGELOG.md. The tracker-outcome path produced no changelog line in any of them.

It could not have. `docs/known-issues/release-sh-calls-the-tracker-fetch-verb-...` recorded on 2026-09-14 that the default path calls the tracker `fetch` verb with a since-tag while that verb takes an issue key, gets HTTP 405, silences the error and degrades. `v0.2.0` was cut with a hand-built `--tracker-fetch` scratch script that no longer exists.

The `cost:` lines in the pre-0.8.0 sections are not evidence to the contrary: those sections arrived wholesale in `b765642`, the squashed initial commit of the public repo, and 41 of the 43 `cost:` lines in the file read `UNVERIFIED`.

What actually carries ticket provenance today is the commit subject. This repo names the ticket in the subject — `fix: count Workflow-tool subagent transcripts, not just Agent-tool ones (NWM-152)` — so release-please's generated sections already link each entry to its ticket and its commit. The thing release.sh was supposed to add was already arriving by a route that works.

So: no replacement tool, no release-notes fragment generator, nothing kept. If ticket-outcome prose is wanted later it should be built against a tracker verb that exists, which is a different piece of work from preserving this one.

### 2026-09-23 — land-branch.sh becomes a wrapper over ai-toolkit's land-core.sh, and is its own hook (NWM-131)

`scripts/land-branch.sh` stays here, at the same plugin-root path, and is now a wrapper: its preflight (argument checks, ticket resolution, tracker status, closing-state gathering, the plan) runs first, and then it hands the merge, the lint gate, the push and the branch cleanup to ai-toolkit's `scripts/land-core.sh`, passing itself as land-core's `--hook`. The four hook points carry the lifecycle: pre-merge does the Awaiting Deployment move, post-merge builds the closing state and re-resolves a file ticket against the merged tree, pre-push commits the file tracker's completion (so it is inside the pushed history), and post-push completes the Jira issue, writes the closing state, notifies, and tears down the herdr workspace. `--already-merged` calls no core and runs the same phase functions inline.

State crosses the process boundary through one mode-600 temp file: the wrapper writes its preflight values as `%q` assignments, each hook sources it and appends what it changed, and the wrapper sources it again once land-core returns. That file is also how land-branch.sh keeps its own exit codes where land-core's differ. A failed Awaiting Deployment POST was exit 1 here, and a pre-merge hook refusal is exit 2 in land-core, so the hook records `WRAPPER_RC` and the wrapper exits with that.

land-core is resolved at run time by `scripts/ai-toolkit-root.sh --land-core`, the same way as known-issue.sh (NWM-128). It is not vendored and not pinned. The cost is an adopter cost: a marketplace installer now needs an ai-toolkit checkout or `$AI_TOOLKIT_ROOT` to land anything, and gets exit 2 naming both when neither resolves. The two `${CLAUDE_PLUGIN_ROOT}/scripts/land-branch.sh` references in `skills/session-start/SKILL.md` keep pointing at the wrapper. The plugin-root check was run, and it found nothing to reroute.

Two behaviour changes come with the move. `LAND_BRANCH_COAUTHOR` and `LAND_BRANCH_SESSION` are gone (decision item 4), so no trailer is ever written. `--lint-cmd` now runs through `bash -c`, which closes the word-split known issue: a word-split `true && false` passes, which means a red lint could land.

One gap belonged to land-core's contract: its branch-worktree clean check could not exempt `.night-watchman/closing-state.md`, which NWM-147 exempts here because the worker brief requires it to exist uncommitted. NWM-175 added `--allow-untracked PATH` to land-core.sh (ai-toolkit 7f9e456, PR #57), which ignores only an exact `?? PATH` porcelain line; a staged or modified copy, or any other untracked file, still refuses. land-branch.sh passes `--allow-untracked .night-watchman/closing-state.md`, and land-branch-selftest test33 is green again.

### 2026-09-24 — script-events-hook.sh drops the project-dir extractor step and greps a sentinel line before invoking (NWM-160)

Owner decision 2026-09-24, choosing both of the ticket's fix candidates over accepting the residual. The consuming project's own scripts/script-analytics.py is no longer a candidate in hooks/script-events-hook.sh's chain: this hook is registered for every installer, so a repo carrying a same-named stranger would otherwise have it run with the hook's argv. Whatever the chain resolves is invoked only if the file carries the line '# script-analytics-extractor-sentinel: v1', which ai-toolkit's script-analytics.py now does (ai-toolkit PR #58). The check is a grep rather than the known issue's original '--help prints a marker' candidate, because executing an unknown file to ask whether it is the extractor is the hazard the check exists to close. The stale-extractor residual NWM-160 also recorded is moot: after NWM-130 neither this checkout nor the installed plugin carries a copy, so the chain ends at ai-toolkit's for everyone. Resolves the 2026-09-13 known issue.
