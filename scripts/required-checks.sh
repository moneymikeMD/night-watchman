#!/bin/bash
#
# required-checks.sh — discover the checks that actually block a merge into
# this repo's default branch and run the ones that are runnable here, so a
# reviewer never has to guess the set and silence is never read as a pass.
#
# Usage: required-checks.sh [--list] [--source auto|ruleset|ci]
#                           [--repo-root DIR] [--ci-file PATH]
#                           [--only CONTEXT] [--skip CONTEXT]
#                           [--allow-run-steps]
#
#   --repo-root is the checkout under review. Without it the checkout holding
#   the current directory is used, and only then the one holding this script —
#   the usual caller runs it out of a plugin cache that is no checkout at all.
#   --source auto (default) reads the branch ruleset through gh and falls back
#   to the job names in .github/workflows/ci.yml; ruleset and ci force one.
#   --list prints the discovered set and its source and runs nothing.
#   --allow-run-steps also executes a job's inline run: steps, which may
#   install packages or reach the network; off by default.
#
# Exit 0 every discovered check passed, 1 at least one failed, 2 usage or
# setup error, 3 nothing failed but at least one check could not be run here.
# A check's own non-zero exit is always a failure, whatever the number; "could
# not run here" travels out of band so it can never be mistaken for one.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

SOURCE=auto
LIST=0
REPO_ROOT=""
CI_FILE=""
ONLY=""
SKIPS=()
ALLOW_RUN=0

die() { printf 'required-checks: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --list) LIST=1 ;;
        --source) SOURCE="${2:-}"; shift ;;
        --repo-root) REPO_ROOT="${2:-}"; shift ;;
        --ci-file) CI_FILE="${2:-}"; shift ;;
        --only) ONLY="${2:-}"; shift ;;
        --skip) SKIPS=("${SKIPS[@]+"${SKIPS[@]}"}" "${2:-}"); shift ;;
        --allow-run-steps) ALLOW_RUN=1 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

case "$SOURCE" in auto|ruleset|ci) ;; *) die "--source must be auto, ruleset or ci" ;; esac

if [ -z "$REPO_ROOT" ]; then
    REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$REPO_ROOT" ] \
      || REPO_ROOT="$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null)"
    [ -n "$REPO_ROOT" ] || die "not in a git checkout; pass --repo-root"
fi
[ -d "$REPO_ROOT" ] || die "no such directory: $REPO_ROOT"
REPO_ROOT="$(cd "$REPO_ROOT" && pwd)"
[ -n "$CI_FILE" ] || CI_FILE="$REPO_ROOT/.github/workflows/ci.yml"

command -v python3 >/dev/null 2>&1 || die "python3 is required"
python3 -c 'import yaml' 2>/dev/null || die "python3 yaml module is required"

is_skipped() {
    local s
    for s in "${SKIPS[@]+"${SKIPS[@]}"}"; do
        [ "$s" = "$1" ] && return 0
    done
    return 1
}

ai_toolkit_root() {
    local c
    for c in "${AI_TOOLKIT_ROOT:-}" "$REPO_ROOT/../ai-toolkit" \
             "$(dirname "$REPO_ROOT")/../ai-toolkit"; do
        [ -n "$c" ] || continue
        [ -d "$c/actions" ] || continue
        (cd "$c" && pwd)
        return 0
    done
    return 1
}

default_branch() {
    local b
    b="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)"
    [ -n "$b" ] && { printf '%s\n' "${b#origin/}"; return 0; }
    printf 'main\n'
}

repo_slug() {
    git -C "$REPO_ROOT" remote get-url origin 2>/dev/null \
      | sed -e 's#^git@github\.com:#-#' -e 's#^https://github\.com/#-#' \
            -e 's#^-##' -e 's#\.git$##'
}

discover_ruleset() {
    command -v gh >/dev/null 2>&1 || return 1
    local slug out; slug="$(repo_slug)"
    case "$slug" in ''|*://*) return 1 ;; esac
    out="$(gh api "repos/$slug/rules/branches/$(default_branch)" \
             --jq '.[]|select(.type=="required_status_checks")
                     |.parameters.required_status_checks[].context' 2>/dev/null)" \
      || return 1
    case "$out" in ''|'{'*|'['*) return 1 ;; esac
    printf '%s\n' "$out"
}

