#!/bin/bash
#
# Selftest for jira-workflow-apply.sh. Runs entirely against a fake
# `jira-api.sh`-shaped stub script (never the real wrapper, never a real
# Jira site, never a real credential) that replays fixtures captured live
# and read-only-by-semantics. `--jira-api` points straight at that stub, so
# there is no `curl` and no `JIRA_HOST` to point at 127.0.0.1 — the
# isolation here is structural for a different reason than
# jira-agile-api-selftest.sh's: this script never talks to curl directly at
# all, only through a wrapper it is handed, so the stub simply refuses to
# be anything other than a stub. `$ISSUES_JIRA_API` is explicitly unset at
# the top of this file and then pointed at a nonexistent path for the one
# test that means to exercise its absence (section 6d) — leaving it as
# whatever the ambient shell happened to have set would let that one case
# silently fall through to a REAL wrapper on a machine that has
# $ISSUES_JIRA_API exported for its own project's session-start.
#
# Fixtures under fixtures/ are real bodies captured live against a real
# Jira Cloud site (example.atlassian.net), via `jira-api.sh raw GET ...`
# (read-only) and `jira-api.sh --yes write POST /workflows ...` /
# `.../workflows/update/validation` (both non-mutating despite the POST
# verb — see jira-workflow-apply.sh's header) — see each fixture's own
# header for the exact command:
#   workflow.search.nwm.txt                       — project NWM's template
#                                                    workflow (3 statuses,
#                                                    the missing-set case)
#   workflow.search.lab.txt                       — project LAB's workflow
#                                                    (9 statuses, "already
#                                                    complete")
#   statuses.search.txt                           — site-wide
#                                                    /statuses/search, trimmed
#   workflows.bulkget.nwm.txt                      — POST /workflows
#                                                    bulk-get for NWM, the
#                                                    real base
#                                                    build_update_body
#                                                    renders from
#   workflows.update.validation.nwm.txt            — the FINAL, correct
#                                                    envelope body,
#                                                    validated live:
#                                                    HTTP 200,
#                                                    `{"errors": []}`
#   workflows.update.validation.spk4.txt           — the same, against
#                                                    SPK4 (see its header
#                                                    for the full
#                                                    iteration history that
#                                                    found the envelope
#                                                    requirement)
#   workflows.update.validation.spk4-rejected-idless.txt
#                                                  — a REAL rejection (HTTP
#                                                    200, several ERROR-
#                                                    level entries) from an
#                                                    earlier iteration step
#   workflows.update.validation.spk4-warnings-only.txt
#                                                  — a REAL WARNING-only
#                                                    response (HTTP 200,
#                                                    zero ERRORs, six
#                                                    WARNINGs) from another
#                                                    iteration step
#
# One response body below is SYNTHETIC, not captured — labelled at its use:
# a transport-level (non-2xx) failure of the /validation call itself, which
# every real attempt with a STRUCTURALLY valid envelope in this session
# never produced (a malformed envelope did, once, before the envelope
# requirement was found — see jira-workflow-apply.sh's header — but that
# capture no longer represents anything this script would ever send, now
# that it always wraps the body correctly). A post-write "read-back"
# workflow (both a complete one and one still missing "Deferred") is also
# SYNTHETIC — real fixtures cannot supply either because the mutating call
# they would follow (/workflows/update) was never issued against any
# project in this session, by design (see the header of
# jira-workflow-apply.sh and this file's section 8).
#
# What this file proves:
#   1. NWM: missing-set computation names all 6 statuses and all 6
#      transitions; the rendered body carries the real ids/categories, and
#      matches — byte for byte — the shape actually validated live (see
#      section 2's envelope-shape assertions).
#   2. The request this script sends to /workflows/update/validation is
#      wrapped in the {"payload": ..., "validationOptions": {"levels":
#      [...]}} envelope — not the bare update body — matching what was
#      found live to be required.
#   3. LAB: "already complete" — exits 0 WITHOUT ever calling the bulk-get
#      or validation endpoints at all (there is nothing to build).
#   4. A REAL rejection (multiple ERROR-level entries) makes the script
#      exit non-zero and print every error, before ever reaching
#      /workflows/update.
#   5. A REAL WARNING-only response (zero ERRORs) is printed as a warning
#      but does NOT stop the run.
#   6. Without --yes and without --dry-run: a real validation SUCCESS
#      still stops before the update call (--yes gate), after showing the
#      full body — and exits the DISTINCT code 3, not 1.
#   7. THE STUB ITSELF fails the whole run if jira-workflow-apply.sh ever
#      issues a `write POST /workflows/update` (the one call that actually
#      mutates state) in any case that should not reach it — proven by
#      observing it actually fire, not merely assumed.
#   8. With --yes, a real validation success, and a stub that DOES allow
#      the update call once: assert_readback's own two branches — (a) a
#      complete re-read (the REAL fixtures/workflow.search.lab.txt — LAB's
#      workflow already carries all 9 target statuses/transitions, so it
#      doubles as "what a successful NWM write would read back as") passes,
#      (b) the same fixture with "Deferred" stripped fails non-zero and
#      names it.
#   9. An unparseable, or `errors`-key-less, 2xx from /validation is a hard
#      die naming the raw response — NOT silently "zero errors" (ROUND-2
#      REVIEW ITEM 1).
#   10. A post-write re-read whose per-transition rule arrays (actions/
#      validators/triggers/links) DIFFER at all from the pre-write
#      snapshot's — full jq deep equality, not merely a count — is a hard
#      stop at the DISTINCT exit code 2, naming the transition. Exercised
#      with a stub that actually empties a real rule between the first
#      and second `write POST /workflows` call (ROUND-3 REVIEW ITEM 3).
#   10b/10c. Using the REAL before/after pair from the actual successful
#      ZZPROBE apply: a rule id that merely got regenerated by Jira on
#      write (ruleKey/parameters unchanged) does NOT trip the diff; a
#      rule whose ruleKey/parameters actually changed still does
#      (ROUND-4 REVIEW ITEM 1 — the false positive found live on that
#      same ZZPROBE apply).
#   11. A target transition id (41/51/61/71/81/91) that already belongs to
#      a DIFFERENT existing transition name is a hard die naming the
#      collision, before anything else runs (ROUND-2 REVIEW ITEM 4).
#   14. --rules, on the REAL SPK4 rehearsal captures: the body
#      rendered for the rule-less workflow equals the probe payload Jira
#      validated and then stored; re-running on the stored workflow is
#      "0 changes" with no validation or update call; a partially-ruled
#      workflow gets only the missing rule; an unknown field name or
#      transition name dies before any write-path call; the real
#      before/after apply pair passes the post-write diff, and an after
#      read that lacks the added rules fails it with exit 2; a placeholder
#      nested in an array is resolved, and a mistyped one dies, both
#      before any write-path call; the spec's errorMessage strings equal
#      the messages Jira returned when it rejected real transitions (14k).
#   12. --restore-from (ROUND-3 REVIEW ITEM 4): (a) a file containing the
#      literal string "<redacted>" (a pre-fix, non---show-secrets
#      snapshot) is refused outright, before any network call; (b) a
#      clean --show-secrets-era file renders and validates a restore
#      body with a freshly-fetched version, reaching the same
#      validate-and-write path as the normal flow.
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

