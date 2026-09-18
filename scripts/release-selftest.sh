#!/bin/bash
#
# Selftest for release.sh. Builds a scratch git repo per test case (a
# minimal .claude-plugin/plugin.json + marketplace.json, this script's
# target release.sh + scripts/lib/kit.sh copied in) and never reaches a
# live tracker: the default tracker-fetch path degrades because no
# providers/ directory exists in any scratch repo, and every override
# used here is a local stub script under this test's own scratch dir,
# never a real tracker/jira implementation.
#
# name-the-oracle: the semver test uses its own independently-written bump
# function and the changelog tests grep literal strings, never release.sh's
# own logic. Test 8 corrupts the input so an assertion is observed failing.
#
# Usage: scripts/release-selftest.sh [path-to-release.sh]
# Defaults to the sibling scripts/release.sh.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REL="${1:-$HERE/release.sh}"
KIT="$HERE/lib/kit.sh"
[ -r "$REL" ] || { echo "cannot read $REL" >&2; exit 2; }
[ -r "$KIT" ] || { echo "cannot read $KIT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# write_plugin_json DIR VERSION
write_plugin_json() {
    printf '{\n  "name": "night-watchman",\n  "version": "%s"\n}\n' "$2" > "$1/.claude-plugin/plugin.json"
}

# write_marketplace_json DIR yes|no [VERSION] — "no" omits .version
# entirely, matching this repo's real marketplace.json today (test 6/f's
# starting point: it must GROW the key, not merely update an existing one).
write_marketplace_json() {
    if [ "$2" = yes ]; then
        printf '{\n  "plugins": [\n    { "name": "night-watchman", "version": "%s" }\n  ]\n}\n' "$3" > "$1/.claude-plugin/marketplace.json"
    else
        printf '{\n  "plugins": [\n    { "name": "night-watchman" }\n  ]\n}\n' > "$1/.claude-plugin/marketplace.json"
    fi
}

# fresh_repo NAME [PLUGIN_VERSION] — a throwaway git repo under $WORK/NAME with
# release.sh + lib/kit.sh installed, plugin.json at PLUGIN_VERSION (default
# 0.1.0), marketplace.json with NO .version key, no CHANGELOG.md, and
# everything committed so the preflight's clean-tree check passes.
fresh_repo() {
    local d="$WORK/$1" version="${2:-0.1.0}"
    rm -rf "$d"
    mkdir -p "$d/scripts/lib" "$d/.claude-plugin"
    cp "$REL" "$d/scripts/release.sh"
    cp "$KIT" "$d/scripts/lib/kit.sh"
    chmod +x "$d/scripts/release.sh"
    write_plugin_json "$d" "$version"
    write_marketplace_json "$d" no
    (
        cd "$d"
        git init -q -b main
        git config commit.gpgsign false
        git config gpg.format openpgp
        git config core.hooksPath /dev/null
        git config user.email "test@example.invalid"
        git config user.name "release selftest"
        git config user.signingkey ""
        git add -A
        git commit -q -m "init"
    ) >/dev/null
    printf '%s\n' "$d"
}

STUBS="$WORK/stubs"
mkdir -p "$STUBS"

# good_fetch — a local stub, never a real tracker: two tickets, one whose
# outcome carries a cost: line, one that does not.
cat > "$STUBS/good_fetch.sh" <<'STUB'
#!/bin/bash
cat <<'JSON'
[
  {"key":"NWM-99","summary":"Add widget frobnicator","outcome":"Did the thing.\ncost: $1.23, 4 turns"},
  {"key":"NWM-100","summary":"Fix bug in gadget","outcome":"Fixed it, no cost line here."}
]
JSON
STUB
chmod +x "$STUBS/good_fetch.sh"

# bad_fetch — simulates an unreachable/broken tracker: fails, prints
# nothing useful. Exercises the override's own degrade path, distinct from
# the default path's degrade (no providers/ dir at all).
cat > "$STUBS/bad_fetch.sh" <<'STUB'
#!/bin/bash
echo "simulated tracker outage" >&2
exit 1
STUB
chmod +x "$STUBS/bad_fetch.sh"

# empty_fetch — a tracker that IS reachable and answers, but there is
# nothing to report (no tickets completed since the last tag). Distinct
# from bad_fetch: this must NOT produce the "no tracker configured" text.
cat > "$STUBS/empty_fetch.sh" <<'STUB'
#!/bin/bash
echo "[]"
STUB
chmod +x "$STUBS/empty_fetch.sh"

# ---- test 1 (a): --dry-run makes zero writes and prints version+changelog+tag.

REPO=$(fresh_repo t1 0.4.2)
BEFORE_HEAD=$(cd "$REPO" && git rev-parse HEAD)
BEFORE_STATUS=$(cd "$REPO" && git status --porcelain)
BEFORE_TAGS=$(cd "$REPO" && git tag -l)
set +e
OUT=$(cd "$REPO" && ./scripts/release.sh patch --dry-run 2>&1)
RC=$?
set -e
AFTER_HEAD=$(cd "$REPO" && git rev-parse HEAD)
AFTER_STATUS=$(cd "$REPO" && git status --porcelain)
AFTER_TAGS=$(cd "$REPO" && git tag -l)
if [ "$RC" -ne 0 ]; then
    bad "test1 (dry-run): exited $RC:
$OUT"
elif [ "$BEFORE_HEAD" != "$AFTER_HEAD" ] || [ "$BEFORE_STATUS" != "$AFTER_STATUS" ] || [ "$BEFORE_TAGS" != "$AFTER_TAGS" ]; then
    bad "test1 (dry-run): the working tree changed (HEAD, status, or tags differ before/after)"
elif ! printf '%s' "$OUT" | grep -qF "new version: 0.4.3"; then
    bad "test1 (dry-run): output did not print the new version 0.4.3:
$OUT"
elif ! printf '%s' "$OUT" | grep -qF "tag: v0.4.3"; then
    bad "test1 (dry-run): output did not print the tag v0.4.3:
$OUT"
elif ! printf '%s' "$OUT" | grep -qF "## [0.4.3]"; then
    bad "test1 (dry-run): output did not print the changelog section heading:
$OUT"
else
    ok "test1: --dry-run prints version+changelog+tag and leaves the tree byte-for-byte unchanged"
fi

# ---- test 2 (b): semver bump math, computed independently in THIS test
# (not derived from release.sh) for several starting versions/bump kinds.

# bump_expected VERSION KIND — an independent reimplementation, deliberately
# not shared code with release.sh's own bump logic.
bump_expected() {
    local v="$1" kind="$2" major minor patch
    IFS='.' read -r major minor patch <<<"$v"
    case "$kind" in
        major) printf '%d.0.0\n' "$((major + 1))" ;;
        minor) printf '%d.%d.0\n' "$major" "$((minor + 1))" ;;
        patch) printf '%d.%d.%d\n' "$major" "$minor" "$((patch + 1))" ;;
    esac
}

