# Fixture provenance — session-cost

`projects/-Users-fixture-repoC/sess-c.jsonl` is hand-authored in the same
shape as `scripts/fixtures/claude-cost-scan/`'s recorded fixtures (see that
directory's own provenance) — two assistant turns, `claude-sonnet-5`,
150+250 = 300 tokens total, no dedupe or subagent cases since
`claude-cost-scan.py` already covers those; this fixture only needs to give
`session-cost.sh` something real to scan.

`stdin.json` is the SessionEnd hook payload shape (`session_id`, `cwd`,
`transcript_path`) with `cwd` pointed at a directory that does not exist on
disk — the selftest passes `--projects-dir` itself rather than relying on
`session-cost.sh`'s `--repo`/slug derivation, so `cwd` only has to match
the fixture transcript's project-slug directory name.
