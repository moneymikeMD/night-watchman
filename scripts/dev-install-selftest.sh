#!/bin/bash
#
# Assertions for dev-install.sh (NWM-172).
#
# Every case runs under a scratch $CLAUDE_CONFIG_DIR and a scratch marketplace
# directory, so the operator's real plugin configuration is never touched —
# asserted, not assumed. Offline by construction: the marketplace source is a
# local path and the plugin is this checkout.
#
# The case that matters most is the teardown one. The install path is a
# SYMLINK to the checkout, so a careless `rm -rf` in --uninstall would delete
# the repository through it. That case counts the checkout's files either side.
#
# It needs the `claude` CLI, which a CI runner does not have. Without it this
# SKIPS LOUDLY and exits 0, because CI runs every *selftest*.sh by glob and
# treats any non-zero as a failure. The skip names what went untested so it
# cannot be read as a pass; NW_DEV_INSTALL_SELFTEST_REQUIRE=1 turns it into a
# failure instead, for somewhere the CLI is supposed to be present.
#
# Usage: ./scripts/dev-install-selftest.sh [path-to-dev-install.sh]
# Exit 0 if every assertion passes (or the CLI is absent and the skip is
# allowed), 1 otherwise, 2 if the environment makes the assertions meaningless.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SUT="${1:-$HERE/dev-install.sh}"
[ -x "$SUT" ] || { echo "cannot execute $SUT" >&2; exit 2; }
if ! command -v claude >/dev/null 2>&1; then
    if [ "${NW_DEV_INSTALL_SELFTEST_REQUIRE:-0}" = 1 ]; then
        echo "dev-install-selftest.sh: the claude CLI is not on PATH and NW_DEV_INSTALL_SELFTEST_REQUIRE=1" >&2
        exit 1
    fi
    echo "dev-install-selftest.sh: SKIPPED — the claude CLI is not on PATH." >&2
    echo "  NOT TESTED: that dev-install.sh installs this checkout, that the install" >&2
    echo "  is live, that --uninstall spares the checkout, and that the real config" >&2
    echo "  is untouched. This is a skip, not a pass. Run it where claude exists," >&2
    echo "  or set NW_DEV_INSTALL_SELFTEST_REQUIRE=1 to make this a failure." >&2
    exit 0
fi
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

FAIL=0
FAILED_NUMS=""
N=0
pass() { N=$((N + 1)); echo "PASS $N: $1"; }
fail() {
  N=$((N + 1)); echo "FAIL $N: $1" >&2
  FAIL=$((FAIL + 1))
  FAILED_NUMS="${FAILED_NUMS:+$FAILED_NUMS,}$N"
}
assert_eq() {
  desc="$1"; want="$2"; got="$3"
  if [ "$want" = "$got" ]; then pass "$desc (want '$want', got '$got')"
  else fail "$desc (want '$want', got '$got')"; fi
}

WORK="$(mktemp -d)" || { echo "mktemp -d failed" >&2; exit 1; }
CFG="$WORK/cfg"
MKT="$WORK/mkt"
mkdir -p "$CFG"

# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() {
    CLAUDE_CONFIG_DIR="$CFG" "$SUT" --marketplace-dir "$MKT" --uninstall >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT

sut() { CLAUDE_CONFIG_DIR="$CFG" "$SUT" --marketplace-dir "$MKT" "$@"; }
installed_path() {
    CLAUDE_CONFIG_DIR="$CFG" claude plugin list --json 2>/dev/null | python3 -c '
import json, sys
try: rows = json.load(sys.stdin)
except Exception: sys.exit(0)
for p in rows if isinstance(rows, list) else rows.get("plugins", []):
    if p.get("id") == "night-watchman@nw-dev":
        print(p.get("installPath") or ""); break
'
}
repo_file_count() { find "$REPO" -type f -not -path "$REPO/.git/*" | wc -l | tr -d ' '; }

# The operator's real configuration must be untouched. Recorded before
# anything runs and compared at the end.
REAL_MARKETS_BEFORE="$(claude plugin marketplace list 2>/dev/null | sort | cksum)"

# --- a dry run changes nothing -----------------------------------------------
sut --dry-run >/dev/null 2>&1
assert_eq "--dry-run installs nothing" "" "$(installed_path)"
assert_eq "--dry-run writes no marketplace file" "no" \
  "$( [ -f "$MKT/.claude-plugin/marketplace.json" ] && echo yes || echo no )"

