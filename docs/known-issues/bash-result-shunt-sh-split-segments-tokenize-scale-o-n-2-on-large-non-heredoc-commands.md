---
title: "bash-result-shunt.sh: per-character string accumulation makes strip_heredocs, split_segments and tokenize all O(n^2) on large commands"
heading_raw: "bash-result-shunt.sh: per-character string accumulation makes strip_heredocs, split_segments and tokenize all O(n^2) on large commands — LOW"
severity: LOW
status: open
qualifiers: []
note: "synthetic 25.9 KB command: 94s wall on macOS bash 3.2"
tickets: ["LAB-187"]
slug: bash-result-shunt-sh-split-segments-tokenize-scale-o-n-2-on-large-non-heredoc-commands
---

strip_heredocs(), split_segments() and tokenize() in hooks/bash-result-shunt.sh
each build their output by per-character bash string concatenation
(`_sh_out="$_sh_out$_sh_c"`, `_ss_cur="$_ss_cur$_ss_c"`, `_tk_cur="$_tk_cur$_tk_c"`),
which copies the whole string on every append, so every command the hook
sees costs O(n^2) in its length, heredoc or not.

Evidence: a synthetic 25.9 KB `echo word0 ... word2999` command fed to the
hook as a PreToolUse payload takes 94s wall on macOS bash 3.2.

The fix is a linear-scan rewrite of the parser state machine the hook's
detection depends on, with hooks/bash-result-shunt-selftest.sh unchanged
before and after and its own timing proof. Open question: has the cost been
observed on a real command rather than a synthetic one?
