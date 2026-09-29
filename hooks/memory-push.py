#!/usr/bin/env python3
#
# memory-push.py — the logic behind hooks/memory-push.sh; see that file's
# header for the contract. Reads one hook payload on stdin, prints at most
# one hookSpecificOutput JSON object on stdout, and always exits 0.

import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

LIMIT = 5
BODIES = 3
BODY_CHARS = 1250
QUERY_CHARS = 1000
DEFAULT_BUDGET = 6.0

HEADER = re.compile(r"^\*\*(\d+)\.\s+(.*)\*\*\s*\(ID:\s*([0-9A-Za-z_-]+)\)\s*$")
PREVIEW = re.compile(r"^Content:\s?(.*)$")


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def left(self):
        return self.end - time.monotonic()


def run(argv, deadline, cwd=None):
    """Run argv within the deadline and return its stdout, or None on any failure."""
    budget = deadline.left()
    if budget <= 0:
        return None
    try:
        proc = subprocess.Popen(argv, cwd=cwd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return None
    try:
        out, _ = proc.communicate(timeout=budget)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        proc.communicate()
        return None
    if proc.returncode != 0:
        return None
    return out.decode("utf-8", "replace")


def as_json(text):
    text = (text or "").strip()
    if not text or text[0] not in "[{":
        return None
    try:
        return json.loads(text)
    except ValueError:
        return None


def parse_recall(text):
    """Return [{id, title, content, full}] from recall output, JSON or the fork's markdown."""
    data = as_json(text)
    if data is not None:
        if isinstance(data, dict):
            data = data.get("results") or data.get("memories") or data.get("items") or []
        results = []
        for item in data if isinstance(data, list) else []:
            if not isinstance(item, dict):
                continue
            mem = item.get("memory") if isinstance(item.get("memory"), dict) else item
            mid = mem.get("id") or mem.get("memory_id")
            if mid and mem.get("title"):
                content = mem.get("content") or ""
                results.append({"id": str(mid), "title": str(mem["title"]), "content": content,
                                "full": bool(content)})
        return results[:LIMIT]
    results = []
    for line in (text or "").splitlines():
        head = HEADER.match(line)
        if head:
            results.append({"id": head.group(3), "title": head.group(2).strip(), "content": "", "full": False})
            continue
        preview = PREVIEW.match(line)
        if preview and results and not results[-1]["content"]:
            results[-1]["content"] = preview.group(1).strip()
    return results[:LIMIT]


def parse_get(text):
    data = as_json(text)
    if data is not None:
        mem = data.get("memory") if isinstance(data, dict) and isinstance(data.get("memory"), dict) else data
        return (mem.get("content") or "") if isinstance(mem, dict) else ""
    marker = "**Content:**"
    at = (text or "").find(marker)
    return text[at + len(marker):].strip() if at >= 0 else ""


def truncate(text, limit=BODY_CHARS):
    text = text.strip()
    if len(text) <= limit:
        return text
    cut = text[:limit]
    space = cut.rfind(" ")
    return (cut[:space] if space > limit // 2 else cut).rstrip() + " [truncated]"


def fill_bodies(results, deadline, cwd):
    def fetch(r):
        body = parse_get(run(["memorygraph", "get", r["id"]], deadline, cwd) or "")
        if body:
            r["content"], r["full"] = body, True

    threads = [threading.Thread(target=fetch, args=(r,), daemon=True) for r in results[:BODIES] if not r["full"]]
    for t in threads:
        t.start()
    for t in threads:
        t.join(max(deadline.left(), 0) + 0.5)


def payload(results):
    parts = ["Stored memories that may be relevant. The top ones are shown in full or truncated; "
             "`memorygraph get <id>` prints one in full.\n"]
    for r in results[:BODIES]:
        parts.append("## %s [%s]\n%s\n" % (r["title"], r["id"], truncate(r["content"])))
    rest = results[BODIES:]
    if rest:
        parts.append("Also possibly relevant (title [id]):\n"
                     + "\n".join("- %s [%s]" % (r["title"], r["id"]) for r in rest))
    return "\n".join(parts).rstrip() + "\n"


def text_of(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return "\n".join(text_of(value.get(k)) for k in ("stderr", "stdout", "error", "output") if value.get(k))
    if isinstance(value, list):
        return "\n".join(text_of(v) for v in value)
    return ""


def session_query(cwd, deadline):
    url = (run(["git", "-C", cwd, "remote", "get-url", "origin"], deadline) or "").strip()
    top = (run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], deadline) or "").strip()
    branch = (run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], deadline) or "").strip()
    repo = re.sub(r"\.git$", "", url.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]) if url else ""
    repo = repo or os.path.basename(top or cwd.rstrip("/"))
    return " ".join(p for p in (repo, branch if branch != "HEAD" else "") if p)


