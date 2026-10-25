#!/bin/bash
#
# Assertions for the `prime-agent` dispatch provider's three verbs. A fake
# `prime-agent` on PATH serves the responses recorded from a live Prime Agent
# 0.10.1 binary under fixtures/ (see fixtures/README.md); the ticket
# frontmatter the executor gate reads is workflow's recorded set, in
# ../workflow/fixtures/. The fake rewrites only a recorded probe session's
# name and cwd to the scenario's ticket and worktree, so the shape under test
# is verbatim.
#
# Isolation: every scenario gets its own scratch `git init` repo (hooks
# pinned off, signing off), its own state directory and its own fake. The
# environment that would change what is measured (NW_CONFIG, NW_ROOT,
# NW_DRY_RUN, NW_DISPATCH_PRIME_AGENT_STATE) is cleared per run. No daemon is
# reached and no session is created: start never calls prime-agent, and watch
# and stop only ever find the fake.
#
# Fail-first: before this file was trusted it was run against four corrupted
# copies of provider.sh, each in a throwaway copy of providers/ and
# templates/, and each FAILED only the scenarios naming that behaviour:
#
#   the cwd half of the session match dropped        -> W1 only (6)
#   stop by session name instead of the active id    -> S0 only (1)
#   --until ignored, one read and return             -> W2 only (4)
#   `worktree add` with no base ref                  -> T6 only (2)
#
# Usage: ./provider-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise, 2 if the environment makes
# the assertions meaningless.

# shellcheck disable=SC1090  # sourced at a path computed at runtime

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/provider.sh"
FIXTURES="$HERE/fixtures"
TICKETS="$HERE/../workflow/fixtures"
CONFIG_SH="$HERE/../../lib/config.sh"
[ -x "$SUT" ] || { echo "cannot find an executable provider.sh next to this selftest" >&2; exit 2; }
for f in "$FIXTURES/sessions-working.json" "$FIXTURES/sessions-idle.json" \
         "$FIXTURES/sessions-all-archived.json" "$FIXTURES/stop.json" \
         "$FIXTURES/stop-not-live.txt" "$TICKETS/ticket-executor-agent.md" \
         "$TICKETS/ticket-executor-mixed.md" "$TICKETS/ticket-executor-human.md" \
         "$TICKETS/ticket-no-executor.md"; do
    [ -r "$f" ] || { echo "cannot read fixture $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "jq is not on PATH" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is not on PATH" >&2; exit 2; }

FAIL=0
MODEL="anthropic/claude-haiku-4-5"

assert_eq() {
    if [ "$2" != "$3" ]; then
        echo "FAIL: $1 — want [$2] got [$3]" >&2
        FAIL=1
    fi
}

assert_contains() {
    case "$2" in
        *"$3"*) ;;
        *) echo "FAIL: $1 — expected to find [$3] in: $2" >&2; FAIL=1 ;;
    esac
}

exists() { [ -e "$1" ] && echo yes || echo no; }
jf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# scratch — a scratch dir holding a git repo with one commit on main, and a
# fake prime-agent in DIR/bin serving whatever DIR/fake/ holds.
scratch() {
    local d
    d=$(cd "$(mktemp -d)" && pwd -P) || return 1
    mkdir -p "$d/repo" "$d/bin" "$d/fake" "$d/no-hooks" || return 1
    git -c init.defaultBranch=main init -q "$d/repo" >/dev/null 2>&1 || return 1
    (
        cd "$d/repo" || exit 1
        git config user.email "test@example.invalid"
        git config user.name "prime-agent provider selftest"
        git config commit.gpgsign false
        git config core.hooksPath "$d/no-hooks"
        git commit -q --allow-empty -m "base"
    ) >/dev/null 2>&1 || return 1
    cat > "$d/bin/prime-agent" <<'FAKE'
#!/bin/bash
# The fake: `sessions [--all] --json` serves fake/sessions[-all].N for its Nth
# call (the highest N once they run out); `stop` serves the recorded success,
# or the recorded refusal when fake/stop-refuses exists. Every call is logged.
F="$FAKE_PA_DIR"
echo "$*" >> "$F/calls.log"
case "$1" in
    sessions)
        base="$F/sessions"; [ "${2:-}" = --all ] && base="$F/sessions-all"
        n=$(cat "$base.count" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$base.count"
        while [ "$n" -gt 0 ] && [ ! -f "$base.$n" ]; do n=$((n - 1)); done
        [ -f "$base.$n" ] || { echo "fake: no $base.N" >&2; exit 9; }
        cat "$base.$n" ;;
    stop)
        if [ -f "$F/stop-refuses" ]; then cat "$FAKE_PA_FIXTURES/stop-not-live.txt" >&2; exit 1; fi
        cat "$FAKE_PA_FIXTURES/stop.json" ;;
    *) echo "fake: unexpected call: $*" >&2; exit 9 ;;
