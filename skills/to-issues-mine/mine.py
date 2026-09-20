#!/usr/bin/env python3
"""Turn a settled-session capture into a decision-list JSON conforming to
work-order's decision-list/FORMAT.md.

Usage: mine.py --fixture SESSION.md --out DECISION_LIST.json

A settled-session capture is a Markdown file with one `## Decision: <id> —
<title>` section per decision, and a fixed set of `**Label**`/`**Label:**`
fields inside each — see fixtures/settled-session.md for a worked one and
SKILL.md for the full grammar. The judgement that turns a freeform
conversation into that shape happens before this script runs; this script
only turns an already-captured session into schema-shaped JSON. Stdlib only.
"""
import argparse
import json
import re
import sys
from pathlib import Path

DECISION_LIST_VERSION = "0.1.0"

HEADER_RE = re.compile(r"^#\s*Settled session:\s*(.+?)\s*$", re.MULTILINE)
DECISION_SPLIT_RE = re.compile(r"^##\s*Decision:\s*(.+?)\s*$", re.MULTILINE)
INLINE_RE = re.compile(r"^\*\*([A-Za-z ]+):\*\*\s*(.*)$")
BLOCK_HEADER_RE = re.compile(r"^\*\*([A-Za-z ]+)\*\*\s*$")
CHOICE_RE = re.compile(r"^-\s*Choice:\s*(.+)$")
REJECTED_INLINE_RE = re.compile(r"^\s*Rejected:\s*(.+)$")
REJECTED_ITEM_RE = re.compile(r"^\s*-\s*(.+)$")

INLINE_LIST_FIELDS = {"tags", "blocked_by", "touches", "appends", "human_steps"}
SINGLE_LINE_BLOCK_FIELDS = {"verify_fails_today"}


def _field_key(label):
    return label.strip().lower().replace(" ", "_")


def _split_list(value):
    value = value.strip()
    if not value or value.lower() == "none":
        return []
    return [v.strip() for v in value.split(",") if v.strip()]


def _is_marker(line):
    return bool(BLOCK_HEADER_RE.match(line) or INLINE_RE.match(line) or DECISION_SPLIT_RE.match(line))


def _parse_rationale(lines, start):
    """Parse the bullet list under a **Rationale** header, returning
    (items, next_index) where next_index points at the line that ended it."""
    items = []
    current = None
    i = start
    while i < len(lines) and not _is_marker(lines[i]):
        line = lines[i]
        m = CHOICE_RE.match(line.strip())
        if m:
            if current is not None:
                items.append(current)
            current = {"choice": m.group(1).strip(), "rejected": []}
            i += 1
            continue
        m = REJECTED_INLINE_RE.match(line)
        if m and current is not None:
            value = m.group(1).strip()
            if value.lower() != "none":
                current["rejected"].append(value)
            i += 1
            continue
        m = REJECTED_ITEM_RE.match(line)
        if m and current is not None:
            current["rejected"].append(m.group(1).strip())
            i += 1
            continue
        i += 1
    if current is not None:
        items.append(current)
    return items, i


def _parse_verify(lines, start):
    """Parse a fenced code block under a **Verify** header, returning
    (text, next_index)."""
    i = start
    while i < len(lines) and not lines[i].strip().startswith("```"):
        i += 1
    i += 1
    body = []
    while i < len(lines) and not lines[i].strip().startswith("```"):
        body.append(lines[i])
        i += 1
    i += 1
    return "\n".join(body).strip("\n"), i


def parse_decision(block_text):
    lines = block_text.splitlines()
    header_line = lines[0].strip()
    if "—" in header_line:
        raw_id, raw_title = header_line.split("—", 1)
    else:
        raw_id, raw_title = header_line, ""

    entry = {
        "id": raw_id.strip(),
        "title": raw_title.strip(),
        "tags": [],
        "blocked_by": [],
        "touches": [],
        "appends": [],
        "rationale": [],
    }

    i = 1
    while i < len(lines):
        line = lines[i]

        m = INLINE_RE.match(line)
        if m:
            key = _field_key(m.group(1))
            value = m.group(2)
            entry[key] = _split_list(value) if key in INLINE_LIST_FIELDS else value.strip()
            i += 1
            continue

        m = BLOCK_HEADER_RE.match(line)
        if m:
            key = _field_key(m.group(1))
            i += 1
            while i < len(lines) and not lines[i].strip():
                i += 1
            if key == "rationale":
                entry["rationale"], i = _parse_rationale(lines, i)
            elif key == "verify":
                entry["verify"], i = _parse_verify(lines, i)
            else:
                body = []
                while i < len(lines) and not _is_marker(lines[i]):
                    body.append(lines[i])
                    i += 1
                if key in SINGLE_LINE_BLOCK_FIELDS:
                    entry[key] = " ".join(line.strip() for line in body if line.strip())
                else:
                    entry[key] = "\n".join(body).strip()
            continue

        i += 1

    return entry


def mine(text):
    header_match = HEADER_RE.search(text)
    splits = list(DECISION_SPLIT_RE.finditer(text))

    decisions = []
    for idx, m in enumerate(splits):
        start = m.end()
        end = splits[idx + 1].start() if idx + 1 < len(splits) else len(text)
        block_text = m.group(1) + "\n" + text[start:end]
        decisions.append(parse_decision(block_text))

    result = {"decision_list_version": DECISION_LIST_VERSION, "decisions": decisions}
    if header_match:
        result["source"] = header_match.group(1)
    return result


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--fixture", required=True, help="path to a settled-session capture (Markdown)")
    parser.add_argument("--out", required=True, help="path to write the decision-list JSON to")
    args = parser.parse_args(argv[1:])

    try:
        text = Path(args.fixture).read_text(encoding="utf-8")
    except OSError as exc:
        print(f"mine: {args.fixture}: {exc}", file=sys.stderr)
        return 1

    result = mine(text)
    Path(args.out).write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f"mine: wrote {args.out} ({len(result['decisions'])} decision(s))")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