def seen_before(session_id, key):
    """True when this session already pushed for this key; records it otherwise."""
    if not session_id:
        return False
    state_dir = os.environ.get("NW_MEMORY_PUSH_STATE") or os.path.join(tempfile.gettempdir(),
                                                                        "night-watchman-memory-push")
    path = os.path.join(state_dir, re.sub(r"[^A-Za-z0-9_-]", "_", session_id))
    digest = hashlib.sha256(key.encode("utf-8", "replace")).hexdigest()
    try:
        with open(path) as fh:
            if digest in fh.read().split():
                return True
    except OSError:
        pass
    try:
        os.makedirs(state_dir, mode=0o700, exist_ok=True)
        with open(path, "a") as fh:
            fh.write(digest + "\n")
    except OSError:
        pass
    return False


def log(record):
    path = os.environ.get("NW_MEMORY_PUSH_LOG")
    if not path:
        return
    try:
        with open(path, "a") as fh:
            fh.write(json.dumps(record) + "\n")
    except OSError:
        pass


def main():
    started = time.monotonic()
    try:
        budget = float(os.environ.get("NW_MEMORY_PUSH_TIMEOUT") or DEFAULT_BUDGET)
    except ValueError:
        budget = DEFAULT_BUDGET
    deadline = Deadline(budget)
    data = json.load(sys.stdin)
    event = data.get("hook_event_name") or ""
    cwd = data.get("cwd") or os.getcwd()
    if not os.path.isdir(cwd):
        cwd = os.getcwd()
    if not os.environ.get("MEMORY_BACKEND") and not os.path.isdir(os.path.join(cwd, ".memorygraph")):
        return  # memorygraph would create an empty cwd-local store rather than read one
    if event == "SessionStart":
        query = session_query(cwd, deadline)
    elif event == "UserPromptSubmit":
        query = data.get("prompt") or ""
    elif event == "PostToolUseFailure":
        query = text_of(data.get("error")) or text_of(data.get("tool_response"))
    else:
        return
    query = query.strip()
    query = query[-QUERY_CHARS:].strip() if event == "PostToolUseFailure" else query[:QUERY_CHARS].strip()
    if not query:
        return
    if event != "SessionStart" and seen_before(data.get("session_id") or "", event + ":" + query):
        log({"event": event, "outcome": "repeat"})
        return
    results = parse_recall(run(["memorygraph", "recall", "--query", query, "--limit", str(LIMIT), "--json"],
                               deadline, cwd))
    if results:
        fill_bodies(results, deadline, cwd)
    record = {"event": event, "query_chars": len(query), "ids": [r["id"] for r in results],
              "seconds": round(time.monotonic() - started, 2)}
    if not results:
        record["outcome"] = "timeout" if deadline.left() <= 0 else "empty"
        log(record)
        return
    text = payload(results)
    record.update(outcome="pushed", payload_chars=len(text), full_bodies=sum(r["full"] for r in results[:BODIES]))
    log(record)
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:  # a push hook must never fail the session it serves
        pass
    sys.exit(0)
