#!/bin/bash
#
# Assertions for the `workflow` dispatch provider's three verbs. The ticket
# frontmatter the executor gate reads comes from the real fixtures under
# fixtures/ — see testing-philosophy.md's "fixture provenance" rule and
# fixtures/README.md. This implementation calls no external binary, so there
# is no stub to install and nothing to record responses from.
#
# Isolation: every scenario gets its own scratch `git init` repo and its own
# state directory, and the environment that would change what is measured
# (NW_CONFIG, NW_ROOT, NW_DRY_RUN, NW_DISPATCH_WORKFLOW_STATE) is cleared per
# run. No network, no live host, no credential, nothing written outside the
# scratch directories — start never reaches a tracker, by design.
#
# Fail-first discipline (name-the-oracle): before this file was trusted it was
# run against three deliberately corrupted copies of provider.sh, each in a
# throwaway copy of providers/ and templates/, and each confirmed to FAIL the
# scenarios that name the corrupted behaviour and no others:
#
#   executor gate short-circuited to `agent`  -> T1 only (4 assertions)
#   the --until/--timeout refusal removed     -> W2 only (8 assertions)
#   the journal_write call deleted            -> T0/T8/T9/W0/W2/S0/S2 (20)
#
# The copies were then deleted and this file confirmed to pass again in full.
#
# Usage: ./provider-selftest.sh
# Exit 0 if every assertion passes, 1 otherwise, 2 if the environment makes
# the assertions meaningless.

# shellcheck disable=SC1090  # sourced at a path computed at runtime

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/provider.sh"
FIXTURES="$HERE/fixtures"
CONFIG_SH="$HERE/../../lib/config.sh"
[ -x "$SUT" ] || { echo "cannot find an executable provider.sh next to this selftest" >&2; exit 2; }
for f in "$FIXTURES/ticket-executor-agent.md" "$FIXTURES/ticket-executor-mixed.md" "$FIXTURES/ticket-no-executor.md"; do
    [ -r "$f" ] || { echo "cannot read fixture $f" >&2; exit 2; }
done
command -v jq >/dev/null 2>&1 || { echo "jq is not on PATH" >&2; exit 2; }
command -v git >/dev/null 2>&1 || { echo "git is not on PATH" >&2; exit 2; }

FAIL=0

assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" != "$got" ]; then
        echo "FAIL: $desc — want [$want] got [$got]" >&2
        FAIL=1
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) ;;
        *) echo "FAIL: $desc — expected to find [$needle] in: $haystack" >&2; FAIL=1 ;;
    esac
}

# scratch — a scratch dir holding a git repo with one commit on main.
# The commit is required: start resolves a base branch (NWM-144) and a repo
# with no refs has none. The state directory is NOT created, because
# scenarios that assert nothing was written would not see it.
scratch() {
    local d
    # `pwd -P` because git reports a resolved path: on macOS mktemp hands back
    # /var/... for /private/var/..., and the two would not compare equal.
    d=$(cd "$(mktemp -d)" && pwd -P) || return 1
    mkdir -p "$d/repo" || return 1
    git -c init.defaultBranch=main init -q "$d/repo" >/dev/null 2>&1 || return 1
    (
        cd "$d/repo" || exit 1
        git config user.email "test@example.invalid"
        git config user.name "workflow provider selftest"
        git config commit.gpgsign false
        git commit -q --allow-empty -m "base"
    ) >/dev/null 2>&1 || return 1
    printf '%s' "$d"
}

# scratch_ahead — as scratch, plus a `feature` branch two commits ahead of
# main, left CHECKED OUT. This is the state NWM-144 was found in: the shared
# checkout sitting on somebody else's in-flight branch.
scratch_ahead() {
    local d
    d=$(scratch) || return 1
    (
        cd "$d/repo" || exit 1
        git checkout -q -b feature
        git commit -q --allow-empty -m "in-flight one"
        git commit -q --allow-empty -m "in-flight two"
    ) >/dev/null 2>&1 || return 1
    printf '%s' "$d"
}

# run_sut DIR VERB [ARG...] — the SUT in DIR/repo with DIR/state as its state
# directory, stdout and stderr merged for error-text assertions.
run_sut() {
    local d="$1"; shift
    (
        cd "$d/repo" || exit 9
        unset NW_CONFIG NW_ROOT NW_DRY_RUN
        NW_DISPATCH_WORKFLOW_STATE="$d/state" "$SUT" "$@" 2>&1
    )
}

