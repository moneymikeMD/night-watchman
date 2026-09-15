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

## Checking these scripts with shellcheck

Run it from inside `scripts/`, with `-P .` so it can resolve the relative
`source`/`.` lines between the scripts and `lib/kit.sh`:

```
cd scripts && shellcheck -x -P . land-branch.sh known-issue.sh \
    land-branch-selftest.sh known-issue-selftest.sh lib/kit.sh
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
