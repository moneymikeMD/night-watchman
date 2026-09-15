#!/bin/bash
#
# Selftest for jira-space-create.sh. Runs entirely against a fake
# `jira-api.sh`-shaped stub script and a fake `jira-workflow-apply.sh`-
# shaped stub script (never the real wrapper, never a real workflow-apply
# run, never a real Jira site or credential) that replay fixtures captured
# under fixtures/space-*.txt. `--jira-api`/`--workflow-apply` point
# straight at those stubs, so there is no `curl` at all in this file's own
# process tree; `NW_JIRA_HOST=127.0.0.1` is exported anyway, belt and
# braces, in case a future edit ever calls the real jira-api.sh by
# accident.
#
# FIXTURE PROVENANCE — READ THIS: every fixtures/space-*.txt file is
# AUTHORED, not captured live. This fixture was built with no live Jira host
# reachable (the orchestrator runs that spike separately, per this
# project's own "live spike first for API-facing scripts" rule — see
# memorygraph). Each fixture's own header says so and names which Jira
# Cloud REST v3 documented shape it is drawn from. This is a KNOWN
# DEVIATION from this project's "fixtures are recorded, never authored"
# rule (skills/shell-scripting/SKILL.md) — flagged here rather than
# silently shipped as if it were the real thing. Before this script is
# trusted at the same level as providers/tracker/jira/jira-workflow-apply.sh (whose
# fixtures ARE real, from a real SPK4/NWM/ZZPROBE spike), re-run the
# recipe against one throwaway project and re-record every fixtures/
# space-*.txt file from what Jira Cloud actually returns.
#
# What this file proves:
#   1. --dry-run: every planned request goes through `jira-api.sh
#      --dry-run` (or is announced without ever invoking the wrapper, for
#      step 3 — see jira-space-create.sh's own header on why); the stub
#      NEVER sees a write call without --dry-run also present in the same
#      invocation.
#   2. KEY/Name argument validation refusals — no wrapper call at all.
#   3. No --yes and no terminal: refused with the distinct exit code 3.
#   4. A Business/next-gen project readback (style != "classic", no Epic
#      issue type) is refused BEFORE creating any status, field or screen
#      entry — a lesson learned live.
#   5. Happy path against an ALREADY-EXISTING classic project: five of six
#      target fields already present (idempotent no-op), "executor"
#      created; two of three executor options already present (idempotent
#      no-op), two created; five of six fields already on the project's
#      one screen (idempotent no-op), "executor" added; the final
#      customfield-id table names all six fields.
#   6. A custom field that already exists under the WRONG schema type is
#      refused, naming the mismatch, before any write.
#   7. THE ZZSPIKE REGRESSION — a real 404 on the initial project GET (the
#      "not found" branch case 5's already-existing project never
#      exercises) leads to a real POST /project with the right key/name/
#      lead in the body, then the post-create readback, all the way
#      through to "bootstrap complete". Found live: `rc=$?` placed AFTER
#      the closing `fi` of an `if ...; then ...; fi` with no `else` reads
#      the if-COMPOUND's own exit status (0, once execution falls through
#      to after `fi`) rather than the real command's — every 404 used to
#      look like an unparseable error and the run died before ever
#      creating anything.
#   8. A GET /project/<KEY> failure that is NOT a 404 is still a hard die
#      ("refusing to guess whether it exists"), never a false "not found"
#      that would attempt to create a project that already exists.
#   9. An already-on-screen field is an idempotent no-op (derived variant
#      of a real tab-fields fixture — see its own comment above section
#      5, and section 5's own note on why the real ZZSPIKE capture alone
#      cannot exercise this branch).
#  10. THE ZZSPIKE RUN 4 REGRESSION — a fully idempotent rerun (nothing
#      to create/add anywhere) issues ZERO writes, and its own output no
#      longer false-matches `grep 'creating'` the way the old "...not
#      creating." wording did on a real, genuinely idempotent run.
#  11. SCRIPT-REVIEWER HIGH — a malformed /screens/<id>/tabs response is a
#      hard die naming the screen, not a silently-skipped screen that
#      still reaches "bootstrap complete".
#  12. SCRIPT-REVIEWER MEDIUM — a custom field name matching MORE THAN ONE
#      field (Jira does not enforce unique names) is a hard die naming
#      every colliding id, not a silent first-match.
#
# THE SCREEN-SCHEME CHAIN (section 5's fixtures): RECORDED LIVE against
# ZZSPIKE, run 2, 2026-09-12 (read-only calls only) — the ZZSPIKE
# regression this same live loop found (GET /screenscheme/<id> does not
# exist; see jira-space-create.sh's own header) meant the step-5 chain's
# fixtures used to be authored guesses same as the rest of
# fixtures/space-*.txt; they are now the one part of this recipe that IS
# real. Everything else under fixtures/space-*.txt remains authored — see
# FIXTURE PROVENANCE above.
#
# Usage: ./jira-space-create-selftest.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/jira-space-create.sh"
FIXDIR="$HERE/fixtures"

export NW_JIRA_HOST=127.0.0.1

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

strip_fixture_header() {
    awk '/^#/{next} /^HTTP [0-9]+$/{next} {print}' "$1"
}

