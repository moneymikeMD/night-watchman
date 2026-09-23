# Testing philosophy

Scripts that touch a live system earn extra discipline in how they are
tested, not just in how they are written.

## A script never touches a live target as a side effect of being tested

Any script with an apply/POST/write/mutate path must be tested with every
target-system variable pointed at an unroutable or loopback address
(`HOST=127.0.0.1`, roughly), or through a `--dry-run`/`--check` path that
stops before the network call. A comment or a brief instructing "do not run
this against production" is prose, not a guard — prose gets skipped under
time pressure, copy-pasted into a context where it no longer applies, or
simply not read. The test environment itself must be structurally unable to
reach the real target, so that running the test suite is safe by
construction, not by discipline.

A backup-job script's test suite once issued a real write against
production infrastructure and was rejected only because one field happened
to be invalid. The isolation had been a convention stated in a comment, not
a structural guarantee, until this rule was adopted in response.

## Two sibling disciplines

**Fixture provenance.** Every selftest stub should trace to a recorded real
response — a file captured from an actual, read-only call — not an authored
guess at what the response probably looks like. A hand-typed fixture tends
to omit exactly the survivable detail (a redacted field, an extra prefix
line, an unusual error shape) that the real interface actually produces,
because the person typing it already knows what they expect to see. See
`agents/script-reviewer.md`'s "fixture provenance" checklist item.

**Self-verification independence** — the name-the-oracle rule. A self-check
that shares a parser, heading matcher, counter, or probe with the write path
it verifies can only agree with the bug it is meant to catch. It is
unproven until it has been observed *failing* on deliberately corrupted
input; a check that has only ever passed has not actually been tested. See
`agents/script-reviewer.md`'s "self-verification must name its oracle" item,
and the README's false-success story.

Both disciplines and the isolation rule above point at the same thing:
a check that cannot fail, or a test that cannot reach the real target,
proves nothing about the thing it claims to protect.

## Testing a skill or agent change

Ported from pstack's `eval` skill, 2026-09-14. Five rules, held to by
`evals/` cases here:

- Candidate never sees eval/test/judge/candidate — `evals/librarian`,
  `evals/researcher`, `evals/diagnose-and-pr` ask for a plan, not a test.
- Prompt is organic, paths sanitized (`example.invalid`, not a live host).
- Judge sees labels, not model or variant names.
- Grade from what the transcript shows was read/done, not self-report —
  `evals/script-reviewer`/`script-author` use `regex` graders against
  fixed identifiers, not an `llm` judge scoring self-description.
- Read every output yourself — see `evals/README.md`'s "Known environment
  flakiness": a hung run reads as failure but isn't one.

## What a selftest structurally cannot catch, and what to do about it

The isolation above is not a limitation to work around — it is what lets
these selftests run on a public repo with no credential configured. But it
has a consequence worth naming, because it cost a released defect.

A selftest stubs every seam that reaches outside the process. So it proves
the code does what the test **enumerates**. It cannot prove anything about a
seam it replaced with a stub, and it cannot notice a cost that only appears
when the real thing runs many times.

NWM-171 is the worked example. NWM-155 moved `kit.sh`'s tmpfile registry
behind an `EXIT` trap. A bash `EXIT` trap does not run when `exec` replaces
the process image, and `providers/lib/provider.sh` execs on **every** provider
verb call — so every call leaked a registry file. 48 assertions across three
copies of `kit.sh` were green and blind: none of them execs, because execing
into a real provider implementation is exactly what the isolation rule
removes. It surfaced days later, after release, by looking at `TMPDIR`.

So: **a change to a hook, a provider, or anything reached through
`${CLAUDE_PLUGIN_ROOT}` is not done when its selftest is green.** Run it.

```bash
scripts/dev-install.sh          # this checkout becomes the installed plugin, live
scripts/dev-install.sh --status # confirm it is a symlink, not a stale copy
scripts/dev-install.sh --uninstall
```

An edit is live with no reinstall. Then do ordinary work with it and watch
what the work produces — `ls "$TMPDIR" | wc -l` before and after a session is
the check that would have caught NWM-171 in minutes. Never reach for `claude
plugin update` to refresh it: at an unchanged version that command is a no-op
that prints success and leaves the old copy, which is worse than not trying.

The two disciplines answer different questions. The selftest asks "does this
do what I said?". The dev install asks "what does this do that nobody
thought to ask about?". A release should not be the first time the second
question gets asked.

## Checking these scripts with shellcheck

Run it from inside `scripts/`, with `-P .` so it can resolve the relative
`source`/`.` lines between the scripts and `lib/kit.sh`:

```
cd scripts && shellcheck -x -P . land-branch.sh ai-toolkit-root.sh \
    land-branch-selftest.sh ai-toolkit-root-selftest.sh lib/kit.sh
```

`providers/` carries its own copy of `lib/kit.sh` (see that file's header
for why), so it is checked the same way from its own directory:

```
cd providers && shellcheck -x -P . config-selftest.sh lib/provider.sh \
    lib/config.sh lib/kit.sh
```

Without `-P .` (e.g. invoking `shellcheck -x scripts/*.sh` from the repo
root, or checking one file at a time from elsewhere), shellcheck cannot
find the sourced file and reports SC1091 — an INFO-level finding, but
shellcheck's default minimum severity is `style`, so an unresolved-source
INFO still makes the run exit non-zero even though nothing is actually
wrong. `-S warning` (raising the minimum severity so INFO-level findings
are ignored) is the fallback when `-P .` genuinely cannot be arranged; `-P
.` is the one that actually fixes the root cause instead of hiding it.
