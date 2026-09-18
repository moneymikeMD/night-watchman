#!/bin/bash
#
# Selftest for providers/lib/config.sh and providers/lib/provider.sh — the
# two files that decide, for every night-watchman script, which outside
# tool gets called. Both are worth a selftest for the same reason: their
# failure mode is silent. A config reader that skips a line it does not
# understand, or a resolver that falls through to a default when a
# committed selection was meant to win, does not error — it does the wrong
# thing successfully, against the wrong Jira site or the wrong vault.
#
# What is asserted, in the order the cases appear:
#
#   1-2   the supported grammar parses, and every value shape round-trips
#         through the one-line key<TAB>value transport intact — including
#         a value holding a literal newline, tab, backslash, and quote,
#         which is exactly what a line-based transport gets wrong.
#   3     every REJECTED construct is rejected, by name, with its line
#         number. This is the bulk of the file: a reader is only as good
#         as what it refuses.
#   4     discovery — NW_CONFIG beats the walk-up, the walk-up finds a
#         config from a nested subdirectory, and no config is not an error.
#   5     precedence — env > config > built-in default, with `origin`
#         agreeing with `resolve` rather than re-deriving the rule.
#   6     a malformed implementation name is refused BEFORE it is
#         concatenated into a path and executed (the traversal case).
#   7     unknown kinds and unknown verbs are refused naming the legal set.
#   8     `run` actually execs the implementation, passing the verb and
#         every argument after it through unmangled.
#   9     sourcing either library does not turn `set -e` on in the caller.
#   10    the shipped template parses, and declares every kind the code
#         knows about — the drift check between the two.
#
# Runs entirely against scratch directories under a temp root. Nothing
# here reads the operator's real config, contacts a host, or reads a
# credential: there is no live target for this layer to reach.
#
# Usage: providers/config-selftest.sh

# shellcheck disable=SC1090  # every `.` below sources one of the two files
# under test, at a path computed from this script's own location.

set -uo pipefail

# Hermetic environment. Every one of these is a legitimate thing for an
# operator to have exported in the shell they run this from, and each one
# would quietly change what the assertions below are measuring — the
# drift check at the end reads the shipped template through the same
# resolution path an operator's `NW_TRACKER` would win. Clear them once,
# here, rather than per case: a case that forgets is a case that passes
# for the wrong reason.
unset NW_CONFIG NW_ROOT NW_TRACKER NW_SECRETS NW_DISPATCH NW_MEMORY

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$HERE")"
CONFIG_SH="$HERE/lib/config.sh"
PROVIDER_SH="$HERE/lib/provider.sh"
TEMPLATE="$REPO/templates/night-watchman.config.toml"

for f in "$CONFIG_SH" "$PROVIDER_SH" "$TEMPLATE"; do
    [ -r "$f" ] || { echo "cannot read $f" >&2; exit 2; }
done
[ -x "$PROVIDER_SH" ] || { echo "$PROVIDER_SH is not executable" >&2; exit 2; }

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

# eq LABEL EXPECTED ACTUAL
eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"
        printf '       expected: %s\n' "$(printf '%s' "$2" | od -c | head -3)"
        printf '       actual:   %s\n' "$(printf '%s' "$3" | od -c | head -3)"
    fi
}

# contains LABEL NEEDLE HAYSTACK
contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1"; printf '       wanted substring: %s\n       in: %s\n' "$2" "$3" ;;
    esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# The walk-up in nw_config_file climbs to /. If the temp root happens to
# sit under a directory that has its own .night-watchman/config.toml, the
# "no config" cases below would silently test the wrong thing — so refuse
# to run rather than report a pass that means nothing.
if ( cd "$WORK" && unset NW_CONFIG NW_ROOT && . "$CONFIG_SH" && [ -n "$(nw_config_file)" ] ); then
    echo "refusing to run: a .night-watchman/config.toml exists above the temp root $WORK" >&2
    exit 2
fi

# get FILE KEY [DEFAULT] — read one key out of a named config file.
get() {
    local f="$1"; shift
    ( unset NW_ROOT; NW_CONFIG="$f"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get "$@" )
}

# ---- 1. the supported grammar parses -----------------------------------

cat > "$WORK/good.toml" <<'EOF'
# a leading comment

