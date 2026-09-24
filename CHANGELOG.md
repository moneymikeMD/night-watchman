# Changelog

All notable changes to this project are documented here.

## [1.7.2](https://github.com/moneymikeMD/night-watchman/compare/v1.7.1...v1.7.2) (2026-09-24)


### Bug Fixes

* land-branch.sh keeps one definition of clean-except-the-closing-state, matching land-core's (NWM-177) ([#90](https://github.com/moneymikeMD/night-watchman/issues/90)) ([d440e5d](https://github.com/moneymikeMD/night-watchman/commit/d440e5d70e13065450d2f8537769547a8115e707))
* script-events-hook.sh drops the project-dir extractor step and greps a sentinel before invoking (NWM-160) ([#86](https://github.com/moneymikeMD/night-watchman/issues/86)) ([d398a14](https://github.com/moneymikeMD/night-watchman/commit/d398a14d555051ef824e52498dc86147527493ff))
* script-events-hook.sh keeps first-valid-hit semantics and never builds a root-anchored candidate (NWM-178) ([#89](https://github.com/moneymikeMD/night-watchman/issues/89)) ([420ac98](https://github.com/moneymikeMD/night-watchman/commit/420ac98cab96d68c74206468984ffa7da3078a21))
* split the atlassian publish selftest so parity-map rows can converge (NWM-161) ([#85](https://github.com/moneymikeMD/night-watchman/issues/85)) ([7fdb43d](https://github.com/moneymikeMD/night-watchman/commit/7fdb43d604e534b35be43e47d749a8ae622ffc1c))

## [1.7.1](https://github.com/moneymikeMD/night-watchman/compare/v1.7.0...v1.7.1) (2026-09-24)


### Bug Fixes

* map homelab's script-analytics pair as not ported (LAB-228) ([#83](https://github.com/moneymikeMD/night-watchman/issues/83)) ([0047e7e](https://github.com/moneymikeMD/night-watchman/commit/0047e7e2b35dea314baf0637212690fd5c1a273f))

## [1.7.0](https://github.com/moneymikeMD/night-watchman/compare/v1.6.0...v1.7.0) (2026-09-24)


### Features

* land-branch.sh wraps ai-toolkit's land-core.sh through its four-point hook contract (NWM-131) ([#80](https://github.com/moneymikeMD/night-watchman/issues/80)) ([52ac4a3](https://github.com/moneymikeMD/night-watchman/commit/52ac4a31256b43b0dc608c9600559aaa12c476dd))
* model-aware cost ledger for orchestrator vs worker spend (NWM-119) ([#79](https://github.com/moneymikeMD/night-watchman/issues/79)) ([511039a](https://github.com/moneymikeMD/night-watchman/commit/511039aa965d48356d1e308d844722bf80767eee))
* night-watchman owns wave computation and preflight (NWM-174) ([#78](https://github.com/moneymikeMD/night-watchman/issues/78)) ([d1581d9](https://github.com/moneymikeMD/night-watchman/commit/d1581d939ba3e3a6f2c7e757ed34ae0fdb05441c))


### Bug Fixes

* herdr mixed-ticket brief no longer claims a stop at Awaiting Deployment (NWM-168) ([#77](https://github.com/moneymikeMD/night-watchman/issues/77)) ([753716a](https://github.com/moneymikeMD/night-watchman/commit/753716af266174b00f4693fb870a9ebf498078ea))

## [1.6.0](https://github.com/moneymikeMD/night-watchman/compare/v1.5.0...v1.6.0) (2026-09-23)


### Features

* dev-install.sh runs the working tree as the installed plugin (NWM-172) ([#74](https://github.com/moneymikeMD/night-watchman/issues/74)) ([797fec9](https://github.com/moneymikeMD/night-watchman/commit/797fec9c9eb8b3578d0ef93eaa3141a5e8248ba9))
* lint kit.sh's cleanup contract instead of remembering it (NWM-173) ([f269a6c](https://github.com/moneymikeMD/night-watchman/commit/f269a6c57eed60ac7a0975afc87ff77f48b5a8b7))


### Bug Fixes

* kit_exec cleans up before exec, which no EXIT trap survives (NWM-171) ([#73](https://github.com/moneymikeMD/night-watchman/issues/73)) ([5fa7244](https://github.com/moneymikeMD/night-watchman/commit/5fa7244e7a115233efd297b1dd653958782eecf5))
* silence two deliberate SC2016 in the NWM-173 selftest ([f8bae06](https://github.com/moneymikeMD/night-watchman/commit/f8bae06e209e05e3057fd1f75aa1c27bc6ac7855))

## [1.5.0](https://github.com/moneymikeMD/night-watchman/compare/v1.4.1...v1.5.0) (2026-09-23)


### Features

* --already-merged runs the lifecycle half for a branch merged elsewhere (NWM-169) ([#70](https://github.com/moneymikeMD/night-watchman/issues/70)) ([c385e83](https://github.com/moneymikeMD/night-watchman/commit/c385e83f9e41710314e6b5358de67c89c2cc02a1))


### Bug Fixes

* --already-merged no longer narrates a merge and a push it did not do (NWM-170) ([#72](https://github.com/moneymikeMD/night-watchman/issues/72)) ([2ecd1cc](https://github.com/moneymikeMD/night-watchman/commit/2ecd1cc15f40e19516c6ccba86cdb44027cd2ee3))

## [1.4.1](https://github.com/moneymikeMD/night-watchman/compare/v1.4.0...v1.4.1) (2026-09-22)


### Bug Fixes

* add --root PATH to decisions.sh (NWM-145) ([#64](https://github.com/moneymikeMD/night-watchman/issues/64)) ([bd56e8d](https://github.com/moneymikeMD/night-watchman/commit/bd56e8d0e88775f640b62cf22c641843161a09bf))
* count selftest failures instead of flagging them (NWM-137) ([#62](https://github.com/moneymikeMD/night-watchman/issues/62)) ([b3ee77e](https://github.com/moneymikeMD/night-watchman/commit/b3ee77eab8763be62d6b3ca156bf0a5b5dfaa4fd))
* cut a worker's worktree from the tracked base branch (NWM-144) ([#65](https://github.com/moneymikeMD/night-watchman/issues/65)) ([9cfaaac](https://github.com/moneymikeMD/night-watchman/commit/9cfaaacd0fff1123e4bb8a04c6a3631f3fa52e3d))
* dispatch executor:mixed tickets from the workflow provider (NWM-146) ([#66](https://github.com/moneymikeMD/night-watchman/issues/66)) ([afa6e5a](https://github.com/moneymikeMD/night-watchman/commit/afa6e5aba6faa56296d6d849ed24dcb42921d356))
* exempt closing-state.md from land-branch.sh's dirty-worktree check (NWM-147) ([#67](https://github.com/moneymikeMD/night-watchman/issues/67)) ([2c12392](https://github.com/moneymikeMD/night-watchman/commit/2c12392ec1d8f6ea0618690984edbe4f8a424a04))
* register kit.sh's tmpfile cleanup outside the $(tmpfile) subshell (NWM-155) ([#63](https://github.com/moneymikeMD/night-watchman/issues/63)) ([ab8702d](https://github.com/moneymikeMD/night-watchman/commit/ab8702df9d5717d76bc304d5dadf589992f724d0))

## [1.4.0](https://github.com/moneymikeMD/night-watchman/compare/v1.3.0...v1.4.0) (2026-09-22)


### Features

* consume script-analytics.py and script-retire.sh from ai-toolkit instead of carrying them (NWM-130) ([a1e52c5](https://github.com/moneymikeMD/night-watchman/commit/a1e52c5f6e0693ca53648fb5ae64301824a478aa))


### Bug Fixes

* count Workflow-tool subagent transcripts, not just Agent-tool ones (NWM-152) ([4de966b](https://github.com/moneymikeMD/night-watchman/commit/4de966b64ce513fc42313492b5a9badba36d83a1))
* fold '_' when deriving a project slug, so --repo works under home_workspace (NWM-165) ([f84cb00](https://github.com/moneymikeMD/night-watchman/commit/f84cb00665c2bf33bb0c8bc1780dbc188d85c63d))
* let script-analytics.py run with no claude-cost sibling present (NWM-156) ([5b3969e](https://github.com/moneymikeMD/night-watchman/commit/5b3969eee7d5b02bc5bc9131dc4b41445fccabb7))
* mark parity-map pairs that will never converge instead of reporting them as drift (NWM-158) ([246b3a5](https://github.com/moneymikeMD/night-watchman/commit/246b3a55e5f213f891c43b00f79e55e34213eae8))
* pass --root to known-issue.sh so cwd cannot pick the target repo (NWM-159) ([1f8ac33](https://github.com/moneymikeMD/night-watchman/commit/1f8ac33289be9ad3bdbf61a49c13bcb691fc2829))

## [1.3.0](https://github.com/moneymikeMD/night-watchman/compare/v1.2.1...v1.3.0) (2026-09-21)


### Features

* take known-issue.sh from ai-toolkit instead of carrying a copy (NWM-128) ([#58](https://github.com/moneymikeMD/night-watchman/issues/58)) ([7acb1ab](https://github.com/moneymikeMD/night-watchman/commit/7acb1ab7097bb05b32ff91ac5079aa0c5bb95c89))


### Bug Fixes

* ignore the dated wave-trail files a wave actually writes (NWM-150) ([#57](https://github.com/moneymikeMD/night-watchman/issues/57)) ([c223e50](https://github.com/moneymikeMD/night-watchman/commit/c223e505d97caa8e7f52145968d4da1f76d3aeef))

## [1.2.1](https://github.com/moneymikeMD/night-watchman/compare/v1.2.0...v1.2.1) (2026-09-21)


### Bug Fixes

* remove the landed branch's worktree with git, not only through herdr ([#53](https://github.com/moneymikeMD/night-watchman/issues/53)) ([e8e3cf5](https://github.com/moneymikeMD/night-watchman/commit/e8e3cf573814bd6ddea309561c57e343b58defd8))

## [1.2.0](https://github.com/moneymikeMD/night-watchman/compare/v1.1.0...v1.2.0) (2026-09-21)


### Features

* cache WebFetch results and reuse them only on a 304 revalidation ([3eaad02](https://github.com/moneymikeMD/night-watchman/commit/3eaad02b9b2ec45c7604c864c7c54a8027ccb1e7))
* consume ai-toolkit skill-routing with prompt fixtures for this repo's skills ([#52](https://github.com/moneymikeMD/night-watchman/issues/52)) ([cd77523](https://github.com/moneymikeMD/night-watchman/commit/cd775232a6ecc202b8d9ada58fd02354d0f6bbfe))
* register memory and release MCP servers in .mcp.json ([68569fb](https://github.com/moneymikeMD/night-watchman/commit/68569fba74f00fd62cd02c184d1c748c5d04d359))
* spec-reviewer runs the repo's discovered required checks before any verdict ([2357068](https://github.com/moneymikeMD/night-watchman/commit/23570687f71f37635c5743a906adf678e5aa9b95))


### Bug Fixes

* **herdr-dispatch:** correct the MIXED TICKET brief text (LAB-211 review) ([426e60c](https://github.com/moneymikeMD/night-watchman/commit/426e60c2ad2094e49a5719bc50b6772010dd1c6a))
* **herdr-dispatch:** dispatch executor:mixed tickets, stop the brief at Awaiting Deployment (LAB-211) ([ae65d30](https://github.com/moneymikeMD/night-watchman/commit/ae65d30292267cca1617b15c4678d9e0a52e3d7b))
* **hooks:** address LAB-187 review round-2 findings ([dd42b96](https://github.com/moneymikeMD/night-watchman/commit/dd42b9627ca3e8dfa246c5b4c12c63942d3c03d5))
* **hooks:** correct the merged mutant-table counts after the NWM-136 rebase ([0b46f39](https://github.com/moneymikeMD/night-watchman/commit/0b46f399bf862b634580968cabf9962138765193))
* **hooks:** strip_heredocs handles multiple heredocs on one line (LAB-187) ([1bdb839](https://github.com/moneymikeMD/night-watchman/commit/1bdb839a014fdfec5fb2875f93ff100f16012251))
* install from the moneymike-plugins marketplace ([ff6b365](https://github.com/moneymikeMD/night-watchman/commit/ff6b365de41bea837e91102aeefaf364191d306d))
* install from the moneymike-plugins marketplace ([#40](https://github.com/moneymikeMD/night-watchman/issues/40)) ([8301992](https://github.com/moneymikeMD/night-watchman/commit/83019926cfa267a38cb0ba3d90003e8f7c8d5956))
* make the Bash output redactor survive a kill and a line continuation ([af06b7f](https://github.com/moneymikeMD/night-watchman/commit/af06b7f3ba40d1e2a438bdc0e7c942d897102305))
* never cache a WebFetch response that is not page content ([08ea321](https://github.com/moneymikeMD/night-watchman/commit/08ea3213c3c563524b1172805140268551ebb3f8))
* redact secret-shaped values in Bash command output (NWM-136) ([f34f0fa](https://github.com/moneymikeMD/night-watchman/commit/f34f0fa1e2bb712f3cbada7680c7be2ca064c644))
* retry the jira closing-state read-back on Jira's read-after-write window ([3e80cea](https://github.com/moneymikeMD/night-watchman/commit/3e80cea62f665b6b62fa1294209978239b89f7c5))

## [1.1.0](https://github.com/moneymikeMD/night-watchman/compare/v1.0.0...v1.1.0) (2026-09-20)


### Features

* **wave-trail:** make the end-of-wave report carry the run record ([#35](https://github.com/moneymikeMD/night-watchman/issues/35)) ([41f23b6](https://github.com/moneymikeMD/night-watchman/commit/41f23b6d46c2b5a683c7372de9e0b674fc6f7ef5))

## [1.0.0](https://github.com/moneymikeMD/night-watchman/compare/v0.11.0...v1.0.0) (2026-09-20)


### ⚠ BREAKING CHANGES

* installing night-watchman now also installs work-order, and the work-order marketplace must be added first.

### Features

* depend on the work-order plugin instead of carrying its copies ([#32](https://github.com/moneymikeMD/night-watchman/issues/32)) ([a9be349](https://github.com/moneymikeMD/night-watchman/commit/a9be3491c9df9cd6914281fd8fb3895321ec2281))

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