SEMVER_FAIL=0
i=0
for case_spec in "0.1.0 patch" "1.2.3 minor" "2.9.9 major" "0.0.9 patch" "9.9.9 major"; do
    i=$((i + 1))
    start=$(printf '%s' "$case_spec" | cut -d' ' -f1)
    kind=$(printf '%s' "$case_spec" | cut -d' ' -f2)
    expected=$(bump_expected "$start" "$kind")
    REPO=$(fresh_repo "t2_$i" "$start")
    set +e
    OUT=$(cd "$REPO" && ./scripts/release.sh "$kind" 2>&1)
    RC=$?
    set -e
    if [ "$RC" -ne 0 ]; then
        bad "test2 ($start $kind -> $expected): release.sh exited $RC:
$OUT"
        SEMVER_FAIL=1
        continue
    fi
    GOT=$(jq -r '.version' "$REPO/.claude-plugin/plugin.json")
    if [ "$GOT" != "$expected" ]; then
        bad "test2 ($start $kind): plugin.json ended up at '$GOT', expected '$expected'"
        SEMVER_FAIL=1
    elif ! (cd "$REPO" && git tag -l "v$expected" | grep -qF "v$expected"); then
        bad "test2 ($start $kind): no tag v$expected was created"
        SEMVER_FAIL=1
    fi
