# Settled session: 2026-09-19 grilling on widgetctl verbosity

## Decision: MINE-001 — Add a --verbose flag to widgetctl

**Problem**

widgetctl runs silently even when something goes wrong partway through a
batch job, so a failed run and a slow-but-successful one look identical from
the terminal until the exit code appears.

**Solution**

Add a `--verbose` flag to `widgetctl` that prints one line per batch item as
it starts and finishes, off by default so normal output stays quiet.

**Rationale**

- Choice: A single `--verbose` boolean flag, off by default.
  Rejected:
  - A `--log-level` enum: more flexibility than anyone asked for, when the only two states anyone described wanting were "quiet" and "narrated".
  - Verbose-by-default: breaks every existing script that scrapes stdout.

**Out of scope**

Structured (JSON) log output, and a `--quiet` flag to suppress the small
amount of output widgetctl already prints by default.

**Executor:** agent
**Tags:** widgetctl, cli
**Blocked by:** none
**Touches:** widgetctl/cli.py
**Appends:** none

**Verify**

```
python3 -c "import widgetctl.cli as c; assert '--verbose' in c.build_parser().format_help()"
```

**Verify fails today**

`widgetctl/cli.py`'s argument parser has no `--verbose` flag today, so the
assertion raises `AssertionError`.

**Created:** 2026-09-19

## Decision: MINE-002 — Document --verbose in widgetctl's README

**Problem**

Once `--verbose` exists, `widgetctl/README.md`'s flag table is out of date
and a new reader has no way to discover the flag short of reading the
source.

**Solution**

Add a row for `--verbose` to the flag table in `widgetctl/README.md`,
describing the per-item start/finish lines it prints.

**Rationale**

- Choice: One table row, matching the existing table's format.
  Rejected: none

**Out of scope**

Any other documentation gap in the README; this covers only the new flag.

**Executor:** agent
**Tags:** widgetctl, docs
**Blocked by:** MINE-001
**Touches:** widgetctl/README.md
**Appends:** none

**Verify**

```
grep -c -- '--verbose' widgetctl/README.md
```

**Verify fails today**

`widgetctl/README.md`'s flag table has no `--verbose` row today, so the grep
exits 1.

**Created:** 2026-09-19
