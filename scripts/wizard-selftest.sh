#!/bin/bash
#
# Selftest for scripts/lib/wizard.sh + templates/wizard-stages.sh. Runs the
# example wizard end to end under /bin/bash (bash 3.2 on stock macOS) with
# gh, open and op stubbed on PATH and stdin scripted, then asserts a planted
# secret string never appears in the combined stdout+stderr of the run, and
# never lands in ENV_FILE — only its reference locator does.
#
# Usage: scripts/wizard-selftest.sh

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

STUBBIN="$WORK/bin"
mkdir -p "$STUBBIN"
# Stubs must not touch stdin: open_url's `open` call inherits the wizard's
# own stdin (unredirected), so a stub that reads it here would drain the
# scripted answers meant for `ask`/`ask_secret` further down the script.
# The sink command given to ask_secret gets its own explicit pipe instead.
for cmd in gh open op; do
    cat > "$STUBBIN/$cmd" <<'EOF'
#!/bin/bash
exit 0
EOF
    chmod +x "$STUBBIN/$cmd"
done

# A second PATH with gh/open stubbed but op absent, for test5: isolation
# must stay structural (see templates/CLAUDE.md) — dropping to a bare
# system PATH there would let open_url's `open` call reach the real
# browser opener instead of exercising the "sink missing" path.
STUBBIN_NO_OP="$WORK/bin-no-op"
mkdir -p "$STUBBIN_NO_OP"
for cmd in gh open; do
    cp "$STUBBIN/$cmd" "$STUBBIN_NO_OP/$cmd"
done

SECRET="pl4nted-s3cret-Xk9"
ENV_FILE="$WORK/out.env"

set +e
OUT=$(printf '\nclient-id-value\n%s\n' "$SECRET" \
    | PATH="$STUBBIN:$PATH" ENV_FILE="$ENV_FILE" \
      /bin/bash "$ROOT/templates/wizard-stages.sh" 2>&1)
RC=$?
set -e

if [ "$RC" -eq 0 ]; then
    ok "test1: example wizard exits 0 with gh/open/op stubbed"
else
    bad "test1: example wizard exited $RC:
$OUT"
fi

if printf '%s' "$OUT" | grep -qF "$SECRET"; then
    bad "test2: planted secret appeared in combined stdout+stderr"
else
    ok "test2: planted secret never appears in combined output"
fi

if [ -f "$ENV_FILE" ] && grep -qF "$SECRET" "$ENV_FILE"; then
    bad "test3: planted secret written to ENV_FILE in plaintext"
else
    ok "test3: ENV_FILE never receives the raw secret value"
fi

if [ -f "$ENV_FILE" ] && grep -q '^PROVIDER_SECRET_KEY=op://' "$ENV_FILE" \
    && grep -q '^PROVIDER_CLIENT_ID=client-id-value$' "$ENV_FILE"; then
    ok "test4: ENV_FILE records the client id and the secret's ref locator only"
else
    bad "test4: ENV_FILE missing expected non-secret rows:
$(cat "$ENV_FILE" 2>/dev/null || echo '(no file)')"
fi

set +e
OUT2=$(printf '\nclient-id-value\n%s\n' "$SECRET" \
    | PATH="$STUBBIN_NO_OP:/usr/bin:/bin" ENV_FILE="$WORK/out2.env" \
      /bin/bash "$ROOT/templates/wizard-stages.sh" 2>&1)
set -e

if printf '%s' "$OUT2" | grep -qF "$SECRET"; then
    bad "test5: planted secret appeared in output when the sink command (op) is missing"
elif printf '%s' "$OUT2" | grep -qi 'still to do by hand'; then
    ok "test5: missing sink command is reported as owed, never as a leaked secret"
else
    bad "test5: expected a 'still to do by hand' note when op is unavailable:
$OUT2"
fi

echo
echo "$PASS passed, $FAIL failed (against: $ROOT/scripts/lib/wizard.sh)"
[ "$FAIL" -eq 0 ]