# --------------------------------------------------------------- fixtures
#
# strip_fixture_header is computed from the actual file (comment lines and
# a lone "HTTP <code>" status line stripped, no hardcoded line count), same
# technique as jira-agile-api-selftest.sh, so a future re-recording with a
# longer or shorter header comment can't silently shift the JSON body.
strip_fixture_header() {
    awk '/^#/{next} /^HTTP [0-9]+$/{next} {print}' "$1"
}
NWM_WORKFLOW="$TMPD/nwm-workflow.json"
strip_fixture_header "$FIXDIR/workflow.search.nwm.txt" > "$NWM_WORKFLOW"
LAB_WORKFLOW="$TMPD/lab-workflow.json"
strip_fixture_header "$FIXDIR/workflow.search.lab.txt" > "$LAB_WORKFLOW"
STATUSES_SEARCH="$TMPD/statuses-search.json"
strip_fixture_header "$FIXDIR/statuses.search.txt" > "$STATUSES_SEARCH"
# ROUND-3 REVIEW ITEM 1/2/6 — the --show-secrets capture, NOT the older
# redacted one (workflows.bulkget.nwm.txt, kept only as a historical
# record of the bug this superseded — see jira_bulkget's header). Real
# ruleKey/permissionKey values (e.g. "system:update-field",
# "CREATE_ISSUES") let section 1 below assert full-passthrough byte for
# byte, not merely structurally.
NWM_BULKGET="$TMPD/nwm-bulkget.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.nwm-secrets.txt" > "$NWM_BULKGET"
VALIDATION_SUCCESS="$TMPD/validation-success.json"
strip_fixture_header "$FIXDIR/workflows.update.validation.nwm.txt" > "$VALIDATION_SUCCESS"
VALIDATION_REJECTED="$TMPD/validation-rejected.json"
strip_fixture_header "$FIXDIR/workflows.update.validation.spk4-rejected-idless.txt" > "$VALIDATION_REJECTED"
VALIDATION_WARNINGS_ONLY="$TMPD/validation-warnings-only.json"
strip_fixture_header "$FIXDIR/workflows.update.validation.spk4-warnings-only.txt" > "$VALIDATION_WARNINGS_ONLY"

