---
title: "guard-fs-writes.sh: quoted-operator mis-split on unescaped ;/&&/||/| hit ANY quoted argument, not just ssh/scp/rsync/mosh payloads"
heading_raw: "guard-fs-writes.sh: quoted-operator mis-split on unescaped ;/&&/||/| hit ANY quoted argument, not just ssh/scp/rsync/mosh payloads — MEDIUM"
severity: MEDIUM
status: resolved
resolved: 2026-09-19
qualifiers: []
note: "widened from ssh/scp/rsync/mosh payloads to any quoted argument of any command; fixed in WO-023"
tickets: ["WO-023"]
slug: guard-fs-writes-sh-quoted-ssh-scp-rsync-mosh-payload-mis-split-on-unescaped
---

scan_command_text split the RAW command text into segments on
`;`/`&&`/`||`/`|` (via a sed pass) BEFORE any quote-aware tokenization
happened. This entry originally scoped the bug to a quoted remote payload
passed to ssh/scp/rsync/mosh, but the root cause was in the shared entry
point every command goes through — it hit ANY quoted argument of ANY
command.

General reproduction (no ssh involved):

    echo "alpha; beta > /etc/passwd gamma"

The quoted `;` split the word before tokenizing; the second fragment
started mid-string with no quote state, and the `>` inside it read as a
real redirect. That is the ordinary shape of a `memorygraph store
--content`, a `known-issue.sh add --body`, or a commit message containing
both a semicolon and a greater-than sign — not an exotic remote-command
shape.

Original (narrower) reproduction, still one instance of the same bug:

    ssh host "cd /tmp && rm -rf /etc/passwd"

split into `ssh host "cd /tmp ` and ` rm -rf /etc/passwd"`, the second
scanned as its own top-level command with `rm` as its command word — the
genuinely remote `rm -rf /etc/passwd` was blocked as if local, or (the
milder false-negative direction, unchanged by the fix below — see WO-023's
own "Out of scope") a mis-split fragment that looked like an
inside-worktree path was silently allowed instead.

Fixed in WO-023: scan_command_text's segment splitter is now quote-aware
(`split_unquoted_segments`) — a separator inside a single- or
double-quoted span is data, never a boundary. `\;` (find's escaped -exec
terminator) still stays literal outside quotes, unchanged.
