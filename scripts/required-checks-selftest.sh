#!/bin/bash
#
# Selftest for required-checks.sh. Structurally offline: every case runs
# against a mktemp git repo with a stub ai-toolkit checkout and a stub `gh`
# on PATH, so no case reaches GitHub or the real ruleset. One case uses the
# real ai-toolkit comment-lint when a checkout is discoverable and counts
# itself skipped when it is not; the summary line carries that count so a CI
# run without ai-toolkit cannot read as full coverage.
#
# Usage: scripts/required-checks-selftest.sh [path-to-required-checks.sh]

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RC_SH="${1:-$HERE/required-checks.sh}"
[ -x "$RC_SH" ] || { echo "cannot execute $RC_SH" >&2; exit 2; }

PASS=0
FAIL=0
SKIPPED=0
ok()   { echo "ok - $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }
skip() { echo "skip - $1"; SKIPPED=$((SKIPPED + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

REPO="$WORK/repo"
TOOLKIT="$WORK/toolkit"
mkdir -p "$REPO/.github/workflows" "$TOOLKIT/actions/comment-lint" \
         "$TOOLKIT/actions/argvcheck"

cat >"$TOOLKIT/actions/comment-lint/comment-lint.py" <<'PY'
import os, sys
limit = 4
args = list(sys.argv[1:])
target = "."
while args:
    a = args.pop(0)
    if a == "--max-block":
        limit = int(args.pop(0))
    elif a.startswith("--"):
        args.pop(0)
    else:
        target = a
bad = []
for root, _, names in os.walk(target):
    for n in names:
        p = os.path.join(root, n)
        try:
            text = open(p).read()
        except (OSError, UnicodeDecodeError):
            continue
        if "OVERLONG" in text:
            bad.append(p)
if bad:
    print("stub comment-lint: over-long comment block in %s (max %d)" % (bad[0], limit))
    sys.exit(1)
print("stub comment-lint: clean")
PY

cat >"$TOOLKIT/actions/argvcheck/argvcheck.py" <<'PY'
import sys
print("ARGV: %r" % (sys.argv[1:],))
sys.exit(1)
PY

git -C "$REPO" init --quiet 2>/dev/null
printf 'echo hi\n' >"$REPO/kept.sh"

write_ci() {
    cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  comment-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: moneymikeMD/ai-toolkit/actions/comment-lint@v1
        with:
          path: .
          max-block: 4
YAML
}
write_ci

run_rc() {
    set +e
    AI_TOOLKIT_ROOT="$TOOLKIT" "$RC_SH" --source ci --repo-root "$REPO" \
        --ci-file "$REPO/.github/workflows/ci.yml" "$@" >"$WORK/out" 2>"$WORK/err"
    RC=$?
    set -e
}

# 1. A branch that trips a required check fails, and the output names it.
printf 'echo one\n# OVERLONG marker\n' >"$REPO/offender.sh"
run_rc
if [ "$RC" = 1 ] && grep -q '^FAIL .*comment-lint' "$WORK/out"; then
    ok "a tripped required check exits 1 and names the check"
else
    bad "a tripped required check exits 1 and names the check (rc=$RC)"; cat "$WORK/out"
fi
if grep -q 'over-long comment block' "$WORK/out"; then
    ok "the failing check's own output is quoted in the report"
else
    bad "the failing check's own output is quoted in the report"
fi

# 2. The same tree without the offending block passes.
rm -f "$REPO/offender.sh"
run_rc
if [ "$RC" = 0 ] && grep -q '^PASS .*comment-lint' "$WORK/out"; then
    ok "a clean tree exits 0, so a reviewer that always refuses cannot pass"
else
    bad "a clean tree exits 0 (rc=$RC)"; cat "$WORK/out"
fi

# 3. The set is read at run time: a job added to ci.yml is picked up with no
#    edit to this script or to agents/spec-reviewer.md.
run_rc --list
if grep -q 'comment-lint' "$WORK/out" && ! grep -q 'fourth-gate' "$WORK/out"; then
    ok "discovery starts from the ci.yml jobs actually present"
else
    bad "discovery starts from the ci.yml jobs actually present"; cat "$WORK/out"
fi
cat >>"$REPO/.github/workflows/ci.yml" <<'YAML'
  fourth-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: some/unknown-action@v1
YAML
run_rc --list
if grep -q 'fourth-gate' "$WORK/out"; then
    ok "a fourth job added to ci.yml is discovered without a code change"
else
    bad "a fourth job added to ci.yml is discovered without a code change"; cat "$WORK/out"
fi

# 4. A discovered check with no local runner is reported, never silently passed.
run_rc
if [ "$RC" = 3 ] && grep -q '^UNRUNNABLE .*fourth-gate' "$WORK/out"; then
    ok "a check with no local runner exits 3 and is named UNRUNNABLE"
else
    bad "a check with no local runner exits 3 and is named UNRUNNABLE (rc=$RC)"; cat "$WORK/out"
fi

# 5. A failure still wins over an unrunnable check.
printf 'echo one\n# OVERLONG marker\n' >"$REPO/offender.sh"
run_rc
if [ "$RC" = 1 ]; then
    ok "a failing check outranks an unrunnable one in the exit code"
else
    bad "a failing check outranks an unrunnable one in the exit code (rc=$RC)"
fi
rm -f "$REPO/offender.sh"

# 6. --skip is loud: it never turns into a pass.
write_ci
run_rc --skip comment-lint
if [ "$RC" = 3 ] && grep -q '^SKIPPED .*comment-lint' "$WORK/out"; then
    ok "a skipped check exits 3 and is reported, not silently passed"
else
    bad "a skipped check exits 3 and is reported (rc=$RC)"; cat "$WORK/out"
fi

# 7. A required context with no job of that name is reported, not ignored.
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  ghost:
    runs-on: ubuntu-latest
YAML
run_rc
if [ "$RC" = 3 ] && grep -q '^UNRUNNABLE .*ghost' "$WORK/out"; then
    ok "a context with no matching job is reported UNRUNNABLE"
else
    bad "a context with no matching job is reported UNRUNNABLE (rc=$RC)"; cat "$WORK/out"
fi
write_ci

# 8. Inline run: steps stay off unless asked for, then execute.
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  inline:
    runs-on: ubuntu-latest
    steps:
      - run: test -f kept.sh
YAML
run_rc
if [ "$RC" = 3 ] && grep -q 'allow-run-steps' "$WORK/out"; then
    ok "an inline run: step is UNRUNNABLE by default"
else
    bad "an inline run: step is UNRUNNABLE by default (rc=$RC)"; cat "$WORK/out"
fi
run_rc --allow-run-steps
if [ "$RC" = 0 ]; then
    ok "--allow-run-steps executes the job's own run: step"
else
    bad "--allow-run-steps executes the job's own run: step (rc=$RC)"; cat "$WORK/out"
fi
write_ci

# 9. Usage errors are exit 2, distinct from a check failure.
run_rc --source bogus
if [ "$RC" = 2 ]; then
    ok "an unknown --source is exit 2, not a check failure"
else
    bad "an unknown --source is exit 2 (rc=$RC)"
fi
set +e
"$RC_SH" --source ci --repo-root "$REPO" --ci-file "$WORK/absent.yml" --list \
    >"$WORK/out" 2>"$WORK/err"
RC=$?
set -e
if [ "$RC" = 2 ]; then
    ok "a missing ci.yml is exit 2, not an empty pass"
else
    bad "a missing ci.yml is exit 2 (rc=$RC)"
fi

# 10. A check's own non-zero exit is a failure whatever the number. Exit 3 is
#     the trap: the script uses 3 for "nothing failed but something could not
#     run", and a gate that exits 3 must not be laundered into that.
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  strictgate:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo 'GATE VIOLATION: three problems found'
          exit 3
YAML
run_rc --allow-run-steps
if [ "$RC" = 1 ] && grep -q '^FAIL .*strictgate' "$WORK/out" \
   && grep -q 'GATE VIOLATION' "$WORK/out"; then
    ok "a gate that exits 3 is FAIL with exit 1, not UNRUNNABLE"
else
    bad "a gate that exits 3 is FAIL with exit 1 (rc=$RC)"; cat "$WORK/out"
fi

# 11. One step that cannot run here does not disarm the steps after it.
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  comment-lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - run: echo setting up
      - uses: moneymikeMD/ai-toolkit/actions/comment-lint@v1
        with:
          path: .
          max-block: 4
YAML
printf 'echo one\n# OVERLONG marker\n' >"$REPO/offender.sh"
run_rc
if [ "$RC" = 1 ] && grep -q '^FAIL .*comment-lint' "$WORK/out"; then
    ok "a run: step before a uses: step does not hide the uses: step's failure"
else
    bad "a run: step before a uses: step does not hide its failure (rc=$RC)"; cat "$WORK/out"
fi
rm -f "$REPO/offender.sh"
run_rc
if [ "$RC" = 3 ] && grep -q '^UNRUNNABLE .*comment-lint' "$WORK/out"; then
    ok "a job with one unrun step is UNRUNNABLE even when its other steps pass"
else
    bad "a job with one unrun step is UNRUNNABLE, not PASS (rc=$RC)"; cat "$WORK/out"
fi
write_ci

# 12. with: inputs reach the action as written, including a block scalar and
#     a YAML boolean.
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  argvcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: moneymikeMD/ai-toolkit/actions/argvcheck@v1
        with:
          exclude: |
            vendor
            node_modules
          strict: true
          max-block: 80
YAML
run_rc
EXPECT_ARGV="ARGV: ['--exclude', 'vendor\nnode_modules\n', '--strict', 'true', '--max-block', '80']"
if grep -qF "$EXPECT_ARGV" "$WORK/out"; then
    ok "a multi-line with: value stays one argument and a YAML bool stays lowercase"
else
    bad "with: inputs reach the action as written"; cat "$WORK/out"
fi
write_ci

# 13. A context whose name contains a space is one context, not two.
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  "build (3.11)":
    runs-on: ubuntu-latest
    steps:
      - run: true
YAML
run_rc
if [ "$RC" = 3 ] && grep -q 'build (3.11)' "$WORK/out" \
   && ! grep -q 'no job of that name' "$WORK/out"; then
    ok "a context containing a space resolves to its job, not to two ghosts"
else
    bad "a context containing a space resolves to its job (rc=$RC)"; cat "$WORK/out"
fi
write_ci

# 14. A job's display name is what GitHub reports as the context, so the
#     discovered set uses it and a ruleset context resolves through it.
cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  lint:
    name: comment-lint
    runs-on: ubuntu-latest
    steps:
      - uses: moneymikeMD/ai-toolkit/actions/comment-lint@v1
        with:
          path: .
          max-block: 4
YAML
run_rc --list
if grep -q ': comment-lint *$' "$WORK/out"; then
    ok "discovery reports a job's name:, which is the context GitHub checks"
else
    bad "discovery reports a job's name:"; cat "$WORK/out"
fi

# 15. --source auto prefers the branch ruleset, and honours what it returns.
mkdir -p "$WORK/bin"
cat >"$WORK/bin/gh" <<'SH'
#!/bin/bash
case "$*" in
    *rules/branches/*) printf 'comment-lint\nphantom-gate\n' ;;
    *) exit 1 ;;
esac
SH
chmod +x "$WORK/bin/gh"
git -C "$REPO" remote add origin git@github.com:acme/widget.git 2>/dev/null
printf 'echo one\n# OVERLONG marker\n' >"$REPO/offender.sh"
set +e
( PATH="$WORK/bin:$PATH" AI_TOOLKIT_ROOT="$TOOLKIT" \
  "$RC_SH" --repo-root "$REPO" --ci-file "$REPO/.github/workflows/ci.yml" \
) >"$WORK/out" 2>"$WORK/err"
RC=$?
set -e
if grep -q '^required checks (branch ruleset): comment-lint phantom-gate' "$WORK/out"; then
    ok "--source auto reads the branch ruleset and names it as the origin"
else
    bad "--source auto reads the branch ruleset"; cat "$WORK/out" "$WORK/err"
fi
if grep -q '^UNRUNNABLE .*phantom-gate' "$WORK/out"; then
    ok "a ruleset context absent from ci.yml is honoured and reported, not dropped"
else
    bad "a ruleset context absent from ci.yml is honoured"; cat "$WORK/out"
fi
if [ "$RC" = 1 ] && grep -q '^FAIL .*comment-lint (job lint)' "$WORK/out"; then
    ok "a ruleset context resolves to the job whose name: matches, and still fails"
else
    bad "a ruleset context resolves through job name: (rc=$RC)"; cat "$WORK/out"
fi
rm -f "$REPO/offender.sh"
cat >"$WORK/bin/gh" <<'SH'
#!/bin/bash
printf '{"message":"Upgrade to GitHub Pro or make this repository public",'
printf '"status":"403"}\n'
exit 1
SH
chmod +x "$WORK/bin/gh"
set +e
( PATH="$WORK/bin:$PATH" AI_TOOLKIT_ROOT="$TOOLKIT" \
  "$RC_SH" --repo-root "$REPO" --ci-file "$REPO/.github/workflows/ci.yml" --list \
) >"$WORK/out" 2>"$WORK/err"
RC=$?
set -e
if [ "$RC" = 0 ] && grep -q '^required checks (ci.yml\|^required checks (.github' "$WORK/out" \
   && ! grep -q 'Upgrade to GitHub Pro' "$WORK/out"; then
    ok "a gh error body is not mistaken for a required context; ci.yml takes over"
else
    bad "a gh error body is not mistaken for a required context (rc=$RC)"; cat "$WORK/out"
fi
write_ci

# 16. The checkout under review is the current directory's, not the script's.
FAKE="$WORK/fakeplugin/scripts"
OTHER="$WORK/other"
mkdir -p "$FAKE" "$OTHER/.github/workflows"
cp "$RC_SH" "$FAKE/required-checks.sh"
chmod +x "$FAKE/required-checks.sh"
git -C "$OTHER" init --quiet 2>/dev/null
cat >"$OTHER/.github/workflows/ci.yml" <<'YAML'
name: CI
on:
  push:
    branches: [main]
jobs:
  other-gate:
    runs-on: ubuntu-latest
    steps:
      - uses: some/unknown-action@v1
YAML
set +e
( cd "$REPO" && AI_TOOLKIT_ROOT="$TOOLKIT" \
  "$FAKE/required-checks.sh" --source ci --list ) >"$WORK/out" 2>"$WORK/err"
RC=$?
set -e
if [ "$RC" = 0 ] && grep -q 'comment-lint' "$WORK/out"; then
    ok "invoked from outside any checkout, it reviews the current directory's repo"
else
    bad "invoked from outside any checkout, it reviews \$PWD's repo (rc=$RC)"
    cat "$WORK/out" "$WORK/err"
fi
set +e
( cd "$OTHER" && AI_TOOLKIT_ROOT="$TOOLKIT" \
  "$FAKE/required-checks.sh" --source ci --repo-root "$REPO" --list \
) >"$WORK/out" 2>"$WORK/err"
RC=$?
set -e
if [ "$RC" = 0 ] && grep -q 'comment-lint' "$WORK/out" \
   && ! grep -q 'other-gate' "$WORK/out"; then
    ok "--repo-root wins over both \$PWD and the script's own location"
else
    bad "--repo-root wins over \$PWD and the script's location (rc=$RC)"
    cat "$WORK/out" "$WORK/err"
fi

# 17. A malformed ci.yml is one line of diagnosis, not a parser traceback.
printf 'name: CI\njobs:\n  x: [1, 2\n' >"$REPO/.github/workflows/ci.yml"
run_rc --list
if [ "$RC" = 2 ] && grep -q 'cannot parse' "$WORK/err" \
   && ! grep -q 'Traceback' "$WORK/err"; then
    ok "a malformed ci.yml is exit 2 with a one-line parse error"
else
    bad "a malformed ci.yml is exit 2 with a one-line parse error (rc=$RC)"
    cat "$WORK/err"
fi
write_ci

# 18. The real ai-toolkit comment-lint, when a checkout is discoverable.
REAL=""
for c in "${AI_TOOLKIT_ROOT:-}" "$HERE/../../ai-toolkit" "$HERE/../../../ai-toolkit"; do
    [ -n "$c" ] && [ -f "$c/actions/comment-lint/comment-lint.py" ] && { REAL="$c"; break; }
done
if [ -z "$REAL" ]; then
    skip "real ai-toolkit comment-lint (no checkout discoverable)"
else
    printf 'echo one\n' >"$REPO/real.sh"
    for i in 1 2 3 4 5 6; do printf '# line %s\n' "$i" >>"$REPO/real.sh"; done
    set +e
    AI_TOOLKIT_ROOT="$REAL" "$RC_SH" --source ci --repo-root "$REPO" \
        --ci-file "$REPO/.github/workflows/ci.yml" >"$WORK/out" 2>&1
    RC=$?
    set -e
    if [ "$RC" = 1 ] && grep -q 'comment block' "$WORK/out"; then
        ok "the real comment-lint action fails an over-long block through this script"
    else
        bad "the real comment-lint action fails an over-long block (rc=$RC)"; cat "$WORK/out"
    fi
    rm -f "$REPO/real.sh"
fi

echo
echo "passed: $PASS  failed: $FAIL  skipped: $SKIPPED"
[ "$FAIL" = 0 ] || exit 1