# --------------------------------------------------------------- fixtures
PROJECT_CLASSIC="$TMPD/project-classic.json"
strip_fixture_header "$FIXDIR/space-project-classic.txt" > "$PROJECT_CLASSIC"
PROJECT_BUSINESS="$TMPD/project-business.json"
strip_fixture_header "$FIXDIR/space-project-business.txt" > "$PROJECT_BUSINESS"
PROJECT_CREATE_RESP="$TMPD/project-create-resp.json"
strip_fixture_header "$FIXDIR/space-project-create-response.txt" > "$PROJECT_CREATE_RESP"
WHOAMI="$TMPD/whoami.json"
strip_fixture_header "$FIXDIR/space-whoami.txt" > "$WHOAMI"
FIELDS_EXISTING="$TMPD/fields-existing.json"
strip_fixture_header "$FIXDIR/space-fields-existing.txt" > "$FIELDS_EXISTING"
FIELDS_AFTER_EXECUTOR="$TMPD/fields-after-executor.json"
strip_fixture_header "$FIXDIR/space-fields-after-executor-create.txt" > "$FIELDS_AFTER_EXECUTOR"
FIELDS_WRONGTYPE="$TMPD/fields-wrongtype.json"
strip_fixture_header "$FIXDIR/space-fields-wrongtype.txt" > "$FIELDS_WRONGTYPE"
# DERIVED (not its own fixture file) from the real fields-existing
# capture: "touches" duplicated under a SECOND id — Jira does not
# enforce unique custom field names, so this is a real shape the site
# can produce, exercised here without waiting for a live site to
# actually have one.
FIELDS_DUPLICATE_NAME="$TMPD/fields-duplicate-name.json"
jq '. + [{"id": "customfield_19998", "name": "touches", "custom": true, "schema": {"type": "string", "custom": "com.atlassian.jira.plugin.system.customfieldtypes:textarea"}}]' \
    "$FIELDS_EXISTING" > "$FIELDS_DUPLICATE_NAME"
FIELD_CREATE_EXECUTOR="$TMPD/field-create-executor.json"
strip_fixture_header "$FIXDIR/space-field-create-executor.txt" > "$FIELD_CREATE_EXECUTOR"
FIELD_CONTEXT="$TMPD/field-context.json"
strip_fixture_header "$FIXDIR/space-field-context.txt" > "$FIELD_CONTEXT"
FIELD_OPTIONS_PARTIAL="$TMPD/field-options-partial.json"
strip_fixture_header "$FIXDIR/space-field-options-partial.txt" > "$FIELD_OPTIONS_PARTIAL"
# ITSS_PROJECT/ITSS_MAPPING/SCREENSCHEME/SCREENS_TABS_*/TAB_FIELDS_* below
# are all RECORDED LIVE (ZZSPIKE run 2, read-only, 2026-09-12) — the one
# part of this recipe that was NOT authored, unlike the rest of
# fixtures/space-*.txt (see this file's own FIXTURE PROVENANCE note
# above). PROJECT_CLASSIC's own .id ("10017") was set to match this same
# real project, so the whole chain is internally consistent.
ITSS_PROJECT="$TMPD/itss-project.json"
strip_fixture_header "$FIXDIR/space-itss-project.txt" > "$ITSS_PROJECT"
ITSS_MAPPING="$TMPD/itss-mapping.json"
strip_fixture_header "$FIXDIR/space-itss-mapping.txt" > "$ITSS_MAPPING"
SCREENSCHEME="$TMPD/screenscheme.json"
strip_fixture_header "$FIXDIR/space-screenscheme.txt" > "$SCREENSCHEME"
SCREENS_TABS_10049="$TMPD/screens-tabs-10049.json"
strip_fixture_header "$FIXDIR/space-screens-tabs-10049.txt" > "$SCREENS_TABS_10049"
SCREENS_TABS_10050="$TMPD/screens-tabs-10050.json"
strip_fixture_header "$FIXDIR/space-screens-tabs-10050.txt" > "$SCREENS_TABS_10050"
SCREENS_TABS_10051="$TMPD/screens-tabs-10051.json"
strip_fixture_header "$FIXDIR/space-screens-tabs-10051.txt" > "$SCREENS_TABS_10051"
# SYNTHETIC — not a real capture, deliberately malformed (a bare object,
# not the array /screens/<id>/tabs always returns) — exercises
# add_fields_to_screens' own `tab_ids=$(... jq ...) || die` guard: a jq
# parse failure here must stop the run, not silently make that screen's
# tab loop run zero times.
SCREENS_TABS_10049_MALFORMED="$TMPD/screens-tabs-10049-malformed.json"
echo '{"this is not": "an array of tabs"}' > "$SCREENS_TABS_10049_MALFORMED"
TAB_FIELDS_10052="$TMPD/tab-fields-10052.json"
strip_fixture_header "$FIXDIR/space-tab-fields-10052.txt" > "$TAB_FIELDS_10052"
TAB_FIELDS_10053="$TMPD/tab-fields-10053.json"
strip_fixture_header "$FIXDIR/space-tab-fields-10053.txt" > "$TAB_FIELDS_10053"
TAB_FIELDS_10054="$TMPD/tab-fields-10054.json"
strip_fixture_header "$FIXDIR/space-tab-fields-10054.txt" > "$TAB_FIELDS_10054"
# Searchability probe — RECORDED LIVE 2026-09-14 against project
# NWM itself (a throwaway textarea field, created and deleted for the
# capture — see each fixture's own header for the full chain).
SEARCH_JQL_NOT_SEARCHABLE="$TMPD/search-jql-not-searchable.json"
strip_fixture_header "$FIXDIR/space-search-jql-not-searchable.txt" > "$SEARCH_JQL_NOT_SEARCHABLE"
SEARCH_JQL_SEARCHABLE="$TMPD/search-jql-searchable.json"
strip_fixture_header "$FIXDIR/space-search-jql-searchable.txt" > "$SEARCH_JQL_SEARCHABLE"
# DERIVED (not its own recorded fixture) from the REAL tab-fields-10052
# capture: "touches" (customfield_10043) added as if it were already on
# that one tab, so the idempotent-skip path on an ALREADY-PRESENT screen
# field has coverage too — the real capture (see space-tab-fields-
# 10052.txt's own header) happened to show every target field absent, so
# this is the only way to exercise that branch honestly labelled as
# derived, not itself a live observation.
TAB_FIELDS_10052_WITH_TOUCHES="$TMPD/tab-fields-10052-with-touches.json"
jq '. + [{"id": "customfield_10043", "name": "touches"}]' "$TAB_FIELDS_10052" > "$TAB_FIELDS_10052_WITH_TOUCHES"

