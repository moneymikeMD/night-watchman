# Decisions — the "why" behind how things are

**GENERATED — do not hand-edit.** Produced by `scripts/decisions.sh index`
from the frontmatter and body of every file in `docs/decisions.d/`. Add an
entry with `scripts/decisions.sh add --title T --body B`, which writes the
file there and reindexes for you. `scripts/decisions.sh lint` fails if this
file ever drifts from what `index` would produce.

One file per decision. An entry states the decision and the reasoning that
still holds, as the current state of the world; a decision that no longer
holds is deleted, not annotated, and its replacement stands on its own.
The point is a fresh session (or a fresh agent) can read this file
top-to-bottom and see not just what was decided but why.

Newest entries at the bottom. Each entry: a date, one line naming the
decision, then the reasoning that led to it — the constraint, tradeoff, or
incident that made one option win. A decision with no reasoning is a
fact, not a decision, and belongs in a `docs/` topic file instead — see
`tickets-protocol`'s routing table.

Add an entry only when all three gates hold: costly to reverse, a future
reader would be surprised without it, and real alternatives were weighed.
Otherwise it is a fact for a topic file, or nothing. Rejected alternatives
worth remembering stay as cancelled tickets with an outcome, not an entry
here.

## Log

### 2026-09-14 — Every capability lands as a provider-neutral contract first

Owner directive: "do everything homelab can do, but written in a generic
way so other tools can implement the interface." homelab, the project this
plugin was extracted from, is the first *provider* of every kind, never the
shape of the contract itself.

Reasoning: a parity audit that only diffs rows already in
`templates/parity-map.tsv` can report drift on a row someone thought to
add, never a capability nobody mapped. A bottom-up walk over the source
project's own orchestration surface (every script, agent, skill and hook
referenced from its CLAUDE.md, skills, agents, settings and docs),
classified as PORTED / PORTED-DRIFT / UNMAPPED GAP / SOURCE-SPECIFIC, is
what finds the unmapped ones.

Decision: the map is the classification *store*; the source of truth for
what exists is the enumeration walk. `scripts/parity-sweep.sh --source-root
DIR` runs it as a fourth pass, with `templates/parity-allowlist.txt` naming
the SOURCE-SPECIFIC lab-infra capabilities (host/media/network ops, TrueNAS,
Proxmox, Grafana, Caddy) this plugin does not generalise. Porting any gap the
sweep finds is its own ticket.

### 2026-09-14 — Jira enforces the field gates; scripts keep the cross-ticket gates

Owner decision: adopt four Jira-native rules — `system:validate-field-value`
for a non-empty `verify` on To Do→In Progress and on every transition into
Completed, the same validator for a non-empty `touches` on To Do→In
Progress, `system:previous-status-validator` (must have been In Progress) on
every transition into Completed, and one Automation scheduled rule that
returns Deferred tickets to To Do once `defer_until` has passed. `touches`
is required for every ticket, not only agent/mixed ones: Jira cannot
condition a validator on another field, and every ticket is created through
the agent anyway.

Reasoning: Jira's workflow capabilities are field, previous-status, parent
and permission validators, field and subtask conditions, webhook
post-functions and GitHub triggers, and no rule at all on linked issues. So
`blocked_by`, `touches` collisions between startable siblings, and `mixed`
needing `human_steps` stay in `issues.py` and land-branch; Jira takes the
two field gates and the status-order gate, which catch a hand-filed ticket
at transition time. Automation is post-hoc and is used only where reacting
late is fine (deferral expiry). Automation execution caps on this plan are
UNVERIFIED.

Implementation: an additive rules spec applied through
`providers/tracker/jira/jira-workflow-apply.sh`, rehearsed on a scratch
project with recorded fixtures. The Automation rule is a UI step.

### 2026-09-14 — Ticket status mirrors the real lifecycle, and the scripts drive it

Owner rule: a ticket is In Progress from the moment it is dispatched (or a
workspace/pane is created for it), Awaiting Deployment before landing, and
Completed after landing. No step is skipped, ever, and no step is done by
hand except to repair one the scripts missed.

Reasoning: the previous-status validator on Completed refuses a landing that
jumps from In Progress straight to Completed, and it is right to. Awaiting
Deployment is the state "merged but not yet proven", and land-branch's push
is the deploy, so it is a mandatory stop even for tickets with nothing else
to deploy. Dispatch start and land-branch drive the three transitions
through the tracker seam, resolved by target status.

### 2026-09-15 — Commit attribution is the owner's alone; AI-attribution trailers are opt-in, not required

Owner rule: every commit and PR, on every machine, is attributed to Mike
Garrett alone. `scripts/land-branch.sh` writes no `Co-Authored-By` or
`Claude-Session` trailer and has no switch that adds one.

Reasoning: a landing script that refuses to land unless attribution
variables are provisioned blocks landing on any machine that has not set
them, and provisioning them would run counter to the attribution rule
itself. Attribution is a property of the owner, not of the tool that
merges.

## 2026-09-18 — GitHub repo hardening: CI on macOS, release-please, a ruleset that points at a branch that exists

Both branch rulesets target `~DEFAULT_BRANCH`, never a literal branch name,
so a default-branch rename cannot silently unprotect `main`.