discover_ci() {
    [ -f "$CI_FILE" ] || return 1
    python3 - "$CI_FILE" <<'PY'
import sys, yaml
try:
    doc = yaml.safe_load(open(sys.argv[1])) or {}
except Exception as exc:
    sys.stderr.write("required-checks: cannot parse %s: %s\n"
                     % (sys.argv[1], str(exc).splitlines()[0]))
    raise SystemExit(1)
for key, job in (doc.get('jobs') or {}).items():
    name = job.get('name') if isinstance(job, dict) else None
    print(name or key)
PY
}

job_plan() {
    python3 - "$CI_FILE" "$1" <<'PY'
import base64, sys, yaml
def b64(s): return base64.b64encode(s.encode()).decode()
def scalar(v):
    if isinstance(v, bool): return "true" if v else "false"
    if v is None: return ""
    return str(v)
lines = []
try:
    doc = yaml.safe_load(open(sys.argv[1])) or {}
    jobs = doc.get('jobs') or {}
    want = sys.argv[2]
    key, job = want, jobs.get(want)
    if not isinstance(job, dict):
        key, job = want, None
        for k, j in jobs.items():
            if isinstance(j, dict) and str(j.get('name') or '') == want:
                key, job = k, j
                break
    if job is None:
        raise KeyError(want)
    lines.append("JOB|%s|" % key)
    for step in job.get('steps') or []:
        if not isinstance(step, dict):
            lines.append("OTHER||")
        elif 'uses' in step:
            pairs = [b64(str(k)) + ":" + b64(scalar(v))
                     for k, v in (step.get('with') or {}).items()]
            lines.append("USES|%s|%s"
                         % (str(step['uses']).split('@')[0], " ".join(pairs)))
        elif 'run' in step:
            lines.append("RUN|%s|%s" % (scalar(step.get('working-directory')),
                                        b64(scalar(step['run']))))
        else:
            lines.append("OTHER||")
except Exception:
    lines = ["MISSING||"]
print("\n".join(lines))
PY
}

CONTEXTS=""
ORIGIN=""
if [ "$SOURCE" = ruleset ] || [ "$SOURCE" = auto ]; then
    CONTEXTS="$(discover_ruleset)"
    [ -n "$CONTEXTS" ] && ORIGIN="branch ruleset"
fi
if [ -z "$CONTEXTS" ] && [ "$SOURCE" != ruleset ]; then
    CONTEXTS="$(discover_ci)"
    [ -n "$CONTEXTS" ] && ORIGIN="${CI_FILE#"$REPO_ROOT"/}"
fi
[ -n "$CONTEXTS" ] || die "no required checks discovered (source: $SOURCE)"

if [ -n "$ONLY" ]; then
    printf '%s\n' "$CONTEXTS" | grep -qxF "$ONLY" \
      || die "--only $ONLY is not in the discovered set"
    CONTEXTS="$ONLY"
fi

printf 'required checks (%s): %s\n' "$ORIGIN" "$(printf '%s' "$CONTEXTS" | tr '\n' ' ')"
if [ "$LIST" = 1 ]; then
    exit 0
fi

TOOLKIT="$(ai_toolkit_root)" || TOOLKIT=""
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAILED=0
INCOMPLETE=0
CANNOT_RUN=0
WHY=""

cannot() { CANNOT_RUN=1; WHY="$1"; }