[providers]
tracker  = "jira"
secrets  = 'op'          # a literal string, and a trailing comment
dispatch = "herdr"
memory   = "memorygraph"

[tracker.jira]
host    = "example.atlassian.net"
project = "NWM"
timeout = 30
retries = -2
verbose = false
enabled = true
EOF

eq "a basic string parses" "jira" "$(get "$WORK/good.toml" providers.tracker)"
eq "a literal string parses" "op" "$(get "$WORK/good.toml" providers.secrets)"
eq "a dotted table header namespaces its keys" "example.atlassian.net" \
   "$(get "$WORK/good.toml" tracker.jira.host)"
eq "an integer parses" "30" "$(get "$WORK/good.toml" tracker.jira.timeout)"
eq "a negative integer parses" "-2" "$(get "$WORK/good.toml" tracker.jira.retries)"
eq "false parses" "false" "$(get "$WORK/good.toml" tracker.jira.verbose)"
eq "true parses" "true" "$(get "$WORK/good.toml" tracker.jira.enabled)"
eq "a trailing comment is not part of the value" "op" "$(get "$WORK/good.toml" providers.secrets)"

MISSING=$(get "$WORK/good.toml" no.such.key); MISSING_RC=$?
eq "an absent key returns 1" "1" "$MISSING_RC"
eq "an absent key prints nothing" "" "$MISSING"
eq "an absent key with a default returns the default" "fallback" \
   "$(get "$WORK/good.toml" no.such.key fallback)"

# ---- 2. values round-trip through the one-line transport ---------------
#
# The reader carries values from awk to the shell one key per line, so a
# value containing a literal newline has to survive an encode/decode pair.
# This is the case a line-based config reader gets wrong, and it corrupts
# every key after the offending one rather than just that value.

printf 'nasty = "a\\tb\\nc\\"d\\\\e"\nafter = "still here"\n' > "$WORK/esc.toml"
WANT=$(printf 'a\tb\nc"d\\e')
eq "escapes round-trip: tab, newline, quote, backslash" "$WANT" "$(get "$WORK/esc.toml" nasty)"
eq "a key after a multi-line value is still readable" "still here" \
   "$(get "$WORK/esc.toml" after)"

printf "lit = 'a\\\\tb'\n" > "$WORK/lit.toml"
eq "a literal string does NOT process escapes" 'a\tb' "$(get "$WORK/lit.toml" lit)"

# A '#' or an '=' inside a quoted string is DATA, not a comment
# delimiter or a second assignment. Both are ordinary in the values this
# config actually carries — an op:// reference, a URL with a fragment, a
# query string — and a reader that scanned for '#' before finding the end
# of the string would silently truncate them.
cat > "$WORK/punct.toml" <<'EOF'
hashed  = "a#b"
equals  = "k=v"
lithash = 'p#q'
both    = "u=1#frag"
commented = "value"   # this one IS a comment
emptied = ""
EOF
eq "a '#' inside a basic string is data, not a comment" "a#b" "$(get "$WORK/punct.toml" hashed)"
eq "an '=' inside a basic string is data, not a second assignment" "k=v" "$(get "$WORK/punct.toml" equals)"
eq "a '#' inside a literal string is data" "p#q" "$(get "$WORK/punct.toml" lithash)"
eq "'#' and '=' together inside one string" "u=1#frag" "$(get "$WORK/punct.toml" both)"
eq "a real trailing comment after a string is still stripped" "value" "$(get "$WORK/punct.toml" commented)"
eq "an empty string is a value, not an absent key" "" "$(get "$WORK/punct.toml" emptied)"
EMPTY_RC=0; get "$WORK/punct.toml" emptied >/dev/null || EMPTY_RC=$?
eq "an empty string returns 0, distinguishing it from absent" "0" "$EMPTY_RC"

# CRLF. A config edited on Windows, or pasted through a tool that
# normalises line endings, must not end up with a trailing carriage
# return welded onto every value — `tracker = "jira\r"` would fail the
# implementation-name check with a message naming a value that looks
# correct on screen.
printf '[providers]\r\ntracker = "jira"\r\n\r\n[tracker.jira]\r\nhost = "example.atlassian.net"\r\n' > "$WORK/crlf.toml"
eq "CRLF line endings parse, with no stray carriage return in the value" \
   "jira" "$(get "$WORK/crlf.toml" providers.tracker)"
