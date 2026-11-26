---
name: shell-scripting
description: Shared-lib conventions and the shipped-bug rules for scripts/ — bash 3.2 limits, subshell die, pipe_ok, secrets in argv, and structural network isolation in selftests. Load before writing or reviewing anything in scripts/.
---

# Shell scripting

The working subset script-author and script-reviewer both check against. The reviewer's checklist is
[references/review-checklist.md](references/review-checklist.md), so the author reads the same rules.

## Pick the lane first

The owner, 2026-11-25: "What I don't want is me wasting hours of my time watching the agent write a
bulletproof script that only gets used 2 or 3 times, if that." Most scripts run a handful of times, so
the cheap lane is the default and hardening is earned.

| Lane | When | Deliverable |
| --- | --- | --- |
| **Command block** | The script bar (below) fails | No script: the exact commands in a fenced block in the ticket |
| **Capture** (default) | The bar holds and no hardened trigger does | One file under about 80 lines; or a bounded edit to an existing script when the diagnosis is supplied |
| **Hardened** | A hardened trigger holds | A blueprint and ledger, a selftest on recorded fixtures, the project's lint script, a `script-reviewer` round |

**Hardened triggers.** Any one is enough:

1. **Unattended**: it runs with nobody watching (cron, a timer, a hook, CI, an alert path).
2. **Destructive**: it makes a destructive or hard-to-reverse change on a host or through an API
   (deletes data, overwrites a config without keeping the previous one, rotates a secret).
3. **Shared library**: it changes the shared shell library (`scripts/lib/`, `providers/lib/`).
4. **Earned**: the project's usage log shows it has been run enough to be worth it, or the owner asks.

When a brief names a lane, take it. When it names none, take capture unless a trigger holds, and say in
the first lines of the reply which trigger holds, or that none does. A script that reads a credential
or writes to a host takes capture unless it is also unattended or destructive (owner, 2026-11-25): the
three rules below cover the credential.

### The script bar

`scripts/` is warranted only if at least one holds: **reusable** (would running it again in six months
make sense — not "might someone want it"), **owner must run it** (sudo, or interactive on a host the
agent cannot reach), or **touches a credential or writes to a host**. If none holds, the deliverable is
a fenced command block in the ticket, not a script.

## Three rules in every lane

Each shipped as a bug, and none costs more than a line. A capture brief that pastes commands breaking
them is transcribed with the rule applied, not copied as run.

