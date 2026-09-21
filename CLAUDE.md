# CLAUDE.md

## What this repo is

`moneymikeMD/night-watchman` is a public Claude Code plugin. It owns
unattended execution — dispatch, waves, session-start, the `land-branch.sh`
lifecycle, the closing-state handoff, wave-trail — plus the write guard and
cheap-reader hooks in `hooks/`, and the provider seam in `providers/`. A
session runs with no human in it; everything here exists to make that
survivable.

That scope is deliberately narrow, and `docs/ethos.md` argues why. A ticket in
this repo's backlog that assigns it work outside that scope predates the
boundary and is stale.

It explicitly does **not** own what a ticket *is*: schema, lifecycle,
conformance and `reference/issues.py` are work-order's (`SPEC.md`,
`conformance/`), declared as a dependency
(`.claude-plugin/plugin.json`, `"work-order" "^1.3.0"`), resolved at run time
by `scripts/work-order-root.sh` — `$WORK_ORDER_ROOT`, then the installed
plugin's path via `claude plugin list --json`, then a sibling checkout.
`skills/to-issues/` keeps only `SKILL.md` and a ticket template; the mining
half that turns a settled conversation into a decision list is
`skills/to-issues-mine/`, this repo's own — turning that list into ticket
files is work-order's `emit-tickets` skill, run separately.

**What this is and is not**, argued at length with evidence, is
`docs/faq.md` and `README.md` — don't re-derive that argument here. Short
version: nine agents ship (`agents/*.md`) and none of them orchestrates;
they're dispatched, they don't dispatch. Orchestration lives in skills and
hooks.

**The installed plugin is not this checkout.** Claude Code runs
`~/.claude/plugins/cache/night-watchman/`, not whatever is on disk here. A
landed and released fix is not a deployed fix, and a session already open
keeps running the version it started with. Check
`claude plugin list --json | jq '.[] | select(.name=="night-watchman")'`
before trusting that a fix is live.

`templates/CLAUDE.md` is not this file and is not read by the plugin. It's
what an *adopting* repo merges into its own CLAUDE.md per
`docs/adopting.md`. Don't confuse the two, and don't copy this
file's content back into it.

## Provider selection and the private config

`.night-watchman/config.toml` (committed) selects: `tracker = "jira"`
(project `NWM`), `secrets = "op"`, `dispatch = "workflow"`,
`memory = "memorygraph"`, `publish = "atlassian"`. `providers/README.md` is
the full contract — verb sets, precedence (`NW_<KIND>` env, then this file,
then built-in defaults), and how to add an implementation. Read it before
calling a provider script directly.

**`host` and every site identifier are deliberately absent from the
committed config.** This repo is public, and a deployment's own
Jira/Confluence coordinates have no reason to be in its history. They belong
in a private file that the `$NW_CONFIG` env var points at — conventionally
`~/.config/night-watchman/nwm.toml`, mode 600.

**Nothing exports `$NW_CONFIG` for you.** No shell profile sources it and
this repo's `.claude/settings.json` is gitignored, so a fresh shell has it
unset even when the private file exists. Export it before running any
tracker or publish verb:

```bash
export NW_CONFIG=~/.config/night-watchman/nwm.toml
```

Without it, `providers/tracker/jira/jira-api.sh` dies with
`no Jira host configured — expected [tracker.jira] host = "..." in
.night-watchman/config.toml, or $NW_JIRA_HOST for testing`. That failure
means the export was skipped, not that the config is broken.

## Landing a ticket: `scripts/land-branch.sh`

Two tracker backends, `--tracker file|jira` (default `file`, zero external
accounts). `file` mode moves a ticket markdown file between
`{open,in-progress,awaiting-deployment,completed,cancelled}/`. `jira` mode
needs four flags with **no built-in defaults** — omitting any one stops the
script before it touches anything:

```
--jira-api PATH --jira-progress-status ID --jira-awaiting-status ID --jira-done-status ID
```

On the `NWM` Jira project (verified live against its transitions): In
Progress is status id `3`, Awaiting Deployment is `10012`, Completed is
`10014`.

