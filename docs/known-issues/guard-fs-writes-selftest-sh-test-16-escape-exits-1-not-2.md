---
title: "guard-fs-writes-selftest.sh: test 16 (~/../.. escape) exits 1 not 2"
heading_raw: "guard-fs-writes-selftest.sh: test 16 (~/../.. escape) exits 1 not 2 — LOW"
severity: LOW
status: open
qualifiers: []
note: "Linux bash 5 only; macOS bash 3.2 passes; current Linux status UNVERIFIED"
tickets: []
slug: guard-fs-writes-selftest-sh-test-16-escape-exits-1-not-2
---

hooks/guard-fs-writes-selftest.sh assertion 16 ("blocks a ~/../.. escape
run from a bare system root") wants exit 2 from the guard and gets exit 1
on Linux (Ubuntu 26.04, bash 5.3, GNU coreutils). On macOS bash 3.2 the
whole selftest passes (138 of 138). Exit 1 means the guard script itself
errors on that input (an unbound-variable trip under `set -u`, or similar)
rather than choosing allow (0) or block (2); `bash -x` against the exact
command in assertion 16 (`rm -rf ~/../../../private/tmp/some-outside-target`
from cwd `/private/tmp`) is where to look. Whether it still reproduces on
the current guard is UNVERIFIED: no Linux host was available to re-run it.
