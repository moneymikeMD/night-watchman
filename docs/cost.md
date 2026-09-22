# Cost ledger

An optional layer (see the README's "Core plus optional layers"): a
per-wave record of what a wave of agentic work cost, so `cost-reviewer`
(or a human) can ask "did last wave's change actually move the number"
without re-deriving it from raw logs each time.

## Files

Two scripts, split on purpose — scan is optional, the ledger is not:

- `scripts/claude-cost.py` — the generic ledger (append/list/compare
  against a TSV file). Dependency-free (Python 3 standard library only).
  Takes `--cost`/`--turns` from the caller; never reads a transcript.
- `scripts/claude-cost-scan.py` — one way to produce that `--cost`/
  `--turns` pair on this machine: scans local Claude Code JSONL
  transcripts under `~/.claude/projects/<slug>/` (main session + any
  `subagents/agent-*.jsonl`), dedupes the several JSONL lines a single
  streamed message can produce (grouped by `message.id`, last one wins),
  and prices tokens against `--prices` (default
  `templates/claude-prices.tsv`). `--ledger-line` prints exactly `cost:
  $<usd>, <turns> turns` for a ticket outcome comment. Never prints
  message content.
- `templates/claude-prices.tsv` — the $/million-token price table
  `claude-cost-scan.py` reads by default: one row per model, columns
  `model`, `input_per_mtok`, `output_per_mtok`, `cache_write_per_mtok`,
  `cache_read_per_mtok`. A model missing from the table costs $0 with a
  one-time stderr warning, never a hard failure. `script-analytics.py`
  reads the same table, but finds it by search rather than by one fixed
  relative path, so it also works from a repo with no `templates/`
  directory: `$CLAUDE_PRICES_TSV`, then `../templates/claude-prices.tsv`
  beside the script, then `claude-prices.tsv` beside the script, then the
  same two under `$CLAUDE_PROJECT_DIR`. When none exists it exits 2 naming
  every path it tried (NWM-156).
- `templates/cost-ledger.tsv` — a header-only starting point. Copy it into
  the project (a common convention is `docs/cost-ledger.tsv`) and start
  appending; the header line is the schema contract — see below.
- `agents/cost-reviewer.md` — the agent that runs this at the end of a
  wave and writes the recommendation.

## Schema

One TSV row per wave:

| column | type | meaning |
| --- | --- | --- |
| `date` | ISO-8601 | when the row was recorded (default: now, UTC) |
| `wave` | text | a short, unique label for the wave, e.g. `2026-09-12-am` |
| `turns` | integer | total agent turns spent on the wave |
| `cost_usd` | float | total cost for the wave, in whatever unit the caller's own accounting uses |
| `model_mix` | text | free text, e.g. `sonnet-5:80,opus-5:20`; not parsed or validated beyond forbidding a tab/newline |
| `notes` | text | what changed this wave, what was adopted from the previous review |

`claude-cost.py` refuses to append to a ledger whose header line does not
exactly match this schema — a stale or hand-edited header is a loud
refusal, never a silent partial append. It also refuses a ledger whose
last line has no trailing newline (a crash mid-append), with a repair
hint naming the line number, and refuses a duplicate `wave` label.

## What this deliberately does not do

`claude-cost.py` itself never reads a transcript, calls any API, or knows
a model's price — that is `claude-cost-scan.py`'s job, and it is optional:
a project without local transcripts (or that prefers a provider billing
export) feeds `claude-cost.py append --cost/--turns` from wherever its own
accounting already lives. `claude-cost-scan.py`'s own price table
(`templates/claude-prices.tsv`) is not cross-checked against a metrics
backend — `cost-reviewer`'s optional metrics cross-check (step 3 of its
procedure) is the seam for a project that has Grafana, Datadog, or similar
wired in; it is skipped, not required, when none is configured.

## Usage

