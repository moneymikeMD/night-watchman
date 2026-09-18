#!/bin/bash
#
# Assertions for herdr-agent-pane.sh: every refusal path (bad --direction,
# HERDR_ENV unset, missing dir, missing herdr/jq, an invalid --name) makes
# zero `herdr pane split` / `herdr agent start` calls, and the happy path
# passes the right argv through to each.
#
# Isolation: a stub `herdr` on PATH, installed fresh per scratch repo, is
# what every scenario runs against — never a real binary or a real pane.
# `jq` is the real system jq (read-only parsing of a fixed stub response),
# except in the one scenario proving `need jq` fires when jq is absent.
#
# Each scenario builds its own scratch git repo under mktemp -d with a COPY
# of the SUT and lib/kit.sh. Per this plugin's testing-philosophy doc ("a
# scratch git repo is not isolated by default"), every scratch repo pins
# core.hooksPath, commit.gpgsign, gpg.format and user.signingkey to values
# inside itself so it cannot pick up this machine's global git config.
#
# Usage: ./herdr-agent-pane-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

SUT_SRC="$HERE/herdr-agent-pane.sh"
KIT_SRC="$HERE/lib/kit.sh"
[ -f "$SUT_SRC" ] || die "cannot find herdr-agent-pane.sh next to this selftest"
[ -f "$KIT_SRC" ] || die "cannot find lib/kit.sh"

FAIL=0
SCRATCH_DIRS=""

# shellcheck disable=SC2329  # called indirectly via the EXIT trap below
cleanup_all() {
    local d
    for d in $SCRATCH_DIRS; do
        rm -rf "$d"
    done
}
trap cleanup_all EXIT

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "ok: $desc"
    else
        echo "FAIL: $desc" >&2
        echo "  want: $want" >&2
        echo "  got:  $got" >&2
        FAIL=1
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok: $desc" ;;
        *)
            echo "FAIL: $desc" >&2
            echo "  wanted to find: $needle" >&2
            echo "  in:" >&2
            printf '%s\n' "$haystack" | sed 's/^/    /' >&2
            FAIL=1
            ;;
    esac
}

assert_nonzero() {
    local desc="$1" rc="$2"
    if [ "$rc" != 0 ]; then
        echo "ok: $desc exit code is non-zero ($rc)"
    else
        echo "FAIL: $desc exit code should be non-zero, got 0" >&2
        FAIL=1
    fi
}

CREATE_FIXTURE_JSON='{"id":"cli:pane:split","result":{"pane":{"pane_id":"pane-1"}}}'
NULL_FIXTURE_JSON='{"id":"cli:pane:split","result":{"pane":{"pane_id":null}}}'

# make_repo — a fresh, self-contained scratch git repo carrying a copy of
# the SUT and lib/kit.sh, plus a work/ directory to pass as --dir.
make_repo() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/herdr-agent-pane-selftest.XXXXXX") || return 1
    SCRATCH_DIRS="$SCRATCH_DIRS $d"
    mkdir -p "$d/lib" "$d/bin" "$d/.githooks-empty" "$d/work/My_Project" || return 1
    cp "$SUT_SRC" "$d/herdr-agent-pane.sh" || return 1
    chmod +x "$d/herdr-agent-pane.sh" || return 1
    cp "$KIT_SRC" "$d/lib/kit.sh" || return 1
    git -C "$d" init -q -b main || return 1
    git -C "$d" config core.hooksPath "$d/.githooks-empty" || return 1
    git -C "$d" config commit.gpgsign false || return 1
    git -C "$d" config gpg.format openpgp || return 1
    git -C "$d" config user.signingkey "" || return 1
    git -C "$d" config user.email "selftest@example.invalid" || return 1
    git -C "$d" config user.name "herdr-agent-pane-selftest" || return 1
    printf 'scratch repo for herdr-agent-pane-selftest.sh\n' > "$d/README.md" || return 1
    git -C "$d" add -A || return 1
    git -C "$d" commit -q -m init || return 1
    printf '%s' "$d"
}