# run_json DIR VERB [ARG...] — as run_sut, stdout only, for jq assertions.
run_json() {
    local d="$1"; shift
    (
        cd "$d/repo" || exit 9
        unset NW_CONFIG NW_ROOT NW_DRY_RUN
        NW_DISPATCH_WORKFLOW_STATE="$d/state" "$SUT" "$@" 2>/dev/null
    )
}

jf() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

count_matches() {
    local pattern="$1" file="$2" n
    n=$(grep -c "$pattern" "$file" 2>/dev/null) || n=0
    printf '%s' "$n"
}

AGENT_TICKET="$FIXTURES/ticket-executor-agent.md"
MIXED_TICKET="$FIXTURES/ticket-executor-mixed.md"
NOEXEC_TICKET="$FIXTURES/ticket-no-executor.md"

# A config.toml above the scratch root would supply the very brief defaults
# two scenarios assert are missing, so refuse rather than report a pass that
# measured nothing.
GUARD=$(mktemp -d) || { echo "cannot create a scratch dir" >&2; exit 2; }
if ( cd "$GUARD" && unset NW_CONFIG NW_ROOT && . "$CONFIG_SH" && [ -n "$(nw_config_file)" ] ); then
    echo "refusing to run: a .night-watchman/config.toml exists above the temp root $GUARD" >&2
    rm -rf "$GUARD"
    exit 2
fi
rm -rf "$GUARD"

# T0 — happy path: the request is recorded, the brief is composed, and every
# template placeholder is substituted.
scenario_start_happy() {
    local d out rc brief
    d=$(scratch) || { echo "FAIL: T0 setup" >&2; FAIL=1; return; }

    out=$(run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" --model opus \
        --timebox "3 hours" --forbidden "do not touch paths outside touches") && rc=0 || rc=$?

    assert_eq "T0 exit code" "0" "$rc"
    assert_eq "T0 ticket is upper-cased" "WO-026" "$(jf "$out" .ticket)"
    assert_eq "T0 branch is lower-cased" "wo-026" "$(jf "$out" .branch)"
    assert_eq "T0 agent defaults to the branch" "wo-026" "$(jf "$out" .agent)"
    assert_eq "T0 model is carried" "opus" "$(jf "$out" .model)"
    assert_eq "T0 state is requested" "requested" "$(jf "$out" .state)"
    assert_eq "T0 the launch names the tool that must perform it" "Workflow" "$(jf "$out" .launch.tool)"
    assert_eq "T0 the worktree is a sibling of the repo, not the repo" \
        "$d/wt-wo-026" "$(jf "$out" .worktree)"
    assert_eq "T0 the journal was written" "yes" \
        "$( [ -f "$d/state/wo-026.json" ] && echo yes || echo no )"
    assert_eq "T0 the brief was written" "yes" \
        "$( [ -f "$d/state/wo-026.brief.md" ] && echo yes || echo no )"

    brief="$d/state/wo-026.brief.md"
    assert_eq "T0 no template placeholder survives substitution" "0" \
        "$(count_matches '@[A-Z][A-Z]*@' "$brief")"
    assert_contains "T0 the brief is this ticket's" "$(cat "$brief")" "WO-026 worker brief"
    assert_contains "T0 the brief carries the timebox" "$(cat "$brief")" "3 hours"
    assert_contains "T0 the brief tells the agent to make its own worktree" \
        "$(cat "$brief")" "worktree add $d/wt-wo-026 -b wo-026"
    assert_contains "T0 the brief carries the forbidden line" "$(cat "$brief")" \
        "do not touch paths outside touches"
    rm -rf "$d"
}

# T1 — a ticket needing a person is refused, and nothing is recorded.
scenario_start_refuses_non_agent() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T1 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" start WO-025 --ticket-file "$MIXED_TICKET" \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?

    assert_eq "T1 exit code" "1" "$rc"
    assert_contains "T1 the refusal names the executor it read" "$out" "executor is 'mixed'"
    assert_contains "T1 the refusal names the only executor that qualifies" "$out" "only 'agent' tickets"
    assert_eq "T1 nothing was recorded" "no" \
        "$( [ -e "$d/state" ] && echo yes || echo no )"
    rm -rf "$d"
}

