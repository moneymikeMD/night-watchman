#!/bin/bash
#
# Assertions for herdr-ticket-start.sh's central claim: every path that
# reaches `herdr agent start` carries an explicit `--model`, and every
# refusal (bad model, human/mixed ticket, branch/worktree trap, --dry-run)
# creates nothing — zero `herdr worktree create` / `herdr agent start` /
# `herdr agent prompt` calls.
#
# Isolation: a stub `herdr` on PATH, installed fresh per scratch repo, is
# what every scenario below runs against — never a real binary. A stub
# `jira-api.sh`-shaped wrapper (see herdr-ticket-start.sh's own "JIRA API"
# header section) stands in for the SUT's `--jira-api` dependency; every
# call is logged and JIRA_HOST is pinned to 127.0.0.1 for the whole file,
# with the stub itself refusing any other value — the same two-layer
# isolation land-branch-jira-selftest.sh uses for its own jira mock.
#
# Each scenario builds its own scratch git repo under mktemp -d, with a
# COPY of herdr-ticket-start.sh and lib/kit.sh, plus a per-scenario stub
# jira-api wrapper answering whatever title/executor id the scenario needs
# — never a real Jira issue. Per this plugin's testing-philosophy doc ("a
# scratch git repo is not isolated by default"), every scratch repo pins
# core.hooksPath, commit.gpgsign, gpg.format and user.signingkey to values
# inside itself so it cannot pick up this machine's global git config.
#
# Fail-first discipline (name-the-oracle): before this file is trusted, its
# central assertion is run against a deliberately corrupted copy of
# herdr-ticket-start.sh and confirmed to FAIL specific assertions, then the
# corruption is reverted and this file is confirmed to pass again in full —
# see the ticket's own verify block for the recorded RED/GREEN output.
#
# Never touches a real herdr binary, a real Jira project, or a live host —
# every jira-api call in this file goes to the per-scenario stub, and every
# herdr call goes to the per-scenario stub binary.
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

# Pinned to loopback for the whole file — belt-and-braces alongside the
# stub itself refusing any other value (see install_stub_jira).
export JIRA_HOST=127.0.0.1

# Recorded herdr responses (fixtures/, captured 2026-09-14 on a throwaway
# branch, see fixtures/README.md). `worktree create`: the SUT reads only
# `.result.root_pane.pane_id`. `worktree list`: the recorded shape is kept
# verbatim (main checkout, one linked worktree with an open workspace, one
# with `branch: null`); only the branch NAMES are rewritten so the cases
# below can prove the SUT's branch match is selective rather than
# accidentally matching the first entry.
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

# assert_nonzero <desc> <rc> — the exit code must NOT be 0. Written as an
# explicit if/else (not `[ ... ] && echo ok || echo FAIL`, SC2015) so a
# failure in the "ok" branch's own echo can never silently fall into FAIL.
assert_nonzero() {
    local desc="$1" rc="$2"
    if [ "$rc" != 0 ]; then
        echo "ok: $desc exit code is non-zero ($rc)"
    else
        echo "FAIL: $desc exit code should be non-zero, got 0" >&2
        FAIL=1
    fi
}

# ------------------------------------------------------------------ fixtures

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

# Recorded tracker fixtures the stub replays (read-only; never edited here):
# the live transitions list (transition 21 -> status 3 In Progress) and the
# live HTTP 400 bodies the validators returned.
TRACKER_FIXTURES="$(cd "$HERE/../../tracker/jira/fixtures" && pwd)" || die "cannot find the tracker/jira fixtures directory"
TRANSITIONS_FIXTURE="$TRACKER_FIXTURES/issue.transitions.live.json"
REJECTED_FIXTURE="$TRACKER_FIXTURES/issue.transition.rules-rejected.txt"
[ -r "$TRANSITIONS_FIXTURE" ] || die "cannot read $TRANSITIONS_FIXTURE"
[ -r "$REJECTED_FIXTURE" ] || die "cannot read $REJECTED_FIXTURE"

