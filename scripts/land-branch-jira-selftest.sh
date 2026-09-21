#!/bin/bash
#
# Selftest for land-branch.sh's jira mode. Deliberately does NOT point at the
# shipped providers/tracker/jira/jira-api.sh: a small stateful mock
# (jira_mock.py) implements exactly the calls land-branch.sh makes, keeping
# this independent of the real wrapper's HTTP/credential plumbing:
#
#   raw GET <path>                    -> issue status / transitions list
#   --yes write POST <path> <json>    -> apply a transition
#   --yes comment <key> -             -> post a comment (text on stdin)
#
# The mock replays RECORDED shapes, never authored ones, from
# providers/tracker/jira/fixtures/. It models the previous-status validator
# as measured live: Completed is refused unless In Progress (3) is among the
# statuses the issue has EXITED.
#
# State lives OUTSIDE each scratch repo ($WORK/<name>.jira-state.json — a repo
# file would trip the dirty-tree preflight). posts[] records each accepted
# transition with origin/main's SHA at that moment, which is how the tests
# assert "before the merge" and "after the push".
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
unset HERDR_ENV HERDR_PANE_ID LAND_BRANCH_ORCHESTRATOR_PANE LAND_BRANCH_HANDOFF_FILE

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
#   JIRA_MOCK_COMMENT_GET_DELAY  the newest comment is missing from the /comment
#                                GET response for its first N calls (NWM-138:
#                                models Jira's read-after-write window)
#   JIRA_MOCK_COMMENT_GET_NEVER  "1" -> the newest comment is missing from every
#                                /comment GET response, regardless of N
#   JIRA_MOCK_COMMENT_GET_FAIL_N the /comment GET itself fails for its first N
#                                calls (a transport failure, not a stale read)
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
        elif "?fields=customfield_" in path:
            print(json.dumps({"fields": {path.split("fields=")[1]: {
                "value": os.environ.get("JIRA_MOCK_EXECUTOR", "agent")}}}))
        elif "/comment" in path:
            st = load()
            n = st.get("comment_gets", 0) + 1
            st["comment_gets"] = n
            save(st)
            fail_n = int(os.environ.get("JIRA_MOCK_COMMENT_GET_FAIL_N", "0") or "0")
            if n <= fail_n:
                print("jira-api: HTTP 500 GET %s" % path, file=sys.stderr)
                return 1
            comments = list(st["comments"])
            delay = os.environ.get("JIRA_MOCK_COMMENT_GET_DELAY")
            never = os.environ.get("JIRA_MOCK_COMMENT_GET_NEVER") == "1"
            if comments and (never or (delay and n <= int(delay))):
                comments = comments[:-1]
            print(json.dumps({"comments": [{"body": c} for c in comments]}))
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
# $WORK/NAME with local-only config, a bare "origin" at $WORK/NAME.git, a
# 'work' branch ready to land, and mock state seeded to STATUS_ID with
# EXITED_CSV already exited. Prints the working repo's path.
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

# ---- NWM-120 closing state, jira mode. A stub herdr logs each call; the
# closing-state comment must be read back before the worker is exited, and a
# failed durable write must leave the worker's pane and workspace alone.

closing_stub() {
    mkdir -p "$WORK/$1.bin"
    cat > "$WORK/$1.bin/herdr" <<'HEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_HERDR_LOG"
case "$1 $2" in
    "agent get") exit 1 ;;
    "worktree list") printf '{"result":{"worktrees":[{"is_linked_worktree":true,"branch":"work","open_workspace_id":"ws1"}]}}\n' ;;
    *) exit 0 ;;
esac
HEOF
    chmod +x "$WORK/$1.bin/herdr"
    : > "$WORK/$1.herdr.log"
}
mkdir -p "$WORK/handoff"
printf 'orchestrator-pane: orch1\n\n## Findings\n- found a thing\n' > "$WORK/handoff/closing-state.md"