# install_stub_herdr <repo> — a stub speaking only `pane split` and `agent
# start`, logging every argv to $STUB_HERDR_LOG and driven by the STUB_* env
# vars read in its body below. Anything else exits 99, so it fails loudly.
install_stub_herdr() {
    local repo="$1"
    cat > "$repo/bin/herdr" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_HERDR_LOG"
case "$1 $2" in
    "pane split")
        if [ "${STUB_SPLIT_FAIL:-0}" = 1 ]; then
            echo "stub herdr: simulated 'pane split' failure" >&2
            exit 1
        fi
        printf '%s\n' "$STUB_SPLIT_JSON"
        ;;
    "agent start")
        if [ "${STUB_START_FAIL:-0}" = 1 ]; then
            echo "stub herdr: simulated 'agent start' failure" >&2
            exit 1
        fi
        exit 0
        ;;
    *)
        echo "stub herdr: unexpected call: $*" >&2
        exit 99
        ;;
esac
STUBEOF
    chmod +x "$repo/bin/herdr"
}

call_count() {
    local log="$1" pattern="$2" n
    [ -f "$log" ] || { printf '0'; return 0; }
    n=$(grep -c -- "^$pattern" "$log" 2>/dev/null) || n=0
    printf '%s' "$n"
}

# run_sut <repo> <herdr-env> [args...] — run the scratch copy of the SUT with
# the scratch bin/ and a real jq on PATH. Prints stdout+stderr; caller takes $?.
run_sut() {
    local repo="$1" herdr_env="$2"; shift 2
    ( cd "$repo" && HERDR_ENV="$herdr_env" PATH="$repo/bin:$PATH" \
        STUB_HERDR_LOG="${STUB_HERDR_LOG:-$repo/herdr.log}" \
        ./herdr-agent-pane.sh "$@" 2>&1 )
}

