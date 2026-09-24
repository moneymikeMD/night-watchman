# providers/ — the contract

Every night-watchman script that reaches outside the repo goes through
this directory. Nothing calls a Jira client, a 1Password binary, a
worktree dispatcher, or a memory CLI directly; it resolves a **kind** to
an **implementation** and calls a fixed **verb** on it.

The point is not abstraction for its own sake. It is that "what does this
repo talk to?" should have one answer, in one committed file, that a
reviewer can read in ten seconds.

This is also the standing directive behind the whole plugin, not just this
directory: every capability lands as a provider-neutral contract first,
with the source project as its first *provider* — never as the shape of
the contract itself. See `docs/decisions.d/2026-09-14-every-capability-lands-as-a-provider-neutral-contract-first.md`
and `scripts/parity-sweep.sh --source-root`, which enumerates the
source project's own orchestration surface to catch a capability nobody
has mapped yet, not just drift on rows already in `templates/parity-map.tsv`.

## Kinds and their verb sets

The verb set is the contract. An implementation of a kind must accept
exactly these verbs; a caller must not invent a new one for one
implementation's benefit, because a verb only `jira` understands is how a
pluggable seam quietly becomes a hard dependency on one tool.

| Kind | Verbs | What it is |
| --- | --- | --- |
| `tracker` | `fetch` `transition` `comment` `create` | Where tickets live |
| `secrets` | `read` | Where credentials live |
| `dispatch` | `start` `watch` `stop` | How a wave of tickets gets run |
| `memory` | `store` `recall` | Durable cross-session knowledge |
| `publish` | `publish-brief` `post-headline` | Where the owner-facing wave brief is written, and where its headline is posted |

**Shipped:** `secrets/op` and `secrets/env`; `tracker/jira`;
`dispatch/workflow` and `dispatch/herdr`; `memory/memorygraph`
(`store`/`recall` over the `memorygraph` CLI); `publish/atlassian`.
`tracker/jira` is a port of the source project's `jira-api.sh` +
`jira-common.sh`, de-identified: the site host comes from
`[tracker.jira] host` in config and the credentials from the configured
`secrets` provider (refs `jira.user` / `jira.token`), never a hardcoded
literal. `transition`/`comment`/`create` are LIVE WRITES by default (no
interactive confirmation) — deliberate, so a wave-dispatch script can call
the tracker kind unattended; set `$NW_DRY_RUN=1`, or pass `--dry-run`
before the verb, to have any verb print the request it would issue and
exit 0 instead. `tracker/jira/jira-space-create.sh` is a
one-run bootstrap for a brand-new Jira Space — project + the six stage
statuses (via `providers/tracker/jira/jira-workflow-apply.sh`) + the six
custom fields + those fields on every project screen — each step
idempotent, so a re-run converges rather than failing on "already there";
not a verb of the `tracker` contract itself, since it is a one-time setup
operation, not part of the fetch/transition/comment/create surface every
implementation must offer. `dispatch` ships two implementations —
`dispatch/workflow` (the default) and `dispatch/herdr` (the fallback) —
and they do not mean the same thing by the same verb; see
"dispatch: `workflow` and `herdr`" below for the table and the one
declared gap. `dispatch/herdr` is a port of a
worktree-dispatch tool's ticket-start flow (`herdr-ticket-start.sh`,
under `providers/dispatch/herdr/`): its `start` verb opens a Herdr
worktree, starts a pinned-model Claude agent in it, and hands it the
ticket's session-start brief; `watch` polls `herdr agent get`/`herdr agent
wait --until STATE --timeout MS`, and `stop` closes the agent's owning
workspace with `herdr workspace close` (an agent with no `workspace_id`
is refused, exit 2 — that paneless case has no recorded fixture) — both
implemented against fixtures recorded from a live herdr binary,
see `providers/dispatch/herdr/fixtures/`.
`providers/dispatch/herdr/commit-staged-worktrees.sh`
is a companion script, not a `dispatch` verb: it commits
already-staged-but-uncommitted work sitting in Herdr worktrees (e.g. after
a commit-signing lock prevented `git commit` from completing), using each
worktree's own `.commit-msg.txt` as the message — see its own header for
the full skip/exit-code contract.
`providers/dispatch/herdr/herdr-agent-pane.sh` is another
companion script, not a `dispatch` verb: run from inside a Herdr pane, it
splits the current pane and starts a named coding agent in the new one —
no ticket/tracker involvement, just `herdr pane split` + `herdr agent
start`; see its own header for the flag contract.

The names above are the built-in defaults — what a kind resolves *to* —
which is a separate question from whether it is installed; `provider.sh
doctor` reports a kind whose implementation is missing as `not-installed`.
They are defaults, not requirements: the core still works with none of
them reachable, because nothing in the core calls a provider unless the
operation it was asked to do actually needs one.

## Layout

```
providers/
  README.md                       this file
  lib/provider.sh                 resolve + dispatch (also a CLI)
  lib/config.sh                   the .night-watchman/config.toml reader
  lib/kit.sh                      die/warn/need/... (a copy; see its header)
  config-selftest.sh              selftest for the two lib files
  <kind>/<impl>/provider.sh       an implementation's executable entry point
