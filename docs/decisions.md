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