Ruleset shape: deletion and non-fast-forward blocked for everyone
(`protect_main-1`, no bypass); linear history, a code-owner-reviewed pull
request and the required checks `selftests`, `docs-site` and `comment-lint`
(`protect_main-2`), with the built-in repository-admin role (`actor_id: 5`)
bypassing always. That combination is deliberate — `scripts/land-branch.sh`
pushes merge commits straight to `main` and must keep working, while an
outside contributor's PR is gated on review and green CI. Verified by
pushing to `main` after the rules went live rather than by reading the
documentation.

CI runs on `macos-latest`, not `ubuntu-latest`. This repo targets bash 3.2 —
the `/bin/bash` every macOS ships — and its scripts are written to that
limit deliberately. A Linux runner's bash 5.x would pass code that breaks on
the machines this actually runs on.

Two selftests run in a separate informational step rather than gating
(`providers/config-selftest.sh` and
`providers/tracker/jira/jira-workflow-apply-selftest.sh`): each fails one
assertion for a filed reason. Quarantining them by name keeps `main`
honestly green while leaving a second failure in the same suite visible.
Each moves back into the gating step when its known issue is resolved.

Versioning is release-please's, bumping `.claude-plugin/plugin.json`. It
needs a one-time Actions permission grant from the owner's own terminal
("Read and write permissions" plus "Allow GitHub Actions to create and
approve pull requests"); without it the action creates its release branch
and then fails to open the PR.

### 2026-09-18 — known-issues is one file per entry with a GENERATED index

`docs/known-issues/` holds one markdown file per finding, and
`docs/known-issues.md` is an index rendered from their frontmatter by
ai-toolkit's `known-issue.sh reindex` (resolved through
`scripts/ai-toolkit-root.sh --known-issue`). Neither is hand-maintained as a
pair.

Reasoning: a single hand-edited `known-issues.md` holding both the prose for
every finding and a hand-maintained index table has two failure modes. Two
agents editing different entries collide on the same file. Worse, the index
drifts from the bodies it summarises — a heading gets edited and its index
row does not, or an entry is added and its row never written, so the entry
becomes invisible in the table with no error and nothing to notice it by.

A generated index cannot lose an entry: `reindex` either lists every entry
file or does not run at all, and `lint` fails when `docs/known-issues.md` is
not byte-identical to what `reindex` would produce right now.

## 2026-09-19 — E6 sequencing: migrate the cost scripts first, then make them model-aware in ai-toolkit

NWM-119 (record the orchestrator's model and effort per wave, so the ledger
shows what Fable costs against Opus-at-high-effort) and NWM-129 (move
`claude-cost.py` and `claude-cost-scan.py` to the public `ai-toolkit`)
change the same file.

Owner decision: migrate first. NWM-129 lands, and NWM-119's change is made
in `ai-toolkit` against the migrated script; NWM-129 blocks NWM-119.

The reasoning is that NWM-119's change is to the generic half. Reading a
transcript's model and effort metadata and splitting spend per model is
something any repo running Claude Code sessions wants; it is not a
night-watchman feature. Doing it here first would mean writing generic code
into a private repo and then moving it a ticket later, the same mistake
NWM-126 corrected for `comment-lint.py`. What stays here is the product
half: the ledger file, `docs/cost.md`'s prose, and the `cost-reviewer`
agent.

### 2026-09-19 — NWM-123 was undispatchable because its contract lived in prose, not in fields

A ticket whose `verify:` and `executor:` are written as prose in the body
while the structured fields are empty is permanently undispatchable and
looks fine: `issues.py` reads the fields, `issues.py lint` reports the
project clean because an empty field is not a lint error, and the only
tool-side net (no executor means never startable) prevents a bad dispatch
while staying silent about the stranded ticket. NWM-123, captured from a
conversation reported across from homelab's LAB-241, sat in exactly that
state until both were lifted into their fields.

The rule that follows: a ticket captured from a conversation carries its
contract as fields, not sentences, and a verify clause asserts stderr as
well as exit codes and includes a case the fix could not pass by refusing
everything — the failure mode a guard fix is most likely to have.

## 2026-09-19 — land-branch.sh splits: a git merge-and-push core moves to ai-toolkit, the lifecycle stays as a night-watchman wrapper

NWM-127 asked whether `scripts/land-branch.sh` is generic enough to move to
`ai-toolkit`. Outcome: **split**. A generic core (integration worktree,
lock, `merge --no-ff` with ORIG_HEAD revert, lint gate, push, branch
cleanup) moves; the ticket lifecycle, both tracker backends and the herdr
teardown stay here as a wrapper that calls it. NWM-131 is the extraction.

Two premises in the ticket did not survive reading the script. It does not
call the tracker provider seam: it takes a wrapper path (`--jira-api`) and
never invokes `providers/lib/provider.sh`. It has no `issues.py lint` hook:
the lint step runs `--lint-cmd` or `./scripts/lint.sh` in the target repo,
and this repo has no `scripts/lint.sh`, so here the step is skipped with a
warning. The lint hook is already generic.

### Why split, not the other two

**Move whole, parameterised.** Rejected. Making the lifecycle configurable
means three Jira status ids, a five-directory file layout, a frontmatter
schema and a herdr teardown all become flags of a public tool. The operating
model would ride in as configuration, which is the outcome the ticket set
out to avoid, and every consumer would carry flags for trackers it does not
have.

