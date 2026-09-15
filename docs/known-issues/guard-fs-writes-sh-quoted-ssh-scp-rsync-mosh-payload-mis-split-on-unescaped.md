---
title: "guard-fs-writes.sh: quoted ssh/scp/rsync/mosh payload mis-split on unescaped ;/&&/||/|"
heading_raw: "guard-fs-writes.sh: quoted ssh/scp/rsync/mosh payload mis-split on unescaped ;/&&/||/| — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "false positive (and a milder false-negative) for quoted remote payloads containing shell operators; the ssh-opacity fix does not cover this shape"
tickets: []
slug: guard-fs-writes-sh-quoted-ssh-scp-rsync-mosh-payload-mis-split-on-unescaped
---

scan_command_text splits the RAW command text into segments on
`;`/`&&`/`||`/`|` (via a sed pass) BEFORE any quote-aware tokenization
happens. This means a quoted remote payload to ssh/scp/rsync/mosh that
itself contains one of those four operators is torn apart at the
operator, even though it is inside a quoted string.

Confirmed reproduction (run from a worktree, guard-fs-writes.sh as of
that earlier fix):

    ssh host "cd /tmp && rm -rf /etc/passwd"

splits into two segments — `ssh host "cd /tmp ` and ` rm -rf /etc/passwd"`
— and the second is then scanned as ITS OWN top-level command, with `rm`
as that segment's own command word. Two observed failure directions:

  - The genuinely remote `rm -rf /etc/passwd` gets BLOCKED as if it were a
    real local `rm -rf /etc/passwd` — exactly the class of false positive
    that fix exists to remove, still present for any quoted remote payload
    that happens to contain `;`/`&&`/`||`/`|`.
  - If the mis-split fragment's target instead LOOKS like an inside-
    worktree relative path, it is silently allowed as if it were a real
    local operation — not a security hole in the strict sense (nothing
    unsafe actually runs locally), but a case where the hook's verdict no
    longer means what its own header claims.

`ssh host "cd /tmp; git stash drop"` was also reproduced allowed (0) for
the wrong reason: NOT because the quoted-word rule made it inert (it did
not — the segment splitter still tore it at the `;`), but because the
second fragment `git stash drop"` happens to land in a LINKED worktree
context in the reproduction session, which is separately allowed by the
existing linked-worktree exception. A main-worktree reproduction of the
same shape would need re-checking against the actual failure mode, not
assumed identical to the `&&` case above.

Left unfixed: fixing this means making scan_command_text's segment
splitter quote-aware (skip splitting inside a quoted span), which is a
change to the shared entry point every re-execution context and the
top-level command both go through — larger and riskier than that fix's own
scope (the ssh/scp/rsync/mosh command-word opacity fix). Workaround until
fixed: avoid `;`/`&&`/`||`/`|` inside a quoted ssh/scp/rsync/mosh remote
command string, or use the `!` prefix to bypass the hook for that one
command.
