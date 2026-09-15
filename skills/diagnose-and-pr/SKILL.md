---
name: diagnose-and-pr
description: Wiring guidance for dispatching a failure signal (an alert, a failed check) to the diagnose-and-pr agent and handling its output. Use when a project wants to turn monitoring findings into draft PRs instead of manual triage, when deciding what counts as in-scope for that agent, or when the owner asks to diagnose/debug a specific failing behaviour and wants the disciplined loop (a red command before any theory), not a one-line question.
---

# Diagnose and PR

Some projects run enough automated checks and alerts that "someone should
look at this" is happening more often than a human reviews it. This skill
is the dispatch contract for turning one firing signal into a candidate
fix, via the `diagnose-and-pr` agent — see `agents/diagnose-and-pr.md` for
what that agent actually does and refuses to do. For the method it follows
once diagnosis actually starts, see `references/diagnosis-loop.md`
(adapted from mattpocock/skills diagnosing-bugs, 2026-09-14).

## Scope: this skill is not the scheduler

This skill does not decide *when* to run — no cron, no webhook receiver, no
alert-routing logic. That is the host project's job, wired to whatever
already triggers work there (a sweep script, a monitoring tool's webhook,
a CI failure hook). This skill only covers what happens once a signal has
already arrived and needs a diagnosis.

## Dispatch checklist

Before calling the `diagnose-and-pr` agent, have on hand:

- **What fired** — the specific alert/check/finding, not a paraphrase.
- **When** — a timestamp, so the agent can bound its log/history search.
- **Any first-pass triage** already done by a monitoring tool, if one ran
  ahead of this (some setups run an automated first pass — e.g. Grafana
  Sift, a lint bot — before escalating to an agent; hand its findings
  along, don't discard them).

If any of these is missing, get it before dispatching rather than sending
the agent to guess which incident is meant.

For a failed-check signal, classify it first:
- **Flake** earns one fresh build, never a retry loop.
- An **identical second failure is not flake** — dispatch it.
- A failure in code the change didn't touch — check
  `git merge-base --is-ancestor` for a stale base before dispatching.
  (Ported from pstack babysit, 2026-09-14.)

## After the agent returns

- **A PR was opened**: review it like any other PR. The agent's PR
  description states its confidence and what it deliberately left out —
  read that before merging, not just the diff.
- **The agent reports the diagnosis as inconclusive**: that is a valid,
  intended outcome, not a failure of the agent. Route it to a human queue
  rather than re-running the agent hoping for a different answer.
- **Never let this loop's credentials merge to a protected branch.** The
  whole safety property this skill depends on is "propose, never land" —
  if the credentials wired to this agent *can* merge or push to `main`,
  that is a configuration bug in the host project, fix that before running
  the agent again.

## Prerequisites

- The `hooks/guard-fs-writes.sh` PreToolUse hook (this plugin's core
  filesystem-scope guard) should be active before this agent runs
  unattended — it is the guard rail an agent with write access to a repo
  needs, and this skill assumes it is present.
- A credential for opening PRs that is scoped to pull-requests and
  contents on the target repo only, with branch protection on the
  destination branch enforced independently of that credential's own
  scope — the credential's scope alone is not a sufficient safety
  argument; branch protection is what actually stops a landed merge.
- Run one harmless end-to-end signal through the whole loop before
  enabling unattended traffic — confirm the PR it opens looks right before
  trusting it on a real one.
  (Ported from pstack babysit, 2026-09-14.)
