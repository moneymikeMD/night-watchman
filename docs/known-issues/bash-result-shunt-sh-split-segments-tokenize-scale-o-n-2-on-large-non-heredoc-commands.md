---
title: "bash-result-shunt.sh split_segments/tokenize scale O(n^2) on large non-heredoc commands"
heading_raw: "bash-result-shunt.sh split_segments/tokenize scale O(n^2) on large non-heredoc commands — LOW"
severity: LOW
status: open
qualifiers: []
note: "Measured 2026-09-20: ~4.4KB input ~3s, ~17.6KB input ~40s. Confirmed present in the ported night-watchman hooks/ copy, not just the original homelab one."
tickets: ["LAB-187"]
slug: bash-result-shunt-sh-split-segments-tokenize-scale-o-n-2-on-large-non-heredoc-commands
---

2026-09-20, LAB-187 residual (d). split_segments() and tokenize() in
hooks/bash-result-shunt.sh build their output by repeated bash string
concatenation in a character-by-character loop (`_ss_cur="$_ss_cur$_ss_c"`,
similarly in tokenize() and strip_heredocs()). Bash string concatenation
copies the whole existing string on every append, so an N-character input
does O(N) appends of O(N) average cost each: O(N^2) overall for a command
with no heredocs (strip_heredocs() itself is linear when it finds no `<<`,
but the segment/tokenize passes downstream inherit the same per-character
accumulation pattern).

Measured against the current (post-move) night-watchman copy, a synthetic
non-heredoc command of ~4.4 KB took ~3.0s wall; ~17.6 KB took ~40.3s wall
(macOS, bash 3.2, this Mac, 2026-09-20). A ~4x input size increase produced
a ~13.4x time increase, consistent with quadratic scaling (4^2=16) given
measurement noise. This reproduces the LAB-187 ticket body's own homelab-era
figures (5 KB ~5s, 20 KB ~77s) in the now-canonical night-watchman location,
so the residual survived the repo move unchanged.

Not fixed here: a linear-scan rewrite of split_segments()/tokenize() (e.g.
building an index of separator positions instead of accumulating a new
string per character, or using `read -N`-style chunked slicing) is a
non-trivial rewrite of the core parsing state machine this hook's whole
detection correctness depends on, and doing it inside a 50-minute dispatch
window carries more correctness risk (a PreToolUse gate that mis-parses is a
security-relevant false negative/positive) than the latency this specific
ticket's synthetic case demonstrates justifies fixing under time pressure.
Per the ticket's own instruction ("if the O(n^2) cost is shown to matter in
practice, i.e. hook latency actually observed on a real command, not just
the synthetic case") — this entry records the synthetic measurement as a
real, confirmed-present cost; whether it has been observed to matter on a
REAL command (as opposed to the synthetic one above) is not yet known and
is the open question for whoever picks up the follow-up ticket.

Recommended follow-up: a dedicated ticket scoped ONLY to this rewrite, with
its own before/after timing proof and full selftest re-run (all 63
assertions in hooks/bash-result-shunt-selftest.sh must still pass unchanged
before/after), so a latency fix is never shipped alongside a correctness
change to the same parser.
