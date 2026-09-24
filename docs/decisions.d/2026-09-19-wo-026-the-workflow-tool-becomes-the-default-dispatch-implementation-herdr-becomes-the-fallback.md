---
seq: 14
date: 2026-09-19
level: 2
slug: 2026-09-19-wo-026-the-workflow-tool-becomes-the-default-dispatch-implementation-herdr-becomes-the-fallback
title: "WO-026: the Workflow tool becomes the default `dispatch` implementation, herdr becomes the fallback"
---

`providers/dispatch/` was a provider-neutral contract with exactly one
implementation, herdr, which made the seam an argument rather than a tested
design. Claude Code's Workflow tool runs subagents in-process under a
deterministic script; the 2026-09-19 work-order wave ran that way — seven
tickets, fourteen agents, nothing above the dispatch seam changed, and zero
dispatch failures against three standing herdr dispatch bugs on the other
path (the cold-boot brief swallow, the reached-working wait failing on
back-to-back starts, the folder-trust dialog in a fresh worktree).
`providers/dispatch/workflow/` is the built-in default.

**herdr is the fallback, not deleted.** It serves what the Workflow tool
does not: a human-visible pane during a supervised run, a session that
outlives the orchestrating turn, and anything needing a real terminal.
Removing it would trade one single-implementation contract for another;
the value of the seam is that it carries two.

**The three herdr dispatch known-issues stay open on their own merits.**
Off the critical path, what the fallback is worth is a separate decision.

**The verbs do not map one-to-one, and the difference is declared rather
than approximated.** A subprocess cannot call an in-process tool, so the
provider owns the deterministic half — compose, record, report — and the
orchestrating turn owns the Workflow launch and the `TaskStop`. `start`
composes the brief and records the launch request; it opens no pane,
creates no worktree (the brief tells the agent to make its own), and writes
nothing to the tracker. `stop` records a stop request and names the
`TaskStop` to issue. `watch` is the verb that genuinely does not map:
herdr's is a live pane plus a blocking wait, and the Workflow tool's
equivalents — a task notification and a journal — are delivered to the turn
holding the tool, never to a subprocess it spawned. So `watch` promises
exactly one thing, the state recorded in the run journal at the moment it
is asked, and `--until`/`--timeout` are refused by name. Accepting them
would produce a wait that could only ever time out. A provider that silently
means something different is worse than one that declares a gap; the gap is
written in `providers/README.md` next to the contract.

**The run journal lives outside the repo**
(`$XDG_STATE_HOME/night-watchman/dispatch-workflow` by default). An
untracked file inside a worktree dirties it, and `land-branch.sh` then
refuses before reading anything.

`templates/night-watchman.config.toml` selects `workflow` too, because
`providers/config-selftest.sh` asserts the template's selection for every
kind equals the built-in default. This repo's own
`.night-watchman/config.toml` and the owner's `~/.config/night-watchman/nwm.toml`
select `workflow`.