done
[ "$SEMVER_FAIL" -eq 0 ] && ok "test2: patch/minor/major bumps compute the expected next version from several starting points"

# ---- test 3 (c): tracker-fetch override renders outcomes into the
# changelog, including a surfaced cost: line, and omits one where absent.

REPO=$(fresh_repo t3 0.2.0)
(cd "$REPO" && ./scripts/release.sh patch --tracker-fetch "$STUBS/good_fetch.sh") >"$WORK/t3.out" 2>&1
RC=$?
CHANGELOG_CONTENT=$(cat "$REPO/CHANGELOG.md" 2>/dev/null || echo "<missing>")
if [ "$RC" -ne 0 ]; then
    bad "test3 (tracker-fetch override): release.sh exited $RC:
$(cat "$WORK/t3.out")"
elif ! printf '%s' "$CHANGELOG_CONTENT" | grep -qF -- "- NWM-99: Add widget frobnicator"; then
    bad "test3: CHANGELOG.md missing the NWM-99 bullet:
$CHANGELOG_CONTENT"
elif ! printf '%s' "$CHANGELOG_CONTENT" | grep -qF -- "cost: \$1.23, 4 turns"; then
    bad "test3: CHANGELOG.md did not surface the cost: line from NWM-99's outcome:
$CHANGELOG_CONTENT"
elif ! printf '%s' "$CHANGELOG_CONTENT" | grep -qF -- "- NWM-100: Fix bug in gadget"; then
    bad "test3: CHANGELOG.md missing the NWM-100 bullet:
$CHANGELOG_CONTENT"
else
    ok "test3: --tracker-fetch override's outcomes render into the changelog, cost: line included when present"
fi

# ---- test 4 (d): tracker fetch unavailable (default path, no providers/
# directory in the scratch repo) and a failing override both degrade to
# the placeholder line rather than dying.

REPO=$(fresh_repo t4a 0.3.0)
set +e
(cd "$REPO" && ./scripts/release.sh patch) >"$WORK/t4a.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test4a (default tracker fetch, none installed): release.sh exited $RC instead of degrading:
$(cat "$WORK/t4a.out")"
elif ! grep -qF "(no tracker configured; add entries by hand)" "$REPO/CHANGELOG.md"; then
    bad "test4a: CHANGELOG.md did not get the placeholder line when no tracker is installed:
$(cat "$REPO/CHANGELOG.md")"
else
    ok "test4a: an unavailable default tracker fetch degrades to the placeholder line, not a failure"
fi

REPO=$(fresh_repo t4b 0.3.0)
set +e
(cd "$REPO" && ./scripts/release.sh patch --tracker-fetch "$STUBS/bad_fetch.sh") >"$WORK/t4b.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 0 ]; then
    bad "test4b (failing --tracker-fetch override): release.sh exited $RC instead of degrading:
$(cat "$WORK/t4b.out")"
elif ! grep -qF "(no tracker configured; add entries by hand)" "$REPO/CHANGELOG.md"; then
    bad "test4b: CHANGELOG.md did not get the placeholder line when the override fails:
$(cat "$REPO/CHANGELOG.md")"
else
    ok "test4b: a failing --tracker-fetch override degrades to the placeholder line, not a failure"
fi

# ---- test 5 (e): CHANGELOG.md is created fresh, with a minimal header,
# when it does not already exist.

REPO=$(fresh_repo t5 0.1.0)
[ ! -f "$REPO/CHANGELOG.md" ] || { bad "test5: fixture already had a CHANGELOG.md — test setup is wrong"; }
(cd "$REPO" && ./scripts/release.sh patch) >"$WORK/t5.out" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
    bad "test5 (fresh CHANGELOG.md): release.sh exited $RC:
$(cat "$WORK/t5.out")"
elif [ ! -f "$REPO/CHANGELOG.md" ]; then
    bad "test5: CHANGELOG.md was not created"
