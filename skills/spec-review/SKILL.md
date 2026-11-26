---
name: spec-review
description: The rules a finished ticket branch is judged by before it lands — the repo's required checks, issues.py scope, each Solution item done, partial, missing or done differently, behaviour no ticket section asked for, a verify that would pass without the intended effect, and the LAND / LAND AFTER FIXES / DO NOT LAND verdict. Load to review a ticket branch against its own ticket, to land a branch as wave-supervisor, or to check your own branch before reporting it done.
---

# Spec review

Judge a finished branch against the ticket that asked for it, not against style: style stays with `/code-review` and `/simplify`. The review is read-only. It never edits a file, never runs a
command against a live system, and never marks a ticket's verify as met; running the repo's own checks against the checkout is within that, since it writes nothing.

Input: ticket id, branch (or its worktree), base ref.

## Process

0. **The repo's required checks, always.** Run `${CLAUDE_PLUGIN_ROOT}/scripts/required-checks.sh --repo-root <branch worktree>` before you look at the ticket at all, naming the worktree
   explicitly: the plugin cache the script is installed into is not a git checkout, so an invocation without `--repo-root` reviews the wrong tree or nothing at all. This step is unconditional; a
   brief that says nothing about gates has not waived it. The script discovers the blocking set at run time (the `required_status_checks` contexts on the default branch's ruleset, falling back to
   the job names in `.github/workflows/ci.yml`), so never carry your own list of which checks exist. Exit codes: `0` all ran and passed, `1` one failed, `2` the script could not start, `3` nothing
   failed but a check could not be run here. If the script is missing or exits `2`, say so in the verdict and run whatever the discovered set names by hand; do not skip the step.
1. Run `issues.py scope <ticket-id> <base-ref>` (add `--source jira` when the project's tracker is jira). Every path it reports UNDECLARED is a finding: the ticket's `touches`/`appends` did not
   cover it. Get `issues.py`'s path from `${CLAUDE_PLUGIN_ROOT}/scripts/work-order-root.sh --issues-py`.
2. Read the ticket's Problem, Solution, Decisions and Out of scope, then `git diff <base-ref>...HEAD`.
3. For each Solution item: present in the diff (done), partially done, missing entirely, or done differently than stated (wrong-implementation).
4. Flag anything the diff does that no ticket section asked for (unrequested).
5. **Hollow-verify check.** Would the ticket's `verify` block pass without the ticket's intended effect? Use script-reviewer item 14's five hollow shapes: weak or no assertion, mock-or-absence
   only, self-referential, constant pin, fixture-asserts-fixture. Report any verify step that only proves it was called, not what it should prove.

## Report

Open with the required-checks line, naming every discovered context and its result, before the findings table:

    required checks (branch ruleset): selftests PASS, docs-site UNRUNNABLE (…), comment-lint FAIL

Then one row per finding, quoting the ticket line it checks against:

| Finding | Ticket line | Missing / Partial / Unrequested / Wrong-impl / Hollow-verify / Required-check |
|---|---|---|

A failed required check is its own row, with the check's name in the Finding cell and the first lines of its output quoted.

End with a verdict on its own line, followed by the commit it covers as `reviewed head <full SHA>`:

- **LAND**: every Solution item done, no UNDECLARED paths, no hollow verify, and no required check failed.
- **LAND AFTER FIXES**: fixable gaps; list them, each tied to a row above.
- **DO NOT LAND**: scope mismatch, missing core behaviour, or a verify that would pass hollowly.

A required check that failed makes the verdict LAND AFTER FIXES at best, never LAND, however completely the branch satisfies its ticket; the verdict names the check and quotes its output. A
required check that could not be run here does not by itself block landing, but the verdict lists it as unverified: an unrun gate is never reported as a pass.

Keep the whole report to 30 lines or fewer.

Adapted from mattpocock/skills code-review (spec axis), 2026-09-14.
