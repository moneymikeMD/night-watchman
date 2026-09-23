#!/usr/bin/env python3
"""claude-cost-scan.py — scan local Claude Code JSONL transcripts and
report per-session/per-model turns, tokens, and cost.

This is the scanning half of the cost-ledger pair (see docs/cost.md):
`claude-cost.py` is a generic ledger (append/list/compare) that takes
--cost/--turns from whatever the caller already has; this script is one
way to produce those numbers from this machine's own local transcripts,
so a caller does not have to read /cost output by hand.

Transcript layout (as written by the Claude Code CLI), THREE shapes:
    ~/.claude/projects/<slug>/<session-uuid>.jsonl            main session
    ~/.claude/projects/<slug>/<session-uuid>/subagents/agent-*.jsonl
                                                                Agent-tool turns
    ~/.claude/projects/<slug>/<session-uuid>/subagents/workflows/wf_*/agent-*.jsonl
                                                                Workflow-tool turns
The third shape is two levels deeper under the same subagents/ root, and
each wf_*/ also holds a journal.jsonl that is not a transcript and is not
read. Missing it is a SILENT under-count, not an error: the scan still
completes and the total simply omits every token a workflow's agents
spent, so the larger the fan-out the worse the number (NWM-152).
`<slug>` is the session's working directory with every "/", "." and "_"
replaced by "-" (e.g. /Users/me/code/my_repo -> -Users-me-code-my-repo).
--repo
computes this from a path; --project-slug takes it directly for a
transcript layout this script cannot derive itself.

A "turn" is one assistant message. Streaming can write several JSONL
lines that share one `message.id` as a message is revised in place (the
CRITICAL finding from the source project this was ported from) — counting
each line would over-count turns and tokens, so lines are grouped by
message id first and only the last line seen per id is kept.

Cost is computed from a price table (--prices, default
templates/claude-prices.tsv next to this script) of $/million-tokens by
model and token class (input, output, cache write, cache read). A model
missing from the table is reported with tokens but zero cost, flagged
once on stderr — never a hard failure, since a stale price table should
not stop a report from printing.

Flags:
    --repo <path>          derive the transcript slug from a repo path
    --project-slug <slug>  the transcript slug directly
    --session <id>         limit to one session (searches all project
                            dirs under --projects-dir if --repo/
                            --project-slug is not also given)
    --since / --until      ISO-8601 timestamp bounds on each turn's own
                            content timestamp (inclusive both ends)
    --prices <tsv>         price table path (see templates/claude-prices.tsv)
    --projects-dir <path>  override ~/.claude/projects (mainly for tests)
    --format tsv|md|json   output format (default: tsv)
    --ledger-line          print exactly `cost: $<usd>, <turns> turns` and
                            nothing else — for a ticket outcome comment
    --ledger-fields        print orchestrator_model/orchestrator_effort/
                            orchestrator_turns/orchestrator_usd/worker_turns/
                            worker_usd as tab-separated key-value lines, for
                            claude-cost.py append's --orchestrator-*/
                            --worker-* flags. The main transcript file is
                            "orchestrator", every subagents/ transcript is
                            "worker" — a filesystem-position label, not a
                            claim about who dispatched whom. Effort comes
                            from each turn's own `perTurnEffort` field when
                            present; a role with no such value anywhere
                            reads `UNVERIFIED`, never a guess, and a role
                            that used more than one model or effort value
                            reads `mixed:a,b`.

This script never prints message content — only ids, timestamps, model
names, and token/cost numbers.

Exit codes: 0 success, 2 a validation failure (bad input; printed to
stderr, no traceback), 1 an unexpected error.
"""

import argparse
import csv
import glob
import json
import os
import sys
from datetime import datetime, timezone


class ValidationError(Exception):
    """Raised for any expected user-input problem. Caught in main() and
    reported to stderr with exit 2 — never a traceback."""


TOKEN_CLASSES = ("input", "output", "cache_write", "cache_read")
PRICE_COLUMNS = ("model",) + tuple("%s_per_mtok" % c for c in TOKEN_CLASSES)


