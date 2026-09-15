#!/bin/bash
#
# Selftest for land-branch.sh's jira mode.
# Unlike file mode (land-branch-selftest.sh), jira mode talks to an external
# dependency — a jira-api.sh-shaped wrapper (--jira-api / $ISSUES_JIRA_API).
# This plugin ships a default one, providers/tracker/jira/jira-api.sh
# but this selftest deliberately does not point at it: it
# supplies a small, stateful mock (jira_mock.py) that implements exactly the
# calls land-branch.sh makes, keeping this selftest independent of the real
# wrapper's HTTP/credential plumbing:
#
#   raw GET <path>                    -> issue status / transitions list
#   --yes write POST <path> <json>    -> apply a transition
#   --yes comment <key> -             -> post a comment (text on stdin)
#
# The mock replays RECORDED shapes, never authored ones: the transitions
# list is providers/tracker/jira/fixtures/issue.transitions.live.json (so
# transition ids 21/61/81 map to status ids 3/10012/10014 as they do live),
# and a refused transition prints the recorded HTTP 400 body from
# issue.transition.rules-rejected.txt. It also models the
# previous-status validator as measured live: Completed is refused unless
# In Progress (3) is among the statuses the issue has EXITED.
#
# State lives in a JSON file OUTSIDE each scratch repo ($WORK/<name>.jira-
# state.json — a repo file would trip the dirty-tree preflight): status_id,
# exited[], comments[], and posts[] (one entry per accepted transition POST:
# the transition id plus origin/main's SHA at that moment, which is how the
# tests assert "before the merge" and "after the push").
#
# Usage: scripts/land-branch-jira-selftest.sh [path-to-land-branch.sh]
# Defaults to the sibling scripts/land-branch.sh.

set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LAND_BRANCH="${1:-$HERE/land-branch.sh}"
KIT="$HERE/lib/kit.sh"
FIXTURES="$HERE/../providers/tracker/jira/fixtures"
[ -r "$LAND_BRANCH" ] || { echo "cannot read $LAND_BRANCH" >&2; exit 2; }
[ -r "$KIT" ] || { echo "cannot read $KIT" >&2; exit 2; }
[ -r "$FIXTURES/issue.transitions.live.json" ] || { echo "cannot read the recorded transitions fixture" >&2; exit 2; }
[ -r "$FIXTURES/issue.transition.rules-rejected.txt" ] || { echo "cannot read the recorded 400 fixture" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 2; }

export JIRA_MOCK_TRANSITIONS="$FIXTURES/issue.transitions.live.json"
export JIRA_MOCK_REJECTED="$FIXTURES/issue.transition.rules-rejected.txt"
# Belt-and-braces: nothing here should reach a real wrapper, but if one ever
# did it would find no routable host.
export JIRA_HOST=127.0.0.1

PASS=0
FAIL=0
ok()  { echo "ok - $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL - $1"; FAIL=$((FAIL + 1)); }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

JIRA_MOCK="$WORK/jira_mock.py"
cat > "$JIRA_MOCK" <<'PYEOF'
#!/usr/bin/env python3
# Minimal jira-api.sh-shaped mock for land-branch-jira-selftest.sh.
# Env:
#   JIRA_MOCK_STATE          path to the state JSON file (required)
#   JIRA_MOCK_BARE           origin bare repo, SHA recorded per POST (required)
#   JIRA_MOCK_TRANSITIONS    recorded transitions list (required)
#   JIRA_MOCK_REJECTED       recorded HTTP 400 bodies (required)
#   JIRA_MOCK_FAIL_TO        a transition id whose POST fails (no state change)
#   JIRA_MOCK_STUCK_TO       a transition id whose POST "succeeds" but moves nothing
#   JIRA_MOCK_FAIL_COMMENT   "1" -> the comment POST fails
import json, os, subprocess, sys

STATE = os.environ["JIRA_MOCK_STATE"]
BARE = os.environ["JIRA_MOCK_BARE"]
with open(os.environ["JIRA_MOCK_TRANSITIONS"]) as f:
    TRANSITIONS = json.load(f)["transitions"]
TO = {t["id"]: t["to"] for t in TRANSITIONS}
NAMES = {t["to"]["id"]: t["to"]["name"] for t in TRANSITIONS}
IN_PROGRESS, COMPLETED = "3", "10014"


