#!/bin/bash
#
# Manage docs/decisions.d/ — one markdown file per dated decision, with
# docs/decisions.md as a GENERATED index concatenating every entry in
# order. Modelled on ai-toolkit's known-issue.sh shape (add/index/lint); no
# manifest/hash tamper-check (WO-022 found known-issue.sh's had drifted
# from every entry) and no status/severity, since a decision is never
# resolved or reopened, only superseded by a later entry.
#
# Subcommands:
#   migrate               ONE-SHOT. Split the hand-written docs/decisions.md
#                         into one file per entry under docs/decisions.d/,
#                         then write docs/decisions.md as the generated
#                         index. Refuses to run if docs/decisions.d/
#                         already holds any entry.
#   add --title T --body B [--date D] [--dry-run]
#                         Write one new entry file and reindex. --date
#                         defaults to today (UTC), YYYY-MM-DD. --dry-run
#                         prints the path that would be written; touches
#                         nothing.
#   index                 Regenerate docs/decisions.md from every file in
#                         docs/decisions.d/. Idempotent: running it twice
#                         with no entry changes produces a byte-identical
#                         file.
#   lint                  Every entry parses, has the required frontmatter,
#                         its filename matches its own slug, no two
#                         entries share a seq, and docs/decisions.md is
#                         exactly what `index` would produce right now.
#
# Global option, recognised anywhere in the argument list:
#   --root PATH           the repo to manage. Without it the repo comes from
#                         the CALLER'S cwd, kept as the default for the
#                         plugin case. A caller whose cwd has drifted then
#                         writes into whichever repo cwd is in, silently;
#                         NWM-122 did exactly that.
#
# Entry frontmatter (docs/decisions.d/<slug>.md):
#   seq    global order counter. index sorts by this, not by filename, so
#          same-day entries keep the order they were written in.
#   date   YYYY-MM-DD
#   level  original heading depth (2 or 3 '#'). A new entry always gets 3;
#          historical ones keep whatever the hand-written log used, so the
#          heading reconstructs exactly.
#   slug   the file's own basename minus .md, for round-trip safety.
#   title  quoted, free text — everything after "DATE — " on the heading.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

need awk git

