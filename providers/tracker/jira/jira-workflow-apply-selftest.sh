#!/bin/bash
#
# Selftest for jira-workflow-apply.sh. Runs entirely against a fake
# `jira-api.sh`-shaped stub — never the real wrapper, never a real Jira
# site, never a real credential. The isolation is structural: this script
# only ever talks to a wrapper it is handed, and the stub refuses to be
# anything else. $ISSUES_JIRA_API is unset below so the one case that
# exercises its absence cannot fall through to a real wrapper on a machine
# that exports it.
#
# Fixtures under fixtures/ are real bodies captured live, except the few
# labelled SYNTHETIC or derived at their point of use. See each fixture's
# own header for the command that produced it.
#
# Usage: ./jira-workflow-apply-selftest.sh

unset ISSUES_JIRA_API

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/jira-workflow-apply.sh"
FIXDIR="$HERE/fixtures"

FAIL=0

check() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "ok   - $desc" ;;
        *) echo "FAIL - $desc (missing: $needle)"; FAIL=1 ;;
    esac
}
check_not() {
    local desc="$1" haystack="$2" needle="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL - $desc (unexpectedly present: $needle)"; FAIL=1 ;;
        *) echo "ok   - $desc" ;;
    esac
}
assert_eq() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (want: $want, got: $got)"
        FAIL=1
    fi
}
assert_nonzero() {
    local desc="$1" rc="$2"
    if [ "$rc" != "0" ]; then
        echo "ok   - $desc (rc=$rc)"
    else
        echo "FAIL - $desc (exited 0)"
        FAIL=1
    fi
}
assert_nonempty() {
    local desc="$1" f="$2"
    if [ -s "$f" ]; then
        echo "ok   - $desc"
    else
        echo "FAIL - $desc (empty — the stub was never reached, this test proves nothing)"
        FAIL=1
    fi
}