# SYNTHETIC — a transport-level (non-2xx) failure of the /validation call
# itself. See this file's header for why every REAL attempt in this
# session with a structurally valid envelope got a 200 instead (errors, if
# any, arrive INSIDE a 200's `errors` array, not as an HTTP-level
# rejection) — this exercises validate_update_body's `|| die "...failed
# outright"` branch, which a well-formed envelope no longer reaches.
VALIDATION_TRANSPORT_FAILURE="$TMPD/validation-transport-failure.json"
echo '{"errorMessages":["synthetic: malformed envelope, never actually produced by this script"]}' > "$VALIDATION_TRANSPORT_FAILURE"

# SYNTHETIC — ROUND-2 REVIEW ITEM 1: a 2xx response with no `errors` key
# at all. Never observed live (every real capture always had one, empty
# or not) — this exercises validate_update_body's hard die on an
# unparseable-or-keyless response, which used to silently become "zero
# errors" via `// []` before the fix.
VALIDATION_NO_ERRORS_KEY="$TMPD/validation-no-errors-key.json"
echo '{"acknowledged":true}' > "$VALIDATION_NO_ERRORS_KEY"

# ROUND-3 REVIEW ITEM 3 — a bulk-get "after" document derived from the
# REAL --show-secrets fixture above, with transition id "11"'"'"'s
# `actions` array emptied out — as if the write had silently stripped an
# existing post-function (this is EXACTLY the shape found live on SPK4 —
# see jira_bulkget's header). Used as the SECOND response to
# `write POST /workflows` (the post-write re-read), while the FIRST call
# in the same run still serves the real, unmodified fixture — this is
# what lets the deep-diff actually observe a change.
NWM_BULKGET_STRIPPED="$TMPD/nwm-bulkget-stripped.json"
jq '.workflows[0].transitions |= map(if .id == "11" then .actions = [] else . end)' \
    "$NWM_BULKGET" > "$NWM_BULKGET_STRIPPED"

# ROUND-4 REVIEW ITEM 1/2 — the REAL before/after pair from the actual
# successful ZZPROBE apply (the run that found the false positive this
# item fixes). See jira-workflow-apply.sh's validate_write_and_diff header
# for the full story: transition 1's validator got a REGENERATED uuid
# `id` on write even though its ruleKey/parameters (its real identity)
# never changed; transitions 11/21/31's numeric action ids did not
# regenerate in the same write.
ZZPROBE_WORKFLOW="$TMPD/zzprobe-workflow.json"
strip_fixture_header "$FIXDIR/workflow.search.zzprobe.txt" > "$ZZPROBE_WORKFLOW"
ZZPROBE_BEFORE="$TMPD/zzprobe-before.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.zzprobe-secrets-before-apply.txt" > "$ZZPROBE_BEFORE"
ZZPROBE_AFTER="$TMPD/zzprobe-after.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.zzprobe-secrets-after-apply.txt" > "$ZZPROBE_AFTER"

# Derived from the REAL after-fixture: transition 1's validator ruleKey
# changed (not just its id) — the deep-diff must still catch THIS, since
# a changed ruleKey/parameters is the rule's actual identity changing, not
# merely Jira's own id-regeneration noise.
ZZPROBE_AFTER_RULEKEY_CHANGED="$TMPD/zzprobe-after-rulekey-changed.json"
jq '.workflows[0].transitions |= map(if .id == "1" then .validators[0].ruleKey = "system:some-other-validator" else . end)' \
    "$ZZPROBE_AFTER" > "$ZZPROBE_AFTER_RULEKEY_CHANGED"