elif [ "$(head -n1 "$REPO/CHANGELOG.md")" != "# Changelog" ]; then
    bad "test5: CHANGELOG.md's first line is not '# Changelog':
$(cat "$REPO/CHANGELOG.md")"
elif ! grep -qF "## [0.1.1]" "$REPO/CHANGELOG.md"; then
    bad "test5: freshly created CHANGELOG.md is missing the new section:
$(cat "$REPO/CHANGELOG.md")"
else
    ok "test5: CHANGELOG.md is created fresh with a minimal header when absent"
fi

# ---- test 6 (f): plugin.json and marketplace.json both get the bumped
# version; marketplace.json GROWS a .version key it did not have before.

REPO=$(fresh_repo t6 0.7.0)
MARKETPLACE_BEFORE=$(jq -r '.plugins[0].version // "MISSING"' "$REPO/.claude-plugin/marketplace.json")
(cd "$REPO" && ./scripts/release.sh minor) >"$WORK/t6.out" 2>&1
RC=$?
PLUGIN_AFTER=$(jq -r '.version' "$REPO/.claude-plugin/plugin.json" 2>/dev/null || echo "MISSING")
MARKETPLACE_AFTER=$(jq -r '.plugins[0].version // "MISSING"' "$REPO/.claude-plugin/marketplace.json" 2>/dev/null || echo "MISSING")
if [ "$RC" -ne 0 ]; then
    bad "test6 (version sync): release.sh exited $RC:
$(cat "$WORK/t6.out")"
elif [ "$MARKETPLACE_BEFORE" != "MISSING" ]; then
    bad "test6: fixture's marketplace.json already had a .version key — test setup is wrong"
elif [ "$PLUGIN_AFTER" != "0.8.0" ]; then
    bad "test6: plugin.json ended up at '$PLUGIN_AFTER', expected '0.8.0'"
elif [ "$MARKETPLACE_AFTER" != "0.8.0" ]; then
    bad "test6: marketplace.json's night-watchman entry ended up at '$MARKETPLACE_AFTER', expected '0.8.0' (key should have been added)"
else
    ok "test6: plugin.json bumped and marketplace.json grows a matching .version key"
fi

# ---- test 7: a dirty working tree refuses the run (exit 2) before any
# write, real-run only (dry-run is exempt by design).

REPO=$(fresh_repo t7 0.1.0)
echo "stray change" >> "$REPO/scripts/release.sh"
BEFORE=$(cat "$REPO/.claude-plugin/plugin.json")
set +e
(cd "$REPO" && ./scripts/release.sh patch) >"$WORK/t7.out" 2>&1
RC=$?
set -e
AFTER=$(cat "$REPO/.claude-plugin/plugin.json")
if [ "$RC" -ne 2 ]; then
    bad "test7 (dirty tree): expected exit 2, got $RC:
$(cat "$WORK/t7.out")"
elif [ "$BEFORE" != "$AFTER" ]; then
    bad "test7: plugin.json changed even though the dirty-tree check should have refused before any write"
else
    ok "test7: a dirty working tree is refused (exit 2) before any write"
fi

# ---- test 8: a malformed .version in plugin.json is refused (exit 2),
# corrupted on purpose so this suite has been observed to fail on bad
# input, not just pass on good input (the name-the-oracle rule).

REPO=$(fresh_repo t8 0.1.0)
write_plugin_json "$REPO" "not-a-version"
(cd "$REPO" && git commit -q -am "corrupt plugin.json for test8")
set +e
(cd "$REPO" && ./scripts/release.sh patch) >"$WORK/t8.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 2 ]; then
    bad "test8 (malformed version): expected exit 2 for .version='not-a-version', got $RC:
$(cat "$WORK/t8.out")"
else
    ok "test8: a malformed .version in plugin.json is refused (exit 2)"
fi

# ---- test 9: a fetch that succeeds with zero tickets gets a distinct
# placeholder from "no tracker configured" — these are different facts
# (tracker answered vs. tracker absent/broken) and must not read the same.

