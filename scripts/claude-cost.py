#!/usr/bin/env python3
"""claude-cost.py — a small, dependency-free ledger for tracking what an
agentic wave of work cost, in whatever unit the caller wants (dollars,
tokens, whatever their own accounting already uses).

This is a deliberately generic port of a source-project-specific script
that scanned local Claude Code JSONL transcripts, priced every token against a
hardcoded model table, and cross-checked the total against a Grafana Cloud
metric. None of that travels well to an arbitrary project: transcript
layout, model pricing, and whether Grafana even exists are all things this
plugin cannot assume. What DOES travel is the shape of the record worth
keeping: one row per wave, with enough columns that a reviewer can ask "did
last wave's change actually move the number" without re-deriving it from
scratch.

Ledger schema (TSV, one row per wave):
    date        ISO-8601 date or timestamp the row was recorded (not
                necessarily when the wave ran — see --date)
    wave        a short label for the wave (e.g. "2026-09-12-am"); must be
                unique within one ledger
    turns       integer — total agent turns spent on the wave, however the
                caller counts a "turn"
    cost_usd    float — total cost for the wave, in whatever currency/unit
                the caller's own accounting uses (the column name says USD
                because that's the common case; nothing here enforces it)
    model_mix   free text — e.g. "sonnet-5:80,opus-5:20" or "haiku only";
                this script does not parse or validate its internal shape,
                it only forbids a tab or newline from corrupting the row
    notes       free text — what changed this wave, what was adopted from
                the previous review, anything a later reviewer needs

Nothing in this script reads a Claude Code transcript, calls any API, or
knows a model's price. The caller supplies cost and turns directly (from
`/cost`, a provider's own billing export, or a project-specific script that
does the scanning this one deliberately does not). That is the generic
seam: a project that wants automatic transcript scanning owns that piece
itself and feeds this script's --cost/--turns from its output.

Subcommands:
    append   add one row to the ledger (refuses a duplicate wave, refuses a
             stale/mismatched header; writes header-if-needed and the row
             as a single os.write()+fsync, intended but UNVERIFIED to
             narrow the crash-mid-append window — see append_ledger_row)
    list     print the ledger's rows
    compare  print a delta table between one row (--wave, default: the
             last row) and the row immediately before it, flagging each
             numeric column up/down/flat at a +/-5% threshold

Exit codes: 0 success, 2 a validation failure (bad input; printed to
stderr, no traceback), 1 an unexpected error.
"""

import argparse
import json
import os
import sys
from datetime import datetime, timezone

LEDGER_COLUMNS = ("date", "wave", "turns", "cost_usd", "model_mix", "notes")
LEDGER_HEADER_LINE = "\t".join(LEDGER_COLUMNS)
LEDGER_DECIMALS = {"cost_usd": 4}
LEDGER_INT_COLUMNS = ("turns",)
LEDGER_NUMERIC_COLUMNS = ("turns", "cost_usd")


class ValidationError(Exception):
    """Raised for any expected user-input problem. Caught in main() and
    reported to stderr with exit 2 — never a traceback."""


def validate_field(text, label):
    """Reject a tab or newline in a free-text ledger field — either would
    corrupt the TSV row shape on append."""
    if "\t" in text or "\n" in text:
        raise ValidationError("%s must not contain a tab or newline" % label)


def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_ledger(path):
    """Return the list of row dicts (column name -> string value) already
    in the ledger at path, in file order. A missing or empty file is an
    empty ledger, not an error — the caller writes the header on first
    append.

    Every row this script itself ever writes ends with a newline; a file
    that does NOT end with one therefore did not finish being written — a
    crash mid-append, not a body row to parse. That case is reported by
    line number with a repair hint rather than silently dropped or fed to
    the field-count parser below (which would otherwise raise a generic
    "wrong number of fields" error indistinguishable from hand-edited
    corruption).

    Raises ValidationError if a present, non-empty file's header line does
    not exactly match LEDGER_HEADER_LINE (a stale schema must be noticed,
    never silently appended to), if the file's last line has no trailing
    newline, or if any complete body line has the wrong number of
    tab-separated fields.
    """
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        return []
    with open(path, "r", encoding="utf-8") as fh:
        raw = fh.read()
    if not raw:
        return []
    if not raw.endswith("\n"):
        lineno = raw.count("\n") + 1
        raise ValidationError(
            "--ledger %s line %d is truncated (no trailing newline) — looks like a crash "
            "mid-append; repair by opening the file and deleting that incomplete last line "
            "(the rows before it are intact), then retry" % (path, lineno)
        )
    lines = raw.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    if not lines:
        return []
    header = lines[0]
    if header != LEDGER_HEADER_LINE:
        raise ValidationError(
            "--ledger %s has an unexpected header line (stale schema?): %r — expected %r"
            % (path, header, LEDGER_HEADER_LINE)
        )
    rows = []
    for lineno, line in enumerate(lines[1:], start=2):
        if not line.strip():
            continue
        fields = line.split("\t")
        if len(fields) != len(LEDGER_COLUMNS):
            raise ValidationError(
                "--ledger %s line %d has %d field(s), expected %d"
                % (path, lineno, len(fields), len(LEDGER_COLUMNS))
            )
        rows.append(dict(zip(LEDGER_COLUMNS, fields)))
    return rows