```bash
# scan this repo's local transcripts since a wave's start
python3 scripts/claude-cost-scan.py --repo . --since 2026-09-12T00:00:00Z --format md

# the exact line for a ticket outcome comment
python3 scripts/claude-cost-scan.py --repo . --since 2026-09-12T00:00:00Z --ledger-line
# -> cost: $42.1000, 380 turns

# add a wave's row
python3 scripts/claude-cost.py append --ledger docs/cost-ledger.tsv \
  --wave 2026-09-12-am --cost 42.10 --turns 380 \
  --model "sonnet-5:90,opus-5:10" --notes "adopted: cut subagent fanout"

# preview a row without writing it
python3 scripts/claude-cost.py append --ledger docs/cost-ledger.tsv \
  --wave test --cost 1.23 --turns 10 --dry-run

# see the ledger
python3 scripts/claude-cost.py list --ledger docs/cost-ledger.tsv --format md

# delta against the previous wave
python3 scripts/claude-cost.py compare --ledger docs/cost-ledger.tsv --format md
```

Run `scripts/claude-cost-selftest.sh` to check the ledger's own
invariants (header creation, duplicate-wave refusal, stale-schema
refusal, the truncated-file repair-hint path, and `compare`'s delta
math) against a scratch file — it touches nothing under `docs/`.

Run `scripts/claude-cost-scan-selftest.sh` to check the scanner against
fixture transcripts under `scripts/fixtures/claude-cost-scan/` —
structurally offline, never reads the real `~/.claude/projects` tree.
Covers the `--repo`/`--project-slug` filter, the same-message-id dedupe,
`--since` filtering, and `--ledger-line`'s exact output shape.

## The ledger's JSONL twin

Every `claude-cost.py append` writes the same row twice: the TSV row
described above, and a JSON object with the same field names as one line
appended to a sibling file, `<ledger path with .tsv swapped for
.jsonl>` (e.g. `docs/cost-ledger.jsonl` next to `docs/cost-ledger.tsv`).
`ledger.jsonl` is derived and append-only — a convenient tail target for a
log shipper (Promtail, Alloy, Fluent Bit, or similar) that wants
line-delimited JSON rather than a TSV parser. It is **not** the source of
truth: `cost-reviewer` and `claude-cost.py list`/`compare` read
`ledger.tsv`, never the jsonl twin. Don't "fix" the tsv by regenerating it
from the jsonl if the two ever look out of sync — the tsv is what to
trust; investigate the jsonl append instead.

This plugin ships no shipper config, pipeline, or dashboard for the jsonl
twin — see the README's "Core plus optional layers": the plugin never
assumes an observability stack. The jsonl file is the seam; wiring it to
Loki/Elasticsearch/whatever a project already runs is the adopter's own
work.

## SessionEnd cost hook

An optional layer, same tier as the scan/ledger split above: `hooks/session-cost.sh`
is wired as a plugin `SessionEnd` hook (see `.claude-plugin/plugin.json`) so
the ticket outcome comment's `cost: <$ or tokens>, <turns>` line is a
by-product of ending a session, not a thing a human has to remember. It
never blocks a session from ending — every failure path (no scanner, no
python3, no ledger, an unparsable transcript) is a one-line stderr
warning, and the hook always exits 0.

On `SessionEnd`, it:

1. Reads the hook's own stdin JSON (`session_id`, `cwd`) and runs
   `scripts/claude-cost-scan.py --repo <cwd> --session <session_id>
   --format json` to get this session's turns, cost, and model mix.
2. Appends a row to the project's ledger — `docs/cost-ledger.tsv` by
   default, override with `NW_COST_LEDGER` — **only if that ledger file
   already exists**; a project that hasn't opted into the ledger layer
   gets no ledger writes. The wave label is `<date>-<session id first
   8 chars>`; a duplicate wave (re-running the hook, or two hooks racing)
   is a no-op, not an error.
3. Writes `.night-watchman/last-session-cost.txt` in the session's `cwd`:
   line one is exactly `cost: $<usd>, <turns> turns` (the ticket-comment
   convention), line two is the session id and date for a human reader.
   This file is untracked — see `docs/adopting.md`'s gitignore guidance.

Per session, not per wave: a wave spanning several sessions gets one
ledger row per session, and `cost-reviewer` (or a human) sums them when
comparing waves.

Run `hooks/session-cost-selftest.sh` to check it against a fixture
transcript under `hooks/fixtures/session-cost/` — structurally offline,
using `NW_COST_PROJECT_SLUG`/`NW_COST_PROJECTS_DIR` overrides so it never
touches the real `~/.claude/projects` tree, and a throwaway working
directory it creates and destroys itself.

## Script lifecycle analytics