esac
FAKE
    chmod +x "$d/bin/prime-agent"
    printf '%s' "$d"
}

# serve DIR KIND N FIXTURE PROBE [NAME CWD] — install FIXTURE as the fake's
# Nth KIND (sessions | sessions-all) response, renaming the recorded session
# PROBE to NAME with cwd CWD when given.
serve() {
    local d="$1" kind="$2" n="$3" fixture="$4" probe="$5" name="${6:-}" cwd="${7:-}"
    if [ -n "$name" ]; then
        jq --arg p "$probe" --arg n "$name" --arg c "$cwd" \
            '.sessions |= map(if .sessionName == $p then .sessionName = $n | .cwd = $c else . end)' \
            "$FIXTURES/$fixture" > "$d/fake/$kind.$n"
    else
        cp "$FIXTURES/$fixture" "$d/fake/$kind.$n"
    fi
}

run_sut() {
    local d="$1"; shift
    (
        cd "$d/repo" || exit 9
        unset NW_CONFIG NW_ROOT NW_DRY_RUN
        PATH="$d/bin:$PATH" FAKE_PA_DIR="$d/fake" FAKE_PA_FIXTURES="$FIXTURES" \
            NW_PRIME_AGENT_POLL_S=0.2 NW_DISPATCH_PRIME_AGENT_STATE="$d/state" "$SUT" "$@" 2>&1
    )
}

run_json() {
    local d="$1"; shift
    (
        cd "$d/repo" || exit 9
        unset NW_CONFIG NW_ROOT NW_DRY_RUN
        PATH="$d/bin:$PATH" FAKE_PA_DIR="$d/fake" FAKE_PA_FIXTURES="$FIXTURES" \
            NW_PRIME_AGENT_POLL_S=0.2 NW_DISPATCH_PRIME_AGENT_STATE="$d/state" "$SUT" "$@" 2>/dev/null
    )
}

# started — a scratch with WO-026 started; the worktree is DIR/wt-wo-026.
started() {
    local d
    d=$(scratch) || return 1
    run_json "$d" start WO-026 --executor agent --model "$MODEL" \
        --timebox "3 hours" --forbidden "x" >/dev/null || return 1
    printf '%s' "$d"
}

calls() { local n; n=$(grep -c "^$2" "$1/fake/calls.log" 2>/dev/null) || true; printf '%s' "${n:-0}"; }

GUARD=$(mktemp -d) || { echo "cannot create a scratch dir" >&2; exit 2; }
if ( cd "$GUARD" && unset NW_CONFIG NW_ROOT && . "$CONFIG_SH" && [ -n "$(nw_config_file)" ] ); then
    echo "refusing to run: a .night-watchman/config.toml exists above the temp root $GUARD" >&2
    rm -rf "$GUARD"
    exit 2
fi
rm -rf "$GUARD"