```

An implementation is a directory holding an executable `provider.sh` that
takes the verb as its first argument. That is the whole interface. It may
keep anything else it wants alongside — a `lib/`, fixtures, its own
selftest — and adopters are expected to: adding `providers/tracker/linear/`
to your own repo is how you swap the tracker without forking this plugin.

## Selection

Highest priority first:

1. **`NW_TRACKER` / `NW_SECRETS` / `NW_DISPATCH` / `NW_MEMORY` /
   `NW_PUBLISH`** — a per-run override, for trying an implementation
   without committing to it. Never the reviewed answer, always the
   temporary one.
2. **`[providers]` in the nearest committed `.night-watchman/config.toml`**,
   found by walking up from the working directory. This is the reviewed
   answer. Copy `templates/night-watchman.config.toml` to
   `.night-watchman/config.toml` in your repo and commit it.
3. **The built-in defaults** in `lib/provider.sh`, so a fresh adopter with
   no config gets a working system rather than an error about a file they
   have never heard of.

There is deliberately no `~/.night-watchman/config.toml` step. Provider
selection is a property of the repo being worked on and is reviewed in
that repo's history; a per-operator home-directory config would mean two
people running the same script against the same repo silently hitting
different providers.

### What was rejected, and why

- **A `--impl` flag on every script.** Works until you want to know what
  the repo actually talks to, at which point the answer is spread across
  every invocation in every skill, agent, and cron entry, with no single
  place to look and nothing to review.
- **Environment variables only.** Same problem, plus a worse one: not in
  the repo's history, so a change to it leaves no trace.
- **A block in `.claude/settings.json`.** That file belongs to Claude
  Code, not to this plugin. Extending someone else's schema with our keys
  means our config breaks when theirs changes, and it is not obviously
  ours to a reader.

## Using it

```
providers/lib/provider.sh resolve tracker            # -> jira
providers/lib/provider.sh origin tracker             # -> env | config | default
providers/lib/provider.sh verbs tracker              # -> fetch transition comment create
providers/lib/provider.sh dir tracker                # -> .../providers/tracker/jira
providers/lib/provider.sh config tracker.jira.host   # -> a key from the config
providers/lib/provider.sh run tracker fetch PROJ-17   # -> execs the implementation
providers/lib/provider.sh doctor                     # -> a table of all five kinds
```

`resolve` reports the winner; `origin` reports which of the three rules it
came from. Both exist because "why is it talking to *that*?" is the
question an operator actually has, and a bare implementation name cannot
answer it. `doctor` prints the config path in effect alongside every kind,
its implementation, where the selection came from, and whether it is
installed — start there when something reaches the wrong place.

`run` validates the verb against the kind's fixed set **before**
dispatching, so an unknown verb is a contract error naming the legal set
rather than whatever the implementation happens to do with an argument it
does not recognise.

The library is sourceable as well as executable: `. providers/lib/provider.sh`
gives you `nw_resolve`, `nw_run`, `nw_config_get` and friends as shell
functions, and deliberately does *not* turn on `set -e` in your script
when sourced.

## The config file

`.night-watchman/config.toml` is read by `lib/config.sh`, which implements
a fixed **TOML subset**, not TOML:

- **Supported** — comments, `[table]` headers (dotted names allowed), and
  `key = value` where the value is a basic string (`\"` `\\` `\n` `\t`
  `\r` escapes), a literal string, an integer, or a boolean.
- **Rejected, each with its own error naming the file, line, and reason** —
  arrays, inline tables, arrays-of-tables, multi-line strings, floats,
  dates, quoted keys, duplicate keys, duplicate table headers, and any
  line that is none of the above.