def slugify_repo(path):
    """Reproduce the Claude Code CLI's transcript directory naming: the
    absolute path with every "/", "." and "_" replaced by "-". The "_" case
    is not cosmetic here — every repo on this machine lives under a
    home_workspace-shaped parent, so omitting it broke --repo for every path
    that matters (NWM-165)."""
    # Observed live 2026-09-22: no slug under ~/.claude/projects contains an
    # underscore, and home_exp_workspace appears as -home-exp-workspace.
    # A path segment containing a SPACE stays UNVERIFIED, as in homelab's
    # equivalent; the plain replace is applied either way.
    abspath = os.path.abspath(os.path.expanduser(path))
    return "".join("-" if ch in "/._" else ch for ch in abspath)


def default_projects_dir():
    return os.path.expanduser("~/.claude/projects")


ROLE_ORCHESTRATOR = "orchestrator"
ROLE_WORKER = "worker"


def find_session_files(projects_dir, slug, session_id):
    """Return a list of (session_id, [(path, role) ...]) for every session
    under projects_dir/slug (or, if slug is None, every project dir),
    optionally narrowed to one session_id. Collects both subagent shapes:
    Agent-tool transcripts directly under subagents/, and Workflow-tool
    transcripts under subagents/workflows/wf_*/ — both tagged role="worker",
    the main transcript role="orchestrator". This is a filesystem-position
    label, not a claim about who dispatched whom."""
    if slug is not None:
        project_dirs = [os.path.join(projects_dir, slug)]
    else:
        project_dirs = sorted(glob.glob(os.path.join(projects_dir, "*")))

    sessions = []
    for project_dir in project_dirs:
        if not os.path.isdir(project_dir):
            continue
        for main_file in sorted(glob.glob(os.path.join(project_dir, "*.jsonl"))):
            sid = os.path.splitext(os.path.basename(main_file))[0]
            if session_id is not None and sid != session_id:
                continue
            files = [(main_file, ROLE_ORCHESTRATOR)]
            subagents_dir = os.path.join(project_dir, sid, "subagents")
            files.extend(
                (p, ROLE_WORKER)
                for p in sorted(glob.glob(os.path.join(subagents_dir, "agent-*.jsonl")))
            )
            files.extend(
                (p, ROLE_WORKER)
                for p in sorted(glob.glob(os.path.join(
                    subagents_dir, "workflows", "wf_*", "agent-*.jsonl")))
            )
            sessions.append((sid, files))
    return sessions


def parse_timestamp(text):
    if text is None:
        return None
    # A bare "Z" suffix is rewritten to +00:00: Python's fromisoformat
    # predates that shorthand.
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


def usage_tokens(usage):
    return {
        "input": usage.get("input_tokens", 0) or 0,
        "output": usage.get("output_tokens", 0) or 0,
        "cache_write": usage.get("cache_creation_input_tokens", 0) or 0,
        "cache_read": usage.get("cache_read_input_tokens", 0) or 0,
    }


def scan_file(path, role, turns_by_id):
    """Read one JSONL transcript file, updating turns_by_id in place:
    message id -> turn dict (session_id, timestamp, model, tokens, role,
    effort). Later lines for an id already seen overwrite the earlier one,
    which is how the several-lines-per-message-id dedupe happens. `effort`
    is the entry's own top-level `perTurnEffort` field when the CLI wrote
    one, else None — the caller decides what a missing value means, this
    function never guesses."""
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except ValueError:
                continue
            if entry.get("type") != "assistant":
                continue
            message = entry.get("message") or {}
            usage = message.get("usage")
            msg_id = message.get("id")
            if not usage or not msg_id:
                continue
            turns_by_id[msg_id] = {
                "session_id": entry.get("sessionId"),
                "timestamp": entry.get("timestamp"),
                "model": message.get("model") or "unknown",
                "tokens": usage_tokens(usage),
                "role": role,
                "effort": entry.get("perTurnEffort") or None,
            }


def scan_sessions(sessions, since, until):
    """Return a flat list of turn dicts (adding a resolved 'session'
    label — the transcript session id, not message.sessionId, since a
    subagent's own message.sessionId differs from its parent) across all
    given (session_id, [(path, role)]) pairs, filtered by [since, until] on
    each turn's own timestamp."""
    turns = []
    for session_id, paths in sessions:
        turns_by_id = {}
        for path, role in paths:
            scan_file(path, role, turns_by_id)
        for turn in turns_by_id.values():
            ts = parse_timestamp(turn["timestamp"])
            if since is not None and (ts is None or ts < since):
                continue
            if until is not None and (ts is None or ts > until):
                continue
            turn["session"] = session_id
            turns.append(turn)
    return turns