A second, separate pair — evidence on the `script-author`/`script-reviewer`
lane specifically, not a wave-level total: rework rounds and their causes
(review findings, lint failures, usage/selftest failures), turns, tokens,
USD, and wall time to acceptance, per script and per agent type.

- `hooks/script-events-hook.sh` — a `SubagentStop` hook (registered in
  `.claude-plugin/plugin.json` with matcher `script-author|script-reviewer`)
  that fires whenever one of those two subagents stops, and runs
  `script-analytics.py extract --agent-id ...` for just the subagent that
  finished. It resolves the extractor through a chain — first
  `$SCRIPT_EVENTS_EXTRACTOR`, then `$CLAUDE_PLUGIN_ROOT/scripts/`, then
  `$CLAUDE_PROJECT_DIR/scripts/`, then its own `../scripts/` — because the
  plugin ships the extractor while a consuming project has no reason to
  carry a copy (NWM-156). Idempotent by its own event `key`, fails open on
  any error (never blocks a subagent's stop), and never prints the hook's
  stdin payload or the extractor's own output — see the hook's own header
  for its wall-clock budget and retry behavior.
- `scripts/script-analytics.py` — reads local Claude Code JSONL
  transcripts (same `~/.claude/projects/<slug>/` layout as
  `claude-cost-scan.py`) and appends one JSON object per line to an events
  file — one row per script-author/script-reviewer invocation,
  lint/selftest call, or SendMessage-resume round. `report` summarises that events file by script
  and by agent type. `record` appends a manual `live-run`/`accepted` event
  for the parts a transcript can't see (an owner trying the script by
  hand). A `record --note` is refused if it looks credential-shaped (a
  long opaque token, or a `key=value` pair whose key names a common secret
  word) before it ever reaches the events file.
- The hook writes to `docs/script-events.jsonl` by default (a sibling
  convention to `docs/cost-ledger.tsv` above — not committed by this
  plugin itself, since it is generated by usage, not shipped as a
  template).

```bash
# after a wave, see what the script lane actually cost
python3 scripts/script-analytics.py report --events docs/script-events.jsonl --format md

# scope to one session or one script
python3 scripts/script-analytics.py extract --events docs/script-events.jsonl --session <session-id>
python3 scripts/script-analytics.py report --events docs/script-events.jsonl --script scripts/foo.sh

# record that an owner tried a script by hand and accepted it
python3 scripts/script-analytics.py record --events docs/script-events.jsonl \
  --script scripts/foo.sh --event accepted --outcome pass --ticket PROJ-123
```

Run `scripts/script-analytics-selftest.sh` and
`hooks/script-events-hook-selftest.sh` to check both halves — both build
their own scratch fixture transcript trees and never read a real
`~/.claude/projects` tree.

### Real-world usage: `invoke`/`owner_wait` events and `report --usage`

Two more event types, on top of the authoring-lane ones above:

- `invoke` — one per Bash tool_use block, across every transcript scanned
  (main-thread and every subagent, any agentType, not just
  script-author/script-reviewer), whose command actually RUNS at least one
  `scripts/*.sh`, `scripts/*.py`, `hooks/*.sh`, or `hooks/*.py` path in an
  executable position of one of its shell segments — a `VAR=val`, `sudo`,
  or `timeout <n>` prefix in front of the invoked path is still detected.
  A lint-shaped command (its own arguments are files being linted, not
  run) never produces one. This is the quantitative signal behind "is a
  script actually being run, or does it just sit there" — `agent_type`
  carries `"main"` for a call found directly in the top-level session
  transcript, or the subagent's own agentType otherwise; `cause` carries
  `"selftest"` when the invoked path is itself a `*-selftest.sh`/
  `*-selftest.py` fixture.
- `owner_wait` — one per owner-attended interval found in any transcript
  scanned. A wait starts at whichever of a configured list of tool_use
  name prefixes is seen first (`OWNER_WAIT_TRIGGER_PREFIXES` in
  `scripts/script-analytics.py` — `AskUserQuestion` by exact name,
  `mcp__spokenly__` by prefix, out of the box; extend the list, don't edit
  the detection logic, to add another interactive tool), or — best-effort
  and explicitly marked UNVERIFIED — the transcript's last text-shaped
  assistant turn if it reads like a hand-off to a human (sign in, install
  an app, click in a console, etc). A wait ends at the next `"type":"user"`
  line in the same transcript; a still-open wait produces no event until a
  later extract run sees its end.