**Keep here, strike from the migration list.** Rejected on measured evidence
of a second consumer: homelab's `scripts/dev/land-branch.sh` is a
1402-line fork of the same skeleton (integration worktree, lock, merge, Jira
window, herdr exit) that carries the same class of fix independently
(SIGPIPE under pipefail, exit codes on pre-flight refusals). That is the
duplication a shared core removes.

**Split.** Wins because the seams already exist in the control flow: the
script has exactly four points where tracker or dispatch code runs (before
the merge, after the merge, before the push, after the push), and the
failure semantics at each are already different and well defined (nothing
to revert; revert the merge; landing stands, report exit 1).

### 2026-09-18 — closing state: durable write first, bounded ack second (NWM-120)

A worker's exit is a handoff. `land-branch.sh` with `HERDR_ENV=1` writes the
worker's closing state to the tracker and reads it back before it ends the
worker's session, and only then notifies the orchestrator.

**Durable write before orchestrator ack.** An orchestrator can be mid-turn,
compacted or closed, so making it the system of record reproduces the
failure where a durable write never happens. The tracker survives; the pane
message is a courtesy.

**A missing ack degrades, it does not block.** A hung worker must never
block landing. The notification waits `LAND_BRANCH_ACK_WAIT_S` (default 10)
for the ack file it names, and a miss is a warning. A failed durable write
is the opposite case: exit 1, the worker's pane and workspace are left in
place so its output survives, and the landing is not reverted.

**Missing run list is refused early.** A human- or mixed-executor ticket
with no `## Human run list` in the worker's
`.night-watchman/closing-state.md` stops the landing at exit 2 before
anything is mutated, because a promised-but-absent run list is the defect.
Only under `HERDR_ENV=1`; without it the script is unchanged.

### 2026-09-19 — the extraction bar has two triggers, not one, and the ticket contract leaves for `work-order`

`docs/ethos.md`'s extraction default — a measured second consumer is the
bar for extracting a shared core — was written for de-duplication, and
de-duplication is the only signal it can see. Applied to the ticket-contract
layer it gave the wrong answer: switchtender has no `issues.py` and no
ticket tooling at all, so by the letter of the rule the extraction was
speculative. The owner supplied the fact that reverses it: every repo he
works in already assumes a tracker space, tickets, and a sprint wrapping
bounded work, and none of them owns that assumption. That is the inverse of
duplication and it costs more, because nothing drifts visibly — the thing
simply is not there, and no diff shows an absence.

**The rule.** Either trigger is enough on its own: a measured fork, or a
universal assumption no repo owns. Absent both, an extraction is
speculative work.

**The decision set**, settled in five rounds of grilling on 2026-09-19
(memory-graph `96a41a7a-3044-428c-aa0e-66644fd3aa2f`, filed as the WO
project in Jira):

1. Extract now, and rewrite the ethos default that said otherwise.
2. The deliverable is a specification — schema and protocol. `issues.py` is
   the reference implementation, not the product.
3. The name is `work-order`.
4. Its own public repository, MIT throughout.
5. The sprint mechanism is an optional documented extension, not core.
6. It ships spec, reference implementation, runnable conformance validator
   and fixtures. The validator is the teeth.
7. One repository, Claude Code plugin included. No package registry until
   an outsider asks for one.
8. The core is tracker-agnostic, with normative bindings: a file binding
   and a Jira binding. The six Jira custom fields become the Jira binding.
9. The Jira binding is a separately versioned package in the same
   repository, and it owns provisioning, because "provision me a conforming
   Space" is what makes a standard adoptable rather than admirable.
10. The spec versions independently of both packages — three version lines
    from one repository, so "conforms to work-order spec 1.0" stays stable
    while the implementations churn.
11. Conformance is MUST/SHOULD levels plus named profiles: minimal, full,
    unattended. The profiles map onto the layer split.
12. night-watchman depends on `work-order` and deletes its copies. No
    vendored fork. It keeps layer 2 only: dispatch, waves, session-start,
    the land-branch lifecycle, closing-state handoff, wave-trail.
13. `work-order` defines the profile names, including `unattended`, under a
    hard test: `unattended` must be writable purely as what a ticket needs
    to start cold with no human. If it cannot be written without naming
    night-watchman behaviour, it does not belong in the spec.
14. `to-issues` splits in two. The seam is a documented structured decision
    list: night-watchman mines the conversation and emits it, `work-order`
    consumes it and emits conforming tickets. Testable from both sides.
15. No retroactive conformance. New and touched tickets conform; existing
    LAB, NWM and CMB tickets are grandfathered under the touched-ticket and
    active-sprint lint scoping.
16. All three repositories convert in one wave.

The reframing behind this is three layers: a ticket is a contract an agent
can execute (tracker-agnostic, the reusable idea, `work-order`); a session
runs unattended (the differentiator, what night-watchman is); the provider
and plugin system (the extension mechanism).

**The boundary rule does not apply to `work-order`, deliberately.**
homelab's LAB-275 sorts shared tooling by one test: does a machine apply it,
or does a repo call it? Machine-applied goes to the private dotfiles repo;
repo-consumed goes to the public `ai-toolkit`. Read literally, a spec plus a
reference implementation that repos consume would land in `ai-toolkit`. It
does not: that rule sorts internal shared plumbing for this owner's own
repositories, and `work-order` is a public product aimed at strangers — a
different audience, a different cadence, its own independently versioned
spec, and a conformance validator outsiders run against implementations
that are not ours. Folding it into `ai-toolkit` would tie a product's
release line to a plumbing repository's moving `@v1` major tag, which is
exactly what decision 10 exists to prevent. `ai-toolkit` remains the default
for shared tooling; `work-order` is the documented exception, not a
precedent.