# ALL SIX target fields already present, DERIVED from each real
# tab-fields-* capture the same way — used only for the fully-idempotent
# rerun test (10, the ZZSPIKE run 4 regression: a real re-run with
# nothing left to do). Real ZZSPIKE run 4 was never itself this file's
# source (a fully-idempotent second run makes zero writes and so
# produces no NEW response bodies to capture beyond what run 2/3 already
# gave — the fixtures below ARE run 2/3's own real bodies, just each with
# the six fields this recipe would have added by the time a real rerun
# happens).
ALL_SIX_FIELDS='{"id": "customfield_10043", "name": "touches"}
{"id": "customfield_10044", "name": "executor"}
{"id": "customfield_10045", "name": "verify"}
{"id": "customfield_10046", "name": "human_steps"}
{"id": "customfield_10047", "name": "appends"}
{"id": "customfield_10048", "name": "defer_until"}'
ALL_SIX_FIELDS_JSON=$(printf '%s\n' "$ALL_SIX_FIELDS" | jq -cs .)
TAB_FIELDS_10052_ALL="$TMPD/tab-fields-10052-all.json"
jq --argjson add "$ALL_SIX_FIELDS_JSON" '. + $add' "$TAB_FIELDS_10052" > "$TAB_FIELDS_10052_ALL"
TAB_FIELDS_10053_ALL="$TMPD/tab-fields-10053-all.json"
jq --argjson add "$ALL_SIX_FIELDS_JSON" '. + $add' "$TAB_FIELDS_10053" > "$TAB_FIELDS_10053_ALL"
TAB_FIELDS_10054_ALL="$TMPD/tab-fields-10054-all.json"
jq --argjson add "$ALL_SIX_FIELDS_JSON" '. + $add' "$TAB_FIELDS_10054" > "$TAB_FIELDS_10054_ALL"

# All three executor options already present, DERIVED from the real
# partial capture the same way.
FIELD_OPTIONS_FULL="$TMPD/field-options-full.json"
jq '.values += [{"id": "10301", "value": "human"}, {"id": "10302", "value": "mixed"}]' "$FIELD_OPTIONS_PARTIAL" > "$FIELD_OPTIONS_FULL"

# --------------------------------------------------------------- workflow-apply stub
#
# workflow_apply_stub PATH RC — a jira-workflow-apply.sh-shaped stub that
# only ever needs to record that it was called with the right args and
# report success/failure; its OWN internal correctness is
# jira-workflow-apply-selftest.sh's job, not this file's.
WFCALLLOG=""
make_workflow_apply_stub() {
    local path="$1" rc="${2:-0}"
    WFCALLLOG="$TMPD/$(basename "$path").calllog"
    cat > "$path" <<STUBEOF
#!/bin/bash
printf '%s\n' "\$*" >> "$WFCALLLOG"
exit $rc
STUBEOF
    chmod +x "$path"
}

# --------------------------------------------------------------- jira-api stub
#
# make_jira_api_stub PATH — dispatches on the request's own METHOD/PATH
# (after stripping --show-secrets/--yes/--dry-run, in any order — same
# convention as jira-workflow-apply-selftest.sh). Logs the RAW (unstripped)
# argv first, so a test can tell whether --dry-run accompanied a call.
# Refuses (exit 97) any request this scenario did not expect, so an
# accidental extra call fails loudly rather than silently returning
# nothing.
CALLLOG=""
make_jira_api_stub() {
    local path="$1"
    CALLLOG="$TMPD/$(basename "$path").calllog"
    : > "$CALLLOG"
    local field_counter zznew_counter
    field_counter="$TMPD/$(basename "$path").field-counter"
    : > "$field_counter"
    zznew_counter="$TMPD/$(basename "$path").zznew-counter"
    : > "$zznew_counter"
    cat > "$path" <<STUBEOF
#!/bin/bash
printf '%s\n' "\$*" >> "$CALLLOG"
DRY=0
while true; do
    case "\$1" in
        --dry-run) DRY=1; shift ;;
        --yes|--show-secrets) shift ;;
        *) break ;;
    esac
done
if [ "\$DRY" = "1" ]; then
    echo "would issue: \$*"
    exit 0
