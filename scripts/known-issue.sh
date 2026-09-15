#!/bin/bash
#
# Manage docs/known-issues/ — one markdown file per finding, with
# docs/known-issues.md as a GENERATED index rendered from their frontmatter.
#
# Why: a docs/known-issues.md that is a single hand-edited file, holding both
# the prose for every finding and a hand-maintained index table linking into
# it, has two known failure modes. First: two agents (or two people) editing
# different entries collide on the same file. Second, worse: the index drifts
# from the bodies it summarises — a heading gets edited and its index row
# does not, or an entry is added and the index row for it never gets written,
# so it becomes invisible in the table with no error and nothing to notice it
# by. One project that ran this way for a while found its source had a dozen
# more entries than its index had rows for it — silently. That is the
# strongest argument for a GENERATED index over a hand-maintained one:
# once the table is derived from the entries themselves rather than kept in
# sync by hand, an entry cannot go missing from it — `reindex` either lists
# every entry file or it doesn't run. This script is the fix: one file per
# entry under docs/known-issues/, and an index that is always regenerated
# from their frontmatter rather than hand-kept in sync.
#
# This is a REPO-DOCS script, not a lab-operations one: it never contacts a
# host, reads no 1Password item, and touches nothing but files under
# docs/known-issues/ and docs/known-issues.md. There is no live-host hazard
# here to guard against.
#
# Subcommands:
#   migrate                    ONE-SHOT. Parse the current, hand-written
#                               docs/known-issues.md, split it into one file
#                               per entry under docs/known-issues/, and
#                               regenerate docs/known-issues.md as the
#                               index. Heading detection is fence-aware for
#                               BOTH ``` and ~~~ delimiters, closed only by a
#                               run of the same character at least as long
#                               as the one that opened it (CommonMark's
#                               rule) — a '## ' line inside either kind of
#                               fenced code block is never mistaken for a
#                               real heading. Every fence delimiter also
#                               requires CommonMark's 0-3-column indent bound
#                               — a 4+-space-indented run of backticks/tildes
#                               is an INDENTED CODE BLOCK, inert literal text,
#                               never a delimiter (caught during review: this bound was
#                               missing from every scanner at once, and an
#                               indented, never-closed ``` swallowed every
#                               heading after it into one entry, silently).
#                               That detection is cross-checked against TWO
#                               further, deliberately differently-shaped
#                               implementations (regex spans over the whole
#                               text; a single explicit stack walked with its
#                               own regex) before migrate trusts any of them,
#                               so a defect specific to one implementation's
#                               shape — or reintroduced into all of them the
#                               same way — can't hide by being reused as its
#                               own verification.
#
#                               Stages every entry to a temp directory first
#                               and verifies ENTIRELY FROM DISK before going
#                               live: a fresh re-read of the source file
#                               (never the in-memory data used to decide what
#                               to write) must agree with a fresh re-read of
#                               the staged files on entry count, on every
#                               heading being recoverable byte-for-byte as
#                               '## '+heading_raw from exactly one file (and
#                               no staged file carrying a heading neither
#                               scanner recognises — the phantom-entry case),
#                               on an ordered line-for-line reconstruction of
#                               the whole document, and on every index note
#                               surviving. Any failure leaves the real
#                               docs/known-issues/ and docs/known-issues.md
#                               untouched.
#
#                               Refuses to run a second time unless
#                               docs/known-issues/ is empty or --force is
#                               given. --force is narrower than it sounds:
#                               --source and --index-file are the SAME path
#                               (docs/known-issues.md), so a successful
#                               migrate overwrites the only thing a later
#                               migrate would read — running migrate twice
#                               back to back, with nothing else changed,
#                               fails before --force's checks even run
#                               (there is no hand-written content left to
#                               parse, which is a different and more
#                               fundamental problem than "an entry was
#                               edited," and gets its own specific error
#                               naming the fix: restore the pre-migration
#                               content first). --force's checksum-manifest
#                               protection only matters, and only engages,
#                               when the source HAS been restored to real
#                               heading content — e.g. a stale `git checkout`
#                               of the old hand-written doc landing on top of
#                               the generated index while entries already
#                               exist. In that situation it refuses unless
#                               every existing entry is simultaneously: (a)
#                               byte-identical, per a recorded sha256, to
#                               what this tool itself last wrote for that
#                               slug — catches a hand edit; (b) present in
#                               the fresh parse of the restored source —
#                               catches an entry (e.g. from `add`) this run
#                               would silently drop; and (c) not a manifest
#                               entry with NO file on disk — catches a
#                               deliberately deleted entry being silently
#                               resurrected, which (a) and (b) alone cannot
#                               see, since both only ever iterate files that
#                               currently exist. See "Frontmatter fields"
#                               below for the manifest itself.
#
#                               A heading with no severity anywhere — not in
#                               the heading, not in a matched index row — is
#                               never guessed at. Of 6 such headings found
#                               against the real doc, 5 were genuine entries
#                               the index table simply never listed and 1
#                               was not; "missing from the index" cannot
#                               tell those apart, so migrate refuses and
#                               prints every one with its line number unless
#                               --accept-severity-defaults is given, which
#                               defaults them to LOW and names them for
#                               follow-up. Silently defaulting is how a HIGH
#                               finding becomes a LOW one and nobody
#                               notices — the same class of failure as the
#                               index/body drift this restructure exists to
#                               kill.
#   reindex                    Regenerate docs/known-issues.md from the
#                               frontmatter of every file under
#                               docs/known-issues/. Idempotent — running it
#                               twice with no entry changes produces a
#                               byte-identical file.
#   add                        Create a new entry file and reindex.
#   resolve <slug>              Mark an entry resolved (status + date) and
#                               reindex.
#   severity <slug> <SEV>       Change an entry's severity and reindex.
#   lint                        Verify every entry file parses, has the
#                               required frontmatter, has a unique slug, and
#                               that docs/known-issues.md is exactly what
#                               `reindex` would produce right now. Non-zero
#                               exit on any failure — this is the guard that
#                               keeps the index from drifting again.
#
# Every subcommand answers -h/--help on its own; run with no arguments for
# the same text this comment carries.
#
# Frontmatter fields (docs/known-issues/<slug>.md):
#   title        entry title, without the trailing severity/status suffix
#   heading_raw  the ORIGINAL '## ' heading line, verbatim, minus the '## '
#                itself. This is the lossless backstop: whatever the
#                severity/status/qualifiers parsing failed to anticipate is
#                still greppable and byte-recoverable here. migrate asserts
#                every heading in the source reconstructs from some entry's
#                heading_raw before it writes anything.
#   severity     exactly one of HIGH | MEDIUM | LOW | COSMETIC (CRITICAL in
#                the original doc folds into HIGH — there is no fifth bucket)
#   status       open | resolved
#   resolved     YYYY-MM-DD — present only when status is resolved
#   qualifiers   [ "...", ... ] — best-effort structured extraction of
#                whatever the heading suffix said beyond severity/status/date
#                ("(was MEDIUM)", "(REPEAT)", "owner decision"). May be
#                empty; heading_raw is the guarantee, this is the convenience.
#   note         optional one-line note (was: index-row text after the em-dash)
#   tickets      [ "PREFIX-nnn", ... ] — may be empty
#   slug         the file's own slug, for round-trip safety
#
# docs/known-issues/_manifest.json is NOT an entry (load_all_entries ignores
# anything not ending .md). It records the sha256 this tool itself wrote for
# every slug, updated by migrate, add, resolve, and severity alike, and is
# what --force checks against — never hand-edit it.
#
set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

need python3 git

# ROOT is the repo this is managing docs/ for — NOT this script's own
# location. As a plugin script it is invoked from ${CLAUDE_PLUGIN_ROOT},
# somewhere outside the target repo entirely, so the target is always the
# git toplevel of wherever the caller's cwd is, never a path relative to $0.
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
ENTRIES_DIR="$ROOT/docs/known-issues"
INDEX_FILE="$ROOT/docs/known-issues.md"
SEVERITIES="HIGH MEDIUM LOW COSMETIC"

valid_severity() {
    local want="$1" s
    for s in $SEVERITIES; do [ "$s" = "$want" ] && return 0; done
    return 1
}

valid_date() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

# Any tracker's key shape: a prefix (letters, optionally digits/underscore),
# a dash, then digits — "PROJ-42", "PROJ-007", "ENG_2-9" all match. Not tied
# to one tracker's convention.
valid_ticket() {
    case "$1" in
        [A-Za-z]*-[0-9]*) return 0 ;;
        *) return 1 ;;
    esac
}

valid_slug_shape() {
    # make_slug() in the engine below only ever produces lowercase alnum
    # segments joined by single hyphens, no leading/trailing/doubled hyphen
    # — anything else is not a slug this tool could have generated.
    # Separated from the existence check below so the two can be reported
    # with DIFFERENT messages: "not a slug" and "no such entry" are not the
    # same failure, and conflating them ("no such entry: ../../elsewhere
    # (no $ENTRIES_DIR/../../elsewhere.md)") is actively misleading for a
    # shape-rejected value — it reads as "just add the entry", when the
    # real reason is that the value was refused before existence was even
    # checked.
    local s="$1"
    [ -n "$s" ] || return 1
    case "$s" in
        *[!a-z0-9-]*) return 1 ;;
        -*|*-|*--*) return 1 ;;
    esac
    return 0
}

valid_slug() {
    # Shape first, existence second: an existence-only check (the original
    # form of this function) passes a slug like '../../elsewhere/x' through
    # to the Python engine unexamined if some file at that resolved path
    # happens to exist and is one of this tool's own frontmatter files —
    # resolve/severity would then rewrite a file outside $ENTRIES_DIR
    # instead of refusing on an obviously malformed slug.
    local s="$1"
    valid_slug_shape "$s" || return 1
    [ -f "$ENTRIES_DIR/$s.md" ]
}

