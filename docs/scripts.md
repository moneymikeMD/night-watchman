# scripts.md

This file is NOT the scripts reference — that page is GENERATED from
`scripts/*.sh`/`scripts/*.py` headers by `scripts/gen-reference-docs.sh`
(see `docs/preview/website/src/content/docs/reference/scripts.mdx`), so a
script's own header stays the single source of truth for what it does
while it is in use.

This file exists only to hold the retirement changelog
`scripts/script-retire.sh` writes to — a script that has been
deleted no longer has a header for the generator to read, so its
retirement record lives here instead. Do not hand-edit `## Retired`;
`script-retire.sh --yes` appends to it.

## Retired

Scripts deleted under the usage/adoption rule (report --usage flagged
retire?). Entries list name, date retired, one-line purpose, and reason.
