#!/bin/bash
#
# Bump this plugin's version, generate a CHANGELOG section from tracker
# outcomes, commit, and tag. The only versioning this repo has today is
# `.claude-plugin/plugin.json`'s `version` field — this script is the
# release process built on top of that.
#
# TICKET OUTCOMES. Ticket completions since the last release tag are read
# through this repo's provider seam (see providers/README.md): the
# default path is `providers/lib/provider.sh run tracker fetch <since>`,
# where <since> is the most recent `vX.Y.Z` tag (empty string if there is
# none yet). No `tracker/jira` implementation is installed yet (that is
# a tracker/jira implementation) — `nw_run` currently reports "not installed" every time, so the
# default path always fails until that ticket lands. This script does not
# die on that: a failed or empty fetch degrades to a single placeholder
# changelog line rather than blocking a release that has nothing else
# wrong with it. `--tracker-fetch PATH` (or $RELEASE_TRACKER_FETCH)
# overrides the default with a caller-supplied executable, same
# precedence style as the rest of this repo's provider selection
# (explicit flag > env var > default provider seam) and the same shape
# land-branch.sh's --jira-api models: an executable that this script
# calls itself, print-to-stdout, no daemon.
#
# The override executable (or the tracker/jira implementation, once
# shipped) is called as `<cmd> <since-tag>` and must print a JSON
# array of `{"key":..., "summary":..., "outcome":...}` to stdout. Any
# outcome text containing a line starting with `cost:` (this repo's
# dogfood convention — see docs/cost.md) has that line surfaced under its
# ticket's bullet; the line is not otherwise parsed or validated.
#
# Usage:
#   release.sh <major|minor|patch> [--dry-run] [--tracker-fetch PATH]
#   release.sh --help
#
# --dry-run prints the computed new version, the full changelog section
# that would be generated, and the tag name that would be created — and
# makes NO filesystem writes, no `git commit`, no `git tag`.
#
# Files touched (real run only):
#   .claude-plugin/plugin.json        .version bumped
#   .claude-plugin/marketplace.json   the "night-watchman" plugin entry's
#                                      .version bumped (added if absent)
#   CHANGELOG.md                      new section prepended (file created
#                                      with a minimal header if absent)
# ...then all three are committed together and an annotated tag `vX.Y.Z`
# is made pointing at that commit.
#
# Env overrides (flag wins):
#   RELEASE_TRACKER_FETCH   see --tracker-fetch above.
#
# Exit codes:
#   0   released (or, with --dry-run, computed cleanly) with nothing else
#       wrong.
#   1   a check failed AFTER a mutation began. plugin.json/marketplace.json/
#       CHANGELOG.md are reverted to their pre-run content before this exit
#       whenever the failure is the `git commit` step or earlier; a `git
#       tag` failure AFTER a successful commit is reported instead of
#       reverted (the commit is real work — the message says how to tag it
#       by hand).
#   2   could not evaluate — bad input, a dirty working tree, a missing or
#       malformed plugin.json/marketplace.json, or a tag that already
#       exists. Nothing was mutated before this exit.

set -euo pipefail
# shellcheck source=lib/kit.sh
. "$(cd "$(dirname "$0")" && pwd)/lib/kit.sh"

# stop2 — a precondition could not be met, BEFORE any mutating command has
# run. Same message shape as kit.sh's die(), different exit code — this
# script's own convention (see the header's Exit codes section).
stop2() { echo "Error: $*" >&2; exit 2; }

# pipe_ok — no-op. Documents a pipeline whose non-zero exit means "found
# nothing", an expected outcome a later check is responsible for reporting
# — not a real failure `set -o pipefail` should be allowed to kill the
# script over before that check runs.
pipe_ok() { return 0; }

TRACKER_FETCH_OVERRIDE=""
DRY_RUN=0
BUMP=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help|help) show_help ;;
        --dry-run) DRY_RUN=1; shift ;;
        --tracker-fetch)
            [ $# -ge 2 ] || stop2 "--tracker-fetch needs a path"
            TRACKER_FETCH_OVERRIDE="$2"; shift 2 ;;
        major|minor|patch)
            [ -z "$BUMP" ] || stop2 "bump kind given twice ('$BUMP' and '$1')"
            BUMP="$1"; shift ;;
        -*) stop2 "unknown option: $1 (see --help)" ;;
        *) stop2 "unexpected argument: $1 (see --help)" ;;
    esac
