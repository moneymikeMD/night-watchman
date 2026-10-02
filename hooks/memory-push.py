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
QUERY_CHARS = 400
DEFAULT_BUDGET = 3.0
DEFAULT_BREAKER = 300.0
EMBED_TIMEOUT_MS = "1500"
REAP_SECONDS = 0.5
DEFAULT_SKIP_WORDS = 3

HEADER = re.compile(r"^\*\*(\d+)\.\s+(.*)\*\*\s*\(ID:\s*([0-9A-Za-z_-]+)\)\s*$")
WORD = re.compile(r"[^\W_]+")
# PostgreSQL's english.stop verbatim: the list the store's full-text recall drops.
STOP_WORDS = frozenset("""
i me my myself we our ours ourselves you your yours yourself yourselves he him his himself she her hers
herself it its itself they them their theirs themselves what which who whom this that these those am is are
was were be been being have has had having do does did doing a an the and but if or because as until while
of at by for with about against between into through during before after above below to from up down in
out on off over under again further then once here there when where why how all any both each few more
most other some such no nor not only own same so than too very s t can will just don should now
""".split())


class Deadline:
    def __init__(self, seconds):
        self.end = time.monotonic() + seconds

    def left(self):
        return self.end - time.monotonic()


def env_float(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return default


def env_int(name, default):
    try:
        return int(os.environ.get(name) or default)
    except ValueError:
        return default


def content_words(text):
    """Count the distinct words left after English stop-word removal, unstemmed."""
    return len({w for w in WORD.findall(text.lower()) if w not in STOP_WORDS})


def run(argv, deadline, cwd=None, env=None):
    """Run argv within the deadline; return (status, stdout) with status ok, error or timeout."""
    budget = deadline.left()
    if budget <= 0:
        return "timeout", ""
    try:
        proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        return "error", ""
    try:
        out, _ = proc.communicate(timeout=budget)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.communicate(timeout=REAP_SECONDS)
        except subprocess.TimeoutExpired:
            pass  # a descendant that left the process group still holds the pipe
        return "timeout", ""
    if proc.returncode != 0:
        return "error", ""
    return "ok", out.decode("utf-8", "replace")


def as_json(text):
    """Parse JSON that starts on any line, since the CLI can print a preamble first."""
    lines = (text or "").splitlines()
    for i, line in enumerate(lines):
        if line.lstrip()[:1] in ("{", "["):
            try:
                return json.loads("\n".join(lines[i:]))
            except ValueError:
                return None
    return None


def parse_recall(text):
    """Return [{id, title, content, full}] from recall output, JSON or the fork's markdown."""
    data = as_json(text)
    results = []
    if data is not None:
        if isinstance(data, dict):
            data = data.get("results") or data.get("memories") or data.get("items") or []
        for item in data if isinstance(data, list) else []:
            if not isinstance(item, dict):
                continue
            mem = item.get("memory") if isinstance(item.get("memory"), dict) else item
            mid = mem.get("id") or mem.get("memory_id")
            if mid and mem.get("title"):
                content = mem.get("content") or ""
                results.append({"id": str(mid), "title": str(mem["title"]), "content": content,
                                "full": bool(content.strip())})
        return results[:LIMIT]
    for line in (text or "").splitlines():
        head = HEADER.match(line)
        if head and head.group(2).strip():
            results.append({"id": head.group(3), "title": head.group(2).strip(), "content": "", "full": False})
    return results[:LIMIT]


def parse_get(text):
    data = as_json(text)
    if data is not None:
        mem = data.get("memory") if isinstance(data, dict) and isinstance(data.get("memory"), dict) else data
        return (mem.get("content") or "").strip() if isinstance(mem, dict) else ""
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
        status, out = run(["memorygraph", "get", r["id"]], deadline, cwd)
        body = parse_get(out) if status == "ok" else ""
        if body:
            r["content"], r["full"] = body, True

    threads = [threading.Thread(target=fetch, args=(r,), daemon=True) for r in results if not r["full"]]
    for t in threads:
        t.start()
    for t in threads:
        t.join(max(deadline.left(), 0) + REAP_SECONDS + 0.5)


def payload(bodies, titles):
    parts = ["Stored memories that may be relevant. The top ones are shown in full or truncated; "
             "`memorygraph get <id>` prints one in full.\n"]
    for r in bodies:
        parts.append("## %s [%s]\n%s\n" % (r["title"], r["id"], truncate(r["content"])))
    if titles:
        parts.append("Also possibly relevant (title [id]):\n"
                     + "\n".join("- %s [%s]" % (r["title"], r["id"]) for r in titles))
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
    url = run(["git", "-C", cwd, "remote", "get-url", "origin"], deadline)[1].strip()
    top = run(["git", "-C", cwd, "rev-parse", "--show-toplevel"], deadline)[1].strip()
    branch = run(["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"], deadline)[1].strip()
    repo = re.sub(r"\.git$", "", url.rstrip("/").rsplit("/", 1)[-1].rsplit(":", 1)[-1]) if url else ""
    repo = repo or os.path.basename(top or cwd.rstrip("/"))
    return " ".join(p for p in (repo, branch if branch != "HEAD" else "") if p)


class State:
    """Per-session record of answered queries (q) and injected memory ids (m), plus the breaker."""

    def __init__(self, session_id):
        self.dir = os.environ.get("NW_MEMORY_PUSH_STATE") or os.path.join(tempfile.gettempdir(),
                                                                          "night-watchman-memory-push")
        name = re.sub(r"[^A-Za-z0-9_-]", "_", session_id) if session_id else ""
        self.path = os.path.join(self.dir, "session-" + name) if name else None
        self.seen = {"q": set(), "m": set()}
        if self.path:
            try:
                with open(self.path) as fh:
                    for line in fh:
                        kind, _, value = line.strip().partition(" ")
                        if kind in self.seen and value:
                            self.seen[kind].add(value)
            except OSError:
                pass

    def _write(self, text, mode):
        try:
            os.makedirs(self.dir, mode=0o700, exist_ok=True)
            with open(self.path, mode) as fh:
                fh.write(text)
        except OSError:
            pass

    def reset(self):
        self.seen = {"q": set(), "m": set()}
        if self.path:
            self._write("", "w")

    def record(self, kind, values):
        values = [v for v in values if v not in self.seen[kind]]
        self.seen[kind].update(values)
        if self.path and values:
            self._write("".join("%s %s\n" % (kind, v) for v in values), "a")

    def breaker_open(self, window):
        try:
            return time.time() - os.path.getmtime(os.path.join(self.dir, "breaker")) < window
        except OSError:
            return False

    def trip(self):
        try:
            os.makedirs(self.dir, mode=0o700, exist_ok=True)
            with open(os.path.join(self.dir, "breaker"), "w") as fh:
                fh.write("%d\n" % time.time())
        except OSError:
            pass


def log(record):
    path = os.environ.get("NW_MEMORY_PUSH_LOG")
    if not path:
        return
    try:
        with open(path, "a") as fh:
            fh.write(json.dumps(record) + "\n")
    except OSError:
        pass


def query_for(event, data, cwd, deadline):
    if event == "SessionStart":
        return session_query(cwd, deadline).strip()
    if event == "UserPromptSubmit":
        return (data.get("prompt") or "").strip()[:QUERY_CHARS].strip()
    if event == "PostToolUseFailure":
        if data.get("is_interrupt") or data.get("tool_name") != "Bash":
            return ""
        text = (text_of(data.get("error")) or text_of(data.get("tool_response"))).strip()
        return text[-QUERY_CHARS:].strip()
    return ""


def main():
    started = time.monotonic()
    deadline = Deadline(env_float("NW_MEMORY_PUSH_TIMEOUT", DEFAULT_BUDGET))
    data = json.load(sys.stdin)
    event = data.get("hook_event_name") or ""
    cwd = data.get("cwd") or os.getcwd()
    if not os.path.isdir(cwd):
        cwd = os.getcwd()
    if not os.environ.get("MEMORY_BACKEND") and not os.path.isdir(os.path.join(cwd, ".memorygraph")):
        return  # memorygraph would create an empty cwd-local store rather than read one
    state = State(data.get("session_id") or "")
    if event == "SessionStart" and data.get("source") in ("compact", "clear"):
        state.reset()
    if state.breaker_open(env_float("NW_MEMORY_PUSH_BREAKER", DEFAULT_BREAKER)):
        log({"event": event, "outcome": "breaker"})
        return
    query = query_for(event, data, cwd, deadline)
    if not query:
        return
    skip_words = env_int("NW_MEMORY_PUSH_SKIP_WORDS", DEFAULT_SKIP_WORDS)
    if event == "UserPromptSubmit" and skip_words > 0:
        words = content_words(query)
        if words <= skip_words:
            log({"event": event, "outcome": "few-words", "content_words": words, "query_chars": len(query)})
            return
    digest = hashlib.sha256((event + ":" + query).encode("utf-8", "replace")).hexdigest()
    if event != "SessionStart" and digest in state.seen["q"]:
        log({"event": event, "outcome": "repeat"})
        return
    env = dict(os.environ, MEMORY_EMBED_TIMEOUT_MS=EMBED_TIMEOUT_MS)
    status, out = run(["memorygraph", "recall", "--query", query, "--limit", str(LIMIT), "--json"],
                      deadline, cwd, env)
    record = {"event": event, "query_chars": len(query)}
    if status != "ok":
        state.trip()
        record.update(outcome=status, seconds=round(time.monotonic() - started, 2))
        log(record)
        return
    results = parse_recall(out)
    fresh = [r for r in results if r["id"] not in state.seen["m"]]
    top, rest = fresh[:BODIES], fresh[BODIES:]
    if top:
        fill_bodies(top, deadline, cwd)
    if deadline.left() <= 0:
        state.trip()
    else:
        state.record("q", [digest])
    bodies = [r for r in top if r["full"]]
    titles = [r for r in top if not r["full"]] + rest
    record.update(ids=[r["id"] for r in results], new=[r["id"] for r in fresh], full_bodies=len(bodies),
                  seconds=round(time.monotonic() - started, 2))
    if not bodies:
        record["outcome"] = "no-bodies" if top else ("nothing-new" if results else "empty")
        log(record)
        return
    text = payload(bodies, titles)
    state.record("m", [r["id"] for r in bodies + titles])
    record.update(outcome="pushed", payload_chars=len(text))
    log(record)
    sys.stdout.write(json.dumps({"hookSpecificOutput": {"hookEventName": event, "additionalContext": text}}) + "\n")


if __name__ == "__main__":
    try:
        main()
    except Exception:  # a push hook must never fail the session it serves
        pass
    sys.exit(0)