`report --usage` (instead of the default author/review/lint table) turns
those into a per-script table — `invocations`, `sessions`, `pass`/`fail`,
`first_used`/`last_used`, `lint_runs`/`selftest_runs`, `rework_rounds`,
`lint_wall_clock_s`, `author_usd`, `rework_ratio`, and a retirement `flag`
— plus an owner_wait summary (total owner-attended seconds per ticket in
the `--since`/`--until` window, and a wave-total row). Only NON-TEST
invocations count toward any of this: an invoke event with cause
`"selftest"`, agent_type `script-author`/`script-reviewer`, or a session
matching one of the script's own `author` events (the authoring session)
is excluded, and a `*-selftest.sh`/`*-selftest.py` fixture never gets its
own row at all. `flag` and the landing date it depends on are always
LIFETIME figures — computed from a script's entire history regardless of
`--since`/`--until` — so a retirement verdict never moves just because a
wave's window changed. Every OTHER per-script column IS windowed by
`--since`/`--until` when given: with a window,
`invocations`/`sessions`/`pass`/`fail`/`lint_runs`/`selftest_runs`/
`rework_rounds`/`lint_wall_clock_s`/`author_usd`/`rework_ratio` reflect
only that window's activity, not the script's lifetime. With no window,
these columns keep their pre-existing lifetime behaviour and the output
is byte-identical to before this ticket. `flag` follows a fixed
precedence, evaluated in order:

1. `>=10` lifetime invocations always reads `"keep"`, regardless of how
   recently the script landed.
2. Otherwise, once `>=15` days have elapsed since landing: `"retire?"` if
   fewer than `5` invocations landed within those first 15 days, else `-`.
3. Otherwise, once `>=7` days have elapsed since landing: `"flag"` if
   fewer than `3` invocations landed within those first 7 days, else `-`.
4. Otherwise (fewer than 7 days elapsed): `-` — not enough time has passed
   to judge usage at all.