# T0 — the happy path: worktree created from main, journal and brief written,
# and the printed call names the session, cwd and model. start reaches no
# prime-agent at all.
scenario_start_happy() {
    local d out rc brief py
    d=$(scratch) || { echo "FAIL: T0 setup" >&2; FAIL=1; return; }
    out=$(run_json "$d" start WO-026 --ticket-file "$TICKETS/ticket-executor-agent.md" \
        --model "$MODEL" --timebox "3 hours" --forbidden "stay in touches") && rc=0 || rc=$?

    assert_eq "T0 exit code" "0" "$rc"
    assert_eq "T0 the session is named after the lowercased ticket" "wo-026" "$(jf "$out" .session_name)"
    assert_eq "T0 state is requested" "requested" "$(jf "$out" .state)"
    assert_eq "T0 the worktree is a sibling of the repo" "$d/wt-wo-026" "$(jf "$out" .worktree)"
    assert_eq "T0 the worktree exists" "yes" "$(exists "$d/wt-wo-026/.git")"
    assert_eq "T0 the worktree is on the ticket's branch" "wo-026" \
        "$(git -C "$d/wt-wo-026" symbolic-ref --short HEAD 2>/dev/null)"
    assert_eq "T0 the journal was written" "yes" "$(exists "$d/state/wo-026.json")"
    assert_eq "T0 nothing was written inside the worktree" "" \
        "$(git -C "$d/wt-wo-026" status --porcelain 2>/dev/null)"
    py=$(jf "$out" .launch.python)
    assert_eq "T0 the launch call is exact" \
        "await rlm.create_session(prompt=open(\"$d/state/wo-026.brief.md\").read(), name=\"wo-026\", cwd=\"$d/wt-wo-026\", model=\"$MODEL\")" "$py"
    assert_eq "T0 start never called prime-agent" "no" "$(exists "$d/fake/calls.log")"

    brief=$(cat "$d/state/wo-026.brief.md")
    assert_eq "T0 no template placeholder survives" "" "$(printf '%s' "$brief" | grep -o '@[A-Z][A-Z]*@')"
    assert_contains "T0 the brief is this ticket's" "$brief" "WO-026 worker brief"
    assert_contains "T0 the brief names the model" "$brief" "(model: $MODEL)"
    assert_contains "T0 the brief says the worktree already exists" "$brief" "Your working directory is your own worktree, $d/wt-wo-026"
    assert_contains "T0 the brief says no plugin skills or hooks are loaded" "$brief" "## HARNESS"
    assert_eq "T0 an agent ticket has no mixed section" "" "$(printf '%s' "$brief" | grep '## MIXED TICKET')"
    rm -rf "$d"
}

