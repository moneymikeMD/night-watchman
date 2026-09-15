---
name: bad-agent
tools: Read
model: sonnet
---

This fixture agent is missing its `description` field on purpose, to
prove gen-reference-docs.sh dies loudly (and does not touch any
committed page) instead of writing a page with a blank description.
