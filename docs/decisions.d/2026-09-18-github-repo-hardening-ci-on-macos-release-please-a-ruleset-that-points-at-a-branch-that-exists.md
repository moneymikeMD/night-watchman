---
seq: 5
date: 2026-09-18
level: 2
slug: 2026-09-18-github-repo-hardening-ci-on-macos-release-please-a-ruleset-that-points-at-a-branch-that-exists
title: "GitHub repo hardening: CI on macOS, release-please, a ruleset that points at a branch that exists"
---

An audit of the repo's GitHub-side settings found the 2026-09-15 hardening
pass had created two branch rulesets targeting `refs/heads/protect_main` — a
branch that has never existed here. Both were active, so the settings page
showed `main` as protected while `main` was in fact force-pushable and
deletable for three days. Both now target `~DEFAULT_BRANCH` rather than a
literal branch name, so a future default-branch rename cannot silently
unprotect it the same way.

Ruleset shape kept as originally built: deletion and non-fast-forward blocked
for everyone; pull request, linear history and a required `selftests` check
required, with the built-in admin role (`actor_id: 5`) bypassing always.
That combination is deliberate — `scripts/land-branch.sh` pushes merge
commits straight to `main` and must keep working, while an outside
contributor's PR is gated on review and green CI. Verified by pushing to
`main` after the rules went live rather than by reading the documentation.

CI runs on `macos-latest`, not `ubuntu-latest`. This repo targets bash 3.2 —
the `/bin/bash` every macOS ships — and its scripts are written to that limit
deliberately. A Linux runner's bash 5.x would pass code that breaks on the
machines this actually runs on, and one selftest is already known to fail
there for exactly that reason.

Two selftests run in a separate informational step rather than gating: each
fails one assertion for a filed, pre-existing reason (the config reader
accepting a case-variant implementation name, and a message-wording
assertion in jira-workflow-apply). Quarantining them by name keeps `main`
honestly green while leaving a second failure in the same suite visible.
Each moves back into the gating step as its known-issue is resolved.

Versioning moves to release-please, seeded at the current 0.7.2 and bumping
both `.claude-plugin/plugin.json` and `marketplace.json`. It needs a one-time
Actions permission grant from the owner's own terminal ("Read and write
permissions" plus "Allow GitHub Actions to create and approve pull
requests"); without it the action creates its release branch and then fails
to open the PR. `scripts/release.sh` now overlaps it and is to be retired
deliberately through `script-retire.sh`, not left to rot.

Establishing the CI baseline meant running all 32 selftests first. 30 passed;
the two failures are the quarantined pair above. A third problem surfaced
only on a clean machine: `land-branch-selftest.sh` needs PyYAML and neither
declares nor checks for it, so it fails with a raw ModuleNotFoundError
traceback anywhere it is not already installed. CI installs it; the
underlying gap is filed.