# --------------------------------------------------------------- the engine
#
# Parsing hand-written markdown headings (mixed-case severity words, trailing
# qualifiers, resolved dates buried in parens, an index table that can drift
# from the bodies it links to) is not a bash 3.2 job. This writes the actual
# engine to a kit.sh tmpfile once at startup — cleaned up at exit like every
# other kit.sh tmpfile — and every subcommand below shells out to it.

ENGINE=$(tmpfile) || die "could not create the engine tempfile"
cat > "$ENGINE" <<'PYEOF'
#!/usr/bin/env python3
import argparse
import difflib
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile

# Sidecar manifest recording the sha256 this tool itself wrote for each
# slug, last write wins. Not a *.md file, so load_all_entries never sees it
# as an entry. Committed to git like everything else under docs/known-issues/
# — that makes "has this entry been hand-touched since the tool last wrote
# it" auditable via git diff too, not just at --force time.
MANIFEST_NAME = "_manifest.json"


def manifest_path(entries_dir):
    return os.path.join(entries_dir, MANIFEST_NAME)


def load_manifest(entries_dir):
    p = manifest_path(entries_dir)
    if not os.path.exists(p):
        return None
    with open(p) as fh:
        return json.load(fh)


def save_manifest(entries_dir, manifest):
    with open(manifest_path(entries_dir), "w") as fh:
        json.dump(manifest, fh, indent=2, sort_keys=True)
        fh.write("\n")