def format_ledger_value(col, value):
    if col in LEDGER_INT_COLUMNS:
        return "%d" % int(value)
    if col in LEDGER_DECIMALS:
        return ("%." + str(LEDGER_DECIMALS[col]) + "f") % float(value)
    return str(value)


def build_row(date, wave, turns, cost_usd, model_mix, notes):
    values = {
        "date": date,
        "wave": wave,
        "turns": turns,
        "cost_usd": cost_usd,
        "model_mix": model_mix,
        "notes": notes,
    }
    return {col: format_ledger_value(col, values[col]) for col in LEDGER_COLUMNS}


def render_row(row):
    return "\t".join(row[col] for col in LEDGER_COLUMNS)


def append_ledger_row(path, row):
    """Append one row to the ledger at path in a SINGLE os.write() —
    header-if-needed and the row itself, both newline-terminated, as one
    chunk — followed by fsync before close, instead of two separate
    write() calls (header, then row). UNVERIFIED: this is intended to
    narrow the crash window where a header could land with no row, or a
    prior append's trailing newline could be missing when this one
    starts, but that has not been tested against an actual interrupted
    write (e.g. a killed process, a full disk) — the selftest only
    exercises the READ side (read_ledger()'s repair-hint path on an
    already-truncated file), not that this write path is itself atomic
    under a real crash."""
    need_header = not os.path.isfile(path) or os.path.getsize(path) == 0
    chunk = ""
    if need_header:
        chunk += LEDGER_HEADER_LINE + "\n"
    chunk += render_row(row) + "\n"
    data = chunk.encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


def append_ledger_jsonl(path, row):
    """Append one row (dict, same field names as LEDGER_COLUMNS) to the
    sibling JSONL log at path as a single JSON object per line, in one
    os.write() followed by fsync before close — same crash-safety
    discipline as append_ledger_row, so a log shipper tailing this file
    never reads a torn line."""
    data = (json.dumps(row) + "\n").encode("utf-8")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, data)
        os.fsync(fd)
    finally:
        os.close(fd)


