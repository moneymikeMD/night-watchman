---
title: "guard-fs-writes-selftest.sh: test 16 (~/../.. escape) exits 1 not 2"
heading_raw: "guard-fs-writes-selftest.sh: test 16 (~/../.. escape) exits 1 not 2 — LOW"
severity: LOW
status: open
qualifiers: []
note: "Ubuntu 26.04 / bash 5.3 only; passes on macOS bash 3.2. Pre-existing, unrelated to the ssh-opacity fix; discovered while verifying that fix on linux-host"
tickets: []
slug: guard-fs-writes-selftest-sh-test-16-escape-exits-1-not-2
---

While verifying the ssh-opacity fix (ssh/scp/rsync/mosh opaque-payload
handling in hooks/guard-fs-writes.sh), `hooks/guard-fs-writes-selftest.sh`
assertion 16 ("blocks a ~/../.. escape run from a bare system root
(finding 3)") failed on an unmodified checkout of the branch — before any
change was applied. Platform scope: observed on linux-host
(Ubuntu 26.04.1, GNU bash 5.3.9, GNU coreutils). The same selftest passes
71/71 on the Mac (macOS, bash 3.2) on both the branch and main, so this
is a Linux/bash-5 divergence, not a universally reproducing bug. Confirmed by stashing that edit and
re-running the selftest: the same assertion fails identically (want exit
2, got exit 1) on main's own code, so this is not a regression introduced
by that change.

Exit 1 (rather than 2) from the guard script under this input means the
script itself is erroring out (an unbound-variable trip under `set -u`,
or similar), not choosing to allow (0) or block (2) — worth a look with
`bash -x` against the exact command in assertion 16
(`rm -rf ~/../../../private/tmp/some-outside-target` run from cwd
`/private/tmp`).

Left unfixed here: out of scope for the ssh-opacity fix (ssh/scp/rsync/mosh payload
opacity), and touching guard-fs-writes.sh's tilde/broad-root resolution
logic deserves its own focused pass and its own selftest coverage, not a
drive-by fix bundled into an unrelated ticket.