TMPD=$(mktemp -d) || { echo "FAIL - could not create scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMPD"' EXIT

# The strip point is computed from the file, never a hardcoded line count,
# so a re-recording with a different header cannot shift the JSON body.
strip_fixture_header() {
    awk '/^#/{next} /^HTTP [0-9]+$/{next} {print}' "$1"
}
NWM_WORKFLOW="$TMPD/nwm-workflow.json"
strip_fixture_header "$FIXDIR/workflow.search.nwm.txt" > "$NWM_WORKFLOW"
LAB_WORKFLOW="$TMPD/lab-workflow.json"
strip_fixture_header "$FIXDIR/workflow.search.lab.txt" > "$LAB_WORKFLOW"
STATUSES_SEARCH="$TMPD/statuses-search.json"
strip_fixture_header "$FIXDIR/statuses.search.txt" > "$STATUSES_SEARCH"
# The --show-secrets capture, not the older redacted one: real
# ruleKey/permissionKey values let section 1 assert passthrough byte for byte.
NWM_BULKGET="$TMPD/nwm-bulkget.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.nwm-secrets.txt" > "$NWM_BULKGET"
VALIDATION_SUCCESS="$TMPD/validation-success.json"
strip_fixture_header "$FIXDIR/workflows.update.validation.nwm.txt" > "$VALIDATION_SUCCESS"
VALIDATION_REJECTED="$TMPD/validation-rejected.json"
strip_fixture_header "$FIXDIR/workflows.update.validation.spk4-rejected-idless.txt" > "$VALIDATION_REJECTED"
VALIDATION_WARNINGS_ONLY="$TMPD/validation-warnings-only.json"
strip_fixture_header "$FIXDIR/workflows.update.validation.spk4-warnings-only.txt" > "$VALIDATION_WARNINGS_ONLY"

# SYNTHETIC — a transport-level failure of /validation itself. A valid
# envelope always returns 200, errors inside the body, so this is unreachable live.
VALIDATION_TRANSPORT_FAILURE="$TMPD/validation-transport-failure.json"
echo '{"errorMessages":["synthetic: malformed envelope, never actually produced by this script"]}' > "$VALIDATION_TRANSPORT_FAILURE"

# SYNTHETIC — a 2xx with no `errors` key at all. Never observed live.
VALIDATION_NO_ERRORS_KEY="$TMPD/validation-no-errors-key.json"
echo '{"acknowledged":true}' > "$VALIDATION_NO_ERRORS_KEY"

# DERIVED from the real fixture above, transition 11's `actions` emptied —
# the shape found live on SPK4. Served as the post-write re-read only.
NWM_BULKGET_STRIPPED="$TMPD/nwm-bulkget-stripped.json"
jq '.workflows[0].transitions |= map(if .id == "11" then .actions = [] else . end)' \
    "$NWM_BULKGET" > "$NWM_BULKGET_STRIPPED"

# The REAL before/after pair from the ZZPROBE apply: transition 1's
# validator uuid regenerated on write, the numeric action ids did not.
ZZPROBE_WORKFLOW="$TMPD/zzprobe-workflow.json"
strip_fixture_header "$FIXDIR/workflow.search.zzprobe.txt" > "$ZZPROBE_WORKFLOW"
ZZPROBE_BEFORE="$TMPD/zzprobe-before.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.zzprobe-secrets-before-apply.txt" > "$ZZPROBE_BEFORE"
ZZPROBE_AFTER="$TMPD/zzprobe-after.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.zzprobe-secrets-after-apply.txt" > "$ZZPROBE_AFTER"

# DERIVED from the real after-fixture: transition 1's validator ruleKey
# changed, not just its id — the rule's real identity, so the diff must catch it.
ZZPROBE_AFTER_RULEKEY_CHANGED="$TMPD/zzprobe-after-rulekey-changed.json"
jq '.workflows[0].transitions |= map(if .id == "1" then .validators[0].ruleKey = "system:some-other-validator" else . end)' \
    "$ZZPROBE_AFTER" > "$ZZPROBE_AFTER_RULEKEY_CHANGED"

# --rules: REAL captures from the SPK4 rules rehearsal. The committed
# workflow-rules.json is the spec under test.
FIELD_LIST="$TMPD/field-list.json"
strip_fixture_header "$FIXDIR/field.list.txt" > "$FIELD_LIST"
SPK4_WORKFLOW="$TMPD/spk4-workflow.json"
strip_fixture_header "$FIXDIR/workflow.search.spk4.txt" > "$SPK4_WORKFLOW"
SPK4_RULES_BEFORE="$TMPD/spk4-rules-before.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.spk4-rules-before.txt" > "$SPK4_RULES_BEFORE"
SPK4_RULES_AFTER="$TMPD/spk4-rules-after.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.spk4-rules-after.txt" > "$SPK4_RULES_AFTER"
SPK4_PROBE3_REQUEST="$TMPD/spk4-probe3-request.json"
awk '/^# --- RESPONSE/ {exit} f && !/^#/ {print} /^# --- REQUEST/ {f=1}' \
    "$FIXDIR/workflows.update.validation.spk4-rules-probe-3.txt" > "$SPK4_PROBE3_REQUEST"
SPK4_PROBE3_RESPONSE="$TMPD/spk4-probe3-response.json"
awk 'f && !/^#/ {print} /^# --- RESPONSE/ {f=1}' \
    "$FIXDIR/workflows.update.validation.spk4-rules-probe-3.txt" > "$SPK4_PROBE3_RESPONSE"
RULES_SPEC="$HERE/workflow-rules.json"

# Derived from the REAL after-fixture: transition 81 without its
# previous-status rule, as if only that one rule were missing.
SPK4_RULES_PARTIAL="$TMPD/spk4-rules-partial.json"
jq '.workflows[0].transitions |= map(if .id == "81" then .validators |= map(select(.ruleKey != "system:previous-status-validator")) else . end)' \
    "$SPK4_RULES_AFTER" > "$SPK4_RULES_PARTIAL"
# DERIVED: transition 21's touches rule under a different field id — same
# ruleKey, different parameters, so a different rule.
SPK4_RULES_OTHER_PARAMS="$TMPD/spk4-rules-other-params.json"
jq '.workflows[0].transitions |= map(if .id == "21" then .validators |= map(if .parameters.fieldsRequired == "customfield_10043" then .parameters.fieldsRequired = "customfield_10047" else . end) else . end)' \
    "$SPK4_RULES_AFTER" > "$SPK4_RULES_OTHER_PARAMS"
RULES_SPEC_BADFIELD="$TMPD/rules-badfield.json"
jq '.transitions[0].validators[0].parameters.fieldsRequired = "{field:no such field}"' "$RULES_SPEC" > "$RULES_SPEC_BADFIELD"
RULES_SPEC_NESTED_UNKNOWN="$TMPD/rules-nested-unknown.json"
jq '.transitions[0].validators[0].parameters.fieldsRequired = ["{field:no such nested field}"]' "$RULES_SPEC" > "$RULES_SPEC_NESTED_UNKNOWN"
RULES_SPEC_TYPO="$TMPD/rules-typo.json"
jq '.transitions[0].validators[0].parameters.fieldsRequired = "{Field:verify}"' "$RULES_SPEC" > "$RULES_SPEC_TYPO"
RULES_SPEC_BADTRANSITION="$TMPD/rules-badtransition.json"
jq '.transitions[0].name = "In Progres"' "$RULES_SPEC" > "$RULES_SPEC_BADTRANSITION"

# --restore-from's two sources: the REAL pre-fix redacted document for the
# refusal path, the --show-secrets fixture above for the happy path.
RESTORE_FROM_REDACTED="$TMPD/restore-from-redacted.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.nwm.txt" > "$RESTORE_FROM_REDACTED"
RESTORE_FROM_CLEAN="$NWM_BULKGET"

# LAB's REAL workflow stands in for a successful post-write re-read of
# NWM: it already carries all 9 targets, and read_workflow only checks
# `.total >= 1`, never that the returned object's name is the one asked for.
WORKFLOW_COMPLETE="$LAB_WORKFLOW"

# DERIVED from the fixture above with "Deferred" removed, as if the write
# had silently dropped one addition — assert_readback's failing branch.
WORKFLOW_STILL_MISSING_DEFERRED="$TMPD/workflow-still-missing-deferred.json"
jq '.values[0].statuses |= map(select(.name != "Deferred")) | .values[0].transitions |= map(select(.name != "Deferred"))' \
    "$WORKFLOW_COMPLETE" > "$WORKFLOW_STILL_MISSING_DEFERRED"

# DERIVED from NWM's real workflow with one extra transition fabricated
# under target id 51 but a different name.
WORKFLOW_ID_COLLISION="$TMPD/workflow-id-collision.json"
jq '.values[0].transitions += [{"id": "51", "name": "Some Unrelated Transition", "description": "", "from": [], "to": "10009", "type": "global"}]' \
    "$NWM_WORKFLOW" > "$WORKFLOW_ID_COLLISION"

# make_stub PATH WORKFLOW_1ST WORKFLOW_2ND VALIDATION ALLOW_UPDATE
#           [MODE=ok|fail] [BULKGET_1ST] [BULKGET_2ND] — a jira-api.sh-shaped
# stub, one per scenario; the 2nd responses cover the post-write re-read.
# ALLOW_UPDATE gates the one mutating call and defaults to 0, refuse.
CALLLOG=""
make_stub() {
    local path="$1" workflow_first="$2" workflow_second="$3" validation_resp="$4" allow_update="$5" \
          validation_mode="${6:-ok}" bulkget_first="${7:-$NWM_BULKGET}" bulkget_second="${8:-${7:-$NWM_BULKGET}}"
    CALLLOG="$TMPD/$(basename "$path").calllog"
    : > "$CALLLOG"
    local counter_file bulkget_counter_file
    counter_file="$TMPD/$(basename "$path").counter"
    : > "$counter_file"
    bulkget_counter_file="$TMPD/$(basename "$path").bulkget-counter"
    : > "$bulkget_counter_file"
    cat > "$path" <<STUBEOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLLOG"
# jira_bulkget sends both --show-secrets and --yes ahead of the verb; strip
# either or both, in any order, not just a single leading --yes.
while true; do
    case "\$1" in
        --yes|--show-secrets) shift ;;
        *) break ;;
    esac