done

[ -n "$BUMP" ] || stop2 "usage: release.sh <major|minor|patch> [--dry-run] [--tracker-fetch PATH] (see --help)"

need git jq

# ---------------------------------------------------------------- preflight

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || stop2 "not inside a git repository"
cd "$REPO_ROOT"

# A real run commits plugin.json/marketplace.json/CHANGELOG.md alone, and
# an unrelated dirty file would either get swept into that commit (if
# staged elsewhere) or make the pre/post-run tree comparison meaningless —
# so this is required before ANY write. --dry-run makes no write at all,
# so it is exempt: the ticket's own verify condition is "prints version +
# changelog + tag and leaves the tree unchanged", which a dry run does
# regardless of what else is sitting uncommitted.
if [ "$DRY_RUN" != 1 ]; then
    STATUS_LINES=$(git status --porcelain 2>/dev/null) || stop2 "git status failed"
    [ -z "$STATUS_LINES" ] || stop2 "working tree has uncommitted changes — commit or stash them before releasing:
$STATUS_LINES"
fi

PLUGIN_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
MARKETPLACE_JSON="$REPO_ROOT/.claude-plugin/marketplace.json"
CHANGELOG="$REPO_ROOT/CHANGELOG.md"

[ -r "$PLUGIN_JSON" ] || stop2 "cannot read $PLUGIN_JSON"
[ -r "$MARKETPLACE_JSON" ] || stop2 "cannot read $MARKETPLACE_JSON"

CUR_VERSION=$(jq -r '.version // empty' "$PLUGIN_JSON" 2>/dev/null) || stop2 "could not parse $PLUGIN_JSON as JSON"
[ -n "$CUR_VERSION" ] || stop2 "$PLUGIN_JSON has no .version field"

MARKETPLACE_MATCHES=$(jq '[.plugins[]? | select(.name=="night-watchman")] | length' "$MARKETPLACE_JSON" 2>/dev/null) \
    || stop2 "could not parse $MARKETPLACE_JSON as JSON"
[ "$MARKETPLACE_MATCHES" = "1" ] \
    || stop2 "expected exactly one 'night-watchman' entry in $MARKETPLACE_JSON's plugins[], found $MARKETPLACE_MATCHES"

# ------------------------------------------------------------- compute semver

OLDIFS="$IFS"
IFS='.'
# shellcheck disable=SC2086  # deliberate word splitting: CUR_VERSION split on '.'
set -- $CUR_VERSION
IFS="$OLDIFS"
[ $# -eq 3 ] || stop2 "$PLUGIN_JSON's .version ('$CUR_VERSION') is not X.Y.Z"
CUR_MAJOR="$1"; CUR_MINOR="$2"; CUR_PATCH="$3"
for part in "$CUR_MAJOR" "$CUR_MINOR" "$CUR_PATCH"; do
    case "$part" in
        ''|*[!0-9]*) stop2 "$PLUGIN_JSON's .version ('$CUR_VERSION') is not X.Y.Z (non-numeric part: '$part')" ;;
    esac
done

NEW_MAJOR="$CUR_MAJOR"; NEW_MINOR="$CUR_MINOR"; NEW_PATCH="$CUR_PATCH"
case "$BUMP" in
    major) NEW_MAJOR=$((CUR_MAJOR + 1)); NEW_MINOR=0; NEW_PATCH=0 ;;
    minor) NEW_MINOR=$((CUR_MINOR + 1)); NEW_PATCH=0 ;;
    patch) NEW_PATCH=$((CUR_PATCH + 1)) ;;
esac
NEW_VERSION="$NEW_MAJOR.$NEW_MINOR.$NEW_PATCH"
TAG="v$NEW_VERSION"

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 && stop2 "tag '$TAG' already exists"

# ---------------------------------------------------------- resolve tracker

LAST_TAG=$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' 2>/dev/null) || LAST_TAG=""