# install_stub_jira <repo> [executor-id] [title] — write the stub jira-api
# wrapper every scenario's Jira call goes through. Speaks exactly the calls
# herdr-ticket-start.sh makes, matched by a glob on the key:
#   raw GET /issue/<KEY>?fields=summary,status,customfield_10047
#   raw GET /issue/<KEY>/transitions      (replays the recorded fixture)
#   --yes write POST /issue/<KEY>/transitions <json>
#   raw GET /issue/<KEY>?fields=status    (read-back)
# executor-id and title are baked into a sibling conf file:
#   executor-id  10020 (agent, default), 10021 (human), 10022 (mixed), an
#                arbitrary unrecognized id, or "" (customfield_10047 comes
#                back null — the unset case).
#   title        the fields.summary value (default: a fixed scratch title).
# Status is stateful per repo ($repo/jira-status, written by a POST). Env
# vars read at call time:
#   STUB_STATUS_ID=ID       starting status id (default 10009, To Do)
#   STUB_JIRA_FAIL=1        the issue read exits 1 with a 404-shaped message
#   STUB_TRANSITION_FAIL=1  the POST exits 1 with the recorded HTTP 400 body
#   STUB_READBACK_STUCK=1   the POST exits 0 but the status does not move
#   STUB_ORDER_LOG=PATH     also append "jira <argv>" (shared with the herdr
#                           stub, so call ORDER can be asserted)
# Every call is logged to $STUB_JIRA_LOG. Anything else is UNEXPECTED and
# exits 1, so a call this file did not anticipate fails loudly.
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

# install_stub_herdr <repo> — a stub speaking exactly the four subcommands
# herdr-ticket-start.sh calls: `worktree list`, `worktree create`,
# `agent start`, `agent prompt`. Every invocation's argv is appended to
# $STUB_HERDR_LOG (one line per call, newlines in the brief flattened to spaces). Behaviour is driven by
# env vars so the same stub file serves every scenario:
#   STUB_LIST_JSON     canned stdout for `worktree list`
#   STUB_LIST_FAIL=1   `worktree list` exits 1 with a stderr message
#   STUB_LIST_NOISE=1  `worktree list` prints ONE extra benign stderr line
#                       before its JSON, on top of whatever STDOUT it
#                       returns — proves the caller does not merge stderr
#                       into the JSON it parses
#   STUB_CREATE_JSON   canned stdout for `worktree create`
#   STUB_CREATE_FAIL=1 `worktree create` exits 1
#   STUB_START_FAIL=1  `agent start` exits 1
#   STUB_START_TRUST_DIALOG=1
#                      first `agent start` exits 1 with "agent_not_ready:
#                      blocked during startup" on stderr; `agent read
#                      --source visible` then returns the trust-dialog
#                      markers until `agent send-keys <pane> Down Enter` is
#                      logged, after which it returns a plain idle prompt
#                      and `agent wait --until idle` succeeds — models the
#                      fix's happy path
#   STUB_START_NOT_READY_OTHER=1
#                      `agent start` exits 1 with "agent_not_ready: blocked
#                      during startup", but the pane shows no trust dialog
#                      (`agent read` returns a plain idle prompt) — models
#                      an agent_not_ready cause that is not the dialog
#   STUB_PROMPT_FAIL=1 `agent prompt` exits 1 with a generic stub message
#   STUB_PROMPT_STALL=1   `agent prompt` exits 1, stderr carries
#                          "agent_prompt_stalled" (the bounded-wait shape:
#                          an accepted submission that never left its
#                          starting state within herdr's own timeout)
#   STUB_PROMPT_BLOCKED=1 `agent prompt` exits 1, stderr carries
#                          "agent_blocked" (submission rejected outright,
#                          agent already blocked)
#   STUB_PROMPT_TIMEOUT=1 `agent prompt` exits 1, stderr carries "timeout"
#                          (herdr's own --timeout expired before a matching
#                          state was observed)
# Anything else — an unrecognised subcommand pair — logs and exits 99, so a
# call this script did not anticipate fails loudly rather than being
# silently accepted.
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

