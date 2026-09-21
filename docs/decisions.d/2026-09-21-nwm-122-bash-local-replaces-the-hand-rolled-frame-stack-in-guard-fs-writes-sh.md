---
seq: 23
date: 2026-09-21
level: 3
slug: 2026-09-21-nwm-122-bash-local-replaces-the-hand-rolled-frame-stack-in-guard-fs-writes-sh
title: "NWM-122: bash `local` replaces the hand-rolled frame stack in guard-fs-writes.sh"
---

NWM-118 made guard-fs-writes.sh's scanner re-entrant with a hand-rolled
frame stack — `_frame_push` / `_frame_pop` / `_FRAME_STACK`, four
hand-maintained `_*_FRAME_VARS` / `_*_FRAME_ARRAYS` name lists, and a
wrapper/`_body` split on each of the three mutually recursive functions.
NWM-122 asked whether bash's own `local` already does that job. It does,
and the frame stack is gone.

**What replaced it.** Each of `scan_command_text`, `scan_segment` and
`scan_dollar_parens_in_word` now declares its own per-call state with
`local` at the top of the function, and the `_body` wrapper pair is
deleted. `local` in bash is DYNAMICALLY scoped, not lexical: a helper
called from the declaring function sees and writes the declaring
function's copy, and a recursive re-entry gets a fresh copy with the
outer one restored on return. That is exactly the property the frame
stack was built to provide. Net −72 lines (1328 → 1256; 21 insertions,
93 deletions).

**The specific risk, hunted and cleared.** `local` would be wrong if a
helper called from one of these bodies relied on a global outliving the
declaring function's return. A whole-file scan for every name in the
four frame lists found exactly four cross-function uses, all of them
inside the declaring function's dynamic extent, so all four are correct
under `local`:

- `tokenize_quoted` writes `_ss_words`; called only from `scan_segment`.
- `split_unquoted_segments` writes `_sct_seglist`; called only from
  `scan_command_text`, which reads it on the next line.
- `_ss_opaque_push` / `_ss_opaque_pop` read and write `_ss_opaque`;
  reached only through `scan_segment`.

`_AC_NAMES` / `_AC_VALUES` are the case the ticket flagged as most
likely to break, since `collect_same_command_assignments` appends to
them and `substitute_same_command_vars` reads them across nested
`scan_command_text` calls. They are genuinely append-only across the
whole invocation — and they were never in any frame list, so the frame
stack never saved them either. Nothing about this change touches them.

**Evidence.** Both shapes were kept side by side and run against the
same oracles.

- Selftest: 135 assertions, 135 passed, on both shapes. Baseline
  (frame stack) and candidate (`local`) counts are identical, so the
  verify's "no fewer assertions than NWM-118 left it at" holds at
  equality.
- Four bypass shapes plus controls, re-run explicitly on the `local`
  shape: assertions 82–89 (`bash -c "true" rm -rf <outside>`,
  `sh -c "x" mv`, `eval true rm -rf`, a second `find -exec rm -rf`
  after a harmless first, `xargs bash -c`, nested `$( $( ) )`,
  `find -exec bash -c`, `find -exec sh -c`) all block; controls 90–94
  (the same shapes with harmless trailing commands, and an in-worktree
  `rm -rf`) all allow, so the mechanism is not simply refusing
  everything.
- Stderr: assertions 95–97 pass — an allowed `echo hello` and an
  allowed nested command each write zero bytes to stderr, and a
  blocked nested command writes only the block message. Measured
  directly as well: `ls -la`, `bash -c "echo hi; ls"` and
  `echo "$(ls -l)"` each produce 0 stderr bytes under both shapes. The
  `${#arr[@]}`-on-a-never-declared-name unbound-variable noise the
  ticket describes was already absent from the landed NWM-118 version
  (its three arrays are pre-declared), so that cost is historical, not
  a live defect this change fixes.
- Differential: 84 commands (every literal `run_guard` command in the
  selftest with paths substituted, plus 18 hand-built deep-nesting,
  heredoc, assignment-substitution and opaque-command cases; 37 block
  and 47 allow under the baseline) produced ZERO differences in exit
  code or stderr between the two shapes.
- Negative control, which is what makes the above non-vacuous: a copy
  of the `local` shape with the `local` declarations stripped and
  nothing else changed fails 8 of the 135 assertions — 82, 83, 85, 86,
  87, 88, 89 and the nested-stderr oracle 97 — and diverges from the
  baseline on 8 of the 84 differential commands. The oracles do
  discriminate; they are not passing because they cannot fail.

**Timing, measured on this Mac, bash 3.2.57, arm64.** Mean wall time
per invocation over 3x40 runs of an ordinary allowed command (`ls -la`):
frame stack 48.7–49.6 ms, `local` 48.3–50.6 ms — indistinguishable,
because both are dominated by the `jq` and `git` subprocess startups,
exactly as the ticket predicted. Over 3x15 runs of a deliberately
pathological four-deep nesting of `bash -c` / `eval` / `find -exec` /
`$( )`: frame stack 107.8–111.0 ms, `local` 87.5–89.2 ms — about 20 ms
and 19% faster, because the frame stack's per-call save/restore loops
over ~34 names in indirect expansion and `eval` are the one part of the
scanner that is not subprocess-bound. So: no measurable cost on the
common path, a real saving on the deep path, and no case where the
frame stack is faster.

**Why it is the frame stack that loses, and not a tie.** The
measurements above are close enough on the common path that speed alone
would not decide it. What decides it is that the frame stack's variable
lists are maintained by hand and the compiler cannot check them. Two
drifts already existed: `_ss_fp` (the `for _ss_fp in
"${_ss_find_paths[@]}"` loop variable) was never in `_SS_FRAME_VARS`,
and the ticket records `_sct_seg` having been missing from
`_SCT_FRAME_VARS` before it was added. Each such omission is a silent
re-entrancy hole of precisely the class NWM-118 was opened to fix. With
`local`, the declaration sits at the top of the function it belongs to,
one screen from the body, and bash enforces it. There is no list to
drift.

**Left in place deliberately.** The `_SS_OPAQUE_STACK` push/pop pair is
now redundant: a nested `scan_segment` gets its own `local _ss_opaque`,
so it can no longer clobber the outer frame's value, which is the only
thing that stack defends against. It stays anyway. The known issue
`guard-fs-writes-sh-trailing-words-after-a-re-execution-context-in-the-same-segment-bypass-local-rules`
records that no probe can isolate that stack's behaviour, and removing
an unfalsifiable guard inside a redesign of the same mechanism is how a
regression ships unnoticed. Removing it is a separate ticket with its
own oracle, or it does not happen.