if [ -n "$TRACKER_FETCH_OVERRIDE" ]; then
    [ -x "$TRACKER_FETCH_OVERRIDE" ] || stop2 "--tracker-fetch path is not executable: $TRACKER_FETCH_OVERRIDE"
    FETCH_CMD="$TRACKER_FETCH_OVERRIDE"
elif [ -n "${RELEASE_TRACKER_FETCH:-}" ]; then
    [ -x "$RELEASE_TRACKER_FETCH" ] || stop2 "\$RELEASE_TRACKER_FETCH path is not executable: $RELEASE_TRACKER_FETCH"
    FETCH_CMD="$RELEASE_TRACKER_FETCH"
else
    FETCH_CMD="$REPO_ROOT/providers/lib/provider.sh"
fi

TICKETS_JSON=""
FETCH_OK=0
if [ -x "$FETCH_CMD" ]; then
    if [ "$FETCH_CMD" = "$REPO_ROOT/providers/lib/provider.sh" ]; then
        OUT=$("$FETCH_CMD" run tracker fetch "$LAST_TAG" 2>/dev/null) || OUT=""
    else
        OUT=$("$FETCH_CMD" "$LAST_TAG" 2>/dev/null) || OUT=""
    fi
    if [ -n "$OUT" ]; then
        TICKETS_JSON="$OUT"
        FETCH_OK=1
    fi
fi
if [ "$FETCH_OK" = 1 ]; then
    printf '%s' "$TICKETS_JSON" | jq -e 'type == "array"' >/dev/null 2>&1 || FETCH_OK=0
fi

TICKET_LINES=""
if [ "$FETCH_OK" = 1 ]; then
    JQ_LINES=$(printf '%s' "$TICKETS_JSON" | jq -c '.[]' 2>/dev/null) || JQ_LINES=""
    if [ -n "$JQ_LINES" ]; then
        while IFS= read -r obj; do
            [ -n "$obj" ] || continue
            key=$(printf '%s' "$obj" | jq -r '.key // empty' 2>/dev/null) || key=""
            summary=$(printf '%s' "$obj" | jq -r '.summary // empty' 2>/dev/null) || summary=""
            outcome=$(printf '%s' "$obj" | jq -r '.outcome // empty' 2>/dev/null) || outcome=""
            [ -n "$summary" ] || summary="(no summary)"
            if [ -n "$key" ]; then
                TICKET_LINES="$TICKET_LINES- $key: $summary
"
            else
                TICKET_LINES="$TICKET_LINES- $summary
"
            fi
            cost_line=$(printf '%s\n' "$outcome" | grep -m1 '^cost:') || pipe_ok
            if [ -n "$cost_line" ]; then
                TICKET_LINES="$TICKET_LINES  $cost_line
"
            fi
        done <<EOF
$JQ_LINES
EOF
    fi
fi
if [ -z "$TICKET_LINES" ]; then
    if [ "$FETCH_OK" = 1 ]; then
        TICKET_LINES="- (no tickets completed since the last tag)
"
    else
        TICKET_LINES="- (no tracker configured; add entries by hand)
"
    fi
fi

# --------------------------------------------------------- build the section

TODAY=$(date +%F)
NEWSEC_FILE=$(tmpfile) || stop2 "could not create a temp file for the changelog section"
{
    printf '## [%s] - %s\n' "$NEW_VERSION" "$TODAY"
    printf '%s' "$TICKET_LINES"
} > "$NEWSEC_FILE"

if [ "$DRY_RUN" = 1 ]; then
    echo "new version: $NEW_VERSION"
    echo "tag: $TAG"
    echo
    echo "changelog section:"
    cat "$NEWSEC_FILE"
    echo
    echo "--dry-run: no files written, no commit, no tag."
    exit 0
fi

# --------------------------------------------------------------- write files

CHANGELOG_EXISTED=1
[ -f "$CHANGELOG" ] || CHANGELOG_EXISTED=0

OLD_CHANGELOG_FILE=$(tmpfile) || stop2 "could not create a temp file"
if [ "$CHANGELOG_EXISTED" = 1 ]; then
    cat "$CHANGELOG" > "$OLD_CHANGELOG_FILE"
