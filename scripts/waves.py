#!/usr/bin/env python3
"""Group startable tickets into parallel waves and report the files two or
more of them would collide on, before a wave is dispatched.

    waves.py waves     <dir>   parallel execution plan + worktree commands
    waves.py preflight <dir>   files two or more startable tickets would
                                write; exit 0 no collisions, 1 collisions
                                found, 2 no wave plan exists

    --source files | jira   (default files; ISSUES_SOURCE also works)
        files: <dir> is a directory of stage subdirectories full of
        frontmatter Markdown tickets (triage/, open/, in-progress/, ...).
        jira: <dir> is ignored; tickets are fetched through a caller-supplied
        jira-api.sh-shaped wrapper.

        --jira-api PATH | ISSUES_JIRA_API=PATH     path to jira-api.sh
        --jira-project KEY | ISSUES_JIRA_PROJECT=KEY   Jira project key
        --fixture PATH      read this JSON file instead of calling jira-api.sh

    --landing serial | parallel   (default serial)
        serial: branches merge one at a time behind a lock, so two tickets
        appending the same file produce a small merge and a shared `appends`
        path stays a warning under `preflight`.
        parallel: nothing serialises the merges, so a shared `appends` path
        collides exactly the way a shared `touches` path does.

Owner decision 2026-09-23: work-order is the ticket contract layer only.
Grouping startable tickets into parallel waves, and the pre-dispatch
collision report, are scheduling concerns and belong here, one level below
the contract. This file owns that scheduling; it imports work-order's
reference/issues.py as a module ONLY for ticket loading (frontmatter parsing,
the Jira fetch, has_executor/is_deferred/overlap/epic rollup) — waves(),
preflight(), _plan_waves() and _claims() are this file's own, so a work-order
release that deletes its originals (the paired WO ticket) does not touch this
file's behaviour.

Resolves issues.py through scripts/work-order-root.sh --issues-py, unless
$WAVES_ISSUES_PY already names it (testing / an out-of-tree checkout).

Stdlib only, same reason issues.py gives: tickets get read by agents on
machines nobody prepared in advance.
"""

import sys
import os
import re
import importlib.util
import subprocess
from fnmatch import fnmatch


def die(msg):
    print(f"waves.py: {msg}", file=sys.stderr)
    sys.exit(1)