run_closing() {
    local name="$1"; shift
    set +e
    # shellcheck disable=SC2086  # STATUS_FLAGS is a fixed flag list
    (cd "$WORK/$name" && HERDR_ENV=1 PATH="$WORK/$name.bin:$PATH" STUB_HERDR_LOG="$WORK/$name.herdr.log" \
        LAND_BRANCH_HANDOFF_FILE="$WORK/handoff/closing-state.md" LAND_BRANCH_ACK_WAIT_S=1 \
        JIRA_MOCK_STATE="$WORK/$name.jira-state.json" JIRA_MOCK_BARE="$WORK/$name.git" env "$@" \
        ./scripts/land-branch.sh work PROJ-1 --tracker jira --jira-api "$JIRA_MOCK" $STATUS_FLAGS --jira-done-status 10014) \
        >"$WORK/$name.out" 2>&1
    RC=$?
    set -e
}

fresh_jira_repo jc1 3 10009 >/dev/null
closing_stub jc1
run_closing jc1
STATE="$WORK/jc1.jira-state.json"
LOG="$WORK/jc1.herdr.log"
if [ "$RC" -ne 0 ]; then
    bad "testJC1 (closing state, jira): exit $RC:
$(cat "$WORK/jc1.out")"
elif [ "$(comment_count "$STATE")" != "2" ]; then
    bad "testJC1: expected outcome + closing-state comments (2), got $(comment_count "$STATE")"
elif ! python3 -c 'import json,sys; sys.exit(0 if "found a thing" in json.load(open(sys.argv[1]))["comments"][1] else 1)' "$STATE"; then
    bad "testJC1: second comment is not the closing state"
elif ! grep -q "closing state written and read back" "$WORK/jc1.out"; then
    bad "testJC1: no read-back confirmation logged:
$(cat "$WORK/jc1.out")"
elif [ "$(grep -n '^pane send-text orch1' "$LOG" | head -1 | cut -d: -f1)" -gt "$(grep -n '^worktree remove' "$LOG" | head -1 | cut -d: -f1)" ]; then
    bad "testJC1: notification came after the workspace removal:
$(cat "$LOG")"
else
    ok "testJC1: the closing state is a tracker comment, read back, before the notification and the workspace removal"
fi

fresh_jira_repo jc2 3 10009 >/dev/null
closing_stub jc2
BEFORE=$(git -C "$WORK/jc2.git" rev-parse main)
run_closing jc2 JIRA_MOCK_FAIL_COMMENT=1
if [ "$RC" -ne 1 ]; then
    bad "testJC2 (durable write fails): exit $RC, expected 1:
$(cat "$WORK/jc2.out")"
elif [ "$(git -C "$WORK/jc2.git" rev-parse main)" = "$BEFORE" ]; then
    bad "testJC2: the landing was reverted/never pushed — a failed closing write must not undo it"
elif [ "$(state_field "$WORK/jc2.jira-state.json" status_id)" != "10014" ]; then
    bad "testJC2: issue is not Completed although the landing stood"
elif grep -q '^worktree remove\|/exit' "$WORK/jc2.herdr.log"; then
    bad "testJC2: the worker was exited or its workspace removed despite the failed write:
$(cat "$WORK/jc2.herdr.log")"
elif ! grep -q "NOT written durably" "$WORK/jc2.out"; then
    bad "testJC2: failure was not loud:
$(cat "$WORK/jc2.out")"
else
    ok "testJC2: a failed closing-state write exits 1 loudly, keeps the landing, and leaves the worker's pane alone"
fi

# ---- NWM-138 testJC3: regression fixture for the exact NWM-123 shape — the
# closing-state comment is present the moment it is POSTed, but the FIRST
# read-back misses it (Jira's read-after-write window); a second read finds
# it. This must exit 0 and tear the workspace down as normal, not report a durable write as failed.

