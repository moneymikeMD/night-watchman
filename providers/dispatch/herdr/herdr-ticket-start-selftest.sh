#!/bin/bash
#
# Assertions for herdr-ticket-start.sh's central claim: every path that
# reaches `herdr agent start` carries an explicit `--model`, and every
# refusal (bad model, human ticket, branch/worktree trap, --dry-run) creates
# nothing — zero `herdr worktree create` / `herdr agent start` / `herdr agent
# prompt` calls. A mixed ticket is not a refusal: it dispatches like an
# agent ticket, but its prompt carries the extra Awaiting-Deployment stop
# instruction.
#
# Isolation: a stub `herdr` and a stub `jira-api.sh`-shaped wrapper on PATH,
# installed fresh per scratch repo. Every jira-api and herdr call in this
# file goes to a per-scenario stub — never a real binary, a real Jira
# project, or a live host. JIRA_HOST is pinned to 127.0.0.1 for the whole
# file and the stub itself refuses any other value.
#
# Each scenario builds its own scratch git repo under mktemp -d with a COPY
# of the SUT and lib/kit.sh. Per this plugin's testing-philosophy doc ("a
# scratch git repo is not isolated by default"), every scratch repo pins
# core.hooksPath, commit.gpgsign, gpg.format and user.signingkey to values
# inside itself so it cannot pick up this machine's global git config.
#
# Fail-first discipline (name-the-oracle): before this file is trusted, its
# central assertion is run against a deliberately corrupted copy of the SUT
# and confirmed to FAIL specific assertions, then the corruption is reverted
# and this file is confirmed to pass again in full — see the ticket's own
# verify block for the recorded RED/GREEN output.
#
# Usage: ./herdr-ticket-start-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/kit.sh
. "$HERE/lib/kit.sh"

SUT_SRC="$HERE/herdr-ticket-start.sh"
KIT_SRC="$HERE/lib/kit.sh"
BRIEF_SRC="$HERE/../../../templates/dispatch-brief.md"
CONFIG_SRC="$HERE/../../lib/config.sh"
SUT_REL="providers/dispatch/herdr"
[ -f "$CONFIG_SRC" ] || die "cannot find providers/lib/config.sh"
[ -f "$BRIEF_SRC" ] || die "cannot find templates/dispatch-brief.md"
[ -f "$SUT_SRC" ] || die "cannot find herdr-ticket-start.sh next to this selftest"
[ -f "$KIT_SRC" ] || die "cannot find lib/kit.sh"

# Pinned to loopback, alongside the stub itself refusing any other value.
export JIRA_HOST=127.0.0.1

