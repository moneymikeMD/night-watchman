# Known issues

**GENERATED — do not hand-edit.** This file is produced by
`known-issue.sh reindex` from the frontmatter of every file in
`docs/known-issues/`. Edit an entry there (or via `known-issue.sh add`,
`resolve`, or `severity`), then run `reindex` — or just run any of those
subcommands, which reindex for you. `known-issue.sh lint` fails if this file
ever drifts from what `reindex` would produce.

| Severity | Finding |
| --- | --- |
| MEDIUM | [dispatch/herdr start: a cold Claude Code boot (plugin marketplace refresh) swallows the brief; herdr reports interactive_ready before the agent can accept input](known-issues/dispatch-herdr-start-a-cold-claude-code-boot-plugin-marketplace-refresh-swallows-the-brief-herdr-reports-interactive-ready-before-the-agent-can-accept-input.md) — first start of a session, not under load; the same start retried is clean because the cache is warm |
| MEDIUM | [dispatch/herdr start: the 60s 'reached working' wait fails when several agents are started back to back; agent left idle with no brief](known-issues/dispatch-herdr-start-the-60s-reached-working-wait-fails-when-several-agents-are-started-back-to-back-agent-left-idle-with-no-brief.md) — seen on 2 of 10 sequential starts in one wave; re-prompting by hand recovered both |
| MEDIUM | [memorygraph link rejects SUPERSEDES and RELATES_TO so a memory cannot be superseded by an edge](known-issues/memorygraph-link-rejects-supersedes-and-relates-to-so-a-memory-cannot-be-superseded-by-an-edge.md) — use CONTRADICTS and name the superseded id in the new memory body |
| MEDIUM | [SubagentStop hook wiring for script-events-hook.sh not yet observed live](known-issues/subagentstop-hook-wiring-for-script-events-hook-sh-not-yet-observed-live.md) — matcher script-author\|script-reviewer has never fired through real Claude Code hook dispatch; docs/script-events.jsonl does not exist |
| LOW | [bash-result-shunt.sh: per-character string accumulation makes strip_heredocs, split_segments and tokenize all O(n^2) on large commands](known-issues/bash-result-shunt-sh-split-segments-tokenize-scale-o-n-2-on-large-non-heredoc-commands.md) — synthetic 25.9 KB command: 94s wall on macOS bash 3.2 |
| LOW | [guard-fs-writes-selftest.sh: test 16 (~/../.. escape) exits 1 not 2](known-issues/guard-fs-writes-selftest-sh-test-16-escape-exits-1-not-2.md) — Linux bash 5 only; macOS bash 3.2 passes; current Linux status UNVERIFIED |
| LOW | [guard-fs-writes.sh at user scope blocks git stash in every repo's main worktree, not just this plugin's](known-issues/guard-fs-writes-sh-at-user-scope-blocks-git-stash-in-every-repo-s-main-worktree-not-just-this-plugin-s.md) |
| LOW | [jira-workflow-apply-selftest 13b: assertion expects the phrase 'project key' but the script says 'PROJECT_KEY'](known-issues/jira-workflow-apply-selftest-13b-assertion-expects-the-phrase-project-key-but-the-script-says-project-key.md) — one assertion; the selftest is quarantined in .github/workflows/ci.yml |
| LOW | [land-branch-selftest.sh needs PyYAML but neither declares nor checks for it](known-issues/land-branch-selftest-sh-needs-pyyaml-but-neither-declares-nor-checks-for-it.md) — passes where PyYAML happens to be installed; CI installs it |
| LOW | [providers/config-selftest.sh: an implementation name differing only in case ('Jira') is accepted](known-issues/providers-config-selftest-sh-an-implementation-name-differing-only-in-case-jira-is-accepted.md) — one assertion; the selftest is quarantined in .github/workflows/ci.yml |

Severity is about blast radius if the thing goes wrong, not effort to fix. Anything resolved is rewritten in place with what was verified, rather than deleted — the history is often the useful part.