# run_uses REF PAIRS — run one `uses:` step, PAIRS being space-separated
# base64(key):base64(value) inputs. Returns the action's own exit status, and
# sets CANNOT_RUN instead when nothing here can run that action.
run_uses() {
    local ref=$1 script pair k v args=()
    case "$ref" in
        actions/checkout|actions/setup-*|oven-sh/setup-bun) return 0 ;;
        moneymikeMD/ai-toolkit/actions/*) ;;
        *) cannot "no local runner for uses: $ref"; return 0 ;;
    esac
    [ -n "$TOOLKIT" ] \
      || { cannot "ai-toolkit checkout not found (set AI_TOOLKIT_ROOT)"; return 0; }
    script="$TOOLKIT/actions/${ref##*/}/${ref##*/}.py"
    [ -f "$script" ] || { cannot "no ${ref##*/} in the ai-toolkit checkout"; return 0; }
    for pair in $2; do
        k="$(printf '%s' "${pair%%:*}" | base64 --decode 2>/dev/null; printf x)"; k="${k%x}"
        v="$(printf '%s' "${pair#*:}" | base64 --decode 2>/dev/null; printf x)"; v="${v%x}"
        [ -n "$k" ] || continue
        case "$k" in
            path) args=("${args[@]+"${args[@]}"}" "$v") ;;
            report-only) : ;;
            *) args=("${args[@]+"${args[@]}"}" "--$k" "$v") ;;
        esac
    done
    ( cd "$REPO_ROOT" && python3 "$script" "${args[@]+"${args[@]}"}" ) >"$WORK/out" 2>&1
    return $?
}

# run_inline WORKDIR B64SCRIPT — run one inline `run:` step. Returns the
# step's own exit status, and sets CANNOT_RUN instead when inline steps are
# not permitted here.
run_inline() {
    if [ "$ALLOW_RUN" != 1 ]; then
        cannot "inline run: step, needs --allow-run-steps"
        return 0
    fi
    printf '%s' "$2" | base64 --decode >"$WORK/step.sh" 2>/dev/null \
      || { cannot "undecodable run: step"; return 0; }
    ( cd "$REPO_ROOT/${1:-.}" && bash "$WORK/step.sh" ) >"$WORK/out" 2>&1
    return $?
}

report() { printf '%-11s %-22s %s\n' "$1" "$2" "$3"; }

while IFS= read -r ctx <&3; do
    [ -n "$ctx" ] || continue
    if is_skipped "$ctx"; then
        report SKIPPED "$ctx" "skipped on request"
        INCOMPLETE=1
        continue
    fi
    plan="$(job_plan "$ctx")"
    if [ -z "$plan" ] || [ "${plan%%|*}" = MISSING ]; then
        report UNRUNNABLE "$ctx" "no job of that name in ${CI_FILE##*/}"
        INCOMPLETE=1
        continue
    fi
    : >"$WORK/out"
    rc=0; job_key=""; step_fail=0; step_incomplete=0; steps_seen=0; job_why=""
    while IFS='|' read -r kind arg payload; do
        [ -n "$kind" ] || continue
        if [ "$kind" = JOB ]; then job_key="$arg"; continue; fi
        steps_seen=$((steps_seen + 1))
        CANNOT_RUN=0; WHY=""
        case "$kind" in
            USES) run_uses "$arg" "$payload"; rc=$? ;;
            RUN)  run_inline "$arg" "$payload"; rc=$? ;;
            *)    cannot "step is neither uses: nor run:"; rc=0 ;;
        esac
        if [ "$CANNOT_RUN" = 1 ]; then
            step_incomplete=1
            [ -n "$job_why" ] || job_why="$WHY"
            continue
        fi
        [ "$rc" = 0 ] || { step_fail=$rc; break; }
    done <<EOF
$plan
EOF
    if [ "$steps_seen" = 0 ]; then
        step_incomplete=1
        job_why="no runnable steps read from the job"
    fi
    label="$ctx"
    if [ -n "$job_key" ] && [ "$job_key" != "$ctx" ]; then
        label="$ctx (job $job_key)"
    fi
    if [ "$step_fail" != 0 ]; then
        report FAIL "$label" "exit $step_fail"
        sed 's/^/    | /' "$WORK/out" 2>/dev/null
        FAILED=1
    elif [ "$step_incomplete" = 1 ]; then
        report UNRUNNABLE "$label" "$job_why"
        INCOMPLETE=1
    else
        report PASS "$label" "ran locally"
    fi
done 3<<EOF
$CONTEXTS
EOF

[ "$FAILED" = 1 ] && exit 1
[ "$INCOMPLETE" = 1 ] && exit 3
exit 0