# --rules. REAL captures from the SPK4 rules rehearsal: the
# workflow before any rule, the same workflow read back after the probe-3
# body was applied live, the site field list, and probe 3's own request and
# response. The committed workflow-rules.json is the spec under test.
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
# Derived from the REAL after-fixture: transition 21's touches rule carries a
# different field id — same ruleKey, different parameters, so a different
# rule. Identity must be ruleKey + parameters, not ruleKey alone.
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

# ROUND-3 REVIEW ITEM 4 — --restore-from's two fixture sources: a REAL
# pre-fix, redacted document (the old workflows.bulkget.nwm.txt, captured
# WITHOUT --show-secrets — its own header explains why it was superseded)
# for the REFUSAL path, and the REAL --show-secrets fixture above (already
# a valid restore source) for the happy path.
RESTORE_FROM_REDACTED="$TMPD/restore-from-redacted.json"
strip_fixture_header "$FIXDIR/workflows.bulkget.nwm.txt" > "$RESTORE_FROM_REDACTED"
RESTORE_FROM_CLEAN="$NWM_BULKGET"

# ROUND-2 REVIEW ITEM 7 — a REAL post-write re-read stand-in, not a
# hand-authored one: LAB's own workflow (fixtures/workflow.search.lab.txt)
# already carries all 9 target statuses/transitions (it is the very
# fixture section 3's "already complete" case reads), so it doubles here
# as "what a successful post-write re-read of NWM would look like" —
# read_workflow only checks `.total >= 1`, never that the returned
# object's own name matches what was asked for, so serving LAB's real
# content in place of NWM's post-write GET is a legitimate stand-in, not
# a mismatch the script would ever notice or care about.
WORKFLOW_COMPLETE="$LAB_WORKFLOW"

# Derived from the REAL fixture above (not hand-typed): the same content
# with "Deferred" (both status and transition) removed, as if the write
# had silently dropped one addition. Proves assert_readback's FAILING
# branch, not just its passing one.
WORKFLOW_STILL_MISSING_DEFERRED="$TMPD/workflow-still-missing-deferred.json"
jq '.values[0].statuses |= map(select(.name != "Deferred")) | .values[0].transitions |= map(select(.name != "Deferred"))' \
    "$WORKFLOW_COMPLETE" > "$WORKFLOW_STILL_MISSING_DEFERRED"

# ROUND-2 REVIEW ITEM 4 — a REAL workflow fixture (NWM's own) with one
# extra, fabricated transition added under id 51 (one of this script's own
# target transition ids) but a DIFFERENT name — exercises
# check_transition_id_collisions' die path against a real base document,
# not a synthetic one built from nothing.
WORKFLOW_ID_COLLISION="$TMPD/workflow-id-collision.json"
jq '.values[0].transitions += [{"id": "51", "name": "Some Unrelated Transition", "description": "", "from": [], "to": "10009", "type": "global"}]' \
    "$NWM_WORKFLOW" > "$WORKFLOW_ID_COLLISION"

# --------------------------------------------------------------- fake wrapper
#
# A jira-api.sh-shaped stub, one per scenario. `$1` selects which
# workflow/search response to serve for the FIRST call and which for the
# SECOND (assert_readback re-reads after a write) — most scenarios never
# reach a second call at all. `$2` selects the validation response and
# whether it comes back as a wrapper-level success (real behaviour: HTTP
# 200 with an `errors` array, empty or not) or a transport failure
# (`$4`=fail). `$3` (0/1) allows or refuses `write POST /workflows/update`,
# the ONE call that actually mutates state — refusing is the default in
# every case that should never reach it. `$7` (default: the real NWM
# bulk-get fixture) is the response for the FIRST `write POST /workflows`
# call (used to build FINAL_BODY and as the pre-write snapshot); `$8`
# (default: same as `$7`, i.e. unchanged) is the response for the SECOND
# such call (the post-write re-read the rule-count diff — ROUND-2 REVIEW
# ITEM 3 — compares against the first).
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
# ROUND-3 REVIEW ITEM 1 — jira_bulkget now sends BOTH --show-secrets AND
# --yes (in that order) ahead of "write POST /workflows"; strip either/
# both, in whatever order, not just a single leading --yes.
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