# --root is lifted out of the argument list before the subcommand is read, so
# it works in any position and no subcommand parser has to know about it. An
# argument sitting in a value-taking option's slot is never treated as a flag,
# so `--body --root` stays a body.
VALUE_OPTS="--title --body --date --root"
HAVE_ROOT=0
ROOT_OVERRIDE=""
ARGS=()
PREV=""
while [ $# -gt 0 ]; do
    # shellcheck disable=SC2086  # VALUE_OPTS is a deliberate word-split list
    if [ "$1" = "--root" ] && ! known_command "$PREV" $VALUE_OPTS; then
        [ $# -ge 2 ] || die "--root needs a PATH"
        ROOT_OVERRIDE="$2"; HAVE_ROOT=1; PREV=""; shift 2; continue
    fi
    case "$1" in
        --root=*)
            # shellcheck disable=SC2086  # VALUE_OPTS is a deliberate word-split list
            if ! known_command "$PREV" $VALUE_OPTS; then
                ROOT_OVERRIDE="${1#--root=}"; HAVE_ROOT=1; PREV=""; shift; continue
            fi ;;
    esac
    ARGS+=("$1"); PREV="$1"; shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

# ROOT is the repo being managed, NOT this script's own location: a plugin
# script runs from ${CLAUDE_PLUGIN_ROOT}, outside the target repo entirely.
# --root overrides that; cwd stays the default so the plugin case is unbroken.
if [ "$HAVE_ROOT" = 1 ]; then
    # HAVE_ROOT rather than [ -n "$ROOT_OVERRIDE" ]: a set-but-EMPTY --root is
    # a caller bug and must fail here, not read as "absent" and fall back to
    # cwd — the target this flag exists to take away from cwd.
    [ -n "$ROOT_OVERRIDE" ] || die "--root: PATH is empty"
    [ -d "$ROOT_OVERRIDE" ] || die "--root: no such directory: $ROOT_OVERRIDE"
    ROOT="$(git -C "$ROOT_OVERRIDE" rev-parse --show-toplevel 2>/dev/null)" \
        || die "--root: not a git repository: $ROOT_OVERRIDE"
else
    ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
fi
ENTRIES_DIR="$ROOT/docs/decisions.d"
INDEX_FILE="$ROOT/docs/decisions.md"

valid_date() {
    case "$1" in
        [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
        *) return 1 ;;
    esac
}

slugify() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

hashes() { printf '%*s' "$1" '' | tr ' ' '#'; }

# frontmatter_field FILE KEY — print KEY's value (unquoted), or fail.
frontmatter_field() {
    awk -v key="$2" '
        NR == 1 { if ($0 != "---") exit 1; next }
        $0 == "---" { exit }
        $0 ~ "^" key ": " {
            v = $0
            sub("^" key ": ", "", v)
            if (v ~ /^".*"$/) {
                v = substr(v, 2, length(v) - 2)
                gsub(/\\"/, "\"", v)
                gsub(/\\\\/, "\\", v)
            }
            print v
            found = 1
        }
        END { exit (found ? 0 : 1) }
    ' "$1"
}

# entry_body FILE — everything after the closing frontmatter '---', minus
# exactly one leading blank line separator.
entry_body() {
    awk '
        NR == 1 && $0 == "---" { infm = 1; next }
        infm && $0 == "---" { infm = 0; started = 1; skip = 1; next }
        infm { next }
        started {
            if (skip && $0 == "") { skip = 0; next }
            skip = 0
            print
        }
    ' "$1"
}

# list_entries — one row per entry file: seq<TAB>path. Skips anything
# that fails to parse (frontmatter_field's own exit status), so a
# malformed file is silently absent here; `lint` is what reports it.
list_entries() {
    local f seq
    for f in "$ENTRIES_DIR"/*.md; do
        [ -e "$f" ] || continue
        seq="$(frontmatter_field "$f" seq)" || continue
        printf '%s\t%s\n' "$seq" "$f"
    done
}

next_seq() {
    local max=0 v f
    for f in "$ENTRIES_DIR"/*.md; do
        [ -e "$f" ] || continue
        v="$(frontmatter_field "$f" seq)" || continue
        case "$v" in ''|*[!0-9]*) continue ;; esac
        [ "$v" -gt "$max" ] && max="$v"
    done
    echo $((max + 1))
}

# render_index — the full generated docs/decisions.md, to stdout.
render_index() {
    cat <<'HEADER'
# Decisions — dated append log of "why"

**GENERATED — do not hand-edit.** Produced by `scripts/decisions.sh index`
from the frontmatter and body of every file in `docs/decisions.d/`. Add an
entry with `scripts/decisions.sh add --title T --body B`, which writes the
file there and reindexes for you. `scripts/decisions.sh lint` fails if this
file ever drifts from what `index` would produce.

Append-only. Never rewrite or delete an entry — if a decision changes,
append a new entry that names the old one it supersedes. The point is a
fresh session (or a fresh agent) can read this file top-to-bottom and see
not just what was decided but why, and whether that reasoning still holds.

Newest entries at the bottom. Each entry: a date, one line naming the
decision, then the reasoning that led to it — the constraint, tradeoff, or
incident that made one option win. A decision with no reasoning is a
fact, not a decision, and belongs in a `docs/` topic file instead — see
`tickets-protocol`'s routing table.

Append only when all three gates hold: costly to reverse, a future reader
would be surprised without it, and real alternatives were weighed.
Otherwise it is a fact for a topic file, or nothing. Rejected alternatives
worth remembering stay as cancelled tickets with an outcome, not an entry
here.

## Log
HEADER
    local path level date title
    list_entries | sort -t "$(printf '\t')" -k1,1n | while IFS="$(printf '\t')" read -r _ path; do
        level="$(frontmatter_field "$path" level)" || die "$path: missing level"
        date="$(frontmatter_field "$path" date)" || die "$path: missing date"
        title="$(frontmatter_field "$path" title)" || die "$path: missing title"
        printf '\n%s %s — %s\n\n' "$(hashes "$level")" "$date" "$title"
        entry_body "$path"
    done
}

write_entry() {
    local path="$1" seq="$2" date="$3" level="$4" slug="$5" title="$6" body="$7"
    {
        printf -- '---\n'
        printf 'seq: %s\n' "$seq"
        printf 'date: %s\n' "$date"
        printf 'level: %s\n' "$level"
        printf 'slug: %s\n' "$slug"
        printf 'title: "%s"\n' "$(printf '%s' "$title" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
        printf -- '---\n\n'
        printf '%s\n' "$body"
    } >"$path"
}

# unique_slug BASE — BASE, or BASE-2, BASE-3, ... whichever doesn't exist.
unique_slug() {
    local base="$1" slug="$1" n=2
    while [ -e "$ENTRIES_DIR/$slug.md" ]; do
        slug="${base}-${n}"
        n=$((n + 1))
    done
    printf '%s\n' "$slug"
}

# add_lock/add_unlock — a bare mkdir is atomic on every POSIX filesystem,
# so this is the whole mutex: two `add` calls at once must not compute the
# same seq or race two writers of docs/decisions.md onto each other.
ADD_LOCK=""
add_unlock() { [ -n "$ADD_LOCK" ] && rmdir "$ADD_LOCK" 2>/dev/null; ADD_LOCK=""; }
add_lock() {
    ADD_LOCK="$ENTRIES_DIR/.add.lock"
    local tries=0
    while ! mkdir "$ADD_LOCK" 2>/dev/null; do
        tries=$((tries + 1))
        [ "$tries" -lt 100 ] || die "could not acquire $ADD_LOCK after 100 tries; a stale lock from a killed run?"
        sleep 0.1
    done
    kit_on_exit add_unlock
}

cmd_add() {
    local title="" body="" date="" dry_run=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --title) [ $# -ge 2 ] || die "--title requires an argument"; title="$2"; shift 2 ;;
            --body) [ $# -ge 2 ] || die "--body requires an argument"; body="$2"; shift 2 ;;
            --date) [ $# -ge 2 ] || die "--date requires an argument"; date="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help) show_help ;;
            *) die "unknown argument: $1 (see --help)" ;;
        esac
    done
    [ -n "$title" ] || die "--title is required"
    [ -n "$body" ] || die "--body is required"
    [ -n "$date" ] || date="$(date -u +%Y-%m-%d)"
    valid_date "$date" || die "--date must be YYYY-MM-DD, got: $date"

    if [ "$dry_run" -eq 1 ]; then
        printf 'docs/decisions.d/%s.md\n' "$(unique_slug "${date}-$(slugify "$title")")"
        return 0
    fi

    [ -d "$ENTRIES_DIR" ] || mkdir -p "$ENTRIES_DIR"
    add_lock
    local slug seq
    slug="$(unique_slug "${date}-$(slugify "$title")")"
    seq="$(next_seq)"
    write_entry "$ENTRIES_DIR/$slug.md" "$seq" "$date" 3 "$slug" "$title" "$body"
    render_index >"$INDEX_FILE.tmp.$$"
    mv "$INDEX_FILE.tmp.$$" "$INDEX_FILE"
    add_unlock
}

cmd_index() {
    [ -d "$ENTRIES_DIR" ] || die "no such directory: $ENTRIES_DIR (run migrate first)"
    render_index >"$INDEX_FILE.tmp.$$"
    mv "$INDEX_FILE.tmp.$$" "$INDEX_FILE"
}

cmd_lint() {
    [ -d "$ENTRIES_DIR" ] || die "no such directory: $ENTRIES_DIR (run migrate first)"
    local fail=0 f base slug seq date level title
    local seen_seqs=" "
    for f in "$ENTRIES_DIR"/*.md; do
        [ -e "$f" ] || continue
        base="$(basename "$f" .md)"
        slug="$(frontmatter_field "$f" slug)" || { echo "FAIL: $f: missing slug"; fail=1; continue; }
        seq="$(frontmatter_field "$f" seq)" || { echo "FAIL: $f: missing seq"; fail=1; continue; }
        date="$(frontmatter_field "$f" date)" || { echo "FAIL: $f: missing date"; fail=1; continue; }
        level="$(frontmatter_field "$f" level)" || { echo "FAIL: $f: missing level"; fail=1; continue; }
        title="$(frontmatter_field "$f" title)" || { echo "FAIL: $f: missing title"; fail=1; continue; }
        [ "$slug" = "$base" ] || { echo "FAIL: $f: slug '$slug' does not match filename"; fail=1; }
        case "$seq" in ''|*[!0-9]*) echo "FAIL: $f: seq '$seq' is not a positive integer"; fail=1 ;; esac
        valid_date "$date" || { echo "FAIL: $f: date '$date' is not YYYY-MM-DD"; fail=1; }
        case "$level" in 1|2|3|4|5|6) ;; *) echo "FAIL: $f: level '$level' is not 1-6"; fail=1 ;; esac
        [ -n "$title" ] || { echo "FAIL: $f: title is empty"; fail=1; }
        case "$seen_seqs" in *" $seq "*) echo "FAIL: $f: seq $seq is used by another entry too"; fail=1 ;; esac
        seen_seqs="$seen_seqs$seq "
    done

    if [ -f "$INDEX_FILE" ]; then
        render_index >"$ROOT/.decisions-lint.$$.tmp"
        if ! diff -q "$ROOT/.decisions-lint.$$.tmp" "$INDEX_FILE" >/dev/null 2>&1; then
            echo "FAIL: docs/decisions.md is out of date; run scripts/decisions.sh index"
            fail=1
        fi
        rm -f "$ROOT/.decisions-lint.$$.tmp"
    else
        echo "FAIL: $INDEX_FILE does not exist; run scripts/decisions.sh index"
        fail=1
    fi

    [ "$fail" -eq 0 ]
}

cmd_migrate() {
    for f in "$ENTRIES_DIR"/*.md; do
        [ -e "$f" ] && die "$ENTRIES_DIR already has entries; migrate only runs once"
        break
    done
    [ -f "$INDEX_FILE" ] || die "no such file: $INDEX_FILE"

    mkdir -p "$ENTRIES_DIR"
    local n
    n="$(awk -v entries_dir="$ENTRIES_DIR" -f "$HERE/lib/decisions-migrate.awk" "$INDEX_FILE" | wc -l | tr -d ' ')"
    [ "$n" -ge 1 ] || die "migrate found no dated entries in $INDEX_FILE"

    render_index >"$INDEX_FILE.tmp.$$"
    mv "$INDEX_FILE.tmp.$$" "$INDEX_FILE"
    echo "migrated $n entries into $ENTRIES_DIR"
}

SUBCMD="${1:-}"
[ -n "$SUBCMD" ] || show_help
shift
case "$SUBCMD" in
    -h|--help) show_help ;;
    add) cmd_add "$@" ;;
    index) cmd_index "$@" ;;
    lint) cmd_lint "$@" ;;
    migrate) cmd_migrate "$@" ;;
    *) die "unknown subcommand: $SUBCMD (see --help)" ;;
esac