# Recorded herdr responses (fixtures/, see fixtures/README.md). The `worktree
# list` shape is verbatim; only branch NAMES are rewritten, so the cases prove
# the branch match is selective, not accidentally matching the first entry.
FIXTURES="$HERE/fixtures"
[ -f "$FIXTURES/worktree-create.json" ] || { echo "missing fixture: $FIXTURES/worktree-create.json" >&2; exit 2; }
[ -f "$FIXTURES/worktree-list.json" ] || { echo "missing fixture: $FIXTURES/worktree-list.json" >&2; exit 2; }
CREATE_FIXTURE_JSON=$(cat "$FIXTURES/worktree-create.json")
LIST_FIXTURE_JSON=$(jq -c '
    .result.worktrees |= (to_entries | map(
        if .key == 1 then .value.branch = "some-other-ticket" | .value.open_workspace_id = "w0" | .value.path = "/x/some-other-ticket"
        elif .key == 2 then .value.branch = "another-ticket" | .value.path = "/x/another-ticket" | del(.value.open_workspace_id)
        else .value.path = "/repo" end
        | .value))' "$FIXTURES/worktree-list.json")

FAIL=0
SCRATCH_DIRS=""

# shellcheck disable=SC2329  # called indirectly via kit_on_exit below
cleanup_all() {
    local d
    for d in $SCRATCH_DIRS; do
        rm -rf "$d"
    done
}
kit_on_exit cleanup_all

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

# assert_nonzero <desc> <rc> — explicit if/else, not `[ ] && echo || echo`
# (SC2015): a failure in the "ok" branch's echo must not fall through to FAIL.
assert_nonzero() {
    local desc="$1" rc="$2"
    if [ "$rc" != 0 ]; then
        echo "ok: $desc exit code is non-zero ($rc)"
    else
        echo "FAIL: $desc exit code should be non-zero, got 0" >&2
        FAIL=1
    fi
}

# make_repo — a fresh, self-contained scratch git repo carrying a copy of
# the SUT and lib/kit.sh.
make_repo() {
    local d
    d=$(mktemp -d "${TMPDIR:-/tmp}/herdr-ticket-start-selftest.XXXXXX") || return 1
    SCRATCH_DIRS="$SCRATCH_DIRS $d"
    mkdir -p "$d/$SUT_REL/lib" "$d/providers/lib" "$d/templates" "$d/bin" "$d/.githooks-empty" || return 1
    cp "$SUT_SRC" "$d/$SUT_REL/herdr-ticket-start.sh" || return 1
    chmod +x "$d/$SUT_REL/herdr-ticket-start.sh" || return 1
    cp "$KIT_SRC" "$d/$SUT_REL/lib/kit.sh" || return 1
    cp "$CONFIG_SRC" "$d/providers/lib/config.sh" || return 1
    cp "$BRIEF_SRC" "$d/templates/dispatch-brief.md" || return 1
    git -C "$d" init -q -b main || return 1
    git -C "$d" config core.hooksPath "$d/.githooks-empty" || return 1
    git -C "$d" config commit.gpgsign false || return 1
    git -C "$d" config gpg.format openpgp || return 1
    git -C "$d" config user.signingkey "" || return 1
    git -C "$d" config user.email "selftest@example.invalid" || return 1
    git -C "$d" config user.name "herdr-ticket-start-selftest" || return 1
    printf 'scratch repo for herdr-ticket-start-selftest.sh\n' > "$d/README.md" || return 1
    git -C "$d" add -A || return 1
    git -C "$d" commit -q -m init || return 1
    printf '%s' "$d"
}

# Recorded tracker fixtures the stub replays, never edited here: the live
# transitions list (21 -> status 3) and the live HTTP 400 validator bodies.
TRACKER_FIXTURES="$(cd "$HERE/../../tracker/jira/fixtures" && pwd)" || die "cannot find the tracker/jira fixtures directory"
TRANSITIONS_FIXTURE="$TRACKER_FIXTURES/issue.transitions.live.json"
REJECTED_FIXTURE="$TRACKER_FIXTURES/issue.transition.rules-rejected.txt"
[ -r "$TRANSITIONS_FIXTURE" ] || die "cannot read $TRANSITIONS_FIXTURE"
[ -r "$REJECTED_FIXTURE" ] || die "cannot read $REJECTED_FIXTURE"

# install_stub_jira <repo> [executor-id] [title] — the stub jira-api wrapper,
# answering only the four calls the SUT makes, stateful per repo, logging to
# $STUB_JIRA_LOG, and driven by the STUB_* env vars read in its body below.
install_stub_jira() {
    local repo="$1" executor_id="${2:-10020}" title="${3:-Scratch ticket for herdr-ticket-start-selftest.sh}"
    {
        printf 'EXECUTOR_ID=%q\n' "$executor_id"
        printf 'TITLE=%q\n' "$title"
        printf 'STATE=%q\n' "$repo/jira-status"
        printf 'TRANSITIONS_FIXTURE=%q\n' "$TRANSITIONS_FIXTURE"
        printf 'REJECTED_FIXTURE=%q\n' "$REJECTED_FIXTURE"
    } > "$repo/bin/jira-stub.conf"
    cat > "$repo/bin/jira-api-stub.sh" <<'EOF'
#!/bin/bash
# shellcheck source=/dev/null
. "$(dirname "$0")/jira-stub.conf"
LOG="${STUB_JIRA_LOG:?STUB_JIRA_LOG must be set}"
if [ "${JIRA_HOST:-}" != "127.0.0.1" ]; then
    echo "REFUSED JIRA_HOST=${JIRA_HOST:-<unset>}" >> "$LOG"
    exit 1
fi
echo "$*" >> "$LOG"
[ -n "${STUB_ORDER_LOG:-}" ] && echo "jira $*" >> "$STUB_ORDER_LOG"
status_id() { if [ -f "$STATE" ]; then cat "$STATE"; else printf '%s' "${STUB_STATUS_ID:-10009}"; fi; }
status_name() {
    jq -r --arg s "$1" '[.transitions[] | select(.to.id == $s)][0].to.name // "Unknown"' "$TRANSITIONS_FIXTURE"
}
case "$1 $2 $3" in
    "raw GET "*"?fields=summary,status,customfield_10047")
        if [ "${STUB_JIRA_FAIL:-0}" = 1 ]; then
            echo "stub jira-api: GET failed (HTTP 404)" >&2
            exit 1
        fi
        sid=$(status_id)
        jq -cn --arg t "$TITLE" --arg sid "$sid" --arg sn "$(status_name "$sid")" --arg e "$EXECUTOR_ID" \
            '{fields: {summary: $t, status: {id: $sid, name: $sn},
              customfield_10047: (if $e == "" then null else {id: $e} end)}}'
        ;;
    "raw GET "*"/transitions")
        cat "$TRANSITIONS_FIXTURE"
        ;;
    "raw GET "*"?fields=status")
        sid=$(status_id)
        jq -cn --arg sid "$sid" --arg sn "$(status_name "$sid")" '{fields: {status: {id: $sid, name: $sn}}}'
        ;;
    "--yes write POST")
        if [ "${STUB_TRANSITION_FAIL:-0}" = 1 ]; then
            echo "jira-api: HTTP 400 POST $4" >&2
            awk '/^# --- transition 21/ { getline; print; exit }' "$REJECTED_FIXTURE" >&2
            exit 1
        fi
        [ "${STUB_READBACK_STUCK:-0}" = 1 ] && exit 0
        tid=$(printf '%s' "$5" | jq -r '.transition.id')
        to=$(jq -r --arg t "$tid" '[.transitions[] | select(.id == $t)][0].to.id // empty' "$TRANSITIONS_FIXTURE")
        [ -n "$to" ] || { echo "stub jira-api: unknown transition $tid" >&2; exit 1; }
        printf '%s' "$to" > "$STATE"
        ;;
    *)
        echo "UNEXPECTED $*" >> "$LOG"
        echo "stub jira-api: unexpected call: $*" >&2
        exit 1
        ;;
esac
exit 0
EOF
    chmod +x "$repo/bin/jira-api-stub.sh"
}

# install_stub_herdr <repo> — a stub answering only `worktree list/create` and
# `agent start/prompt`, logging every argv to $STUB_HERDR_LOG and driven by the
# STUB_* env vars read in its body below. Anything else exits 99, failing loudly.
install_stub_herdr() {
    local repo="$1"
    cat > "$repo/bin/herdr" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$(printf '%s' "$*" | tr '\n' ' ')" >> "$STUB_HERDR_LOG"
[ -n "${STUB_ORDER_LOG:-}" ] && printf 'herdr %s\n' "$*" >> "$STUB_ORDER_LOG"
DIALOG_FLAG="$(dirname "$0")/../dialog-answered"
case "$1 $2" in
    "worktree list")
        if [ "${STUB_LIST_FAIL:-0}" = 1 ]; then
            echo "stub herdr: simulated 'worktree list' failure" >&2
            exit 1
        fi
        [ "${STUB_LIST_NOISE:-0}" = 1 ] && echo "stub herdr: benign notice on stderr" >&2
        printf '%s\n' "$STUB_LIST_JSON"
        ;;
    "worktree create")
        if [ "${STUB_CREATE_FAIL:-0}" = 1 ]; then
            echo "stub herdr: simulated 'worktree create' failure" >&2
            exit 1
        fi
        printf '%s\n' "$STUB_CREATE_JSON"
        ;;
    "agent start")
        [ "${STUB_START_FAIL:-0}" = 1 ] && { echo "stub herdr: simulated 'agent start' failure" >&2; exit 1; }
        if [ "${STUB_START_TRUST_DIALOG:-0}" = 1 ] && [ ! -f "$DIALOG_FLAG" ]; then
            echo "agent_not_ready: blocked during startup" >&2
            exit 1
        fi
        if [ "${STUB_START_NOT_READY_OTHER:-0}" = 1 ]; then
            echo "agent_not_ready: blocked during startup" >&2
            exit 1
        fi
        exit 0
        ;;
    "agent read")
        if [ "${STUB_START_TRUST_DIALOG:-0}" = 1 ] && [ ! -f "$DIALOG_FLAG" ]; then
            printf 'Is this a project you created or one you trust?\n> Yes, I trust this folder\n  No\n'
        else
            printf '(idle prompt)\n'
        fi
        ;;
    "agent send-keys")
        [ "${STUB_START_TRUST_DIALOG:-0}" = 1 ] && : > "$DIALOG_FLAG"
        exit 0
        ;;
    "agent wait")
        exit 0
        ;;
    "agent prompt")
        if [ "${STUB_PROMPT_STALL:-0}" = 1 ]; then
            echo "error: agent_prompt_stalled" >&2
            exit 1
        fi
        if [ "${STUB_PROMPT_BLOCKED:-0}" = 1 ]; then
            echo "error: agent_blocked" >&2
            exit 1
        fi
        if [ "${STUB_PROMPT_TIMEOUT:-0}" = 1 ]; then
            echo "error: timeout" >&2
            exit 1
        fi
        [ "${STUB_PROMPT_FAIL:-0}" = 1 ] && { echo "stub herdr: simulated 'agent prompt' failure" >&2; exit 1; }
        echo "matched state: working"
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