fi
case "\$1 \$2" in
    "raw GET")
        case "\$3" in
            /project/ZZSPACE) cat "$PROJECT_CLASSIC" ;;
            /project/ZZBIZ) cat "$PROJECT_BUSINESS" ;;
            /project/ZZNEW)
                # 1st call: the soft existence check, a real 404 shape
                # (rc=1, stderr line "jira-api: HTTP 404 GET <path>").
                # 2nd call: the post-create readback. See section 7 in
                # this file's own header for the bug this exercises.
                n=\$(cat "$zznew_counter"); n=\$((n + 1)); echo "\$n" > "$zznew_counter"
                if [ "\$n" = "1" ]; then
                    echo "not found" >&2
                    echo "jira-api: HTTP 404 GET /project/ZZNEW" >&2
                    exit 1
                else
                    cat "$PROJECT_CLASSIC"
                fi
                ;;
            /project/ZZERR)
                echo "internal server error" >&2
                echo "jira-api: HTTP 500 GET /project/ZZERR" >&2
                exit 1
                ;;
            /myself) cat "$WHOAMI" ;;
            /field)
                if [ -n "\${FIELDS_FIXTURE:-}" ]; then
                    cat "\$FIELDS_FIXTURE"
                else
                    n=\$(cat "$field_counter"); n=\$((n + 1)); echo "\$n" > "$field_counter"
                    if [ "\$n" = "1" ]; then cat "$FIELDS_EXISTING"; else cat "$FIELDS_AFTER_EXECUTOR"; fi
                fi
                ;;
            /field/customfield_10044/context) cat "$FIELD_CONTEXT" ;;
            /field/customfield_10044/context/10200/option)
                if [ -n "\${FIELD_OPTIONS_OVERRIDE:-}" ]; then cat "\$FIELD_OPTIONS_OVERRIDE"; else cat "$FIELD_OPTIONS_PARTIAL"; fi
                ;;
            "/issuetypescreenscheme/project?projectId=10017") cat "$ITSS_PROJECT" ;;
            "/issuetypescreenscheme/mapping?issueTypeScreenSchemeId=10017") cat "$ITSS_MAPPING" ;;
            # ONLY the repeated-id query form is ever answered — the
            # comma-joined form (id=10049,10050,10051) falls through to
            # the wildcard refusal below, same as any other call this
            # scenario did not expect. That IS the "assert the comma-form
            # is never used" guard: if jira-space-create.sh ever sent it,
            # this stub could not serve it and the whole run would die
            # with "STUB: no fixture", not silently succeed.
            "/screenscheme?id=10049&id=10050&id=10051") cat "$SCREENSCHEME" ;;
            /screens/10049/tabs)
                if [ -n "\${SCREENS_TABS_10049_OVERRIDE:-}" ]; then cat "\$SCREENS_TABS_10049_OVERRIDE"; else cat "$SCREENS_TABS_10049"; fi
                ;;
            /screens/10050/tabs) cat "$SCREENS_TABS_10050" ;;
            /screens/10051/tabs) cat "$SCREENS_TABS_10051" ;;
            /screens/10049/tabs/10052/fields)
                if [ -n "\${TAB_FIELDS_10052_OVERRIDE:-}" ]; then cat "\$TAB_FIELDS_10052_OVERRIDE"; else cat "$TAB_FIELDS_10052"; fi
                ;;
            /screens/10050/tabs/10053/fields)
                if [ -n "\${TAB_FIELDS_10053_OVERRIDE:-}" ]; then cat "\$TAB_FIELDS_10053_OVERRIDE"; else cat "$TAB_FIELDS_10053"; fi
                ;;
            /screens/10051/tabs/10054/fields)
                if [ -n "\${TAB_FIELDS_10054_OVERRIDE:-}" ]; then cat "\$TAB_FIELDS_10054_OVERRIDE"; else cat "$TAB_FIELDS_10054"; fi
                ;;
            /search/jql\?jql=*)
                # ensure_field_searchable's own probe. \$FORCE_UNSEARCHABLE
                # (space-separated field names) names fields whose FIRST
                # probe this run must answer "not searchable" (HTTP 400) —
                # every later probe for that same name (the re-probe after
                # the PUT this scenario expects) answers 200. Any name not
                # listed is searchable from its first probe: no PUT, no
                # extra write to assert against.
                qs="\$3"
                forced=0
                for want in \${ALWAYS_UNSEARCHABLE:-}; do
                    case "\$qs" in
                        *"%22\$want%22"*) forced=1 ;;
                    esac
                done
                for want in \${FORCE_UNSEARCHABLE:-}; do
                    case "\$qs" in
                        *"%22\$want%22"*)
                            cf="$TMPD/probe-\$want.count"
                            n=\$(cat "\$cf" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$cf"
                            if [ "\$n" = "1" ]; then forced=1; fi
                            ;;
                    esac
                done
                if [ "\$forced" = "1" ]; then
                    cat "$SEARCH_JQL_NOT_SEARCHABLE" >&2
                    echo "jira-api: HTTP 400 GET \$qs" >&2
                    exit 1
                fi
                cat "$SEARCH_JQL_SEARCHABLE"
                ;;
            *) echo "STUB: no fixture for raw GET \$3" >&2; exit 98 ;;
        esac
        ;;
    "write POST")
        case "\$3" in
            /project) cat "$PROJECT_CREATE_RESP" ;;
            /field) cat "$FIELD_CREATE_EXECUTOR" ;;
            /field/customfield_10044/context/10200/option) echo '{}' ;;
            /screens/10049/tabs/10052/fields) echo '{}' ;;
            /screens/10050/tabs/10053/fields) echo '{}' ;;
            /screens/10051/tabs/10054/fields) echo '{}' ;;
            *) echo "STUB: no handler for write POST \$3" >&2; exit 98 ;;
        esac
        ;;
    "write PUT")
        case "\$3" in
            /field/*) echo '{}' ;;
            *) echo "STUB: no handler for write PUT \$3" >&2; exit 98 ;;
        esac
        ;;
    *) echo "STUB: refusing unexpected call: \$*" >&2; exit 97 ;;
esac
STUBEOF
    chmod +x "$path"
}

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
# 1. --dry-run: every planned request goes through the stub WITH
#    --dry-run, or (step 3) is announced without ever invoking any
#    wrapper at all. The stub never sees a write call missing --dry-run.
# =================================================================
WRAP_DRY="$TMPD/wrap-dry.sh"
make_jira_api_stub "$WRAP_DRY"
run dryrun ZZSPACE "ZZ Space" --dry-run --jira-api "$WRAP_DRY"
assert_eq "1: --dry-run exits 0" "0" "$LAST_RC"
check "1: announces step 1 (project)" "$LAST_OUT" "read-or-create the project"
check "1: announces step 2 (ASSERT)" "$LAST_OUT" "would then ASSERT"
check "1: announces step 3 without invoking a real workflow-apply wrapper" "$LAST_OUT" "not invoked here"
check "1: announces step 4 (fields)" "$LAST_OUT" "discover-or-create these custom fields"
check "1: announces the searchability probe" "$LAST_OUT" "would probe searchability"
check "1: the probe GET is a real (dry-run) wrapper call, e.g. for touches" "$LAST_OUT" 'would issue: raw GET /search/jql?jql=project%20%3D%20ZZSPACE%20AND%20%22touches%22%20is%20EMPTY&fields=key&maxResults=1'
check "1: announces the searcherKey repair PUT" "$LAST_OUT" "would repair with"
check "1: announces step 6 (table)" "$LAST_OUT" "would print a table"
DRYCALLLOG="$TMPD/$(basename "$WRAP_DRY").calllog"
assert_nonempty "1: the stub was actually reached for the parts this script does call directly" "$DRYCALLLOG"
check_not "1: no call reached the stub without --dry-run present in the SAME invocation" "$(awk '!/--dry-run/' "$DRYCALLLOG")" "write POST"

# =================================================================
# 2. Argument validation — no wrapper call at all.
# =================================================================
run badkeylower zz1 "Test" --dry-run --jira-api "$WRAP_DRY"
assert_nonzero "2a: a lowercase KEY is refused" "$LAST_RC"
check "2a: names the problem" "$LAST_ERR" "uppercase letter"

run badkeyshort Z "Test" --dry-run --jira-api "$WRAP_DRY"
assert_nonzero "2b: a 1-character KEY is refused" "$LAST_RC"
check "2b: names the length rule" "$LAST_ERR" "2-10 characters"

run badkeylong ZABCDEFGHIJ "Test" --dry-run --jira-api "$WRAP_DRY"
assert_nonzero "2c: an 11-character KEY is refused" "$LAST_RC"
check "2c: names the length rule" "$LAST_ERR" "2-10 characters"

run noname ZZSPACE --dry-run --jira-api "$WRAP_DRY"
assert_nonzero "2d: a missing Name is refused" "$LAST_RC"
check "2d: names the problem" "$LAST_ERR" "Name is required"

run nokeyname
assert_nonzero "2e: no arguments at all is refused" "$LAST_RC"

# =================================================================
# 3. No --yes and no terminal: refused with the distinct exit code 3.
# =================================================================
WRAP_NOYES="$TMPD/wrap-noyes.sh"
make_jira_api_stub "$WRAP_NOYES"
run noyes ZZSPACE "ZZ Space" --jira-api "$WRAP_NOYES"
assert_eq "3: no --yes, no terminal exits the distinct code 3" "3" "$LAST_RC"
check "3: names why" "$LAST_ERR" "no --yes and no terminal"
assert_eq "3: never reached the wrapper at all (refused before any network call)" "" "$(cat "$TMPD/$(basename "$WRAP_NOYES").calllog")"

# =================================================================
# 4. A Business/next-gen project readback is refused before creating any
#    status, field or screen entry — a lesson learned live.
# =================================================================
WRAP_BIZ="$TMPD/wrap-biz.sh"
make_jira_api_stub "$WRAP_BIZ"
WF_BIZ="$TMPD/wf-biz.sh"
make_workflow_apply_stub "$WF_BIZ" 0
run business ZZBIZ "ZZ Biz" --yes --jira-api "$WRAP_BIZ" --workflow-apply "$WF_BIZ"
assert_nonzero "4: a Business/next-gen project readback is refused" "$LAST_RC"
check "4: names the lesson learned live" "$LAST_ERR" "Business project"
check "4: names the actual style found" "$LAST_ERR" "next-gen"
assert_nonempty "4: the wrapper was reached (proves the refusal is real, not vacuous)" "$TMPD/$(basename "$WRAP_BIZ").calllog"
BIZLOG="$TMPD/$(basename "$WRAP_BIZ").calllog"
check_not "4: never reached POST /project (no create attempted against an existing project)" "$(cat "$BIZLOG")" "write POST /project"
assert_eq "4: jira-workflow-apply.sh was never invoked" "" "$(cat "$TMPD/$(basename "$WF_BIZ").calllog" 2>/dev/null || true)"

# =================================================================
# 5. Happy path, project ALREADY EXISTS (classic): idempotent no-ops
#    where fixtures already carry the field/option, real create/add calls
#    where they do not, and the final table names all six fields with
#    real (fixture) ids. The screen-scheme chain here (steps 5's project/
#    mapping/screenscheme/tabs/fields calls) replays the REAL ZZSPIKE run
#    2 capture — three distinct screens (default/Bug/Epic), one tab each,
#    none of the six target fields present on any of them yet, so all
#    six get added to all three (18 adds) — see this file's own header,
#    section 5, and space-tab-fields-1005{2,3,4}.txt's own headers.
# =================================================================
WRAP_HAPPY="$TMPD/wrap-happy.sh"
make_jira_api_stub "$WRAP_HAPPY"
WF_HAPPY="$TMPD/wf-happy.sh"
make_workflow_apply_stub "$WF_HAPPY" 0
run happy ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_HAPPY" --workflow-apply "$WF_HAPPY"
assert_eq "5: the happy path exits 0" "0" "$LAST_RC"
check "5: says the project already exists (idempotent — no creation)" "$LAST_OUT" "already exists"
HAPPYLOG="$TMPD/$(basename "$WRAP_HAPPY").calllog"
check_not "5: no POST /project was issued for an already-existing project" "$(cat "$HAPPYLOG")" "write POST /project "
check "5: jira-workflow-apply.sh was invoked with the right project key" "$(cat "$TMPD/$(basename "$WF_HAPPY").calllog")" "ZZSPACE"
check "5: jira-workflow-apply.sh was invoked with --yes" "$(cat "$TMPD/$(basename "$WF_HAPPY").calllog")" "--yes"
check "5: an already-present field is reported as a no-op" "$LAST_OUT" "field 'touches' already present"
check "5: the absent field (executor) is reported as created" "$LAST_OUT" "field 'executor' absent — creating"
check "5: an already-present executor option is a no-op" "$LAST_OUT" "executor option 'agent' already present"
check "5: an absent executor option is added" "$LAST_OUT" "executor option 'human' absent — adding"
check "5: the ONE bulk screen-scheme call used the repeated-id form" "$(cat "$HAPPYLOG")" "raw GET /screenscheme?id=10049&id=10050&id=10051"
check_not "5: the comma-joined screenscheme form was never sent" "$(cat "$HAPPYLOG")" "screenscheme?id=10049,10050,10051"
check "5: touches was added to the default screen (10049/10052)" "$LAST_OUT" "field 'touches' absent from screen 10049 / tab 'Field Tab' — adding"
check "5: defer_until was added to the Bug screen (10050/10053)" "$LAST_OUT" "field 'defer_until' absent from screen 10050 / tab 'Field Tab' — adding"
check "5: executor was added to the Epic screen (10051/10054)" "$LAST_OUT" "field 'executor' absent from screen 10051 / tab 'Field Tab' — adding"
ADDCOUNT=$(grep -cE "write POST /screens/(10049|10050|10051)/tabs/(10052|10053|10054)/fields" "$HAPPYLOG")
assert_eq "5: all six fields were added to all three screens (6*3=18 adds, no idempotent skip in the real captured state)" "18" "$ADDCOUNT"
check "5: the final table names touches" "$LAST_OUT" "customfield_10043"
check "5: the final table names executor's real (fixture) id" "$LAST_OUT" "customfield_10044"
check "5: the final table names defer_until" "$LAST_OUT" "customfield_10048"
check "5: bootstrap-complete banner shown" "$LAST_OUT" "bootstrap complete"
# ZZSPIKE run 3 cosmetic bug: the table printed a LITERAL backslash-t
# between columns ("customfield_10043\ttouches\t...") because a
# double-quoted string's \t is not an escape — only printf's is. column
# -t (this repo's own `table` helper) turns real tabs into aligned
# spaces, so a literal "\t" surviving into the output can only mean the
# row was built with the string-interpolation bug, not a real tab.
check_not "5: no literal backslash-t leaked into the final table (real tabs, column-aligned like the header)" "$LAST_OUT" '\t'

# =================================================================
# 6. A field that already exists under the WRONG schema type is refused,
#    naming the mismatch, before any write.
# =================================================================
WRAP_WRONGTYPE="$TMPD/wrap-wrongtype.sh"
make_jira_api_stub "$WRAP_WRONGTYPE"
FIELDS_FIXTURE="$FIELDS_WRONGTYPE"
export FIELDS_FIXTURE
WF_WRONGTYPE="$TMPD/wf-wrongtype.sh"
make_workflow_apply_stub "$WF_WRONGTYPE" 0
run wrongtype ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_WRONGTYPE" --workflow-apply "$WF_WRONGTYPE"
unset FIELDS_FIXTURE
assert_nonzero "6: an existing field under the wrong schema type is refused" "$LAST_RC"
check "6: names the field" "$LAST_ERR" "touches"
check "6: names the mismatch" "$LAST_ERR" "not the expected"
WRONGTYPELOG="$TMPD/$(basename "$WRAP_WRONGTYPE").calllog"
check_not "6: never issued a write for the mismatched field" "$(cat "$WRONGTYPELOG")" "write POST /field "

# =================================================================
# 7. The 404-then-create path (ZZSPIKE regression). This is the case the
#    happy path (5) does NOT cover — 5's project already exists, so it
#    never exercises jira_get_soft's real "not found" branch at all.
#    Found live: `rc=$?` placed AFTER the `if existing=$(...); then ...;
#    fi` block (no `else`) reads the IF-COMPOUND's own exit status once
#    execution falls through past `fi` — 0, because the untaken `then`
#    branch is what "the compound succeeded" means here — never
#    jira_get_soft's real 1 for a 404. So a real 404 used to hit the
#    "unexpected error" die below unconditionally, and no project was
#    ever created. Fixed: `existing=$(...); rc=$?` on ONE line, then
#    branch on $rc explicitly.
# =================================================================
WRAP_CREATE="$TMPD/wrap-create.sh"
make_jira_api_stub "$WRAP_CREATE"
WF_CREATE="$TMPD/wf-create.sh"
make_workflow_apply_stub "$WF_CREATE" 0
run create ZZNEW "ZZ New Space" --yes --lead 5f9a1111aaaa2222bbbb3333 \
    --jira-api "$WRAP_CREATE" --workflow-apply "$WF_CREATE"
assert_eq "7: a real 404-then-create run exits 0" "0" "$LAST_RC"
check "7: reports the project does not exist and is being created" "$LAST_OUT" "does not exist — creating it"
CREATELOG="$TMPD/$(basename "$WRAP_CREATE").calllog"
check "7: the GET that found the 404 was actually issued" "$(cat "$CREATELOG")" "raw GET /project/ZZNEW"
check "7: POST /project was actually issued" "$(cat "$CREATELOG")" "write POST /project "
CREATEBODY=$(awk '/write POST \/project /{print; exit}' "$CREATELOG")
check "7: the create body carries the given KEY" "$CREATEBODY" '"key":"ZZNEW"'
check "7: the create body carries the given Name" "$CREATEBODY" '"name":"ZZ New Space"'
check "7: the create body carries projectTypeKey software" "$CREATEBODY" '"projectTypeKey":"software"'
check "7: the create body carries the simplified-scrum template key" "$CREATEBODY" 'gh-simplified-scrum-classic'
check "7: the create body carries the given --lead accountId" "$CREATEBODY" '"leadAccountId":"5f9a1111aaaa2222bbbb3333"'
check_not "7: --lead given means /myself was never called" "$(cat "$CREATELOG")" "raw GET /myself"
check "7: the post-create readback ran (project readback proceeded past create)" "$LAST_OUT" "bootstrap complete"

# =================================================================
# 8. A GET /project/<KEY> failure that is NOT a 404 (a real transport or
#    server error) still dies with the "refusing to guess" message, and
#    never attempts a create.
# =================================================================
WRAP_ERR="$TMPD/wrap-err.sh"
make_jira_api_stub "$WRAP_ERR"
WF_ERR="$TMPD/wf-err.sh"
make_workflow_apply_stub "$WF_ERR" 0
run geterr ZZERR "ZZ Err" --yes --lead 5f9a1111aaaa2222bbbb3333 \
    --jira-api "$WRAP_ERR" --workflow-apply "$WF_ERR"
assert_nonzero "8: a non-404 GET failure is a hard die" "$LAST_RC"
check "8: names the refusal, not a false 'not found'" "$LAST_ERR" "refusing to guess whether it exists"
ERRLOG="$TMPD/$(basename "$WRAP_ERR").calllog"
check_not "8: no POST /project was attempted after a non-404 error" "$(cat "$ERRLOG")" "write POST /project "
assert_eq "8: jira-workflow-apply.sh was never invoked" "" "$(cat "$TMPD/$(basename "$WF_ERR").calllog" 2>/dev/null || true)"

# =================================================================
# 9. An already-on-screen field is an idempotent no-op. The REAL ZZSPIKE
#    capture happened to show every target field absent everywhere (see
#    section 5), so this uses ONE derived variant of the real
#    tab-fields-10052 fixture (touches added, as if a previous run had
#    already placed it there — see TAB_FIELDS_10052_WITH_TOUCHES's own
#    comment above) to prove the skip branch actually skips, not just
#    that it happens to never trigger in the one state this repo has
#    seen live.
# =================================================================
WRAP_SCREENSKIP="$TMPD/wrap-screenskip.sh"
make_jira_api_stub "$WRAP_SCREENSKIP"
WF_SCREENSKIP="$TMPD/wf-screenskip.sh"
make_workflow_apply_stub "$WF_SCREENSKIP" 0
TAB_FIELDS_10052_OVERRIDE="$TAB_FIELDS_10052_WITH_TOUCHES"
export TAB_FIELDS_10052_OVERRIDE
run screenskip ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_SCREENSKIP" --workflow-apply "$WF_SCREENSKIP"
unset TAB_FIELDS_10052_OVERRIDE
assert_eq "9: exits 0 with one field already on one screen" "0" "$LAST_RC"
check "9: touches is reported already on screen 10049 (idempotent no-op)" "$LAST_OUT" "field 'touches' already on screen 10049 / tab 'Field Tab'."
SCREENSKIPLOG="$TMPD/$(basename "$WRAP_SCREENSKIP").calllog"
check_not "9: no write was issued to add touches to screen 10049's own tab" "$(cat "$SCREENSKIPLOG")" '/screens/10049/tabs/10052/fields {"fieldId":"customfield_10043"}'
check "9: touches was still added to the OTHER two screens (only 10049 already had it)" "$LAST_OUT" "field 'touches' absent from screen 10050 / tab 'Field Tab' — adding"

# =================================================================
# 10. THE ZZSPIKE RUN 4 REGRESSION — a fully idempotent rerun (project
#     already exists, all six fields already present with the right
#     schema type, all three executor options already present, all six
#     fields already on all three screens) makes ZERO write calls at
#     all, AND a grep for "creating" against the run's own output finds
#     ZERO matches. Found live: ZZSPIKE run 4 (genuinely zero POSTs) still
#     matched `grep 'creating'` once, from "...verifying, not creating." —
#     a caller scripting "did this rerun actually create anything?" as
#     grep 'creating' got a false positive on a project that already
#     existed. Fixed wording ("no create needed") deliberately does not
#     contain the substring "creating" anywhere.
# =================================================================
WRAP_IDEMPOTENT="$TMPD/wrap-idempotent.sh"
make_jira_api_stub "$WRAP_IDEMPOTENT"
WF_IDEMPOTENT="$TMPD/wf-idempotent.sh"
make_workflow_apply_stub "$WF_IDEMPOTENT" 0
FIELDS_FIXTURE="$FIELDS_AFTER_EXECUTOR"
FIELD_OPTIONS_OVERRIDE="$FIELD_OPTIONS_FULL"
TAB_FIELDS_10052_OVERRIDE="$TAB_FIELDS_10052_ALL"
TAB_FIELDS_10053_OVERRIDE="$TAB_FIELDS_10053_ALL"
TAB_FIELDS_10054_OVERRIDE="$TAB_FIELDS_10054_ALL"
export FIELDS_FIXTURE FIELD_OPTIONS_OVERRIDE TAB_FIELDS_10052_OVERRIDE TAB_FIELDS_10053_OVERRIDE TAB_FIELDS_10054_OVERRIDE
run idempotent ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_IDEMPOTENT" --workflow-apply "$WF_IDEMPOTENT"
unset FIELDS_FIXTURE FIELD_OPTIONS_OVERRIDE TAB_FIELDS_10052_OVERRIDE TAB_FIELDS_10053_OVERRIDE TAB_FIELDS_10054_OVERRIDE
assert_eq "10: a fully idempotent rerun exits 0" "0" "$LAST_RC"
IDEMPOTENTLOG="$TMPD/$(basename "$WRAP_IDEMPOTENT").calllog"
assert_eq "10: zero writes were issued on a fully idempotent rerun" "0" "$(grep -c "write POST" "$IDEMPOTENTLOG")"
assert_eq "10: grep 'creating' against the run's own output finds ZERO matches (the ZZSPIKE run 4 regression)" "0" "$(printf '%s\n' "$LAST_OUT" | grep -c "creating")"
check "10: the accurate wording is used instead" "$LAST_OUT" "already exists — verifying, no create needed."
check "10: bootstrap-complete banner still shown" "$LAST_OUT" "bootstrap complete"

# =================================================================
# 11. SCRIPT-REVIEWER HIGH — a malformed /screens/<id>/tabs response (not
#     the array Jira always actually returns) must be a hard die, not a
#     silently-skipped screen. Before the fix, `done <<EOF /
#     $(jq ... .[].id)` embedded the parse directly in the heredoc word,
#     where a jq failure's exit status is discarded — the loop for that
#     screen would just run zero times and the script would print
#     "bootstrap complete" having skipped it.
# =================================================================
WRAP_BADTABS="$TMPD/wrap-badtabs.sh"
make_jira_api_stub "$WRAP_BADTABS"
WF_BADTABS="$TMPD/wf-badtabs.sh"
make_workflow_apply_stub "$WF_BADTABS" 0
SCREENS_TABS_10049_OVERRIDE="$SCREENS_TABS_10049_MALFORMED"
export SCREENS_TABS_10049_OVERRIDE
run badtabs ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_BADTABS" --workflow-apply "$WF_BADTABS"
unset SCREENS_TABS_10049_OVERRIDE
assert_nonzero "11: a malformed /screens/<id>/tabs response is a hard die" "$LAST_RC"
check "11: names the screen it failed on" "$LAST_ERR" "could not parse tab ids for screen 10049"
check_not "11: never reaches \"bootstrap complete\" having silently skipped the screen" "$LAST_OUT" "bootstrap complete"

# =================================================================
# 12. SCRIPT-REVIEWER MEDIUM — a custom field name that matches MORE THAN
#     ONE field (Jira does not enforce unique custom field names) is a
#     hard die naming every colliding id, not a silent "pick the first
#     match".
# =================================================================
WRAP_DUPFIELD="$TMPD/wrap-dupfield.sh"
make_jira_api_stub "$WRAP_DUPFIELD"
WF_DUPFIELD="$TMPD/wf-dupfield.sh"
make_workflow_apply_stub "$WF_DUPFIELD" 0
FIELDS_FIXTURE="$FIELDS_DUPLICATE_NAME"
export FIELDS_FIXTURE
run dupfield ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_DUPFIELD" --workflow-apply "$WF_DUPFIELD"
unset FIELDS_FIXTURE
assert_nonzero "12: a duplicate-named custom field is refused" "$LAST_RC"
check "12: names the field" "$LAST_ERR" "'touches'"
check "12: names both colliding ids" "$LAST_ERR" "customfield_10043, customfield_19998"
DUPFIELDLOG="$TMPD/$(basename "$WRAP_DUPFIELD").calllog"
check_not "12: never issued a write for the ambiguous field" "$(cat "$DUPFIELDLOG")" "write POST /field "

# =================================================================
# 13. A field probed unsearchable (HTTP 400) gets repaired with
#     PUT /field/<id> {searcherKey: <textsearcher, from
#     FIELD_SEARCHER_KEYS>} and a passing re-probe; a field that answers
#     searchable from its first probe issues no PUT at all. The stub's 400/
#     200 bodies come from fixtures/space-search-jql-not-searchable.txt
#     and fixtures/space-search-jql-searchable.txt — RECORDED LIVE
#     2026-09-14 against project NWM itself (a throwaway textarea field,
#     created and deleted for the capture; see each fixture's own header
#     and space-search-jql-field-create.txt/space-search-jql-searcherkey-
#     put.txt for the rest of the chain). Unlike the rest of this file's
#     fixtures (see FIXTURE PROVENANCE above), these four ARE real: the
#     real 400 body carries no "not searchable" text at all — that wording
#     is the Automation UI's, a different surface — which is exactly why
#     probe_field_searchable() treats any HTTP 400 on this probe as the
#     signal, not a body-text match.
# =================================================================
WRAP_UNSEARCH="$TMPD/wrap-unsearch.sh"
make_jira_api_stub "$WRAP_UNSEARCH"
WF_UNSEARCH="$TMPD/wf-unsearch.sh"
make_workflow_apply_stub "$WF_UNSEARCH" 0
FORCE_UNSEARCHABLE="touches"
export FORCE_UNSEARCHABLE
run unsearch ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_UNSEARCH" --workflow-apply "$WF_UNSEARCH"
unset FORCE_UNSEARCHABLE
assert_eq "13a: exits 0 once the repair succeeds" "0" "$LAST_RC"
check "13a: reports the confirmed-unsearchable field and its repair" "$LAST_OUT" "field 'touches' (customfield_10043) is NOT searchable (confirmed via HTTP 400) — repairing: PUT searcherKey=com.atlassian.jira.plugin.system.customfieldtypes:textsearcher."
check "13a: reports searchable after repair" "$LAST_OUT" "field 'touches' (customfield_10043) is JQL-searchable after repair."
UNSEARCHLOG="$TMPD/$(basename "$WRAP_UNSEARCH").calllog"
check "13a: issued the repair PUT with the right searcherKey" "$(cat "$UNSEARCHLOG")" 'write PUT /field/customfield_10043 {"searcherKey":"com.atlassian.jira.plugin.system.customfieldtypes:textsearcher"}'
check_not "13a: a field that is searchable from the start (executor) issued no PUT" "$(cat "$UNSEARCHLOG")" "write PUT /field/customfield_10044"

WRAP_STILLBAD="$TMPD/wrap-stillbad.sh"
make_jira_api_stub "$WRAP_STILLBAD"
WF_STILLBAD="$TMPD/wf-stillbad.sh"
make_workflow_apply_stub "$WF_STILLBAD" 0
ALWAYS_UNSEARCHABLE="touches"
export ALWAYS_UNSEARCHABLE
run stillbad ZZSPACE "ZZ Space" --yes --jira-api "$WRAP_STILLBAD" --workflow-apply "$WF_STILLBAD"
unset ALWAYS_UNSEARCHABLE
assert_nonzero "13b: still-unsearchable after the PUT is a hard die, never guessed past" "$LAST_RC"
check "13b: names the field and refuses to guess further" "$LAST_ERR" "field 'touches' (customfield_10043) is still not JQL-searchable after PUT searcherKey=com.atlassian.jira.plugin.system.customfieldtypes:textsearcher — refusing to guess further"
check_not "13b: never reaches bootstrap complete" "$LAST_OUT" "bootstrap complete"

echo
if [ "$FAIL" = "0" ]; then
    echo "jira-space-create-selftest: all checks passed"
    exit 0
fi
echo "jira-space-create-selftest: FAILURES above" >&2
exit 1
