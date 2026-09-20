---
seq: 7
date: 2026-09-19
level: 2
slug: 2026-09-19-e6-sequencing-migrate-the-cost-scripts-first-then-make-them-model-aware-in-ai-toolkit
title: "E6 sequencing: migrate the cost scripts first, then make them model-aware in ai-toolkit"
---

NWM-119 (record the orchestrator's model and effort per wave, so the ledger
shows what Fable costs against Opus-at-high-effort) and NWM-129 (move
`claude-cost.py` and `claude-cost-scan.py` to the public `ai-toolkit`) both
change the same file. Yesterday's handoff flagged the sequencing as unmade
and warned against running them in parallel.

Owner decision: migrate first. NWM-129 lands, and NWM-119's change is then
made in `ai-toolkit` against the migrated script. The `Blocks` link was
reversed to match — NWM-129 now blocks NWM-119, where it previously ran the
other way.

The reasoning is that NWM-119's change is to the generic half. Reading a
transcript's model and effort metadata and splitting spend per model is
something any repo running Claude Code sessions wants; it is not a
night-watchman feature. Doing it here first would mean writing generic code
into a private repo and then moving it a ticket later, which is the same
mistake NWM-126 was filed to correct for `comment-lint.py`. What stays here
is the product half: the ledger file, `docs/cost.md`'s prose, and the
`cost-reviewer` agent.

NWM-119's `touches` was corrected while making this change. It listed
`scripts/claude-cost.py` (about to leave the repo) plus `docs/cost/README.md`
and `docs/cost/reviews/`, neither of which exists — the real layout is a
single `docs/cost.md`. It now names only what this repo will still own.
