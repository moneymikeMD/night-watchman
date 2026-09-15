# fixtures/ — recorded herdr output

Every file here is a real, read-only response captured from a live herdr
0.8.2 binary — none are hand-authored guesses. Per this project's fixture
rule ("fixtures are recorded, never authored") and
`docs/testing-philosophy.md`'s "fixture provenance" discipline,
`provider-selftest.sh`'s stub canned responses are these files' contents
verbatim, not retyped.

| File | Captured with | Notes |
| --- | --- | --- |
| `agent-get.json` | `herdr agent get <branch>` | one running agent, workspace_id `w2T` |
| `agent-get-help.txt` | `herdr agent get --help` | |
| `agent-wait.json` | `herdr agent wait <branch> ...` | re-verified against a live agent: the recorded copy carried a trailing `wait exit 0` line that real `agent wait` never prints — that was capture-script noise, stripped here |
| `agent-wait-help.txt` | `herdr agent wait --help` | |
| `agent-list.json` | `herdr agent list` | several unrelated agents, useful as "don't match the wrong one" noise |
| `agent-list-help.txt` | `herdr agent list --help` | |
| `workspace-get.json` | `herdr workspace get w2T` | |
| `workspace-get-help.txt` | `herdr workspace get --help` | |
| `workspace-close-help.txt` | `herdr workspace close --help` | |
| `workspace-close.json` | `herdr workspace close <id>` | captured against a throwaway `herdr worktree create` target made and torn down for exactly this purpose — never a real ticket's workspace |
| `pane-close-help.txt` | `herdr pane close --help` | recorded for reference only — `stop` does not call `pane close`; no live `pane close` *response* has been captured, so a paneless agent (no workspace_id) is a stop2 refusal, not a fallback. Wiring one up is a follow-up once that response is recorded, not before. |
| `worktree-create.json` | `herdr worktree create --cwd <repo> --branch fixture-probe --label ... --no-focus` | recorded 2026-09-14 on a throwaway branch (removed after); `.result.root_pane.pane_id` is the field `herdr-ticket-start.sh` reads; home path de-identified |
| `worktree-list.json` | `herdr worktree list --cwd <repo>` | recorded 2026-09-14: the main checkout, the probe worktree (open workspace), and the integration worktree with `branch: null`; `herdr-ticket-start-selftest.sh` rewrites only the `branch` values for its noise cases, the shape is verbatim |

`herdr agent stop` does not exist (`herdr agent --help` lists no `stop`
subcommand) — `stop` closes the agent's owning workspace instead (see
`provider.sh`'s own header). An agent with no `workspace_id` is refused
(exit 2) rather than guessed at with an unrecorded `pane close` call.
