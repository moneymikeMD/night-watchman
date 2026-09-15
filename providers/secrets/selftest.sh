#!/bin/bash
#
# Selftest for providers/secrets/ — the `read.sh` dispatcher plus the two
# shipped implementations, `env` and `op`. A stranger with no 1Password
# access must be able to run this and a first session with `env` only, so
# the `op` cases here stub the `op` binary rather than requiring a real
# vault.
#
# What is asserted:
#   1  env: a set NW_<REF> env var is read, and read.sh dispatches to it
#      through NW_SECRETS=env exactly as the ticket's own verify command
#      does.
#   2  env: an unset env var is a named error, not a silent empty value.
#   3  env: a malformed reference is refused before it is turned into an
#      env var name.
#   4  op: REF resolves an item/field/vault out of config into an
#      op://vault/item/field URI, handed to a stubbed `op` on PATH.
#   5  op: the per-ref vault overrides [secrets.op].vault, which overrides
#      the built-in default "Private".
#   6  op: a REF missing its item/field configuration is a named error.
#   7  the secret value is never seen on stderr, in either implementation.
#
# Runs entirely against a scratch directory; the stub `op` never contacts
# 1Password, and `env` never contacts anything.
#
# Usage: providers/secrets/selftest.sh

set -uo pipefail

unset NW_CONFIG NW_ROOT NW_TRACKER NW_SECRETS NW_DISPATCH NW_MEMORY

HERE="$(cd "$(dirname "$0")" && pwd)"
READ_SH="$HERE/read.sh"
ENV_PROVIDER="$HERE/env/provider.sh"
OP_PROVIDER="$HERE/op/provider.sh"

for f in "$READ_SH" "$ENV_PROVIDER" "$OP_PROVIDER"; do
    [ -x "$f" ] || { echo "not executable: $f" >&2; exit 2; }
done

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

# ---- 1-3. env -----------------------------------------------------------

run_env() { ( unset NW_CONFIG NW_ROOT; export NW_SECRETS=env; "$@" ) }

OUT=$(run_env env NW_JIRA_TOKEN=abc "$READ_SH" jira.token)
eq "env: read.sh dispatches NW_SECRETS=env and prints the value" "abc" "$OUT"

BYTES=$(run_env env NW_JIRA_TOKEN=abc "$READ_SH" jira.token | wc -c | tr -d ' ')
eq "env: the ticket's own verify command prints exactly value+newline" "4" "$BYTES"

ERR=$( ( run_env "$ENV_PROVIDER" read jira.token ) 2>&1 ); RC=$?
eq "env: an unset variable exits non-zero" "1" "$RC"
contains "env: an unset variable names the variable it looked for" "NW_JIRA_TOKEN" "$ERR"

ERR=$( ( run_env env NW_JIRA_TOKEN=abc "$ENV_PROVIDER" read "Not Valid" ) 2>&1 ); RC=$?
eq "env: a malformed reference exits non-zero" "1" "$RC"
contains "env: a malformed reference is refused by name" "malformed secret reference" "$ERR"

ERRLESS=$( ( run_env env NW_JIRA_TOKEN=abc "$ENV_PROVIDER" read jira.token ) 2>&1 1>/dev/null )
eq "env: the secret value never appears on stderr" "" "$ERRLESS"

# ---- 4-6. op, against a stubbed `op` binary ------------------------------

mkdir -p "$WORK/bin" "$WORK/repo/.night-watchman"
cat > "$WORK/bin/op" <<'OPEOF'
#!/bin/bash
# Stand-in for the real `op` CLI: `op read op://VAULT/ITEM/FIELD` prints a
# value derived from its own argument, so the assertions below can check
# the exact URI this provider built without ever touching 1Password.
[ "$1" = "read" ] || { echo "stub op: unexpected verb: $1" >&2; exit 1; }
case "$2" in
    op://TestVault/jira-item/token) echo "s3cr3t" ;;
    op://OverrideVault/other-item/password) echo "override-value" ;;
    *) echo "stub op: no such reference: $2" >&2; exit 1 ;;
esac
OPEOF
chmod +x "$WORK/bin/op"

cat > "$WORK/repo/.night-watchman/config.toml" <<'EOF'
[secrets.op]
vault = "Private"

[secrets.op.jira.token]
item  = "jira-item"
field = "token"
vault = "TestVault"

[secrets.op.other.secret]
item  = "other-item"
field = "password"
vault = "OverrideVault"

[secrets.op.no.field]
item = "incomplete-item"
EOF

# shellcheck disable=SC2030  # deliberately scoped to this subshell: the stub `op` must not leak onto the operator's real PATH
run_op() { ( cd "$WORK/repo" && unset NW_CONFIG; export PATH="$WORK/bin:$PATH"; "$@" ) }

OUT=$(run_op "$OP_PROVIDER" read jira.token)
eq "op: an item/field/vault in config resolves to the built op:// URI" "s3cr3t" "$OUT"

OUT=$(run_op "$OP_PROVIDER" read other.secret)
eq "op: the per-ref vault overrides [secrets.op].vault" "override-value" "$OUT"

ERR=$( ( run_op "$OP_PROVIDER" read no.field ) 2>&1 ); RC=$?
eq "op: a ref missing its field exits non-zero" "1" "$RC"
contains "op: a ref missing its field is refused by name" "no 1Password field configured" "$ERR"

ERR=$( ( run_op "$OP_PROVIDER" read never.configured ) 2>&1 ); RC=$?
eq "op: a ref with no config at all exits non-zero" "1" "$RC"
contains "op: a ref with no config at all is refused by name" "no 1Password item configured" "$ERR"

ERRLESS=$( ( run_op "$OP_PROVIDER" read jira.token ) 2>&1 1>/dev/null )
eq "op: the secret value never appears on stderr" "" "$ERRLESS"

# read.sh itself dispatches to op through the resolver when NW_SECRETS is
# unset (op is the built-in default for the secrets kind).
# shellcheck disable=SC2031  # deliberately scoped to this subshell, same as run_op above
OUT=$( cd "$WORK/repo" && unset NW_CONFIG NW_SECRETS && export PATH="$WORK/bin:$PATH" && "$READ_SH" jira.token )
eq "read.sh reaches op through the resolver with no override" "s3cr3t" "$OUT"

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/secrets/selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/secrets/selftest.sh: all assertions passed" >&2
exit 0