def recorded_400(transition_id):
    with open(os.environ["JIRA_MOCK_REJECTED"]) as f:
        lines = f.read().splitlines()
    for i, line in enumerate(lines):
        if line.startswith("# --- transition %s " % transition_id):
            return lines[i + 1]
    sys.exit("mock: no recorded 400 body for transition %s" % transition_id)


def load():
    with open(STATE) as f:
        return json.load(f)


def save(st):
    with open(STATE, "w") as f:
        json.dump(st, f)


def origin_sha():
    return subprocess.check_output(["git", "-C", BARE, "rev-parse", "main"], text=True).strip()


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit("mock: no command")

    if args[0] == "raw":
        path = args[2]
        if path.endswith("/transitions"):
            print(json.dumps({"transitions": TRANSITIONS}))
        elif path.endswith("?fields=status"):
            st = load()
            print(json.dumps({"fields": {"status": {
                "id": st["status_id"], "name": NAMES.get(st["status_id"], "Unknown")}}}))
        else:
            sys.exit("mock: unexpected GET %s" % path)
        return 0

    if args[0] == "--yes" and args[1] == "write":
        tid = json.loads(args[4])["transition"]["id"]
        if os.environ.get("JIRA_MOCK_FAIL_TO") == tid:
            print("jira-api: HTTP 500 POST %s" % args[3], file=sys.stderr)
            return 1
        st = load()
        if tid not in TO:
            sys.exit("mock: unknown transition %s" % tid)
        if TO[tid]["id"] == COMPLETED and IN_PROGRESS not in st["exited"]:
            print("jira-api: HTTP 400 POST %s" % args[3], file=sys.stderr)
            print(recorded_400("81"), file=sys.stderr)
            return 1
        st["posts"].append({"transition": tid, "origin": origin_sha()})
        if os.environ.get("JIRA_MOCK_STUCK_TO") != tid:
            st["exited"].append(st["status_id"])
            st["status_id"] = TO[tid]["id"]
        save(st)
        return 0

    if args[0] == "--yes" and args[1] == "comment":
        text = sys.stdin.read()
        if os.environ.get("JIRA_MOCK_FAIL_COMMENT") == "1":
            print("mock: forced comment failure", file=sys.stderr)
            return 1
        st = load()
        st["comments"].append(text)
        save(st)
        print("comment-1")
        return 0

    sys.exit("mock: unknown command: %s" % " ".join(args))


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x "$JIRA_MOCK"

# fresh_jira_repo NAME STATUS_ID EXITED_CSV — a throwaway git repo under
# $WORK/NAME with local-only config and a bare "origin" at $WORK/NAME.git it
# has already pushed main to (a landing's effect is only ever visible by
# reading the bare origin back). A 'work' branch with one commit is left
# ready to land, and the mock state is seeded with the given status and the
# comma-separated list of statuses the issue has already exited. Prints the
# working repo's path.
fresh_jira_repo() {
    local d="$WORK/$1"
    rm -rf "$d" "$d.git" "$d-land" "$d-land.lock"
    git init -q --bare -b main "$d.git" >/dev/null
    mkdir -p "$d/scripts/lib"
    (
        cd "$d"
        git init -q -b main
        git config commit.gpgsign false
        git config gpg.format openpgp
        git config core.hooksPath /dev/null
        git config user.email "test@example.invalid"
        git config user.name "land-branch jira selftest"
        git config user.signingkey ""
        git remote add origin "$d.git"
        cp "$LAND_BRANCH" scripts/land-branch.sh
        cp "$KIT" scripts/lib/kit.sh
        chmod +x scripts/land-branch.sh
        printf 'placeholder\n' > README.md
        git add -A
        git commit -q -m "init"
        git push -q -u origin main
        git checkout -q -b work
        echo hello > foo.txt
        git add foo.txt
        git commit -q -m "PROJ-1: do the work"
        git checkout -q main
    ) >/dev/null
    python3 -c '
import json, sys
exited = [s for s in sys.argv[3].split(",") if s]
json.dump({"status_id": sys.argv[2], "exited": exited, "comments": [], "posts": []},
          open(sys.argv[1], "w"))
' "$WORK/$1.jira-state.json" "$2" "$3"
    printf '%s\n' "$d"
}