fresh_jira_repo jc3 3 10009 >/dev/null
closing_stub jc3
JC3_START=$SECONDS
run_closing jc3 JIRA_MOCK_COMMENT_GET_DELAY=1 LAND_BRANCH_CLOSING_READBACK_DELAY_S=0
JC3_ELAPSED=$((SECONDS - JC3_START))
STATE="$WORK/jc3.jira-state.json"
if [ "$RC" -ne 0 ]; then
    bad "testJC3 (NWM-123 regression: one missed read-back): exit $RC:
$(cat "$WORK/jc3.out")"
elif [ "$(state_field "$STATE" comment_gets)" -lt 2 ]; then
    bad "testJC3: expected at least 2 read-back attempts, got $(state_field "$STATE" comment_gets)"
elif ! grep -q "closing state written and read back" "$WORK/jc3.out"; then
    bad "testJC3: no read-back confirmation logged:
$(cat "$WORK/jc3.out")"
elif grep -q "NOT written durably" "$WORK/jc3.out"; then
    bad "testJC3: a durable write was reported failed on nothing but a first-read miss:
$(cat "$WORK/jc3.out")"
elif ! grep -q '^worktree remove' "$WORK/jc3.herdr.log"; then
    bad "testJC3: the worker's workspace was not torn down despite the write eventually reading back:
$(cat "$WORK/jc3.herdr.log")"
else
    ok "testJC3: NWM-123 regression — a first read-back miss is retried and reported as success, workspace torn down"
fi

# ---- NWM-138 testJC3b: same one-miss-then-hit shape as testJC3, but with a
# real non-zero LAND_BRANCH_CLOSING_READBACK_DELAY_S, so the backoff
# arithmetic (every other test pins DELAY_S=0) has coverage — measured
# against testJC3's own elapsed time to absorb this runner's timing noise.

fresh_jira_repo jc3b 3 10009 >/dev/null
closing_stub jc3b
JC3B_START=$SECONDS
run_closing jc3b JIRA_MOCK_COMMENT_GET_DELAY=1 LAND_BRANCH_CLOSING_READBACK_DELAY_S=3
JC3B_ELAPSED=$((SECONDS - JC3B_START))
JC3B_EXTRA=$((JC3B_ELAPSED - JC3_ELAPSED))
if [ "$RC" -ne 0 ]; then
    bad "testJC3b (real backoff delay): exit $RC:
$(cat "$WORK/jc3b.out")"
elif [ "$JC3B_EXTRA" -lt 2 ]; then
    bad "testJC3b: one miss with delay=3 should cost ~3s more than testJC3's delay=0 run (delay * attempt 1), got only ${JC3B_EXTRA}s more (testJC3=${JC3_ELAPSED}s, testJC3b=${JC3B_ELAPSED}s) — the backoff sleep does not look like it ran"
else
    ok "testJC3b: a real LAND_BRANCH_CLOSING_READBACK_DELAY_S actually backs off (+${JC3B_EXTRA}s over testJC3's delay=0 run)"
fi

# ---- NWM-138 testJC4: three consecutive misses, all inside the default
# retry budget (4 attempts) — proves this is a bounded RETRY, not one extra
# read tacked onto the original.

fresh_jira_repo jc4 3 10009 >/dev/null
closing_stub jc4
run_closing jc4 JIRA_MOCK_COMMENT_GET_DELAY=3 LAND_BRANCH_CLOSING_READBACK_DELAY_S=0
STATE="$WORK/jc4.jira-state.json"
if [ "$RC" -ne 0 ]; then
    bad "testJC4 (three misses, within budget): exit $RC:
$(cat "$WORK/jc4.out")"
elif [ "$(state_field "$STATE" comment_gets)" != "4" ]; then
    bad "testJC4: expected exactly 4 read-back attempts (3 misses + the hit), got $(state_field "$STATE" comment_gets)"
elif ! grep -q "closing state written and read back" "$WORK/jc4.out"; then
    bad "testJC4: no read-back confirmation logged:
$(cat "$WORK/jc4.out")"
else
    ok "testJC4: three consecutive misses inside the retry budget still end in a reported success"
fi

# ---- NWM-138 testJC5: the closing-state comment NEVER reads back — assert
# the other direction too, so a fix that just stops checking cannot pass.
# After the retries are exhausted this must still be reported failed, the
# landing must stand, and the worker's pane/workspace must be left alone.

fresh_jira_repo jc5 3 10009 >/dev/null
closing_stub jc5
BEFORE=$(git -C "$WORK/jc5.git" rev-parse main)
run_closing jc5 JIRA_MOCK_COMMENT_GET_NEVER=1 LAND_BRANCH_CLOSING_READBACK_DELAY_S=0 LAND_BRANCH_CLOSING_READBACK_ATTEMPTS=3
STATE="$WORK/jc5.jira-state.json"
if [ "$RC" -ne 1 ]; then
    bad "testJC5 (never reads back): exit $RC, expected 1:
$(cat "$WORK/jc5.out")"
elif [ "$(git -C "$WORK/jc5.git" rev-parse main)" = "$BEFORE" ]; then
    bad "testJC5: the landing was reverted/never pushed — a failed read-back must not undo it"
elif [ "$(state_field "$STATE" comment_gets)" != "3" ]; then
    bad "testJC5: expected exactly 3 read-back attempts (the configured budget), got $(state_field "$STATE" comment_gets)"
elif grep -q '^worktree remove\|/exit' "$WORK/jc5.herdr.log"; then
    bad "testJC5: the worker was exited or its workspace removed despite the write never reading back:
$(cat "$WORK/jc5.herdr.log")"
elif ! grep -q "NOT written durably" "$WORK/jc5.out"; then
    bad "testJC5: failure was not loud:
$(cat "$WORK/jc5.out")"
elif ! grep -q "the GET succeeded but the comment list did not carry" "$WORK/jc5.out"; then
    bad "testJC5: the failure message does not say the GET succeeded without the marker:
$(cat "$WORK/jc5.out")"
else
    ok "testJC5: a closing-state write that never reads back is still reported failed once retries are exhausted, landing stands, pane untouched"
fi

# ---- NWM-138 testJC6: the read-back GET fails outright (a transport error,
# not a stale read) on every attempt — the message must say the GET failed,
# never the 'succeeded but missing' wording, so the two failure shapes are
# distinguishable in the tracker comment or a hand-back.

fresh_jira_repo jc6 3 10009 >/dev/null
closing_stub jc6
run_closing jc6 JIRA_MOCK_COMMENT_GET_FAIL_N=9 LAND_BRANCH_CLOSING_READBACK_DELAY_S=0 LAND_BRANCH_CLOSING_READBACK_ATTEMPTS=2
if [ "$RC" -ne 1 ]; then
    bad "testJC6 (read-back GET always fails): exit $RC, expected 1:
$(cat "$WORK/jc6.out")"
elif ! grep -q "GET /issue/PROJ-1/comment failed" "$WORK/jc6.out"; then
    bad "testJC6: failure message does not say the GET itself failed:
$(cat "$WORK/jc6.out")"
elif grep -q "the GET succeeded but" "$WORK/jc6.out"; then
    bad "testJC6: a GET failure was reported with the 'succeeded but missing' wording — the two failure shapes are not distinguishable:
$(cat "$WORK/jc6.out")"
else
    ok "testJC6: a read-back GET that fails outright is reported distinctly from a GET that succeeds without the marker"
fi

# ---- NWM-138 testJC7: both backoff knobs set to non-numeric values must
# fall back to their defaults rather than aborting the arithmetic or killing
# the shell under set -u — the one-miss-then-hit shape must still succeed.