def read_prices(path):
    prices = {}
    with open(path) as f:
        reader = csv.DictReader(f, delimiter="\t")
        if reader.fieldnames != list(PRICE_COLUMNS):
            raise ValidationError(
                "--prices %s: header must be exactly %s (found %s)"
                % (path, "\t".join(PRICE_COLUMNS), "\t".join(reader.fieldnames or []))
            )
        for row in reader:
            model = row["model"]
            try:
                prices[model] = {c: float(row["%s_per_mtok" % c]) for c in TOKEN_CLASSES}
            except ValueError:
                raise ValidationError("--prices %s: non-numeric rate for model %r" % (path, model))
    return prices


def turn_cost(turn, prices, warned_models):
    rate = prices.get(turn["model"])
    if rate is None:
        if turn["model"] not in warned_models:
            print("claude-cost-scan.py: no price row for model %r; costing as $0" % turn["model"],
                  file=sys.stderr)
            warned_models.add(turn["model"])
        return 0.0
    tokens = turn["tokens"]
    return sum(tokens[c] / 1_000_000.0 * rate[c] for c in TOKEN_CLASSES)


def group_turns(turns, prices, warned_models):
    """Return {(session, model): {"turns": n, "tokens": n, "cost": f}}."""
    groups = {}
    for turn in turns:
        key = (turn["session"], turn["model"])
        g = groups.setdefault(key, {"turns": 0, "tokens": 0, "cost": 0.0})
        g["turns"] += 1
        g["tokens"] += sum(turn["tokens"].values())
        g["cost"] += turn_cost(turn, prices, warned_models)
    return groups


def group_by_role(turns, prices, warned_models):
    """Return {(role, model): {"turns": n, "tokens": n, "cost": f,
    "efforts": {values}}} — the per-role counterpart to group_turns, used
    only by --ledger-fields. `efforts` collects every non-null
    perTurnEffort seen for that (role, model), so the caller can tell a
    single consistent value from a mix or from none at all."""
    groups = {}
    for turn in turns:
        key = (turn["role"], turn["model"])
        g = groups.setdefault(key, {"turns": 0, "tokens": 0, "cost": 0.0, "efforts": set()})
        g["turns"] += 1
        g["tokens"] += sum(turn["tokens"].values())
        g["cost"] += turn_cost(turn, prices, warned_models)
        if turn["effort"]:
            g["efforts"].add(turn["effort"])
    return groups


def summarize_role(groups, role):
    """Reduce group_by_role's per-(role, model) buckets to one row for a
    single role: total turns/cost across every model that role used, the
    model with the most turns (or "mixed:<a>,<b>,..." when more than one
    model appears), and the effort the same way — "UNVERIFIED" when no
    turn for this role ever carried a perTurnEffort value, never a guess."""
    rows = {model: g for (r, model), g in groups.items() if r == role}
    if not rows:
        return {"model": "-", "effort": "UNVERIFIED", "turns": 0, "cost": 0.0}
    total_turns = sum(g["turns"] for g in rows.values())
    total_cost = sum(g["cost"] for g in rows.values())
    models_by_turns = sorted(rows.items(), key=lambda kv: (-kv[1]["turns"], kv[0]))
    if len(models_by_turns) == 1:
        model = models_by_turns[0][0]
    else:
        model = "mixed:" + ",".join(m for m, _ in models_by_turns)
    efforts = set()
    for g in rows.values():
        efforts |= g["efforts"]
    if not efforts:
        effort = "UNVERIFIED"
    elif len(efforts) == 1:
        effort = next(iter(efforts))
    else:
        effort = "mixed:" + ",".join(sorted(efforts))
    return {"model": model, "effort": effort, "turns": total_turns, "cost": total_cost}


def render_table_rows(groups):
    rows = []
    for (session, model), g in sorted(groups.items()):
        rows.append([session, model, g["turns"], g["tokens"], "%.4f" % g["cost"]])
    total_turns = sum(g["turns"] for g in groups.values())
    total_tokens = sum(g["tokens"] for g in groups.values())
    total_cost = sum(g["cost"] for g in groups.values())
    rows.append(["TOTAL", "", total_turns, total_tokens, "%.4f" % total_cost])
    return rows