# --- install -----------------------------------------------------------------
REPO_FILES_BEFORE="$(repo_file_count)"
sut >/dev/null 2>&1
PATH_AFTER="$(installed_path)"
VERSION_EXPECTED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO/.claude-plugin/plugin.json")"

if [ -n "$PATH_AFTER" ]; then
  pass "the plugin installs from the dev marketplace ($PATH_AFTER)"
else
  fail "the plugin installs from the dev marketplace (nothing reported by claude plugin list)"
fi
assert_eq "the installed version is plugin.json's" "$VERSION_EXPECTED" \
  "$(CLAUDE_CONFIG_DIR="$CFG" claude plugin list --json 2>/dev/null | python3 -c '
import json,sys
try: rows=json.load(sys.stdin)
except Exception: sys.exit(0)
for p in rows if isinstance(rows,list) else rows.get("plugins",[]):
    if p.get("id")=="night-watchman@nw-dev": print(p.get("version") or ""); break')"
assert_eq "the install path resolves to this checkout" "$(cd "$REPO" && pwd -P)" \
  "$(cd "$PATH_AFTER" 2>/dev/null && pwd -P)"
assert_eq "--status reports it live" "yes" \
  "$(sut --status 2>/dev/null | awk -F': *' '/live *:/{print $2}' | cut -d' ' -f1)"

# --- it is LIVE: proven by content, with nothing run in between --------------
MARKER="devinstall-marker-$$-$(date +%s)"
MARKER_FILE="$REPO/.dev-install-selftest-marker"
printf '%s\n' "$MARKER" > "$MARKER_FILE"
assert_eq "a file written in the checkout is readable through the install path, with no reinstall" \
  "$MARKER" "$(cat "$PATH_AFTER/.dev-install-selftest-marker" 2>/dev/null)"
rm -f "$MARKER_FILE"
assert_eq "and removing it is visible through the install path too" "no" \
  "$( [ -e "$PATH_AFTER/.dev-install-selftest-marker" ] && echo yes || echo no )"

# --- re-running is idempotent and still live ---------------------------------
sut >/dev/null 2>&1
PATH_AGAIN="$(installed_path)"
assert_eq "re-running leaves the same install path" "$PATH_AFTER" "$PATH_AGAIN"
printf '%s\n' "$MARKER" > "$MARKER_FILE"
assert_eq "and it is still live afterwards" "$MARKER" \
  "$(cat "$PATH_AGAIN/.dev-install-selftest-marker" 2>/dev/null)"
rm -f "$MARKER_FILE"

# --- the update trap must be warned about, never used ------------------------
# Matched as the COMMAND WORD: a mention inside an echo is the warning doing
# its job, and an earlier version of this case failed on exactly that.
assert_eq "'claude plugin update' is never the command the script runs" "0" \
  "$(grep -cE '^[[:space:]]*(run[[:space:]]+)?claude[[:space:]]+plugin[[:space:]]+update' "$SUT")"
assert_eq "the header warns a reader off it" "1" \
  "$(grep -cE '^#[[:space:]]*NEVER run .claude plugin update.' "$SUT")"
assert_eq "--status warns when the install is a copy rather than a link" "1" \
  "$(grep -c 'no-op at the same version' "$SUT")"

# --- teardown does not delete the checkout through the symlink ---------------
sut --uninstall >/dev/null 2>&1
REPO_FILES_AFTER="$(repo_file_count)"
assert_eq "--uninstall leaves the checkout's every file in place" \
  "$REPO_FILES_BEFORE" "$REPO_FILES_AFTER"
assert_eq "--uninstall removes the plugin" "" "$(installed_path)"
assert_eq "--uninstall removes the dev marketplace entry" "no" \
  "$( [ -f "$MKT/.claude-plugin/marketplace.json" ] && echo yes || echo no )"
assert_eq "the checkout is still a git repository afterwards" "yes" \
  "$( [ -d "$REPO/.git" ] && echo yes || echo no )"

# --- the real configuration was never touched --------------------------------
assert_eq "the operator's real marketplace list is unchanged (cksum)" \
  "$REAL_MARKETS_BEFORE" "$(claude plugin marketplace list 2>/dev/null | sort | cksum)"

echo
echo "$N assertion(s), $((N - FAIL)) passed, $FAIL failed" >&2
if [ "$FAIL" -ne 0 ]; then
  echo "failing assertion(s): $FAILED_NUMS" >&2
  echo "dev-install-selftest.sh: FAILED" >&2
  exit 1
fi
echo "dev-install-selftest.sh: all assertions passed" >&2
exit 0
