# script-reviewer checklist

The checklist a `script-reviewer` round works, and the one a hardened-lane author answers item by item before handing a script over. Items are in order of past damage. The reviewer runs
for the hardened lane only (`../SKILL.md`, "Pick the lane first"); a capture-lane script is reviewed only on owner or orchestrator request.

## Gate

An API-facing script needs a recorded live run against a throwaway target before it ships: iteration against the real API is where its fixtures come from. With none, the first finding is a
blocking HIGH naming that requirement, and the verdict cannot be SHIP. Then review the script in full anyway: a round that stops at the gate finds none of the bugs it was started for.

## Items

0. **Lane and bar.** Does the script meet the script bar (reusable, owner must run it, touches a credential or writes to a host)? Does a hardened trigger hold (unattended, destructive, the shared
   library, earned by use)? A script meeting no bar is a LOW, "should be a command block"; a hardened-lane build with no trigger is a LOW, "capture lane". Neither is grounds to skip the rest.
   A timezone-setter script once went through author, reviewer and selftest while meeting no bar at all.
1. **Secrets in argv or output.** `curl -u`, `-H "Authorization: ..."` with a variable, `jq --arg` with a credential, `env VAR=val cmd`, an `echo` of anything credential-shaped, raw API output not
   piped through the redaction helper, a "show secrets" flag near a default path. A secret surfacing by another route: an error body, a URL, a temp file. Credential-bearing data on disk outside a
   guarded tmpfile or state-dir helper with 0700 permissions.
2. **Subshell `die`.** Any `$( )` whose inner failure is meant to stop the script, including a helper called on a command line (`curl ... "$(api_key)"`). The pattern is `x=$(helper) || die "..."`:
   the helper returns, the caller decides.
3. **pipefail vs. deferred checks.** A pipeline that may legitimately fail ahead of an explicit `[ -s ... ] || die` needs `|| pipe_ok`, or the script exits silently before the check that would have
   explained it. The mirror image: a reader that stops early (`grep -q`, `head -1`) under `pipefail` makes the writer die of SIGPIPE.
4. **Credential-store scope omission.** Every credential-store access carries an explicit scope or vault, directly or through a shared-library default. Interactive success proves nothing; the
   service-account path is the one nobody watches.
5. **Bash 3.2.** Associative arrays (`declare -A`), `${var^^}`, `readarray`, `mapfile`: all break on stock macOS `/bin/bash`.
6. **Idempotency and destructiveness.** Safe to run twice? Does a write stage and validate before it commits, and keep the previous version? Does it verify its outcome rather than trusting the
   transport's exit 0 (a 200 or a clean scp is not a deploy)? Can it push an empty file over a live one? Does a delete have a dry-run and a floor? What happens if the previous run crashed at every
   possible point?
7. **Read/write separation.** A read-only API client gaining a write subcommand is a design regression; the write belongs in a sibling script.
8. **Interface hygiene.** Arguments, not hardcoded targets; inputs validated and failing loudly; `--help` via a shared help function; exit codes meaningful ("could not evaluate" must not masquerade
   as "check failed", or the reverse).
9. **Rendering.** Empty fields blanked before `column -t`; an empty value shifts every later column silently.
10. **Claims are proven, not read.** For every guarantee a header comment or docs entry makes ("tmpfile removed on exit", "never prints a value", "safe to run twice"), name the test that observes the
    effect, or report the claim UNPROVEN. When a security property rests on a shared helper, review the helper by running it: a shared helper's cleanup once failed silently for weeks while three
    script reviews passed, each taking the convention on faith.
11. **Shared-library blast radius.** A diff to the shared shell library gets its own pass: who sources it (`grep -rl` across `scripts/`), what inherits through `$( )`, `exec` and concurrent runs,
    which scripts install their own `trap`. Verify signal behaviour in a child process (exit 130/143), not by reading the trap line.
12. **Self-verification names its oracle.** A self-check sharing a parser, heading matcher, counter or probe with the write path it verifies is a finding, never evidence, and is UNPROVEN until
    observed failing on deliberately corrupted input. One script printed "Migration OK" on a fence-split entry because its self-check reused the heading matcher that did the splitting.
13. **Fixture provenance.** Each stub a selftest replays names the recorded output it stands in for, or run one live read-only call of that subcommand and diff its shape. An authored stub is a HIGH
    however many mutants the suite kills: passing mutants prove only that the script matches the stub.
14. **Hollow selftest check.** Would the selftest still pass if every stubbed command returned empty? Five shapes that would: weak or no assertion, mock-or-absence only ("was called"),
    self-referential (the expected value comes from the code under test), constant pin, fixture-asserts-fixture.

## Safety fact and proof rung

For a diff touching the shared library, a credential, a host or sudo: name the one fact that makes the diff safe, then how far you proved it. 1, you said so (worthless alone); 2, you pointed at the
line; 3, you walked the failure step by step; 4, you ran it (a test that calls the real code and fails loud if wrong); 5, you reproduced it against the running system. A safety fact short of rung 4
is reported as not settled.

## Python lane (`.py` only)

First: a `.py` that runs commands against a live target system is rejected. Then the items above where they translate: lint clean through the project's lint script; no secret in argv or an
f-string into a subprocess (item 1); the same target-host isolation variable as the bash equivalent (item 8); raw output filtered before stdout (item 1); `--help`, idempotent, arguments not a
hardcoded target. A file-granularity suppression table (a `per-file-ignores` block) that blinds the lane to new findings is a finding on sight. Do not invent a Python-only failure mode without a
cited incident.

## Running the review

Bash is for the project's lint script and targeted `shellcheck -x -P SCRIPTDIR <file>` only; never execute the script under review. Include lint's verdict. Trace a hypothetical failure to a real
call site before flagging it; if every finding is a nit, say the script is fine.

## Report format

- One line per finding: `path:line — severity — problem — fix`. Severity by blast radius. No praise, no style nits that do not change behaviour.
- **Report failures, not fixes.** The deliverable is the failing case and its evidence: what input, what happened, what should have happened. Proposed code is labelled `UNTESTED HYPOTHESIS` and kept
  to one line; the author owns and tests the fix. Two review comments once carried fix code the author implemented verbatim, and each introduced a worse regression than its finding.
- End with a verdict: SHIP, SHIP WITH FIXES (naming the blocking ones), or DO NOT RUN AGAINST A LIVE SYSTEM.
- The last line is the tally, each finding counted once at its final severity: `FINDINGS: CRITICAL=<n> HIGH=<n> MEDIUM=<n> LOW=<n>`. The ledger reads its counts from it.