state_field() {
    python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2"
}
comment_count() {
    python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["comments"]))' "$1"
}
# posted_transitions STATE — accepted transition ids in order, space-joined.
posted_transitions() {
    python3 -c 'import json,sys; print(" ".join(p["transition"] for p in json.load(open(sys.argv[1]))["posts"]))' "$1"
}
# post_origin STATE TRANSITION_ID — origin/main SHA when that POST landed.
post_origin() {
    python3 -c '
import json, sys
print(next((p["origin"] for p in json.load(open(sys.argv[1]))["posts"] if p["transition"] == sys.argv[2]), ""))
' "$1" "$2"
}

STATUS_FLAGS="--jira-progress-status 3 --jira-awaiting-status 10012"

# run_land NAME [extra args...] — land 'work' as PROJ-1 in $WORK/NAME with the
# mock wired in; output to $WORK/NAME.out, exit code in $RC.
run_land() {
    local name="$1"; shift
    set +e
    # shellcheck disable=SC2086  # STATUS_FLAGS is a fixed flag list
    (cd "$WORK/$name" && JIRA_MOCK_STATE="$WORK/$name.jira-state.json" JIRA_MOCK_BARE="$WORK/$name.git" \
        ./scripts/land-branch.sh work PROJ-1 --tracker jira --jira-api "$JIRA_MOCK" $STATUS_FLAGS "$@") \
        >"$WORK/$name.out" 2>&1
    RC=$?
    set -e
}

# ---- test J1: the full lifecycle. An In Progress issue is moved to Awaiting
# Deployment BEFORE the merge (origin/main still at its pre-landing SHA when
# that POST lands), then to Completed AFTER the push (origin/main already
# carries the merge), with no previous-status refusal; one outcome comment.

fresh_jira_repo j1 3 10009 >/dev/null
STATE="$WORK/j1.jira-state.json"
BEFORE=$(git -C "$WORK/j1.git" rev-parse main)
run_land j1 --jira-done-status 10014
AFTER=$(git -C "$WORK/j1.git" rev-parse main)
if [ "$RC" -ne 0 ]; then
    bad "testJ1 (full lifecycle): land-branch.sh exited $RC:
$(cat "$WORK/j1.out")"
elif [ "$(posted_transitions "$STATE")" != "61 81" ]; then
    bad "testJ1: transitions posted were '$(posted_transitions "$STATE")', expected '61 81' (Awaiting Deployment, then Completed)"
elif [ "$(post_origin "$STATE" 61)" != "$BEFORE" ]; then
    bad "testJ1: the Awaiting Deployment POST saw origin/main at '$(post_origin "$STATE" 61)', expected the pre-merge '$BEFORE'"
elif [ "$(post_origin "$STATE" 81)" != "$AFTER" ] || [ "$AFTER" = "$BEFORE" ]; then
    bad "testJ1: the Completed POST saw origin/main at '$(post_origin "$STATE" 81)', expected the pushed '$AFTER' (before: $BEFORE)"
elif [ "$(state_field "$STATE" status_id)" != "10014" ]; then
    bad "testJ1: final status_id is '$(state_field "$STATE" status_id)', expected 10014 (Completed)"
elif [ "$(comment_count "$STATE")" != "1" ]; then
    bad "testJ1: expected exactly 1 outcome comment, got $(comment_count "$STATE")"
elif [ "$(git -C "$WORK/j1.git" log --format=%s main | grep -c '^PROJ-1: do the work$' || true)" -lt 1 ]; then
    # grep -c, not grep -q: under pipefail, grep -q exiting on the first
    # match SIGPIPEs git log (141) and fails the pipeline — the J1 flake.
    bad "testJ1: work branch's commit is not reachable from origin/main after landing"
else
    ok "testJ1: Awaiting Deployment before the merge, Completed after the push, read back each time, one comment, no validator refusal"
fi

# ---- test J2: --no-complete --note runs only the first move: the issue ends
# Awaiting Deployment, one note comment, no Completed POST.

fresh_jira_repo j2 3 10009 >/dev/null
STATE="$WORK/j2.jira-state.json"
run_land j2 --no-complete --note "still needs review"
if [ "$RC" -ne 0 ]; then
    bad "testJ2 (--no-complete --note): land-branch.sh exited $RC:
$(cat "$WORK/j2.out")"
elif [ "$(posted_transitions "$STATE")" != "61" ]; then
    bad "testJ2: transitions posted were '$(posted_transitions "$STATE")', expected only '61'"
elif [ "$(comment_count "$STATE")" != "1" ]; then
    bad "testJ2: expected exactly 1 note comment, got $(comment_count "$STATE")"
else
    ok "testJ2: --no-complete moves the issue to Awaiting Deployment only and posts the note"
fi

# ---- test J3: an issue already Completed gets no transition at all, still
# gets the outcome comment, and the landing succeeds.

fresh_jira_repo j3 10014 10009,3,10012 >/dev/null
STATE="$WORK/j3.jira-state.json"
run_land j3 --jira-done-status 10014
if [ "$RC" -ne 0 ]; then
    bad "testJ3 (already Completed): land-branch.sh exited $RC:
$(cat "$WORK/j3.out")"
elif [ -n "$(posted_transitions "$STATE")" ]; then
    bad "testJ3: transitions posted '$(posted_transitions "$STATE")' on an already-Completed issue, expected none"
elif [ "$(comment_count "$STATE")" != "1" ]; then
    bad "testJ3: expected exactly 1 outcome comment, got $(comment_count "$STATE")"
else
    ok "testJ3: an already-Completed issue skips both transitions but still gets the outcome comment"
fi

# ---- test J3b: an issue already Awaiting Deployment skips the first move and
# is Completed after the push.

fresh_jira_repo j3b 10012 10009,3 >/dev/null
STATE="$WORK/j3b.jira-state.json"
run_land j3b --jira-done-status 10014
if [ "$RC" -ne 0 ]; then
    bad "testJ3b (already Awaiting Deployment): land-branch.sh exited $RC:
$(cat "$WORK/j3b.out")"
elif [ "$(posted_transitions "$STATE")" != "81" ]; then
    bad "testJ3b: transitions posted were '$(posted_transitions "$STATE")', expected only '81'"
else
    ok "testJ3b: an issue already Awaiting Deployment skips that move and is Completed after the push"
fi

# ---- test J4: the Awaiting Deployment POST fails — nothing merged, nothing
# pushed, status unchanged, exit 1.

fresh_jira_repo j4 3 10009 >/dev/null
STATE="$WORK/j4.jira-state.json"
BEFORE=$(git -C "$WORK/j4.git" rev-parse main)
JIRA_MOCK_FAIL_TO=61 run_land j4 --jira-done-status 10014
if [ "$RC" -ne 1 ]; then
    bad "testJ4 (Awaiting Deployment POST fails): exit $RC, expected 1:
$(cat "$WORK/j4.out")"
elif [ "$(git -C "$WORK/j4.git" rev-parse main)" != "$BEFORE" ]; then
    bad "testJ4: origin/main moved even though the pre-merge transition failed"
elif [ "$(state_field "$STATE" status_id)" != "3" ]; then
    bad "testJ4: status_id is '$(state_field "$STATE" status_id)', expected unchanged 3"
else
    ok "testJ4: a failing Awaiting Deployment POST stops before the merge with nothing pushed"
fi

# ---- test J4b: the Awaiting Deployment POST returns 2xx but the read-back
# shows no move — refused the same way (a 2xx is not proof).

fresh_jira_repo j4b 3 10009 >/dev/null
BEFORE=$(git -C "$WORK/j4b.git" rev-parse main)
JIRA_MOCK_STUCK_TO=61 run_land j4b --jira-done-status 10014
if [ "$RC" -ne 1 ]; then
    bad "testJ4b (stuck read-back): exit $RC, expected 1:
$(cat "$WORK/j4b.out")"
elif [ "$(git -C "$WORK/j4b.git" rev-parse main)" != "$BEFORE" ]; then
    bad "testJ4b: origin/main moved even though the read-back disagreed"
elif ! grep -q "reads back as 'In Progress'" "$WORK/j4b.out"; then
    bad "testJ4b: message does not say what the read-back showed:
$(cat "$WORK/j4b.out")"
else
    ok "testJ4b: a 2xx Awaiting Deployment POST that does not read back stops before the merge"
fi