# T1 — --thinking is carried into the call; an off-contract value is refused.
scenario_start_thinking() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T1 setup" >&2; FAIL=1; return; }
    out=$(run_json "$d" start WO-026 --executor agent --model "$MODEL" --thinking low \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T1 exit code" "0" "$rc"
    assert_contains "T1 thinking is passed" "$(jf "$out" .launch.python)" ", thinking=\"low\")"

    out=$(run_sut "$d" start WO-027 --executor agent --model "$MODEL" --thinking extreme \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T1 a bad level exits 1" "1" "$rc"
    assert_contains "T1 the refusal names the levels" "$out" "off, minimal, low, medium, high, xhigh, max"
    assert_eq "T1 no worktree for the refused start" "no" "$(exists "$d/wt-wo-027")"
    rm -rf "$d"
}

# T2 — the model has no default and must be a PROVIDER/MODEL selector.
scenario_start_model() {
    local d out rc m
    d=$(scratch) || { echo "FAIL: T2 setup" >&2; FAIL=1; return; }
    out=$(run_sut "$d" start WO-026 --executor agent --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T2 no model exits 1" "1" "$rc"
    assert_contains "T2 the refusal names both sources" "$out" "[dispatch.prime-agent] model"
    for m in sonnet /claude anthropic/ "anthropic/claude sonnet"; do
        out=$(run_sut "$d" start WO-026 --executor agent --model "$m" \
            --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
        assert_eq "T2 '$m' exits 1" "1" "$rc"
        assert_contains "T2 '$m' is refused as a selector" "$out" "PROVIDER/MODEL"
    done
    out=$(run_json "$d" start WO-026 --executor agent --model "prime-inference/z-ai/glm-5.3" \
        --timebox "3 hours" --forbidden "x" --dry-run) && rc=0 || rc=$?
    assert_eq "T2 a selector with a nested model id is accepted" "0" "$rc"
    assert_eq "T2 nothing was recorded" "no" "$(exists "$d/state")"
    rm -rf "$d"
}

# T3 — the executor gate: human refused, no assertion refused, an unreadable
# executor is exit 2; mixed dispatches with its extra section.
scenario_start_executor() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T3 setup" >&2; FAIL=1; return; }
    out=$(run_sut "$d" start WO-059 --ticket-file "$TICKETS/ticket-executor-human.md" \
        --model "$MODEL" --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T3 human exits 1" "1" "$rc"
    assert_contains "T3 the refusal names the executor" "$out" "executor is 'human'"

    out=$(run_sut "$d" start WO-026 --model "$MODEL" --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T3 no assertion exits 1" "1" "$rc"
    assert_contains "T3 the refusal names --executor agent" "$out" "--executor agent"

    out=$(run_sut "$d" start WO-026 --ticket-file "$TICKETS/ticket-no-executor.md" \
        --model "$MODEL" --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T3 an unreadable executor exits 2" "2" "$rc"
    assert_eq "T3 nothing was recorded or created" "no no" "$(exists "$d/state") $(exists "$d/wt-wo-026")"

    out=$(run_json "$d" start WO-025 --ticket-file "$TICKETS/ticket-executor-mixed.md" \
        --model "$MODEL" --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T3 mixed is dispatched" "0" "$rc"
    assert_contains "T3 mixed gets its section" "$(cat "$d/state/wo-025.brief.md")" "## MIXED TICKET"
    rm -rf "$d"
}

# T4 — --dry-run prints the brief and creates nothing.
scenario_start_dry_run() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T4 setup" >&2; FAIL=1; return; }
    out=$(run_json "$d" start WO-026 --executor agent --model "$MODEL" \
        --timebox "3 hours" --forbidden "x" --dry-run) && rc=0 || rc=$?
    assert_eq "T4 exit code" "0" "$rc"
    assert_eq "T4 the output says it is a dry run" "true not-requested" "$(jf "$out" '"\(.dry_run) \(.state)"')"
    assert_contains "T4 the brief is printed" "$(jf "$out" .brief)" "WO-026 worker brief"
    assert_eq "T4 no state dir, no worktree, no branch" "no no " \
        "$(exists "$d/state") $(exists "$d/wt-wo-026") $(git -C "$d/repo" branch --list wo-026)"
    rm -rf "$d"
}

# T5 — a second start on an open request re-composes nothing; a stopped run
# is refused; a worktree path in the way with no run recorded is refused.
scenario_start_again() {
    local d out rc first
    d=$(scratch) || { echo "FAIL: T5 setup" >&2; FAIL=1; return; }
    first=$(run_json "$d" start WO-026 --executor agent --model "$MODEL" --timebox "3 hours" --forbidden "x")
    out=$(run_json "$d" start WO-026 --executor agent --model "$MODEL" --timebox "9 hours" --forbidden "y") && rc=0 || rc=$?
    assert_eq "T5 a second start exits 0" "0" "$rc"
    assert_contains "T5 it says nothing was re-composed" "$(jf "$out" .note)" "already recorded"
    assert_eq "T5 the recorded request is untouched" "$(jf "$first" .requested_at)" "$(jf "$out" .requested_at)"

    jq '.state = "stopped"' "$d/state/wo-026.json" > "$d/j" && mv "$d/j" "$d/state/wo-026.json"
    out=$(run_sut "$d" start WO-026 --executor agent --model "$MODEL" --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T5 a stopped run is not restarted" "1" "$rc"
    assert_contains "T5 the refusal says how to start over" "$out" "remove"

    mkdir -p "$d/wt-wo-031"
    out=$(run_sut "$d" start WO-031 --executor agent --model "$MODEL" --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T5 a worktree path in the way exits 1" "1" "$rc"
    assert_contains "T5 the refusal names the path" "$out" "$d/wt-wo-031 already exists"
    assert_eq "T5 nothing was recorded for it" "no" "$(exists "$d/state/wo-031.json")"
    rm -rf "$d"
}

# T6 — NWM-144's rule: the worktree is cut from the base, not from whatever
# the shared checkout has checked out; --base overrides; a missing base is 2.
scenario_start_base() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T6 setup" >&2; FAIL=1; return; }
    ( cd "$d/repo" && git checkout -q -b feature && git commit -q --allow-empty -m "in-flight" ) >/dev/null 2>&1

    out=$(run_json "$d" start WO-026 --executor agent --model "$MODEL" --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T6 exit code" "0" "$rc"
    assert_eq "T6 the base is main" "main main" "$(jf "$out" '"\(.base) \(.base_ref)"')"
    assert_eq "T6 the worker branch carries nothing main does not" "" "$(git -C "$d/repo" log --oneline main..wo-026)"
    assert_eq "T6 and sits on main's head" "$(git -C "$d/repo" rev-parse main)" "$(git -C "$d/repo" rev-parse wo-026)"

    out=$(run_json "$d" start WO-027 --executor agent --model "$MODEL" --base feature --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T6 --base feature is honoured" "$(git -C "$d/repo" rev-parse feature)" "$(git -C "$d/repo" rev-parse wo-027)"

    out=$(run_sut "$d" start WO-028 --executor agent --model "$MODEL" --base nope --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T6 a missing base exits 2" "2" "$rc"
    assert_contains "T6 the error names it" "$out" "base branch 'nope'"
    assert_eq "T6 no worktree for it" "no" "$(exists "$d/wt-wo-028")"
    rm -rf "$d"
}

# W0 — watch reads the live session matched by name and cwd, with tokens and
# cost; the unrelated recorded sessions do not match.
scenario_watch_live() {
    local d out rc
    d=$(started) || { echo "FAIL: W0 setup" >&2; FAIL=1; return; }
    serve "$d" sessions 1 sessions-working.json nw-probe-001 wo-026 "$d/wt-wo-026"
    out=$(run_json "$d" watch WO-026) && rc=0 || rc=$?
    assert_eq "W0 exit code" "0" "$rc"
    assert_eq "W0 state is the session's activity" "working" "$(jf "$out" .state)"
    assert_eq "W0 the recorded active id" "b2e69e97ba52" "$(jf "$out" .session.id)"
    assert_eq "W0 the model as a selector" "anthropic/claude-haiku-4-5" "$(jf "$out" .session.model)"
    assert_eq "W0 tokens and cost" "11357 63 0.014510500000000004" \
        "$(jf "$out" '"\(.session.usage.inputTokens) \(.session.usage.outputTokens) \(.session.usage.cost)"')"
    assert_eq "W0 a live match needs no --all read" "0" "$(calls "$d" 'sessions --all')"
    rm -rf "$d"
}

# W1 — the same name in another cwd is not this ticket's session; with no
# match anywhere the state is not-started, and an archived match is archived.
scenario_watch_not_live() {
    local d out
    d=$(started) || { echo "FAIL: W1 setup" >&2; FAIL=1; return; }
    serve "$d" sessions 1 sessions-working.json nw-probe-001 wo-026 "/elsewhere/wt-wo-026"
    serve "$d" sessions-all 1 sessions-all-archived.json nw-probe-001 wo-026 "/elsewhere/wt-wo-026"
    out=$(run_json "$d" watch wo-026)
    assert_eq "W1 another cwd does not match" "not-started" "$(jf "$out" .state)"
    assert_eq "W1 and no session is reported" "null" "$(jf "$out" .session)"

    serve "$d" sessions-all 2 sessions-all-archived.json nw-probe-001 wo-026 "$d/wt-wo-026"
    out=$(run_json "$d" watch wo-026)
    assert_eq "W1 an archived match reports archived" "archived" "$(jf "$out" .state)"
    assert_eq "W1 an archived session's id is its durable id" "01a17417-1cf8-74b0-9e2f-dc30108a27d8" "$(jf "$out" .session.id)"
    assert_eq "W1 its final cost is reported" "0.017229350000000004" "$(jf "$out" .session.usage.cost)"
    assert_eq "W1 an archived record carries no model" "null" "$(jf "$out" .session.model)"
    rm -rf "$d"
}

# W2 — --until polls until the state is reached; --timeout bounds it and
# exits 1 with the last state.
scenario_watch_until() {
    local d out rc
    d=$(started) || { echo "FAIL: W2 setup" >&2; FAIL=1; return; }
    serve "$d" sessions 1 sessions-working.json nw-probe-001 wo-026 "$d/wt-wo-026"
    serve "$d" sessions 3 sessions-idle.json nw-probe-001 wo-026 "$d/wt-wo-026"
    out=$(run_json "$d" watch wo-026 --until idle --timeout 30000) && rc=0 || rc=$?
    assert_eq "W2 exit code" "0" "$rc"
    assert_eq "W2 it returned on idle" "idle" "$(jf "$out" .state)"
    assert_eq "W2 after three reads" "3" "$(calls "$d" 'sessions --json')"

    rm -f "$d/fake/sessions."*
    serve "$d" sessions 1 sessions-working.json nw-probe-001 wo-026 "$d/wt-wo-026"
    out=$(run_json "$d" watch wo-026 --until idle --until archived --timeout 1000) && rc=0 || rc=$?
    assert_eq "W2 a timeout exits 1" "1" "$rc"
    assert_eq "W2 and reports the last state" "working true" "$(jf "$out" '"\(.state) \(.timed_out)"')"

    out=$(run_sut "$d" watch wo-026 --timeout 1000) && rc=0 || rc=$?
    assert_eq "W2 --timeout alone exits 1" "1" "$rc"
    assert_contains "W2 and says why" "$out" "pass --until STATE"
    out=$(run_sut "$d" watch wo-026 --until idle --timeout 1s) && rc=0 || rc=$?
    assert_eq "W2 a non-numeric timeout exits 1" "1" "$rc"
    rm -rf "$d"
}

# W3 — what watch cannot evaluate: no run, a corrupt journal, unparseable
# prime-agent output, two live sessions matching.
scenario_watch_errors() {
    local d out rc
    d=$(started) || { echo "FAIL: W3 setup" >&2; FAIL=1; return; }
    out=$(run_sut "$d" watch WO-404) && rc=0 || rc=$?
    assert_eq "W3 no run exits 1" "1" "$rc"
    assert_contains "W3 and names the ticket" "$out" "no prime-agent dispatch recorded for 'wo-404'"

    printf 'not json\n' > "$d/fake/sessions.1"
    out=$(run_sut "$d" watch wo-026) && rc=0 || rc=$?
    assert_eq "W3 unparseable output exits 2" "2" "$rc"

    # Derived, not recorded: the recorded live session twice under two ids,
    # which is what two orchestrators naming a worker alike would produce.
    serve "$d" sessions 2 sessions-working.json nw-probe-001 wo-026 "$d/wt-wo-026"
    jq '.sessions += [.sessions[] | select(.sessionName == "wo-026") | .id = "000000000000"]' \
        "$d/fake/sessions.2" > "$d/two" && mv "$d/two" "$d/fake/sessions.2"
    out=$(run_sut "$d" watch wo-026) && rc=0 || rc=$?
    assert_eq "W3 two live matches exit 2" "2" "$rc"
    assert_contains "W3 and name both ids" "$out" "b2e69e97ba52, 000000000000"

    cp "$d/state/wo-026.json" "$d/keep"; printf 'nope\n' > "$d/state/wo-026.json"
    out=$(run_sut "$d" watch wo-026) && rc=0 || rc=$?
    assert_eq "W3 a corrupt journal exits 2" "2" "$rc"
    rm -rf "$d"
}

# S0 — stop calls `prime-agent stop` with the matched ACTIVE id and records
# it; a second stop finds nothing live and changes nothing.
scenario_stop() {
    local d out rc first
    d=$(started) || { echo "FAIL: S0 setup" >&2; FAIL=1; return; }
    serve "$d" sessions 1 sessions-idle.json nw-probe-001 wo-026 "$d/wt-wo-026"
    serve "$d" sessions 2 sessions-idle.json nw-probe-001
    serve "$d" sessions-all 1 sessions-all-archived.json nw-probe-001 wo-026 "$d/wt-wo-026"
    first=$(run_json "$d" stop WO-026 --reason "wave cancelled") && rc=0 || rc=$?
    assert_eq "S0 exit code" "0" "$rc"
    assert_eq "S0 the active id was stopped" "1" "$(calls "$d" 'stop b2e69e97ba52 --json')"
    assert_eq "S0 state is stopped" "stopped" "$(jf "$first" .state)"
    assert_eq "S0 the reason is recorded" "wave cancelled" "$(jf "$first" .stop_reason)"
    assert_eq "S0 the journal carries it" "stopped" "$(jf "$(cat "$d/state/wo-026.json")" .state)"
    assert_eq "S0 the stopped session's usage is kept" "34451" "$(jf "$first" .stopped_session.usage.inputTokens)"

    out=$(run_json "$d" stop WO-026 --reason "again") && rc=0 || rc=$?
    assert_eq "S0 a second stop exits 0" "0" "$rc"
    assert_contains "S0 and says so" "$(jf "$out" .note)" "already stopped"
    assert_eq "S0 the first reason survives" "wave cancelled" "$(jf "$out" .stop_reason)"
    assert_eq "S0 prime-agent stop ran once" "1" "$(calls "$d" 'stop ')"
    rm -rf "$d"
}

# S1 — nothing live and nothing recorded as stopped is a refusal; a refused
# `prime-agent stop` is exit 1 and the journal is unchanged.
scenario_stop_refusals() {
    local d out rc
    d=$(started) || { echo "FAIL: S1 setup" >&2; FAIL=1; return; }
    serve "$d" sessions 1 sessions-idle.json nw-probe-001
    serve "$d" sessions-all 1 sessions-all-archived.json nw-probe-001 wo-026 "$d/wt-wo-026"
    out=$(run_sut "$d" stop WO-026) && rc=0 || rc=$?
    assert_eq "S1 nothing live exits 1" "1" "$rc"
    assert_contains "S1 and names the state" "$out" "nothing to stop (state: archived)"
    assert_eq "S1 prime-agent stop was not called" "0" "$(calls "$d" 'stop ')"

    rm -f "$d/fake/sessions."*
    serve "$d" sessions 1 sessions-idle.json nw-probe-001 wo-026 "$d/wt-wo-026"
    touch "$d/fake/stop-refuses"
    out=$(run_sut "$d" stop WO-026) && rc=0 || rc=$?
    assert_eq "S1 a refused stop exits 1" "1" "$rc"
    assert_contains "S1 the CLI's own refusal is shown" "$out" "Unknown active session"
    assert_eq "S1 the journal is unchanged" "requested" "$(jf "$(cat "$d/state/wo-026.json")" .state)"
    rm -rf "$d"
}

# U0 — the contract's error surface, and the resolver reaching this directory.
scenario_usage() {
    local out rc
    out=$("$SUT" 2>&1) && rc=0 || rc=$?
    assert_eq "U0 no verb exits 1" "1" "$rc"
    assert_contains "U0 no verb names the set" "$out" "verbs: start, watch, stop"
    out=$("$SUT" resume 2>&1) && rc=0 || rc=$?
    assert_contains "U0 an unknown verb names the contract" "$out" "contract: start, watch, stop"
    out=$("$SUT" --help 2>&1) && rc=0 || rc=$?
    assert_eq "U0 --help exits 0" "0" "$rc"
    assert_contains "U0 --help says who makes the call" "$out" "TOP-LEVEL Prime Agent session"
    out=$(cd "$HERE" && NW_DISPATCH=prime-agent "$HERE/../../lib/provider.sh" dir dispatch 2>&1)
    assert_eq "U0 NW_DISPATCH=prime-agent resolves here" "$HERE" "$out"
}

scenario_start_happy
scenario_start_thinking
scenario_start_model
scenario_start_executor
scenario_start_dry_run
scenario_start_again
scenario_start_base
scenario_watch_live
scenario_watch_not_live
scenario_watch_until
scenario_watch_errors
scenario_stop
scenario_stop_refusals
scenario_usage

if [ "$FAIL" = 0 ]; then
    echo "OK: all prime-agent dispatch provider assertions passed"
    exit 0
fi
echo "FAILURES ABOVE" >&2
exit 1