REPO=$(fresh_repo t9 0.5.0)
(cd "$REPO" && ./scripts/release.sh patch --tracker-fetch "$STUBS/empty_fetch.sh") >"$WORK/t9.out" 2>&1
RC=$?
CHANGELOG_CONTENT=$(cat "$REPO/CHANGELOG.md" 2>/dev/null || echo "<missing>")
if [ "$RC" -ne 0 ]; then
    bad "test9 (empty tracker fetch): release.sh exited $RC:
$(cat "$WORK/t9.out")"
elif ! printf '%s' "$CHANGELOG_CONTENT" | grep -qF -- "- (no tickets completed since the last tag)"; then
    bad "test9: CHANGELOG.md did not get the 'no tickets completed' line for a reachable-but-empty tracker:
$CHANGELOG_CONTENT"
elif printf '%s' "$CHANGELOG_CONTENT" | grep -qF -- "no tracker configured"; then
    bad "test9: CHANGELOG.md wrongly used the 'no tracker configured' text for a reachable, empty tracker fetch:
$CHANGELOG_CONTENT"
else
    ok "test9: a reachable tracker fetch with zero tickets is distinguished from no tracker configured"
fi

# ---- test 10: a commit failure part-way through (simulated with a
# failing pre-commit hook) reverts plugin.json/marketplace.json/
# CHANGELOG.md to their pre-run content and creates no tag — the
# rollback_files() path, previously unexercised by this suite.

REPO=$(fresh_repo t10 0.6.0)
mkdir -p "$REPO/.githooks"
cat > "$REPO/.githooks/pre-commit" <<'HOOK'
#!/bin/bash
echo "simulated pre-commit failure" >&2
exit 1
HOOK
chmod +x "$REPO/.githooks/pre-commit"
# Commit the hook file BEFORE pointing hooksPath at it — otherwise this
# very commit would trigger it (core.hooksPath already .../dev/null from
# fresh_repo, so it doesn't fire here).
(cd "$REPO" && git add .githooks && git commit -q -m "add failing pre-commit hook for test10")
(cd "$REPO" && git config core.hooksPath .githooks)
PLUGIN_BEFORE=$(cat "$REPO/.claude-plugin/plugin.json")
MARKETPLACE_BEFORE=$(cat "$REPO/.claude-plugin/marketplace.json")
[ ! -f "$REPO/CHANGELOG.md" ] || bad "test10: fixture already had a CHANGELOG.md — test setup is wrong"
BEFORE_TAGS=$(cd "$REPO" && git tag -l)
set +e
(cd "$REPO" && ./scripts/release.sh patch) >"$WORK/t10.out" 2>&1
RC=$?
set -e
PLUGIN_AFTER=$(cat "$REPO/.claude-plugin/plugin.json")
MARKETPLACE_AFTER=$(cat "$REPO/.claude-plugin/marketplace.json")
STATUS_AFTER=$(cd "$REPO" && git status --porcelain)
AFTER_TAGS=$(cd "$REPO" && git tag -l)
if [ "$RC" -ne 1 ]; then
    bad "test10 (commit-failure rollback): expected exit 1, got $RC:
$(cat "$WORK/t10.out")"
elif [ "$PLUGIN_BEFORE" != "$PLUGIN_AFTER" ]; then
    bad "test10: plugin.json was not reverted after the simulated commit failure"
elif [ "$MARKETPLACE_BEFORE" != "$MARKETPLACE_AFTER" ]; then
    bad "test10: marketplace.json was not reverted after the simulated commit failure"
elif [ -f "$REPO/CHANGELOG.md" ]; then
    bad "test10: freshly-created CHANGELOG.md was not removed after the simulated commit failure"
elif [ "$BEFORE_TAGS" != "$AFTER_TAGS" ]; then
    bad "test10: a tag was created despite the commit failing"
elif [ -n "$STATUS_AFTER" ]; then
    bad "test10: working tree is not clean after rollback:
$STATUS_AFTER"
else
    ok "test10: a failing git commit reverts plugin.json/marketplace.json/CHANGELOG.md and creates no tag"
fi

echo
echo "$PASS passed, $FAIL failed (against: $REL)"
[ "$FAIL" -eq 0 ]