**The lifecycle a ticket must follow is In Progress → Awaiting Deployment →
Completed, never a direct In Progress → Completed.** The workflow's
`system:previous-status-validator` on the Completed transition rejects the
shortcut with `The issue never transitioned through the desired status: In
Progress` — it checks statuses the issue has *left*, not the one it's in,
so an issue that went straight from In Progress reads as never having left
To Do. `land-branch.sh` always moves a ticket to Awaiting Deployment before
completing it (`--no-complete` stops there on purpose); see
`docs/known-issues/nwm-workflow-previous-status-validator-*.md` for the
full mechanism.

**A ticket cannot leave To Do without `verify` and `touches` set, and
cannot reach Completed without `verify`.** Both are workflow-level required
fields (`providers/tracker/jira/workflow-rules.json`), not merely a
convention. An Epic issue type has no `touches` field at all, so an Epic can
never satisfy that gate structurally — `NWM-10` cannot close for this
reason and is tracked as **WO-71** (a work-order schema issue, since the
validator applying task-shaped requirements to Epics is work-order-jira's
provisioning, not this repo's).

**Landing runs in `<parent-of-main-worktree>/night-watchman-land`**, a
dedicated integration worktree `land-branch.sh` owns and resets to
`origin/main` on every run — never in the invoking tree, which it refuses
outright if dirty (`--reset-land` overrides the worktree reset, not the
dirty-invoker check). See "The wave-trail gitignore gap" below for the one
file that trips this today.

### Merge commits land directly, and the branch ruleset does not stop them

`land-branch.sh` does `git merge --no-ff` and `git push origin
HEAD:main` — a direct push of a two-parent merge commit, no pull request.
`protect_main-2` requires linear history and a code-owner-reviewed PR, but
its `bypass_actors` grants the repo-admin role (the owner) `bypass_mode:
"always"` on every rule in the ruleset, confirmed live
(`current_user_can_bypass: "always"`). `git log --merges` on `main` shows
the result: two-parent commits (`NWM-122: merge branch 'nwm-122' into
main`) sit directly alongside one-parent PR squash-merges (`fix: remove the
landed branch's worktree with git... (#53)`). **So parent count tells the two paths apart:** two parents means
`land-branch.sh`, one means a squash through the UI. Verify with
`git log --format='%h %p' -1 <sha>` rather than reading the ruleset and
assuming it was enforced — a bypass actor makes a ruleset an intent, not an
outcome.

The ruleset's one-review/code-owner-review requirement binds a PR from
anyone who is *not* a bypass actor — `CODEOWNERS` is `* @moneymikeMD`, so an
outside contributor's PR needs the owner's review and GitHub's own
self-approval block means the owner can't satisfy that on their own PR
either, absent the bypass. It does not bind an owner-run `land-branch.sh`
landing, which never opens a PR.

## The wave-trail gitignore gap (NWM-150, open)

`.gitignore` matches `.night-watchman/wave-trail.tsv` but not the dated
`wave-trail-YYYY-MM-DD.tsv` files a wave actually writes. Because
`land-branch.sh` refuses a dirty invoking tree, one untracked dated trail
file blocks every landing until it's tracked, `git clean`ed, or the pattern
is fixed. `.night-watchman/wave-trail-2026-09-14.tsv` is sitting untracked
in this checkout right now, reproducing the bug — leave it in place; it is
NWM-150's evidence, not litter to clear.

## CI (`.github/workflows/ci.yml`)

Runs on **`macos-latest`**, not Ubuntu — this repo targets bash 3.2, the
`/bin/bash` macOS ships, and a Linux runner's newer bash would hide a
regression. Jobs:

- **work-order dependency** — resolves work-order's newest `v1.*` tag *live*
  with `git ls-remote`, clones it, and requires
  `scripts/work-order-root.sh --issues-py` to find `reference/issues.py`
  there before anything else runs. No version literal to go stale here.
- **shellcheck** — `hooks providers scripts`, `-e SC1091` (several scripts
  source a sibling through a runtime-resolved path shellcheck can't follow).
- **selftests** — discovers every `*selftest*.sh` by `find` and runs it; a
  new selftest needs no workflow edit. Two are quarantined by exact path
  (`providers/config-selftest.sh`,
  `providers/tracker/jira/jira-workflow-apply-selftest.sh`, each failing one
  known assertion) — skipped in the gating step, re-run informationally
  with `continue-on-error`.
- **known-issues index is not drifted** — `known-issue.sh lint`, run out of
  an **ai-toolkit checkout**: the script left this repo under NWM-128 and is
  resolved at run time by `scripts/ai-toolkit-root.sh --known-issue`
  (`$AI_TOOLKIT_ROOT`, then a sibling checkout). The CI job clones ai-toolkit's
  default branch for it, because `scripts/` there is the unpinned surface with
  no tag to resolve. `docs/known-issues.md` is **generated** from
  `docs/known-issues/*.md` frontmatter by `known-issue.sh reindex`
  (`add`/`resolve`/`severity` call it too); never hand-edit the index.
- **generated reference docs are not drifted** — `scripts/gen-reference-docs.sh
  --check` diffs against `docs/preview/website/src/content/docs/reference/`.
  Those `.mdx` pages are rendered from `agents/*.md`, `skills/*/SKILL.md`,
  script and hook header comments, and `templates/night-watchman.config.toml`
  — never hand-edit a page there; edit the source and run
  `scripts/gen-reference-docs.sh` (no `--check`) to regenerate.
- **no-major** — this plugin stays below a major version bump by owner
  decision, 2026-09-20: no commit subject or PR title
  matching `^[A-Za-z]+(\([^)]*\))?!:`, no `BREAKING CHANGE:` footer. A
  genuinely breaking change ships as a plain `feat:` describing the
  incompatibility in the body as prose.
- **skill-routing** — report-only against `evals/routing/`, deliberately: a
  gate that reddens every branch gets disabled rather than obeyed.
- **docs-site** — frozen `bun install` + `astro build` for
  `docs/preview/website`, catching a desynced lockfile before the real
  deploy does.

Only `selftests`, `docs-site` and `comment-lint` are in `protect_main-2`'s
required-status-checks list; `no-major` and `skill-routing` run on every
push and PR but aren't ruleset-required (they still gate a PR merged through
the UI, since GitHub blocks on any check the PR shows as failing, required
or not — they just don't independently block a bypassed push).

## Selftests are the house standard

Every operator script under `scripts/` and `providers/*/*/` is paired with
its own `<name>-selftest.sh`, discovered by CI glob, not by an explicit
list. Several — `scripts/land-branch-selftest.sh` is the reference — take
an older revision of the script under test as a positional argument, so a
fix can be proved red-then-green against a specific historical bug rather
than only against current code; read that file's own header before writing
a new selftest in this style. Selftests are offline by construction
(`docs/testing-philosophy.md`): each stubs its own HTTP client or CLI
target, so none reaches a network, site, or credential — the reason they
can run on a public repo with no secret configured.

## Handoffs

`docs/handoffs/` holds one dated note, read once at the next session start
then moved to `docs/handoffs/archive/`. The current one is
`docs/handoffs/2026-09-19.md`; check `docs/handoffs/` fresh rather than
trusting that filename, since the next session to run `session-start` moves
it. A handoff is a pointer to tickets and `docs/decisions.md`, not a
substitute for either.

## Writing this file

`docs/writing-style.md`'s "Skill and agent prose" section governs
`CLAUDE.md` itself, not just `skills/` and `agents/`. Before adding a line
here: does it change behavior versus the model's default (no-op test)? Is
the rule already stated in `providers/README.md`, `docs/faq.md` or
`docs/ethos.md` — if so, point at it instead of restating it (single
source of truth). Prefer stating the target behavior over banning its
opposite.

## Commands

```bash
providers/lib/provider.sh doctor                     # what does this repo talk to, and why
scripts/work-order-root.sh --issues-py                # resolve the work-order dependency
scripts/ai-toolkit-root.sh --known-issue              # resolve the ai-toolkit dependency
scripts/land-branch-selftest.sh [old-land-branch.sh] [issues.py]
"$(scripts/ai-toolkit-root.sh --known-issue)" add|reindex|resolve <slug>
scripts/gen-reference-docs.sh --check                 # CI's drift check
scripts/gen-reference-docs.sh                         # regenerate after editing a source
find hooks providers scripts -name '*.sh' -not -path 'scripts/fixtures/*' \
  -print0 | xargs -0 shellcheck -x -e SC1091 -P SCRIPTDIR
```