# call_count <log> <regex> — logged calls whose argv line starts with <regex>.
# 0, never a grep failure, if the log is missing or has no match.
call_count() {
    local log="$1" pattern="$2" n
    [ -f "$log" ] || { printf '0'; return 0; }
    n=$(grep -c -- "^$pattern" "$log" 2>/dev/null) || n=0
    printf '%s' "$n"
}

# run_sut <repo> <ticket-id> [herdr-env] [args...] — run the scratch copy of the
# SUT with the scratch bin/ first on PATH and --jira-api on the stub, printing
# stdout+stderr. Passes ${RUN_SUT_PROGRESS:-3} unless RUN_SUT_NO_PROGRESS=1.
run_sut() {
    local repo="$1" ticket="$2" herdr_env="$3"; shift 3
    local brief_flags=(--timebox "3 hours" --forbidden "selftest ban")
    [ "${RUN_SUT_NO_BRIEF:-0}" = 1 ] && brief_flags=()
    set -- ${brief_flags[@]+"${brief_flags[@]}"} "$@"
    unset NW_CONFIG NW_ROOT
    if [ "${RUN_SUT_NO_PROGRESS:-0}" = 1 ]; then
        ( cd "$repo/$SUT_REL" && HERDR_ENV="$herdr_env" PATH="$repo/bin:$PATH" \
            STUB_JIRA_LOG="${STUB_JIRA_LOG:-$repo/jira.log}" \
            ./herdr-ticket-start.sh "$ticket" --jira-api "$repo/bin/jira-api-stub.sh" "$@" 2>&1 )
    else
        ( cd "$repo/$SUT_REL" && HERDR_ENV="$herdr_env" PATH="$repo/bin:$PATH" \
            STUB_JIRA_LOG="${STUB_JIRA_LOG:-$repo/jira.log}" \
            ./herdr-ticket-start.sh "$ticket" --jira-api "$repo/bin/jira-api-stub.sh" \
            --jira-progress-status "${RUN_SUT_PROGRESS:-3}" "$@" 2>&1 )
    fi
}

# A0 — happy path, default model (sonnet), with the BOUNDED wait.
scenario_happy_default_model() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: A0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch happy-path ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-900 1) && rc=0 || rc=$?

    assert_eq "A0 exit code" "0" "$rc"
    assert_eq "A0 worktree create calls" "1" "$(call_count "$log" "worktree create")"
    assert_eq "A0 agent start calls" "1" "$(call_count "$log" "agent start")"
    assert_eq "A0 agent prompt calls" "1" "$(call_count "$log" "agent prompt")"
    assert_contains "A0 agent start argv carries --model sonnet" "$(grep '^agent start' "$log" || true)" "--model sonnet"
    assert_contains "A0 agent prompt names the Jira issue key, not a file path" "$(grep '^agent prompt' "$log" || true)" "PROJ-900 worker brief"
    assert_contains "A0 default agent prompt argv carries the bounded wait" "$(grep '^agent prompt' "$log" || true)" "--wait --until working --timeout 60000"
    case "$(grep '^agent prompt' "$log" || true)" in
        *3600000*)
            echo "FAIL: A0 default agent prompt argv must not carry the full 3600000ms wait" >&2
            FAIL=1
            ;;
        *) echo "ok: A0 default agent prompt argv has no 3600000ms wait" ;;
    esac
    assert_contains "A0 stdout reports success" "$out" "started"
}

# A3 — --wait restores the fully-blocking wait: "--wait --timeout 3600000"
# with NO --until (settle on idle/done/blocked), not the bounded default.
scenario_happy_wait_opt_in() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: A3 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch happy-path ticket, --wait"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-903 1 --wait) && rc=0 || rc=$?

    assert_eq "A3 exit code" "0" "$rc"
    assert_eq "A3 worktree create calls" "1" "$(call_count "$log" "worktree create")"
    assert_eq "A3 agent start calls" "1" "$(call_count "$log" "agent start")"
    assert_eq "A3 agent prompt calls" "1" "$(call_count "$log" "agent prompt")"
    assert_contains "A3 agent prompt argv carries --wait --timeout 3600000" "$(grep '^agent prompt' "$log" || true)" "--wait --timeout 3600000"
    case "$(grep '^agent prompt' "$log" || true)" in
        *--until*)
            echo "FAIL: A3 --wait argv must not carry --until (settles on idle/done/blocked)" >&2
            FAIL=1
            ;;
        *) echo "ok: A3 --wait argv has no --until" ;;
    esac
    assert_contains "A3 stdout reports success" "$out" "started"
}

