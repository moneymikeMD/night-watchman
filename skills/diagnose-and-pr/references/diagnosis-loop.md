# Diagnosis loop

Loaded only when actually diagnosing — not on every `diagnose-and-pr` run.
A discipline for hard bugs: skip a phase only when explicitly justified.

*Adapted from mattpocock/skills diagnosing-bugs, 2026-09-14.*

## The gate

No hypothesis until one named command — a script path, a test invocation,
a curl — that you have **already run at least once** (show the invocation
and its redacted output) goes red on *this* symptom. Not "runs without
erroring": it must catch this specific bug and go green once fixed.

If you catch yourself reading code to build a theory before this command
exists: stop. Jumping to a hypothesis before the loop exists is the exact
failure this discipline prevents.

## Build the loop, cheapest first

1. **Failing test** at whatever seam reaches the bug.
2. **HTTP probe** (curl / script) against a running dev server.
3. **CLI plus fixture diff** — invoke with a fixture input, diff stdout
   against a known-good snapshot.
4. **Captured-trace replay** — save a real request/payload/event log,
   replay it through the code path in isolation.
5. **Throwaway harness** — a minimal subset of the system (one service,
   mocked deps) exercising the bug in one function call.
6. **Fuzz** — for "sometimes wrong output", run many random inputs and
   look for the failure mode.
7. **`git bisect run` harness** — if the bug appeared between two known
   states, automate "boot at state X, check, repeat".
8. **Old-vs-new differential** — same input through two versions/configs,
   diff the outputs.
9. **HITL script, last resort** — if a human must click, drive them with
   `templates/hitl-loop.sh` so the loop stays structured.

A loop is done when it is red-capable, deterministic, fast, and
agent-runnable unattended (human only via the HITL template).

## Flaky signals

The goal is a higher reproduction rate, not a clean repro. Loop the
trigger, parallelise, add stress, narrow timing windows. A 1% flake is not
debuggable; keep raising the rate until it is.

## Minimise

Once red, shrink to the smallest scenario that still goes red. Cut one
element at a time, re-running the loop after each cut. Done when every
remaining element is load-bearing — removing any one makes it go green.
The minimised repro becomes the regression test's seam in Phase 5 below.

## Ranked hypotheses

Generate 3 to 5 hypotheses before testing any of them — single-hypothesis
generation anchors on the first plausible idea. Each must be falsifiable:
"If `<X>` is the cause, then `<changing Y>` makes the bug disappear."
A hypothesis with no stated prediction is a vibe — discard or sharpen it.

This agent runs unattended, so the ranked list has no human checkpoint to
show it to. Record it in the PR body's Why section instead, most-likely
first, so the reviewer sees the reasoning, not just the winner.

## Instrument

One variable per probe, mapped to a specific hypothesis. Tag every debug
line with a unique prefix, e.g. `[DEBUG-a4f2]`. Cleanup is a single grep
for the prefix that must come back empty before the PR is opened.

**Perf branch.** Logs are usually wrong for regressions. Establish a
baseline measurement first, then bisect. Measure, then fix.

## Regression test only at a correct seam

A correct seam exercises the real bug pattern as it occurs at the call
site — not a shallow single-caller test standing in for a chain that
triggered a multi-caller bug. If no correct seam exists, that absence is
itself the finding: state it in the PR's Scope section rather than writing
a test that gives false confidence.

## Redact

Every pasted output and captured artifact is redacted (`<REDACTED>` in
place of the secret) before it appears anywhere — the PR body, this
loop's instrumentation, a HITL capture. Complements the agent's existing
"never print a secret" rule.