# A0 — happy path, defaults.
scenario_A0() {
    local repo log out rc=0
    repo=$(make_repo) || { echo "FAIL: A0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    out=$(STUB_HERDR_LOG="$log" STUB_SPLIT_JSON="$CREATE_FIXTURE_JSON" \
        run_sut "$repo" 1 --dir "$repo/work/My_Project") && rc=0 || rc=$?

    assert_eq "A0 exit code" 0 "$rc"
    assert_eq "A0 exactly one pane split call" 1 "$(call_count "$log" "pane split")"
    assert_eq "A0 exactly one agent start call" 1 "$(call_count "$log" "agent start")"
    assert_contains "A0 split carries --direction right" "$(cat "$log")" "--direction right"
    assert_contains "A0 split carries --cwd" "$(cat "$log")" "--cwd $repo/work/My_Project"
    assert_contains "A0 split carries --no-focus" "$(cat "$log")" "--no-focus"
    assert_contains "A0 start carries derived sanitized name" "$(cat "$log")" "agent start my_project"
    assert_contains "A0 start carries --kind claude" "$(cat "$log")" "--kind claude"
    assert_contains "A0 start carries --pane pane-1" "$(cat "$log")" "--pane pane-1"
    assert_contains "A0 prints confirmation" "$out" "agent my_project (claude) started in pane pane-1"
}

# A1 — explicit --name/--kind/--direction and trailing agent args pass through.
scenario_A1() {
    local repo log out rc=0
    repo=$(make_repo) || { echo "FAIL: A1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    out=$(STUB_HERDR_LOG="$log" STUB_SPLIT_JSON="$CREATE_FIXTURE_JSON" \
        run_sut "$repo" 1 --dir "$repo/work" --name custom-agent --kind opus \
            --direction down -- --resume --model opus) && rc=0 || rc=$?

    assert_eq "A1 exit code" 0 "$rc"
    assert_contains "A1 split carries --direction down" "$(cat "$log")" "--direction down"
    assert_contains "A1 start carries explicit name" "$(cat "$log")" "agent start custom-agent"
    assert_contains "A1 start carries --kind opus" "$(cat "$log")" "--kind opus"
    assert_contains "A1 start carries trailing agent args" "$(cat "$log")" "-- --resume --model opus"
}

# B0 — bad --direction is refused before HERDR_ENV/dir/herdr are checked.
scenario_B0() {
    local repo log rc=0
    repo=$(make_repo) || { echo "FAIL: B0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    STUB_HERDR_LOG="$log" run_sut "$repo" 0 --direction sideways >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B0 bad --direction" "$rc"
    assert_eq "B0 makes zero herdr calls" 0 "$(call_count "$log" ".")"
}

# B1 — HERDR_ENV unset (or not "1") is refused; zero calls.
scenario_B1() {
    local repo log rc=0
    repo=$(make_repo) || { echo "FAIL: B1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    STUB_HERDR_LOG="$log" run_sut "$repo" 0 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B1 HERDR_ENV unset" "$rc"
    assert_eq "B1 makes zero herdr calls" 0 "$(call_count "$log" ".")"
}

# B2 — nonexistent --dir is refused; zero calls.
scenario_B2() {
    local repo log rc=0
    repo=$(make_repo) || { echo "FAIL: B2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    STUB_HERDR_LOG="$log" run_sut "$repo" 1 --dir "$repo/no-such-dir" >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B2 nonexistent --dir" "$rc"
    assert_eq "B2 makes zero herdr calls" 0 "$(call_count "$log" ".")"
}

# B3 — herdr missing from PATH is refused before any call. PATH is scoped to
# the real system PATH minus the scratch bin/, with no stub installed.
scenario_B3() {
    local repo out rc=0
    repo=$(make_repo) || { echo "FAIL: B3 setup (make_repo)" >&2; FAIL=1; return; }

    out=$(cd "$repo" && HERDR_ENV=1 PATH="/usr/bin:/bin" ./herdr-agent-pane.sh --dir "$repo/work" 2>&1) && rc=0 || rc=$?

    assert_nonzero "B3 herdr missing from PATH" "$rc"
    assert_contains "B3 names herdr as the missing command" "$out" "herdr"
}

# B4 — jq missing from PATH is refused (need jq), with herdr present.
scenario_B4() {
    local repo out rc=0
    repo=$(make_repo) || { echo "FAIL: B4 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"

    out=$(cd "$repo" && HERDR_ENV=1 PATH="$repo/bin" ./herdr-agent-pane.sh --dir "$repo/work" 2>&1) && rc=0 || rc=$?

    assert_nonzero "B4 jq missing from PATH" "$rc"
    assert_contains "B4 names jq as the missing command" "$out" "jq"
}

# B5 — an explicit --name failing the regex is refused before any herdr call.
scenario_B5() {
    local repo log rc=0
    repo=$(make_repo) || { echo "FAIL: B5 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    STUB_HERDR_LOG="$log" run_sut "$repo" 1 --dir "$repo/work" --name "Not Valid!" >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B5 invalid --name" "$rc"
    assert_eq "B5 makes zero herdr calls" 0 "$(call_count "$log" ".")"
}

# B6 — a null pane_id from `pane split` is refused; no `agent start` follows.
scenario_B6() {
    local repo log rc=0
    repo=$(make_repo) || { echo "FAIL: B6 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    STUB_HERDR_LOG="$log" STUB_SPLIT_JSON="$NULL_FIXTURE_JSON" \
        run_sut "$repo" 1 --dir "$repo/work" >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B6 null pane_id" "$rc"
    assert_eq "B6 makes zero agent start calls" 0 "$(call_count "$log" "agent start")"
}

# B7 — `pane split` failing outright is refused; zero agent start calls.
scenario_B7() {
    local repo log rc=0
    repo=$(make_repo) || { echo "FAIL: B7 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    STUB_HERDR_LOG="$log" STUB_SPLIT_FAIL=1 \
        run_sut "$repo" 1 --dir "$repo/work" >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B7 pane split failure" "$rc"
    assert_eq "B7 makes zero agent start calls" 0 "$(call_count "$log" "agent start")"
}

# B8 — `agent start` failing outright is refused.
scenario_B8() {
    local repo log rc=0
    repo=$(make_repo) || { echo "FAIL: B8 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_herdr "$repo"
    log="$repo/herdr.log"

    STUB_HERDR_LOG="$log" STUB_SPLIT_JSON="$CREATE_FIXTURE_JSON" STUB_START_FAIL=1 \
        run_sut "$repo" 1 --dir "$repo/work" >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B8 agent start failure" "$rc"
}

scenario_A0
scenario_A1
scenario_B0
scenario_B1
scenario_B2
scenario_B3
scenario_B4
scenario_B5
scenario_B6
scenario_B7
scenario_B8

if [ "$FAIL" = 0 ]; then
    echo "All assertions passed."
    exit 0
else
    echo "One or more assertions FAILED." >&2
    exit 1
fi
