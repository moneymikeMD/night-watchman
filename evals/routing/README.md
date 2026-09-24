# Skill-routing fixtures

Nothing else here tests that a user prompt reaches the right `SKILL.md`.
Routing failures are silent: the wrong skill loads, or none does, and nothing
goes red. `evals/*/case.yaml` covers agents through `claude plugin eval`, which
costs tokens and a live model per case, so it cannot run on every push.

This is the cheap half. The ranker lives in ai-toolkit
(`actions/skill-routing`); it is a stemmed TF-IDF cosine over the
`description` frontmatter of every skill, zero tokens and no model call. The
generic rule is in the action, the judgement about *these* skills is here —
the same split comment-lint uses.

## The rule

**A routing failure means fix the description, never the prompt.** The prompt
is the user, and the user does not get patched. A fixture edited to make the
check green measures nothing; that is how a routing eval passes vacuously.

Reword a prompt only when the prompt itself was unrealistic — nobody would say
it that way — and say so in the PR.

## Running it

```bash
python3 ../ai-toolkit/actions/skill-routing/skill-routing.py \
  night-watchman=skills --fixtures evals/routing/prompts.json \
  --allow evals/routing/allowed-collisions.json
```

The `night-watchman=` label pins the skill ids, so a fixture keeps working
whatever the checkout directory is called. To see the cross-repo picture, pass
several roots:

```bash
python3 .../skill-routing.py \
  homelab=../homelab/.claude/skills night-watchman=skills \
  --similarity-warn 0.30
```

## Files

| | |
| --- | --- |
| `prompts.json` | positives (this prompt must rank its skill first) and negatives (this prompt must be outranked by the skill that owns it) |
| `allowed-collisions.json` | description pairs this repo has decided not to fix |

The third judgement input is the rank-1 floor, and it lives in
`.github/workflows/ci.yml` beside the fixture paths rather than in the action's
defaults, so changing what this repo demands of its own skills is a diff here
and not a diff in ai-toolkit. It is `1.0` with `top-k: "1"`: every positive
prompt must put its own skill first.

## Known misses

CI runs this `report-only: "true"`. Two fixture prompts miss (rank-1 rate
0.846 over 13 positives), and both are descriptions to fix, not prompts to
soften:

- *"Poke holes in this before I commit to it — I want the weak spots found
  now, not after."* → wants `grill`, shares **no** stemmed term with its
  description, so it scores zero everywhere and `to-issues` wins the residue at
  0.161. `grill`'s description has "pressure-test" and "grill me" and nothing a
  user who does not already know the skill's name would say.
- *"Write all of this up as separate pieces of work so I can close the session
  and start fresh tomorrow."* → wants `to-issues`, gets `handoff-docs` at 0.475
  with `to-issues` at rank 2. "write up" plus "session" is handoff-docs
  vocabulary, and the two skills genuinely compete at the end of a session.
  This one is a real routing hazard, not a fixture artefact.

Turn the gate on (`report-only: "false"`) once both descriptions are fixed and
the rank-1 rate is back at the 1.0 floor.
