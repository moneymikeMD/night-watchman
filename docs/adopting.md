# Adopting night-watchman on an existing repo

A terse runbook for wiring an existing repo up as a night-watchman adopter.
Written from the second adopter (ADOPT) adoption, 2026-09-13.

## Runbook

1. **Stash the adopter repo's dirty tree first.** `git status --short` to
   see what's there, then `git stash push -u -m "<ticket> pre-install
   stash <date>"` to get a clean baseline. Do this from **outside** any
   session that has night-watchman's `hooks/guard-fs-writes.sh` active —
   see Snags below. Record the stash ref; leave it unpopped for the owner
   unless told otherwise.

2. **Confirm the plugin is actually available to the adopter repo.**
   `claude plugin list` — if `night-watchman@moneymike-plugins` shows
   `Scope: user` and `Status: ✔ enabled`, it already covers every repo on
   the machine; no per-project enable step is needed. Only reach for
   `claude plugin enable` or an `enabledPlugins` entry in
   `.claude/settings.json` if the listing shows it disabled or absent.

   In the same listing, confirm `work-order@moneymike-plugins` is present with an
   empty `errors`. It is the one plugin dependency, and it carries
   `issues.py`. A cross-marketplace dependency whose marketplace was never
   added still reports `ok` and exits 0, so the exit code proves nothing:
   ```
   claude plugin marketplace add moneymikeMD/moneymike-plugins
   claude plugin list --json \
     | jq '.[] | select(.id == "work-order@moneymike-plugins") | {version, errors}'
   ```

3. **Merge `templates/CLAUDE.md` into the adopter's CLAUDE.md, additively.**
   Append a clearly delimited section (HTML comment markers work well);
   never replace the adopter's own product overview. Copy
   `templates/ethos.md` to `docs/ethos.md` (create `docs/` and a
   `docs/README.md` index if neither exists yet; if a `docs/README.md`
   index already exists, just add a row for `ethos.md`), stripping the
   template's own "copy this / delete this comment" preamble since it's a
   real doc now, not a template. Copy
   `templates/night-watchman.config.toml` to
   `.night-watchman/config.toml`, setting `[tracker.jira] project` to the
   adopter's real project key; leave secret coordinates as reference
   names only, never values, and point at the private `NW_CONFIG` toml
   the same way `providers/README.md`'s "Private config" section
   describes.

4. **Create `.claude/settings.json`** (don't touch `settings.local.json`
   if one exists) with the tracker env vars the adopter's tooling needs
   (`ISSUES_SOURCE`, `ISSUES_JIRA_PROJECT`, `ISSUES_JIRA_API`,
   `NW_CONFIG`). Do **not** add a local `guard-fs-writes` hook entry —
   the plugin's own copy already runs via the plugin manifest once it's
   enabled (user or project scope); a second copy would just be
   redundant. Say so explicitly in the adopter's CLAUDE.md so a future
   reader doesn't "fix" the perceived gap.

   Check whether the adopter's `.gitignore` has a blanket `.claude/`
   entry before assuming `settings.json` will commit — see Snags.

5. **Verify** with the adopter's own tracker project key:
   ```
   ISSUES_SOURCE=jira ISSUES_JIRA_PROJECT=<KEY> \
   ISSUES_JIRA_API=<path>/providers/tracker/jira/jira-api.sh \
   NW_CONFIG=<path to private toml> \
   python3 "$( <path>/scripts/work-order-root.sh --issues-py )" next
   ```
   should list the adopter's open tickets with exit 0. Run the same
   env vars against `issues.py lint` and record the counts — expect
   "no verify" errors on tickets that predate this adoption; don't fix
   the adopter's own tickets as part of this wiring pass.

6. **Commit in the adopter repo** with a message listing exactly what
   was added (CLAUDE.md section, docs/ethos.md, .night-watchman/config.toml,
   .claude/settings.json, any .gitignore change) and the verify counts.
   Leave the pre-install stash unpopped.

## Jira-native gates

Once the tracker is Jira (company-managed project), three ticket gates are
enforced by the workflow itself and one by an Automation rule. The
workflow rules are applied by
`providers/tracker/jira/jira-workflow-apply.sh <PROJECT> --rules
providers/tracker/jira/workflow-rules.json` (additive, idempotent; dry-run
first). They are:

| Transition | Rule | Message |
| --- | --- | --- |
| into In Progress | `verify` non-empty | `verify is required before work starts` |
| into In Progress | `touches` non-empty | `touches is required before work starts` |
| into Completed | `verify` non-empty | `verify is required before completing` |
| into Completed | issue has exited In Progress (`system:previous-status-validator`) | `The issue never transitioned through the desired status: In Progress` |

The last rule counts statuses the issue has *left*, so the lifecycle must
be In Progress at dispatch, Awaiting Deployment before landing, Completed
after landing; `dispatch start` and `land-branch.sh` make those moves (see
`tickets-protocol`). Everything Jira cannot express (blocked-by links,
`touches` collisions between startable siblings, `mixed` needing
`human_steps`) stays in `issues.py lint`.

### Automation rule: deferral expiry (owner UI step)

Jira exposes no public API for Automation rules on the plans this plugin
targets, so this one is created by hand. It exists for visibility only:
`issues.py next` already ignores Deferred tickets, and a Deferred ticket
with a past date is simply invisible until someone notices.

**One global rule is enough.** Create it under Jira Settings → System →
Global automation, scoped to all software projects, with no `project =`
clause in the JQL (`status = Deferred AND "defer_until" <= now()`). Every
project bootstrapped by `jira-space-create.sh` gets the Deferred status and
the `defer_until` field, so the rule covers projects created later with no
further work. This is what the first adopter did (2026-09-14). A global
rule counts against the site-wide Automation execution allowance; at one
run a day that is about 30 executions a month. Per-project rules (the
steps below, or the import template) are the fallback when a site wants
the allowance untouched.

