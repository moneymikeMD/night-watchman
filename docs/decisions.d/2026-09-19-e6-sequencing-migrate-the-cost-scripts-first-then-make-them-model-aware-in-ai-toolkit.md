---
seq: 7
date: 2026-09-19
level: 2
slug: 2026-09-19-e6-sequencing-migrate-the-cost-scripts-first-then-make-them-model-aware-in-ai-toolkit
title: "E6 sequencing: migrate the cost scripts first, then make them model-aware in ai-toolkit"
---

NWM-119 (record the orchestrator's model and effort per wave, so the ledger
shows what Fable costs against Opus-at-high-effort) and NWM-129 (move
`claude-cost.py` and `claude-cost-scan.py` to the public `ai-toolkit`)
change the same file.

Owner decision: migrate first. NWM-129 lands, and NWM-119's change is made
in `ai-toolkit` against the migrated script; NWM-129 blocks NWM-119.

The reasoning is that NWM-119's change is to the generic half. Reading a
transcript's model and effort metadata and splitting spend per model is
something any repo running Claude Code sessions wants; it is not a
night-watchman feature. Doing it here first would mean writing generic code
into a private repo and then moving it a ticket later, the same mistake
NWM-126 corrected for `comment-lint.py`. What stays here is the product
half: the ledger file, `docs/cost.md`'s prose, and the `cost-reviewer`
agent.
