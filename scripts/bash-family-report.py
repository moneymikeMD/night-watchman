#!/usr/bin/env python3
"""bash-family-report.py — rank Bash tool-call "families" across local
Claude Code JSONL transcripts by evidence, so the question "should this
repeated invocation become a typed tool" is answered by counting instead
of impression (see docs/cost.md).

Streams every `~/.claude/projects/**/*.jsonl` file (main session and any
subagent transcript, same corpus `claude-cost-scan.py`/`script-analytics.py`
read), collecting every Bash `tool_use` block's `command`. Each command is
normalised to a "family" key:

    - a leading `cd <path> &&` and any leading `VAR=value` assignments are
      stripped — ceremony, not a distinguishing part of the call
    - a heredoc form (`<<` anywhere in the remainder) folds to
      `python3 heredoc` or `cat > heredoc` — a heredoc is a program
      delivered through Bash, not a call worth ranking by its body
    - otherwise the family is the executable's basename plus its first
      non-flag argument (e.g. `./scripts/jira-api.sh raw ...` families as
      `jira-api.sh raw`), or just the basename if there is no such argument

Families are ranked by call count; average command length (of the
ORIGINAL, un-normalised command) is reported alongside it, since volume
alone picks out `grep`-shaped noise while length is what flags a call
worth turning into a typed tool.

Flags:
    --projects-dir <path>  override ~/.claude/projects (mainly for tests)
    --since <iso8601>      only Bash calls at/after this timestamp
    --top <n>              max families to report, ranked by count (default: 20)
    --format text|json     output format (default: text)

This script never prints a command's full text unbounded — the reported
`example` is truncated to 200 characters and never the whole corpus.

Exit codes: 0 success, 2 a validation failure (bad input; printed to
stderr, no traceback), 1 an unexpected error.
"""

import argparse
import glob
import json
import os
import shlex
import sys
from datetime import datetime, timezone
import re


class ValidationError(Exception):
    """Raised for any expected user-input problem. Caught in main() and
    reported to stderr with exit 2 — never a traceback."""


EXAMPLE_MAX_CHARS = 200

CD_PREFIX_RE = re.compile(r'^cd\s+(?:"[^"]*"|\'[^\']*\'|[^\s&]+)\s*&&\s*')
VAR_ASSIGN_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|\'[^\']*\'|\S*)\s+')
HEREDOC_RE = re.compile(r'<<-?\s*[\'"]?\w+')
CAT_REDIRECT_RE = re.compile(r'^cat\s+>>?')


def default_projects_dir():
    return os.path.expanduser("~/.claude/projects")


def parse_timestamp(text):
    text = text.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        raise ValidationError("could not parse timestamp: %r" % text)
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def parse_line_timestamp(d):
    raw_ts = d.get("timestamp")
    if not raw_ts:
        return None
    try:
        return parse_timestamp(raw_ts)
    except ValidationError:
        return None


def iter_bash_calls(projects_dir, since):
    """Yield (timestamp_or_None, command) for every Bash tool_use block
    found under projects_dir/**/*.jsonl. A line is skipped before it is
    even handed to json.loads unless it contains the literal substring
    "Bash" — a tool_use block for any other tool never does, and this is
    the cheap filter that keeps a 1GB+ corpus scan fast."""
    pattern = os.path.join(projects_dir, "**", "*.jsonl")
    for path in sorted(glob.glob(pattern, recursive=True)):
        try:
            with open(path, "r", errors="replace") as fh:
                for raw in fh:
                    if "Bash" not in raw:
                        continue
                    raw = raw.strip()
                    if not raw:
                        continue
                    try:
                        d = json.loads(raw)
                    except json.JSONDecodeError:
                        continue
                    if not isinstance(d, dict):
                        continue
                    msg = d.get("message")
                    if not isinstance(msg, dict):
                        continue
                    content = msg.get("content")
                    if not isinstance(content, list):
                        continue
                    ts = parse_line_timestamp(d)
                    if since is not None and (ts is None or ts < since):
                        continue
                    for block in content:
                        if not (isinstance(block, dict) and block.get("type") == "tool_use"
                                and block.get("name") == "Bash"):
                            continue
                        command = (block.get("input") or {}).get("command")
                        if not command:
                            continue
                        yield ts, command
        except OSError:
            continue


