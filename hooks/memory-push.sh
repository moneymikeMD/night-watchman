#!/bin/bash
#
# memory-push.sh — Claude Code SessionStart, UserPromptSubmit and
# PostToolUseFailure (Bash only) hook. Pushes recalled memory into the
# session as additionalContext, so a model that does not recall on its own
# still sees what the store knows (homelab LAB-345/LAB-355; payload per
# LAB-361). It fails open and silent within a 3 s budget; set
# NW_MEMORY_PUSH=0 to turn it off.
#
# Query per event, raw case, at most 400 characters:
#   SessionStart        the repo name (origin URL basename) and branch
#   UserPromptSubmit    the prompt's head
#   PostToolUseFailure  the error's tail, where Bash puts the failing line;
#                       skipped for other tools and when is_interrupt is set
#
# It runs `memorygraph recall --query Q --limit 5 --json` with
# MEMORY_EMBED_TIMEOUT_MS=1500 in that call's environment only, so any
# backend works and a slow embedder falls back to full-text quickly. The
# 0.14 fork ignores --json and prints markdown with ~150-character
# previews, so the top 3 bodies come from parallel `memorygraph get` calls,
# each cut at 1,250 characters. A preview is never shown as a body: an entry
# whose get fails drops to the title list, and a push with no full body
# injects nothing. The remaining results are listed as titles.
#
# Once per session: a memory injected as a body or a title is not injected
# again, and a query already answered is not re-run. A push with nothing
# new injects nothing. SessionStart with source compact
# or clear starts the record afresh, since that context is gone; resume
# keeps it, since the transcript still carries what was pushed.
#
# Content-word gate (NWM-191): a UserPromptSubmit prompt with 3 or fewer
# content words ("run the tests", "continue") is not sent to recall, since
# some memory contains every such word and recall answers with a full page.
# Content words are the distinct words left after removing PostgreSQL's
# English stop words, the list the store's full-text recall drops; they are
# counted in-process and unstemmed. A prompt that names a ticket key (LAB-201,
# nwm-191) is never gated. The gate runs before the circuit breaker.
# SessionStart and PostToolUseFailure pushes are not gated.
#
# Circuit breaker: a recall that errors or times out, or a push that runs
# out of budget, skips every push on this machine for the next 5 minutes.
# A store that silently drops packets therefore costs the budget once per
# window, not on every prompt.
#
# With MEMORY_BACKEND unset and no <cwd>/.memorygraph/, memorygraph would
# create an empty store in the project, so the hook skips instead.
#
# Usage: fed the hook JSON on stdin, no arguments.
#   NW_MEMORY_PUSH=0          disable the hook
#   NW_MEMORY_PUSH_TIMEOUT    seconds per push, recall and gets together
#                             (default 3; recall measured 0.55-1.83 s with
#                             the 1.5 s embed cap, gets 0.3 s in parallel;
#                             plugin.json's 5 s is the outer backstop)
#   NW_MEMORY_PUSH_BREAKER    seconds to skip pushes after a failure
#                             (default 300)
#   NW_MEMORY_PUSH_SKIP_WORDS a prompt with this many content words or fewer
#                             is not recalled (default 3; 0 turns the gate
#                             off). A prompt naming a ticket key (LAB-201)
#                             is always recalled. Limits: text in an
#                             unsegmented script (Chinese) counts as one
#                             word and is always skipped; "up" and "down"
#                             are stop words, so "docker compose up fails"
#                             counts 3 and is skipped.
#   NW_MEMORY_PUSH_STATE      state directory (default
#                             $TMPDIR/night-watchman-memory-push)
#   NW_MEMORY_PUSH_LOG        append one JSON line per push (event, ids,
#                             seconds, outcome; never the query text); a
#                             gated prompt logs outcome few-words and its
#                             content_words count
#   Off the LAN: a store that drops packets costs one budget (3 s) on the
#   first event, a refused or unresolvable one well under a second, and
#   either way nothing more until the breaker window ends.

[ "${NW_MEMORY_PUSH:-1}" = "0" ] && exit 0
command -v python3 >/dev/null 2>&1 || exit 0
command -v memorygraph >/dev/null 2>&1 || exit 0
python3 "$(cd "$(dirname "$0")" && pwd)/memory-push.py" 2>/dev/null
exit 0