1. **No secret in argv.** Not `curl -u`, `-H "Authorization: Bearer $T"`, a key in the URL,
   `jq --arg` with a credential, or `env VAR=val cmd` (the assignment is env's own argv). Config goes
   to curl on stdin (`curl --config -`); in jq, `export` then `$ENV.NAME`. A key file lives in a
   `tmpfile`, removed on exit, never at a fixed `/tmp` path.
2. **Raw API output goes through the redaction helper.** Any mode that prints an API's JSON unfiltered
   (`raw`, a full-object dump, `jq .`) pipes it through the project's redactor first.
3. **Every credential-store call names its scope.** For 1Password, every `op` call names its vault
   (`--vault`, an `op://<vault>/...` reference, or a helper that defaults to the project's vault).
   Without it the interactive path passes and the service-account path dies.

## Capture lane

The default: commands already run live ("save that as a script"), or a bounded edit to an existing
script. Transcription, not design.

**New script from commands already run.** `#!/bin/bash`, `set -euo pipefail`, a header comment with a
`Usage:` block that `--help` prints, a flag for each value that varied (defaults from the session), the
commands as run with the three rules applied, dying on an empty or `null` result. Source the shared
library when the script needs a credential, prints API output or reaches a host. Under about 80 lines.
No selftest, no fixtures, no reviewer. Check with `shellcheck <file>` and `bash -n <file>`, plus `--help`
and argument-validation runs with every host variable pointed at `127.0.0.1`. Never run it against a
host; the main thread runs it live.

**Bounded edit to an existing script.** The brief names the script, the live diagnosis (what fired,
what was observed) and the exact change. Missing either the diagnosis or the change: hand it back and
say which. Make that change and nothing else, in the script's existing style. Run `shellcheck`,
`bash -n` and the script's existing selftest, and hand back the diff and the three results.

## Hardened lane

- **Blueprint before code**: the stages in order, what each reads or writes, its flags and gating.
- **Spike first.** An API-facing script starts with a recorded live run against a throwaway target,
  run by the main thread; the fixtures come from that run (below). The author never reaches a host.
- **A destructive change is staged**: `--dry-run` or a list-first mode, stage → validate → apply with
  the previous version kept, and a floor a bad input cannot get past.
- **A selftest on recorded fixtures**, proven red by mutating the script under test, offline by
  construction (rule 5 below), then the project's lint script.
- **Ledger**: answer [references/review-checklist.md](references/review-checklist.md) item by item.
- **Review**: one `script-reviewer` round; a second only when the first reported a CRITICAL or HIGH.
  Findings reach the author as failing cases, never as fix code.

## Shape

Every script sources the shared library — here `scripts/lib/kit.sh`
(`die`, `warn`, `need`, `show_help`, `tmpfile`, `kit_exec`, `kit_on_exit`,
`known_command`); `providers/lib/kit.sh` is its copy for provider scripts:

```bash
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"
```

`pipe_ok`, `blank()` and the curl-config helpers named below are
conventions a script or a domain library (`providers/tracker/jira/lib/http.sh`
has `curl_auth_config`) defines; `kit.sh` does not ship them.

API client shape: header comment → source the library → resolve credentials
**once at startup** (not per request) → a request helper → one `view_*` per
subcommand → `case` dispatch with a `raw` passthrough piped through a
redaction helper.

Read-only clients stay read-only by design; writes live in sibling scripts.
Scripts that change host state split the write from its consequence:
stage → validate → apply, previous version kept.

A script earns its place when it: takes arguments rather than hardcoding one
target, validates inputs and fails loudly, is safe to run twice, and answers
`--help` (via a shared help function that prints the header comment).

- Comments are for the header, not the body: a function gets at most 4 lines
  above it, and any rationale already recorded elsewhere (a decisions log,
  durable project memory) is deleted rather than duplicated in-line.

## The shipped-bug rules

1. **`die` inside `$( )` does not stop the script.** Command substitution
   runs in a subshell. Fallible helpers *return* non-zero and print nothing:
   `user=$(field_helper "$ITEM" username) || die "could not read username"`.
2. **A failing pipeline under `pipefail` kills the script before the check
   meant to report it.** Append `|| pipe_ok` to pipelines whose emptiness a
   later `[ -s ... ] || die` is supposed to explain — otherwise the script
   exits 1 with no message at all.

   The mirror image shipped too: a **reader that stops early**
   (`grep -q`, `head -1`, `awk '... exit'`) makes the writer die of SIGPIPE
   (exit 141), and `pipefail` reports the pipeline failed even though the
   match was found. `git show FILE | grep -q PATTERN` passes on a small
   file and fails on one larger than the pipe buffer; a selftest built on
   it flaked a third of its runs and `land-branch.sh` could exit 141 before
   touching anything. Readers consume to EOF — `grep -c PATTERN >/dev/null`,
   `awk` without an early `exit` — unless the writer's exit is irrelevant,
   in which case `|| pipe_ok` says so explicitly.
3. **Secrets must not enter argv**, and **4. a credential-store call names
   its scope**: the first and third always-on rules above. Helpers such as
   `curl_auth_config`/`curl_form_config` put the config on stdin; helpers
   should default to the project's own scope/vault variable.
5. **A test invocation never reaches a live host — and only the target-host
   variable guarantees that.** Any script with an apply/POST/run path is
   tested with every relevant target-host variable exported to an
   unroutable or loopback address, or run behind stubs on `PATH`. "Do not
   run against hosts" in a brief is prose, not a guard.

   **No one variable covers everything, so know which governs your path.**
   API-client variables govern only their own client. Anything that reaches
   a host over SSH should resolve through a single umbrella variable first,
   then a per-host fallback — the umbrella variable is the one to reach for
   because it covers hosts added after a test was written. Set it, never
   blank it — an empty override that carries nothing (an unset variable or a
   failed command substitution assigned in) must stop the run rather than
   fall through to a live default in silence.

   `--dry-run` is **not** that guard. It promises *changes nothing*, not *no
   network* — a dry run typically still reads live state to report what it
   would do. So a dry run is safe to point at production and unsafe to point
   at production *by accident*: reach for the flag when you want to inspect,
   and for the loopback-export-plus-stubs combination when you want
   isolation. Never one in place of the other.

   A selftest that drives a dry-run path under a logging stub must fail on
   any non-read call, and the assertion needs to be discriminating for every
   gate it covers — a stub too strict to reach credential resolution can
   pass green while proving nothing about the gate it exists to test.

Sixth, smaller: render fields through a `blank()`-style helper before
`column -t` — an empty value shifts every later column left, silently. A
`// "-"` default in jq does not catch an actual empty string; that is what
the helper is for.

## Fixtures are recorded, never authored (hardened lane)

Every wrapper subcommand or API a new script consumes gets its real output
captured once — a read-only call runs live; a write call comes from a real
recorded run — redacted through the project's own redactors, and saved
under `scripts/fixtures/<wrapper>/<subcommand>.<case>.txt`. Stubs replay
those files. A fixture typed from what the author expects the shape to be
is not a fixture, it is a second copy of the author's guess, and
script-reviewer reports it as a finding regardless of how many mutants the
suite passes against it. For API-facing scripts, fixtures come from a live
spike against a throwaway target first, not from reviewing stubs.

Author and reviewer writing a stub from the same guess about an interface
means the mutation suite can only prove the script matches its own fixture,
never that the fixture matches reality.

## Why a self-check is not evidence

A check written to verify its own output is only as independent as its
oracle. If the check and the write path share a parser, a heading matcher, a
counter, or a probe, a bug in that shared piece cannot make the check
fail — it can only make both sides wrong the same way. Before trusting a
self-check, name what it shares with the code it verifies, and run it once
against input deliberately corrupted — a check that has never been observed
failing has not been tested, only exercised.

## Environment limits

Target **bash 3.2** (e.g. stock macOS `/bin/bash`): no associative arrays,
no `${var^^}`, no `readarray`/`mapfile`. Under a non-C locale its `[a-z]` also
matches uppercase, so a validating `case` pattern spells the letters out.

## Exit codes

`0` all clear, `1` a check failed, `2` a check **could not be evaluated**.
Unknown is worse news than known-bad; collapsing them hides a broken
credential behind a real finding.

## Lint

Capture: `shellcheck` and `bash -n` on the file. Hardened, and any change a
landing will lint: the project's lint script (shellcheck with `-x -P SCRIPTDIR`; every script
carries a `# shellcheck source=` comment because the source line is computed
at runtime). The zsh trap: unquoted `$FILES` does **not** word-split in zsh,
so a hand-run `shellcheck $FILES` checks one giant filename and reports zero
problems. A suspiciously clean result means check that first. Suppressions
need a reason at the site.

**Cap: two failed lint runs.** If the lint script fails twice in a session,
script-author stops and reports the failing case verbatim to the orchestrator
instead of running it a third time.

## Wizards for `human_steps`

When a `mixed` ticket's `human_steps` exceed a few actions, or ask the owner
to capture values (an API key, a token, a client id), the deliverable is a
wizard stages file (see `templates/wizard-stages.sh`), not a fenced command
block: `set -euo pipefail`, source `scripts/lib/wizard.sh`, then `stage`/
`say`/`step`/`open_url`/`ask`/`ask_secret` through each human action in
order. Author the stages; never hand-edit `wizard.sh` itself.

The one rule that matters: `ask_secret` never writes a raw value to disk.
It pipes the value on stdin to a caller-named sink command (the secrets
provider's underlying CLI, or `gh secret set`) and records only the
resulting reference locator via `write_env` — never the secret itself.
A wizard is a credential path: its selftest must prove a planted secret
never reaches combined stdout+stderr of a full run.