done
case "\$1 \$2" in
    "raw GET")
        case "\$3" in
            *"/statuses/search"*) cat "$STATUSES_SEARCH" ;;
            /field) cat "$FIELD_LIST" ;;
            *"/workflow/search"*)
                n=\$(cat "$counter_file")
                n=\$((n + 1))
                echo "\$n" > "$counter_file"
                if [ "\$n" = "1" ]; then cat "$workflow_first"; else cat "$workflow_second"; fi
                ;;
            *) echo "STUB: no fixture for raw GET \$3" >&2; exit 98 ;;
        esac
        ;;
    "write POST")
        case "\$3" in
            /workflows)
                bn=\$(cat "$bulkget_counter_file")
                bn=\$((bn + 1))
                echo "\$bn" > "$bulkget_counter_file"
                if [ "\$bn" = "1" ]; then cat "$bulkget_first"; else cat "$bulkget_second"; fi
                ;;
            /workflows/update/validation)
                if [ "$validation_mode" = "transport_fail" ]; then
                    cat "$validation_resp" >&2
                    exit 1
                else
                    cat "$validation_resp"
                fi
                ;;
            /workflows/update)
                if [ "$allow_update" = "1" ]; then
                    echo '{}'
                else
                    echo "STUB: refusing write POST /workflows/update during selftest (this call actually mutates state)" >&2
                    exit 97
                fi
                ;;
            *) echo "STUB: no handler for write POST \$3" >&2; exit 98 ;;
        esac
        ;;
    *)
        echo "STUB: refusing non-GET/non-write call during selftest: \$*" >&2
        exit 97
        ;;
esac
STUBEOF
    chmod +x "$path"
}

# run <name> <args...> — TMPDIR points at this file's own scratch dir so
# the snapshot files a real write produces land somewhere it cleans up.
run() {
    local name="$1"; shift
    local rc=0
    local outf="$TMPD/$name.out" errf="$TMPD/$name.err"
    ( export TMPDIR="$TMPD"; exec "$SCRIPT" "$@" ) > "$outf" 2> "$errf" < /dev/null || rc=$?
    LAST_RC="$rc"
    LAST_OUT=$(cat "$outf")
    LAST_ERR=$(cat "$errf")
}

# 0. baseline: the happy path reaches the stub, so the negative assertions mean something
WRAP_LAB="$TMPD/wrap-lab.sh"
make_stub "$WRAP_LAB" "$LAB_WORKFLOW" "$LAB_WORKFLOW" "$VALIDATION_SUCCESS" 0
run base0 LAB --jira-api "$WRAP_LAB" --dry-run
assert_eq "0: LAB dry-run exits 0" "0" "$LAST_RC"
CALLLOG_LAB="$TMPD/$(basename "$WRAP_LAB").calllog"
assert_nonempty "0: the stub was actually reached" "$CALLLOG_LAB"
check "0: statuses/search was called" "$(cat "$CALLLOG_LAB")" "statuses/search"
check "0: workflow/search was called" "$(cat "$CALLLOG_LAB")" "workflow/search"

# 1. NWM: names every missing status and transition, and renders the validated body
WRAP_NWM_OK="$TMPD/wrap-nwm-ok.sh"
make_stub "$WRAP_NWM_OK" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_SUCCESS" 0
run nwm1 NWM --jira-api "$WRAP_NWM_OK" --dry-run
assert_eq "1: NWM --dry-run (real validation success) exits 0" "0" "$LAST_RC"
check "1: names missing status Open" "$LAST_OUT" "Open"
check "1: names missing status Triage" "$LAST_OUT" "Triage"
check "1: names missing status Awaiting Deployment" "$LAST_OUT" "Awaiting Deployment"
check "1: names missing status Deferred" "$LAST_OUT" "Deferred"
check "1: names missing status Completed" "$LAST_OUT" "Completed"
check "1: names missing status Cancelled" "$LAST_OUT" "Cancelled"
DRYRUN_JSON=$(printf '%s\n' "$LAST_OUT" | sed -n '/^{$/,$p')
for id in 41 51 61 71 81 91; do
    check "1: dry-run body carries transition id \"$id\"" "$DRYRUN_JSON" "\"id\": \"$id\""
done
check "1: added status definitions carry BOTH id and statusReference (the fix for NON_UNIQUE_STATUS_NAME)" "$DRYRUN_JSON" '"id": "10013",
      "statusReference": "10013"'
