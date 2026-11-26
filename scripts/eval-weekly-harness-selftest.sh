#!/bin/bash
#
# Selftest for eval-weekly-harness.sh. Structurally offline: the script under
# test runs from a fixture git checkout, with claude and eval-weekly.sh both
# stubbed through EVAL_HARNESS_CLAUDE and EVAL_HARNESS_WEEKLY.
#
# Usage: scripts/eval-weekly-harness-selftest.sh [path-to-eval-weekly-harness.sh]

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="${1:-$HERE/eval-weekly-harness.sh}"
[ -f "$SUT" ] || { echo "cannot read $SUT" >&2; exit 2; }

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

REPO="$WORK/repo"
mkdir -p "$REPO/scripts/lib" "$REPO/.claude-plugin" "$REPO/agents" \
    "$REPO/evals/librarian" "$REPO/evals/trigger-x/fire-1" "$REPO/evals/trigger-x/fire-mm" \
    "$REPO/evals/routing" "$REPO/evals/results"
cp "$SUT" "$REPO/scripts/eval-weekly-harness.sh"
chmod +x "$REPO/scripts/eval-weekly-harness.sh"
cp "$HERE/lib/kit.sh" "$REPO/scripts/lib/kit.sh"
echo '{"name":"night-watchman"}' > "$REPO/.claude-plugin/plugin.json"
echo agent > "$REPO/agents/a.md"
echo gone > "$REPO/agents/deleted.md"
printf 'name: librarian-case\ntags:\n- agent\ngraders: []\n' > "$REPO/evals/librarian/case.yaml"
printf 'name: trigger-x-fire-1\ntags:\n- trigger\n' > "$REPO/evals/trigger-x/fire-1/case.yaml"
printf 'name: trigger-x-fire-mm\ntags:\n- needs-moneymike-skills\n' > "$REPO/evals/trigger-x/fire-mm/case.yaml"
echo 'positive prompts' > "$REPO/evals/routing/cases.txt"
printf 'case\tmean_score\nlibrarian-case\t1.000\n' > "$REPO/evals/results/baseline.tsv"
echo stale > "$REPO/evals/results/old-run.json"
git -C "$REPO" init -q
git -C "$REPO" add -A
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qm fixture
rm "$REPO/agents/deleted.md"
echo untracked > "$REPO/agents/untracked.md"

mkdir -p "$WORK/wo-user" "$WORK/wo-project" "$WORK/mm-user"
echo user > "$WORK/wo-user/marker"
echo project > "$WORK/wo-project/marker"
echo mm > "$WORK/mm-user/marker"

# make_claude FILE JSON — a claude stub whose `plugin list --json` prints JSON.
make_claude() {
    printf '#!/bin/bash\n[ "$*" = "plugin list --json" ] || exit 9\ncat <<'"'"'EOF'"'"'\n%s\nEOF\n' "$2" > "$1"
    chmod +x "$1"
}
FULL='[{"id":"work-order@moneymike-plugins","scope":"project","installPath":"'"$WORK/wo-project"'"},
{"id":"work-order@moneymike-plugins","scope":"user","installPath":"'"$WORK/wo-user"'"},
{"id":"moneymike-skills@moneymike-plugins","scope":"user","installPath":"'"$WORK/mm-user"'"}]'
make_claude "$WORK/claude-full" "$FULL"
make_claude "$WORK/claude-no-wo" '[{"id":"work-order@moneymike-plugins","scope":"project","installPath":"'"$WORK/wo-project"'"}]'
make_claude "$WORK/claude-no-mm" '[{"id":"work-order@moneymike-plugins","scope":"user","installPath":"'"$WORK/wo-user"'"}]'

cat > "$WORK/weekly-stub.sh" <<'EOF'
#!/bin/bash
last="${!#}"
{ printf '%s\n' "$@"; [ -f "$last/evals/results/baseline.tsv" ] && echo HARNESS-PRESENT; } > "$WEEKLY_LOG"
exit 7
EOF

# run_sut CLAUDE_STUB ARGS... — sets RC, OUT and ERR.
run_sut() {
    local stub="$1"
    shift
    set +e
    EVAL_HARNESS_CLAUDE="$stub" EVAL_HARNESS_WEEKLY="$WORK/weekly-stub.sh" WEEKLY_LOG="$WORK/weekly.log" \
        "$REPO/scripts/eval-weekly-harness.sh" "$@" >"$WORK/out" 2>"$WORK/err"
    RC=$?
    set -e
    OUT=$(cat "$WORK/out")
    ERR=$(cat "$WORK/err")
}

H="$WORK/h1/night-watchman"
run_sut "$WORK/claude-full" --build-only "$H"
if [ "$RC" -eq 0 ] && [ "$OUT" = "$H" ]; then
    ok "--build-only builds and prints the directory"
else
    bad "--build-only: rc=$RC out='$OUT' err='$ERR'"
fi

if [ -f "$H/plugins/night-watchman/agents/a.md" ] && [ -f "$H/plugins/night-watchman/.claude-plugin/plugin.json" ] \
    && [ ! -e "$H/plugins/night-watchman/evals" ] && [ ! -e "$H/plugins/night-watchman/agents/untracked.md" ] \
    && [ ! -e "$H/plugins/night-watchman/agents/deleted.md" ]; then
    ok "plugins/night-watchman holds the tracked files present on disk, without evals/ or untracked files"
