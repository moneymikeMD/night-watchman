# Script retirement

At wave wrap-up, once `cost-reviewer` has reported its "Retirement candidates" list (rows flagged `retire?` by `script-analytics.py report --usage`), retire each one. Both scripts live in
ai-toolkit and are resolved at run time, never by a path in this repo:

```bash
python3 "$(${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh --script-analytics)" report --events docs/script-events.jsonl --usage --format tsv \
  | awk -F'\t' 'NR>1 && $NF=="retire?"'   # confirm the candidate list independently before acting
"$(${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh --script-retire)" --events docs/script-events.jsonl --dry-run   # read the plan first, always
"$(${CLAUDE_PLUGIN_ROOT}/scripts/ai-toolkit-root.sh --script-retire)" --events docs/script-events.jsonl --yes --ticket <KEY>
```

Run `--yes` only for a candidate `cost-reviewer` actually listed, and only after the dry run.

`script-retire.sh --yes` creates branch `retire-<slug>`, deletes the script and its selftest, removes its `docs/scripts.md` row (if the project keeps one), appends a line under
`docs/scripts.md`'s `## Retired` section, commits, and lands via the project's `scripts/land-branch.sh`, one candidate at a time, so a failure on one never blocks the rest. Use the ticket this
wave is wrapping up under (or file a small dedicated retirement ticket if none fits); `--yes` refuses without `--ticket` and on a dirty working tree.

The script does not touch prose references in `agents/`, `skills/`, or other `docs/` files. It lists the files that mention the retired script's basename so you can `Edit` out the stale reference
by hand (a blind text match on a script name is not safe to auto-delete). Do this before landing if the reference is load-bearing (e.g. another agent's brief still names the retired script).

List every retired script (name, one-line why) in the wave note (`docs/handoffs/<date>.md`). Retirement is delete, not move to `docs/retired/` or `scripts/retired/`: an LLM-readable folder of
dead scripts costs tokens on every future read for no benefit the git history doesn't already give. The `## Retired` line plus `git log` is the full record, and reverting a wrong call is one
`git revert`.