CATS=$(printf '%s' "$DRYRUN_JSON" | jq -r '[.statuses[].statusCategory] | sort | join(",")' 2>/dev/null || echo "?")
assert_eq "1: all 9 status definitions (3 existing + 6 added) carry real statusCategory values (not null)" "DONE,DONE,DONE,IN_PROGRESS,IN_PROGRESS,TODO,TODO,TODO,TODO" "$CATS"
IDLESS=$(printf '%s' "$DRYRUN_JSON" | jq -e '[.workflows[0].transitions[] | select(has("id") | not)] | length == 0' 2>/dev/null || echo "false")
assert_eq "1: no transition in the final body is missing its 'id' field" "true" "$IDLESS"
TRANSCOUNT=$(printf '%s' "$DRYRUN_JSON" | jq '.workflows[0].transitions | length' 2>/dev/null || echo "?")
assert_eq "1: FULL body — 4 existing + 6 added = 10 transitions (not a delta of 6)" "10" "$TRANSCOUNT"
STATUSCOUNT=$(printf '%s' "$DRYRUN_JSON" | jq '.workflows[0].statuses | length' 2>/dev/null || echo "?")
assert_eq "1: FULL body — 3 existing + 6 added = 9 statuses (not a delta of 6)" "9" "$STATUSCOUNT"
check_not "1: never calls the actual update endpoint under --dry-run" "$(cat "$TMPD/$(basename "$WRAP_NWM_OK").calllog")" "workflows/update "