# run <name> <args...> — TMPDIR is pointed at this file's own scratch dir
# (not the ambient /tmp) so the before/after snapshot files
# jira-workflow-apply.sh writes on a real write (ROUND-2 REVIEW ITEM 2)
# land somewhere this selftest already cleans up, not in system /tmp.
run() {
    local name="$1"; shift
    local rc=0
    local outf="$TMPD/$name.out" errf="$TMPD/$name.err"
    ( export TMPDIR="$TMPD"; exec "$SCRIPT" "$@" ) > "$outf" 2> "$errf" < /dev/null || rc=$?
    LAST_RC="$rc"
    LAST_OUT=$(cat "$outf")
    LAST_ERR=$(cat "$errf")
}

# =================================================================
# 0. baseline — the happy path reaches the stub for both required GETs on
#    the "already complete" (LAB) case, so every "the stub was never
#    reached" assertion elsewhere is meaningful.
# =================================================================
WRAP_LAB="$TMPD/wrap-lab.sh"
make_stub "$WRAP_LAB" "$LAB_WORKFLOW" "$LAB_WORKFLOW" "$VALIDATION_SUCCESS" 0
run base0 LAB --jira-api "$WRAP_LAB" --dry-run
assert_eq "0: LAB dry-run exits 0" "0" "$LAST_RC"
CALLLOG_LAB="$TMPD/$(basename "$WRAP_LAB").calllog"
assert_nonempty "0: the stub was actually reached" "$CALLLOG_LAB"
check "0: statuses/search was called" "$(cat "$CALLLOG_LAB")" "statuses/search"
check "0: workflow/search was called" "$(cat "$CALLLOG_LAB")" "workflow/search"

# =================================================================
# 1. NWM (missing-set) — names every missing status and transition, and
#    the rendered body (validated against a REAL validation success)
#    carries the right ids/categories, and no id-less transition. This is
#    the SAME body confirmed live to validate with zero errors — see
#    jira-workflow-apply.sh's header and workflows.update.validation.
#    {spk4,nwm}.txt.
# =================================================================
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

# ROUND-3 REVIEW ITEM 2/6 — build_update_body carries EVERY existing
# transition's full rule definitions forward BYTE FOR BYTE from the
# fixture, not merely structurally — this is the actual fix for the
# stripped-rules bug found live on SPK4. Compares the three EXISTING
# transitions (11/21/31, all "system:update-field") plus the INITIAL one
# (transition "1", "system:check-permission-validator" / "CREATE_ISSUES")
# in the rendered body against the same objects in the fixture, via jq
# deep equality — the strongest form of "byte for byte" available.
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

# =================================================================
# 2. Envelope shape — the request this script actually sends to
#    /workflows/update/validation must be wrapped in
#    {"payload": ..., "validationOptions": {"levels": [...]}}, not the
#    bare update body. This is the root-cause fix: sending the bare body
#    400s with a useless generic message (see jira-workflow-apply.sh's
#    header) — confirmed by inspecting what the stub actually received.
# =================================================================
# The stub logs each call's full argv, including embedded newlines from
# jq's own pretty-printed output — so the request body can span several
# PHYSICAL lines in the calllog file even though it is one logical call.
# Read the WHOLE file rather than grepping a single line, or a multi-line
# JSON body would only ever show its first line to `check`.
VALIDATION_CALL_LOG=$(cat "$TMPD/$(basename "$WRAP_NWM_OK").calllog")
check "2: the validation call's body is wrapped in a \"payload\" key" "$VALIDATION_CALL_LOG" '"payload"'
check "2: the validation call's body carries validationOptions.levels" "$VALIDATION_CALL_LOG" '"validationOptions"'
check "2: validationOptions names both severity levels" "$VALIDATION_CALL_LOG" '"ERROR"'
check "2: the wrapped payload nests a \"workflows\" key (the actual update body, not something re-shaped)" "$VALIDATION_CALL_LOG" '"workflows"'

# =================================================================
# 3. LAB (already complete) — exits 0, says so, and NEVER calls the
#    bulk-get or validation endpoints at all (there is nothing to build,
#    so this script's own design skips them entirely — see main's
#    ordering). Also true without --dry-run/--yes.
# =================================================================
run lab1 LAB --jira-api "$WRAP_LAB" --dry-run
assert_eq "3a: LAB --dry-run exits 0" "0" "$LAST_RC"
check "3a: reports already complete" "$LAST_OUT" "already complete"