def file_hash(path):
    with open(path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest()


def record_written(entries_dir, slug, path):
    """Update (or create) the manifest entry for one just-written file.
    Used by add/resolve/severity so their own writes never look like a
    stray hand edit on the next --force."""
    manifest = load_manifest(entries_dir) or {}
    manifest[slug] = file_hash(path)
    save_manifest(entries_dir, manifest)

SEV_ORDER = ["HIGH", "MEDIUM", "LOW", "COSMETIC"]
SEV_WORDS = ["CRITICAL", "HIGH", "MEDIUM", "LOW", "COSMETIC"]
SEV_NORM = {"CRITICAL": "HIGH", "HIGH": "HIGH", "MEDIUM": "MEDIUM",
            "LOW": "LOW", "COSMETIC": "COSMETIC"}
DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
TICKET_RE = re.compile(r"\b[A-Za-z][A-Za-z0-9_]*-\d+\b")
STRIKE_RE = re.compile(r"~~\s*([A-Za-z]+)\s*~~")

# A fuzzy title match below this ratio is refused outright (the index row is
# reported unmatched, which fails migration) rather than silently attached to
# the nearest-sounding entry. Calibrated against the real doc's five genuine
# title-edit cases (ratios 0.72-1.00) and a fabricated "Totally Unmatchable
# Nonsense Zzzqx" row a reviewer used to probe this (ratio 0.45-0.47) — 0.6
# sits cleanly between the two and rejects the latter.
FUZZY_ACCEPT = 0.6
# Above this, an accepted fuzzy match is almost certainly just an anchor gone
# stale (title unchanged or trivially reformatted); below it (but still
# accepted), the title itself was substantively edited. Purely a labeling
# split for the report — both are still accepted matches.
FUZZY_CONFIDENT = 0.85

GENERATED_HEADER = """# Known issues

**GENERATED — do not hand-edit.** This file is produced by
`known-issue.sh reindex` from the frontmatter of every file in
`docs/known-issues/`. Edit an entry there (or via `known-issue.sh add`,
`resolve`, or `severity`), then run `reindex` — or just run any of those
subcommands, which reindex for you. `known-issue.sh lint` fails if this file
ever drifts from what `reindex` would produce.

"""

TRAILING_NOTE = (
    "Severity is about blast radius if the thing goes wrong, not effort to "
    "fix. Anything resolved is rewritten in place with what was verified, "
    "rather than deleted — the history is often the useful part.\n"
)


# --------------------------------------------------------------- fence-aware line scan
#
# A line starting with '## ' inside a fenced code block is not a heading —
# A review reproduced a bogus entry and a truncated real one by planting
# '## this looks like a heading but is code' inside a ``` fence, and a
# second review reproduced the identical failure with a ~~~ fence, which the
# first fix did not recognise at all. CommonMark allows EITHER backtick or
# tilde fences, closed only by a run of the SAME character at least as long
# as the one that opened it — a fence of one kind is not closed by a marker
# of the other, and a short run inside a longer-opened fence is just content.
#
# Every heading-boundary decision the WRITE path makes goes through
# find_heading_indices. verify_migration_on_disk deliberately does NOT reuse
# it for its own ground truth — see find_heading_indices_independent below —
# because a defect in this one shared function would otherwise be invisible
# to a verification step that claims to catch exactly this class of bug.

def _leading_indent(line):
    """Column width of a line's leading whitespace, tabs expanded to the
    next multiple of 4 (CommonMark's tab-stop rule). Used only to decide
    whether a run of backticks/tildes is a fence delimiter at all — a
    fence requires 0-3 columns of indent; 4+ is CommonMark's INDENTED CODE
    BLOCK, which is inert literal text, not a delimiter, and must not
    open or close anything."""
    n = 0
    for c in line:
        if c == " ":
            n += 1
        elif c == "\t":
            n += 4 - (n % 4)
        else:
            break
    return n


def _fence_marker(line):
    """(char, run_length) if `line` is a CommonMark fence delimiter, else
    (None, 0). Only the leading run counts — CommonMark ignores anything
    after it on the opening line (e.g. an info string: '```python').

    A review once reproduced a bogus single-entry migration from
    a 4-space-INDENTED '```' with no closing fence anywhere in the
    document: the previous version of this function received an
    already-`.strip()`-ed line, so it could not see that the backticks
    were indented, treated it as a real unclosed fence opener, and every
    heading after it was swallowed as "inside a fence" through EOF. A
    fence delimiter is column-sensitive; stripping the line before
    looking at it throws away the one fact that decides whether it is a
    delimiter or plain text."""
    indent = _leading_indent(line)
    if indent > 3:
        return None, 0
    content = line.lstrip(" \t")
    for ch in ("`", "~"):
        if content.startswith(ch * 3):
            n = 0
            while n < len(content) and content[n] == ch:
                n += 1
            return ch, n
    return None, 0


def fence_state_per_line(lines):
    """states[i] is True if line i's own '## ' prefix (if any) must NOT count
    as a heading because it sits inside an open fence (or is itself a fence
    delimiter line, which can't start with '## ' anyway)."""
    states = []
    open_char = None
    open_len = 0
    for l in lines:
        ch, n = _fence_marker(l)
        if ch is not None:
            if open_char is None:
                open_char, open_len = ch, n
                states.append(True)
                continue
            if ch == open_char and n >= open_len:
                open_char, open_len = None, 0
                states.append(True)
                continue
            # A marker of the other character, or a shorter run of the same
            # one, while already inside a fence: that's fence CONTENT (e.g.
            # a ``` example embedded inside a ~~~-fenced block), not a
            # delimiter.
            states.append(True)
            continue
        states.append(open_char is not None)
    return states


def find_heading_indices(lines):
    states = fence_state_per_line(lines)
    return [i for i, l in enumerate(lines)
            if l.startswith("## ") and not states[i]]


def find_heading_indices_independent(lines):
    """A second, DELIBERATELY differently-shaped implementation of the same
    rule, used only by verify_migration_on_disk to cross-check
    find_heading_indices against something that does not share its
    traversal, its state variables, or even its regex. find_heading_indices
    walks every line updating two scalars; this one instead locates every
    fence-marker LINE with a single regex pass over the whole joined text,
    resolves opens/closes only among those matches, materialises the
    resulting fenced LINE RANGES, and only then filters headings — a
    structurally unrelated path to the same answer. If the two ever
    disagree, verify_migration_on_disk treats that as a hard failure rather
    than trusting either, on the theory that a bug shaped like "only
    recognises one fence delimiter" is unlikely to be written identically
    twice by two different-shaped implementations.
    """
    text = "\n".join(lines)
    # 0-3 leading spaces only — CommonMark's own bound on a fence delimiter.
    # A leading tab always expands to a 4-column tab stop or more (see
    # _leading_indent), so a tab-indented run is never a fence either;
    # excluding \t here rather than trying to bound it keeps that true
    # without duplicating the tab-expansion arithmetic in a second place.
    marker_re = re.compile(r"^[ ]{0,3}(`{3,}|~{3,})[^\n]*$", re.MULTILINE)

    line_starts = [0]
    for l in lines:
        line_starts.append(line_starts[-1] + len(l) + 1)

    def line_of(offset):
        lo, hi = 0, len(lines) - 1
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if line_starts[mid] <= offset:
                lo = mid
            else:
                hi = mid - 1
        return lo

    fenced_spans = []
    open_line = None
    open_marker = None
    for m in marker_re.finditer(text):
        idx = line_of(m.start())
        marker = m.group(1)
        ch, n = marker[0], len(marker)
        if open_line is None:
            open_line, open_marker = idx, (ch, n)
        elif ch == open_marker[0] and n >= open_marker[1]:
            fenced_spans.append((open_line, idx))
            open_line, open_marker = None, None
        # else: a marker of the other kind, or too short, while a fence is
        # already open — that match is fence content, not a new delimiter.
    if open_line is not None:
        fenced_spans.append((open_line, len(lines) - 1))

    fenced = [False] * len(lines)
    for start, end in fenced_spans:
        for i in range(start, end + 1):
            fenced[i] = True

    return [i for i, l in enumerate(lines) if l.startswith("## ") and not fenced[i]]


_STACK_FENCE_RE = re.compile(r"^( {0,3})(`{3,}|~{3,})")


def find_heading_indices_stack(lines):
    """A THIRD oracle, used only by verify_migration_on_disk alongside the
    two above. find_heading_indices and find_heading_indices_independent
    differ in traversal shape (per-line scalar toggle vs. whole-text regex
    with span pairing) but, at one point shared the exact same
    underlying rule bug: neither bounded a fence delimiter's indent, so a
    4-space-indented '```' (CommonMark: an INDENTED CODE BLOCK, inert,
    never a delimiter) was accepted as a real unclosed fence opener by
    BOTH — and because both were wrong identically, they agreed with each
    other and no disagreement-based check caught it. Fixing the shared
    bug in both is necessary but does not by itself prevent that from
    happening again the same way; this function is deliberately a THIRD,
    differently-shaped implementation (a single explicit LIFO stack of
    open fences, walked with its own regex, never sharing code with
    either of the above) so that if the indent bound is ever dropped from
    both of the others at once, this one still disagrees with them rather
    than completing a false 3-way consensus.
    """
    stack = []
    out = []
    for i, l in enumerate(lines):
        m = _STACK_FENCE_RE.match(l)
        if m:
            ch, n = m.group(2)[0], len(m.group(2))
            if stack and stack[-1][0] == ch and n >= stack[-1][1]:
                stack.pop()
            elif not stack:
                stack.append((ch, n))
            # else: a marker of the other kind, or a shorter run of the
            # same one, while a fence is already open — fence CONTENT, not
            # a new delimiter (mirrors the other two scanners' rule).
            continue
        if not stack and l.startswith("## "):
            out.append(i)
    return out


# --------------------------------------------------------------- unclosed fence
#
# A later review reproduced a case none of the three
# scanners above can ever catch by disagreeing: a fence opened with 3
# leading spaces, closed by a line with 4. All three scanners apply the
# IDENTICAL CommonMark rule (indent 0-3 to be a delimiter at all) to that
# closing line, so all three agree it is not a valid closer — and CommonMark's
# own answer for "a fence that never gets a valid closer" is to swallow
# everything after it, to EOF, as inert literal code. That is unanimous,
# correct-by-the-shared-policy agreement producing a wrong outcome for this
# tool's purpose: three independent implementations of one rule are not three
# independent opinions, and a defect (or, as here, a plain typo in the
# source markdown) that lives in what the rule ACCEPTS rather than in how any
# one scanner is coded cannot be caught by comparing scanners that all encode
# the same rule. This is a structurally different, additional invariant, not
# a fourth vote alongside the other three: it does not ask "do the scanners
# agree" but "did every fence this rule recognises as OPENED also get a
# recognised CLOSE before EOF" — a document can satisfy that and still have
# scanners disagree over something else entirely (in which case the 3-way
# cross-check above is what fires), or fail this while all three scanners
# agree perfectly with each other about the resulting (wrong) heading count.

def find_unclosed_fence(lines):
    """1-based line number of the outermost fence opener with no valid
    closer before EOF, or None if every opened fence closes. Deliberately
    policy over disagreement: rather than trusting any scanner's fence-state
    output (all three encode the same acceptance rule and would happily
    report "no heading found here" for every line the unclosed fence
    swallows), this refuses outright whenever an opened fence never
    receives a same-character, run->=length, 0-3-indent closer — on the
    working assumption that for a curated doc like docs/known-issues.md, an
    unclosed-to-EOF fence is essentially always a typo (a closing line
    indented one space too many, a closer using the wrong character, a
    forgotten closer entirely) rather than an intentional multi-heading
    code block, and silently absorbing every heading after it is a worse
    failure than refusing and asking a human to fix the fence."""
    open_line = None
    open_char = None
    open_len = 0
    for i, l in enumerate(lines):
        ch, n = _fence_marker(l)
        if ch is None:
            continue
        if open_char is None:
            open_char, open_len, open_line = ch, n, i
        elif ch == open_char and n >= open_len:
            open_char, open_len, open_line = None, 0, None
        # else: a marker of the other character, or a shorter run of the
        # same one, while already inside a fence — fence CONTENT, not a
        # delimiter (the same rule every scanner above applies).
    return (open_line + 1) if open_line is not None else None


# --------------------------------------------------------------- slugs

def gh_slug(heading):
    h = heading.strip().lower()
    kept = [c for c in h if c.isalnum() or c in "-_ "]
    return "".join(kept).replace(" ", "-")


SLUG_RE = re.compile(r'^[a-z0-9]+(-[a-z0-9]+)*$')


def validate_slug_arg(slug):
    """Refuse anything make_slug() could not have produced (no '/', no
    '..', no leading/trailing/doubled hyphen) BEFORE it is joined into a
    path — the bash wrapper's valid_slug() is meant to gate this already,
    but this engine is the one thing that actually opens the file, and
    should not trust an argument it was invoked with directly (e.g. a
    future caller that shells out to this engine without going through the
    bash wrapper) to have already been checked."""
    if not SLUG_RE.match(slug):
        print("Error: %r is not a valid slug (want lowercase "
              "letters/digits/hyphens, no leading/trailing/doubled hyphen)"
              % slug, file=sys.stderr)
        return False
    return True


def make_slug(title, existing):
    s = title.strip().lower()
    s = re.sub(r"`", "", s)
    s = re.sub(r"[^a-z0-9]+", "-", s)
    s = s.strip("-")
    s = re.sub(r"-+", "-", s)
    if not s:
        s = "entry"
    base = s
    n = 2
    while s in existing:
        s = "%s-%d" % (base, n)
        n += 1
    existing.add(s)
    return s


# --------------------------------------------------------------- heading-suffix parse

def split_top_level(text):
    """Split on every top-level ' — ' (not inside parens). Returns a list of
    >=1 segments; a heading with no top-level ' — ' returns [heading] whole."""
    parts = []
    depth = 0
    start = 0
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and text[i:i + 3] == " — ":
            parts.append(text[start:i])
            i += 3
            start = i
            continue
        i += 1
    parts.append(text[start:])
    return parts


def cleanup_qualifier(text):
    s = re.sub(r"\s+", " ", text).strip()
    s = re.sub(r"\(\s*\)", "", s).strip()
    s = s.strip(" ,;-")
    s = re.sub(r"\s+", " ", s).strip()
    if not s or re.fullmatch(r"[\s,;\-()]*", s):
        return None
    return s


def process_heading(heading):
    """Returns (title, severity, status, resolved, qualifiers). Every scrap
    of the heading suffix that isn't consumed as a recognised severity/status/
    date token is kept as a qualifier string, one per top-level segment — so
    '(was MEDIUM)', '(REPEAT)', and '(was MEDIUM, UNVERIFIED cause)' all
    survive structurally, not just inside heading_raw's verbatim backstop."""
    parts = split_top_level(heading)
    title = parts[0].strip()
    if len(parts) == 1:
        return title, None, "open", None, []

    severity = None
    status = "open"
    resolved = None
    qualifiers = []

    for seg in parts[1:]:
        work = seg
        seg_had_signal = False

        # Leftmost severity word wins — position, not a fixed priority list,
        # so 'HIGH (was MEDIUM)' keeps 'MEDIUM' as part of the qualifier
        # rather than a second pass mistaking it for the current severity.
        sev_re = re.compile(
            r"\b(" + "|".join(SEV_WORDS) + r")\b", re.IGNORECASE)
        m = sev_re.search(work)
        if m:
            seg_had_signal = True
            if severity is None:
                severity = SEV_NORM[m.group(1).upper()]
            work = work[:m.start()] + work[m.end():]

        m = re.search(r"\bRESOLVED\b", work, re.IGNORECASE)
        if m:
            seg_had_signal = True
            status = "resolved"
            work = work[:m.start()] + work[m.end():]
            dm = DATE_RE.search(work)
            if dm:
                resolved = dm.group(1)
                work = work[:dm.start()] + work[dm.end():]
        else:
            m = re.search(r"\bOPEN\b", work, re.IGNORECASE)
            if m:
                seg_had_signal = True
                work = work[:m.start()] + work[m.end():]
                dm = DATE_RE.search(work)
                if dm:
                    work = work[:dm.start()] + work[dm.end():]
            else:
                m = re.search(r"\bowner decision\b", work, re.IGNORECASE)
                if m:
                    seg_had_signal = True
                    status = "resolved"
                    dm = DATE_RE.search(work)
                    if dm:
                        resolved = dm.group(1)
                        work = work[:dm.start()] + work[dm.end():]
                    # 'owner decision' itself is left in place — it is
                    # meaningfully different from a fixed bug and worth
                    # keeping as a qualifier, not just consumed silently.

        cleaned = cleanup_qualifier(work)
        if cleaned:
            qualifiers.append(cleaned)
        elif not seg_had_signal:
            # A whole segment with no recognised signal at all — keep it
            # verbatim rather than silently dropping it (heading_raw is the
            # ultimate backstop regardless, but this keeps qualifiers honest
            # for grammar this parser did not anticipate).
            cleaned = cleanup_qualifier(seg)
            if cleaned:
                qualifiers.append(cleaned)

    return title, severity, status, resolved, qualifiers


# --------------------------------------------------------------- source parse

def parse_sections(lines):
    idxs = find_heading_indices(lines)
    sections = []
    for n, idx in enumerate(idxs):
        heading = lines[idx][3:]
        end = idxs[n + 1] if n + 1 < len(idxs) else len(lines)
        body = lines[idx + 1:end]
        while body and body[0].strip() == "":
            body.pop(0)
        while body and body[-1].strip() == "":
            body.pop()
        title, sev, status, resolved, qualifiers = process_heading(heading)
        sections.append({
            "line": idx + 1,
            "heading": heading,
            "heading_raw": heading,
            "title": title,
            "body": body,
            "severity": sev,
            "status": status,
            "resolved": resolved,
            "qualifiers": qualifiers,
            "note": None,
        })
    return sections


def parse_index(lines):
    rows = []
    in_table = False
    row_re = re.compile(
        r"^\|\s*(?P<sev>[^|]+?)\s*\|\s*\[(?P<title>[^\]]+)\]\(#(?P<anchor>[^)]+)\)(?P<rest>.*)\|\s*$"
    )
    for l in lines:
        if l.startswith("| Severity"):
            in_table = True
            continue
        if not in_table:
            continue
        if not l.startswith("|"):
            break
        if re.match(r"^\|\s*-+\s*\|", l):
            continue
        m = row_re.match(l)
        if not m:
            continue
        rest = m.group("rest").strip()
        note = None
        if rest.startswith("—"):
            note = rest[1:].strip()
        elif rest:
            note = rest.strip(" —")
        rows.append({
            "sev_raw": m.group("sev").strip(),
            "title": m.group("title").strip(),
            "anchor": m.group("anchor").strip(),
            "note": note or None,
        })
    return rows


def index_row_severity(row):
    m = STRIKE_RE.search(row["sev_raw"])
    word = m.group(1).upper() if m else row["sev_raw"].strip().upper()
    return SEV_NORM.get(word)


def match_index_to_sections(sections, index_rows):
    """Greedy 1:1: exact gh_slug(heading)==anchor first, then the best fuzzy
    title match among unclaimed sections — but only if its ratio clears
    FUZZY_ACCEPT. Below that, the row is left UNMATCHED (migration then
    fails loudly on it) rather than silently attached to a coin-flip
    candidate. Returns (unmatched_rows, title_warnings, status_warnings,
    ratio_report) — ratio_report lists every accepted fuzzy match with its
    score, split into confident vs needs-a-look, for the report.
    """
    slugs = [gh_slug(s["heading"]) for s in sections]
    used = set()
    title_warnings = []
    status_warnings = []
    ratio_report = []
    unmatched_rows = []

    for row in index_rows:
        match_idx = None
        exact = False
        for i, sl in enumerate(slugs):
            if sl == row["anchor"] and i not in used:
                match_idx = i
                exact = True
                break
        ratio = None
        if match_idx is None:
            best_ratio, best_i = -1.0, None
            norm_row = re.sub(r"`", "", row["title"]).lower()
            for i, s in enumerate(sections):
                if i in used:
                    continue
                norm_sec = re.sub(r"`", "", s["title"]).lower()
                r = difflib.SequenceMatcher(None, norm_row, norm_sec).ratio()
                if r > best_ratio:
                    best_ratio, best_i = r, i
            if best_ratio >= FUZZY_ACCEPT:
                match_idx = best_i
                ratio = best_ratio
        if match_idx is None:
            unmatched_rows.append(row)
            continue
        used.add(match_idx)
        sec = sections[match_idx]
        if not exact:
            confidence = "confident" if ratio >= FUZZY_CONFIDENT else "needs review"
            ratio_report.append(
                "%.2f (%s): index title %r (anchor #%s) -> entry %r at line %d"
                % (ratio, confidence, row["title"], row["anchor"],
                   sec["heading"], sec["line"])
            )
            if slugs[match_idx] != row["anchor"]:
                title_warnings.append(
                    "title/anchor mismatch: index title %r (anchor #%s) "
                    "matched to current heading %r at line %d (ratio %.2f) "
                    "— the title was edited after the anchor was set" % (
                        row["title"], row["anchor"], sec["heading"],
                        sec["line"], ratio)
                )
        sec["note"] = row["note"]
        if sec["severity"] is None:
            sev = index_row_severity(row)
            if sev:
                sec["severity"] = sev
        if "RESOLVED" in row["sev_raw"].upper() and sec["status"] != "resolved":
            status_warnings.append(
                "status disagreement for %r: the entry's own heading (line "
                "%d) does not say RESOLVED, but the index row marks it "
                "%r — kept 'open' from the heading (the heading/body prose "
                "read as still-active); verify by hand and use "
                "`known-issue.sh resolve <slug>` if it is actually fixed" % (
                    sec["title"], sec["line"], row["sev_raw"])
            )

    return unmatched_rows, title_warnings, status_warnings, ratio_report


def find_missing_severity(sections):
    """Sections with no severity from ANY source (heading, matched index
    row). Deliberately does NOT guess: an owner audit of the real doc found
    6 such headings, 5 of which are genuine entries the index table simply
    never listed and 1 of which is not — "missing from the index" cannot
    tell those apart, so there is no heuristic here to get wrong. The
    caller decides whether to refuse (default) or default them to LOW under
    --accept-severity-defaults, explicitly, once, out loud."""
    return [s for s in sections if s["severity"] is None]


def apply_severity_defaults(missing):
    """Only called once the caller has confirmed --accept-severity-defaults.
    Defaults every section in `missing` to LOW and returns one warning line
    per section, naming the fix-up command."""
    warnings = []
    for s in missing:
        s["severity"] = "LOW"
        warnings.append(
            "line %d: %r — no severity found anywhere (heading or a "
            "matched index row); defaulted to LOW because "
            "--accept-severity-defaults was given. Review with "
            "`known-issue.sh severity %s <SEV>`." % (
                s["line"], s["heading"], s["slug"])
        )
    return warnings


def extract_tickets(heading, body):
    text = heading + "\n" + "\n".join(body)
    return sorted(set(TICKET_RE.findall(text)))


# --------------------------------------------------------------- frontmatter

def esc(s):
    # Order matters: backslash first (so a real backslash in the input
    # isn't re-escaped by the later steps), then the quote, then a literal
    # newline — a title/note is stored as one physical `key: "value"` line
    # (FM_LINE_RE below is line-based, no re.DOTALL), so an unescaped
    # newline would split one frontmatter field across two lines and the
    # second half would fail to parse as a field at all on the very next
    # read. Every caller that puts free text here (cmd_add --title/--note,
    # cmd_resolve --note) can pass a string containing one.
    return (s.replace("\\", "\\\\")
             .replace('"', '\\"')
             .replace("\n", "\\n"))


def unesc(s):
    # Reverse of esc(), in reverse order: undo the last transform first.
    return (s.replace("\\n", "\n")
             .replace('\\"', '"')
             .replace("\\\\", "\\"))


def dump_list(items):
    return "[%s]" % ", ".join('"%s"' % esc(i) for i in items)


LIST_ITEM_RE = re.compile(r'"((?:[^"\\]|\\.)*)"')


def parse_list(val):
    inner = val.strip()
    if inner.startswith("[") and inner.endswith("]"):
        inner = inner[1:-1]
    return [unesc(m) for m in LIST_ITEM_RE.findall(inner)]


FRONTMATTER_FIELDS = ["title", "heading_raw", "severity", "status",
                       "resolved", "qualifiers", "note", "tickets", "slug"]


def dump_entry(meta, body_lines):
    out = ["---"]
    out.append('title: "%s"' % esc(meta["title"]))
    out.append('heading_raw: "%s"' % esc(meta["heading_raw"]))
    out.append("severity: %s" % meta["severity"])
    out.append("status: %s" % meta["status"])
    if meta["status"] == "resolved" and meta.get("resolved"):
        out.append("resolved: %s" % meta["resolved"])
    out.append("qualifiers: %s" % dump_list(meta.get("qualifiers") or []))
    if meta.get("note"):
        out.append('note: "%s"' % esc(meta["note"]))
    out.append("tickets: %s" % dump_list(meta.get("tickets") or []))
    out.append("slug: %s" % meta["slug"])
    out.append("---")
    text = "\n".join(out) + "\n"
    if body_lines:
        text += "\n" + "\n".join(body_lines) + "\n"
    return text


FM_LINE_RE = re.compile(r'^(?P<key>[a-z_]+):\s*(?P<val>.*)$')


def load_entry(path):
    with open(path) as fh:
        text = fh.read()
    if not text.startswith("---\n"):
        raise ValueError("%s: missing frontmatter opening ---" % path)
    end = text.find("\n---", 4)
    if end == -1:
        raise ValueError("%s: missing frontmatter closing ---" % path)
    fm_text = text[4:end]
    rest = text[end + 4:]
    if rest.startswith("\n"):
        rest = rest[1:]
    body_lines = rest.split("\n")
    while body_lines and body_lines[0] == "":
        body_lines.pop(0)
    while body_lines and body_lines[-1] == "":
        body_lines.pop()
    meta = {"tickets": [], "qualifiers": []}
    for line in fm_text.split("\n"):
        if not line.strip():
            continue
        m = FM_LINE_RE.match(line)
        if not m:
            raise ValueError("%s: unparsable frontmatter line: %r" % (path, line))
        key, val = m.group("key"), m.group("val")
        if key in ("title", "note", "heading_raw"):
            if val.startswith('"') and val.endswith('"') and len(val) >= 2:
                val = unesc(val[1:-1])
            meta[key] = val
        elif key in ("tickets", "qualifiers"):
            meta[key] = parse_list(val)
        else:
            meta[key] = val
    for req in ("title", "heading_raw", "severity", "status", "slug"):
        if req not in meta:
            raise ValueError("%s: missing required frontmatter field %r" % (path, req))
    if meta["severity"] not in SEV_ORDER:
        raise ValueError("%s: invalid severity %r" % (path, meta["severity"]))
    if meta["status"] not in ("open", "resolved"):
        raise ValueError("%s: invalid status %r" % (path, meta["status"]))
    return meta, body_lines


# --------------------------------------------------------------- index render

def md_pipe_escape(s):
    # A literal '|' inside a markdown table cell ends that cell early and
    # shifts every following cell in the row — not a rendering nicety, a
    # structural break. Neither title nor note used to go through this
    # before being interpolated into a "| %s | %s |" row, so a title like
    # "Foo | Bar" silently corrupted its own row and every row after it in
    # a real markdown viewer, while producing byte-identical output on every
    # call — which is exactly why `lint`'s own check (below), built by
    # calling this same function, could never have caught it either.
    #
    # A real embedded newline is the same class of problem one layer up: a
    # title round-trips through the frontmatter fine (esc()/unesc() handle
    # that), but load_entry() hands build_index the UNESCAPED string, real
    # newline restored — and a markdown table row must be exactly one
    # physical line, so that newline splits the row in two just as
    # effectively as an unescaped '|' shifts it sideways. Caught by
    # lint_index_row_shapes (below) during this fix's own selftest.
    return s.replace("|", "\\|").replace("\n", " ")


def build_index(entries):
    def sort_key(e):
        meta = e[0]
        sev_rank = SEV_ORDER.index(meta["severity"])
        status_rank = 0 if meta["status"] == "open" else 1
        return (sev_rank, status_rank, meta["title"].lower())

    rows = []
    for meta, relpath in sorted(entries, key=sort_key):
        sev_cell = meta["severity"] if meta["status"] == "open" else (
            "~~%s~~ RESOLVED" % meta["severity"])
        title_cell = md_pipe_escape(meta["title"])
        link = "[%s](%s)" % (title_cell, md_pipe_escape(relpath))
        if meta.get("note"):
            row = "| %s | %s — %s |" % (sev_cell, link, md_pipe_escape(meta["note"]))
        else:
            row = "| %s | %s |" % (sev_cell, link)
        rows.append(row)

    out = [GENERATED_HEADER.rstrip("\n")]
    out.append("")
    out.append("| Severity | Finding |")
    out.append("| --- | --- |")
    out.extend(rows)
    out.append("")
    out.append(TRAILING_NOTE.rstrip("\n"))
    return "\n".join(out) + "\n"


def load_all_entries(entries_dir):
    entries = []
    slugs_seen = {}
    for name in sorted(os.listdir(entries_dir)):
        if not name.endswith(".md"):
            continue
        path = os.path.join(entries_dir, name)
        meta, body = load_entry(path)
        expected_slug = name[:-3]
        if meta["slug"] != expected_slug:
            raise ValueError(
                "%s: slug field %r does not match filename" % (path, meta["slug"]))
        if expected_slug in slugs_seen:
            raise ValueError("duplicate slug %r (%s and %s)" % (
                expected_slug, slugs_seen[expected_slug], path))
        slugs_seen[expected_slug] = path
        entries.append((meta, body, "known-issues/%s.md" % expected_slug, path))
    return entries


def load_all_entries_safe(entries_dir):
    """Same as load_all_entries but never raises — callers that are not
    already inside a try/except (reindex/add/resolve/severity) get the
    tool's own 'Error: ...' presentation instead of a raw traceback."""
    try:
        return load_all_entries(entries_dir), None
    except ValueError as e:
        return None, str(e)


# --------------------------------------------------------------- independent
# post-write verification
#
# Deliberately reads everything FRESH from disk here — the original source
# file a second time, and every staged entry file — rather than reusing the
# in-memory `sections` list that decided what to write. A bug in the WRITE
# step (wrong body slice, a dropped line, an encoding mishap) changes what
# lands on disk without necessarily changing the in-memory objects; comparing
# disk-to-disk is what would catch that. It also means a heading wrongly
# recognised inside a fenced code block shows up as a genuine mismatch here
# (an extra heading_raw with no counterpart in an independently-rescanned,
# fence-aware read of the source) instead of validating itself, which is
# exactly the failure mode a review once reproduced against this tool.

def verify_migration_on_disk(source_path, staging_dir):
    failures = []

    with open(source_path) as fh:
        fresh_text = fh.read()
    fresh_lines = fresh_text.split("\n")

    # Defense in depth: cmd_migrate already refuses on an unclosed fence
    # before it ever parses a section, but this function's whole premise is
    # trusting nothing except a fresh re-read from disk — so re-run the same
    # check against that fresh re-read rather than assuming the earlier
    # pre-flight result still applies.
    unclosed_line = find_unclosed_fence(fresh_lines)
    if unclosed_line is not None:
        return [
            "unclosed fenced code block starting at line %d in a fresh "
            "re-read of %s — no closing delimiter was found before EOF; "
            "every heading after it would be silently swallowed. Refusing "
            "to trust any heading count derived from this file." % (
                unclosed_line, source_path)
        ]

    # Cross-check heading detection against a structurally independent
    # implementation before trusting either. A defect specific to one
    # implementation's shape — e.g. only recognising one fence delimiter —
    # would otherwise be invisible to a verification pass that reuses the
    # exact function the write path already trusted.
    fresh_idxs = find_heading_indices(fresh_lines)
    fresh_idxs_cross = find_heading_indices_independent(fresh_lines)
    fresh_idxs_stack = find_heading_indices_stack(fresh_lines)
    scanners = [
        ("find_heading_indices", fresh_idxs),
        ("find_heading_indices_independent", fresh_idxs_cross),
        ("find_heading_indices_stack", fresh_idxs_stack),
    ]
    if not (fresh_idxs == fresh_idxs_cross == fresh_idxs_stack):
        disagreement = []
        for i, (name_a, idxs_a) in enumerate(scanners):
            for name_b, idxs_b in scanners[i + 1:]:
                only_a = sorted(x + 1 for x in set(idxs_a) - set(idxs_b))
                only_b = sorted(x + 1 for x in set(idxs_b) - set(idxs_a))
                if only_a or only_b:
                    disagreement.append(
                        "%s claims a heading at 1-based line(s) %r that %s "
                        "does not; the reverse is true for line(s) %r" % (
                            name_a, only_a, name_b, only_b))
        return [
            "heading-detection cross-check disagreement among all three "
            "independent scanners — refusing to trust any of them. Fix the "
            "disagreement before migrating."
        ] + disagreement

    if not fresh_idxs:
        return ["no '## ' headings found outside fenced code in %s" % source_path]
    fresh_heading_lines = [fresh_lines[i] for i in fresh_idxs]

    staged_names = sorted(f for f in os.listdir(staging_dir) if f.endswith(".md"))
    staged = []
    for name in staged_names:
        try:
            meta, body = load_entry(os.path.join(staging_dir, name))
        except ValueError as e:
            failures.append("could not read back staged entry %s: %s" % (name, e))
            continue
        staged.append((meta, body))

    # CHECK A — count from two independent sources: a fresh, fence-aware
    # re-scan of the source, versus a directory listing of what actually
    # landed on disk.
    if len(fresh_idxs) != len(staged_names):
        failures.append(
            "count mismatch: %d headings in a fresh fence-aware re-scan of "
            "%s, but %d entry files on disk in %s" % (
                len(fresh_idxs), source_path, len(staged_names), staging_dir)
        )

    # CHECK B — every heading found by the fresh re-scan must be recoverable,
    # byte-for-byte, as '## ' + heading_raw from EXACTLY one staged file; and
    # no staged file may carry a heading_raw that the fresh re-scan does NOT
    # recognise as a real (non-fenced) heading — that second half is what
    # catches a phantom entry created from a false-positive heading.
    import collections
    ground_truth = collections.Counter(fresh_heading_lines)
    staged_headings = collections.Counter("## " + m["heading_raw"] for m, b in staged)
    missing = ground_truth - staged_headings
    phantom = staged_headings - ground_truth
    for line, n in missing.items():
        failures.append("heading not recoverable from any entry file (x%d): %r" % (n, line))
    for line, n in phantom.items():
        failures.append(
            "entry file carries a heading_raw that a fresh, fence-aware "
            "re-scan of the source does not recognise as a real heading "
            "(x%d): %r — likely a false-positive heading (e.g. inside a "
            "fenced code block)" % (n, line)
        )

    # CHECK D — ordered, byte-level reconstruction. Walk the fresh ground-
    # truth headings in original document order, pair each with the staged
    # entry carrying that exact heading_raw (one-to-one; a Counter-based
    # take so duplicate headings still pair up correctly), and rebuild
    # '## heading_raw' + body for each in that order. The resulting sequence
    # of NON-BLANK lines must equal, in order, the sequence of non-blank
    # lines in the original file from the first heading to EOF. This is
    # strictly stronger than a multiset diff — it also catches content
    # silently reordered or reattached between neighbouring entries, not
    # just content dropped outright.
    if not failures:
        by_heading_raw = {}
        for m, b in staged:
            by_heading_raw.setdefault(m["heading_raw"], []).append((m, b))
        reconstructed = []
        for i in fresh_idxs:
            h = fresh_lines[i][3:]
            bucket = by_heading_raw.get(h)
            if not bucket:
                failures.append("internal: no staged entry left for heading %r "
                                 "during reconstruction" % h)
                break
            m, b = bucket.pop(0)
            reconstructed.append("## " + m["heading_raw"])
            reconstructed.extend(b)
        if not failures:
            recon_nonblank = [l for l in reconstructed if l.strip() != ""]
            orig_nonblank = [l for l in fresh_lines[fresh_idxs[0]:] if l.strip() != ""]
            if recon_nonblank != orig_nonblank:
                sm = difflib.SequenceMatcher(None, orig_nonblank, recon_nonblank)
                for tag, i1, i2, j1, j2 in sm.get_opcodes():
                    if tag == "equal":
                        continue
                    failures.append(
                        "reconstruction mismatch (%s): original lines %r "
                        "vs migrated lines %r" % (
                            tag, orig_nonblank[i1:i2][:5], recon_nonblank[j1:j2][:5])
                    )
                    if len(failures) > 60:
                        break

    # CHECK E — index coverage, re-derived fresh (independent of whatever the
    # write step used to decide notes/severity).
    fresh_index_rows = parse_index(fresh_lines)
    for row in fresh_index_rows:
        if row.get("note") is None:
            continue
        if not any(m.get("note") == row["note"] for m, b in staged):
            failures.append("note lost for index row %r: %r" % (
                row["title"], row["note"]))

    return failures


# --------------------------------------------------------------- commands

def cmd_migrate(args):
    dest_exists = os.path.isdir(args.entries_dir) and os.listdir(args.entries_dir)
    if dest_exists and not args.force:
        print("Error: %s already exists and is not empty (use --force to "
              "overwrite)" % args.entries_dir, file=sys.stderr)
        return 1

    with open(args.source) as fh:
        src_text = fh.read()
    src_lines = src_text.split("\n")

    # Checked before any heading is parsed, not just before staging: an
    # unclosed-to-EOF fence changes what parse_sections itself sees as
    # headings (everything after the opener reads as fence content), so
    # this has to run on the same src_lines parse_sections is about to
    # walk, not merely on the later staged/re-read copy. See "unclosed
    # fence" section above for why this can't be a disagreement-based
    # check like the three-scanner cross-check.
    unclosed_line = find_unclosed_fence(src_lines)
    if unclosed_line is not None:
        print("Error: unclosed fenced code block starting at line %d in %s "
              "— no closing delimiter (same character, run length >= the "
              "opener's, indented 0-3 columns) was found before EOF. Every "
              "heading after this point would be silently swallowed into "
              "whichever entry precedes it. Fix the fence (a common cause: "
              "the closing line is indented one column more or less than "
              "required) before migrating." % (unclosed_line, args.source),
              file=sys.stderr)
        return 1

    sections = parse_sections(src_lines)
    if not sections:
        # FINDING 2: --source and --index-file are the SAME path, so a
        # successful migrate overwrites the only thing a later migrate would
        # read from. On the natural "run it again" sequence there is no
        # hand-written content left to re-split at all — the checksum
        # manifest below never even gets a chance to matter, because there
        # is nothing to compute a fresh entry set from. That is a different,
        # more fundamental problem than "an entry was hand-edited", so it
        # gets a different, specific message rather than a generic
        # "no headings" error that leaves the operator guessing why.
        if "GENERATED — do not hand-edit" in src_text:
            print("Error: %s is already the GENERATED index (produced by a "
                  "previous migrate or reindex) — there is no hand-written "
                  "content left to split. --force will not help here: it "
                  "protects entries from being clobbered, but it cannot "
                  "invent a source that no longer exists. If you meant to "
                  "redo the original one-shot split, restore the "
                  "pre-migration content of %s first (e.g. `git checkout "
                  "<commit-before-the-first-migrate> -- %s`), then re-run "
                  "migrate --force." % (args.source, args.source, args.source),
                  file=sys.stderr)
        else:
            print("Error: no '## ' headings found outside fenced code in %s" %
                  args.source, file=sys.stderr)
        return 1

    existing_slugs = set()
    for s in sections:
        s["slug"] = make_slug(s["title"], existing_slugs)
        s["tickets"] = extract_tickets(s["heading"], s["body"])

    if dest_exists and args.force:
        # BLOCKER 3: --force must not blindly clobber entries that were
        # hand-edited (or created/changed by add/resolve/severity) since the
        # last migrate. A body-text edit round-trips through load+dump just
        # fine — dump_entry only ever re-serialises whatever it was handed,
        # so "does this file survive its own parser" proves nothing about
        # whether its CONTENT changed since the tool last wrote it. What is
        # needed is a reference to what the tool itself last wrote, which is
        # the manifest: a sha256 per slug, recorded every time migrate,
        # add, resolve, or severity writes a file. No manifest at all means
        # this directory predates manifest-tracking or was hand-assembled —
        # refuse rather than guess.
        manifest = load_manifest(args.entries_dir)
        if manifest is None:
            print("Error: --force refused: no %s found under %s, so there is "
                  "no record of what this tool last wrote — cannot tell a "
                  "hand-edited entry from an untouched one. Remove the "
                  "directory yourself if you are certain it is safe to "
                  "replace, then re-run without needing --force." % (
                      MANIFEST_NAME, args.entries_dir), file=sys.stderr)
            return 1
        entries, err = load_all_entries_safe(args.entries_dir)
        if err is not None:
            print("Error: --force refused: %s could not be read back to "
                  "check for hand edits (%s) — inspect it by hand before "
                  "retrying" % (args.entries_dir, err), file=sys.stderr)
            return 1
        fresh_slugs = {s["slug"] for s in sections}
        dirty = []
        orphaned = []
        present_slugs = set()
        for meta, body, relpath, path in entries:
            present_slugs.add(meta["slug"])
            recorded = manifest.get(meta["slug"])
            current = file_hash(path)
            if recorded is None or recorded != current:
                dirty.append(path)
            elif meta["slug"] not in fresh_slugs:
                # Untouched since it was written, but this migrate run would
                # not recreate it — e.g. an entry made with `add` for
                # something outside the original doc. Replacing the
                # directory would silently delete it even though nothing
                # about it is "dirty".
                orphaned.append(path)
        # A manifest key with NO file on disk at all is a deliberately
        # deleted entry — the loop above only ever looks at files that
        # EXIST, so this is the one case it structurally cannot see on its
        # own. Left unchecked, --force silently resurrects it: rmtree wipes
        # what remains, the fresh migrate recreates every slug the source
        # still has (including the deleted one, if the source still mentions
        # it), and the deletion is gone with no error, no warning, nothing.
        deleted = sorted(
            os.path.join(args.entries_dir, slug + ".md")
            for slug in manifest
            if slug not in present_slugs
        )
        if deleted:
            print("Error: --force refused: %d slug(s) recorded in %s have no "
                  "file on disk under %s — deleted since this tool last "
                  "wrote them. Replacing the directory would silently bring "
                  "them back from the source. If the deletion was "
                  "intentional, remove the corresponding key(s) from %s by "
                  "hand first; if it was not, something else deleted these "
                  "files and needs investigating before --force is safe. "
                  "Affected slug(s):" % (
                      len(deleted), MANIFEST_NAME, args.entries_dir,
                      manifest_path(args.entries_dir)), file=sys.stderr)
            for p in deleted:
                print("  - " + p, file=sys.stderr)
            return 1
        if dirty:
            print("Error: --force refused: %d entry file(s) under %s do not "
                  "match the recorded checksum of what this tool last wrote "
                  "there — something touched them since (a hand edit, a "
                  "stale git checkout, a merge). Overwriting would silently "
                  "discard that. Affected files:" % (
                      len(dirty), args.entries_dir), file=sys.stderr)
            for p in dirty:
                print("  - " + p, file=sys.stderr)
            print("Resolve those by hand (or move them aside) before "
                  "re-running --force.", file=sys.stderr)
            return 1
        if orphaned:
            print("Error: --force refused: %d entry file(s) under %s are "
                  "untouched since they were written, but this migrate run "
                  "of %s would not recreate them (they are not one of its "
                  "headings) — replacing the directory would silently "
                  "delete them. Move them aside first if that is really "
                  "intended:" % (len(orphaned), args.entries_dir, args.source),
                  file=sys.stderr)
            for p in orphaned:
                print("  - " + p, file=sys.stderr)
            return 1

    index_rows = parse_index(src_lines)
    unmatched_rows, mismatch_warnings, status_warnings, ratio_report = \
        match_index_to_sections(sections, index_rows)

    pre_failures = []
    for r in unmatched_rows:
        pre_failures.append(
            "index row could not be matched to any entry with confidence "
            ">= %.2f: %r (anchor #%s) — its note would be lost; if this is "
            "a genuine entry, fix its heading or the index row by hand "
            "first" % (FUZZY_ACCEPT, r["title"], r["anchor"]))

    # Missing severity is never guessed. An owner audit of the real doc
    # found no discriminator between "a genuine entry the index table
    # simply never listed" and "not really an entry" — of 6 headings with
    # no severity anywhere, 5 were the former and 1 the latter, and
    # "missing from the index" was true of both. Defaulting silently is how
    # a HIGH finding becomes a LOW one and nobody notices — refuse instead,
    # and make a human decide once, loudly, with --accept-severity-defaults.
    missing_severity = find_missing_severity(sections)
    default_warnings = []
    if missing_severity and not args.accept_severity_defaults:
        pre_failures.append(
            "%d heading(s) have no severity anywhere (not in the heading, "
            "not in a matched index row) and --accept-severity-defaults was "
            "not given — refusing to guess:" % len(missing_severity))
        for s in missing_severity:
            pre_failures.append(
                "  line %d: %r" % (s["line"], s["heading"]))
        pre_failures.append(
            "Either give each of these an explicit severity in its heading "
            "or a matching index row, or re-run with "
            "--accept-severity-defaults to default them all to LOW (and "
            "fix them up afterwards with `known-issue.sh severity`)."
        )
    elif missing_severity:
        default_warnings = apply_severity_defaults(missing_severity)

    if pre_failures:
        print("MIGRATION VERIFICATION FAILED — nothing written.\n", file=sys.stderr)
        for f in pre_failures:
            print(" - " + f, file=sys.stderr)
        return 1

    # -------- stage to a temp dir; verify from disk; only then go live --------
    staging = tempfile.mkdtemp(prefix="known-issue-migrate-")
    try:
        entries_for_index = []
        for s in sections:
            meta = {
                "title": s["title"], "heading_raw": s["heading_raw"],
                "severity": s["severity"], "status": s["status"],
                "resolved": s["resolved"], "qualifiers": s["qualifiers"],
                "note": s["note"], "tickets": s["tickets"], "slug": s["slug"],
            }
            path = os.path.join(staging, s["slug"] + ".md")
            with open(path, "w") as fh:
                fh.write(dump_entry(meta, s["body"]))
            entries_for_index.append((meta, "known-issues/%s.md" % s["slug"]))

        failures = verify_migration_on_disk(args.source, staging)
        if failures:
            print("MIGRATION VERIFICATION FAILED — nothing written.\n", file=sys.stderr)
            for f in failures:
                print(" - " + f, file=sys.stderr)
            return 1

        index_text = build_index(entries_for_index)

        if os.path.isdir(args.entries_dir):
            shutil.rmtree(args.entries_dir)
        shutil.move(staging, args.entries_dir)
        staging = None  # moved; do not clean up below

        manifest = {}
        for s in sections:
            manifest[s["slug"]] = file_hash(
                os.path.join(args.entries_dir, s["slug"] + ".md"))
        save_manifest(args.entries_dir, manifest)

        with open(args.index_file, "w") as fh:
            fh.write(index_text)
    finally:
        if staging is not None and os.path.isdir(staging):
            shutil.rmtree(staging)

    print("Migration OK.")
    print("  entries written: %d" % len(sections))
    print("  index rows matched: %d/%d" % (
        len(index_rows) - len(unmatched_rows), len(index_rows)))
    if ratio_report:
        print("\nFuzzy title matches accepted (ratio, confidence):")
        for w in ratio_report:
            print("  - " + w)
    if mismatch_warnings:
        print("\nTitle/anchor mismatches (title was edited after the anchor "
              "was generated — informational, not blocking):")
        for w in mismatch_warnings:
            print("  - " + w)
    if status_warnings:
        print("\nStatus disagreements between the heading and the stale "
              "index (kept the heading's status; review by hand):")
        for w in status_warnings:
            print("  - " + w)
    if default_warnings:
        print("\nSeverity backfilled from context — review these:")
        for w in default_warnings:
            print("  - " + w)
    return 0


def cmd_reindex(args):
    entries, err = load_all_entries_safe(args.entries_dir)
    if err is not None:
        print("Error: " + err, file=sys.stderr)
        return 1
    index_entries = [(meta, relpath) for meta, body, relpath, path in entries]
    with open(args.index_file, "w") as fh:
        fh.write(build_index(index_entries))
    print("Reindexed %d entries into %s" % (len(entries), args.index_file))
    return 0


def cmd_lint(args):
    entries, err = load_all_entries_safe(args.entries_dir)
    if err is not None:
        print("Error: " + err, file=sys.stderr)
        return 1
    if not entries:
        print("Error: no entries found in %s" % args.entries_dir, file=sys.stderr)
        return 1
    index_entries = [(meta, relpath) for meta, body, relpath, path in entries]
    expected = build_index(index_entries)
    actual = None
    if os.path.exists(args.index_file):
        with open(args.index_file) as fh:
            actual = fh.read()
    if actual != expected:
        print("LINT FAILED:", file=sys.stderr)
        print(" - %s is not what `reindex` would produce — run "
              "`known-issue.sh reindex`" % args.index_file, file=sys.stderr)
        return 1
    # A row-shape check independent of build_index: "actual == expected"
    # above can only ever confirm the index agrees with itself — if
    # build_index has a rendering bug (an unescaped '|' in a title, say)
    # both sides of that comparison have the identical bug and it can never
    # be seen. This counts UNESCAPED pipe delimiters per data row by
    # scanning the on-disk text directly, without calling build_index or
    # any of its helpers, so it can catch a rendering defect that
    # comparison-against-itself structurally cannot.
    shape_errors = lint_index_row_shapes(actual)
    if shape_errors:
        print("LINT FAILED:", file=sys.stderr)
        for e in shape_errors:
            print(" - " + e, file=sys.stderr)
        return 1
    print("OK: %d entries, index up to date." % len(entries))
    return 0


def lint_index_row_shapes(index_text):
    """Independent structural check: every markdown table DATA row in
    index_text must have exactly 3 unescaped '|' delimiters (a 2-column
    table: | severity | finding |). Does not call build_index or any of
    its helpers — an unescaped '|' inside a title/note cell would silently
    shift a row's column count, and this is the check able to notice that
    even if the code that rendered the row is itself the buggy code."""
    errors = []
    in_table = False
    for lineno, line in enumerate(index_text.split("\n"), start=1):
        if line.startswith("| Severity | Finding |"):
            in_table = True
            continue
        if in_table and re.match(r'^\|\s*-+\s*\|\s*-+\s*\|$', line):
            continue  # the header separator row
        if in_table and line.startswith("|"):
            unescaped_pipes = len(re.findall(r'(?<!\\)\|', line))
            if unescaped_pipes != 3:
                errors.append(
                    "index line %d has %d unescaped '|' delimiters, expected 3 "
                    "(a title or note likely contains an unescaped '|'): %r"
                    % (lineno, unescaped_pipes, line))
        elif in_table and line == "":
            in_table = False
    return errors


def write_entry_verified(entries_dir, slug, path, meta, body_lines):
    """Write an entry, then immediately re-parse it FROM DISK with the
    same load_entry() any later lint/reindex/add call would use — never
    trust that a write which didn't raise produced a file the rest of this
    tool can actually read back. A dump_entry bug (escaping, field
    ordering, anything) would otherwise land on disk, get manifest-recorded
    via record_written, and only surface on the NEXT unrelated invocation
    of this tool, as a hard failure against a file nobody suspects. On
    failure, the bad file is removed (nothing was recorded, nothing is left
    behind to explain) and the caller reports the error and returns
    non-zero without calling record_written or cmd_reindex.
    Returns True on success, False (with an error already printed) on
    failure."""
    with open(path, "w") as fh:
        fh.write(dump_entry(meta, body_lines))
    try:
        load_entry(path)
    except ValueError as e:
        try:
            os.remove(path)
        except OSError:
            pass
        print("Error: wrote %s but could not read it back (%s) — removed it, "
              "nothing recorded" % (path, e), file=sys.stderr)
        return False
    record_written(entries_dir, slug, path)
    return True


def cmd_add(args):
    existing_slugs = set()
    if os.path.isdir(args.entries_dir):
        existing_slugs = {n[:-3] for n in os.listdir(args.entries_dir) if n.endswith(".md")}
    slug = make_slug(args.title, existing_slugs)
    with open(args.body_file) as fh:
        body_lines = fh.read().split("\n")
    while body_lines and body_lines[0] == "":
        body_lines.pop(0)
    while body_lines and body_lines[-1] == "":
        body_lines.pop()
    meta = {
        "title": args.title,
        "heading_raw": "%s — %s" % (args.title, args.severity),
        "severity": args.severity,
        "status": "open",
        "qualifiers": [],
        "note": args.note,
        "tickets": args.tickets.split(",") if args.tickets else [],
        "slug": slug,
    }
    os.makedirs(args.entries_dir, exist_ok=True)
    path = os.path.join(args.entries_dir, slug + ".md")
    if not write_entry_verified(args.entries_dir, slug, path, meta, body_lines):
        return 1
    print("Wrote %s" % path)
    return cmd_reindex(args)


def cmd_resolve(args):
    if not validate_slug_arg(args.slug):
        return 1
    path = os.path.join(args.entries_dir, args.slug + ".md")
    if not os.path.exists(path):
        print("Error: no such entry %r" % args.slug, file=sys.stderr)
        return 1
    try:
        meta, body = load_entry(path)
    except ValueError as e:
        print("Error: " + str(e), file=sys.stderr)
        return 1
    meta["status"] = "resolved"
    meta["resolved"] = args.date
    if args.note:
        meta["note"] = args.note
    if not write_entry_verified(args.entries_dir, args.slug, path, meta, body):
        return 1
    print("Resolved %s (%s)" % (args.slug, args.date))
    return cmd_reindex(args)


def cmd_severity(args):
    if not validate_slug_arg(args.slug):
        return 1
    path = os.path.join(args.entries_dir, args.slug + ".md")
    if not os.path.exists(path):
        print("Error: no such entry %r" % args.slug, file=sys.stderr)
        return 1
    try:
        meta, body = load_entry(path)
    except ValueError as e:
        print("Error: " + str(e), file=sys.stderr)
        return 1
    meta["severity"] = args.severity
    if not write_entry_verified(args.entries_dir, args.slug, path, meta, body):
        return 1
    print("%s severity now %s" % (args.slug, args.severity))
    return cmd_reindex(args)


def main():
    p = argparse.ArgumentParser(prog="known-issue-engine")
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--entries-dir", required=True)
        sp.add_argument("--index-file", required=True)

    m = sub.add_parser("migrate")
    common(m)
    m.add_argument("--source", required=True)
    m.add_argument("--force", action="store_true")
    m.add_argument("--accept-severity-defaults", action="store_true")

    common(sub.add_parser("reindex"))
    common(sub.add_parser("lint"))

    a = sub.add_parser("add")
    common(a)
    a.add_argument("--title", required=True)
    a.add_argument("--severity", required=True, choices=SEV_ORDER)
    a.add_argument("--note")
    a.add_argument("--tickets")
    a.add_argument("--body-file", required=True)

    r = sub.add_parser("resolve")
    common(r)
    r.add_argument("--slug", required=True)
    r.add_argument("--date", required=True)
    r.add_argument("--note")

    s = sub.add_parser("severity")
    common(s)
    s.add_argument("--slug", required=True)
    s.add_argument("--severity", required=True, choices=SEV_ORDER)

    args = p.parse_args()
    fn = {
        "migrate": cmd_migrate, "reindex": cmd_reindex, "lint": cmd_lint,
        "add": cmd_add, "resolve": cmd_resolve, "severity": cmd_severity,
    }[args.cmd]
    return fn(args)


if __name__ == "__main__":
    sys.exit(main())
PYEOF

run_engine() {
    python3 "$ENGINE" "$@"
}

# --------------------------------------------------------------- help text

usage_migrate() {
    cat <<EOF
Usage: known-issue.sh migrate [--force] [--accept-severity-defaults]

ONE-SHOT. Parses the current docs/known-issues.md (hand-written prose plus a
hand-maintained index table) and splits it into one file per entry under
docs/known-issues/, then regenerates docs/known-issues.md as the index.

Heading detection is fence-aware for both \`\`\` and ~~~ code blocks, and is
cross-checked against a second, independently-shaped implementation before
being trusted. Every entry is staged to a temp directory and verified
entirely from a FRESH re-read of both the source and the staged files —
never the in-memory data used to decide what to write — before anything
goes live. If any check fails, nothing is written and the real
docs/known-issues/ and docs/known-issues.md are untouched.

A heading with no severity anywhere — not in the heading itself, not in a
matched index row — is never guessed. "Missing from the index" cannot tell
a genuine entry the table simply forgot from something that is not really
an entry at all (both shapes exist in the real doc). migrate refuses,
printing every such heading with its line number, unless
--accept-severity-defaults is given, in which case they are set to LOW and
named in the output for follow-up with \`known-issue.sh severity\`.

Refuses to run if docs/known-issues/ already exists and is non-empty, unless
--force is given. --force only helps when docs/known-issues.md has been
restored to real hand-written content (its own successful run overwrites
that path with the generated index, so running it twice back to back with
nothing else changed fails earlier, with its own explanation, for a more
fundamental reason). When it does run, --force refuses unless every
existing entry is simultaneously unmodified since this tool last wrote it,
still produced by this run, and not a manifest entry whose file was deleted
out from under it — see the header comment for the full three-part check.
EOF
    exit 0
}

usage_reindex() {
    cat <<EOF
Usage: known-issue.sh reindex

Regenerates docs/known-issues.md from the frontmatter of every file under
docs/known-issues/. Idempotent: running it twice with no entry changes
produces a byte-identical file.
EOF
    exit 0
}

usage_lint() {
    cat <<EOF
Usage: known-issue.sh lint

Verifies every docs/known-issues/*.md file parses, carries the required
frontmatter (title, severity, status, slug), has a slug matching its own
filename and unique among all entries, and that docs/known-issues.md is
exactly what \`reindex\` would produce right now. Exits non-zero on any
failure — this is the guard that keeps the index from drifting again.
EOF
    exit 0
}

usage_add() {
    cat <<EOF
Usage: known-issue.sh add --title TITLE --severity SEV [--note NOTE]
                           [--ticket PREFIX-nnn]... [--body TEXT]

Creates a new entry file under docs/known-issues/ and reindexes.

  --title TITLE      required
  --severity SEV     required; one of $SEVERITIES
  --note NOTE        optional one-line note shown in the index row
  --ticket PREFIX-nnn optional, repeatable
  --body TEXT        entry body. If omitted, the body is read from stdin.

Example:
  known-issue.sh add --title "Foo is broken" --severity MEDIUM \\
      --ticket PROJ-200 <<< "Foo has been broken since ..."
EOF
    exit 0
}

usage_resolve() {
    cat <<EOF
Usage: known-issue.sh resolve <slug> [--date YYYY-MM-DD] [--note NOTE]

Marks an existing entry resolved and reindexes.

  <slug>             required; the entry's filename under docs/known-issues/
                     without the .md suffix
  --date DATE        resolved date, YYYY-MM-DD (default: today)
  --note NOTE        replaces the entry's index-row note
EOF
    exit 0
}

usage_severity() {
    cat <<EOF
Usage: known-issue.sh severity <slug> <SEVERITY>

Changes an existing entry's severity and reindexes.

  <slug>             required; the entry's filename under docs/known-issues/
                     without the .md suffix
  <SEVERITY>         one of $SEVERITIES
EOF
    exit 0
}

# ---------------------------------------------------------------- dispatch

[ $# -ge 1 ] || show_help
case "$1" in
    -h|--help) show_help ;;
esac

CMD="$1"; shift
known_command "$CMD" migrate reindex add resolve severity lint \
    || die "unknown subcommand: $CMD (try --help)"

case "$CMD" in
    migrate)
        ENGINE_ARGS=(migrate --source "$INDEX_FILE" --entries-dir "$ENTRIES_DIR"
                     --index-file "$INDEX_FILE")
        while [ $# -gt 0 ]; do
            case "$1" in
                --force) ENGINE_ARGS+=(--force); shift ;;
                --accept-severity-defaults)
                    ENGINE_ARGS+=(--accept-severity-defaults); shift ;;
                -h|--help) usage_migrate ;;
                *) die "migrate: unknown option: $1 (try --help)" ;;
            esac
        done
        run_engine "${ENGINE_ARGS[@]}"
        ;;

    reindex)
        if [ $# -gt 0 ]; then
            case "$1" in
                -h|--help) usage_reindex ;;
                *) die "reindex: unknown option: $1 (try --help)" ;;
            esac
        fi
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        run_engine reindex --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
        ;;

    lint)
        if [ $# -gt 0 ]; then
            case "$1" in
                -h|--help) usage_lint ;;
                *) die "lint: unknown option: $1 (try --help)" ;;
            esac
        fi
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        run_engine lint --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
        ;;

    add)
        TITLE=""; SEVERITY=""; NOTE=""; BODY=""; HAVE_BODY=0
        TICKETS=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --title) TITLE="$2"; shift 2 ;;
                --severity) SEVERITY="$2"; shift 2 ;;
                --note) NOTE="$2"; shift 2 ;;
                --ticket)
                    valid_ticket "$2" || die "add: not a ticket id (want PREFIX-nnn): $2"
                    TICKETS="${TICKETS:+$TICKETS,}$2"
                    shift 2
                    ;;
                --body) BODY="$2"; HAVE_BODY=1; shift 2 ;;
                -h|--help) usage_add ;;
                *) die "add: unknown option: $1 (try --help)" ;;
            esac
        done
        [ -n "$TITLE" ] || die "add: --title is required"
        [ -n "$SEVERITY" ] || die "add: --severity is required"
        valid_severity "$SEVERITY" || die "add: severity must be one of $SEVERITIES (got: $SEVERITY)"

        BODY_FILE=$(tmpfile) || die "could not create a body tempfile"
        if [ "$HAVE_BODY" = 1 ]; then
            printf '%s\n' "$BODY" > "$BODY_FILE"
        else
            cat > "$BODY_FILE"
        fi
        [ -s "$BODY_FILE" ] || die "add: entry body is empty (pass --body or pipe one on stdin)"

        # Built as an array, not string-interpolated flags, so a note or
        # ticket list containing spaces survives as ONE argument instead of
        # being word-split back apart on its way to run_engine.
        ENGINE_ARGS=(add --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
                     --title "$TITLE" --severity "$SEVERITY" --body-file "$BODY_FILE")
        [ -n "$NOTE" ] && ENGINE_ARGS+=(--note "$NOTE")
        [ -n "$TICKETS" ] && ENGINE_ARGS+=(--tickets "$TICKETS")
        run_engine "${ENGINE_ARGS[@]}"
        ;;

    resolve)
        [ $# -ge 1 ] || usage_resolve
        case "$1" in -h|--help) usage_resolve ;; esac
        SLUG="$1"; shift
        DATE="$(date +%Y-%m-%d)"
        NOTE=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --date) DATE="$2"; shift 2 ;;
                --note) NOTE="$2"; shift 2 ;;
                -h|--help) usage_resolve ;;
                *) die "resolve: unknown option: $1 (try --help)" ;;
            esac
        done
        valid_date "$DATE" || die "resolve: --date must be YYYY-MM-DD (got: $DATE)"
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        valid_slug_shape "$SLUG" || die "resolve: not a valid slug (want lowercase letters/digits/hyphens, no leading/trailing/doubled hyphen): $SLUG"
        valid_slug "$SLUG" || die "resolve: no such entry: $SLUG (no $ENTRIES_DIR/$SLUG.md)"

        ENGINE_ARGS=(resolve --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE"
                     --slug "$SLUG" --date "$DATE")
        [ -n "$NOTE" ] && ENGINE_ARGS+=(--note "$NOTE")
        run_engine "${ENGINE_ARGS[@]}"
        ;;

    severity)
        [ $# -ge 2 ] || usage_severity
        case "$1" in -h|--help) usage_severity ;; esac
        SLUG="$1"; SEV="$2"; shift 2
        [ $# -eq 0 ] || die "severity: unknown option: $1 (try --help)"
        valid_severity "$SEV" || die "severity: must be one of $SEVERITIES (got: $SEV)"
        [ -d "$ENTRIES_DIR" ] || die "no entries yet — run 'migrate' first"
        valid_slug_shape "$SLUG" || die "severity: not a valid slug (want lowercase letters/digits/hyphens, no leading/trailing/doubled hyphen): $SLUG"
        valid_slug "$SLUG" || die "severity: no such entry: $SLUG (no $ENTRIES_DIR/$SLUG.md)"

        run_engine severity --entries-dir "$ENTRIES_DIR" --index-file "$INDEX_FILE" \
            --slug "$SLUG" --severity "$SEV"
        ;;
esac
