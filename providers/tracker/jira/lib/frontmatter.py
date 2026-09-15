#!/usr/bin/env python3
"""Parse frontmatter tickets and print one JSON object per line (JSONL) on
stdout, sorted ascending by the numeric suffix of each ticket's `id`.

Ported for jira-import.sh / jira-backfill.sh / verify-jira-keys.sh, which
all need the same local-ticket-id ordering: creates one Jira issue per
line in the order printed here, so a fresh
project's assigned keys land in that same order — the "keys match ids"
property the other two scripts both assume (local ticket NNN -> Jira issue
PROJECT-NNN). See those scripts' headers.

Self-contained copy of to-issues/scripts/issues.py's parse_frontmatter()
algorithm (same hand-rolled subset: scalars, inline lists, block lists,
block scalars) — duplicated rather than imported so providers/ stays
copy-portable into an adopter's own repo independent of where the
to-issues skill happens to be installed (see providers/README.md: this
directory is meant to be copied out, not referenced in place).

Usage:
    frontmatter.py DIR [--schema issues|dotissues]

--schema issues     (default) the standard tree: DIR/<stage>/*.md, stage in
                     open, in-progress, awaiting-deployment, deferred,
                     completed, cancelled (see tickets-protocol; `deferred`
                     is an adopter extension some source trees use, not a
                     stage tickets-protocol itself documents).
--schema dotissues  the chronicle-style flat tree: every *.md file anywhere
                     under DIR, no stage subdirectories. Frontmatter fields
                     are otherwise identical; `_stage` is reported as
                     "cancelled" when the ticket has an `outcome` field and
                     no `verify`, else "imported" (this schema predates the
                     stage-directory convention and never encoded stage in
                     its layout).

Stdlib only. A file with no frontmatter (no leading "---" fence) or whose
`id` has no trailing digits (so it cannot be given an unambiguous position
in the create order) is skipped with a warning on stderr, not silently
dropped and not a fatal error — see main().
"""

import sys
import os
import re
import json
import glob as globmod

STAGES = ["open", "in-progress", "awaiting-deployment", "deferred", "completed", "cancelled"]


def parse_frontmatter(text):
    """Return (dict, body). Handles the subset tickets actually use:
    scalars, inline lists, block lists, and block scalars (| and >-).
    Identical algorithm to to-issues/scripts/issues.py's parse_frontmatter
    — see this file's module docstring for why it is copied, not imported.

    Normalises CRLF/CR line endings to LF first (script-reviewer round on
    71e649c): un-normalised, `lines[0]` is "---\\r", never equal to "---",
    so a CRLF ticket file silently reads as having no frontmatter at all
    rather than erroring — the worst kind of failure for a bulk import."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    lines = text.split("\n")
    if not lines or lines[0] != "---":
        return {}, text
    end_idx = None
    for i in range(1, len(lines)):
        if lines[i] == "---":
            end_idx = i
            break
    if end_idx is None:
        return {}, text
    raw = "\n".join(lines[1:end_idx])
    body = "\n".join(lines[end_idx + 1:])

    data, key, mode, buf = {}, None, None, []

    def flush():
        if key is None:
            return
        if mode == "block":
            data[key] = "\n".join(buf).strip()
        elif mode == "list":
            data[key] = [x for x in buf if x]

    for line in raw.split("\n"):
        if mode == "block" and (line.startswith("  ") or not line.strip()):
            buf.append(line[2:] if line.startswith("  ") else "")
            continue
        if mode == "list" and line.strip().startswith("- "):
            buf.append(line.strip()[2:].strip())
            continue
        flush()
        key, mode, buf = None, None, []

        if not line.strip() or line.strip().startswith("#"):
            continue
        m = re.match(r"^([A-Za-z_][\w-]*):\s*(.*)$", line)
        if not m:
            continue
        k, v = m.group(1), m.group(2).strip()
        if v in ("|", ">-", ">", "|-"):
            key, mode, buf = k, "block", []
        elif v == "":
            key, mode, buf = k, "list", []
            data[k] = []
        elif v.startswith("[") and v.endswith("]"):
            inner = v[1:-1].strip()
            data[k] = [x.strip() for x in inner.split(",") if x.strip()]
        else:
            data[k] = v.strip().strip('"').strip("'")
    flush()
    return data, body


def _num(ticket_id):
    """The trailing digits of PREFIX-NNN, or None when there are none —
    a ticket this script cannot place in create order."""
    if not ticket_id:
        return None
    m = re.search(r"(\d+)$", str(ticket_id))
    return int(m.group(1)) if m else None


def load_issues(root):
    tickets = []
    for stage in STAGES:
        for path in sorted(globmod.glob(os.path.join(root, stage, "*.md"))):
            fm, body = parse_frontmatter(open(path).read())
            fm["_path"], fm["_stage"], fm["_body"] = path, stage, body
            tickets.append(fm)
    return tickets


def load_dotissues(root):
    tickets = []
    for path in sorted(globmod.glob(os.path.join(root, "**", "*.md"), recursive=True)):
        fm, body = parse_frontmatter(open(path).read())
        if not fm:
            continue
        stage = "cancelled" if (fm.get("outcome") and not fm.get("verify")) else "imported"
        fm["_path"], fm["_stage"], fm["_body"] = path, stage, body
        tickets.append(fm)
    return tickets


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return 0

    schema = "issues"
    positional = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--schema":
            if i + 1 >= len(argv):
                print("frontmatter.py: --schema needs a value", file=sys.stderr)
                return 2
            schema = argv[i + 1]
            i += 2
            continue
        positional.append(a)
        i += 1

    if schema not in ("issues", "dotissues"):
        print(f"frontmatter.py: --schema must be 'issues' or 'dotissues' (got '{schema}')", file=sys.stderr)
        return 2
    if not positional:
        print("frontmatter.py: usage: frontmatter.py DIR [--schema issues|dotissues]", file=sys.stderr)
        return 2
    root = positional[0]
    if not os.path.isdir(root):
        print(f"frontmatter.py: not a directory: {root}", file=sys.stderr)
        return 2

    tickets = load_issues(root) if schema == "issues" else load_dotissues(root)

    numbered = []
    for t in tickets:
        n = _num(t.get("id"))
        if n is None:
            print(f"frontmatter.py: skipping {t.get('_path')}: id '{t.get('id')}' has no trailing digits", file=sys.stderr)
            continue
        t["_num"] = n
        numbered.append(t)

    numbered.sort(key=lambda t: t["_num"])
    for t in numbered:
        print(json.dumps(t))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
