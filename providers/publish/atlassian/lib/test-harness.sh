#!/bin/bash
#
# Shared offline harness for providers/publish/atlassian/{confluence,
# townsquare}-selftest.sh. Sourced, never run: sets up the scratch WORK
# directory, the assertion helpers, the stub `curl` that answers from
# fixtures/, the throwaway config, and the run/dry wrappers. Named without
# "selftest" so CI's `find -name '*selftest*.sh'` never executes it.
#
# Usage: . "$(dirname "$0")/lib/test-harness.sh"

# shellcheck disable=SC2034  # FIX, OUT, ERR, RC are read by the sourcing selftest
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROVIDER="$HERE/provider.sh"
CONF="$HERE/confluence.sh"
TSQ="$HERE/townsquare.sh"
FIX="$HERE/fixtures"

for f in "$PROVIDER" "$CONF" "$TSQ"; do
    [ -x "$f" ] || { echo "$f is missing or not executable" >&2; exit 2; }
done

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
    case "$3" in *"$2"*) ok "$1" ;; *) bad "$1"; printf '       wanted: %s\n       in: %s\n' "$2" "$3" ;; esac
}
not_contains() {
    case "$3" in *"$2"*) bad "$1"; printf '       unwanted: %s\n' "$2" ;; *) ok "$1" ;; esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# strip FIXTURE > OUT — the recorded body below the '---' header line.
strip() { sed -n '/^---$/,$p' "$1" | tail -n +2; }
check_fixtures() {
    for f in "$WORK"/*.json; do
        jq -e . >/dev/null 2>&1 < "$f" || { echo "fixture is not valid JSON: $f" >&2; exit 2; }
    done
}

# Stub curl. Logs argv and stdin; routes on "METHOD PATH-SUBSTRING" through
# $STUB_ROUTES ("METHOD|substring|file|code;..."), first match wins. Suffix a
# route's file with '!' to consume it once, so a path can answer twice.
cat > "$WORK/bin/curl" <<'CURLEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_ARGV"
cat >> "$STUB_STDIN"
method=GET out="" url="" data="" prev=""
for a in "$@"; do
    case "$prev" in
        -X) method="$a" ;;
        -o) out="$a" ;;
        --data-binary) data="$a" ;;
    esac
    case "$a" in https://*) url="$a" ;; esac
    prev="$a"
done
body=""
case "$data" in @*) body=$(cat "${data#@}") ;; esac
printf '%s\t%s\t%s\n' "$method" "$url" "$body" >> "$STUB_REQ"
used="$STUB_REQ.used"; touch "$used"
i=0
old="$IFS"; IFS=';'
for r in $STUB_ROUTES; do
    i=$((i + 1))
    IFS="$old"
    m="${r%%|*}"; rest="${r#*|}"; sub="${rest%%|*}"; rest="${rest#*|}"; file="${rest%%|*}"; code="${rest#*|}"
    once=0
    case "$file" in *'!') once=1; file="${file%!}" ;; esac
    if [ "$m" = "$method" ] && case "$url" in *"$sub"*) true ;; *) false ;; esac; then
        if [ "$once" = "1" ] && grep -qx "$i" "$used"; then IFS=';'; continue; fi
        [ "$once" = "1" ] && echo "$i" >> "$used"
        cat "$file" > "$out"
        printf '%s' "$code"
        exit 0
    fi
    IFS=';'
done
IFS="$old"
echo "stub curl: no route for $method $url" >&2
exit 7
CURLEOF
chmod +x "$WORK/bin/curl"

CFG="$WORK/config.toml"
cat > "$CFG" <<'EOF'
[providers]
secrets = "env"
publish = "atlassian"

[publish.atlassian]
host = "unused.invalid"
space = "4242"
root_page = "9001"
project_name = "demo"
project_feed = "ari:cloud:townsquare:c0:project/default-feed"

[publish.atlassian.feeds]
PROJ-12 = "ari:cloud:townsquare:c0:project/epic-feed"
EOF

# run [VAR=VAL...] CMD... — offline environment; sets OUT, ERR, RC.
run() {
    : > "$WORK/argv"; : > "$WORK/stdin"; : > "$WORK/req"; rm -f "$WORK/req.used"
    OUT=$( env PATH="$WORK/bin:$PATH" NW_CONFIG="$CFG" NW_ATLASSIAN_HOST=127.0.0.1 \
               NW_SECRETS=env NW_JIRA_USER=stub-user NW_JIRA_TOKEN=STUB-TOKEN-XYZ \
               STUB_ARGV="$WORK/argv" STUB_STDIN="$WORK/stdin" STUB_REQ="$WORK/req" \
               "$@" 2>"$WORK/err" )
    RC=$?
    ERR=$(cat "$WORK/err")
}
reqs() { wc -l < "$WORK/req" | tr -d ' '; }

# NW_SECRETS=op with no op on PATH: a dry run that tried to read a credential
# would fail, so passing proves the secrets provider was skipped.
dry() {
    : > "$WORK/req"
    OUT=$( env PATH="$WORK/bin:$PATH" NW_CONFIG="$CFG" NW_ATLASSIAN_HOST=127.0.0.1 \
               NW_SECRETS=op NW_DRY_RUN=1 STUB_ARGV="$WORK/argv" STUB_STDIN="$WORK/stdin" \
               STUB_REQ="$WORK/req" STUB_ROUTES="" "$@" 2>"$WORK/err" )
    RC=$?
    ERR=$(cat "$WORK/err")
}

# finish NAME — print the summary and exit 1 on any failure.
finish() {
    echo
    echo "$N assertion(s), $((N - FAIL)) passed" >&2
    if [ "$FAIL" -ne 0 ]; then
        echo "$1: FAILED" >&2
        exit 1
    fi
    echo "$1: all assertions passed" >&2
    exit 0
}