# T2 — no executor assertion at all is a refusal, not a default.
scenario_start_requires_an_executor_assertion() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T2 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" start WO-026 --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?

    assert_eq "T2 exit code" "1" "$rc"
    assert_contains "T2 the refusal names both ways to assert it" "$out" "--ticket-file"
    assert_contains "T2 the refusal names the --executor form too" "$out" "--executor agent"
    assert_eq "T2 nothing was recorded" "no" \
        "$( [ -e "$d/state" ] && echo yes || echo no )"
    rm -rf "$d"
}

# T3 — a ticket whose executor cannot be read is exit 2, not a dispatch.
scenario_start_unreadable_executor() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T3 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" start WO-026 --ticket-file "$NOEXEC_TICKET" \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?

    assert_eq "T3 exit code is 2 (could not evaluate, not a plain refusal)" "2" "$rc"
    assert_contains "T3 the error names the missing field" "$out" "no 'executor:' line"

    out=$(run_sut "$d" start WO-026 --ticket-file "$d/nope.md" \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?
    assert_eq "T3 an unreadable ticket file is also exit 2" "2" "$rc"
    assert_contains "T3 the error names the file it could not read" "$out" "cannot read the ticket file"
    rm -rf "$d"
}

# T4 — an off-contract model is a hard refusal, never a fallback.
scenario_start_bad_model() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T4 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" start WO-026 --model gpt --executor agent \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?

    assert_eq "T4 exit code" "1" "$rc"
    assert_contains "T4 the refusal names the legal models" "$out" "sonnet, opus, haiku"
    rm -rf "$d"
}

# T5 — a ticket id that is not PROJ-### is refused before anything is read.
scenario_start_bad_ticket_id() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T5 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" start notaticket --executor agent \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?

    assert_eq "T5 exit code" "1" "$rc"
    assert_contains "T5 the refusal names the expected shape" "$out" "does not look like PROJ-###"
    rm -rf "$d"
}

# T6 — an incomplete brief is refused rather than composed, naming the part
# that is missing. No config exists above the scratch root to supply either.
scenario_start_incomplete_brief() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T6 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" start WO-026 --executor agent --forbidden "x") && rc=0 || rc=$?
    assert_eq "T6 a missing timebox exits 1" "1" "$rc"
    assert_contains "T6 the refusal names TIMEBOX" "$out" "no TIMEBOX"
    assert_contains "T6 the refusal says an incomplete brief is never sent" "$out" \
        "an incomplete brief is never sent"

    out=$(run_sut "$d" start WO-026 --executor agent --timebox "3 hours") && rc=0 || rc=$?
    assert_eq "T6 a missing forbidden list exits 1" "1" "$rc"
    assert_contains "T6 the refusal names FORBIDDEN" "$out" "no FORBIDDEN"
    assert_eq "T6 nothing was recorded" "no" \
        "$( [ -e "$d/state" ] && echo yes || echo no )"
    rm -rf "$d"
}

# T7 — --dry-run prints the whole brief and writes nothing at all.
scenario_start_dry_run() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T7 setup" >&2; FAIL=1; return; }

    out=$(run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x" --dry-run) && rc=0 || rc=$?

    assert_eq "T7 exit code" "0" "$rc"
    assert_eq "T7 the output says it is a dry run" "true" "$(jf "$out" .dry_run)"
    assert_eq "T7 the state is not-requested" "not-requested" "$(jf "$out" .state)"
    assert_contains "T7 the brief is printed in full" "$(jf "$out" .brief)" "WO-026 worker brief"
    assert_eq "T7 the state directory was never created" "no" \
        "$( [ -e "$d/state" ] && echo yes || echo no )"
    rm -rf "$d"
}

