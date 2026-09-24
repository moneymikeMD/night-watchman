---
name: shell-scripting
description: Shared-lib conventions and the shipped-bug rules for scripts/ — bash 3.2 limits, subshell die, pipe_ok, secrets in argv, and structural network isolation in selftests. Load before writing or reviewing anything in scripts/.
---

# Shell scripting

The working subset script-author and script-reviewer both check against.

## The bar for a script

Before any convention below applies, check whether a script is warranted at
all. `scripts/` is warranted only if at least one holds: **reusable** (would
running it again in six months make sense — not "might someone want it"),
**owner must run it** (sudo, or interactive on a host the agent cannot
reach), or **touches a credential or writes to a host** (needs the guards
below even for a one-off). If none holds, the deliverable is a fenced
command block in the ticket, not a script.

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

## The five rules (each shipped as a bug)

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
3. **Secrets must not enter argv.** Mechanics: config on stdin
   (`curl_auth_config`/`curl_form_config`-style helpers) and exported
   `$ENV.NAME` in jq, never a bare CLI flag or an interpolated string.
4. **A credential-store call needs an explicit scope under a service
   account.** The interactive path passes; the unattended one dies. Helpers
   should default to the project's own scope/vault variable rather than
   omitting it.
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

## Fixtures are recorded, never authored

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
no `${var^^}`, no `readarray`/`mapfile`.

## Exit codes

`0` all clear, `1` a check failed, `2` a check **could not be evaluated**.
Unknown is worse news than known-bad; collapsing them hides a broken
credential behind a real finding.

## Lint

The project's lint script (shellcheck with `-x -P SCRIPTDIR`; every script
carries a `# shellcheck source=` comment because the source line is computed
at runtime). The zsh trap: unquoted `$FILES` does **not** word-split in zsh,
so a hand-run `shellcheck $FILES` checks one giant filename and reports zero
problems. A suspiciously clean result means check that first. Suppressions
need a reason at the site.

**Cap: two failed lint runs.** If the lint script fails twice in a session,
script-author stops and reports the failing case verbatim to the orchestrator
instead of running it a third time.

## Review scope: narrowed default

`script-reviewer` runs by default only for scripts touching credentials,
hosts, sudo, or any diff to `scripts/lib/*` (this project's shared library —
whatever this skill's "Shape" section says a script sources for common
helpers). Every other script ships on the author's lint + selftest alone; the
reviewer runs on owner/orchestrator request, not automatically.

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
This is a credential path, so `script-reviewer` is mandatory regardless of
the narrowed-default rule above, and the selftest must prove a planted
secret never reaches combined stdout+stderr of a full run.