# call_count <log> <regex> — number of logged calls whose argv line starts
# with <regex> (e.g. "worktree create"). 0, never a grep failure, if the log
# does not exist yet or has no match.
call_count() {
    local log="$1" pattern="$2" n
    [ -f "$log" ] || { printf '0'; return 0; }
    n=$(grep -c -- "^$pattern" "$log" 2>/dev/null) || n=0
    printf '%s' "$n"
}

# run_sut <repo> <ticket-id> [herdr-env] [extra args...] — invoke the
# scratch repo's copy of the SUT with the scratch bin/ prepended to PATH
# (so its stub herdr shadows any real one), from inside the repo, with
# --jira-api pointed at the stub jira wrapper. Prints combined
# stdout+stderr; the caller captures $? via `||`. Passes
# --jira-progress-status ${RUN_SUT_PROGRESS:-3} (the recorded In Progress
# status id) unless RUN_SUT_NO_PROGRESS=1.
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

# ------------------------------------------------------------------ scenarios

# A0 — happy path, default model (sonnet). Asserts: exit 0; exactly one
# worktree create / agent start / agent prompt call each; the logged
# `agent start` argv carries "--model sonnet"; the default default carries
# the BOUNDED wait, not no wait at all.
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

# A3 — --wait passed explicitly restores the old blocking behaviour. Same
# shape as A0: exit code, call counts, the logged `agent prompt` argv
# carrying "--wait --timeout 3600000" with NO --until (a settle-on-idle/
# done/blocked wait, not the bounded default), and stdout still reports
# success.
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

# A4 — --no-wait passed explicitly opts fully out of the bounded default.
# Asserts the logged `agent prompt` argv carries no --wait flag at all
# (symmetric with A0/A3: exit code, call counts, stdout).
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

# A6 — the reverse order: --no-wait then --wait must resolve to the FULL
# wait (--wait --timeout 3600000, no --until), same as A3, proving
# precedence is genuinely last-flag-wins and not just "no-wait always wins".
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

# A2 — stub replays a realistic-shaped worktree-list response (several
# unrelated worktrees present, none matching this branch), proving the SUT
# still creates fresh cleanly against non-empty noise.
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

# B0 — unresolvable model: exit non-zero, no herdr call of any kind (the
# check runs before HERDR_ENV or any herdr invocation).
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

# C0 — human-executor ticket: exit non-zero, zero herdr calls of any kind
# (the executor check runs before the idempotency check, so not even
# `worktree list` is ever called).
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

# C1 — mixed-executor ticket: same shape as C0.
scenario_mixed_executor() {
    local repo log rc
    repo=$(make_repo) || { echo "FAIL: C1 setup (make_repo)" >&2; FAIL=1; return; }
    install_stub_jira "$repo" 10022 "Scratch mixed-executor ticket"
    install_stub_herdr "$repo"
    log="$repo/herdr.log"; : > "$log"

    STUB_HERDR_LOG="$log" run_sut "$repo" PROJ-921 1 >/dev/null 2>&1 && rc=0 || rc=$?

    assert_nonzero "C1" "$rc"
    assert_eq "C1 total herdr calls" "0" "$(wc -l < "$log" | tr -d ' ')"
}

# C2 — unrecognized executor custom-field value (an option id that is none
# of agent=10020/human=10021/mixed=10022): this is a malformed-input case,
# not a refused-but-understood human/mixed ticket, so it must exit 2 ("could
# not evaluate") rather than 1 ("a check failed"). Zero herdr calls of any
# kind, same as C0/C1.
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

# D0 — --dry-run: exit 0, zero worktree create / agent start / agent
# prompt calls (worktree LIST is still expected — the idempotency check
# runs even in a dry run), and the three fully-substituted commands are on
# stdout, model included. The default plan carries the BOUNDED wait, not no
# wait at all.
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