# --------------------------------------------------------------- render
def render_table(headers, rows):
    if not rows:
        widths = [len(h) for h in headers]
    else:
        widths = [
            max(len(h), max(len(str(r[i])) for r in rows))
            for i, h in enumerate(headers)
        ]
    lines = ["  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))]
    lines.append("  ".join("-" * w for w in widths))
    for r in rows:
        lines.append("  ".join(str(r[i]).ljust(widths[i]) for i in range(len(headers))))
    return "\n".join(lines)


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


RENDERERS = {"table": render_table, "tsv": render_tsv, "md": render_md}


# ------------------------------------------------------------- subcommands
def cmd_append(args):
    validate_field(args.wave, "--wave")
    if args.date is not None:
        validate_field(args.date, "--date")
    if args.notes is not None:
        validate_field(args.notes, "--notes")
    if args.model is not None:
        validate_field(args.model, "--model")
    if args.turns < 0:
        raise ValidationError("--turns must be >= 0 (got %d)" % args.turns)
    if args.cost < 0:
        raise ValidationError("--cost must be >= 0 (got %s)" % args.cost)

    existing = read_ledger(args.ledger)
    if any(r["wave"] == args.wave for r in existing):
        raise ValidationError(
            "--ledger %s already has a row for wave '%s'" % (args.ledger, args.wave)
        )

    row = build_row(
        date=args.date or now_iso(),
        wave=args.wave,
        turns=args.turns,
        cost_usd=args.cost,
        model_mix=args.model or "-",
        notes=args.notes or "-",
    )

    if args.dry_run:
        print(LEDGER_HEADER_LINE)
        print(render_row(row))
        return
    jsonl_path = os.path.splitext(args.ledger)[0] + ".jsonl"
    append_ledger_row(args.ledger, row)
    append_ledger_jsonl(jsonl_path, row)
    print(
        "# ledger: appended wave %s to %s and %s"
        % (args.wave, args.ledger, jsonl_path)
    )


def cmd_list(args):
    rows = read_ledger(args.ledger)
    if args.limit is not None:
        rows = rows[-args.limit:]
    renderer = RENDERERS[args.format]
    table_rows = [[r[col] for col in LEDGER_COLUMNS] for r in rows]
    print(renderer(list(LEDGER_COLUMNS), table_rows))


def cmd_compare(args):
    """Read-only delta report between one ledger row ("current" — --wave,
    default: the ledger's last row) and the row immediately before it in
    the file ("previous"). Never writes."""
    rows = read_ledger(args.ledger)
    if len(rows) < 2:
        raise ValidationError(
            "--compare requires at least two rows in --ledger %s (found %d)"
            % (args.ledger, len(rows))
        )
    if args.wave:
        idx = next((i for i, r in enumerate(rows) if r["wave"] == args.wave), None)
        if idx is None:
            raise ValidationError("compare: wave '%s' not found in %s" % (args.wave, args.ledger))
        if idx == 0:
            raise ValidationError(
                "compare: wave '%s' is the first row in %s — nothing to compare against"
                % (args.wave, args.ledger)
            )
    else:
        idx = len(rows) - 1

    cur, prev = rows[idx], rows[idx - 1]
    headers = ["metric", "previous", "current", "delta", "delta_pct", "direction"]
    table_rows = []
    for col in LEDGER_NUMERIC_COLUMNS:
        try:
            pv = float(prev[col])
            cv = float(cur[col])
        except ValueError:
            raise ValidationError(
                "--ledger %s: wave '%s' or '%s' has a non-numeric '%s' value ('%s' / '%s')"
                % (args.ledger, prev["wave"], cur["wave"], col, prev[col], cur[col])
            )
        delta = cv - pv
        if pv == 0:
            delta_pct_str, direction = "n/a", "flat"
        else:
            delta_pct = delta / pv * 100.0
            delta_pct_str = "%.2f" % delta_pct
            direction = "flat" if abs(delta_pct) < 5.0 else ("up" if delta > 0 else "down")

        if col in LEDGER_INT_COLUMNS:
            pv_s, cv_s, delta_s = "%d" % pv, "%d" % cv, "%+d" % int(round(delta))
        else:
            decimals = LEDGER_DECIMALS.get(col, 2)
            pv_s = ("%." + str(decimals) + "f") % pv
            cv_s = ("%." + str(decimals) + "f") % cv
            delta_s = ("%+." + str(decimals) + "f") % delta
        table_rows.append([col, pv_s, cv_s, delta_s, delta_pct_str, direction])

    renderer = RENDERERS[args.format]
    print("# compare: %s -> %s" % (prev["wave"], cur["wave"]))
    print(renderer(headers, table_rows))


# ------------------------------------------------------------------- main
def parse_args(argv):
    parser = argparse.ArgumentParser(
        prog="claude-cost.py",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_append = sub.add_parser("append", help="add one row to the ledger")
    p_append.add_argument("--ledger", required=True, help="TSV ledger path (created if absent)")
    p_append.add_argument("--wave", required=True, help="wave label; must be unique in the ledger")
    p_append.add_argument("--cost", required=True, type=float, help="total cost for the wave")
    p_append.add_argument("--turns", required=True, type=int, help="total agent turns for the wave")
    p_append.add_argument("--date", default=None, help="ISO-8601 date/timestamp (default: now, UTC)")
    p_append.add_argument("--model", default=None, help="free-text model mix, e.g. 'sonnet-5:80,opus-5:20'")
    p_append.add_argument("--notes", default=None, help="free-text note for this row")
    p_append.add_argument("--dry-run", action="store_true", dest="dry_run",
                           help="print the row that would be appended without writing it")
    p_append.set_defaults(func=cmd_append)

    p_list = sub.add_parser("list", help="print the ledger's rows")
    p_list.add_argument("--ledger", required=True, help="TSV ledger path")
    p_list.add_argument("--format", choices=sorted(RENDERERS.keys()), default="table")
    p_list.add_argument("--limit", type=int, default=None, help="show only the last N rows")
    p_list.set_defaults(func=cmd_list)

    p_compare = sub.add_parser("compare", help="delta table between two adjacent rows")
    p_compare.add_argument("--ledger", required=True, help="TSV ledger path")
    p_compare.add_argument("--wave", default=None, help="'current' row (default: the ledger's last row)")
    p_compare.add_argument("--format", choices=sorted(RENDERERS.keys()), default="table")
    p_compare.set_defaults(func=cmd_compare)

    return parser.parse_args(argv)


def main(argv):
    try:
        args = parse_args(argv)
    except SystemExit as exc:
        return 2 if exc.code not in (0, None) else 0

    try:
        args.func(args)
    except ValidationError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001 - deliberate catch-all boundary
        print("unexpected error: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
