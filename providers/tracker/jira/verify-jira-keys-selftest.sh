#!/bin/bash
#
# Selftest for providers/tracker/jira/verify-jira-keys.sh.
# Nothing here reaches a real network: a stub `curl` sits on PATH first
# for every assertion (the same technique jira-api-selftest.sh uses).
#
# What is asserted:
#   1  Every local title matches its stubbed remote summary: exits 0,
#      prints "N/N exact matches".
#   2  One remote title differs: exits 1, the mismatch is named, the
#      match count reflects only the tickets that DID match.
#   3  A fetch that fails outright (a stubbed non-2xx) is reported as a
#      MISS, not a script crash, still counts against the total, and
#      exits 2 — a distinct code from a pure title mismatch (1), since a
#      fetch failure says nothing about whether the title is even right.
#
# Usage: providers/tracker/jira/verify-jira-keys-selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VERIFY_SH="$HERE/verify-jira-keys.sh"
FIXTURES="$HERE/fixtures"

[ -x "$VERIFY_SH" ] || { echo "$VERIFY_SH is missing or not executable" >&2; exit 2; }

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"
        printf '       expected: %s\n' "$2"
        printf '       actual:   %s\n' "$3"
    fi
}

contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1"; printf '       wanted substring: %s\n       in: %s\n' "$2" "$3" ;;
    esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

unset NW_CONFIG NW_ROOT NW_TRACKER NW_SECRETS NW_DISPATCH NW_MEMORY

# STUB_TITLES: newline-separated "KEY<TAB>title" the stub answers with; a
# key not listed there gets a 404.
titles_file="$WORK/titles.tsv"

cat > "$WORK/bin/curl" <<CURLEOF
#!/bin/bash
cat >/dev/null
out="" url=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "-o" ]; then out="\$a"; fi
    prev="\$a"
done
url="\${!#}"
[ -n "\$out" ] || { echo "stub curl: no -o path found in: \$*" >&2; exit 2; }
key="\${url##*/issue/}"
title=\$(awk -F'\t' -v k="\$key" '\$1 == k { print \$2; found=1 } END { if (!found) exit 1 }' "$titles_file")
if [ -n "\$title" ]; then
    python3 -c 'import json,sys; print(json.dumps({"key": sys.argv[1], "fields": {"summary": sys.argv[2]}}))' "\$key" "\$title" > "\$out"
    printf '200'
else
    printf '{"errorMessages":["Issue does not exist"]}' > "\$out"
    printf '404'
fi
CURLEOF
chmod +x "$WORK/bin/curl"

run_e2e() {
    ( export PATH="$WORK/bin:$PATH"
      export NW_JIRA_HOST=127.0.0.1
      export NW_SECRETS=env
      export NW_JIRA_USER=testuser NW_JIRA_TOKEN=testtoken
      unset NW_CONFIG NW_ROOT NW_TRACKER
      "$@" )
}

# ---- 1. every title matches -------------------------------------------------

cat > "$titles_file" <<'EOF'
SPK-1	Add health check endpoint
SPK-2	Document the health endpoint
SPK-3	Load-test the health endpoint
EOF

OUT=$(run_e2e "$VERIFY_SH" --project SPK "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "all-match: exits 0" "0" "$RC"
contains "all-match: reports 3/3" "3/3 exact matches" "$OUT"

# ---- 2. one title differs ---------------------------------------------------

cat > "$titles_file" <<'EOF'
SPK-1	Add health check endpoint
SPK-2	SOMETHING ELSE ENTIRELY
SPK-3	Load-test the health endpoint
EOF

OUT=$(run_e2e "$VERIFY_SH" --project SPK "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "one-mismatch: exits 1 (title mismatch, not a fetch failure)" "1" "$RC"
contains "one-mismatch: reports 2/3" "2/3 exact matches" "$OUT"
contains "one-mismatch: names the differing key" "DIFF  SPK-2" "$OUT"
contains "one-mismatch: shows both titles" "SOMETHING ELSE ENTIRELY" "$OUT"

# ---- 3. a fetch fails outright ----------------------------------------------

cat > "$titles_file" <<'EOF'
SPK-1	Add health check endpoint
SPK-3	Load-test the health endpoint
EOF

OUT=$(run_e2e "$VERIFY_SH" --project SPK "$FIXTURES/import-tickets" 2>&1); RC=$?
eq "missing-issue: exits 2 (a fetch failure, not just a mismatch)" "2" "$RC"
contains "missing-issue: reports MISS, not a crash" "MISS  SPK-2" "$OUT"
contains "missing-issue: reports 2/3" "2/3 exact matches" "$OUT"

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/tracker/jira/verify-jira-keys-selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/tracker/jira/verify-jira-keys-selftest.sh: all assertions passed" >&2
exit 0