The rejections are the feature. A reader that quietly skipped a line it
did not understand would let a typo three lines above `tracker = "jira"`
silently fall the selection back to a built-in default, and the operator
would get a clean run against the wrong provider with nothing printed. The
subset is small enough to implement correctly in bash 3.2; a full TOML
implementation there would be a large, badly-tested surface for a file
that only holds provider selections and a handful of settings.

No secret goes in this file — it is committed. Credentials come from the
`secrets` provider at run time; what lives in config is the *reference*
(an `op://` path, a vault name), never the value.

## secrets: `op` and `env`

`secrets` has one verb, `read REF`, and prints the secret on stdout, never
elsewhere — no implementation may echo, log, or error-message the value.
`REF` is a dotted lowercase name (e.g. `jira.token`), and a wrapper at
`providers/secrets/read.sh` resolves the kind and dispatches for callers
that only care about secrets:

```
providers/secrets/read.sh jira.token
```

- **`env`** maps `REF` straight to an environment variable:
  `NW_` + `REF` with `.` → `_` and every letter upper-cased, so
  `jira.token` → `NW_JIRA_TOKEN`. No config needed — this is the path a
  stranger with no 1Password access uses to run the selftests and a first
  session.
- **`op`** looks up an item, field, and (optionally) vault for `REF` in
  config and builds the `op://` URI itself, so a ref never doubles as the
  1Password coordinate an operator has to keep in sync by hand:

  ```
  [secrets.op.jira.token]
  item  = "..."            # required
  field = "..."            # required
  vault = "..."            # optional; falls back to [secrets.op].vault,
                            # then the built-in default "Private"
  ```

  An item name containing parentheses breaks `op read` — a limitation of
  `op` itself, not this provider.

## publish: `atlassian`

`publish` writes a wave's product-manager brief to an external system of
record and posts a short headline pointing at it to a project status feed.
Two verbs:

- **`publish-brief <title> <body.md>`** — writes the markdown brief as a
  page titled `<title>` under this project's "`<project_name>` Project
  Updates" page (created under the configured root page on first run) and
  prints its URL. Never overwrites: if the title already exists there, the
  existing page's URL is printed and nothing is written.
- **`post-headline <project-ref> <text> <url>`** — posts `<text> <url>` to
  a status feed. `<project-ref>` is `default`, a tracker epic key mapped
  under `[publish.<impl>.feeds]`, or a feed id used as given. A rejected
  post exits 1; callers note it and carry on with the next feed.

`atlassian` is the first implementation: Confluence Cloud pages
(`providers/publish/atlassian/confluence.sh`) and Atlassian Home Projects
status updates (`providers/publish/atlassian/townsquare.sh`), ported from
a production client and trimmed to create/read — no page update or delete
path ships. Config keys are listed in the implementation's
`provider.sh --help` and in `templates/night-watchman.config.toml`. Writes
are live by default so a wrap-up can run unattended; `NW_DRY_RUN=1` shows
every request with no network and no credential.

Known coupling: `publish/atlassian` sources
`providers/tracker/jira/lib/http.sh` for curl auth and response
redaction, so both Atlassian kinds share one redaction word list. The
price is a cross-kind file dependency — an adopter who swaps the tracker
away from `jira` and deletes that directory breaks this implementation
until `http.sh` moves to `providers/lib/`.

A repo that is published should keep `space`, `root_page`,
`project_feed` and any `[publish.atlassian.feeds]` entries out of its
committed config and put them in the private copy described under
"Private config" below, alongside `[tracker.jira] host`.

## dispatch: `workflow` and `herdr`

`dispatch` is the first kind with two implementations, and they do not
mean the same thing by the same verb. That is what having two is for; it
is also where this contract's only declared gap lives.

**`workflow`** runs subagents in-process, inside the orchestrating turn,
under a deterministic script — Claude Code's Workflow tool. It is the
default because the three open herdr dispatch issues (a cold boot
swallowing the brief, the reached-working wait failing on back-to-back
starts, a fresh worktree hitting the folder-trust dialog; see
`docs/known-issues.md`) cannot occur here, because none of the machinery
they live in exists here.

**`herdr`** opens a pane per ticket in a worktree-dispatch tool. It stays
registered and working, and it is still the right answer for three things
the Workflow tool does not do: a human-visible pane during a supervised
run, a session that outlives the orchestrating turn, and anything that
needs a real terminal.