# A4 — --no-wait opts fully out: no --wait flag at all on `agent prompt`.
scenario_happy_no_wait_opt_out() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: A4 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch happy-path ticket, --no-wait"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-904 1 --no-wait) && rc=0 || rc=$?

    assert_eq "A4 exit code" "0" "$rc"
    assert_eq "A4 worktree create calls" "1" "$(call_count "$log" "worktree create")"
    assert_eq "A4 agent start calls" "1" "$(call_count "$log" "agent start")"
    assert_eq "A4 agent prompt calls" "1" "$(call_count "$log" "agent prompt")"
    case "$(grep '^agent prompt' "$log" || true)" in
        *--wait*)
            echo "FAIL: A4 --no-wait argv must not carry --wait" >&2
            FAIL=1
            ;;
        *) echo "ok: A4 --no-wait argv has no --wait" ;;
    esac
    assert_contains "A4 stdout reports success" "$out" "started"
}

# A5 — --wait then --no-wait on the same command line: the LAST one wins,
# so this must behave exactly like A4 (no --wait at all), not like A3.
scenario_wait_then_no_wait_precedence() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: A5 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch precedence ticket, --wait --no-wait"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-905 1 --wait --no-wait >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "A5 exit code" "0" "$rc"
    case "$(grep '^agent prompt' "$log" || true)" in
        *--wait*)
            echo "FAIL: A5 '--wait --no-wait' must resolve to no --wait (last flag wins)" >&2
            FAIL=1
            ;;
        *) echo "ok: A5 '--wait --no-wait' resolves to no --wait (last flag wins)" ;;
    esac
}

# A6 — the reverse order resolves to the FULL wait, proving precedence is
# genuinely last-flag-wins and not just "no-wait always wins".
scenario_no_wait_then_wait_precedence() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: A6 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch precedence ticket, --no-wait --wait"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-906 1 --no-wait --wait >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "A6 exit code" "0" "$rc"
    assert_contains "A6 '--no-wait --wait' resolves to --wait --timeout 3600000 (last flag wins)" "$(grep '^agent prompt' "$log" || true)" "--wait --timeout 3600000"
}

# A1 — happy path, --model opus. Asserts the flag carries the CHOSEN model,
# not a hardcoded default.
scenario_happy_model_opus() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: A1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch happy-path ticket, opus"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-901 1 --model opus >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "A1 exit code" "0" "$rc"
    assert_contains "A1 agent start argv carries --model opus" "$(grep '^agent start' "$log" || true)" "--model opus"
}

# A2 — several unrelated worktrees present, none matching: still creates.
scenario_happy_against_realistic_list() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: A2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch happy-path ticket vs realistic list"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON="$LIST_FIXTURE_JSON" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-902 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "A2 exit code" "0" "$rc"
    assert_eq "A2 worktree create calls" "1" "$(call_count "$log" "worktree create")"
}

# B0 — unresolvable model: refused before HERDR_ENV or any herdr call.
scenario_bad_model() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: B0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch ticket, never reached"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" run_sut "$repo" PROJ-910 1 --model nonsense >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "B0" "$rc"
    assert_eq "B0 worktree create calls" "0" "$(call_count "$log" "worktree create")"
    assert_eq "B0 agent start calls" "0" "$(call_count "$log" "agent start")"
}

# C0 — human executor: zero herdr calls, not even `worktree list`.
scenario_human_executor() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: C0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10021 "Scratch human-executor ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" run_sut "$repo" PROJ-920 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "C0" "$rc"
    assert_eq "C0 total herdr calls" "0" "$(wc -l < "$log" | tr -d ' ')"
}

# C1 — mixed-executor ticket dispatches like an agent ticket (LAB-211): it
# proceeds (not refused), and the prompt handed to `herdr agent prompt`
# carries the Awaiting-Deployment stop instruction.
scenario_mixed_executor() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: C1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10022 "Scratch mixed-executor ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-921 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "C1 exit code" "0" "$rc"
    assert_eq "C1 worktree create calls" "1" "$(call_count "$log" "worktree create")"
    assert_eq "C1 agent start calls" "1" "$(call_count "$log" "agent start")"
    assert_eq "C1 agent prompt calls" "1" "$(call_count "$log" "agent prompt")"
    assert_contains "C1 prompt instructs stopping at Awaiting Deployment" "$(grep '^agent prompt' "$log" || true)" "Awaiting Deployment"
}

# C1b — agent-executor ticket's prompt carries NO Awaiting-Deployment
# section: the addition in C1 is mixed-only, not a blanket brief change.
scenario_agent_executor_prompt_has_no_mixed_section() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: C1b setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch agent-executor ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-923 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "C1b exit code" "0" "$rc"
    case "$(grep '^agent prompt' "$log" || true)" in
        *"Awaiting Deployment"*)
            echo "FAIL: C1b agent-executor prompt must not carry the mixed-only Awaiting Deployment section" >&2
            FAIL=1
            ;;
        *) echo "ok: C1b agent-executor prompt has no Awaiting Deployment section" ;;
    esac
}

# C2 — an unrecognized executor id is malformed input, not a understood
# refusal, so it exits 2 ("could not evaluate"), not 1. Zero herdr calls.
scenario_unrecognized_executor() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: C2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 99999 "Scratch unrecognized-executor ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" run_sut "$repo" PROJ-922 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "C2 exit code is 2 (could not evaluate, not 1)" "2" "$rc"
    assert_eq "C2 total herdr calls" "0" "$(wc -l < "$log" | tr -d ' ')"
}

# D0 — --dry-run: zero create/start/prompt calls, but worktree LIST is still
# expected because the idempotency check runs even in a dry run.
scenario_dry_run() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: D0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch dry-run ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        run_sut "$repo" PROJ-930 1 --model haiku --dry-run) && rc=0 || rc=$?

    assert_eq "D0 exit code" "0" "$rc"
    assert_eq "D0 worktree create calls" "0" "$(call_count "$log" "worktree create")"
    assert_eq "D0 agent start calls" "0" "$(call_count "$log" "agent start")"
    assert_eq "D0 agent prompt calls" "0" "$(call_count "$log" "agent prompt")"
    assert_contains "D0 prints worktree create command" "$out" "herdr worktree create"
    assert_contains "D0 prints branch proj-930" "$out" "--branch \"proj-930\""
    assert_contains "D0 prints agent start command with model" "$out" "-- --model \"haiku\""
    assert_contains "D0 prints agent prompt command" "$out" "herdr agent prompt \"proj-930\""
    assert_contains "D0 states nothing was created" "$out" "Nothing was created"
    assert_contains "D0 default dry-run plan prints the bounded wait" "$out" "--wait --until working --timeout 60000"
    case "$out" in
        *3600000*)
            echo "FAIL: D0 default dry-run plan must not print the full 3600000ms wait" >&2
            FAIL=1
            ;;
        *) echo "ok: D0 default dry-run plan has no 3600000ms wait" ;;
    esac
}