def render_tsv(headers, rows):
    lines = ["\t".join(headers)]
    lines.extend("\t".join(str(x) for x in r) for r in rows)
    return "\n".join(lines)


def render_md(headers, rows):
    lines = ["| " + " | ".join(headers) + " |"]
    lines.append("| " + " | ".join("---" for _ in headers) + " |")
    for r in rows:
        lines.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(lines)


def render_json(headers, rows):
    return json.dumps([dict(zip(headers, r)) for r in rows], indent=2)


RENDERERS = {"tsv": render_tsv, "md": render_md, "json": render_json}
HEADERS = ["session", "model", "turns", "tokens", "cost_usd"]


def cmd_scan(args):
    if not args.repo and not args.project_slug and not args.session:
        raise ValidationError("one of --repo, --project-slug, or --session is required")

    slug = None
    if args.project_slug:
        slug = args.project_slug
    elif args.repo:
        slug = slugify_repo(args.repo)

    sessions = find_session_files(args.projects_dir, slug, args.session)
    if not sessions:
        raise ValidationError(
            "no transcripts found under %s%s"
            % (args.projects_dir, (" for slug %r" % slug) if slug else "")
        )

    since = parse_timestamp(args.since) if args.since else None
    until = parse_timestamp(args.until) if args.until else None
    turns = scan_sessions(sessions, since, until)

    prices = read_prices(args.prices)
    warned_models = set()
    groups = group_turns(turns, prices, warned_models)

    if args.ledger_line:
        total_turns = sum(g["turns"] for g in groups.values())
        total_cost = sum(g["cost"] for g in groups.values())
        print("cost: $%.4f, %d turns" % (total_cost, total_turns))
        return

    if args.ledger_fields:
        role_groups = group_by_role(turns, prices, warned_models)
        orch = summarize_role(role_groups, ROLE_ORCHESTRATOR)
        work = summarize_role(role_groups, ROLE_WORKER)
        fields = [
            ("orchestrator_model", orch["model"]),
            ("orchestrator_effort", orch["effort"]),
            ("orchestrator_turns", "%d" % orch["turns"]),
            ("orchestrator_usd", "%.4f" % orch["cost"]),
            ("worker_turns", "%d" % work["turns"]),
            ("worker_usd", "%.4f" % work["cost"]),
        ]
        for key, value in fields:
            print("%s\t%s" % (key, value))
        return

    rows = render_table_rows(groups)
    renderer = RENDERERS[args.format]
    print(renderer(HEADERS, rows))


def default_prices_path():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "templates", "claude-prices.tsv")


def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="claude-cost-scan.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--repo", default=None, help="repo path; the transcript slug is derived from it")
    parser.add_argument("--project-slug", default=None, help="transcript slug directly")
    parser.add_argument("--session", default=None, help="limit to one session id")
    parser.add_argument("--since", default=None, help="only turns at/after this ISO-8601 timestamp")
    parser.add_argument("--until", default=None, help="only turns at/before this ISO-8601 timestamp")
    parser.add_argument("--prices", default=None, help="price table TSV (default: templates/claude-prices.tsv)")
    parser.add_argument("--projects-dir", default=None,
                         help="override ~/.claude/projects (mainly for tests)")
    parser.add_argument("--format", choices=sorted(RENDERERS.keys()), default="tsv")
    parser.add_argument("--ledger-line", action="store_true",
                         help="print exactly 'cost: $<usd>, <turns> turns' and nothing else")
    parser.add_argument("--ledger-fields", action="store_true", dest="ledger_fields",
                         help="print orchestrator_model/orchestrator_effort/orchestrator_turns/"
                              "orchestrator_usd/worker_turns/worker_usd as tab-separated "
                              "key-value lines, for claude-cost.py append's --orchestrator-*/"
                              "--worker-* flags")
    args = parser.parse_args(argv)
    if args.prices is None:
        args.prices = default_prices_path()
    if args.projects_dir is None:
        args.projects_dir = default_projects_dir()
    return args


def main(argv):
    try:
        args = parse_args(argv)
        cmd_scan(args)
    except ValidationError as e:
        print("claude-cost-scan.py: %s" % e, file=sys.stderr)
        return 2
    except Exception as e:  # noqa: BLE001 - last-resort, never a bare traceback for expected paths
        print("claude-cost-scan.py: unexpected error: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