### 2026-09-19 — WO-002 spike: plugin dependencies are real and enforced, but a clean exit code does not prove the pin held

Measured first-hand on the Mac against Claude Code 2.1.278, using two
throwaway local-folder marketplaces and four scratch plugins; no real
marketplace was touched.

**Plugin dependencies are real.** `.claude-plugin/plugin.json` takes a
`dependencies` array whose entries are either a bare plugin name or an
object of `name`, `version` and `marketplace`. Installing a dependent plugin
alone installs its dependency (`(+ 1 dependency: ...)`). One repository can
publish several plugins on independent version lines through one
`marketplace.json`, tagged `{plugin-name}--v{version}`; `claude plugin tag`
derives the tag from the manifest and refuses when `plugin.json` and the
marketplace entry disagree.

**The semver constraint is enforced, not decorative.** With the marketplace
advertising `2.0.0` and tags at `1.0.0`, `1.1.0` and `2.0.0`, a dependent
pinning `^1.0` resolved to `1.1.0` — the highest tag satisfying the range —
and skipped the newer copy. The recorded version carries a commit-SHA suffix
(`1.1.0-767ec7e66eeb`), so a force-moved tag gets a fresh cache directory
rather than stale content.

**Disable is refused, and the refusal is machine-readable.** Disabling a
dependency while its dependent is enabled fails with exit 1, `failureCode:
"required_by_dependents"`, a `reverseDependents` array, and a chained
command that disables the pair in the correct order. Enabling is symmetric.
`claude plugin prune` tracks auto-install provenance and lists only orphans.

**The trap.** An unsatisfiable constraint does not reliably fail the
install. When another *installed* plugin already constrains the same
dependency and the ranges do not intersect, the install hard-fails (exit 1,
`failureCode: "dependency_version_conflict"`). When nothing else constrains
it and no tag satisfies the range, a plugin the marketplace references by
relative path installs the marketplace's *current copy* instead and reports
`outcome: "ok"` with exit 0; the violation appears only in the `errors`
field of `claude plugin list --json` (`Requires "core@mkt" ^9.0, installed
2.0.0`). A blocked cross-marketplace dependency behaves the same way:
`outcome: "ok"`, exit 0, dependency not installed,
`dependency-unsatisfied` visible only in `errors`. A failed install also
leaves an entry behind with `enabled: true`; `enabled` is the configured
flag, not the effective load state.

So a zero exit from `claude plugin install` is not evidence that a version
pin was honoured or that a dependency arrived. Anything gating on dependency
resolution asserts on the `errors` field, not on the exit code.

**Cross-marketplace dependencies need an allowlist.** By default they are
blocked. They work only when the root marketplace — the one hosting the
plugin being installed — carries `allowCrossMarketplaceDependenciesOn`
naming the target marketplace. night-watchman and work-order both publish
through `moneymike-plugins`, so the dependency here is not cross-marketplace.

