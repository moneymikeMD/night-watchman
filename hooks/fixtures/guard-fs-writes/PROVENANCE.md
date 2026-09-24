# Provenance — hooks/fixtures/guard-fs-writes/

`case4-long-quoted-prompt.recorded.txt` is the exact `.tool_input.command`
text of a real command of the shape `<remote-agent-dispatch-tool>
agent-prompt x "<long double-quoted argument containing single quotes, a
literal '--', and a literal '\$'>" >/dev/null && echo done`. A guard that
does not trim whitespace both before and after same-command variable
substitution blocks it falsely (RC=2, "(resolves to: /dev/null )" with a
trailing space); `target_is_outside` trims, and this fixture proves it.

Captured byte-for-byte from the original diagnostic run rather than
retyped by hand, specifically because this exact text is long, has nested
quoting, and is exactly the kind of string a hand-transcription would
subtly corrupt. The tool name, ticket path, and internal CLI invocations
in the original capture have been replaced here with generic placeholders
(`some-tool`, `EXAMPLE-1.md`, `memory-tool`) — the replacement preserves
every structural property the assertion in `guard-fs-writes-selftest.sh`
depends on (a double-quoted argument containing single-quoted spans, a
literal `--`, a literal `\$`, and a trailing `>/dev/null`), so the
byte-for-byte claim applies to structure and length, not to the literal
tool/ticket names, which were never load-bearing for what this fixture
tests. Nothing secret in it — a placeholder ticket path, placeholder CLI
invocations, and a `perl -e 'alarm ...'` guard, all literal example prose
that is itself the ARGUMENT to a wrapper command, never executed.