: > "$CALLLOG_LAB"
run lab2 LAB --jira-api "$WRAP_LAB" --yes
assert_eq "3b: LAB with --yes (no --dry-run) still exits 0 (nothing to add)" "0" "$LAST_RC"
check "3b: still reports already complete" "$LAST_OUT" "already complete"
assert_eq "3b: exactly 2 calls (both GETs) — no bulk-get, no validation, no update" "2" "$(wc -l < "$CALLLOG_LAB" | tr -d ' ')"
check_not "3b: no bulk-get was issued" "$(cat "$CALLLOG_LAB")" "write POST /workflows "

# =================================================================
# 4. A REAL rejection (workflows.update.validation.spk4-rejected-idless.txt
#    — several ERROR-level entries from an early iteration step, kept as
#    real fixture material) makes the run exit non-zero, printing every
#    error, BEFORE ever reaching /workflows/update.
# =================================================================
WRAP_NWM_REJECTED="$TMPD/wrap-nwm-rejected.sh"
make_stub "$WRAP_NWM_REJECTED" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_REJECTED" 0
run nwm4 NWM --jira-api "$WRAP_NWM_REJECTED" --yes
assert_nonzero "4: a real validation rejection (multiple ERRORs) stops the run" "$LAST_RC"
check "4: a real error message is shown" "$LAST_ERR" "NON_UNIQUE_STATUS_NAME"
check "4: refuses before the update call, naming why" "$LAST_ERR" "refusing to write"
check_not "4: the stub's write-refusal never had to fire (validation stopped it first)" "$LAST_ERR" "STUB: refusing"

# =================================================================
# 5. A REAL WARNING-only response (zero ERRORs, six WARNINGs —
#    workflows.update.validation.spk4-warnings-only.txt) is printed but
#    does NOT stop the run — validate_update_body's WARNING branch warns
#    and continues, unlike its ERROR branch.
# =================================================================
WRAP_NWM_WARNONLY="$TMPD/wrap-nwm-warnonly.sh"
make_stub "$WRAP_NWM_WARNONLY" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_WARNINGS_ONLY" 0
run nwm5 NWM --jira-api "$WRAP_NWM_WARNONLY" --dry-run
assert_eq "5: a WARNING-only validation result does not stop --dry-run" "0" "$LAST_RC"
check "5: the warning is shown" "$LAST_ERR" "NO_INBOUND_TRANSITIONS_TO_STATUS"
check "5: says how many warnings" "$LAST_ERR" "reported 6 warning(s)"
check "5: still reaches the final-body preview" "$LAST_OUT" "validation passed"

# =================================================================
# 6. Without --yes and without --dry-run: a REAL validation success still
#    stops before the update call (--yes gate), after showing the full
#    body — and exits the DISTINCT code 3 (ROUND-2 REVIEW ITEM 6), not the
#    generic failure code 1.
# =================================================================
run noyes2 NWM --jira-api "$WRAP_NWM_OK"
assert_eq "6: no --yes and no --dry-run exits the distinct code 3, not 1" "3" "$LAST_RC"
check "6: refusal names the reason" "$LAST_ERR" "not confirmed"
check "6: the final body was still shown before stopping" "$LAST_OUT" "workflows"
check_not "6: the update endpoint was never reached" "$(cat "$TMPD/$(basename "$WRAP_NWM_OK").calllog")" "workflows/update "

# =================================================================
# 7. THE STUB ITSELF fails the run if jira-workflow-apply.sh issues a
#    `write POST /workflows/update` in a case that should never reach it —
#    proven by observing it actually fire, not merely assumed. Force this
#    by handing --yes to a stub explicitly configured to REFUSE the update
#    call (allow_update=0) with a real validation success — if the
#    script's own --yes gate were broken, this would trip the refusal.
# =================================================================
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

# =================================================================
# 8. assert_readback's own two branches, exercised for real: a stub that
#    ALLOWS exactly one write POST /workflows/update (so the script's
#    happy path can actually complete), then serves either (a) LAB's REAL
#    complete workflow (PASS) or (b) the same with "Deferred" stripped
#    (FAIL, and names it) — see ROUND-2 REVIEW ITEM 7 / this file's header.
# =================================================================
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