### What the three verbs mean for an in-process dispatcher

A subprocess cannot call an in-process tool. So
`providers/dispatch/workflow/provider.sh` owns the deterministic half of
dispatch — compose, record, report — and the orchestrating turn owns the
half only it can perform. Every verb prints one JSON object naming what is
left for the turn to do, and a run journal outside the repo (see that
file's header for where) is the only state that outlives the turn.

| Verb | `herdr` | `workflow` |
| --- | --- | --- |
| `start` | opens a worktree and pane, starts a pinned-model agent, hands it the brief, transitions the ticket | composes the brief, records the launch request, prints it. No pane, no folder-trust dialog, no worktree — the brief tells the agent to create its own, the way the wave ran |
| `watch` | `herdr agent wait`, blocking, optionally `--until STATE --timeout MS`; a pane a human can look at | a point-in-time read of the run journal. It does not block, and there is nothing to look at |
| `stop` | closes the agent's owning workspace, taking the pane with it | records a stop request and prints the `TaskStop` the turn must issue. Nothing is killed, because nothing was spawned |

### The declared gap

**`watch` does not promise what herdr's `watch` promises, and does not
pretend to.** herdr's is a live view plus a blocking wait. The Workflow
tool's equivalents are a task notification and a journal, and both are
delivered to the turn holding the tool — never to a subprocess it spawned.
So this implementation's `watch` promises exactly one thing: the state
recorded in the run journal at the moment it is asked. `--until` and
`--timeout` are refused by name rather than accepted and approximated,
because a wait here could only ever time out — nothing in this process's
lifetime writes the state it would be waiting on. A caller that needs to
block has to *be* the turn, and has to wait on the Workflow task itself.

Two smaller differences, declared for the same reason rather than papered
over:

- **`start` does not transition the ticket.** herdr's does, as its last
  step, because by then the agent is running. Here the launch happens
  after `start` returns, so a transition would move the ticket at request
  time and claim something that has not happened yet. The lifecycle move
  stays with the caller.
- **`start` requires an executor assertion** — `--ticket-file PATH`, whose
  frontmatter decides, or `--executor agent`. herdr reads the executor
  from the tracker; this implementation reaches no tracker at all, and an
  unattended dispatch where nobody checked who the ticket is for is the
  one failure mode worth a required flag.

Neither implementation is a superset of the other, and a caller written
against one should read this table before assuming the other will do.

## Adding an implementation

1. `mkdir -p providers/<kind>/<name>` and write an executable
   `provider.sh` there that handles every verb in that kind's row above.
2. Select it: `[providers] <kind> = "<name>"` in your
   `.night-watchman/config.toml`, or `NW_<KIND>=<name>` for a one-off run.
3. `providers/lib/provider.sh doctor` should show it as `installed`.

Implementation names are a single lowercase path segment
(`[a-z0-9_-]`). That is enforced as a **security** check, not a style one:
the name is concatenated into a filesystem path and then executed, so
`NW_TRACKER=../../../tmp/evil` is refused by the resolver rather than
resolved by the kernel.

## Testing

`providers/config-selftest.sh` covers both library files: the supported
grammar, every rejected construct by name, the discovery walk, the
three-level precedence, the path-traversal refusal, verb validation,
argument passthrough, and a drift check that the shipped template still
declares every kind the resolver knows about. It runs entirely against
scratch directories — there is no live target for this layer to reach, so
there is nothing here to accidentally write to.

## Private config (owner-local secrets coordinates)

The committed `.night-watchman/config.toml` never carries 1Password
coordinates, because this repo is published. Keep them in a private copy
outside the repo and point the reader at it:

```
export NW_CONFIG=~/.config/night-watchman/<project>.toml   # mode 600
```

That file is the committed config plus `[tracker.jira] host = ...`, the
`[secrets.op.jira.user]` / `[secrets.op.jira.token]` tables (item, field,
optional vault), and — if a `publish` provider is used — the
`[publish.atlassian]` site identifiers (`space`, `root_page`,
`project_feed`, `[publish.atlassian.feeds]`). It holds names only; the
value is fetched by `op read` at run time and reaches only the wrapper's
stdin. Without `NW_CONFIG` the tracker verbs fail with `no Jira host
configured`, which is the intended behaviour on a fresh checkout.