fresh_jira_repo jc7 3 10009 >/dev/null
closing_stub jc7
run_closing jc7 JIRA_MOCK_COMMENT_GET_DELAY=1 LAND_BRANCH_CLOSING_READBACK_DELAY_S=abc LAND_BRANCH_CLOSING_READBACK_ATTEMPTS=0.5
if [ "$RC" -ne 0 ]; then
    bad "testJC7 (malformed backoff knobs): exit $RC, expected 0 (fall back to defaults):
$(cat "$WORK/jc7.out")"
elif ! grep -q "closing state written and read back" "$WORK/jc7.out"; then
    bad "testJC7: no read-back confirmation logged despite the malformed knobs:
$(cat "$WORK/jc7.out")"
else
    ok "testJC7: non-numeric LAND_BRANCH_CLOSING_READBACK_DELAY_S/_ATTEMPTS fall back to their defaults instead of crashing"
fi

# ---- NWM-134 testJG1: HERDR_ENV=1 with no hand-off must leave the tracker and
# origin identical to an unset run; commit dates are pinned so SHAs match.

export GIT_AUTHOR_DATE="2026-01-02T03:04:05Z" GIT_COMMITTER_DATE="2026-01-02T03:04:05Z"
fresh_jira_repo jg1a 3 10009 >/dev/null
closing_stub jg1a
set +e
# shellcheck disable=SC2086  # STATUS_FLAGS is a fixed flag list
(cd "$WORK/jg1a" && HERDR_ENV=1 PATH="$WORK/jg1a.bin:$PATH" STUB_HERDR_LOG="$WORK/jg1a.herdr.log" \
    JIRA_MOCK_STATE="$WORK/jg1a.jira-state.json" JIRA_MOCK_BARE="$WORK/jg1a.git" \
    ./scripts/land-branch.sh work PROJ-1 --tracker jira --jira-api "$JIRA_MOCK" $STATUS_FLAGS --jira-done-status 10014) \
    >"$WORK/jg1a.out" 2>&1
RC_A=$?
set -e
fresh_jira_repo jg1b 3 10009 >/dev/null
run_land jg1b --jira-done-status 10014
RC_B=$RC
unset GIT_AUTHOR_DATE GIT_COMMITTER_DATE
STATE_A="$WORK/jg1a.jira-state.json"
STATE_B="$WORK/jg1b.jira-state.json"
TREE_A=$(git -C "$WORK/jg1a.git" rev-parse "main^{tree}") || TREE_A=a-unreadable
TREE_B=$(git -C "$WORK/jg1b.git" rev-parse "main^{tree}") || TREE_B=b-unreadable
if [ "$RC_A" -ne 0 ] || [ "$RC_B" -ne 0 ]; then
    bad "testJG1: exits differ from 0 (HERDR_ENV=1: $RC_A, unset: $RC_B):
$(tail -8 "$WORK/jg1a.out")"
elif [ "$(comment_count "$STATE_A")" != "1" ] || grep -q "Closing state" "$STATE_A"; then
    bad "testJG1: HERDR_ENV=1 with no hand-off wrote a closing-state comment ($(comment_count "$STATE_A") comments)"
elif ! cmp -s "$STATE_A" "$STATE_B"; then
    bad "testJG1: tracker state differs from the HERDR_ENV-unset run:
$(diff "$STATE_A" "$STATE_B" || true)"
elif [ "$TREE_A" != "$TREE_B" ] || [ "${#TREE_A}" -ne 40 ]; then
    bad "testJG1: origin trees differ ($TREE_A vs $TREE_B)"
elif grep -q "^pane send-text" "$WORK/jg1a.herdr.log"; then
    bad "testJG1: orchestrator notified with no hand-off:
$(cat "$WORK/jg1a.herdr.log")"
else
    ok "testJG1: HERDR_ENV=1 without a hand-off leaves the jira tracker and origin byte-identical to HERDR_ENV unset"
fi

echo
echo "$PASS passed, $FAIL failed (against: $LAND_BRANCH)"
[ "$FAIL" -eq 0 ]