# T8 — a second start on an open request re-composes nothing: the recorded
# request is what the orchestrating turn may already have acted on.
scenario_start_is_idempotent() {
    local d first second rc
    d=$(scratch) || { echo "FAIL: T8 setup" >&2; FAIL=1; return; }

    first=$(run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x")
    second=$(run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "9 hours" --forbidden "y") && rc=0 || rc=$?

    assert_eq "T8 the second start exits 0" "0" "$rc"
    assert_contains "T8 the second start says it re-composed nothing" \
        "$(jf "$second" .note)" "already recorded"
    assert_eq "T8 the recorded request is untouched" \
        "$(jf "$first" .requested_at)" "$(jf "$second" .requested_at)"
    assert_contains "T8 the brief on disk is still the first one" \
        "$(cat "$d/state/wo-026.brief.md")" "3 hours"
    rm -rf "$d"
}

# T9 — starting over a stop-requested run refuses and says how to clear it,
# rather than silently reopening a run somebody stopped.
scenario_start_after_stop() {
    local d out rc
    d=$(scratch) || { echo "FAIL: T9 setup" >&2; FAIL=1; return; }

    run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x" >/dev/null
    run_json "$d" stop WO-026 >/dev/null
    out=$(run_sut "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x") && rc=0 || rc=$?

    assert_eq "T9 exit code" "1" "$rc"
    assert_contains "T9 the refusal names the state it found" "$out" "state 'stop-requested'"
    assert_contains "T9 the refusal says how to start over" "$out" "remove"
    rm -rf "$d"
}

# W0 — watch reports the recorded state, stamped with when it was read.
scenario_watch_happy() {
    local d out rc WATCH_STAMP
    d=$(scratch) || { echo "FAIL: W0 setup" >&2; FAIL=1; return; }

    run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x" >/dev/null
    out=$(run_json "$d" watch wo-026) && rc=0 || rc=$?

    assert_eq "W0 exit code" "0" "$rc"
    assert_eq "W0 the recorded state is reported" "requested" "$(jf "$out" .state)"
    WATCH_STAMP=$(jf "$out" .observed_at)
    assert_eq "W0 the read is stamped with a full UTC timestamp" "20" "${#WATCH_STAMP}"
    assert_contains "W0 the stamp is UTC" "$WATCH_STAMP" "Z"
    rm -rf "$d"
}

# W1 — no recorded run is a clear refusal naming the ticket, not an empty
# print a caller could mistake for "running, nothing to report".
scenario_watch_no_run() {
    local d out rc
    d=$(scratch) || { echo "FAIL: W1 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" watch WO-404) && rc=0 || rc=$?

    assert_eq "W1 exit code" "1" "$rc"
    assert_contains "W1 the refusal names the ticket" "$out" "no workflow dispatch recorded for 'wo-404'"
    rm -rf "$d"
}

# W2 — the declared gap: herdr's blocking flags are refused by name, and the
# refusal points at where the gap is written down. The journal is untouched.
scenario_watch_refuses_blocking_flags() {
    local d out rc flag
    d=$(scratch) || { echo "FAIL: W2 setup" >&2; FAIL=1; return; }

    run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x" >/dev/null

    for flag in --until --timeout; do
        out=$(run_sut "$d" watch wo-026 "$flag" working) && rc=0 || rc=$?
        assert_eq "W2 $flag exits 1" "1" "$rc"
        assert_contains "W2 $flag is refused by name" "$out" "'$flag' is not offered"
        assert_contains "W2 $flag refusal says watch does not block" "$out" "does not block"
        assert_contains "W2 $flag refusal points at the declared gap" "$out" "providers/README.md"
    done

    assert_eq "W2 the journal is unchanged by a refused watch" "requested" \
        "$(jf "$(run_json "$d" watch wo-026)" .state)"
    rm -rf "$d"
}

# W3 — a corrupt journal is exit 2, and says how to clear it.
scenario_watch_corrupt_journal() {
    local d out rc
    d=$(scratch) || { echo "FAIL: W3 setup" >&2; FAIL=1; return; }

    run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x" >/dev/null
    printf 'not json at all\n' > "$d/state/wo-026.json"
    out=$(run_sut "$d" watch wo-026) && rc=0 || rc=$?

    assert_eq "W3 exit code is 2" "2" "$rc"
    assert_contains "W3 the error names the corrupt journal" "$out" "not valid JSON"
    rm -rf "$d"
}

# S0 — stop records the request and names the in-process call that honours
# it. Nothing is killed here, and the output says so.
scenario_stop_happy() {
    local d out rc
    d=$(scratch) || { echo "FAIL: S0 setup" >&2; FAIL=1; return; }

    run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x" >/dev/null
    out=$(run_json "$d" stop WO-026 --reason "wave cancelled") && rc=0 || rc=$?

    assert_eq "S0 exit code" "0" "$rc"
    assert_eq "S0 the recorded state is stop-requested" "stop-requested" "$(jf "$out" .state)"
    assert_eq "S0 the stop names the tool that performs it" "TaskStop" "$(jf "$out" .stop.tool)"
    assert_eq "S0 the stop names the agent" "wo-026" "$(jf "$out" .stop.agent)"
    assert_eq "S0 the reason is recorded" "wave cancelled" "$(jf "$out" .stop_reason)"
    assert_eq "S0 the journal on disk carries the new state" "stop-requested" \
        "$(jf "$(cat "$d/state/wo-026.json")" .state)"
    rm -rf "$d"
}

# S1 — stopping a ticket that was never started is a refusal, not a no-op 0.
scenario_stop_no_run() {
    local d out rc
    d=$(scratch) || { echo "FAIL: S1 setup" >&2; FAIL=1; return; }

    out=$(run_sut "$d" stop WO-404) && rc=0 || rc=$?

    assert_eq "S1 exit code" "1" "$rc"
    assert_contains "S1 the refusal says there is nothing to stop" "$out" "nothing to stop"
    rm -rf "$d"
}

# S2 — a second stop does not restamp the first one.
scenario_stop_twice() {
    local d first second rc
    d=$(scratch) || { echo "FAIL: S2 setup" >&2; FAIL=1; return; }

    run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "x" >/dev/null
    first=$(run_json "$d" stop WO-026 --reason "first")
    second=$(run_json "$d" stop WO-026 --reason "second") && rc=0 || rc=$?

    assert_eq "S2 the second stop exits 0" "0" "$rc"
    assert_contains "S2 the second stop says the request is unchanged" \
        "$(jf "$second" .note)" "already requested"
    assert_eq "S2 the first stop's timestamp survives" \
        "$(jf "$first" .stop_requested_at)" "$(jf "$second" .stop_requested_at)"
    assert_eq "S2 the first stop's reason survives" "first" "$(jf "$second" .stop_reason)"
    rm -rf "$d"
}

# U0 — the contract's error surface: an unknown verb and a missing one both
# name the legal set, and each verb names its own usage.
scenario_usage() {
    local out rc
    out=$("$SUT" 2>&1) && rc=0 || rc=$?
    assert_eq "U0 no verb exits 1" "1" "$rc"
    assert_contains "U0 no verb names the verb set" "$out" "verbs: start, watch, stop"

    out=$("$SUT" resume 2>&1) && rc=0 || rc=$?
    assert_eq "U0 an unknown verb exits 1" "1" "$rc"
    assert_contains "U0 an unknown verb names the contract" "$out" "contract: start, watch, stop"

    out=$("$SUT" watch 2>&1) && rc=0 || rc=$?
    assert_eq "U0 watch with no ticket exits 1" "1" "$rc"
    assert_contains "U0 watch with no ticket names usage" "$out" "usage: provider.sh watch"

    out=$("$SUT" stop 2>&1) && rc=0 || rc=$?
    assert_eq "U0 stop with no ticket exits 1" "1" "$rc"
    assert_contains "U0 stop with no ticket names usage" "$out" "usage: provider.sh stop"

    out=$("$SUT" --help 2>&1) && rc=0 || rc=$?
    assert_eq "U0 --help exits 0" "0" "$rc"
    assert_contains "U0 --help documents the three verbs" "$out" "provider.sh start <ticket-id>"
}

# T10 — NWM-144: the brief names the base branch, so the worker's branch is
# cut from the tracked base and not from whatever the shared checkout has
# checked out. Found live dispatching a 24-ticket wave whose checkout sat on
# an unmerged feature branch; every worker branch inherited its commits.
scenario_start_names_the_base() {
    local d out rc brief wt
    d=$(scratch_ahead) || { echo "FAIL: T10 setup" >&2; FAIL=1; return; }

    out=$(run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "none") && rc=0 || rc=$?

    assert_eq "T10 exit code" "0" "$rc"
    assert_eq "T10 the resolved base is reported" "main" "$(jf "$out" .base)"
    assert_eq "T10 the ref the worktree is cut from is reported" "main" "$(jf "$out" .base_ref)"
    assert_contains "T10 the checkout being on another branch is warned about, not silently accepted" \
        "$(jf "$out" .base_warning)" "is on 'feature', not the base 'main'"

    brief="$d/state/wo-026.brief.md"
    assert_contains "T10 the brief's worktree command names the base explicitly" \
        "$(cat "$brief")" "worktree add $d/wt-wo-026 -b wo-026 main"

    # The oracle that matters: run the command the brief actually gives the
    # worker, then ask git where the branch came from.
    wt="$d/wt-wo-026"
    ( cd "$d/repo" && git worktree add "$wt" -b wo-026 main ) >/dev/null 2>&1
    assert_eq "T10 the branch the brief creates has nothing on it that main does not" "" \
        "$( cd "$d/repo" && git log --oneline main..wo-026 2>/dev/null )"
    assert_eq "T10 its merge-base with main IS main's own head" \
        "$( cd "$d/repo" && git rev-parse main )" \
        "$( cd "$d/repo" && git merge-base main wo-026 2>/dev/null )"

    # And the counterfactual, so the assertions above are not vacuous: the
    # old form, with no start-point, inherits the checked-out branch.
    ( cd "$d/repo" && git worktree add "$d/wt-old" -b old-form ) >/dev/null 2>&1
    assert_eq "T10 the old no-start-point form DOES inherit the in-flight commits" "2" \
        "$( cd "$d/repo" && git log --oneline main..old-form 2>/dev/null | wc -l | tr -d ' ' )"
}

# T11 — a base that cannot be resolved stops the run and says which one.
scenario_start_unresolvable_base() {
    local d out rc
    d=$(scratch_ahead) || { echo "FAIL: T11 setup" >&2; FAIL=1; return; }
    ( cd "$d/repo" && git branch -D main ) >/dev/null 2>&1

    out=$(run_sut "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "none") && rc=0 || rc=$?

    assert_eq "T11 a missing base exits 2, not 0" "2" "$rc"
    assert_contains "T11 the error names the base it could not find" "$out" "base branch 'main'"
    assert_eq "T11 nothing was recorded" "no" \
        "$( [ -f "$d/state/wo-026.json" ] && echo yes || echo no )"
    assert_eq "T11 no brief was written" "no" \
        "$( [ -f "$d/state/wo-026.brief.md" ] && echo yes || echo no )"
}

# T12 — --base overrides the resolved default, and a checkout sitting ON the
# base draws no warning.
scenario_start_base_override() {
    local d out rc
    d=$(scratch_ahead) || { echo "FAIL: T12 setup" >&2; FAIL=1; return; }

    out=$(run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" --base feature \
        --timebox "3 hours" --forbidden "none") && rc=0 || rc=$?
    assert_eq "T12 exit code with --base" "0" "$rc"
    assert_eq "T12 --base is what the brief branches from" "feature" "$(jf "$out" .base_ref)"
    assert_contains "T12 the brief carries the overridden base" \
        "$(cat "$d/state/wo-026.brief.md")" "-b wo-026 feature"
    assert_eq "T12 a checkout already on the base draws no warning" "null" \
        "$(jf "$out" .base_warning)"

    d=$(scratch) || { echo "FAIL: T12 setup 2" >&2; FAIL=1; return; }
    out=$(run_json "$d" start WO-026 --ticket-file "$AGENT_TICKET" \
        --timebox "3 hours" --forbidden "none") && rc=0 || rc=$?
    assert_eq "T12 a checkout on main draws no warning" "null" "$(jf "$out" .base_warning)"
}

scenario_start_happy
scenario_start_names_the_base
scenario_start_unresolvable_base
scenario_start_base_override
scenario_start_refuses_non_agent
scenario_start_requires_an_executor_assertion
scenario_start_unreadable_executor
scenario_start_bad_model
scenario_start_bad_ticket_id
scenario_start_incomplete_brief
scenario_start_dry_run
scenario_start_is_idempotent
scenario_start_after_stop
scenario_watch_happy
scenario_watch_no_run
scenario_watch_refuses_blocking_flags
scenario_watch_corrupt_journal
scenario_stop_happy
scenario_stop_no_run
scenario_stop_twice
scenario_usage

if [ "$FAIL" = 0 ]; then
    echo "OK: all workflow dispatch provider assertions passed"
    exit 0
else
    echo "FAILURES ABOVE" >&2
    exit 1
fi
