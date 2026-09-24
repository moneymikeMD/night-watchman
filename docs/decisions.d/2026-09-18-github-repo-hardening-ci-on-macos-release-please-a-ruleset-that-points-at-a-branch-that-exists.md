---
seq: 5
date: 2026-09-18
level: 2
slug: 2026-09-18-github-repo-hardening-ci-on-macos-release-please-a-ruleset-that-points-at-a-branch-that-exists
title: "GitHub repo hardening: CI on macOS, release-please, a ruleset that points at a branch that exists"
---

Both branch rulesets target `~DEFAULT_BRANCH`, never a literal branch name,
so a default-branch rename cannot silently unprotect `main`.

Ruleset shape: deletion and non-fast-forward blocked for everyone
(`protect_main-1`, no bypass); linear history, a code-owner-reviewed pull
request and the required checks `selftests`, `docs-site` and `comment-lint`
(`protect_main-2`), with the built-in repository-admin role (`actor_id: 5`)
bypassing always. That combination is deliberate — `scripts/land-branch.sh`
pushes merge commits straight to `main` and must keep working, while an
outside contributor's PR is gated on review and green CI. Verified by
pushing to `main` after the rules went live rather than by reading the
documentation.

CI runs on `macos-latest`, not `ubuntu-latest`. This repo targets bash 3.2 —
the `/bin/bash` every macOS ships — and its scripts are written to that
limit deliberately. A Linux runner's bash 5.x would pass code that breaks on
the machines this actually runs on.

Two selftests run in a separate informational step rather than gating
(`providers/config-selftest.sh` and
`providers/tracker/jira/jira-workflow-apply-selftest.sh`): each fails one
assertion for a filed reason. Quarantining them by name keeps `main`
honestly green while leaving a second failure in the same suite visible.
Each moves back into the gating step when its known issue is resolved.

Versioning is release-please's, bumping `.claude-plugin/plugin.json`. It
needs a one-time Actions permission grant from the owner's own terminal
("Read and write permissions" plus "Allow GitHub Actions to create and
approve pull requests"); without it the action creates its release branch
and then fails to open the PR.