# =================================================================
# 9. ROUND-2 REVIEW ITEM 1 — an unparseable-or-`errors`-key-less 2xx from
#    /validation is a hard die naming the raw response, not silently
#    "zero errors".
# =================================================================
WRAP_NOERRORSKEY="$TMPD/wrap-noerrorskey.sh"
make_stub "$WRAP_NOERRORSKEY" "$NWM_WORKFLOW" "$NWM_WORKFLOW" "$VALIDATION_NO_ERRORS_KEY" 0
run noerrorskey NWM --jira-api "$WRAP_NOERRORSKEY" --dry-run
assert_nonzero "9: a 2xx validation response with no 'errors' array is a hard die" "$LAST_RC"
check "9: names the problem, not a silent pass" "$LAST_ERR" "no 'errors' array"
check "9: shows the raw (already-redacted) response" "$LAST_ERR" "acknowledged"

# =================================================================
# 10. ROUND-3 REVIEW ITEM 3 — a post-write re-read whose per-transition
#     rule ARRAYS differ at all (full jq deep equality, not merely a
#     count) from the pre-write snapshot's is a hard stop at the DISTINCT
#     exit code 2, naming the transition. The stub serves the REAL,
#     unmodified NWM bulk-get fixture for the FIRST `write POST
#     /workflows` call (used to build FINAL_BODY and as the
#     before-snapshot) and the emptied-`actions` variant for the SECOND
#     (the post-write re-read) — the exact shape found live on SPK4.
# =================================================================
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

# =================================================================
# 10b/10c. ROUND-4 REVIEW ITEM 1 — the REAL before/after pair from the
#     actual successful ZZPROBE apply. A rule entry's OWN `id` changing
#     (Jira regenerates a validator's uuid on every write) must NOT trip
#     the diff (10b); a rule's ruleKey or parameters actually changing —
#     its real identity — still must (10c). Both use PROJECT_KEY=ZZPROBE
#     and the exact real fixtures, not synthetic ones — this is the
#     regression test for a false positive that actually happened live.
# =================================================================
# workflow_second is LAB's REAL complete workflow (same trick as section
# 8's readback-pass) — assert_readback's own re-read after the write needs
# to see all 9 target statuses/transitions present, and ZZPROBE_WORKFLOW
# (workflow/search, 3 statuses) is the PRE-write state, not post.
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

# =================================================================
# 11. ROUND-2 REVIEW ITEM 4 — a target transition id (here: 51, "Open")
#     that already belongs to a DIFFERENT existing transition name is a
#     hard die naming the collision, before anything else about that
#     project runs.
# =================================================================
WRAP_COLLISION="$TMPD/wrap-collision.sh"
make_stub "$WRAP_COLLISION" "$WORKFLOW_ID_COLLISION" "$WORKFLOW_ID_COLLISION" "$VALIDATION_SUCCESS" 0
run collision NWM --jira-api "$WRAP_COLLISION" --dry-run
assert_nonzero "11: a target transition id already owned by a different name is a hard die" "$LAST_RC"
check "11: names the colliding id" "$LAST_ERR" "transition id 51"
check "11: names the unexpected existing owner" "$LAST_ERR" "Some Unrelated Transition"
check "11: names what this script would have called it instead" "$LAST_ERR" "not 'Open'"
check_not "11: never reaches the bulk-get (dies before any write-path call)" "$(cat "$TMPD/$(basename "$WRAP_COLLISION").calllog")" "write POST"

# =================================================================
# 12. --restore-from (ROUND-3 REVIEW ITEM 4).
#     (a) a file containing the literal string "<redacted>" is refused
#         BEFORE any network call — proven with a stub that refuses
#         literally everything; if the redaction check happened after a
#         read, this case would trip the stub's own refusal instead of
#         the intended message.
#     (b) a clean --show-secrets-era file renders and validates a restore
#         body with a freshly-fetched version, reaching the same
#         validate-and-print path as the normal flow (--dry-run stops it
#         there, same as always).
# =================================================================
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

# =================================================================
# 13. Argument validation — a script that earns its place fails loudly on
#     a bad PROJECT_KEY or a missing --jira-api, rather than silently
#     doing nothing useful.
# =================================================================
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

# =================================================================
# 14. --rules, against the REAL SPK4 rehearsal captures.
# =================================================================
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