eq "CRLF: a later table's key is unaffected" "example.atlassian.net" \
   "$(get "$WORK/crlf.toml" tracker.jira.host)"

# A key is only ever reachable at its own dotted path. Asking for the
# bare name, or for it under a different table, must miss — a lookup that
# fell back to "any table with this key" would let [secrets.op] silently
# answer a question about [tracker.jira].
cat > "$WORK/tables.toml" <<'EOF'
[tracker.jira]
host = "jira.example.invalid"

[secrets.op]
vault = "Private"
EOF
eq "a table's key is not reachable by its bare name" "MISS" \
   "$(get "$WORK/tables.toml" host MISS)"
eq "a key is not reachable under the wrong table" "MISS" \
   "$(get "$WORK/tables.toml" secrets.op.host MISS)"
eq "a key is not reachable under a truncated table path" "MISS" \
   "$(get "$WORK/tables.toml" jira.host MISS)"
eq "the correct dotted path still resolves" "jira.example.invalid" \
   "$(get "$WORK/tables.toml" tracker.jira.host)"

# ---- 3. everything outside the subset is a named error -----------------

# reject LABEL NEEDLE CONTENT — CONTENT must fail to parse, with NEEDLE in
# the complaint. Both halves matter: a reader that rejects everything
# passes the exit-status half, so the message is asserted too.
reject() {
    local out rc=0
    printf '%s\n' "$3" > "$WORK/bad.toml"
    out=$( ( unset NW_CONFIG NW_ROOT; . "$CONFIG_SH"; nw_config_parse "$WORK/bad.toml" >/dev/null ) 2>&1 ) || rc=$?
    if [ "$rc" -eq 0 ]; then
        bad "$1 (parsed it without complaint)"
        return
    fi
    contains "$1" "$2" "$out"
}

reject "arrays are rejected"              "arrays are not supported"            'a = [1, 2]'
reject "inline tables are rejected"       "inline tables are not supported"     'a = { b = 1 }'
reject "arrays of tables are rejected"    "arrays of tables"                    '[[x]]'
reject "multi-line strings are rejected"  "multi-line strings"                  'a = """x"""'
reject "floats are rejected"              "only strings, integers, and booleans" 'a = 1.5'
reject "dates are rejected"               "only strings, integers, and booleans" 'a = 1979-05-27'
reject "quoted keys are rejected"         "quoted keys are not supported"       '"a" = 1'
reject "a bare word is rejected"          "not a comment, table header, or key" 'oops'
reject "an unterminated string is rejected" "unterminated string"               'a = "x'
reject "an unknown escape is rejected"    "unsupported escape"                  'a = "x\qy"'
reject "trailing junk after a value is rejected" "trailing junk"                'a = "x" y'
reject "a malformed table header is rejected" "malformed table header"          '[a b]'
reject "a missing value is rejected"      "missing value for key"               'a ='
reject "a duplicate key is rejected"      "duplicate key: a"                    $'a = 1\na = 2'
reject "a duplicate table header is rejected" "duplicate table header"          $'[t]\nx = 1\n[t]\ny = 2'

printf 'a = 1\nb = [2]\nc = 1.5\n' > "$WORK/many.toml"
MANY=$( ( unset NW_CONFIG NW_ROOT; . "$CONFIG_SH"; nw_config_parse "$WORK/many.toml" >/dev/null ) 2>&1 )
contains "every bad line is reported, not just the first (arrays)" "arrays are not supported" "$MANY"
contains "every bad line is reported, not just the first (floats)" "only strings, integers" "$MANY"
contains "an error names the line number" "many.toml:2:" "$MANY"

# ---- 4. discovery ------------------------------------------------------

mkdir -p "$WORK/repo/.night-watchman" "$WORK/repo/deep/deeper"
printf '[providers]\ntracker = "filed"\n' > "$WORK/repo/.night-watchman/config.toml"

