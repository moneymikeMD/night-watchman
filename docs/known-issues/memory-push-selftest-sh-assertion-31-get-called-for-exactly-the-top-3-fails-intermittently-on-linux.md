---
title: "memory-push-selftest.sh: assertion 31 (get called for exactly the top 3) fails intermittently on Linux"
heading_raw: "memory-push-selftest.sh: assertion 31 (get called for exactly the top 3) fails intermittently on Linux — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "Linux: about 1 run in 15; reddened main CI at 025bc4c"
tickets: []
slug: memory-push-selftest-sh-assertion-31-get-called-for-exactly-the-top-3-fails-intermittently-on-linux
---

hooks/memory-push-selftest.sh assertion 31 ("markdown: get called for exactly the top 3") expects get to be called for ids 11111111, 22222222 and 33333333 in that order.
On a failing run the recorded call list begins with 22222222.

Seen 2026-10-12 on the push-to-main CI run 38271700367 at 025bc4c, in the selftests (linux) leg only; the macOS selftests leg of the same run passed.
The same tree passed the Linux leg on pull requests 127 and 128.
On mike-desktop-l (Linux, bash 5) the selftest failed 1 of 15 consecutive runs with the same assertion and passed the other 14.

025bc4c did not cause it: git diff 5a9b702 025bc4c -- hooks/ is empty.

The cause is not established.
The assertion compares the order of calls, so anything that fetches the three bodies concurrently or iterates an unordered set would produce this; neither has been checked.
Until it is fixed a red selftests (linux) on a branch that does not touch hooks/ is worth one re-run before it is read as a regression.
