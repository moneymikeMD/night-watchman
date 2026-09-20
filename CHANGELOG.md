# Changelog

All notable changes to this project are documented here.

## [0.11.0](https://github.com/moneymikeMD/night-watchman/compare/v0.10.0...v0.11.0) (2026-09-20)


### Features

* **to-issues-mine:** add the mining half of to-issues ([#27](https://github.com/moneymikeMD/night-watchman/issues/27)) ([4a2febd](https://github.com/moneymikeMD/night-watchman/commit/4a2febd3bad1d81415900ee1d52acc279e3b1fa2))

## [0.10.0](https://github.com/moneymikeMD/night-watchman/compare/v0.9.2...v0.10.0) (2026-09-20)


### Features

* **dispatch:** make the Workflow tool the default dispatch provider, herdr the fallback ([#21](https://github.com/moneymikeMD/night-watchman/issues/21)) ([3a314db](https://github.com/moneymikeMD/night-watchman/commit/3a314db69b84cf6f477cd95b67f7d06056a79ea7))


### Bug Fixes

* **known-issues:** make lint catch manifest hash drift, repair it ([#20](https://github.com/moneymikeMD/night-watchman/issues/20)) ([517e7b9](https://github.com/moneymikeMD/night-watchman/commit/517e7b9fd801a6565303be9f95a282b1479602ba))

## [0.9.2](https://github.com/moneymikeMD/night-watchman/compare/v0.9.1...v0.9.2) (2026-09-19)


### Bug Fixes

* **guard-fs-writes:** make segment splitting quote-aware and resolve the whole worktree set ([#14](https://github.com/moneymikeMD/night-watchman/issues/14)) ([20ea533](https://github.com/moneymikeMD/night-watchman/commit/20ea53361a4309ce0f02e74791e4116956dee08f))

## [0.9.1](https://github.com/moneymikeMD/night-watchman/compare/v0.9.0...v0.9.1) (2026-09-19)


### Bug Fixes

* **ci:** trim land-branch.sh's file header back under the 80-line cap ([857ec4d](https://github.com/moneymikeMD/night-watchman/commit/857ec4d2ef7bcda8e8a989debaceb2d12aada5f4))
* **guard-fs-writes:** match the binary a command word resolves to ([5c04dcc](https://github.com/moneymikeMD/night-watchman/commit/5c04dcc57038b49dbb43bcc6bf0c29243b7b3e3f))
* **guard-fs-writes:** resolve command heads only in command position ([d85ac5d](https://github.com/moneymikeMD/night-watchman/commit/d85ac5ddbf130ed5d44f1ca09eb57a0fb70f6a57))

## [0.9.0](https://github.com/moneymikeMD/night-watchman/compare/v0.8.0...v0.9.0) (2026-09-19)


### Features

* **ci:** consume comment-lint from ai-toolkit instead of shipping it ([dd1062b](https://github.com/moneymikeMD/night-watchman/commit/dd1062b401754e295a8d4ea230c67be5bdd926e7))

## [0.8.0](https://github.com/moneymikeMD/night-watchman/compare/v0.7.2...v0.8.0) (2026-09-18)


### Features

* **dispatch:** start verb hands the agent a complete brief ([daeaa9a](https://github.com/moneymikeMD/night-watchman/commit/daeaa9ad4407557e801f2c2cc1ed72c786ec5221))


### Bug Fixes

* **dispatch:** brief refusal before any tracker/herdr call; test and document [dispatch.brief] ([3fb6ecf](https://github.com/moneymikeMD/night-watchman/commit/3fb6ecf2d673d2f617e214fb4d2ed53331258b56))
* **guard-fs-writes:** make per-segment scan state re-entrant ([573acb3](https://github.com/moneymikeMD/night-watchman/commit/573acb335c88ee4c61a85cc52e56491f73160c5c))
* **guard-fs-writes:** silence frame-push stderr noise, frame arrays and _sct_seg, propagate body status ([a49b068](https://github.com/moneymikeMD/night-watchman/commit/a49b0689bac4944f262c545b8a2c939456704f17))
* **known-issues:** resolve committed merge-conflict markers in _manifest.json ([0bd58ba](https://github.com/moneymikeMD/night-watchman/commit/0bd58ba8cd94f9ba4b9522d0c945c734690ae33e))

## [0.7.2] - 2026-09-15
- docs site: in-page links were root-absolute (`/guides/...`) and 404ed under the GitHub Pages base path `/night-watchman/`; all 20 content links are now relative, verified by a build-time scan of every internal href
- no logic changes in the core product

## [0.7.1] - 2026-09-15
- docs site deploys to GitHub Pages from docs/preview/website: one workflow builds with bun, configure-pages supplies --site/--base, deploy-pages publishes; the sample astro.yml is gone
- README: install from the GitHub marketplace first (`claude plugin marketplace add moneymikeMD/night-watchman`), local checkout second; links the published documentation
- no logic changes in the core product

## [0.7.0] - 2026-09-15
- first public release: history squashed to a single commit; private session logs, ticket ids and site identifiers removed from the tree; fixtures use placeholder hosts and ids
- land-branch.sh: LAND_BRANCH_COAUTHOR / LAND_BRANCH_SESSION are optional; unset means no trailer, commits default to the owner alone
- guard-fs-writes.sh: the argv of ssh, scp, rsync and mosh is opaque remote payload when one of them is the segment's command word (after NAME=value, env, command prefixes); a trailing local redirect is still checked; opacity state is saved and restored across nested scans
- dispatch start: detects Claude Code's folder-trust dialog in a fresh Herdr worktree, answers it, and continues to the brief hand-off instead of failing agent_not_ready
- known-issues: quoted ssh payloads containing an unescaped operator are still mis-split by the segment splitter; words after bash -c / eval in the same segment bypass the guard (fix pending); the tilde-escape selftest case fails on Linux only

## [0.6.0] - 2026-09-14
- decision: Jira enforces the field gates (verify, touches) and the status-order gate; scripts keep blocked_by, touches collisions and mixed/human_steps
  cost: UNVERIFIED
- jira-workflow-apply.sh --rules: additive validator merge from a committed rules spec, placeholders resolved by name, rehearsed on a scratch project; rules applied live
  cost: UNVERIFIED
- scripts drive the ticket lifecycle: dispatch start moves to In Progress, land-branch to Awaiting Deployment before the merge and Completed after the push (new no-default status flags); pipefail SIGPIPE fixes
  cost: UNVERIFIED
- publish/atlassian converter escapes double quotes in link URLs
  cost: UNVERIFIED

## [0.5.0] - 2026-09-14
- parity-sweep.sh --source-root bottom-up enumeration of the source project (scripts, agents/skills, hook commands), allowlist, docs/decisions.md directive
  cost: UNVERIFIED
- publish provider kind (publish-brief, post-headline) with the first implementation providers/publish/atlassian, wired into session-start wrap-up
  cost: UNVERIFIED
- first bottom-up sweep finds classified; parity-sweep.sh dangling bucket for references to files absent in the source
  cost: UNVERIFIED

## [0.4.1] - 2026-09-14
- agents/spec-reviewer: ticket-vs-diff review, no Agent tool
  cost: UNVERIFIED
- to-issues: decision tickets and Not yet specified fog
  cost: UNVERIFIED
- scripts/lib/wizard.sh guided human-step library, secrets via provider sink (MIT)
  cost: UNVERIFIED

## [0.4.0] - 2026-09-14
- capability-ladder rung 1: build the lever from a proven run; a script beats fan-out
  cost: UNVERIFIED
- pstack-port cleanup: reflect section points at agents/reflector.md; evidence.md Migration OK pointer
  cost: UNVERIFIED
- session-start: resolve land-branch conflicts by ticket intent
  cost: UNVERIFIED
- skills/grill: round-based owner interview that hands off to to-issues
  cost: UNVERIFIED
- to-issues: prefactor, expand-contract slicing, red verify at base commit
  cost: UNVERIFIED
- issues.py scope: flag branch paths not declared in touches/appends
  cost: ~24k tokens, 1 turn
- diagnose-and-pr: diagnosis-loop reference, red-command gate, HITL loop template (MIT)
  cost: UNVERIFIED
- handoff-docs: suggested next, redaction rule, phase-boundary choice
  cost: UNVERIFIED
- decisions log: three-gate test before appending a why
  cost: UNVERIFIED
- writing-style: skill and agent prose rules; reflector no-op filter
  cost: UNVERIFIED

## [0.3.1] - 2026-09-14
- providers/tracker/jira: Jira issue key never redacted (verified already satisfied, no code change)
  cost: ~$0.02, 1 turn
- script-analytics.py: --since/--until windows every per-script column; window owner_wait and tickets-per-owner-hour footer
  cost: UNVERIFIED

## [0.3.0] - 2026-09-14
- session-start: brief contract, retry-by-failure-mode, child accounting, inspect-the-diff, exit predicate
  cost: UNVERIFIED
- skills/wave-trail: per-wave decision trail audited against the transcript
  cost: UNVERIFIED
- script-reviewer and diagnose-and-pr: safety-fact proof ladder, attack-the-premise, stale-state-first
  cost: UNVERIFIED
- capability-ladder: rule-enforcement ladder and reflect step
  cost: UNVERIFIED
- ethos observable-fact rule, to-issues red-team step, handoff-docs mid-wave pause
  cost: UNVERIFIED
- diagnose-and-pr: pre-diagnosis gates, PR body sections, flake classification
  cost: UNVERIFIED
- scripts/decision-log.sh + selftest
  cost: UNVERIFIED
- session-start wrap-up: wave-trail audit, status tags, reflector hand-off; retry table moved to references/
  cost: UNVERIFIED
- agents/reflector.md: correction-to-skill-edit proposals with owner approval
  cost: UNVERIFIED
- script-reviewer: hollow-selftest check, crash-point probe, output rules
  cost: UNVERIFIED
- templates/CLAUDE.md: delegation and claim rules
  cost: UNVERIFIED
- tickets-protocol: confidence tiers on the routing table
  cost: UNVERIFIED
- cost-reviewer: one adopted change per wave, variance, revert-not-tweak
  cost: UNVERIFIED
- docs/testing-philosophy.md: blinded evals for skill and agent changes
  cost: UNVERIFIED
- docs/writing-style.md plus librarian dedupe and compensation rules
  cost: UNVERIFIED

## [0.2.0] - 2026-09-14
- trackers/jira: jira-workflow-apply.sh — add plugin stage statuses to a project's default workflow
- T1 — issues.py: map Jira `Done` to completed and exclude it in the JQL
- T2 — providers/tracker/jira: ship jira-api.sh + jira-common.sh as the default tracker provider
- T3 — providers/tracker/jira/jira-space-create.sh: one-run Space bootstrap (project + six statuses + six custom fields)
- T4 — providers/secrets: op and env implementations
- T5 — providers/ contract: layout, verb sets, .night-watchman/config.toml reader
- T6 — Reshuffle: move trackers/jira and optional/herdr into providers/
- T8 — Evals for script-author and script-reviewer seeded from real history
- T9 — Evals for librarian, researcher, diagnose-and-pr
- T10 — Port read-shunt and bash-result-shunt PreToolUse hooks
- T11 — Port shell-scripting conventions skill
- T12 — providers/memory/memorygraph: recall.sh single-noun fan-out + store/recall verbs
- T13 — Port Jira import, backfill, verify-keys trio
- T14 — Port commit-staged-worktrees.sh into the herdr dispatch provider
- T15 — Port cost-reviewer agent + generic cost ledger
- T16 — Decisions / known-issues / scripts-claims conventions as templates
- T17 — docs/ethos.md seed for this repo (capped, generic)
- T18 — README rewrite to herdr's six-section shape
- T19 — Docs site scaffold + publisher (human)
- T20 — Docs pages: move content out of README/SKILL.md/script headers; generated reference
- T21 — Release process: version bump, CHANGELOG from outcomes, tags
- T24 — dispatch/herdr provider: implement watch and stop verbs from a recorded herdr spike
- T25 — Pre-squash leftovers: generalize the adopter key in evals/README.md and its docs mirror; clean the generic "homelab" noun
- T26 — Parity sweep of the source project (2026-09-13): fold new generic scripts, agents, skills, hooks into this repo
- T27 — scripts/parity-sweep.sh: recurring drift check against the source project, wired into session-start
- P1 — cost ledger: port the --repo/--project-slug session filter into claude-cost.py
- P2 — memorygraph recall.sh: port multi-noun rank-fusion recall
- P3 — port script-events-hook.sh (SubagentStop) and script-analytics.py
- P4 — bash-result-shunt.sh: fold in the three detector fixes from the source project
- P6 — herdr-ticket-start.sh: tracker-provider ticket resolution, early return, model pin
- P7 — jira-api.sh: numeric issue id support and error_body redaction fixes
- P8 — land-branch.sh: accept a ticket the worker already moved to awaiting-deployment; default tracker
- P9 — jira-agile-api.sh: sprint-update and sprint-delete verbs
- P10 — port the script-author-lite agent
- P11 — port herdr-agent-pane.sh into the dispatch provider
- P12 — land-branch.sh: land in a ../<repo>-land integration worktree with lock and dirty gate
  cost: UNVERIFIED
- P13 — jira-import.sh: read the create response correctly when the write path emits a stderr preamble
- T28 — session-start: preflight the configured dispatch provider and make provider dispatch the rule, not an option
- T29 — SessionEnd cost hook: append the session's cost and turns to the ledger and emit the outcome cost line automatically
- P14 — script-analytics.py: invoke events, report --usage keep/retire?/flag, owner_wait, live-run fixes
  cost: UNVERIFIED
- P15 — script-analytics.py: per-ticket cost table and tracker status-duration events
  cost: UNVERIFIED
- P16 — scripts/script-retire.sh; cost-reviewer lists retire? candidates, librarian retires at wrap-up
  cost: UNVERIFIED
- P17 — script-author lint cap of two, script-reviewer default scope narrowed
  cost: UNVERIFIED
- P18 — session-start records accepted events before cost-reviewer; claude-cost.py writes ledger.jsonl
  cost: UNVERIFIED
