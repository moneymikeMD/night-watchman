---
seq: 14
date: 2026-09-19
level: 2
slug: 2026-09-19-wo-026-the-workflow-tool-becomes-the-default-dispatch-implementation-herdr-becomes-the-fallback
title: "WO-026: the Workflow tool becomes the default `dispatch` implementation, herdr becomes the fallback"
---

`providers/dispatch/` was a provider-neutral contract with exactly one
implementation. herdr was not the default so much as the only thing there,
which made the seam an argument rather than a tested design. Meanwhile the
platform grew a dispatcher: Claude Code's Workflow tool runs subagents
in-process under a deterministic script, and the 2026-09-19 work-order wave
ran that way — seven tickets, fourteen agents, nothing above the dispatch
seam changed, and zero dispatch failures against three standing herdr
dispatch bugs on the other path (the cold-boot brief swallow, the
reached-working wait failing on back-to-back starts, the folder-trust dialog
in a fresh worktree). WO-026 turns that into `providers/dispatch/workflow/`
and flips the built-in default to it.

**herdr is demoted, not deleted.** It serves what the Workflow tool does
not: a human-visible pane during a supervised run, a session that outlives
the orchestrating turn, and anything needing a real terminal. Removing it
would trade one single-implementation contract for another, and the value of
this ticket is precisely that the seam now carries two.

**The three herdr dispatch known-issues are deliberately not fixed here.**
Once herdr is the fallback they leave the critical path, and what the
fallback is worth is a separate decision. Re-rank them after this, not
before.

**The verbs do not map one-to-one, and the difference is declared rather
than approximated.** A subprocess cannot call an in-process tool, so the new
provider owns the deterministic half — compose, record, report — and the
orchestrating turn owns the Workflow launch and the `TaskStop`. `start`
composes the brief and records the launch request; it opens no pane, creates
no worktree (the brief tells the agent to make its own, as the wave did),
and writes nothing to the tracker. `stop` records a stop request and names
the `TaskStop` to issue. `watch` is the verb that genuinely does not map:
herdr's is a live pane plus a blocking wait, and the Workflow tool's
equivalents — a task notification and a journal — are delivered to the turn
holding the tool, never to a subprocess it spawned. So `watch` promises
exactly one thing, the state recorded in the run journal at the moment it is
asked, and `--until`/`--timeout` are refused by name. Accepting them would
have produced a wait that could only ever time out, since nothing in that
process's lifetime writes the state being waited on. A provider that
silently means something different is worse than one that declares a gap;
the gap is written down in `providers/README.md` next to the contract.

**The run journal lives outside the repo** (`$XDG_STATE_HOME/night-watchman/
dispatch-workflow` by default). An untracked file inside a worktree dirties
it, and `land-branch.sh` then refuses before reading anything — that
deadlock has already cost one landing.

**Two files the flip forced, both outside the ticket's `touches`.**
`templates/night-watchman.config.toml` had to follow, because
`providers/config-selftest.sh` asserts the template's selection for every
kind equals the built-in default — the flip would otherwise have failed the
selftest it was required to pass. This repo's own
`.night-watchman/config.toml` was flipped for a different reason: it is the
reviewed answer for night-watchman itself, and leaving it pinned to herdr
would have made the flip invisible even to a fresh clone.

**What the flip does not change on the owner's machine.** Resolution is env
| config | default, and `~/.config/night-watchman/nwm.toml` — machine
config, not repo content — still pins `dispatch = "herdr"`. So
`providers/lib/provider.sh origin dispatch` reports `config` and `resolve`
still answers `herdr` wherever `NW_CONFIG` points there. That file was left
alone deliberately; it is the operator's to change, and a flip nobody can
observe is the failure mode this ticket was most likely to ship, so it is
recorded here rather than quietly worked around.