else
    printf '# Changelog\n\nAll notable changes to this project are documented here.\n' > "$OLD_CHANGELOG_FILE"
fi

NEW_CHANGELOG_FILE=$(tmpfile) || stop2 "could not create a temp file"
awk -v secfile="$NEWSEC_FILE" '
    BEGIN { inserted = 0 }
    /^## \[/ && !inserted {
        while ((getline line < secfile) > 0) print line
        print ""
        inserted = 1
    }
    { print }
    END {
        if (!inserted) {
            print ""
            while ((getline line < secfile) > 0) print line
        }
    }
' "$OLD_CHANGELOG_FILE" > "$NEW_CHANGELOG_FILE" || stop2 "could not build new CHANGELOG.md content"

NEW_PLUGIN_FILE=$(tmpfile) || stop2 "could not create a temp file"
jq --arg v "$NEW_VERSION" '.version = $v' "$PLUGIN_JSON" > "$NEW_PLUGIN_FILE" \
    || stop2 "could not update .version in $PLUGIN_JSON"
[ -s "$NEW_PLUGIN_FILE" ] || stop2 "updating $PLUGIN_JSON produced an empty file"

NEW_MARKETPLACE_FILE=$(tmpfile) || stop2 "could not create a temp file"
jq --arg v "$NEW_VERSION" '
    .plugins = [ .plugins[] | if .name == "night-watchman" then .version = $v else . end ]
' "$MARKETPLACE_JSON" > "$NEW_MARKETPLACE_FILE" \
    || stop2 "could not update night-watchman's .version in $MARKETPLACE_JSON"
[ -s "$NEW_MARKETPLACE_FILE" ] || stop2 "updating $MARKETPLACE_JSON produced an empty file"

# rollback_files — restore plugin.json/marketplace.json/CHANGELOG.md to
# their pre-run content. Safe because the preflight above already
# guaranteed a clean working tree before any of these three were touched,
# so `git checkout --` on the two that pre-existed always has something to
# restore to, and CHANGELOG.md (which may be new) is simply removed rather
# than checked out when this run created it.
rollback_files() {
    git checkout -- "$PLUGIN_JSON" "$MARKETPLACE_JSON" 2>/dev/null \
        || warn "could not restore plugin.json/marketplace.json to their pre-release content — check by hand"
    if [ "$CHANGELOG_EXISTED" = 1 ]; then
        git checkout -- "$CHANGELOG" 2>/dev/null \
            || warn "could not restore CHANGELOG.md to its pre-release content — check by hand"
    else
        rm -f "$CHANGELOG" 2>/dev/null \
            || warn "could not remove newly created CHANGELOG.md — check by hand"
    fi
}

if ! mv "$NEW_PLUGIN_FILE" "$PLUGIN_JSON"; then
    rollback_files
    die "could not write $PLUGIN_JSON — reverted"
fi
if ! mv "$NEW_MARKETPLACE_FILE" "$MARKETPLACE_JSON"; then
    rollback_files
    die "could not write $MARKETPLACE_JSON — reverted"
fi
if ! mv "$NEW_CHANGELOG_FILE" "$CHANGELOG"; then
    rollback_files
    die "could not write $CHANGELOG — reverted"
fi

# -------------------------------------------------------------------- commit

COMMIT_MSG="release: $TAG

$(cat "$NEWSEC_FILE")"

if ! git add -- "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$CHANGELOG"; then
    rollback_files
    die "could not stage release files — reverted, nothing committed"
fi
if ! git commit -q -m "$COMMIT_MSG" -- "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$CHANGELOG"; then
    git reset -- "$PLUGIN_JSON" "$MARKETPLACE_JSON" "$CHANGELOG" >/dev/null 2>&1 || true
    rollback_files
    die "git commit failed — reverted, nothing committed"
fi

if ! git tag -a "$TAG" -m "$TAG"; then
    die "release commit for $TAG was made, but 'git tag -a $TAG' failed — the commit stands; create the tag by hand: git tag -a $TAG -m $TAG"
fi

echo "released $TAG (was $CUR_VERSION)."
exit 0
