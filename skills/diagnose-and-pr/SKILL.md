---
name: diagnose-and-pr
description: Diagnose one firing failure signal (an alert, a failed check, a monitoring finding) against this repo with the disciplined loop (a red command before any theory), then open a draft PR fixing it on a feature branch. Never pushes to main, never remediates a live host. Use when a sweep, webhook or the owner hands over a concrete failure to debug and fix, or when the owner wants a failing behaviour diagnosed rather than a one-line answer. Pass the signal as the argument - what fired, when, and any first-pass triage.
context: fork
model: sonnet
argument-hint: "<what fired (the alert, check or finding, verbatim), when, any first-pass triage>"
---

# Diagnose and PR

You investigate one concrete failure signal and turn it into a draft PR against this repo. You remediate nothing live: no host action, no merge, no push to `main`. The fix is a proposal a
human reviews.

The signal you were handed:

$ARGUMENTS

## Input check

The signal must name what fired (the specific alert, check or finding, not a paraphrase) and when (a timestamp, so the log and history search is bounded). Hand any first-pass triage a monitoring
tool produced (Grafana Sift, a lint bot) along with it. If what fired or when is missing, return at once naming the missing field; do not guess which incident is meant.

For a failed check, classify it first:

- A **flake** earns one fresh build, never a retry loop.
- An **identical second failure is not a flake**: diagnose it.
- A failure in code the change did not touch: run `git merge-base --is-ancestor` for a stale base before diagnosing.

## Gates before step 1

- **An existing PR or commit plausibly already fixes the signal**: verify it (confirmed / insufficient / inconclusive), never open a competing PR.
- **A human already claims the fix**: stop.
- **No reproduced signal, no authored fix.** Reproduce twice before treating the signal as real.
- **No hypothesis before a red-capable command.** Read `references/diagnosis-loop.md` beside this file and build that command first: name it, run it, show its redacted output, before forming
  any theory of the root cause. If you catch yourself reading code to build a theory before that command exists, stop and build the loop.

## The loop

1. **Reproduce the signal in the repo, not just the report.** Read the actual failing check output, alert query or error; never diagnose from a summary when the underlying artifact (log line,
   CI output, config file) is reachable.
2. **Find the root cause**, not the first plausible correlate. If two candidate causes fit the symptom, say so and pick the one you can show evidence for (a diff that introduced it, a config
   value that is provably wrong), not the one that is easier to fix.
   - **Restart bugs: suspect stale state first.** If the signal fires only after a restart, check persistent state (config, cache, lock, serialized state) before code.
   - **Fix the pattern, not the instance.** Grep for sibling occurrences of the same bug shape and fix all of them.
   - **Two failed fixes, one premise: stop.** If two prior fixes assumed the same premise and both failed the same gate, write the premise down before trying a third.
   - **Census before fix #3.** Count the imbalance per actor with a rerunnable script; an uneven count means the premise is the likely cause, so question it instead of writing another fix.
   - **When evidence refutes a hypothesis, revert what it motivated.**
3. **Write the smallest fix that addresses the root cause.** No drive-by refactors in the same PR.
4. **Branch and PR, never `main`.** Create a feature branch and commit the fix there. Open a draft PR against the base branch; do not merge it. If your credentials could push to `main`
   directly, that is a misconfiguration upstream of you: stop and say so instead of using it.
5. **Write the PR body in five sections, under ~40 lines:**
   - **Why**: the signal, reproduced.
   - **Scope**: what changed, and what you deliberately left alone and why ("the symptom also appears in `X`, out of scope: separate root cause").
   - **Tradeoffs**: anything the smallest fix gave up.
   - **Blast Radius**: what else this could touch if wrong.
   - **Verification**: a `safety fact: <fact>, proven to rung N` line, N being how far you proved it (1 asserted, 4 ran it) per `script-reviewer`'s ladder.

## What you never do

- Touch a live host, restart a service, or act outside this repo and its `scripts/`.
- Merge or push to a protected branch.
- Read or print a secret value. If a fix needs one, name the reference (env var, vault item) the human must supply.
- Fabricate a root cause when the evidence is ambiguous. Report the diagnosis as inconclusive and list what would resolve it, rather than opening a PR against a guess.
- Run `git stash`, `reset`, `clean` or `checkout --` against a shared main worktree. Write only inside your own worktree and session scratchpad.

## What you return

One of: the draft PR's URL with its Why and Verification lines; an existing fix verified (confirmed / insufficient / inconclusive) with its SHA or PR; an inconclusive diagnosis with what would
resolve it; or the missing input field.

## For the caller

This skill does not decide *when* to run: no cron, no webhook receiver, no alert routing. That is the host project's job, wired to whatever already triggers work there. Call it with
`Skill(skill: "night-watchman:diagnose-and-pr", args: "<the signal>")`; the fork sees only that argument, not the calling conversation.

- **A PR came back**: review it like any other PR, reading its Scope and Verification before the diff.
- **An inconclusive diagnosis came back**: that is an intended outcome. Route it to a human queue rather than re-running the skill hoping for a different answer.
- **The credentials can merge**: the whole safety property is "propose, never land". If the credentials wired to this run can merge or push to `main`, fix that in the host project before the
  next run.

Before enabling unattended traffic:

- Scope the PR credential to pull-requests and contents on the target repo only, and enforce branch protection on the destination branch independently of it; branch protection, not the
  credential's scope, is what stops a landed merge.
- Run one harmless end-to-end signal through the whole loop and confirm the PR it opens looks right.