FOUND=$( unset NW_CONFIG; NW_ROOT="$WORK/repo/deep/deeper"; export NW_ROOT; . "$CONFIG_SH"; nw_config_file )
eq "the walk-up finds a repo config from a nested subdirectory" \
   "$(cd "$WORK/repo" && pwd -P)/.night-watchman/config.toml" "$FOUND"

FOUND=$( NW_CONFIG="$WORK/good.toml"; export NW_CONFIG; NW_ROOT="$WORK/repo/deep"; export NW_ROOT; . "$CONFIG_SH"; nw_config_file )
eq "NW_CONFIG beats the walk-up" "$WORK/good.toml" "$FOUND"

mkdir -p "$WORK/bare"
FOUND=$( unset NW_CONFIG; NW_ROOT="$WORK/bare"; export NW_ROOT; . "$CONFIG_SH"; nw_config_file )
eq "no config anywhere is an empty answer, not an error" "" "$FOUND"

NOCFG=$( unset NW_CONFIG; NW_ROOT="$WORK/bare"; export NW_ROOT; . "$CONFIG_SH"; nw_config_parse; echo "rc=$?" )
eq "parsing with no config succeeds and prints nothing" "rc=0" "$NOCFG"

UNREADABLE=$( ( unset NW_ROOT; NW_CONFIG="$WORK/no-such-file.toml"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_parse ) 2>&1; echo "rc=$?" )
contains "a named-but-unreadable config IS an error" "not readable" "$UNREADABLE"

# ---- 5-8. the resolver -------------------------------------------------
#
# Exercised through the CLI in a scratch repo, so the assertions cover the
# path an actual caller takes rather than the functions in isolation.

mkdir -p "$WORK/repo/providers/lib" "$WORK/repo/providers/tracker/fake"
cp "$HERE/lib/kit.sh" "$HERE/lib/config.sh" "$PROVIDER_SH" "$WORK/repo/providers/lib/"
chmod +x "$WORK/repo/providers/lib/provider.sh"
P="$WORK/repo/providers/lib/provider.sh"

cat > "$WORK/repo/providers/tracker/fake/provider.sh" <<'FAKEEOF'
#!/bin/bash
# A stand-in implementation. Prints its argv, one argument per line,
# bracketed — so an argument containing a space or an empty argument is
# visible in the assertion rather than being smoothed over by the shell.
for a in "$@"; do printf '[%s]\n' "$a"; done
FAKEEOF
chmod +x "$WORK/repo/providers/tracker/fake/provider.sh"

run_p() { ( cd "$WORK/repo" && unset NW_CONFIG NW_TRACKER NW_SECRETS NW_DISPATCH NW_MEMORY; "$@" ) }

# 5. precedence
eq "config beats the built-in default" "filed" "$(run_p "$P" resolve tracker)"
eq "origin says config when the config decided" "config" "$(run_p "$P" origin tracker)"
eq "a kind absent from the config falls back to the built-in default" "op" \
   "$(run_p "$P" resolve secrets)"
eq "origin says default when the built-in decided" "default" "$(run_p "$P" origin secrets)"
eq "the NW_<KIND> env var beats the config" "fake" \
   "$( cd "$WORK/repo" && NW_TRACKER=fake "$P" resolve tracker )"
eq "origin says env when the env var decided" "env" \
   "$( cd "$WORK/repo" && NW_TRACKER=fake "$P" origin tracker )"
eq "an empty NW_<KIND> does not count as a selection" "filed" \
   "$( cd "$WORK/repo" && NW_TRACKER='' "$P" resolve tracker )"

# 6. a malformed implementation name never reaches the filesystem
TRAV=$( cd "$WORK/repo" && NW_TRACKER='../../../tmp' "$P" resolve tracker 2>&1 ); TRAV_RC=$?
eq "a path-traversing implementation name exits non-zero" "1" "$TRAV_RC"
contains "a path-traversing implementation name is refused by name" "malformed implementation name" "$TRAV"
for nasty in 'Jira' 'ji ra' 'ji/ra' '-x' ''; do
    OUT=$( cd "$WORK/repo" && NW_TRACKER="$nasty" "$P" resolve tracker 2>&1 )
    RC=$?
    if [ -z "$nasty" ]; then
        eq "an empty NW_TRACKER falls through rather than erroring" "0" "$RC"
    elif [ "$RC" -ne 0 ]; then
        ok "implementation name '$nasty' is refused"
    else
        bad "implementation name '$nasty' was accepted, giving '$OUT'"
    fi
