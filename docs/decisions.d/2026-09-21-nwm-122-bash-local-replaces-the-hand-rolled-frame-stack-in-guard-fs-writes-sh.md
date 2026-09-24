---
seq: 23
date: 2026-09-21
level: 3
slug: 2026-09-21-nwm-122-bash-local-replaces-the-hand-rolled-frame-stack-in-guard-fs-writes-sh
title: "NWM-122: bash `local` replaces the hand-rolled frame stack in guard-fs-writes.sh"
---

`hooks/guard-fs-writes.sh`'s scanner is re-entrant through bash's own
`local`, not a hand-rolled frame stack. Each of `scan_command_text`,
`scan_segment` and `scan_dollar_parens_in_word` declares its per-call state
with `local` at the top of the function. `local` in bash is DYNAMICALLY
scoped, not lexical: a helper called from the declaring function sees and
writes the declaring function's copy, and a recursive re-entry gets a fresh
copy with the outer one restored on return — exactly the property a frame
stack (`_frame_push` / `_frame_pop`, hand-maintained `_*_FRAME_VARS` name
lists, a wrapper/`_body` split per scanner) exists to provide, at −74 lines.

**The specific risk.** `local` would be wrong if a helper called from one of
these bodies relied on a global outliving the declaring function's return.
Every cross-function use of a scanner variable is inside the declaring
function's dynamic extent: `tokenize_quoted` writes `_ss_words` and is
called only from `scan_segment`; `split_unquoted_segments` writes
`_sct_seglist` and is called only from `scan_command_text`, which reads it
on the next line; `_ss_opaque_push` / `_ss_opaque_pop` are reached only
through `scan_segment`. `_AC_NAMES` / `_AC_VALUES` are append-only across
the whole invocation and were never frame-saved; nothing about `local`
touches them.

**Why `local` wins, and not a tie.** Timing is indistinguishable on the
common path (both dominated by the `jq` and `git` subprocess startups) and
about 19% faster for `local` on a pathological four-deep nesting, because a
frame stack's per-call save/restore over ~34 names in indirect expansion
and `eval` is the one part of the scanner that is not subprocess-bound. What
decides it is that a frame stack's variable lists are maintained by hand
and nothing checks them: a loop variable omitted from a list is latent
until a later edit adds a re-entrant call under that loop, and nothing in
the repo distinguishes the latent omission from a live one. With `local`
the declaration sits at the top of the function it belongs to and bash
enforces it.

**The oracle that discriminates.** The behavioural assertions in
`hooks/guard-fs-writes-selftest.sh` pass against both shapes, so they
cannot tell them apart. Three static assertions do: every `_ss_` / `_sct_`
/ `_sdp_` variable assigned anywhere in the hook is declared `local` in its
owning scanner, none is assigned at file scope, and `tokenize_quoted` /
`split_unquoted_segments` are called only from the scanner whose `local`
they write. A copy with one `local` name removed fails exactly that
assertion and nothing else, which is the drift this design has to survive.

**Left in place deliberately.** The `_SS_OPAQUE_STACK` push/pop pair is
redundant under `local` — a nested `scan_segment` gets its own
`_ss_opaque`, so it can no longer clobber the outer frame's value, which is
the only thing that stack defends against. It stays. The known issue
`guard-fs-writes-sh-trailing-words-after-a-re-execution-context-in-the-same-segment-bypass-local-rules`
records that no probe can isolate that stack's behaviour, and removing an
unfalsifiable guard inside a redesign of the same mechanism is how a
regression ships unnoticed. Removing it is a separate ticket with its own
oracle.