else
    bad "plugin copy: $(cd "$H/plugins/night-watchman" 2>/dev/null && find . -type f | sort | tr '\n' ' ')"
fi

if [ "$(cat "$H/plugins/work-order/marker" 2>/dev/null)" = user ] && [ "$(cat "$H/plugins/moneymike-skills/marker" 2>/dev/null)" = mm ]; then
    ok "work-order and moneymike-skills come from their user-scope installs, not a project-scope one"
else
    bad "installed plugins: wo='$(cat "$H/plugins/work-order/marker" 2>/dev/null)' mm='$(cat "$H/plugins/moneymike-skills/marker" 2>/dev/null)'"
fi

if [ -f "$H/evals/librarian/case.yaml" ] && [ -f "$H/evals/trigger-x/fire-1/case.yaml" ] \
    && [ ! -e "$H/evals/routing" ] && [ ! -e "$H/evals/results/old-run.json" ] \
    && cmp -s "$REPO/evals/results/baseline.tsv" "$H/evals/results/baseline.tsv"; then
    ok "every case folder and the baseline are copied; folders with no case.yaml and old results are not"
else
    bad "evals copy: $(cd "$H/evals" && find . | sort | tr '\n' ' ')"
fi

want_top=$(printf 'plugins:\n- ../../plugins/night-watchman\n- ../../plugins/work-order')
want_nested=$(printf 'plugins:\n- ../../../plugins/night-watchman\n- ../../../plugins/work-order')
want_mm=$(printf '%s\n- ../../../plugins/moneymike-skills' "$want_nested")
if [ "$(tail -n 3 "$H/evals/librarian/case.yaml")" = "$want_top" ] \
    && [ "$(tail -n 3 "$H/evals/trigger-x/fire-1/case.yaml")" = "$want_nested" ] \
    && [ "$(tail -n 4 "$H/evals/trigger-x/fire-mm/case.yaml")" = "$want_mm" ] \
    && [ "$(head -n 1 "$H/evals/librarian/case.yaml")" = "name: librarian-case" ]; then
    ok "each case.yaml gets a plugins: list at its own depth, moneymike-skills only where tagged"
else
    bad "case patch: top='$(tail -n 3 "$H/evals/librarian/case.yaml")' mm='$(tail -n 4 "$H/evals/trigger-x/fire-mm/case.yaml")'"
fi

run_sut "$WORK/claude-full" --build-only "$H"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"exists and is not empty"* ]]; then
    ok "--build-only refuses a non-empty directory"
else
    bad "non-empty refusal: rc=$RC err='$ERR'"
fi

rm -f "$WORK/weekly.log"
run_sut "$WORK/claude-full" --max-cost-usd 5 --state-dir "$WORK/state"
if [ "$RC" -eq 7 ] && [ -f "$WORK/weekly.log" ] \
    && [ "$(sed -n 1,4p "$WORK/weekly.log")" = "$(printf -- '--max-cost-usd\n5\n--state-dir\n%s' "$WORK/state")" ] \
    && [ "$(basename "$(sed -n 5p "$WORK/weekly.log")")" = night-watchman ] \
    && grep -qx HARNESS-PRESENT "$WORK/weekly.log"; then
    ok "run mode passes every argument through, then the harness named night-watchman, and returns eval-weekly's exit code"
else
    bad "run mode: rc=$RC log='$(cat "$WORK/weekly.log" 2>/dev/null)' err='$ERR'"
fi
harness_used=$(sed -n 5p "$WORK/weekly.log")
if [ -n "$harness_used" ] && [ ! -e "$harness_used" ] && [ -z "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 ! -name 'kit*' -print)" ]; then
    ok "the harness is removed after the run"
else
    bad "harness left behind: '$harness_used' tmp='$(ls -A "$TMPDIR")'"
fi

run_sut "$WORK/claude-no-wo" --build-only "$WORK/h2/night-watchman"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"work-order@moneymike-plugins is not installed at user scope"* ]]; then
    ok "a work-order installed only at project scope is refused by name"
else
    bad "no user-scope work-order: rc=$RC err='$ERR'"
fi

run_sut "$WORK/claude-no-mm" --build-only "$WORK/h3/night-watchman"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"moneymike-skills@moneymike-plugins is not installed"* ]]; then
    ok "a case tagged needs-moneymike-skills with no moneymike-skills installed is refused by name"
else
    bad "missing moneymike-skills: rc=$RC err='$ERR'"
fi

printf 'plugins:\n- ../elsewhere\n' >> "$REPO/evals/librarian/case.yaml"
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -qam "own plugins"
run_sut "$WORK/claude-full" --build-only "$WORK/h4/night-watchman"
if [ "$RC" -eq 1 ] && [[ "$ERR" == *"already has a plugins: list"* ]]; then
    ok "a case.yaml that already lists plugins is refused, not overwritten"
else
    bad "existing plugins: rc=$RC err='$ERR'"
fi

echo
echo "$PASS passed, $FAIL failed (against: $SUT)"
[ "$FAIL" -eq 0 ]