# Full-passthrough, byte for byte: jq deep equality between each existing
# transition in the rendered body and the same object in the fixture.
FULLPASS_OK=$(printf '%s' "$DRYRUN_JSON" | jq --slurpfile fixture "$NWM_BULKGET" '
    ($fixture[0].workflows[0].transitions) as $fx
    | (.workflows[0].transitions) as $rendered
    | [ $fx[] as $f
        | ($rendered[] | select(.id == $f.id)) as $r
        | select($r != $f)
      ] | length == 0
    ' 2>/dev/null || echo "false")
assert_eq "1: every existing transition (11/21/31/1) is byte-for-byte identical to the fixture — actions/validators/ruleKey/permissionKey all preserved" "true" "$FULLPASS_OK"
check "1: a real ruleKey survived (not redacted, not dropped)" "$DRYRUN_JSON" '"ruleKey": "system:update-field"'
check "1: a real permissionKey survived" "$DRYRUN_JSON" '"permissionKey": "CREATE_ISSUES"'
check_not "1: no redacted placeholder leaked into the rendered body" "$DRYRUN_JSON" "<redacted>"

# 2. the validation request is wrapped in the payload/validationOptions envelope
# Read the WHOLE calllog, never grep one line: the stub logs full argv, so
# a pretty-printed JSON body spans several physical lines per logical call.
VALIDATION_CALL_LOG=$(cat "$TMPD/$(basename "$WRAP_NWM_OK").calllog")
check "2: the validation call's body is wrapped in a \"payload\" key" "$VALIDATION_CALL_LOG" '"payload"'
check "2: the validation call's body carries validationOptions.levels" "$VALIDATION_CALL_LOG" '"validationOptions"'
check "2: validationOptions names both severity levels" "$VALIDATION_CALL_LOG" '"ERROR"'
check "2: the wrapped payload nests a \"workflows\" key (the actual update body, not something re-shaped)" "$VALIDATION_CALL_LOG" '"workflows"'

# 3. LAB is already complete: exits 0 without the bulk-get or validation calls
run lab1 LAB --jira-api "$WRAP_LAB" --dry-run
assert_eq "3a: LAB --dry-run exits 0" "0" "$LAST_RC"
check "3a: reports already complete" "$LAST_OUT" "already complete"

: > "$CALLLOG_LAB"
run lab2 LAB --jira-api "$WRAP_LAB" --yes
assert_eq "3b: LAB with --yes (no --dry-run) still exits 0 (nothing to add)" "0" "$LAST_RC"
check "3b: still reports already complete" "$LAST_OUT" "already complete"
assert_eq "3b: exactly 2 calls (both GETs) — no bulk-get, no validation, no update" "2" "$(wc -l < "$CALLLOG_LAB" | tr -d ' ')"
check_not "3b: no bulk-get was issued" "$(cat "$CALLLOG_LAB")" "write POST /workflows "

# 4. a real ERROR-level rejection exits non-zero before reaching /workflows/update
WRAP_NWM_REJECTED="$TMPD/wrap-nwm-rejected.sh"
make_stub "$WRAP_NWM_REJECTED" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_REJECTED" 0
run nwm4 NWM --jira-api "$WRAP_NWM_REJECTED" --yes
assert_nonzero "4: a real validation rejection (multiple ERRORs) stops the run" "$LAST_RC"
check "4: a real error message is shown" "$LAST_ERR" "NON_UNIQUE_STATUS_NAME"
check "4: refuses before the update call, naming why" "$LAST_ERR" "refusing to write"
check_not "4: the stub's write-refusal never had to fire (validation stopped it first)" "$LAST_ERR" "STUB: refusing"

# 5. a real WARNING-only response is printed but does not stop the run
WRAP_NWM_WARNONLY="$TMPD/wrap-nwm-warnonly.sh"
make_stub "$WRAP_NWM_WARNONLY" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_WARNINGS_ONLY" 0
run nwm5 NWM --jira-api "$WRAP_NWM_WARNONLY" --dry-run
assert_eq "5: a WARNING-only validation result does not stop --dry-run" "0" "$LAST_RC"
check "5: the warning is shown" "$LAST_ERR" "NO_INBOUND_TRANSITIONS_TO_STATUS"
check "5: says how many warnings" "$LAST_ERR" "reported 6 warning(s)"
check "5: still reaches the final-body preview" "$LAST_OUT" "validation passed"

# 6. no --yes and no --dry-run: stops before the write at the distinct exit code 3
run noyes2 NWM --jira-api "$WRAP_NWM_OK"
assert_eq "6: no --yes and no --dry-run exits the distinct code 3, not 1" "3" "$LAST_RC"
check "6: refusal names the reason" "$LAST_ERR" "not confirmed"
check "6: the final body was still shown before stopping" "$LAST_OUT" "workflows"
check_not "6: the update endpoint was never reached" "$(cat "$TMPD/$(basename "$WRAP_NWM_OK").calllog")" "workflows/update "

# 7. the stub itself fails the run on any /workflows/update it should not have seen
run forceupdate NWM --jira-api "$WRAP_NWM_OK" --yes
assert_nonzero "7: even with --yes, a stub configured to refuse /workflows/update stops the run" "$LAST_RC"
check "7: the stub's own refusal is what stopped it" "$LAST_ERR" "STUB: refusing write POST /workflows/update"

# A transport-level (non-2xx) failure of /validation itself is still a
# hard stop, distinct from an errors-array rejection — SYNTHETIC (see this
# file's header): a structurally valid envelope never produced one live.
WRAP_TRANSPORT_FAIL="$TMPD/wrap-transport-fail.sh"
make_stub "$WRAP_TRANSPORT_FAIL" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_TRANSPORT_FAILURE" 0 transport_fail
run transportfail NWM --jira-api "$WRAP_TRANSPORT_FAIL" --yes
assert_nonzero "7b: a transport-level (non-2xx) validation failure also stops the run" "$LAST_RC"
check "7b: names the failure as outright, not an errors-array rejection" "$LAST_ERR" "failed outright"

# 8. assert_readback's two branches, against a stub that allows one real update
WRAP_READBACK_PASS="$TMPD/wrap-readback-pass.sh"
make_stub "$WRAP_READBACK_PASS" "$NWM_WORKFLOW" "$WORKFLOW_COMPLETE" "$VALIDATION_SUCCESS" 1
run readbackpass NWM --jira-api "$WRAP_READBACK_PASS" --yes
assert_eq "8a: --yes with a complete post-write re-read exits 0" "0" "$LAST_RC"
check "8a: read-back confirms completeness" "$LAST_OUT" "read-back confirms"
assert_eq "8a: workflow/search was called exactly twice (initial read + read-back)" "2" "$(grep -c 'raw GET.*workflow/search' "$TMPD/$(basename "$WRAP_READBACK_PASS").calllog")"

WRAP_READBACK_FAIL="$TMPD/wrap-readback-fail.sh"
make_stub "$WRAP_READBACK_FAIL" "$NWM_WORKFLOW" "$WORKFLOW_STILL_MISSING_DEFERRED" "$VALIDATION_SUCCESS" 1
run readbackfail NWM --jira-api "$WRAP_READBACK_FAIL" --yes
assert_nonzero "8b: --yes with a re-read still missing Deferred exits non-zero" "$LAST_RC"
check "8b: names Deferred as still missing" "$LAST_ERR" "Deferred"
check "8b: says the update did not take effect as expected" "$LAST_ERR" "did not take effect as expected"

# 9. an unparseable or errors-key-less 2xx dies naming the raw response
WRAP_NOERRORSKEY="$TMPD/wrap-noerrorskey.sh"
make_stub "$WRAP_NOERRORSKEY" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_NO_ERRORS_KEY" 0
run noerrorskey NWM --jira-api "$WRAP_NOERRORSKEY" --dry-run
assert_nonzero "9: a 2xx validation response with no 'errors' array is a hard die" "$LAST_RC"
check "9: names the problem, not a silent pass" "$LAST_ERR" "no 'errors' array"
check "9: shows the raw (already-redacted) response" "$LAST_ERR" "acknowledged"

# 10. a post-write re-read whose rule arrays differ is exit 2, naming the transition
WRAP_STRIPPED="$TMPD/wrap-stripped.sh"
make_stub "$WRAP_STRIPPED" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_SUCCESS" 1 ok "$NWM_BULKGET" "$NWM_BULKGET_STRIPPED"
run stripped NWM --jira-api "$WRAP_STRIPPED" --yes
assert_eq "10: a changed rule set exits the DISTINCT code 2, not 0 or 1" "2" "$LAST_RC"
check "10: names the affected transition" "$LAST_ERR" "differ from what the update sent on transition 11"
check "10: prints the before-file path" "$LAST_ERR" "before file:"
check "10: prints the after-file path" "$LAST_ERR" "after file:"
BEFORE_PATH=$(printf '%s' "$LAST_ERR" | sed -n 's/^before file: *//p' | head -1)
assert_nonempty "10: the before-snapshot file this script named actually exists" "$BEFORE_PATH"
check "10: the update response was shown before the diff" "$LAST_OUT" "/workflows/update response:"
check "10: the deep diff itself was printed" "$LAST_OUT" "per-transition rule DEEP DIFF"
check "10: the diff shows what was sent against what was stored" "$LAST_OUT" '"stored":'

# 10b/10c. a regenerated rule id must not trip the diff; a changed ruleKey must
# workflow_second is LAB's REAL complete workflow: assert_readback's
# re-read needs all 9 targets present, and ZZPROBE_WORKFLOW is pre-write.
WRAP_ZZPROBE_IDCHANGE="$TMPD/wrap-zzprobe-idchange.sh"
make_stub "$WRAP_ZZPROBE_IDCHANGE" "$ZZPROBE_WORKFLOW" "$LAB_WORKFLOW" "$VALIDATION_SUCCESS" 1 ok "$ZZPROBE_BEFORE" "$ZZPROBE_AFTER"
run zzprobeidchange ZZPROBE --jira-api "$WRAP_ZZPROBE_IDCHANGE" --yes
assert_eq "10b: a rule id that merely got regenerated (ruleKey/parameters unchanged) does NOT trip the diff" "0" "$LAST_RC"
check "10b: the deep diff printed an empty result" "$LAST_OUT" "per-transition rule DEEP DIFF"
check_not "10b: no rule-diff failure was reported" "$LAST_ERR" "differ from what the update sent"

WRAP_ZZPROBE_RULEKEYCHANGE="$TMPD/wrap-zzprobe-rulekeychange.sh"
make_stub "$WRAP_ZZPROBE_RULEKEYCHANGE" "$ZZPROBE_WORKFLOW" "$ZZPROBE_WORKFLOW" "$VALIDATION_SUCCESS" 1 ok "$ZZPROBE_BEFORE" "$ZZPROBE_AFTER_RULEKEY_CHANGED"
run zzproberulekeychange ZZPROBE --jira-api "$WRAP_ZZPROBE_RULEKEYCHANGE" --yes
assert_eq "10c: a rule whose ruleKey actually changed still exits the DISTINCT code 2" "2" "$LAST_RC"
check "10c: names the affected transition (1, the INITIAL/Create one)" "$LAST_ERR" "differ from what the update sent on transition 1"

# 11. a target transition id already owned by a different name is a hard die
WRAP_COLLISION="$TMPD/wrap-collision.sh"
make_stub "$WRAP_COLLISION" "$WORKFLOW_ID_COLLISION" "$WORKFLOW_ID_COLLISION" "$VALIDATION_SUCCESS" 0
run collision NWM --jira-api "$WRAP_COLLISION" --dry-run
assert_nonzero "11: a target transition id already owned by a different name is a hard die" "$LAST_RC"
check "11: names the colliding id" "$LAST_ERR" "transition id 51"
check "11: names the unexpected existing owner" "$LAST_ERR" "Some Unrelated Transition"
check "11: names what this script would have called it instead" "$LAST_ERR" "not 'Open'"
check_not "11: never reaches the bulk-get (dies before any write-path call)" "$(cat "$TMPD/$(basename "$WRAP_COLLISION").calllog")" "write POST"

# 12. --restore-from: a redacted file is refused; a clean one reaches validate
WRAP_REFUSE_ALL="$TMPD/wrap-refuse-all.sh"
cat > "$WRAP_REFUSE_ALL" <<'STUBEOF'
#!/bin/bash
echo "STUB: refuse-all wrapper called: $*" >&2
exit 97
STUBEOF
chmod +x "$WRAP_REFUSE_ALL"
run restorebad NWM --jira-api "$WRAP_REFUSE_ALL" --restore-from "$RESTORE_FROM_REDACTED" --dry-run
assert_nonzero "12a: a redacted --restore-from file is refused" "$LAST_RC"
check "12a: names why (contains the literal <redacted>)" "$LAST_ERR" '<redacted>'
check "12a: says WITHOUT --show-secrets" "$LAST_ERR" "WITHOUT --show-secrets"
check "12a: never reached the stub at all (refused before any network call)" "$LAST_ERR" "reproduce the exact rules-stripping bug"
check_not "12a: the refuse-all stub was never actually invoked" "$LAST_ERR" "STUB: refuse-all wrapper called"

WRAP_RESTORE_OK="$TMPD/wrap-restore-ok.sh"
cat > "$WRAP_RESTORE_OK" <<STUBEOF
#!/bin/bash
case "\$*" in
    *"write POST /workflows/update/validation"*) cat "$VALIDATION_SUCCESS" ;;
    *"write POST /workflows "*) cat "$RESTORE_FROM_CLEAN" ;;
    *) echo "STUB: no handler: \$*" >&2; exit 98 ;;
