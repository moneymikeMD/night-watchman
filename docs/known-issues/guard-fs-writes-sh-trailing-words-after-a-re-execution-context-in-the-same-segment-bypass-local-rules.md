---
title: "guard-fs-writes.sh: trailing words after a re-execution context in the same segment bypass local rules"
heading_raw: "guard-fs-writes.sh: trailing words after a re-execution context in the same segment bypass local rules — HIGH"
severity: HIGH
status: resolved
resolved: 2026-09-18
qualifiers: []
note: "pre-existing, unrelated to the ssh-opacity fix; found while verifying it"
tickets: []
slug: guard-fs-writes-sh-trailing-words-after-a-re-execution-context-in-the-same-segment-bypass-local-rules
---

scan_segment's own loop state — _ss_words, _ss_n, _ss_i — is held in plain
globals (matching this file's existing style; nothing here is `local`).
scan_segment recurses through scan_command_text for every re-execution
context (bash -c/sh -c/eval/xargs's target/a double-quoted word's
$( ... )); find -exec is the one case that defends against this by
advancing its own _ss_i to the end of the segment after handling its
nested scan. bash -c/sh -c/eval do not.

Confirmed reproduction (predates the ssh-opacity fix; not introduced by it):

    bash -c "true" rm -rf /etc

is ALLOWED (exit 0). The nested scan_command_text call for `"true"`
overwrites the global _ss_words/_ss_n/_ss_i with the NESTED segment's own
array/length/position; when that nested call returns, the OUTER
scan_segment loop's own `_ss_i=$((_ss_i + 1))` / `while [ "$_ss_i" -lt
"$_ss_n" ]` continue against the clobbered state instead of the outer
segment's real array and length, so `rm -rf /etc` — which really is a
plain top-level local command in this one segment — is never reached by
the dispatch loop at all.

Left unfixed: out of scope for the ssh-opacity fix (which only touches ssh/scp/rsync/
mosh opacity and, per its own script-review fix, the _ss_opaque stack
specifically). This is a bigger, pre-existing structural gap — every
_ss_* loop variable in scan_segment would need real call-stack scoping
(bash's `local`, deliberately unused throughout this file, or an explicit
save/restore stack like the one added for _ss_opaque, generalized
to _ss_words/_ss_n/_ss_i too) or bash -c/sh -c/eval would need find's own
"advance _ss_i to end of segment after a nested scan" pattern applied to
them as well. Either fix deserves its own ticket and its own focused
selftest coverage, not a drive-by bundled into an unrelated fix.

**Resolved 2026-09-18 (NWM-118).** scan_segment, scan_dollar_parens_in_word and scan_command_text now save and restore all their per-call globals (including _ss_words/_ss_n/_ss_i) in a frame stack around each call. Verified: 16 new selftest cases (13 re-entrancy and control cases, 7 of them red on the old hook, plus 3 stderr-oracle cases), 96/96 on bash 3.2.57 (macOS), shellcheck clean.