done

# 7. unknown kinds and verbs
OUT=$( run_p "$P" resolve nonsense 2>&1 ); RC=$?
eq "an unknown kind exits non-zero" "1" "$RC"
contains "an unknown kind lists the known ones" "tracker, secrets, dispatch, memory" "$OUT"
OUT=$( cd "$WORK/repo" && NW_TRACKER=fake "$P" run tracker publish 2>&1 ); RC=$?
eq "an unknown verb exits non-zero" "1" "$RC"
contains "an unknown verb names the kind's contract" "fetch, transition, comment, create" "$OUT"
eq "the documented tracker verb set" "fetch transition comment create" "$(run_p "$P" verbs tracker)"
eq "the documented secrets verb set" "read" "$(run_p "$P" verbs secrets)"
eq "the documented dispatch verb set" "start watch stop" "$(run_p "$P" verbs dispatch)"
eq "the documented memory verb set" "store recall" "$(run_p "$P" verbs memory)"

# 8. run dispatches, passing the verb and arguments through unmangled
OUT=$( cd "$WORK/repo" && NW_TRACKER=fake "$P" run tracker fetch NWM-17 --json 2>&1 )
eq "run execs the implementation with the verb first, arguments intact" \
   "$(printf '[fetch]\n[NWM-17]\n[--json]')" "$OUT"
OUT=$( cd "$WORK/repo" && NW_TRACKER=fake "$P" run tracker comment NWM-17 'two words' '' 2>&1 )
eq "an argument with a space, and an empty argument, survive dispatch" \
   "$(printf '[comment]\n[NWM-17]\n[two words]\n[]')" "$OUT"
OUT=$( run_p "$P" run tracker fetch X 2>&1 ); RC=$?
eq "a selected-but-absent implementation exits non-zero" "1" "$RC"
contains "a selected-but-absent implementation says so, with the path it looked at" \
   "is not installed" "$OUT"

mkdir -p "$WORK/repo/providers/tracker/noexec"
: > "$WORK/repo/providers/tracker/noexec/provider.sh"
OUT=$( cd "$WORK/repo" && NW_TRACKER=noexec "$P" run tracker fetch 2>&1 ); RC=$?
eq "a non-executable entry point exits non-zero" "1" "$RC"
contains "a non-executable entry point is distinguished from a missing one" \
   "no executable entry point" "$OUT"

# ---- 8b. THE SOURCED PATH: a refusal must actually stop the caller -----
#
# provider.sh is documented as sourceable, and a sourced caller runs with
# `set -e` OFF. nw_resolve's refusal of a malformed implementation name
# happens inside a command substitution, so before this was fixed the
# refusal exited only that subshell: nw_run carried on with `impl=''` and
# went looking for `providers/<kind>//provider.sh`.
#
# The stray entry point below is what makes this an assertion rather than
# an accident. Pre-fix, the empty implementation name collapsed the path
# to `providers/tracker/provider.sh` — so if such a file exists and is
# executable, a refused name DISPATCHES. It passed the old suite only
# because no such file happened to be there.

cat > "$WORK/repo/providers/tracker/provider.sh" <<'STRAYEOF'
#!/bin/bash
echo "DISPATCHED $*"
STRAYEOF
chmod +x "$WORK/repo/providers/tracker/provider.sh"

SRC_OUT=$( cd "$WORK/repo" && bash -c '
    set +e
    . providers/lib/provider.sh
    export NW_TRACKER=../../../tmp
    out=$(nw_run tracker fetch MUST-NOT-DISPATCH 2>&1)
    echo "rc=$?"
    printf "%s\n" "$out"
    echo "caller-survived"
' 2>&1 )

case "$SRC_OUT" in
    *"rc=0"*) bad "sourced + set -e off: a malformed name must not return 0 (got: $SRC_OUT)" ;;
    *) ok "sourced + set -e off: a malformed implementation name returns non-zero" ;;
esac
case "$SRC_OUT" in
    *DISPATCHED*) bad "sourced + set -e off: a malformed name DISPATCHED to the stray entry point" ;;
    *) ok "sourced + set -e off: a malformed implementation name does not dispatch" ;;