# E0 — idempotent: a workspace is already open on this branch (per
# `worktree list`'s .open_workspace_id). Exit 0, zero create/start/prompt
# calls, message says so.
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

# E1 — worktree exists but has NO open workspace (open_workspace_id is
# absent/null): this is the branch/worktree TRAP, not idempotency — exit
# non-zero, zero create/start/prompt calls.
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

# F0 — herdr not on PATH: exit 2 (could not evaluate). PATH deliberately
# built from only /usr/bin:/bin, excluding both the stub bin/ and any real
# herdr on PATH. The herdr check runs before the Jira read, so no stub
# jira-api wrapper is needed here.
scenario_herdr_missing() {
    local repo rc
    repo=$(make_repo) || { echo "FAIL: F0 setup (make_repo)" >&2; FAIL=1; return; }

    ( cd "$repo/$SUT_REL" && HERDR_ENV=1 PATH="/usr/bin:/bin" ./herdr-ticket-start.sh PROJ-950 --jira-api "$repo/bin/jira-api-stub.sh" --jira-progress-status 3 ) \
        >/dev/null 2>&1 && rc=0 || rc=$?

    assert_eq "F0 exit code is 2 (could not evaluate)" "2" "$rc"
}

# F1 — the Jira issue cannot be read (the stub answers a 404 via
# STUB_JIRA_FAIL): exit 2, zero herdr calls (the Jira read runs before any
# herdr invocation).
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

# G0 — worktree list returns benign stderr noise alongside a valid JSON
# stdout: the SUT must still parse it and proceed cleanly, proving it does
# NOT merge stderr into the JSON it reads (a merge would corrupt it).
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

# I0/I1/I2 — the bounded default wait can fail in three distinct
# herdr-reported shapes (agent_prompt_stalled, agent_blocked, timeout). In
# every case: exit non-zero, and the die message carries herdr's OWN error
# text, not just a generic "failed".
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

# J0 — `agent start` first reports agent_not_ready because the
# pane is showing Claude Code's folder-trust dialog. The SUT must read the
# pane, recognize the dialog markers, send Down+Enter exactly once, wait for
# idle, then continue to the normal prompt/transition steps as if nothing
# had gone wrong. Exit 0, exactly one `agent start`/`agent send-keys`/
# `agent wait`/`agent prompt` call, and a line in stdout saying the dialog
# was answered.
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

# J1 — agent_not_ready for a reason OTHER than the trust dialog (the pane
# shows a plain idle prompt, no dialog markers): the SUT must still abort
# exactly as any other agent-start failure — exit non-zero, zero
# send-keys/wait/prompt calls, herdr's own agent_not_ready text surfaced.
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

# L0..L6 — the lifecycle move: In Progress after the brief
# hand-off, resolved by target status, read back, loud on failure.

EMPTY_LIST='{"id":"cli:worktree:list","result":{"worktrees":[]}}'

# jira_posts <repo> <KEY> — number of transition POSTs the stub logged.
jira_posts() {
    call_count "$1/jira.log" "--yes write POST /issue/$2/transitions"
}

# L0 — happy path: exactly one POST, carrying the transition resolved from
# the recorded fixture (21), logged AFTER `agent prompt`, and the stub's
# status reads back as In Progress.
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
# ticket named, the tracker's own message surfaced, the agent left running
# (one prompt, no teardown call of any kind), status unchanged.
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

# L5 — no --jira-progress-status and no env: refused before any herdr or
# jira call.
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

# B0 — dry-run prints the whole brief: four headings, ticket key, timebox,
# every --forbidden line, tracker line with the jira-api path and project.
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

# B5 — with no flags, [dispatch.brief] timebox/forbidden/cloud_id and
# [tracker.jira] project come from the repo's .night-watchman/config.toml.
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

# ------------------------------------------------------------------------ run

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
scenario_unrecognized_executor
scenario_dry_run
scenario_dry_run_wait
scenario_dry_run_no_wait
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