# ---- test J5: the Completed POST fails AFTER the push — the landing stands
# (not reverted), exit 1, the issue stays Awaiting Deployment, no outcome
# comment, and the message says to complete it by hand.

fresh_jira_repo j5 3 10009 >/dev/null
STATE="$WORK/j5.jira-state.json"
BEFORE=$(git -C "$WORK/j5.git" rev-parse main)
JIRA_MOCK_FAIL_TO=81 run_land j5 --jira-done-status 10014
if [ "$RC" -ne 1 ]; then
    bad "testJ5 (Completed POST fails after the push): exit $RC, expected 1:
$(cat "$WORK/j5.out")"
elif [ "$(git -C "$WORK/j5.git" rev-parse main)" = "$BEFORE" ]; then
    bad "testJ5: origin/main did not move — the push should have happened before the Completed transition"
elif [ "$(state_field "$STATE" status_id)" != "10012" ]; then
    bad "testJ5: status_id is '$(state_field "$STATE" status_id)', expected 10012 (still Awaiting Deployment)"
elif [ "$(comment_count "$STATE")" != "0" ]; then
    bad "testJ5: an outcome comment was posted although Completed was never confirmed"
elif ! grep -q "NOT completed" "$WORK/j5.out"; then
    bad "testJ5: message does not say the ticket was not completed:
$(cat "$WORK/j5.out")"
else
    ok "testJ5: a failing Completed POST after the push leaves the landing standing, the issue Awaiting Deployment, and exits 1"
fi

# ---- test J6: the message path for the recorded previous-status refusal. An
# issue moved to Awaiting Deployment WITHOUT ever passing through In Progress
# is refused Completed by the (modelled) previous-status validator; land-branch must
# surface Jira's own recorded 400 text verbatim and exit 1.

fresh_jira_repo j6 10012 10009 >/dev/null
STATE="$WORK/j6.jira-state.json"
run_land j6 --jira-done-status 10014
if [ "$RC" -ne 1 ]; then
    bad "testJ6 (recorded previous-status 400): exit $RC, expected 1:
$(cat "$WORK/j6.out")"
elif ! grep -qF "The issue never transitioned through the desired status: In Progress" "$WORK/j6.out"; then
    bad "testJ6: the recorded 400 body is not in the output:
$(cat "$WORK/j6.out")"
elif [ "$(state_field "$STATE" status_id)" != "10012" ]; then
    bad "testJ6: status_id is '$(state_field "$STATE" status_id)', expected unchanged 10012"
else
    ok "testJ6: a previous-status refusal carries the recorded Jira 400 text and exits 1"
fi

# ---- test J7: an issue still To Do (the dispatch step was skipped) is refused
# before anything happens — exit 2, nothing posted, nothing pushed.

fresh_jira_repo j7 10009 "" >/dev/null
STATE="$WORK/j7.jira-state.json"
BEFORE=$(git -C "$WORK/j7.git" rev-parse main)
run_land j7 --jira-done-status 10014
if [ "$RC" -ne 2 ]; then
    bad "testJ7 (issue still To Do): exit $RC, expected 2:
$(cat "$WORK/j7.out")"
elif [ -n "$(posted_transitions "$STATE")" ]; then
    bad "testJ7: transitions were posted on a To Do issue: $(posted_transitions "$STATE")"
elif [ "$(git -C "$WORK/j7.git" rev-parse main)" != "$BEFORE" ]; then
    bad "testJ7: origin/main moved on a refused landing"
elif ! grep -q "lifecycle was skipped" "$WORK/j7.out"; then
    bad "testJ7: refusal does not name the skipped lifecycle:
$(cat "$WORK/j7.out")"
else
    ok "testJ7: a To Do issue is refused before the merge, nothing posted or pushed"
fi

# ---- test J8: --jira-awaiting-status has no default — a jira landing without
# it (flag or env) refuses with exit 2 and names the flag.

fresh_jira_repo j8 3 10009 >/dev/null
set +e
(cd "$WORK/j8" && LAND_BRANCH_JIRA_AWAITING_STATUS='' JIRA_MOCK_STATE="$WORK/j8.jira-state.json" JIRA_MOCK_BARE="$WORK/j8.git" \
    ./scripts/land-branch.sh work PROJ-1 --tracker jira --jira-api "$JIRA_MOCK" \
    --jira-progress-status 3 --jira-done-status 10014) >"$WORK/j8.out" 2>&1
