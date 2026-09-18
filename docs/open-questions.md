# Open questions

Guesses and things checked live against a system this repo doesn't control.
Resolved entries stay here as a record; only unresolved ones carry
`UNVERIFIED`.

## Does a clean Claude Code exit clear the Remote Control entry, or just mark it offline? (NWM-117)

RESOLVED 2026-09-18, tested live on mike-desktop-l.

Started a throwaway `claude` agent in a scratch Herdr pane (not a worktree
worker), confirmed it registered as an interactive session, then sent it
`/exit` followed by Enter (typed via `herdr pane send-text`, confirmed via
`herdr agent read` — the slash-command palette needs the literal text, not
the `send-keys` logical-key set). Herdr reported `agent_not_found` on the
next call against that agent name, and the pane's shell prompt came back —
a clean exit, not a kill.

Before exit, the session showed up in the session list. After exit, it was
gone entirely — no "offline" entry left behind. Contrast: `herdr worktree
remove` on a still-running agent leaves the permanent offline entry the
ticket describes; a Claude-Code-initiated `/exit` does not.

Conclusion for NWM-117: a clean `/exit` before `herdr worktree remove` is
sufficient — no known-issues entry needed, the underlying gap is only that
`herdr worktree remove` alone (killing the process) never gives Claude Code
the chance to deregister.
