---
title: "dispatch start fails agent_not_ready on Claude's folder-trust dialog in a fresh Herdr worktree"
heading_raw: "dispatch start fails agent_not_ready on Claude's folder-trust dialog in a fresh Herdr worktree — MEDIUM"
severity: MEDIUM
status: open
qualifiers: []
note: "fixed by detect-and-answer in herdr-ticket-start.sh; entry stays until the fix lands and is verified"
tickets: []
slug: dispatch-start-fails-agent-not-ready-on-claude-s-folder-trust-dialog-in-a-fresh-herdr-worktree
---

On some hosts (observed on linux-host, not on a Mac) a fresh Herdr
worktree makes Claude Code show its interactive folder-trust dialog ("Is
this a project you created or one you trust?") the first time it starts in
that pane. `herdr agent start` then returns `agent_not_ready: blocked
during startup` and `providers/dispatch/herdr/herdr-ticket-start.sh`
aborted after the worktree had already been created — a related report on
2026-09-15, and again the same day for a research workspace.

Manual recovery worked every time: `herdr agent send-keys <pane> Down
Enter` selects "Yes, I trust this folder", the agent goes idle in about two
seconds, and the brief can be sent with `herdr agent prompt`.

2026-09-15 follow-up observation: the
dialog is not per-worktree after all. Once one worktree per repo has been
accepted by hand, further dispatches on the same host start their agents
with no dialog and need no send-keys — it appears to fire once per repo,
not once per ticket (unverified which key Claude Code uses: possibly the
git common dir, possibly the first accepted path under
`~/.herdr/worktrees/<repo>`). Trusting the parent `~/.herdr` directory did
not prevent the first prompt for night-watchman.

A fix lands in `herdr-ticket-start.sh`'s dispatch-start verb: on
agent_not_ready, read the pane (`herdr agent read <pane> --source
visible`), and if it shows the dialog's own markers, answer it
(`send-keys ... Down Enter`) and wait for idle before continuing. Any other
agent_not_ready cause still aborts as before. The homelab copy of the
script needs the same change under its own LAB ticket — tracked
separately, out of scope here.
