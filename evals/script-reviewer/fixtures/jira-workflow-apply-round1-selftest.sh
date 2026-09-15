#!/bin/bash
#
# ROUND-1 FIXTURE (frozen for evals/script-reviewer). Trimmed
# selftest harness for jira-workflow-apply-round1.sh, reconstructed from
# the real incident: the harness stubs $JIRA_API_PATH but never clears
# $ISSUES_JIRA_API from the environment it inherits, so a developer who
# has that variable exported for this project's own session-start (a
# normal, common state) has every "no --jira-api" test case silently pick
# up the REAL wrapper instead of the stub, and it can reach the network.
#
# NEVER run this against a live Jira project — it is a review fixture only.

set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/jira-workflow-apply-round1.sh"
TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

PASS=0
FAIL=0
check() {
    local label="$1" got="$2" want="$3"
    if printf '%s' "$got" | grep -qF "$want"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $label (expected to find '$want')" >&2
    fi
}

# Stub wrapper — always available on PATH-relative lookup for the tests
# below, but nothing here removes $ISSUES_JIRA_API from the environment
# before exercising the "no --jira-api flag given" cases.
STUB="$TMPD/stub-jira-api.sh"
cat > "$STUB" <<'EOF'
#!/bin/bash
echo '{"stub": true}'
EOF
chmod +x "$STUB"

# case: no --jira-api flag given — should fall back to $ISSUES_JIRA_API.
# If that variable is already exported in the ambient shell (e.g. a
# developer's own project session-start left it set), this test exercises
# whatever wrapper THAT points at, not the stub above.
OUT=$("$SCRIPT" NWM --dry-run 2>&1) && RC=0 || RC=$?
check "falls back to \$ISSUES_JIRA_API when no --jira-api given" "$OUT" "PROJECT_KEY"

echo "selftest: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
