---
title: "known-issues _manifest.json hashes disagree with every entry file, so the force-mode tamper check is meaningless directory-wide"
heading_raw: "known-issues _manifest.json hashes disagree with every entry file, so the force-mode tamper check is meaningless directory-wide — LOW"
severity: LOW
status: open
qualifiers: []
note: "All 18 recorded sha256s drifted; cause unknown. Found 2026-09-18 while resolving the manifest's merge-conflict markers."
tickets: []
slug: known-issues-manifest-json-hashes-disagree-with-every-entry-file-so-the-force-mode-tamper-check-is-meaningless-directory-wide
---

docs/known-issues/_manifest.json records, per slug, the sha256 of the entry file that known-issue.sh itself last wrote. Its purpose is tamper detection: it lets force mode (and a git diff) show whether an entry has been hand-edited since the tool wrote it.

Observed 2026-09-18 while fixing committed merge-conflict markers in that manifest (commit 0bd58ba): EVERY one of the 18 recorded hashes disagrees with the current content of its entry file. Recomputing sha256 over each entry markdown file with the same method the script uses (file_hash, sha256 over the raw bytes) matched 0 of 18.

Consequence: the tamper signal is currently dead across the whole directory. Nothing fails loudly, because known-issue.sh lint does not verify these hashes. It checks the generated index against entry frontmatter, and reports "OK: 18 entries, index up to date" regardless. Only the force path consults the manifest, so the degradation is silent.

Cause UNVERIFIED. Candidates not yet distinguished: (a) a bulk reformat or reindex that rewrote entry bodies without calling record_written; (b) ordinary hand-editing of entries over time, which is exactly what the manifest exists to reveal; (c) a change to the entry file format or frontmatter rendering after the hashes were recorded. That all 18 drifted together points away from (b) and toward a systematic rewrite, but that is inference, not evidence.

Deliberately NOT fixed by regenerating the hashes. Rewriting them would make the manifest self-consistent again while erasing the only record that the drift happened, for all 18 entries at once: a tidy-looking change that destroys the signal the file exists to carry. The hashes were preserved as recorded through the conflict resolution for that reason.

Fixing this properly means first establishing which cause applies, then either re-baselining deliberately (with that decision recorded) or repairing whatever path rewrites entries without updating the manifest.
