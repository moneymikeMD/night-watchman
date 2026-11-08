#!/bin/bash
#
# Selftest for providers/memory/lamplighter/provider.sh. Runs against a
# stubbed `lampl` put first on PATH, with LAMPL_* unset and the config read
# from a scratch file, so nothing here reaches a real lamplighter server.
#
# Usage: providers/memory/lamplighter/selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
P="$HERE/provider.sh"
[ -x "$P" ] || { echo "$P is missing or not executable" >&2; exit 2; }

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"; printf '       expected: %s\n       actual:   %s\n' "$2" "$3"
    fi
}
contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1"; printf '       wanted substring: %s\n       in: %s\n' "$2" "$3" ;;
    esac
}

for v in $(env | sed -n 's/^\(LAMPL[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$v"; done
unset NW_DRY_RUN NW_MEMORY NW_ROOT

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
cat > "$WORK/bin/lampl" <<'STUB'
#!/bin/bash
for a in "$@"; do printf '[%s]' "$a"; done >> "$WORK_LOG"
echo >> "$WORK_LOG"
case "$1" in
    store)  echo '{"id":"00000000-0000-0000-0000-000000000001"}' ;;
    recall) echo '{"hits":[]}' ;;
esac
STUB
chmod +x "$WORK/bin/lampl"
export WORK_LOG="$WORK/calls.log"
export PATH="$WORK/bin:$PATH"

printf '[memory.lamplighter]\nproject = "demo"\n' > "$WORK/config.toml"
export NW_CONFIG="$WORK/config.toml"

: > "$WORK_LOG"
OUT=$("$P" store --title "T one" --content "body text" --type fact --component hooks --kind fix --tags a,b --importance 0.7 2>&1)
eq "store exits 0 and prints lampl's JSON" '{"id":"00000000-0000-0000-0000-000000000001"}' "$OUT"
eq "store maps --content to --body, defaults --project from config and builds tags" \
    '[store][--title][T one][--body][body text][--project][demo][--tags][demo,hooks,fix,a,b][--type][fact][--importance][0.7]' \
    "$(cat "$WORK_LOG")"

: > "$WORK_LOG"
"$P" recall --query "two words" --limit 3 --json >/dev/null 2>&1
eq "recall passes query, config project, limit and --json" \
    '[recall][--query][two words][--project][demo][--limit][3][--json]' "$(cat "$WORK_LOG")"

: > "$WORK_LOG"
"$P" recall --query q --project other >/dev/null 2>&1
eq "--project overrides the config" '[recall][--query][q][--project][other]' "$(cat "$WORK_LOG")"

: > "$WORK_LOG"
OUT=$("$P" --dry-run store --title "a b" --content c 2>&1)
eq "--dry-run never calls lampl" "" "$(cat "$WORK_LOG")"
contains "--dry-run prints the shell-quoted command" 'lampl store --title a\ b --body c --project demo --tags demo' "$OUT"

OUT=$(NW_DRY_RUN=1 "$P" recall --query q 2>&1)
contains "NW_DRY_RUN=1 behaves as --dry-run" 'lampl recall --query q --project demo' "$OUT"

OUT=$("$P" store --content c 2>&1); rc=$?
eq "store without --title exits 1" 1 "$rc"
contains "and names the flag" "--title is required" "$OUT"

OUT=$("$P" recall 2>&1); rc=$?
eq "recall without --query exits 1" 1 "$rc"

: > "$WORK/empty.toml"
OUT=$(NW_CONFIG="$WORK/empty.toml" "$P" store --title t --content c 2>&1); rc=$?
eq "store with no project anywhere exits 1" 1 "$rc"
contains "and says where to set it" "[memory.lamplighter] project" "$OUT"

OUT=$("$P" link a b 2>&1); rc=$?
eq "a verb outside the contract exits 1" 1 "$rc"
contains "and names the contract" "contract: store, recall" "$OUT"

OUT=$(PATH="/usr/bin:/bin" "$P" recall --query q 2>&1); rc=$?
eq "a missing lampl exits 1" 1 "$rc"
contains "and names it" "lampl" "$OUT"

echo "$N assertions, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    echo "providers/memory/lamplighter/selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/memory/lamplighter/selftest.sh: all assertions passed" >&2