def _load_issues_module():
    """Import work-order's reference/issues.py by path, never by adding it to
    sys.path — two plugins may both ship an issues.py-named file and import
    machinery must not let one shadow the other."""
    path = os.environ.get("WAVES_ISSUES_PY")
    if not path:
        here = os.path.dirname(os.path.abspath(__file__))
        try:
            path = subprocess.run(
                [os.path.join(here, "work-order-root.sh"), "--issues-py"],
                check=True, capture_output=True, text=True,
            ).stdout.strip()
        except subprocess.CalledProcessError as e:
            die(f"could not resolve work-order's issues.py: {e.stderr.strip()}")
    if not path or not os.path.isfile(path):
        die(f"issues.py not found at '{path}'")
    spec = importlib.util.spec_from_file_location("_wo_issues", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ISSUES = _load_issues_module()

STAGES = ISSUES.STAGES
DONE = ISSUES.DONE
WORKABLE = ISSUES.WORKABLE
RESOLVING = ISSUES.RESOLVING
has_executor = ISSUES.has_executor
is_deferred = ISSUES.is_deferred
overlap = ISSUES.overlap
_numeric_id = ISSUES._numeric_id
compute_epic_rollup = ISSUES.compute_epic_rollup
epic_label = ISSUES.epic_label
load_files = ISSUES.load_files
load_jira = ISSUES.load_jira


def _claims(t, landing):
    """The paths a ticket claims for a wave slot. Under `serial` landing only
    `touches` claims one; under `parallel` an `appends` path does too,
    because no lock serialises the merges that made appending safe."""
    paths = list(t.get("touches") or [])
    if landing == "parallel":
        paths += list(t.get("appends") or [])
    return paths


def _plan_waves(tickets, landing="serial"):
    """Group the dispatchable tickets into waves, without printing anything.
    Returns {waves, stalled, unresolvable, no_progress, deferred_ids, by_id}.
    waves() renders this and preflight() counts it, so the two can never
    disagree about what a wave is."""
    by_id = {t["id"]: t for t in tickets if t.get("id")}
    deferred_ids = {t["id"] for t in tickets if is_deferred(t)}
    pending = [t for t in tickets
               if t["_stage"] in WORKABLE and not is_deferred(t) and not t.get("_is_epic")
               and has_executor(t)]

    def resolved(dep):
        return by_id.get(dep, {}).get("_stage") in RESOLVING

    remaining = list(pending)
    done = {t["id"] for t in tickets if t["_stage"] in DONE}
    plan, stalled, unresolvable, no_progress = [], [], [], False

    while remaining:
        ready = [t for t in remaining
                 if all(d in done or resolved(d) for d in (t.get("blocked_by") or []))]
        if not ready:
            blocked_via_deferral = set()
            changed = True
            while changed:
                changed = False
                for t in remaining:
                    if t["id"] in blocked_via_deferral:
                        continue
                    unresolved = [d for d in (t.get("blocked_by") or [])
                                  if d not in done and not resolved(d)]
                    if unresolved and all(d in deferred_ids or d in blocked_via_deferral
                                           for d in unresolved):
                        blocked_via_deferral.add(t["id"])
                        changed = True

            unresolvable = [t for t in remaining if t["id"] not in blocked_via_deferral]
            if not unresolvable:
                stalled = list(remaining)
            break

        wave, deferred, claimed = [], [], []
        ready = sorted(ready, key=lambda t: _numeric_id(t["id"]))
        for t in ready:
            paths = _claims(t, landing)
            if any(overlap(p, c) for p in paths for c in claimed):
                deferred.append(t)
            else:
                wave.append(t)
                claimed.extend(paths)

        plan.append(wave)
        if not wave:
            no_progress = True
            break
        for t in wave:
            done.add(t["id"])
        remaining = deferred + [t for t in remaining if t not in wave and t not in deferred]

    return {"waves": plan, "stalled": stalled, "unresolvable": unresolvable,
            "no_progress": no_progress, "deferred_ids": deferred_ids, "by_id": by_id}


def waves(tickets, root, landing="serial"):
    rollup = compute_epic_rollup(tickets)
    plan = _plan_waves(tickets, landing)
    by_id, deferred_ids = plan["by_id"], plan["deferred_ids"]

    for wave_no, wave in enumerate(plan["waves"], 1):
        agents = [t for t in wave if t.get("executor") == "agent"]
        print(f"\nWave {wave_no} — {len(wave)} ticket(s), "
              f"{len(agents)} agent-workable in parallel")
        for t in wave:
            mark = {"agent": "  ", "human": " *", "mixed": " ~"}.get(t.get("executor"), " ?")
            print(f" {mark} {t['id']}  {t.get('title','')}{epic_label(t, rollup)}")
        if agents:
            print("\n    worktrees:")
            for t in agents:
                print(f"      git worktree add ../wt-{t['id'].lower()} -b {t['id'].lower()}")

    if plan["no_progress"]:
        print("  no progress possible")
        return 1
    if plan["unresolvable"]:
        print("  cycle or unresolvable dependency among: "
              + ", ".join(t["id"] for t in plan["unresolvable"]))
        return 1

    if plan["stalled"]:
        print("\nBlocked by a deferred dependency (not a cycle — resolves once "
              "the date passes):")
        for t in plan["stalled"]:
            direct = [d for d in (t.get("blocked_by") or []) if d in deferred_ids]
            if direct:
                labels = ", ".join(
                    f"{d} until {by_id[d].get('defer_until')}" for d in direct)
                print(f"    {t['id']}  {t.get('title','')}  blocked by deferred {labels}")
            else:
                print(f"    {t['id']}  {t.get('title','')}  blocked transitively "
                      f"via a deferred dependency")

    print("\n  * needs a human   ~ agent works it, human finishes it")
    return 0


def _decl_paths(t):
    """Every path a ticket declares, paired with the field it was declared in."""
    return ([(p, "touches") for p in (t.get("touches") or [])]
            + [(p, "appends") for p in (t.get("appends") or [])])


_GLOB_META = re.compile(r"[*?\[]")


def _hotspot_key(x, y):
    """One heading for a colliding glob pair: the more literal side, so
    `reference/*` and `reference/issues.py` read as one hotspot, not two."""
    xg, yg = bool(_GLOB_META.search(x)), bool(_GLOB_META.search(y))
    if xg != yg:
        return y if xg else x
    return min(x, y)


def startable_now(tickets):
    """The tickets a dispatcher could hand out right now — wave 1 as it
    would be if nothing collided."""
    by_id = {t["id"]: t for t in tickets if t.get("id")}
    done = {t["id"] for t in tickets if t["_stage"] in DONE}
    return [t for t in tickets
            if t["_stage"] in WORKABLE and not is_deferred(t)
            and not t.get("_is_epic") and has_executor(t)
            and all(d in done or by_id.get(d, {}).get("_stage") in RESOLVING
                    for d in (t.get("blocked_by") or []))]


def preflight(tickets, root, landing="serial"):
    """Report every file two or more startable tickets would write, before
    the wave is dispatched. Returns 0 when nothing collides under `landing`,
    1 when something does, and 2 when no wave plan exists at all."""
    ready = startable_now(tickets)

    hotspots = {}
    for i, a in enumerate(ready):
        for b in ready[i + 1:]:
            for x, kx in _decl_paths(a):
                for y, ky in _decl_paths(b):
                    if not overlap(x, y):
                        continue
                    h = hotspots.setdefault(
                        _hotspot_key(x, y),
                        {"ids": set(), "kinds": set(), "hard": False})
                    h["ids"].update((a["id"], b["id"]))
                    h["kinds"].update((kx, ky))
                    if kx == "touches" and ky == "touches":
                        h["hard"] = True

    plans = {}
    for mode in ("serial", "parallel"):
        p = _plan_waves(tickets, mode)
        if p["unresolvable"] or p["no_progress"]:
            stuck = ", ".join(t["id"] for t in p["unresolvable"]) or "(no progress)"
            print(f"waves.py: no {mode} wave plan — cycle or unresolvable "
                  f"dependency among: {stuck}", file=sys.stderr)
            return 2
        plans[mode] = p

    print(f"preflight — {len(ready)} startable ticket(s), landing={landing}")
    collisions = 0
    for key in sorted(hotspots):
        h = hotspots[key]
        blocking = h["hard"] or landing == "parallel"
        collisions += 1 if blocking else 0
        kinds = "+".join(sorted(h["kinds"]))
        ids = ", ".join(sorted(h["ids"], key=_numeric_id))
        print(f"  {'COLLISION' if blocking else 'warn     '}  {key}  "
              f"via {kinds} — {ids}")
    if not hotspots:
        print("  no file is written by more than one startable ticket")

    print(f"\n  waves: {len(plans['serial']['waves'])} under serial landing, "
          f"{len(plans['parallel']['waves'])} under parallel")
    print(f"\n{len(hotspots)} shared file(s), {collisions} collision(s) under "
          f"{landing} landing")
    return 1 if collisions else 0


CMDS = {"waves": waves, "preflight": preflight}


def parse_args(argv):
    """waves.py <waves|preflight> [dir] [--source files|jira] [--jira-api PATH]
    [--jira-project KEY] [--fixture PATH] [--landing serial|parallel]. Flags
    may appear in any order after the command."""
    if len(argv) > 1 and argv[1] in ("-h", "--help", "help"):
        print(__doc__)
        sys.exit(0)
    if len(argv) < 2 or argv[1] not in CMDS:
        print(__doc__)
        sys.exit(2)
    cmd = argv[1]
    rest = argv[2:]

    source = os.environ.get("ISSUES_SOURCE", "files")
    jira_api = os.environ.get("ISSUES_JIRA_API")
    jira_project = os.environ.get("ISSUES_JIRA_PROJECT")
    fixture = None
    landing = "serial"
    positional = []

    i = 0
    while i < len(rest):
        a = rest[i]
        if a == "--source":
            if i + 1 >= len(rest):
                die("--source needs a value (files or jira)")
            source = rest[i + 1]
            i += 2
        elif a == "--jira-api":
            if i + 1 >= len(rest):
                die("--jira-api needs a path")
            jira_api = rest[i + 1]
            i += 2
        elif a == "--jira-project":
            if i + 1 >= len(rest):
                die("--jira-project needs a value (e.g. PROJ)")
            jira_project = rest[i + 1]
            i += 2
        elif a == "--fixture":
            if i + 1 >= len(rest):
                die("--fixture needs a path")
            fixture = rest[i + 1]
            i += 2
        elif a == "--landing":
            if i + 1 >= len(rest):
                die("--landing needs a value (serial or parallel)")
            landing = rest[i + 1]
            i += 2
        elif a in ("-h", "--help"):
            print(__doc__)
            sys.exit(0)
        else:
            positional.append(a)
            i += 1

    if source not in ("files", "jira"):
        die(f"--source must be 'files' or 'jira' (got '{source}')")
    if landing not in ("serial", "parallel"):
        die(f"--landing must be 'serial' or 'parallel' (got '{landing}')")

    root = positional[0].rstrip("/") if positional else None
    if source == "files" and not root:
        print(__doc__)
        sys.exit(2)

    return cmd, source, root, jira_api, jira_project, fixture, landing


def main(argv):
    cmd, source, root, jira_api, jira_project, fixture, landing = parse_args(argv)
    if source == "jira":
        if jira_project:
            ISSUES.JIRA_PROJECT_KEY = jira_project
            ISSUES.JIRA_JQL = ISSUES._jira_jql(jira_project)
        tickets = load_jira(jira_api, fixture)
        label = root or f"jira:{ISSUES.JIRA_PROJECT_KEY}"
    else:
        tickets = load_files(root)
        label = root
    return CMDS[cmd](tickets, label, landing=landing)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