esac
STUBEOF
chmod +x "$WRAP_RESTORE_OK"
run restoreok NWM --jira-api "$WRAP_RESTORE_OK" --restore-from "$RESTORE_FROM_CLEAN" --dry-run
assert_eq "12b: a clean --show-secrets-era --restore-from file exits 0 under --dry-run" "0" "$LAST_RC"
check "12b: says it is restoring, naming the source file" "$LAST_OUT" "restoring workflow"
check "12b: reaches the same validation-passed preview as the normal flow" "$LAST_OUT" "validation passed"
check "12b: the restore body still carries the real ruleKey (full passthrough, not reshaped)" "$LAST_OUT" '"ruleKey": "system:update-field"'
check_not "12b: never reaches the actual update endpoint under --dry-run" "$LAST_OUT" "/workflows/update response"

# 13. argument validation: a bad PROJECT_KEY or a missing --jira-api fails loudly
run novargs
assert_nonzero "13a: no arguments at all fails" "$LAST_RC"

run badkey "not-a-key" --jira-api "$WRAP_NWM_OK"
assert_nonzero "13b: a lowercase project key is refused" "$LAST_RC"
check "13b: message names the problem" "$LAST_ERR" "project key"

run nowrapper NWM --jira-api /nonexistent/path/to/nothing
assert_nonzero "13c: a --jira-api path that does not exist is refused" "$LAST_RC"
check "13c: message names what's wrong" "$LAST_ERR" "not an executable file"

( unset ISSUES_JIRA_API; exec "$SCRIPT" NWM ) > "$TMPD/noenv.out" 2> "$TMPD/noenv.err" < /dev/null && NOENV_RC=0 || NOENV_RC=$?
assert_nonzero "13d: no --jira-api and no \$ISSUES_JIRA_API is refused" "$NOENV_RC"
check "13d: message names what's missing" "$(cat "$TMPD/noenv.err")" "ISSUES_JIRA_API"

run rulesmissingfile NWM --jira-api "$WRAP_REFUSE_ALL" --rules /nonexistent/rules.json --dry-run
assert_nonzero "13e: a --rules path that does not exist is refused" "$LAST_RC"
check "13e: message names the missing file" "$LAST_ERR" "--rules file not found"