# D1 — --dry-run --wait: the printed step 3 command carries
# --wait --timeout 3600000 and no --until.
scenario_dry_run_wait() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: D1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch dry-run --wait ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        run_sut "$repo" PROJ-931 1 --wait --dry-run) && rc=0 || rc=$?

    assert_eq "D1 exit code" "0" "$rc"
    assert_contains "D1 prints step 3 with --wait --timeout 3600000" "$out" "--wait --timeout 3600000"
    case "$out" in
        *--until*)
            echo "FAIL: D1 --wait dry-run plan must not print --until" >&2
            FAIL=1
            ;;
        *) echo "ok: D1 --wait dry-run plan has no --until" ;;
    esac
}

# D2 — --dry-run --no-wait: the printed step 3 command carries no --wait
# flag at all.
scenario_dry_run_no_wait() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: D2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch dry-run --no-wait ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        run_sut "$repo" PROJ-932 1 --no-wait --dry-run) && rc=0 || rc=$?

    assert_eq "D2 exit code" "0" "$rc"
    case "$out" in
        *--wait*)
            echo "FAIL: D2 --no-wait dry-run plan must not print --wait" >&2
            FAIL=1
            ;;
        *) echo "ok: D2 --no-wait dry-run plan has no --wait" ;;
    esac
}

# D3 — LAB-211's own verify clause: a mixed-executor ticket under --dry-run
# proceeds (exit 0, not refused) and the printed brief instructs the worker
# to stop at Awaiting Deployment.
scenario_dry_run_mixed_executor() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: D3 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10022 "Scratch dry-run mixed-executor ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        run_sut "$repo" PROJ-933 1 --dry-run) && rc=0 || rc=$?

    assert_eq "D3 exit code (mixed dry-run proceeds, not refused)" "0" "$rc"
    assert_contains "D3 printed brief instructs stopping at Awaiting Deployment" "$out" "Awaiting Deployment"
    assert_contains "D3 states nothing was created" "$out" "Nothing was created"
}

# E0 — a workspace already open on this branch: exit 0, nothing created.
scenario_idempotent_existing_workspace() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: E0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch idempotent ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" \
        STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[{"branch":"proj-940","is_linked_worktree":true,"open_workspace_id":"w9","path":"/x"}]}}' \
        run_sut "$repo" PROJ-940 1) && rc=0 || rc=$?

    assert_eq "E0 exit code" "0" "$rc"
    assert_eq "E0 worktree create calls" "0" "$(call_count "$log" "worktree create")"
    assert_eq "E0 agent start calls" "0" "$(call_count "$log" "agent start")"
    assert_contains "E0 states workspace already exists" "$out" "already exists"
}

# E1 — worktree present with open_workspace_id null: the branch/worktree
# TRAP, not idempotency — refused, nothing created.
scenario_worktree_no_open_workspace() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: E1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch worktree-no-workspace ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" \
        STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[{"branch":"proj-941","is_linked_worktree":true,"path":"/x"}]}}' \
        run_sut "$repo" PROJ-941 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "E1" "$rc"
    assert_eq "E1 worktree create calls" "0" "$(call_count "$log" "worktree create")"
}

# E2 — no herdr worktree at all, but a bare local git branch with the same
# name already exists. Exit non-zero, zero create/start/prompt calls.
scenario_bare_branch_trap() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: E2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch bare-branch-trap ticket"
    git -C "$repo" branch proj-942 >/dev/null 2>&1 || die "E2 setup: could not create local branch 'proj-942'"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        run_sut "$repo" PROJ-942 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "E2" "$rc"
    assert_eq "E2 worktree create calls" "0" "$(call_count "$log" "worktree create")"
}

# E3 — ambiguous: more than one worktree entry matches the branch. Exit
# non-zero, zero create calls, refuses to guess.
scenario_ambiguous_match() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: E3 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch ambiguous-match ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" \
        STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[{"branch":"proj-943","is_linked_worktree":true,"open_workspace_id":"w1","path":"/a"},{"branch":"proj-943","is_linked_worktree":true,"open_workspace_id":"w2","path":"/b"}]}}' \
        run_sut "$repo" PROJ-943 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "E3" "$rc"
    assert_eq "E3 worktree create calls" "0" "$(call_count "$log" "worktree create")"
}

# F0 — herdr not on PATH: exit 2. PATH is /usr/bin:/bin only, and the herdr
# check runs before the Jira read, so no stub wrapper is needed.
scenario_herdr_missing() {
    local repo rc
    repo=$(make_repo) || { echo "FAIL: F0 setup (make_repo)" >&2; FAIL=1; return; }

    ( cd "$repo/$SUT_REL" && HERDR_ENV=1 PATH="/usr/bin:/bin" ./herdr-ticket-start.sh PROJ-950 --jira-api "$repo/bin/jira-api-stub.sh" --jira-progress-status 3 ) \
        >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "F0 exit code is 2 (could not evaluate)" "2" "$rc"
}

# F1 — the issue cannot be read: exit 2, zero herdr calls.
scenario_ticket_missing() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: F1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "unreachable"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_JIRA_FAIL=1 run_sut "$repo" PROJ-999 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "F1 exit code is 2 (could not evaluate)" "2" "$rc"
    assert_eq "F1 total herdr calls" "0" "$(wc -l < "$log" | tr -d ' ')"
}

# F2 — the Jira issue's executor custom field is null (customfield unset):
# exit 2.
scenario_ticket_missing_executor() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: F2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" "" "Scratch ticket with an unset executor field"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" run_sut "$repo" PROJ-951 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "F2 exit code is 2 (could not evaluate)" "2" "$rc"
}