**Two validator limits.** `claude plugin validate --strict` recognises
`dependencies` (it proposes it as the correction for a typo'd field name)
but does not check that a `version` string is valid semver: `"not a semver
range !!"` passes strict validation. Range syntax errors surface at install
or load, not in CI.

Not measured: whether a plugin carrying a dependency error fails to load in
a live session, and dependency resolution from a real remote GitHub
marketplace. Local-folder marketplaces resolve tags only when the folder is
a git repository.

## 2026-09-19 — WO-026: the Workflow tool becomes the default `dispatch` implementation, herdr becomes the fallback

`providers/dispatch/` was a provider-neutral contract with exactly one
implementation, herdr, which made the seam an argument rather than a tested
design. Claude Code's Workflow tool runs subagents in-process under a
deterministic script; the 2026-09-19 work-order wave ran that way — seven
tickets, fourteen agents, nothing above the dispatch seam changed, and zero
dispatch failures against three standing herdr dispatch bugs on the other
path (the cold-boot brief swallow, the reached-working wait failing on
back-to-back starts, the folder-trust dialog in a fresh worktree).
`providers/dispatch/workflow/` is the built-in default.

**herdr is the fallback, not deleted.** It serves what the Workflow tool
does not: a human-visible pane during a supervised run, a session that
outlives the orchestrating turn, and anything needing a real terminal.
Removing it would trade one single-implementation contract for another;
the value of the seam is that it carries two.

**The three herdr dispatch known-issues stay open on their own merits.**
Off the critical path, what the fallback is worth is a separate decision.

**The verbs do not map one-to-one, and the difference is declared rather
than approximated.** A subprocess cannot call an in-process tool, so the
provider owns the deterministic half — compose, record, report — and the
orchestrating turn owns the Workflow launch and the `TaskStop`. `start`
composes the brief and records the launch request; it opens no pane,
creates no worktree (the brief tells the agent to make its own), and writes
nothing to the tracker. `stop` records a stop request and names the
`TaskStop` to issue. `watch` is the verb that genuinely does not map:
herdr's is a live pane plus a blocking wait, and the Workflow tool's
equivalents — a task notification and a journal — are delivered to the turn
holding the tool, never to a subprocess it spawned. So `watch` promises
exactly one thing, the state recorded in the run journal at the moment it
is asked, and `--until`/`--timeout` are refused by name. Accepting them
would produce a wait that could only ever time out. A provider that silently
means something different is worse than one that declares a gap; the gap is
written in `providers/README.md` next to the contract.

**The run journal lives outside the repo**
(`$XDG_STATE_HOME/night-watchman/dispatch-workflow` by default). An
untracked file inside a worktree dirties it, and `land-branch.sh` then
refuses before reading anything.

`templates/night-watchman.config.toml` selects `workflow` too, because
`providers/config-selftest.sh` asserts the template's selection for every
kind equals the built-in default. This repo's own
`.night-watchman/config.toml` and the owner's `~/.config/night-watchman/nwm.toml`
select `workflow`.

## 2026-09-19 — Bare `cd <repo> &&`/`;` Bash prefixes replaced with `-C`/`--repo` (WO-034)

Baseline measured over the full transcript corpus on 2026-09-19 (WO-033,
memory `c3a3f04e`): 3,561 Bash calls carried a leading `cd` that no tool
needed — `cd .../homelab && …` (2,349 calls, avg 682 chars), `cd
.../homelab; …` (1,212 calls, avg 580 chars), and `cd .../night-watchman &&
…` (425 calls, avg 892 chars). 199 `git -C …` calls already existed in the
same corpus, so the alternative was in use, just not by default.

The owner's `~/.claude/CLAUDE.md` states a substitution table (`git -C`, `gh
--repo`, a script's own path argument, or `( cd … )` as the catch-all
subshell) instead of a bare prohibition — a prohibition with no named
alternative gets ignored — and states the cost inline: a bare `cd` mutates
the session's cwd for every later call, and that drift causes
`guard-fs-writes.sh` false positives on writes that resolve outside the
current worktree.

A PreToolUse hook that rewrote the `cd` prefix automatically was considered
and deferred: it would sit beside `rtk-rewrite.sh`, which already rewrites
every Bash command, and a rewriter on that seam has already produced guard
false positives. A second rewriter there is something to earn with evidence
from a re-run of the WO-033 report against this baseline, not assume up
front.

### 2026-09-19 — WO-035: memorygraph gets a typed MCP dispatcher, not a bundled server

`memorygraph` is the second-highest-volume Bash family in the corpus — 744
`recall` calls averaging 124 characters, 622 `store` calls averaging 1,427
characters (WO-033, memory `c3a3f04e`) — every one a long shell string
wrapping a payload that is already structured data. Two failure modes come
directly from that shape: a multi-word `recall` silently returns nothing
(`--query "jira api auth"` finds zero; `--query "jira"` finds six), and a
`store` with a 1,400+-character payload through `--content` can fail on
shell quoting and succeed on a bare retry of the same content.

Decision: `dotfiles/dot_claude/mcp/memory/` is a thin MCP server dispatching
`recall`/`store`/`link`/`related`/`briefing` to the `memorygraph` CLI as
argv arrays, never a shell string, and holding no graph logic of its own.
`recall` rejects a multi-word `noun` outright instead of returning an empty
result set; `store` validates `type` against the CLI's real 13-value enum
and `link` against the three relationship types that work (`SOLVES`,
`CAUSES`, `CONTRADICTS`), both before the CLI is invoked. Registered per
project through that project's own `.mcp.json`, never in
`~/.claude/settings.json`.

Reasoning: this does not reverse memorygraph's own v0.14 decision to drop
its bundled MCP server for shell invocation — that removed a coupling
*inside the product*; a thin local dispatcher over the published CLI
reintroduces none of it, since the CLI stays the interface and deleting the
server leaves every existing call site working. The guards are the point,
not the typing: converting the multi-word-recall rule from prose a caller
has to remember into something that cannot be got wrong is the enforcement
ladder's top rung applied to a rule that was sitting on its bottom rung.
`store` gains no convenience beyond the schema — no auto-tagging, no
inferred type — because guessing metadata is how a graph fills with entries
nobody trusts. The server never reaches FalkorDB directly: backend
selection, credentials and the off-LAN fail-closed behaviour all live in
the CLI's own environment contract, and duplicating that here is how the
two diverge.

Out of scope, deliberately: changing `memorygraph` itself, or upstreaming
the multi-word-recall behaviour as a fix there; auto-recall on session
start.

### 2026-09-19 — MCP sits beside rung 1 as a surface, not a fourth rung (WO-030)

`skills/capability-ladder/SKILL.md`: a script can carry a typed, callable
MCP surface without becoming a new rung. Placed beside rung 1, not above or
below it — above would say MCP holds judgement, which it doesn't; below
would say it replaces the script, which it must not, since a server that
owns behaviour can't be retired without a rewrite. The script stays the
artifact; MCP is only its signature — schema-validated parameters, call by
name, a distinct `tool_name` in tool analytics.

Two premises that would close this question off are false. An MCP server
needs no deployed backend — a local stdio process shelling out to `gh`,
`git`, or `docker` is ordinary. And tool schemas are not a per-turn context
cost in this harness: they're deferred, so an unused tool costs one name in
a list, not a schema; the dominant cost of a crowded tool list is choosing
the wrong tool, not token count.

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
laundering hazard is named in the skill itself: a tool that reaches an
action its script can't, or carries a flag bypassing a check the script
enforces, is a permission bypass wearing an interface.

### 2026-09-19 — WO-037: ship About/Learning/Risk/Decision as four named verbs, not a `mutate` passthrough

The Home Projects fields that carry the *reasoning* behind a status
(Learning, Decision, Risk, About) have no REST fallback (memory `8238ce2c`),
and this workspace's operating model produces exactly those artifacts
(decision entries, known-issue resolutions, per-wave learnings).
`townsquare.sh` ships them as four named verbs (`about`, `learning`,
`decision`, `risk`), each mirroring `update`'s own read/write discipline,
rather than one free-form `mutate` passthrough: a passthrough would make
every future field free but also make an arbitrary GraphQL mutation against
the live site one typo away. `mutate` stays unshipped.

`learning`/`decision`/`risk` take only `<project-ari> -`, unlike homelab's
`atlassian-graphql.sh` which also takes a separate `<summary>` shell
argument. The short plain-text `summary` these three mutations require is
derived from the first line of stdin, with the whole text ADF-encoded into
`description` — one input channel instead of two, at the cost of the summary
and the body's first line always matching.

Every mutation ships with a fixture recorded from a real call, because a
guessed GraphQL shape is worse than no entry:
`fixtures/townsquare/{learning,risk,decision,about}.*.json` are the LAB-180
spike's verified recordings from
`homelab/scripts/fixtures/atlassian-graphql/` (the throwaway
`ZZPROBE-tabs-fixtures-2026-09-11` project, never the real Homelab
project). Two facts from that spike this implementation depends on:
`description` requires ADF the same as `update`'s `summary` does (a plain
string is rejected, naming the field), while `summary` on
Learning/Risk/Decision is the one exception and is sent as plain text; and
Risk/Decision's created id carries the ARI type segment `learning`
regardless — the server's own inconsistency, not a bug.

### 2026-09-19 — WO-039: check known-issues and memory-graph before reporting broken — shipped as prose, which the trace-flag rule already showed can fail

An agent reporting something as broken, denied, or unexplained when the
answer is already on disk — a `docs/known-issues/` entry, or a merge status
the primary source disproves — is a lookup-before-reporting problem, not a
diagnosis problem, and the lookup is one `grep` and one `memorygraph
recall` away.

One precondition, phrased on reporting rather than diagnosing, lives in the
three places an agent's working contract comes from:
`templates/dispatch-brief.md` (the only one that reaches a dispatched wave
worker's own prompt), `templates/CLAUDE.md` (for sessions that never go
through dispatch), and the owner's dotfiles `CLAUDE.md` (its memory-graph
trigger list names `docs/known-issues/` beside it).

This ships as prose, and that is a known-weak choice. The trace-flag
prohibition is the same shape of rule — capitalized, in a brief, with its
exact consequence spelled out — and an agent with that exact paragraph in
its own brief still ran `zsh -x` while debugging a verify line, leaking
`OP_SERVICE_ACCOUNT_TOKEN` and `MEMORY_FALKORDB_PASSWORD` into the
transcript (memory-graph, tag `wo-042`). A rule read minutes earlier did
not survive a debugging shortcut under time pressure, and there is no
reason to expect this one to fare better for being written more
emphatically.

A structural version is the stronger option and is not built. The nearest
precedent is `guard-fs-writes.sh`, which stops an out-of-worktree write
mechanically — a hook on the report/hand-back path could `grep
docs/known-issues/` for the reported symptom before a BLOCKED or "reporting
broken" status is accepted. It is not built because there is no reliable
machine signal for "this text is reporting a failure" comparable to the
redirect-target signal the guard checks; building that detector well enough
to avoid false positives is its own piece of work. Revisit this, including
possibly reverting the prose version, if recurrence shows prose does not
hold here either.

### 2026-09-20 — WO-010: night-watchman depends on work-order v1.3.0 and deletes its own ticket-contract copies

night-watchman does not carry the ticket contract. `.claude-plugin/plugin.json`
declares `work-order ^1.3.0` from the `moneymike-plugins` marketplace, and
this repo has no copy of `issues.py` or of the frontmatter reference.

**How a dependent finds a dependency's files.** `${CLAUDE_PLUGIN_ROOT}`
names only the plugin that is executing and cannot reach a sibling, so
`scripts/work-order-root.sh` resolves the location at runtime:
`$WORK_ORDER_ROOT`, then the `.installPath` of the `claude plugin list
--json` entry whose `.id` is `work-order@moneymike-plugins` (there is no
`.name` field to key on), then a work-order checkout beside the plugin. The
third is not a nicety — a plugin loaded from a local checkout has no
plugin-list entry at all, so without it every instruction file here breaks
for anyone running from a checkout. Each candidate must actually hold
`reference/issues.py`, so a stale `installPath` is not trusted.

**Exit 0 is not the evidence.** A blocked or unsatisfied dependency still
reports `ok` and exits 0, recording the violation only in `errors` (the
WO-002 entry), so proof of the dependency is the plugin-list entry with
`errors: null` and the installed tree holding `reference/issues.py`. CI
clones the newest `v1.*` tag resolved at run time rather than pinning a
literal that would go stale, and `scripts/land-branch-selftest.sh` takes
its `issues.py` from the same resolver.

Not deleted: `skills/to-issues/assets/ticket-template.md`. work-order ships
`SPEC.md`, `bindings/file/BINDING.md` and example tickets, but no bare
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

`hooks/guard-fs-writes.sh`'s scanner is re-entrant through bash's own
`local`, not a hand-rolled frame stack. Each of `scan_command_text`,
`scan_segment` and `scan_dollar_parens_in_word` declares its per-call state
with `local` at the top of the function. `local` in bash is DYNAMICALLY
scoped, not lexical: a helper called from the declaring function sees and
writes the declaring function's copy, and a recursive re-entry gets a fresh
copy with the outer one restored on return — exactly the property a frame
stack (`_frame_push` / `_frame_pop`, hand-maintained `_*_FRAME_VARS` name
lists, a wrapper/`_body` split per scanner) exists to provide, at −74 lines.

**The specific risk.** `local` would be wrong if a helper called from one of
these bodies relied on a global outliving the declaring function's return.
Every cross-function use of a scanner variable is inside the declaring
function's dynamic extent: `tokenize_quoted` writes `_ss_words` and is
called only from `scan_segment`; `split_unquoted_segments` writes
`_sct_seglist` and is called only from `scan_command_text`, which reads it
on the next line; `_ss_opaque_push` / `_ss_opaque_pop` are reached only
through `scan_segment`. `_AC_NAMES` / `_AC_VALUES` are append-only across
the whole invocation and were never frame-saved; nothing about `local`
touches them.

**Why `local` wins, and not a tie.** Timing is indistinguishable on the
common path (both dominated by the `jq` and `git` subprocess startups) and
about 19% faster for `local` on a pathological four-deep nesting, because a
frame stack's per-call save/restore over ~34 names in indirect expansion
and `eval` is the one part of the scanner that is not subprocess-bound. What
decides it is that a frame stack's variable lists are maintained by hand
and nothing checks them: a loop variable omitted from a list is latent
until a later edit adds a re-entrant call under that loop, and nothing in
the repo distinguishes the latent omission from a live one. With `local`
the declaration sits at the top of the function it belongs to and bash
enforces it.

**The oracle that discriminates.** The behavioural assertions in
`hooks/guard-fs-writes-selftest.sh` pass against both shapes, so they
cannot tell them apart. Three static assertions do: every `_ss_` / `_sct_`
/ `_sdp_` variable assigned anywhere in the hook is declared `local` in its
owning scanner, none is assigned at file scope, and `tokenize_quoted` /
`split_unquoted_segments` are called only from the scanner whose `local`
they write. A copy with one `local` name removed fails exactly that
assertion and nothing else, which is the drift this design has to survive.

**Left in place deliberately.** The `_SS_OPAQUE_STACK` push/pop pair is
redundant under `local` — a nested `scan_segment` gets its own
`_ss_opaque`, so it can no longer clobber the outer frame's value, which is
the only thing that stack defends against. It stays. The known issue
`guard-fs-writes-sh-trailing-words-after-a-re-execution-context-in-the-same-segment-bypass-local-rules`
records that no probe can isolate that stack's behaviour, and removing an
unfalsifiable guard inside a redesign of the same mechanism is how a
regression ships unnoticed. Removing it is a separate ticket with its own
oracle.

### 2026-09-22 — script-analytics.py vendors its cost helpers instead of importing them (NWM-156)

The 85 lines script-analytics.py needs from claude-cost.py and
claude-cost-scan.py are copies inside it, not `importlib` loads of two
siblings at import time. The file is self-contained and runs from any
directory in any repo, which is what living in ai-toolkit requires and what
NWM-129 made permanent by fixing the two claude-cost files in this repo for
good.

A third shared module was rejected because it renames the coupling rather
than removing it, and because `hooks/session-cost.sh` runs for every
installer under `SessionEnd`, so the plugin cannot depend on an ai-toolkit
checkout to satisfy it. Environment-supplied paths were rejected because
they turn a build-time coupling into a runtime dependency on the repo the
script is leaving. The price of vendoring is two copies of three renderers
and four price helpers; ai-toolkit's `scripts/script-analytics-selftest.sh`
carries a drift guard that compares the two implementations' behaviour so
the copies cannot diverge unnoticed.

`templates/claude-prices.tsv` is found by a search, not one fixed relative
path: `$CLAUDE_PRICES_TSV`, `../templates/`, beside the script, then the
same two under `$CLAUDE_PROJECT_DIR`, with a validation error naming every
path tried when none exists.

The general lesson: a migration must count `$PROJECT_DIR` paths as a
consumer surface alongside `${CLAUDE_PLUGIN_ROOT}` ones, and the
`$PROJECT_DIR` kind is worse, because it fails for consumers rather than
installers and a fail-open hook leaves no error behind.

### 2026-09-22 — parity-map.tsv rows are marked diverged, never deleted (NWM-158)

A pair that is known not to converge — two files sharing a name that an
owner decision settled as two different programs — gets a third
tab-separated column `diverged:<TICKET>` on its `templates/parity-map.tsv`
row, and `parity-sweep.sh` reports it in its own section, out of `drift` and
out of the exit code.

Deleting the row instead does not work, and this is invisible from the map
file. `parity-sweep.sh` registers a row's source path as mapped BEFORE it
compares anything, and its `new` bucket is "files under a mapped source
directory with no row at all". Every path in this map lives under a mapped
directory. So a deleted row's source reappears immediately under `new`,
which sets exit 1 exactly as `drift` does: the false positive moves, it
does not go away. Measured against `../homelab`, not reasoned about.

Three edge cases are decided rather than left to the reader. A marker on a
row whose local column is `-` is a malformed map: `-` already claims the
file was never ported. A marked pair whose local file is MISSING stays in
`drift` and keeps setting exit 1, because deliberately different is not
deliberately absent. A marked pair whose files turn out IDENTICAL is flagged
in the diverged section as a possibly stale marker, visibly but without
changing the exit code — `drift`, `new`, `vanished` and `unmapped` keep the
contract that LAB-228's and NWM-125's verify blocks read.

Two rows carry a marker: the two claude-cost rows (NWM-129). land-branch.sh
is NOT marked: NWM-131 splits it behind a hook contract rather than forking
it permanently.

### 2026-09-22 — script-analytics.py and script-retire.sh left for ai-toolkit; the hook resolves them and pins its own price table (NWM-130)

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

### 2026-09-22 — release.sh is retired without keeping its tracker-outcome changelog, because that feature never produced a line

NWM-124 asked, before deleting `scripts/release.sh`, whether the one thing
release-please cannot do — generating a CHANGELOG section from TRACKER
OUTCOMES rather than from Conventional Commit subjects — was worth keeping
as its own smaller tool.

It is not, and the reason is measurement rather than taste.

Three releases were ever cut with release.sh on this repo's history:
`v0.7.0` (48ca184), `v0.7.1` (e995591) and `v0.7.2` (aae4ffc). Every
section they wrote is hand-authored prose. None carries a ticket key, none
carries a `cost:` line, and the placeholder the script falls back to — `(no
tracker configured; add entries by hand)` — appears nowhere in
CHANGELOG.md. The tracker-outcome path produced no changelog line in any of
them. It could not have: the default path called the tracker `fetch` verb
with a since-tag while that verb takes an issue key, got HTTP 405, silenced
the error and degraded (the known issue
`release-sh-calls-the-tracker-fetch-verb-with-a-since-tag-...`).

The `cost:` lines in the pre-0.8.0 sections are not evidence to the
contrary: those sections arrived wholesale in `b765642`, the squashed
initial commit of the public repo, and 41 of the 43 `cost:` lines in the
file read `UNVERIFIED`.

What carries ticket provenance is the commit subject. This repo names the
ticket in the subject — `fix: count Workflow-tool subagent transcripts, not
just Agent-tool ones (NWM-152)` — so release-please's generated sections
already link each entry to its ticket and its commit.

So: no replacement tool, no release-notes fragment generator, nothing kept.
If ticket-outcome prose is wanted later it should be built against a
tracker verb that exists.

### 2026-09-23 — land-branch.sh becomes a wrapper over ai-toolkit's land-core.sh, and is its own hook (NWM-131)

`scripts/land-branch.sh` stays here, at the same plugin-root path, as a
wrapper: its preflight (argument checks, ticket resolution, tracker status,
closing-state gathering, the plan) runs first, and then it hands the merge,
the lint gate, the push and the branch cleanup to ai-toolkit's
`scripts/land-core.sh`, passing itself as land-core's `--hook`. The four
hook points carry the lifecycle: pre-merge does the Awaiting Deployment
move, post-merge builds the closing state and re-resolves a file ticket
against the merged tree, pre-push commits the file tracker's completion (so
it is inside the pushed history), and post-push completes the Jira issue,
writes the closing state, notifies, and tears down the herdr workspace.
`--already-merged` calls no core and runs the same phase functions inline.

State crosses the process boundary through one mode-600 temp file: the
wrapper writes its preflight values as `%q` assignments, each hook sources
it and appends what it changed, and the wrapper sources it again once
land-core returns. That file is also how land-branch.sh keeps its own exit
codes where land-core's differ: a failed Awaiting Deployment POST is exit 1
here while a pre-merge hook refusal is exit 2 in land-core, so the hook
records `WRAPPER_RC` and the wrapper exits with that.

land-core is resolved at run time by `scripts/ai-toolkit-root.sh
--land-core`, the same way as known-issue.sh. It is not vendored and not
pinned. The cost is an adopter cost: a marketplace installer needs an
ai-toolkit checkout or `$AI_TOOLKIT_ROOT` to land anything, and gets exit 2
naming both when neither resolves.

`--lint-cmd` runs through `bash -c`, so a compound lint command is one
command, not word-split into `true && false`, which would let a red lint
land.

land-core's branch-worktree clean check exempts exactly one untracked path
through `--allow-untracked PATH` (an exact `?? PATH` porcelain line; a
staged or modified copy, or any other untracked file, still refuses), and
land-branch.sh passes `--allow-untracked .night-watchman/closing-state.md`
because the worker brief requires that file to exist uncommitted (NWM-147).

### 2026-09-24 — script-events-hook.sh drops the project-dir extractor step and greps a sentinel line before invoking (NWM-160)

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

### 2026-09-26 — release-please pushes with a fine-grained PAT so release PRs get checks

release-please's release branch was pushed with the default GITHUB_TOKEN, and GitHub never runs workflows on pushes made with that token, so every release PR sat with no checks and could not satisfy protect_main-2's required-status-checks list. The fix is a fine-grained PAT (Contents and Pull requests, read/write) stored as the repo secret RELEASE_PLEASE_TOKEN and passed as the action's token input in .github/workflows/release-please.yml, proven first on switchtender PR #36. A fine-grained PAT expires after at most one year: this one must be rotated before 2027-09-26, and the symptom of an expired one is release PRs reappearing with no checks. If a release PR is already open with no checks, closing and reopening it once triggers them.
