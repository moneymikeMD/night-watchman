---
name: to-issues-mine
description: Mine a settled planning, grilling, or design conversation into a decision-list JSON conforming to work-order's decision-list/FORMAT.md — the mining half of to-issues, split so that ticket authoring lives in work-order's emit-tickets skill instead of here. Use whenever a grilling session ends and the decisions need to leave the conversation as data, before anything decides how they become ticket files.
---

# to-issues-mine

`to-issues` used to read a settled conversation and write ticket files in one
pass. This skill is the first half only: read the conversation, decide what
counts as a decision, and write a decision list. Turning that list into
ticket files is work-order's `emit-tickets` skill, run separately, against a
format both sides can test independently — see
`~/code/home_workspace/work-order/decision-list/FORMAT.md`.

The bar is the same one `to-issues` always used: an agent with no memory of
this conversation must be able to finish the resulting ticket without asking
a question. That bar is set by the *content* of each decision, which is this
skill's job — the mechanics of turning content into a valid ticket file are
`emit-tickets`'s job, not this one's.

## The judgement that stays here

**The three failure modes.** A decision that needs the conversation to make
sense (restate it, don't reference it). A decision whose `touches` will
collide with another (declare paths generously, checked before anyone
starts). A decision nobody can prove is done (`verify` is a command with a
deterministic result, not "confirm it works").

**Decision tickets vs. build tickets.** If the destination is clear but the
route is not, don't force a vague build decision — mine a decision *about
the open question itself*: its `title` is the question, `tags` includes
`decision`, and `verify` names where the answer must land (typically a grep
against the target repo's decision log). `executor` follows what resolving
it needs: `human` for an owner conversation, `agent` for a fact research can
surface. No build decision's `blocked_by` should list a decision id that is
itself still a build decision if the destination isn't actually settled —
that's the tell that it should have been mined as a decision ticket instead.

**Slicing for independence.** Same rule `to-issues` always used: split on
whether an agent could finish it alone in its own worktree, not on size. A
piece that needs another's output first is two decisions and a `blocked_by`,
not one.

**The red-team pass.** Before finishing the list, assume a ticket made from
it shipped and failed a month from now — what's the likely cause, and which
decision already defends against it? A cause with no defending decision is a
gap; mine one more entry for it.

## Process

1. **Read the settled conversation.** Note every decision, what was
   rejected and why, what depends on what, and anything verified as fact
   (mark anything merely assumed as assumed in the decision's own text — a
   confident guess mined as fact gets acted on).

2. **Write a settled-session capture** in the grammar below — one file, one
   `## Decision:` section per decision. This is the artifact the judgement
   above produces; everything past this point is mechanical.

3. **Run `mine.py`** to turn the capture into decision-list JSON:

   ```
   python3 mine.py --fixture SESSION.md --out decisions.json
   ```

4. **Validate against work-order's schema**, not just this skill's own
   parsing:

   ```
   python3 ~/code/home_workspace/work-order/decision-list/validate.py decisions.json
   ```

   A schema error names the field and the decision index. Fix the capture
   and re-run step 3 — never hand-edit the generated JSON, or the capture and
   the list drift apart.

5. **Hand the validated list to a consumer.** `emit-tickets` (in work-order)
   turns it into ticket files; something else might turn it into a different
   shape entirely. This skill's job ends at a valid decision list.

## The settled-session capture grammar

`fixtures/settled-session.md` is a complete worked example — mine it (no pun
intended) for the exact shape before writing one by hand. The rules `mine.py`
depends on:

- An optional `# Settled session: <source>` line at the top. Becomes the
  decision list's `source` field.
- One `## Decision: <id> — <title>` heading per decision, id and title
  separated by an em dash (`—`).
- Prose fields (`Problem`, `Solution`, `Out of scope`) are a `**Label**`
  header with no colon, followed by one or more lines of text ending at the
  next marker. Paragraph breaks (blank lines) are preserved.
- `Verify fails today` is the same shape but is collapsed to a single line —
  `emit-tickets` renders it as one trailing comment line in the ticket's
  `verify:` block, so a line break here would corrupt that YAML block scalar.
- Short fields (`Executor`, `Tags`, `Blocked by`, `Touches`, `Appends`,
  `Human steps`, `Created`) are `**Label:** value` on one line. List fields
  are comma-separated, or the literal word `none` for an empty list. Each
  belongs on one physical line, however long — `mine.py` does not merge
  wrapped continuation lines for these.
- `Rationale` is a `**Rationale**` header followed by a bullet list:
  `- Choice: <text>` then an indented `Rejected:` line, either inline
  (`Rejected: <one reason>` or `Rejected: none`) or as its own indented
  bullet list. As with the short fields above, keep each choice and each
  rejected reason on one physical line.
- `Verify` is a `**Verify**` header followed by a fenced code block; its
  contents (unindented) become the `verify` field.

A decision missing a field `decision-list/validate.py` requires produces a
JSON document that fails validation with that field named — that failure is
the intended way to notice; there is no separate schema check inside
`mine.py` itself.

## What this skill does not do

- It does not decide `defer_until` or lifecycle position — a decision list
  describes work not yet started, at the `open` position, unconditionally.
- It does not check `blocked_by` ids against a wider ticket set, or ticket
  file naming, or frontmatter rendering — that is `emit-tickets` and,
  beyond it, the conformance validator's job.
- It does not require a live conversation. `--fixture` reads any
  settled-session capture, live-written or checked in as a test fixture —
  the flag name describes the shape of the input, not where it came from.