# G0 — benign stderr noise alongside valid JSON stdout: the SUT must still
# parse it, proving it does NOT merge stderr into the JSON it reads.
scenario_list_stderr_noise_does_not_corrupt() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: G0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch stderr-noise ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_LIST_NOISE=1 STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" \
        run_sut "$repo" PROJ-960 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "G0 exit code (stderr noise on a successful list must not break it)" "0" "$rc"
    assert_eq "G0 worktree create calls" "1" "$(call_count "$log" "worktree create")"
}

# H0 — a failed `worktree create`: exit non-zero, zero agent start/prompt
# calls.
scenario_create_fails() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: H0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch create-fails ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_FAIL=1 run_sut "$repo" PROJ-970 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "H0" "$rc"
    assert_eq "H0 agent start calls" "0" "$(call_count "$log" "agent start")"
    assert_eq "H0 agent prompt calls" "0" "$(call_count "$log" "agent prompt")"
}

# I0/I1/I2 — the three herdr-reported bounded-wait failures. In every case the
# die message must carry herdr's OWN error text, not a generic "failed".
scenario_prompt_stalled() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: I0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch agent_prompt_stalled ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" STUB_PROMPT_STALL=1 run_sut "$repo" PROJ-980 1) && rc=0 || rc=$?

    assert_nonzero "I0" "$rc"
    assert_contains "I0 die message carries herdr's agent_prompt_stalled text" "$out" "agent_prompt_stalled"
}

scenario_prompt_blocked() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: I1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch agent_blocked ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" STUB_PROMPT_BLOCKED=1 run_sut "$repo" PROJ-981 1) && rc=0 || rc=$?

    assert_nonzero "I1" "$rc"
    assert_contains "I1 die message carries herdr's agent_blocked text" "$out" "agent_blocked"
}

scenario_prompt_timeout() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: I2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch timeout ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON='{"id":"cli:worktree:list","result":{"worktrees":[]}}' \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" STUB_PROMPT_TIMEOUT=1 run_sut "$repo" PROJ-982 1) && rc=0 || rc=$?

    assert_nonzero "I2" "$rc"
    assert_contains "I2 die message carries herdr's timeout text" "$out" "timeout"
}

# J0 — agent_not_ready because the pane shows Claude's folder-trust dialog:
# the SUT reads the pane, sends Down+Enter ONCE, waits for idle, and carries on.
scenario_trust_dialog_answered() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: J0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch trust-dialog ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" STUB_START_TRUST_DIALOG=1 \
        run_sut "$repo" PROJ-1000 1) && rc=0 || rc=$?

    assert_eq "J0 exit code" "0" "$rc"
    assert_eq "J0 agent start calls" "1" "$(call_count "$log" "agent start")"
    assert_eq "J0 agent send-keys calls" "1" "$(call_count "$log" "agent send-keys")"
    assert_contains "J0 agent send-keys argv is Down Enter" "$(grep '^agent send-keys' "$log" || true)" "Down Enter"
    assert_eq "J0 agent wait calls" "1" "$(call_count "$log" "agent wait")"
    assert_contains "J0 agent wait argv waits for idle" "$(grep '^agent wait' "$log" || true)" "--until idle"
    assert_eq "J0 agent prompt calls" "1" "$(call_count "$log" "agent prompt")"
    assert_contains "J0 stdout reports the dialog was answered" "$out" "detected Claude's folder-trust dialog"
    assert_contains "J0 stdout still reports success" "$out" "started"
}

# J1 — agent_not_ready with NO dialog markers: aborts like any other
# agent-start failure, with zero send-keys/wait/prompt calls.
scenario_not_ready_without_dialog() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: J1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch not-ready-without-dialog ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" STUB_START_NOT_READY_OTHER=1 \
        run_sut "$repo" PROJ-1001 1) && rc=0 || rc=$?

    assert_nonzero "J1" "$rc"
    assert_eq "J1 agent send-keys calls" "0" "$(call_count "$log" "agent send-keys")"
    assert_eq "J1 agent wait calls" "0" "$(call_count "$log" "agent wait")"
    assert_eq "J1 agent prompt calls" "0" "$(call_count "$log" "agent prompt")"
    assert_contains "J1 die message carries herdr's agent_not_ready text" "$out" "agent_not_ready"
    assert_contains "J1 die message says no dialog was shown" "$out" "showed no folder-trust dialog"
}

# L0..L6 — the In Progress move after hand-off: resolved by target status,
# read back, loud on failure.

EMPTY_LIST='{"id":"cli:worktree:list","result":{"worktrees":[]}}'

# jira_posts <repo> <KEY> — number of transition POSTs the stub logged.
jira_posts() {
    call_count "$1/jira.log" "--yes write POST /issue/$2/transitions"
}

