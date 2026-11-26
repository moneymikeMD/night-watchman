---
name: wrap-up
description: Wrap up a session — ask what it left behind and run only the session-end mechanisms that apply (reflector, librarian or session-harvest, handoff-docs, memory). Use when the user says "wrap up", "we are done for today", "end the session", or before closing a session that did real work.
---

# Wrap-up

Five mechanisms run at the end of a session, and each answers a different question. This skill asks the questions and runs the mechanism only where the answer is yes. A session that
answers no to all of them ends with the one-line summary in step 4 and nothing else.

## 0. Did this session run a wave?

If it dispatched or landed a wave, load `references/wave.md` now and do its "Before the questions" steps. Its "After the handoff" steps come after step 3.

## 1. Did the owner correct the agent, or was a claim retracted?

Yes: hand the transcript path to the `reflector` agent (`agents/reflector.md`) and put its Accepted / Rejected / Backlog tables in front of the owner. Done when the tables are shown, or the reflector
reports nothing to route.

## 2. Did the session learn something durable?

A root cause, a decision, a gotcha, a ticket to file or move.

- The repo runs the night-watchman model (`.night-watchman/config.toml` exists): the `librarian` agent with `tickets-protocol` records it in `docs/` and the tracker.
- It does not: `session-harvest` from moneymike-skills proposes where each piece belongs.

Done when every learned item has a durable home or the owner declined it.

## 3. Is unfinished work moving to another session, machine or person?

Yes: write the note with `handoff-docs`. Done when the note is committed and every remaining item in it points at a ticket.

## 4. Memory summary

Store what step 2 did not already cover through the `memory` provider (`providers/lib/provider.sh memory store`), if one is configured, then tell the owner in one line per mechanism what ran and what
it left.

If the session lost time to tooling or navigation (a tool misbehaving, a file that took several searches to find), say in one line that `retro` from moneymike-skills would look at it, and leave running
it to the owner.