run rulesrestore NWM --jira-api "$WRAP_REFUSE_ALL" --rules "$RULES_SPEC" --restore-from "$RESTORE_FROM_CLEAN" --dry-run
assert_nonzero "13f: --rules with --restore-from is refused" "$LAST_RC"
check "13f: message says they are mutually exclusive" "$LAST_ERR" "mutually exclusive"

# 14. --rules, against the REAL SPK4 rehearsal captures.
WRAP_RULES_ADD="$TMPD/wrap-rules-add.sh"
make_stub "$WRAP_RULES_ADD" "$SPK4_WORKFLOW" "$SPK4_WORKFLOW" "$SPK4_PROBE3_RESPONSE" 0 ok "$SPK4_RULES_BEFORE"
CALLLOG_RULES_ADD="$CALLLOG"
run rulesadd SPK4 --jira-api "$WRAP_RULES_ADD" --rules "$RULES_SPEC" --dry-run
assert_eq "14a: --rules on the rule-less SPK4 workflow exits 0 under --dry-run" "0" "$LAST_RC"
check "14a: names the missing In Progress rules" "$LAST_OUT" "rules:       In Progress: system:validate-field-value, system:validate-field-value"
check "14a: names the missing Completed rules" "$LAST_OUT" "rules:       Completed: system:validate-field-value, system:previous-status-validator"
RULES_BODY=$(printf '%s\n' "$LAST_OUT" | sed -n '/^{$/,$p')
check_not "14a: no placeholder survived resolution" "$RULES_BODY" "{field:"
SAME_AS_PROBE=$(printf '%s' "$RULES_BODY" | jq --slurpfile req "$SPK4_PROBE3_REQUEST" '. == $req[0].payload' 2>/dev/null || echo "false")
assert_eq "14a: the rendered body equals the probe-3 payload Jira validated with zero errors" "true" "$SAME_AS_PROBE"
SAME_AS_STORED=$(printf '%s' "$RULES_BODY" | jq --slurpfile after "$SPK4_RULES_AFTER" '
    def rules: map({id, v: ((.validators // []) | map(del(.id)))});
    (.workflows[0].transitions | rules) == ($after[0].workflows[0].transitions | rules)' 2>/dev/null || echo "false")
assert_eq "14a: every transition's validators equal what Jira stored after the live apply (rule ids aside)" "true" "$SAME_AS_STORED"
check_not "14a: never calls the update endpoint under --dry-run" "$(cat "$CALLLOG_RULES_ADD")" "workflows/update "

WRAP_RULES_DONE="$TMPD/wrap-rules-done.sh"
make_stub "$WRAP_RULES_DONE" "$SPK4_WORKFLOW" "$SPK4_WORKFLOW" "$SPK4_PROBE3_RESPONSE" 0 ok "$SPK4_RULES_AFTER"
CALLLOG_RULES_DONE="$CALLLOG"
run rulesdone SPK4 --jira-api "$WRAP_RULES_DONE" --rules "$RULES_SPEC" --yes
assert_eq "14b: re-running --rules on the applied workflow exits 0" "0" "$LAST_RC"
check "14b: reports zero changes" "$LAST_OUT" "0 changes"
check_not "14b: no validation call" "$(cat "$CALLLOG_RULES_DONE")" "update/validation"
check_not "14b: no update call (the stub would refuse it)" "$LAST_ERR" "STUB: refusing"

WRAP_RULES_PARTIAL="$TMPD/wrap-rules-partial.sh"
make_stub "$WRAP_RULES_PARTIAL" "$SPK4_WORKFLOW" "$SPK4_WORKFLOW" "$SPK4_PROBE3_RESPONSE" 0 ok "$SPK4_RULES_PARTIAL"
run rulespartial SPK4 --jira-api "$WRAP_RULES_PARTIAL" --rules "$RULES_SPEC" --dry-run
assert_eq "14c: a partially-ruled workflow exits 0 under --dry-run" "0" "$LAST_RC"
check_not "14c: In Progress is not listed as missing" "$LAST_OUT" "rules:       In Progress"
check "14c: only the previous-status rule is missing on Completed" "$LAST_OUT" "rules:       Completed: system:previous-status-validator"
PARTIAL_COUNTS=$(printf '%s\n' "$LAST_OUT" | sed -n '/^{$/,$p' | jq -r '[.workflows[0].transitions[] | select(.id == "21" or .id == "81") | "\(.id)=\(.validators | length)"] | join(",")' 2>/dev/null || echo "?")
assert_eq "14c: present rules are not duplicated (21 keeps 2, 81 back to 2)" "21=2,81=2" "$PARTIAL_COUNTS"

: > "$CALLLOG_RULES_ADD"
run rulesbadfield SPK4 --jira-api "$WRAP_RULES_ADD" --rules "$RULES_SPEC_BADFIELD" --dry-run
assert_nonzero "14d: a field name the site does not have is a hard die" "$LAST_RC"
check "14d: names the unresolved field" "$LAST_ERR" "field:no such field"
check_not "14d: dies before any write-path call" "$(cat "$CALLLOG_RULES_ADD")" "write POST"

: > "$CALLLOG_RULES_ADD"
run rulesbadtransition SPK4 --jira-api "$WRAP_RULES_ADD" --rules "$RULES_SPEC_BADTRANSITION" --dry-run
assert_nonzero "14e: a transition name the workflow does not have is a hard die" "$LAST_RC"
check "14e: names the unknown transition" "$LAST_ERR" "In Progres"
check_not "14e: dies before any write-path call" "$(cat "$CALLLOG_RULES_ADD")" "write POST"

WRAP_RULES_APPLY="$TMPD/wrap-rules-apply.sh"
make_stub "$WRAP_RULES_APPLY" "$SPK4_WORKFLOW" "$SPK4_WORKFLOW" "$SPK4_PROBE3_RESPONSE" 1 ok "$SPK4_RULES_BEFORE" "$SPK4_RULES_AFTER"
run rulesapply SPK4 --jira-api "$WRAP_RULES_APPLY" --rules "$RULES_SPEC" --yes
assert_eq "14f: the REAL before/after pair of the live SPK4 apply passes the post-write diff" "0" "$LAST_RC"
check "14f: read-back confirms" "$LAST_OUT" "read-back confirms"
check_not "14f: no rule-diff failure" "$LAST_ERR" "differ from what the update sent"

WRAP_RULES_NOTSTORED="$TMPD/wrap-rules-notstored.sh"
make_stub "$WRAP_RULES_NOTSTORED" "$SPK4_WORKFLOW" "$SPK4_WORKFLOW" "$SPK4_PROBE3_RESPONSE" 1 ok "$SPK4_RULES_BEFORE" "$SPK4_RULES_BEFORE"
run rulesnotstored SPK4 --jira-api "$WRAP_RULES_NOTSTORED" --rules "$RULES_SPEC" --yes
assert_eq "14g: an after read without the added rules exits the DISTINCT code 2" "2" "$LAST_RC"
check "14g: names the first transition whose rules were not stored" "$LAST_ERR" "differ from what the update sent on transition 21"

WRAP_RULES_OTHER="$TMPD/wrap-rules-other.sh"
make_stub "$WRAP_RULES_OTHER" "$SPK4_WORKFLOW" "$SPK4_WORKFLOW" "$SPK4_PROBE3_RESPONSE" 0 ok "$SPK4_RULES_OTHER_PARAMS"
run rulesother SPK4 --jira-api "$WRAP_RULES_OTHER" --rules "$RULES_SPEC" --dry-run
assert_eq "14h: same ruleKey with different parameters exits 0 under --dry-run" "0" "$LAST_RC"
check "14h: the touches rule counts as missing (identity is ruleKey + parameters)" "$LAST_OUT" "rules:       In Progress: system:validate-field-value"
OTHER_21=$(printf '%s\n' "$LAST_OUT" | sed -n '/^{$/,$p' | jq -r '[.workflows[0].transitions[] | select(.id == "21") | .validators[].parameters.fieldsRequired] | join(",")' 2>/dev/null || echo "?")
assert_eq "14h: additive only — the differing rule stays and the spec rule is appended" "customfield_10044,customfield_10047,customfield_10043" "$OTHER_21"

: > "$CALLLOG_RULES_ADD"
run rulesnested SPK4 --jira-api "$WRAP_RULES_ADD" --rules "$RULES_SPEC_NESTED_UNKNOWN" --dry-run
assert_nonzero "14i: a placeholder nested in an array is resolved, and an unknown name there dies" "$LAST_RC"
check "14i: the resolver itself reached the nested value (its message, not the leftover guard's)" "$LAST_ERR" "does not have exactly once: UNRESOLVED:field:no such nested field"
check_not "14i: dies before any write-path call" "$(cat "$CALLLOG_RULES_ADD")" "write POST"

: > "$CALLLOG_RULES_ADD"
run rulestypo SPK4 --jira-api "$WRAP_RULES_ADD" --rules "$RULES_SPEC_TYPO" --dry-run
assert_nonzero "14j: a mistyped placeholder ({Field:verify}) is a hard die" "$LAST_RC"
check "14j: the leftover-placeholder guard names it" "$LAST_ERR" "{Field:verify}"
check "14j: says why it refuses" "$LAST_ERR" "placeholder-shaped value after resolution"
check_not "14j: dies before any write-path call" "$(cat "$CALLLOG_RULES_ADD")" "write POST"

# 14k. The REAL live rejections after the rules were applied: the spec's
# errorMessage strings are exactly what Jira showed the user.
REJECTED_FIX="$FIXDIR/issue.transition.rules-rejected.txt"
REJECTED_21=$(awk '/^# --- transition 21/ {f=1; next} /^#/ {f=0} f' "$REJECTED_FIX" | jq -c '.errorMessages' 2>/dev/null || echo "?")
REJECTED_81=$(awk '/^# --- transition 81/ {f=1; next} /^#/ {f=0} f' "$REJECTED_FIX" | jq -c '.errorMessages' 2>/dev/null || echo "?")
SPEC_21=$(jq -c '[.transitions[] | select(.name == "In Progress") | .validators[].parameters.errorMessage | select(. != null)]' "$RULES_SPEC")
SPEC_81=$(jq -c '[.transitions[] | select(.name == "Completed") | .validators[].parameters.errorMessage | select(. != null)]' "$RULES_SPEC")
assert_eq "14k: In Progress rejection messages equal the spec's errorMessage strings, in order" "$SPEC_21" "$REJECTED_21"
SPEC_81_SHOWN=$(jq -cn --argjson spec "$SPEC_81" --argjson got "$REJECTED_81" '$spec | all(. as $m | $got | index($m) != null)' 2>/dev/null || echo "false")
assert_eq "14k: every Completed errorMessage in the spec is a message Jira returned" "true" "$SPEC_81_SHOWN"
check "14k: the previous-status validator was enforced too (Jira's own text)" "$REJECTED_81" "never transitioned through the desired status: In Progress"

echo
if [ "$FAIL" = "0" ]; then
    echo "jira-workflow-apply-selftest: all checks passed"
    exit 0
fi
echo "jira-workflow-apply-selftest: FAILURES above" >&2
exit 1
