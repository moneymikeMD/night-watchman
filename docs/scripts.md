# scripts.md

This file is NOT the scripts reference — that page is GENERATED from
`scripts/*.sh`/`scripts/*.py` headers by `scripts/gen-reference-docs.sh`
(see `docs/preview/website/src/content/docs/reference/scripts.mdx`), so a
script's own header stays the single source of truth for what it does
while it is in use.

This file exists only to hold the retirement changelog
`script-retire.sh` (ai-toolkit's, since NWM-130) writes to — a script that
has been deleted no longer has a header for the generator to read, so its
retirement record lives here instead. `script-retire.sh --yes` appends
to `## Retired`; a script that leaves for another repo, or that is
superseded by a mechanism rather than falling out of use, is outside that
script's usage-driven candidate rule and is appended by hand, naming the
ticket that retired it.

## Retired

Scripts deleted under the usage/adoption rule (report --usage flagged
retire?), or relocated to another repo. Entries list name, date
retired, one-line purpose, and reason.

- `comment-lint.py` — retired 2026-09-18. Fail a build when comments run longer than the project's comment rule allows. Reason: relocated to the public moneymikeMD/ai-toolkit and consumed here as `actions/comment-lint@v1` (NWM-126).
- `comment-lint-selftest.sh` — retired 2026-09-18. Selftest for comment-lint.py. Reason: relocated with comment-lint.py to moneymikeMD/ai-toolkit (NWM-126).
- `known-issue.sh` — retired 2026-09-21. Manage `docs/known-issues/` as one file per finding under a generated index. Reason: relocated to the public moneymikeMD/ai-toolkit and consumed here through `scripts/ai-toolkit-root.sh --known-issue` (NWM-128).
- `known-issue-selftest.sh` — retired 2026-09-21. Selftest for known-issue.sh. Reason: relocated with known-issue.sh to moneymikeMD/ai-toolkit (NWM-128).
- `script-analytics.py` — retired 2026-09-22. Extract per-script lifecycle events from Claude Code transcripts and report on them. Reason: relocated to the public moneymikeMD/ai-toolkit and consumed here through `scripts/ai-toolkit-root.sh --script-analytics` (NWM-130).
- `script-analytics-selftest.sh` — retired 2026-09-22. Selftest for script-analytics.py. Reason: relocated with script-analytics.py to moneymikeMD/ai-toolkit (NWM-130).
- `script-retire.sh` — retired 2026-09-22. Turn a `retire?` row into a landed retirement branch. Reason: relocated to the public moneymikeMD/ai-toolkit and consumed here through `scripts/ai-toolkit-root.sh --script-retire` (NWM-130).
- `script-retire-selftest.sh` — retired 2026-09-22. Selftest for script-retire.sh. Reason: relocated with script-retire.sh to moneymikeMD/ai-toolkit (NWM-130).
- `release.sh` — retired 2026-09-22. Bump the plugin version, generate a CHANGELOG section from tracker outcomes, commit and tag. Reason: superseded by release-please, which has owned versioning and CHANGELOG.md since 2026-09-18 and has now cut v1.0.0 through v1.4.0; two mechanisms writing the same three files is how a version ends up disagreeing with a tag (NWM-124).
- `release-selftest.sh` — retired 2026-09-22. Selftest for release.sh. Reason: retired with release.sh (NWM-124).