RC=$?
set -e
if [ "$RC" -ne 2 ]; then
    bad "testJ8 (no --jira-awaiting-status): exit $RC, expected 2"
elif ! grep -q -- "--jira-awaiting-status" "$WORK/j8.out"; then
    bad "testJ8: refusal does not name --jira-awaiting-status:
$(cat "$WORK/j8.out")"
else
    ok "testJ8: --jira-awaiting-status has no default; its absence is refused with exit 2"
fi

# ---- test J9: a comment-post failure AFTER a confirmed Completed warns but
# does not fail the run.

fresh_jira_repo j9 3 10009 >/dev/null
STATE="$WORK/j9.jira-state.json"
JIRA_MOCK_FAIL_COMMENT=1 run_land j9 --jira-done-status 10014
if [ "$RC" -ne 0 ]; then
    bad "testJ9 (comment fails after Completed): exit $RC, expected 0:
$(cat "$WORK/j9.out")"
elif [ "$(state_field "$STATE" status_id)" != "10014" ]; then
    bad "testJ9: status_id is '$(state_field "$STATE" status_id)', expected 10014"
else
    ok "testJ9: a comment-post failure after a confirmed Completed warns and leaves the landing standing"
fi

# ---- test J11: the Awaiting Deployment move succeeds and a LATER pre-push
# step fails (lint on the merged tree): the merge is reverted, origin/main is
# unchanged, no Completed POST, and the stop message carries the lifecycle
# note saying the issue stays Awaiting Deployment.

fresh_jira_repo j11 3 10009 >/dev/null
STATE="$WORK/j11.jira-state.json"
BEFORE=$(git -C "$WORK/j11.git" rev-parse main)
run_land j11 --jira-done-status 10014 --lint-cmd false
if [ "$RC" -ne 1 ]; then
    bad "testJ11 (lint fails after the Awaiting move): exit $RC, expected 1:
$(cat "$WORK/j11.out")"
elif [ "$(git -C "$WORK/j11.git" rev-parse main)" != "$BEFORE" ]; then
    bad "testJ11: origin/main moved although lint failed before the push"
elif [ "$(posted_transitions "$STATE")" != "61" ]; then
    bad "testJ11: transitions posted were '$(posted_transitions "$STATE")', expected only '61'"
elif [ "$(state_field "$STATE" status_id)" != "10012" ]; then
    bad "testJ11: status_id is '$(state_field "$STATE" status_id)', expected 10012 (Awaiting Deployment)"
elif ! grep -q "before this stop and stays there" "$WORK/j11.out"; then
    bad "testJ11: stop message lacks the lifecycle note:
$(cat "$WORK/j11.out")"
elif grep -q "untouched" "$WORK/j11.out"; then
    bad "testJ11: stop message claims something is untouched next to the lifecycle note:
$(cat "$WORK/j11.out")"
else
    ok "testJ11: a pre-push failure after the Awaiting move reverts the merge, pushes nothing, and says the issue stays Awaiting Deployment"
fi

# ---- test J10: the default tracker is still 'file', not 'jira' — a run with
# no --tracker behaves as file mode and refuses on a missing issues/ ticket.

fresh_jira_repo j10 3 10009 >/dev/null
set +e
(cd "$WORK/j10" && JIRA_MOCK_STATE="$WORK/j10.jira-state.json" JIRA_MOCK_BARE="$WORK/j10.git" \
    ./scripts/land-branch.sh work PROJ-1 --jira-api "$JIRA_MOCK" --jira-done-status 10014) >"$WORK/j10.out" 2>&1
RC=$?
set -e
if [ "$RC" -eq 0 ]; then
    bad "testJ10 (default tracker): exited 0 in a repo with no issues/ directory — expected the file-mode refusal"
elif ! grep -qi "issues/{open,in-progress,awaiting-deployment,completed,cancelled}" "$WORK/j10.out"; then
    bad "testJ10: refusal doesn't look like the file-mode 'ticket not found' error:
$(cat "$WORK/j10.out")"
else
    ok "testJ10: with no --tracker given, land-branch.sh still defaults to file mode"
fi

echo
echo "$PASS passed, $FAIL failed (against: $LAND_BRANCH)"
[ "$FAIL" -eq 0 ]