1. Project settings → Automation → Create rule.
2. Trigger: **Scheduled**. Run daily. Tick "Run a JQL search and execute
   actions for each issue in the query". JQL, with your project key and the
   field's display name (`defer_until` on a project bootstrapped by
   `jira-space-create.sh`):

   ```
   project = PROJ AND status = Deferred AND "defer_until" <= now()
   ```

3. Action: **Transition issue** → To Do.
4. Action: **Comment on issue**, text:

   ```
   defer_until passed; returned to To Do by Automation
   ```

5. Name it `defer_until expiry`, save, then **Run rule** once by hand and
   check the audit log shows one run (zero matched issues is fine).
6. Prove it: set a scratch issue to Deferred with `defer_until` yesterday,
   wait for the next scheduled run (or run the rule again), confirm it is
   in To Do with the comment, then cancel the scratch issue.

Record the rule id and the audit-log line in the ticket that asked for
the rule.

**Import instead of clicking.** Automation rules export and import as
JSON. `templates/jira-automation-defer-until.json` is the rule above,
de-identified (recorded from a live export, then placeholders substituted).
Fill it and import it:

```
jq --arg cloud "<cloud id>" --arg pid "<numeric project id>" --arg key "PROJ" \
   --arg me "<your account id>" '
  .rules[0].trigger.value.jql |= sub("PROJ"; $key)
  | (.. | strings) |= (sub("CLOUD_ID"; $cloud) | sub("PROJECT_ID"; $pid)
                       | sub("ACTOR_ACCOUNT_ID"; $me) | sub("AUTHOR_ACCOUNT_ID"; $me))
' templates/jira-automation-defer-until.json > /tmp/defer-until-rule.json
```

Then Project settings → Automation → the `...` menu → **Import rules**,
choose the file, enable it, and run it once. The cloud id comes from
`GET /rest/api/3/serverInfo` or the `atlassianUserInfo` connector call; the
project id from `GET /rest/api/3/project/PROJ`.

**If Jira says `Field 'defer_until' is not searchable`:** the custom field
has no searcher, which happens to fields created through the API. Give it
one and retry (date fields take `daterange`, text fields `textsearcher`,
single-select fields `multiselectsearcher`; `selectsearcher` is refused
with HTTP 400):

```
providers/tracker/jira/jira-api.sh --yes write PUT /field/<customfield id> \
  '{"searcherKey":"com.atlassian.jira.plugin.system.customfieldtypes:daterange"}'
```

`GET /rest/api/3/field` keeps reporting `searcherKey: null` afterwards;
prove it with a JQL search on the field instead. `jira-space-create.sh`
now does this probe-and-repair for every field it creates or finds — see
its own header, THE RECIPE step 4; the manual form above is the
fallback for a field it did not touch.

## Snags

- **`hooks/guard-fs-writes.sh`, once enabled at user scope, guards every
  repo, not just night-watchman's own.** It blocked `git stash push -u`
  run from inside a hooked session against the adopter repo's main
  worktree (it can't confirm the adopter repo is a linked worktree of
  anything it's tracking, so it treats it as "the main worktree" and
  refuses). Workaround: run the stash from outside the hooked session —
  in Claude Code, the `!` prefix runs a raw shell command that bypasses
  the PreToolUse hook. There's no in-session override; this is a
  structural block, not a permission prompt, and correctly so — it just
  means the *human* runs this one command, not the agent.
- **The same hook also blocks writing command output to `/tmp` or
  anywhere outside the current worktree/scratchpad** (e.g.
  `... > /tmp/out.txt`). Redirect into the worktree or the session
  scratchpad instead, or just let the command print to stdout.
- **A blanket `.claude/` entry in `.gitignore` swallows the new
  `settings.json` too**, and a plain `!.claude/settings.json` negation
  does not resurrect it — git won't descend into an already-excluded
  directory to evaluate negations inside it. Fix: change the ignore line
  to `.claude/*` (ignore contents, not the directory itself) and keep
  the `!.claude/settings.json` negation under it. `settings.local.json`
  stays ignored under the same `.claude/*` line.
- **No template collisions were hit** on this adoption — `docs/ethos.md`
  and `.night-watchman/config.toml` didn't already exist in the adopter,
  and `docs/README.md` already existed as a real index (not a template),
  so it only needed one new row rather than a fresh file.
- **`.night-watchman/last-session-cost.txt` (written by the `SessionEnd`
  cost hook, see `docs/cost.md`) is per-machine, per-session state, not
  project config — add `.night-watchman/last-session-cost.txt` to the
  adopter's `.gitignore` alongside any other `.night-watchman/` entries;
  don't gitignore the whole `.night-watchman/` directory, since
  `config.toml` there is real project config that should commit.
  `.night-watchman/closing-state.md` belongs on that list too. It is
  per-run state a worker writes and does not commit. Not gitignoring it
  no longer *blocks* a landing — `land-branch.sh` exempts exactly that one
  path from its dirty-worktree check (NWM-147) — but it still shows up in
  every `git status` the worker and the reviewer run.
- **The adopter's first session-start committed `dispatch = "herdr"`,
  had `herdr` on PATH, and `HERDR_ENV=1` set — and still dispatched
  through a plain `git worktree` subagent** because session-start framed provider dispatch as an optional
  layer the orchestrator could choose not to reach for. Fixed by making
  provider dispatch the rule once doctor reports it installed and ready,
  with a preflight check that stops orientation loudly instead of
  silently falling through.
