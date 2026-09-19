# scripts.md

This file is NOT the scripts reference — that page is GENERATED from
`scripts/*.sh`/`scripts/*.py` headers by `scripts/gen-reference-docs.sh`
(see `docs/preview/website/src/content/docs/reference/scripts.mdx`), so a
script's own header stays the single source of truth for what it does
while it is in use.

This file exists only to hold the retirement changelog
`scripts/script-retire.sh` writes to — a script that has been
deleted no longer has a header for the generator to read, so its
retirement record lives here instead. `script-retire.sh --yes` appends
to `## Retired`; a script that leaves for another repo rather than for
disuse is outside that script's usage-driven candidate rule and is
appended by hand, naming the ticket that moved it.

## Retired

Scripts deleted under the usage/adoption rule (report --usage flagged
retire?), or relocated to another repo. Entries list name, date
retired, one-line purpose, and reason.

- `comment-lint.py` — retired 2026-09-18. Fail a build when comments run longer than the project's comment rule allows. Reason: relocated to the public moneymikeMD/ai-toolkit and consumed here as `actions/comment-lint@v1` (NWM-126).
- `comment-lint-selftest.sh` — retired 2026-09-18. Selftest for comment-lint.py. Reason: relocated with comment-lint.py to moneymikeMD/ai-toolkit (NWM-126).