# L0 — one POST, transition 21 from the fixture, logged AFTER `agent prompt`.
scenario_lifecycle_after_prompt() {
    local repo log order out rc
    repo=$(make_repo) || { echo "FAIL: L0 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch lifecycle ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"
    order="$repo/order.log"; : > "$order"

    out=$(STUB_HERDR_LOG="$log" STUB_ORDER_LOG="$order" STUB_LIST_JSON="$EMPTY_LIST" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-990 1) && rc=0 || rc=$?

    assert_eq "L0 exit code" "0" "$rc"
    assert_eq "L0 transition POSTs" "1" "$(jira_posts "$repo" PROJ-990)"
    assert_contains "L0 POST carries the transition resolved from target status 3" \
        "$(grep -- '--yes write POST' "$repo/jira.log" || true)" '{"transition":{"id":"21"}}'
    assert_eq "L0 POST is logged after agent prompt" "after" \
        "$(awk '/^herdr agent prompt/ { p = NR } /^jira --yes write POST/ { w = NR } END { print (p && w && p < w) ? "after" : "not-after" }' "$order")"
    assert_eq "L0 stub status after the run" "3" "$(cat "$repo/jira-status" 2>/dev/null || echo none)"
    assert_contains "L0 stdout reports the read-back" "$out" "read-back confirms 'In Progress'"
}

# L1 — --dry-run prints the transition and sends nothing; NW_DRY_RUN=1
# without the flag behaves the same.
scenario_lifecycle_dry_run() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: L1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch lifecycle dry-run ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" run_sut "$repo" PROJ-991 1 --dry-run) && rc=0 || rc=$?
    assert_eq "L1 --dry-run exit code" "0" "$rc"
    assert_eq "L1 --dry-run transition POSTs" "0" "$(jira_posts "$repo" PROJ-991)"
    assert_contains "L1 --dry-run prints the In Progress transition" "$out" "'To Do' -> 'In Progress'"
    assert_contains "L1 --dry-run prints the resolved transition body" "$out" '{"transition":{"id":"21"}}'

    out=$(NW_DRY_RUN=1 STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" run_sut "$repo" PROJ-991 1) && rc=0 || rc=$?
    assert_eq "L1 NW_DRY_RUN=1 exit code" "0" "$rc"
    assert_eq "L1 NW_DRY_RUN=1 transition POSTs" "0" "$(jira_posts "$repo" PROJ-991)"
    assert_eq "L1 NW_DRY_RUN=1 worktree create calls" "0" "$(call_count "$log" "worktree create")"
    assert_contains "L1 NW_DRY_RUN=1 prints the plan" "$out" "Nothing was created or sent"
}

# L2 — already In Progress: no transitions read, no POST, still exit 0.
scenario_lifecycle_already_in_progress() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: L2 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch already-in-progress ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_STATUS_ID=3 STUB_LIST_JSON="$EMPTY_LIST" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-992 1) && rc=0 || rc=$?

    assert_eq "L2 exit code" "0" "$rc"
    assert_eq "L2 transition POSTs" "0" "$(jira_posts "$repo" PROJ-992)"
    assert_eq "L2 transitions list reads" "0" "$(call_count "$repo/jira.log" "raw GET /issue/PROJ-992/transitions")"
    assert_eq "L2 agent prompt calls" "1" "$(call_count "$log" "agent prompt")"
    assert_contains "L2 stdout says no transition" "$out" "already 'In Progress'"
}

# L3 — the POST is rejected with the recorded HTTP 400 body: exit 1, the
# tracker's own message surfaced, and the agent LEFT RUNNING (no teardown).
scenario_lifecycle_post_rejected() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: L3 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch rejected-transition ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_TRANSITION_FAIL=1 STUB_LIST_JSON="$EMPTY_LIST" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-993 1) && rc=0 || rc=$?

    assert_eq "L3 exit code" "1" "$rc"
    assert_contains "L3 message names the ticket" "$out" "PROJ-993: the agent is running"
    assert_contains "L3 message carries the recorded 400 body" "$out" "touches is required before work starts"
    assert_eq "L3 agent prompt calls" "1" "$(call_count "$log" "agent prompt")"
    assert_eq "L3 herdr calls beyond list/create/start/prompt" "0" \
        "$(grep -cvE '^(worktree list|worktree create|agent start|agent prompt)' "$log" || true)"
    assert_eq "L3 stub status unchanged" "none" "$(cat "$repo/jira-status" 2>/dev/null || echo none)"
}

# L4 — a 2xx POST whose read-back still shows the old status: exit 1.
scenario_lifecycle_readback_stuck() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: L4 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch stuck-readback ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    out=$(STUB_HERDR_LOG="$log" STUB_READBACK_STUCK=1 STUB_LIST_JSON="$EMPTY_LIST" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-994 1) && rc=0 || rc=$?

    assert_eq "L4 exit code" "1" "$rc"
    assert_contains "L4 message says the read-back disagrees" "$out" "reads back as 'To Do'"
}

# L5 — no --jira-progress-status and no env: refused before any call.
scenario_lifecycle_missing_status_flag() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: L5 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch missing-flag ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    RUN_SUT_NO_PROGRESS=1 HERDR_JIRA_PROGRESS_STATUS='' STUB_HERDR_LOG="$log" \
        run_sut "$repo" PROJ-995 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "L5" "$rc"
    assert_eq "L5 total herdr calls" "0" "$(wc -l < "$log" | tr -d ' ')"
    assert_eq "L5 jira calls" "0" "$(call_count "$repo/jira.log" "")"
}

# L6 — no live transition into the configured status: exit 2, nothing
# created, nothing posted.
scenario_lifecycle_no_matching_transition() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: L6 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch no-matching-transition ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    RUN_SUT_PROGRESS=99999 STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" \
        STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-996 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "L6 exit code is 2 (could not evaluate)" "2" "$rc"
    assert_eq "L6 worktree create calls" "0" "$(call_count "$log" "worktree create")"
    assert_eq "L6 transition POSTs" "0" "$(jira_posts "$repo" PROJ-996)"
}

# B0 — dry-run prints the whole brief, headings and every substitution.
scenario_brief_dry_run() {
    local repo out rc
    repo=$(make_repo) || { echo "FAIL: B0 setup" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch brief ticket"
    install_stub_herdr "$repo"
    : > "$repo/herdr.log"
    out=$(STUB_HERDR_LOG="$repo/herdr.log" STUB_LIST_JSON="$EMPTY_LIST" \
        run_sut "$repo" PROJ-940 1 --timebox "90 minutes" --forbidden "no touching a" --forbidden "no touching b" --dry-run) && rc=0 || rc=$?
    assert_eq "B0 exit code" "0" "$rc"
    assert_contains "B0 TIMEBOX heading" "$out" "## TIMEBOX"
    assert_contains "B0 FORBIDDEN heading" "$out" "## FORBIDDEN"
    assert_contains "B0 REPORT heading" "$out" "## REPORT"
    assert_contains "B0 STANDING heading" "$out" "## STANDING"
    assert_contains "B0 TRACKER heading" "$out" "## TRACKER"
    assert_contains "B0 ticket key" "$out" "PROJ-940 worker brief"
    assert_contains "B0 timebox text" "$out" "90 minutes. On expiry"
    assert_contains "B0 first forbidden" "$out" "- no touching a"
    assert_contains "B0 second forbidden" "$out" "- no touching b"
    assert_contains "B0 tracker jira-api path" "$out" "$repo/bin/jira-api-stub.sh"
    assert_contains "B0 tracker project" "$out" "Jira project PROJ"
    assert_eq "B0 prompt calls" "0" "$(call_count "$repo/herdr.log" "agent prompt")"
}

# B1 — the real prompt carries the rendered brief with no unfilled placeholder.
scenario_brief_sent() {
    local repo log out rc
    repo=$(make_repo) || { echo "FAIL: B1 setup" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch brief sent ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"
    out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" STUB_CREATE_JSON="$CREATE_FIXTURE_JSON" run_sut "$repo" PROJ-941 1) && rc=0 || rc=$?
    assert_eq "B1 exit code" "0" "$rc"
    assert_eq "B1 prompt calls" "1" "$(call_count "$log" "agent prompt")"
    assert_contains "B1 logged prompt has STANDING" "$(cat "$log")" "## STANDING"
    assert_contains "B1 logged prompt has the timebox" "$(cat "$log")" "3 hours"
    case "$(cat "$log")" in
        *@KEY@*|*@TIMEBOX@*|*@FORBIDDEN@*|*@TRACKER@*|*@BRANCH@*|*@MODEL@*)
            echo "FAIL: B1 logged prompt has an unfilled placeholder" >&2; FAIL=1 ;;
        *) echo "ok: B1 no unfilled placeholder" ;;
    esac
}