def strip_ceremony(command):
    """Strip a leading `cd <path> &&` and any leading `VAR=value`
    assignments — ceremony a family key should not vary on."""
    rest = command.strip()
    rest = CD_PREFIX_RE.sub("", rest, count=1)
    while True:
        stripped = VAR_ASSIGN_RE.sub("", rest, count=1)
        if stripped == rest:
            break
        rest = stripped
    return rest.strip()


def family_key(command):
    """Return the family key for one Bash command, per the normalisation
    rules in this file's own docstring."""
    rest = strip_ceremony(command)
    if not rest:
        return "(empty)"
    if HEREDOC_RE.search(rest):
        first_word = rest.split(None, 1)[0]
        if first_word in ("python3", "python"):
            return "python3 heredoc"
        if CAT_REDIRECT_RE.match(rest):
            return "cat > heredoc"
    try:
        tokens = shlex.split(rest, posix=True)
    except ValueError:
        tokens = rest.split()
    if not tokens:
        return "(empty)"
    exe = os.path.basename(tokens[0])
    for tok in tokens[1:]:
        if not tok.startswith("-"):
            return "%s %s" % (exe, tok)
    return exe


def build_families(calls):
    """calls: iterable of (ts, command). Returns
    {family: {"count", "total_len", "example"}} keyed by family_key()."""
    families = {}
    for _ts, command in calls:
        key = family_key(command)
        f = families.setdefault(key, {"count": 0, "total_len": 0, "example": None})
        f["count"] += 1
        f["total_len"] += len(command)
        if f["example"] is None:
            f["example"] = command
    return families


def truncate_example(command):
    example = command.replace("\n", "\\n")
    if len(example) > EXAMPLE_MAX_CHARS:
        example = example[:EXAMPLE_MAX_CHARS] + "…"
    return example


def rank_rows(families, top):
    rows = []
    for family, f in families.items():
        avg = f["total_len"] / f["count"]
        rows.append({
            "family": family,
            "count": f["count"],
            "avg_chars": round(avg, 1),
            "example": truncate_example(f["example"]),
        })
    rows.sort(key=lambda r: (-r["count"], r["family"]))
    if top is not None:
        rows = rows[:top]
    return rows


def render_text(rows):
    headers = ["family", "count", "avg_chars", "example"]
    lines = ["\t".join(headers)]
    for r in rows:
        lines.append("\t".join(str(r[h]) for h in headers))
    return "\n".join(lines)


def render_json(rows):
    return json.dumps(rows, indent=2)


RENDERERS = {"text": render_text, "json": render_json}


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="bash-family-report.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--projects-dir", default=None,
                         help="override ~/.claude/projects (mainly for tests)")
    parser.add_argument("--since", default=None,
                         help="only Bash calls at/after this ISO-8601 timestamp")
    parser.add_argument("--top", type=int, default=20,
                         help="max families to report, ranked by call count (default: 20)")
    parser.add_argument("--format", choices=sorted(RENDERERS.keys()), default="text")
    args = parser.parse_args(argv)
    if args.projects_dir is None:
        args.projects_dir = default_projects_dir()
    return args


def main(argv):
    try:
        args = parse_args(argv)
        since = parse_timestamp(args.since) if args.since else None
        calls = iter_bash_calls(args.projects_dir, since)
        families = build_families(calls)
        rows = rank_rows(families, args.top)
        renderer = RENDERERS[args.format]
        print(renderer(rows))
    except ValidationError as e:
        print("bash-family-report.py: %s" % e, file=sys.stderr)
        return 2
    except Exception as e:  # noqa: BLE001 - last-resort, never a bare traceback for expected paths
        print("bash-family-report.py: unexpected error: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