This flags/proposes only — it does not retire anything by itself.
`scripts/script-retire.sh` is the mechanism that turns a `retire?` row
into an actual retirement: dry-run by default (prints the plan — script,
selftest, and `docs/scripts.md` row it would remove, plus the `##
Retired` line it would add — without touching anything), and `--yes
--ticket NWM-nnn` creates branch `retire-<name>`, deletes the
script/selftest/doc row, appends the `## Retired` entry, commits, and
lands via `scripts/land-branch.sh`. `cost-reviewer` lists `retire?` rows
in its wave review under "Retirement candidates"; `librarian` runs the
retirement at wrap-up (see that agent's "Script retirement" section).
Deletion, never a `scripts/retired/`/`docs/retired/` folder — an
LLM-readable graveyard of dead scripts costs tokens on every future read
for no benefit `git log` doesn't already give.

Every already-recorded `script`/`scripts` value is resolved to its CURRENT
repo-relative path by basename lookup against the real `scripts/`/`hooks/`
trees on disk, both going forward (at `extract`/`record` time) and, for
events already on disk, via the `backfill-script-paths` subcommand —
rerunnable, not a one-time migration, since a script moving directories
again needs this again:

```bash
# see what's actually getting used, and hand `retire?` rows to
# scripts/script-retire.sh per the procedure above
python3 scripts/script-analytics.py report --events docs/script-events.jsonl --usage --format md

# normalize every already-recorded script/scripts path to its current
# location (preview first, then apply)
python3 scripts/script-analytics.py backfill-script-paths --events docs/script-events.jsonl --dry-run
python3 scripts/script-analytics.py backfill-script-paths --events docs/script-events.jsonl
```

### Wave summary line

`report --usage` prints `# window rework_ratio: <n>` unconditionally
(unwindowed rework cost / author cost across every script, lifetime with
no `--since`/`--until` given — this line predates this ticket and its
unwindowed value is unchanged). When `--since` or `--until` IS given, two
more lines follow: `# window owner_wait_s: <n>` (the owner_wait summary's
wave-total, same number as the "total" row below it) and `# window
tickets_per_owner_hour: <n or ->` (distinct tickets with an accepted/pass
event in the window, divided by owner-attended hours from that same
total). Both are wave-scoped concepts with no lifetime equivalent, so
they print ONLY with a window — printing them unconditionally would grow
a plain unwindowed `--usage` call by two lines it never had before.
`tickets_per_owner_hour` reads `-` (not a divide-by-zero crash) whenever
the window's owner-attended hours are 0 — a window with zero owner_wait
events landing inside it while ticket(s) still land is a normal shape
(e.g. every owner_wait in that stretch ended just before the window
opened), not a bug.

### Per-ticket cost, and tracker status-duration events

`report --usage` also prints a per-ticket cost table (ticket / session /
agent_type / cost_usd), grouped from `author`/`review`/`rework` events only
— an `invoke` event always carries ticket `-`, so it groups nowhere — and
windowed by the same `--since`/`--until` the rest of `--usage` takes.

`status-durations` derives `status_duration` events straight from the
tracker's changelog, not from a transcript — the one subcommand in this
file that talks to the tracker at all:

```bash
python3 scripts/script-analytics.py status-durations PROJ-123 PROJ-124 \
    --events docs/script-events.jsonl
```

One event per status a ticket occupied, `duration_s` seconds each. The
read goes through `providers/tracker/jira/jira-api.sh raw GET
/issue/<TICKET>/changelog` directly — `provider.sh` (the tracker seam) has
no changelog verb, so this is a documented exception, the same one
`jira-backfill.sh` already sets a precedent for. `NW_DRY_RUN=1` (or
`--jira-api`'s own `--dry-run`, passed through the same way
`provider.sh` does) prints the exact request instead of issuing it,
resolving no credential. The ticket's still-current status is written with
`outcome: open` and its `duration_s` is corrected in place on a later run
(never re-appended as a duplicate); every other status is `outcome:
closed` and immutable once written. Does not paginate: a changelog with
more than one page is truncated to its most recent page, named on stderr.

## Bash-family report: ranking parameterisation candidates by evidence

A third, separate tool answering a narrower question than either lane
above: not "what did a wave cost" or "is a script getting used", but
"which repeated Bash invocation is actually a function in disguise" —
answered by counting, not by impression. A one-off scratchpad scan on
2026-09-19 found 39,652 Bash tool calls across 4,735 distinct command
families in the local transcript corpus, and counting reversed the wave's
first pick: a `gh` release family had been chosen as the pilot before
anyone counted, and counting showed it was comparatively rare.

- `scripts/bash-family-report.py` — streams every
  `~/.claude/projects/**/*.jsonl` file (same corpus as
  `claude-cost-scan.py`/`script-analytics.py`), collects every Bash
  `tool_use` block's `command`, and normalises each to a family key: a
  leading `cd <path> &&` and any leading `VAR=value` assignments are
  stripped, a heredoc form folds to `python3 heredoc` or `cat > heredoc`
  rather than being ranked by its body, and otherwise the family is the
  executable's basename plus its first non-flag argument (e.g.
  `./scripts/jira-api.sh raw ...` families as `jira-api.sh raw`). Families
  are ranked by call count; average command length (of the original,
  un-normalised command) is reported alongside it, since volume alone
  surfaces `grep`-shaped noise while length is what flags a call worth
  turning into a typed tool. `--since`, `--top`, `--projects-dir`, and
  `--format text|json`; `--projects-dir` is the same test seam
  `claude-cost-scan.py` and `script-events-hook.sh` use, so a selftest
  never reads the live corpus. `rtk discover` is adjacent but answers a
  different question — a rolling 30-day window ranked by RTK savings
  opportunity ("what should RTK proxy"), not "what is a function in
  disguise" over the whole corpus.

```bash
# rank the top 20 families by call count
python3 scripts/bash-family-report.py --top 20 --format text

# scope to a wave's window, machine-readable for trend tracking
python3 scripts/bash-family-report.py --since 2026-09-12T00:00:00Z --format json
```

Run `scripts/bash-family-report-selftest.sh` to check the normalisation
rules and every flag against fixture transcripts under
`scripts/fixtures/bash-family/` — structurally offline, never reads the
real `~/.claude/projects` tree.

This tool only ranks; it does not decide. Turning a ranked family into an
actual typed MCP tool, and picking the pilot, is out of scope here — see
the ticket that specified this report (WO-033) and the one that covers
the pilot pattern (WO-029).