# B2/B3 — a missing timebox or forbidden dies naming the field before any herdr call.
scenario_brief_missing_field() {
    local repo log out rc field
    for field in timebox forbidden; do
        repo=$(make_repo) || { echo "FAIL: B2 setup" >&2; FAIL=1; return; }
        install_stub_jira "$repo" 10020 "Scratch brief missing ticket"
        install_stub_herdr "$repo"
        log="$repo/herdr.log"; : > "$log"
        if [ "$field" = timebox ]; then
            out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" RUN_SUT_NO_BRIEF=1 run_sut "$repo" PROJ-942 1 --forbidden x) && rc=0 || rc=$?
        else
            out=$(STUB_HERDR_LOG="$log" STUB_LIST_JSON="$EMPTY_LIST" RUN_SUT_NO_BRIEF=1 run_sut "$repo" PROJ-943 1 --timebox "1 hour") && rc=0 || rc=$?
        fi
        assert_eq "B2 $field missing exit code" "1" "$rc"
        assert_contains "B2 $field missing names the field" "$out" "no $(printf '%s' "$field" | tr '[:lower:]' '[:upper:]')"
        assert_eq "B2 $field missing worktree list calls" "0" "$(call_count "$log" "worktree list")"
        assert_eq "B2 $field missing worktree create calls" "0" "$(call_count "$log" "worktree create")"
        assert_eq "B2 $field missing agent start calls" "0" "$(call_count "$log" "agent start")"
        assert_eq "B2 $field missing agent prompt calls" "0" "$(call_count "$log" "agent prompt")"
    done
}

# B5 — with no flags, the brief's values come from the repo's config.toml.
scenario_brief_config_defaults() {
    local repo out rc
    repo=$(make_repo) || { echo "FAIL: B5 setup" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch brief config ticket"
    install_stub_herdr "$repo"
    mkdir -p "$repo/.night-watchman"
    printf '[tracker.jira]\nproject = "CFGP"\n[dispatch.brief]\ntimebox = "45 minutes"\nforbidden = "config ban"\ncloud_id = "cloud-123"\n' > "$repo/.night-watchman/config.toml"
    out=$(STUB_HERDR_LOG="$repo/herdr.log" STUB_LIST_JSON="$EMPTY_LIST" RUN_SUT_NO_BRIEF=1 run_sut "$repo" PROJ-945 1 --dry-run) && rc=0 || rc=$?
    assert_eq "B5 exit code" "0" "$rc"
    assert_contains "B5 config timebox" "$out" "45 minutes. On expiry"
    assert_contains "B5 config forbidden" "$out" "- config ban"
    assert_contains "B5 config project" "$out" "Jira project CFGP"
    assert_contains "B5 config cloud id" "$out" "connector cloud id cloud-123"
}

# B4 — the missing-status refusal names the STATUS id, not the transition id.
scenario_brief_status_hint() {
    local repo out rc
    repo=$(make_repo) || { echo "FAIL: B4 setup" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10020 "Scratch status hint ticket"
    install_stub_herdr "$repo"
    out=$(STUB_HERDR_LOG="$repo/herdr.log" STUB_LIST_JSON="$EMPTY_LIST" RUN_SUT_NO_PROGRESS=1 run_sut "$repo" PROJ-944 1 --dry-run) && rc=0 || rc=$?
    assert_eq "B4 exit code" "1" "$rc"
    assert_contains "B4 names STATUS id" "$out" "STATUS id of In Progress"
    assert_contains "B4 warns off transition id" "$out" "not a transition id"
}

scenario_happy_default_model
scenario_happy_model_opus
scenario_happy_against_realistic_list
scenario_happy_wait_opt_in
scenario_happy_no_wait_opt_out
scenario_wait_then_no_wait_precedence
scenario_no_wait_then_wait_precedence
scenario_bad_model
scenario_human_executor
scenario_mixed_executor
scenario_agent_executor_prompt_has_no_mixed_section
scenario_unrecognized_executor
scenario_dry_run
scenario_dry_run_wait
scenario_dry_run_no_wait
scenario_dry_run_mixed_executor
scenario_idempotent_existing_workspace
scenario_worktree_no_open_workspace
scenario_bare_branch_trap
scenario_ambiguous_match
scenario_herdr_missing
scenario_ticket_missing
scenario_ticket_missing_executor
scenario_list_stderr_noise_does_not_corrupt
scenario_create_fails
scenario_prompt_stalled
scenario_prompt_blocked
scenario_prompt_timeout
scenario_trust_dialog_answered
scenario_not_ready_without_dialog
scenario_lifecycle_after_prompt
scenario_lifecycle_dry_run
scenario_lifecycle_already_in_progress
scenario_lifecycle_post_rejected
scenario_lifecycle_readback_stuck
scenario_lifecycle_missing_status_flag
scenario_lifecycle_no_matching_transition
scenario_brief_dry_run
scenario_brief_sent
scenario_brief_missing_field
scenario_brief_status_hint
scenario_brief_config_defaults

if [ "$FAIL" = 1 ]; then
    echo "herdr-ticket-start-selftest.sh: FAILED" >&2
    exit 1
fi
echo "herdr-ticket-start-selftest.sh: all assertions passed"
exit 0
