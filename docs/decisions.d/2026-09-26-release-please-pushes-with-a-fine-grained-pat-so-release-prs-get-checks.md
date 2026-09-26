---
seq: 30
date: 2026-09-26
level: 3
slug: 2026-09-26-release-please-pushes-with-a-fine-grained-pat-so-release-prs-get-checks
title: "release-please pushes with a fine-grained PAT so release PRs get checks"
---

release-please's release branch was pushed with the default GITHUB_TOKEN, and GitHub never runs workflows on pushes made with that token, so every release PR sat with no checks and could not satisfy protect_main-2's required-status-checks list. The fix is a fine-grained PAT (Contents and Pull requests, read/write) stored as the repo secret RELEASE_PLEASE_TOKEN and passed as the action's token input in .github/workflows/release-please.yml, proven first on switchtender PR #36. A fine-grained PAT expires after at most one year: this one must be rotated before 2027-09-26, and the symptom of an expired one is release PRs reappearing with no checks. If a release PR is already open with no checks, closing and reopening it once triggers them.
