---
title: "known-issues _manifest.json hashes disagree with every entry file, so the force-mode tamper check is meaningless directory-wide"
heading_raw: "known-issues _manifest.json hashes disagree with every entry file, so the force-mode tamper check is meaningless directory-wide — LOW"
severity: LOW
status: resolved
resolved: 2026-09-19
qualifiers: []
note: "Fixed 2026-09-19: lint now checks the manifest (check_manifest), manifest regenerated, selftest test 5 proves it catches a hand-edit. Root cause confirmed first-hand for 2/17; the other 15 trace to a squashed Initial Commit and are UNVERIFIED (see body)."
tickets: []
slug: known-issues-manifest-json-hashes-disagree-with-every-entry-file-so-the-force-mode-tamper-check-is-meaningless-directory-wide
---

docs/known-issues/_manifest.json records, per slug, the sha256 of the entry file that known-issue.sh itself last wrote. Its purpose is tamper detection: it lets force mode (and a git diff) show whether an entry has been hand-edited since the tool wrote it.

Observed 2026-09-18 while fixing committed merge-conflict markers in that manifest (commit 0bd58ba): EVERY one of the 18 recorded hashes disagrees with the current content of its entry file. Recomputing sha256 over each entry markdown file with the same method the script uses (file_hash, sha256 over the raw bytes) matched 0 of 18.

Consequence: the tamper signal is currently dead across the whole directory. Nothing fails loudly, because known-issue.sh lint does not verify these hashes. It checks the generated index against entry frontmatter, and reports "OK: 18 entries, index up to date" regardless. Only the force path consults the manifest, so the degradation is silent.

Cause, resolved for 2 of the 17 still-mismatched entries as of 2026-09-19,
confirmed first-hand by diffing each commit against `file_hash` of its own
committed blob: `guard-fs-writes-sh-false-positives-on-redirect...` (commit
bf94c90) and `guard-fs-writes-sh-trailing-words-after-a-re-execution...`
(commits 573acb3, a49b068) were each hand-edited directly — a "Resolved
..." paragraph appended to the body, or existing body prose revised — in
the same commit as, or after, a legitimate frontmatter change. Neither edit
went through `add`/`resolve`/`severity`, so `record_written` never ran, and
the manifest kept the hash from before the hand-edit. `known-issue.sh lint`
never noticed because it did not check the manifest at all (fixed below).

The other 15 mismatched entries (now 15 of 25 total, after WO-019/WO-023
added correctly-hashed entries) trace only to `b765642 "feat: Initial
Commit"` and were never touched by any commit since. That commit is a
squashed snapshot — no earlier history survives in this repo to show what
produced it — so the exact edit that diverged their content from their
recorded hash is UNVERIFIED and not recoverable. It is consistent with the
same class of cause (content on disk not mediated by
`add`/`resolve`/`severity` at the moment it was captured), but that is
inference from the pattern, not a first-hand confirmation like the two
above.

Fixed by giving `lint` — the check CI already runs on every push
(`.github/workflows/ci.yml`) — a manifest-hash comparison
(`check_manifest`), so any future drift, by either mechanism, fails loudly
on the next routine invocation instead of only being checked by the rare
`migrate --force` recovery path. Regenerating the manifest was safe only
once that check existed: re-baselining without it would have repeated
exactly this bug the next time an entry is hand-edited outside the CLI.
`scripts/known-issue-selftest.sh` test 5 hand-edits a fresh entry after
`add` and asserts `lint` now refuses it; run against the pre-fix script it
fails red, confirming the assertion is real.