esac
contains "sourced + set -e off: the refusal is still reported" \
   "malformed implementation name" "$SRC_OUT"
contains "sourced + set -e off: the sourcing shell is not killed by the refusal" \
   "caller-survived" "$SRC_OUT"

# The same shape for the other two entry points that resolve an
# implementation inside a command substitution.
for fn in nw_dir nw_origin nw_doctor; do
    RC=$( cd "$WORK/repo" && bash -c '
        set +e
        . providers/lib/provider.sh
        export NW_TRACKER=../../../tmp
        '"$fn"' tracker >/dev/null 2>&1
        echo "$?"
    ' )
    if [ "$RC" = "0" ]; then
        bad "sourced + set -e off: $fn returned 0 for a malformed implementation name"
    else
        ok "sourced + set -e off: $fn returns non-zero for a malformed implementation name"
    fi
done

# nw_origin must apply the same name check as nw_resolve, or `doctor`
# reports a selection that `resolve` refuses.
OUT=$( cd "$WORK/repo" && NW_TRACKER='../../../tmp' "$P" origin tracker 2>&1 ); RC=$?
eq "origin refuses a malformed implementation name too" "1" "$RC"
contains "origin's refusal names the same problem resolve's does" \
   "malformed implementation name" "$OUT"

rm -f "$WORK/repo/providers/tracker/provider.sh"

# ---- 9. sourcing must not change the caller's error handling -----------

SOURCED=$( bash -c '
    . "$1"
    . "$2"
    false
    echo "survived"
' _ "$CONFIG_SH" "$PROVIDER_SH" 2>&1 )
eq "sourcing the libraries does not turn set -e on in the caller" "survived" "$SOURCED"

# ---- 10. the shipped template ------------------------------------------

eq "templates/night-watchman.config.toml exists and parses" "0" \
   "$( ( unset NW_ROOT; NW_CONFIG="$TEMPLATE"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_parse >/dev/null ) 2>/dev/null; echo $? )"
eq "the template selects the shipped tracker" "jira" \
   "$( cd "$WORK/bare" && NW_CONFIG="$TEMPLATE" "$PROVIDER_SH" resolve tracker )"
eq "NW_TRACKER still overrides the template" "fake" \
   "$( cd "$WORK/bare" && NW_CONFIG="$TEMPLATE" NW_TRACKER=fake "$PROVIDER_SH" resolve tracker )"

# Drift check: the template must declare every kind the resolver knows
# about. Without this, adding a kind to provider.sh and forgetting the
# template leaves adopters with a selection they cannot see or review.
for kind in $( cd "$WORK/bare" && "$PROVIDER_SH" kinds ); do
    VAL=$( unset NW_ROOT; NW_CONFIG="$TEMPLATE"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get "providers.$kind" "" )
    if [ -n "$VAL" ]; then
        ok "the template declares providers.$kind"
    else
        bad "the template does not declare providers.$kind — a kind was added without it"
    fi
    DEFAULT=$( cd "$WORK/bare" && "$PROVIDER_SH" resolve "$kind" )
    eq "the template's $kind matches the built-in default ($DEFAULT)" "$DEFAULT" "$VAL"
done

# The per-provider coordinates cannot be checked against a built-in
# default, because there is none: there is no sensible default value for
# someone else's Jira site or project key, and inventing one is how a
# template starts pointing at a real instance. So they are checked
# against the PLACEHOLDERS instead — which is the failure this actually
# guards against, a real host or project key pasted into the shipped
# template and copied unnoticed into every adopting repo.
TPL_HOST=$( NW_CONFIG="$TEMPLATE"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get tracker.jira.host "" )
TPL_PROJ=$( NW_CONFIG="$TEMPLATE"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get tracker.jira.project "" )
eq "the template's Jira host is the placeholder, not a real site" \
   "example.atlassian.net" "$TPL_HOST"
eq "the template's Jira project is the placeholder, not a real key" \
   "PROJ" "$TPL_PROJ"

# This repo's own committed config is the opposite case: it dogfoods the
# contract, so it must NOT still be carrying the template's placeholders.
REPO_CFG="$REPO/.night-watchman/config.toml"
if [ -f "$REPO_CFG" ]; then
    OWN_PROJ=$( NW_CONFIG="$REPO_CFG"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get tracker.jira.project "" )
    if [ -n "$OWN_PROJ" ] && [ "$OWN_PROJ" != "PROJ" ]; then
        ok "this repo's own config carries a real project key, not the placeholder"
    else
        bad "this repo's .night-watchman/config.toml still has the template placeholder project key"
    fi
    eq "this repo's own config resolves the tracker" "jira" \
       "$( cd "$WORK/bare" && NW_CONFIG="$REPO_CFG" "$PROVIDER_SH" resolve tracker )"
fi

# ---- 11. the publish kind's config keys ------------------------

eq "publish has the fixed verb set" "publish-brief post-headline" \
   "$( cd "$WORK/bare" && "$PROVIDER_SH" verbs publish )"
eq "an unknown publish verb is refused naming the contract" "1" \
   "$( cd "$WORK/bare" && "$PROVIDER_SH" run publish update-page >/dev/null 2>&1; echo $? )"
contains "the refusal names the publish contract" "publish-brief, post-headline" \
   "$( cd "$WORK/bare" && "$PROVIDER_SH" run publish update-page 2>&1 )"

tpl_get() { ( NW_CONFIG="$TEMPLATE"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get "$1" "" ); }
for key in space root_page; do
    eq "the template's publish.atlassian.$key is the placeholder 0" "0" "$(tpl_get "publish.atlassian.$key")"
done
eq "the template's publish.atlassian.project_name is the placeholder" "PROJ" "$(tpl_get publish.atlassian.project_name)"
eq "the template's publish.atlassian.status is the documented default" "on_track" "$(tpl_get publish.atlassian.status)"
eq "the template's dispatch.brief.timebox is the documented default" "3 hours" "$(tpl_get dispatch.brief.timebox)"
eq "the template's dispatch.brief.forbidden is set" "do not touch paths outside the ticket's touches" "$(tpl_get dispatch.brief.forbidden)"
eq "the template carries no dispatch.brief.cloud_id (commented-out example)" "" "$(tpl_get dispatch.brief.cloud_id)"
eq "the template carries no publish host (it falls back to the tracker's)" "" "$(tpl_get publish.atlassian.host)"
for key in publish.atlassian.project_feed publish.atlassian.feeds.PROJ-1; do
    eq "the template's $key is the all-zero placeholder ARI" \
       "ari:cloud:townsquare:00000000-0000-0000-0000-000000000000:project/00000000-0000-0000-0000-000000000000" \
       "$(tpl_get "$key")"
done

# A hyphenated epic key is a legal bare key, and the nested feeds table
# reads back through the same dotted path post-headline looks up.
FEEDS="$WORK/feeds.toml"
printf '[publish.atlassian.feeds]\nNWM-88 = "ari:cloud:townsquare:c:project/p"\n' > "$FEEDS"
eq "a hyphenated epic key maps to its feed" "ari:cloud:townsquare:c:project/p" \
   "$( NW_CONFIG="$FEEDS"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get publish.atlassian.feeds.NWM-88 "" )"

if [ -f "$REPO_CFG" ]; then
    own_get() { ( NW_CONFIG="$REPO_CFG"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_get "$1" "" ); }
    # This repo is published, so the owner-site identifiers stay in the
    # private config, the same way [tracker.jira] host does.
    for key in host space root_page project_feed; do
        eq "this repo's committed config carries no publish.atlassian.$key" "" \
           "$(own_get "publish.atlassian.$key")"
    done
    eq "this repo's committed config carries no publish.atlassian.feeds table" "" \
       "$( NW_CONFIG="$REPO_CFG"; export NW_CONFIG; . "$CONFIG_SH"; nw_config_keys | grep '^publish\.atlassian\.feeds\.' )"
    eq "this repo's publish.atlassian.project_name names this project" "night-watchman" \
       "$(own_get publish.atlassian.project_name)"
    eq "this repo's own config resolves publish" "atlassian" \
       "$( cd "$WORK/bare" && NW_CONFIG="$REPO_CFG" "$PROVIDER_SH" resolve publish )"
fi

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/config-selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/config-selftest.sh: all assertions passed" >&2
exit 0
