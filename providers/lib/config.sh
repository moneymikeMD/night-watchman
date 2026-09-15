#!/bin/bash
#
# config.sh — a deliberately small TOML *subset* reader for
# `.night-watchman/config.toml`, plus the discovery rule that finds that
# file. Sourced by providers/lib/provider.sh; not a CLI of its own.
#
# Why a subset and not a real TOML parser: the core is dependency-free by
# rule, so `tomlq`/`python3 -c 'import tomllib'` are both off the table
# (the latter is 3.11+, and the plugin supports whatever python3 an
# adopter's machine already has). A whole TOML implementation in bash 3.2
# would be a large, badly-tested surface for a file that only ever holds
# provider selections and a handful of per-provider settings. So the
# supported grammar is fixed and small, and everything outside it is a
# LOUD ERROR rather than a silent misparse:
#
#   SUPPORTED
#     # comment lines, and trailing comments after a value
#     bare_key = "basic string"        \" \\ \n \t \r escapes
#     bare_key = 'literal string'      no escapes
#     bare_key = 12  /  -3             integers
#     bare_key = true / false          booleans
#     [table]                          one level or dotted, e.g. [tracker.jira]
#
#   REJECTED, each with its own message naming what it saw
#     [[array.of.tables]]              arrays of tables
#     key = [1, 2]                     arrays
#     key = { a = 1 }                  inline tables
#     key = """..."""                  multi-line strings
#     key = 1.5 / 1979-05-27           floats, dates, times
#     "quoted key" = 1                 quoted keys
#     a duplicate bare key, or a duplicate [table] header
#
# The rejections are the point. A reader that quietly skipped a line it
# did not understand would let `tracker = "jira"` fall back to a built-in
# default because of a typo three lines above it, and the operator would
# get a working run against the wrong provider with nothing printed. Every
# unparsable line is an error naming the file, line number, and reason.
#
# Values are carried between the awk parser and the shell as ONE LINE PER
# KEY, so a value containing a literal newline (from a `\n` escape) has to
# be re-encoded on the way out and decoded on the way in — see
# `_nw_config_encode` / `nw_config_decode`. Skipping that round-trip is
# how a line-based config reader corrupts every key after the first
# multi-line value.
#
# bash 3.2 compatible: no associative arrays (the parsed config is a
# newline-delimited "key<TAB>value" blob, looked up by scanning), no
# `${var^^}`, no `readarray`.
#
# Usage: source this file, then call
#   nw_config_file            — path of the config in effect, or empty
#   nw_config_parse [FILE]    — encoded key<TAB>value lines on stdout
#   nw_config_get KEY [DEF]   — decoded value; 1 if absent and no DEF
#   nw_config_keys            — every dotted key, one per line

# Discovery order, highest priority first:
#   1. $NW_CONFIG            — an explicit path (used by the selftest, and
#                              by anyone running against another checkout)
#   2. the nearest `.night-watchman/config.toml` walking UP from
#      ${NW_ROOT:-$PWD} to /, so a script invoked from a subdirectory of
#      the adopting repo finds the repo's committed config
#   3. nothing — callers fall back to their own built-in defaults
#
# Note there is deliberately no ~/.night-watchman/config.toml step. Provider
# selection is a property of the repo being worked on and is reviewed in
# that repo's history; a per-operator home-directory config would mean two
# people running the same script against the same repo silently hitting
# different providers.
nw_config_file() {
    if [ -n "${NW_CONFIG:-}" ]; then
        printf '%s\n' "$NW_CONFIG"
        return 0
    fi
    local dir
    dir="${NW_ROOT:-$PWD}"
    # `cd -P` so a symlinked worktree walks its physical parents.
    dir=$(cd "$dir" 2>/dev/null && pwd -P) || return 0
    while :; do
        if [ -f "$dir/.night-watchman/config.toml" ]; then
            printf '%s\n' "$dir/.night-watchman/config.toml"
            return 0
        fi
        [ "$dir" = "/" ] && return 0
        dir=$(dirname "$dir")
    done
}

# _nw_config_awk — the parser itself. Reads a config on stdin, writes
# `key<TAB>encoded-value` lines on stdout, and every complaint on stderr.
# Exits 1 if it complained about anything, having still printed the keys
# it did understand (so a caller that only wants to report errors gets the
# full list in one run rather than one per invocation).
_nw_config_awk() {
    awk -v src="$1" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function err(msg) { printf "%s:%d: %s\n", src, NR, msg > "/dev/stderr"; bad = 1 }
        # encode — make a value safe to carry on one line.
        function encode(s) {
            gsub(/\\/, "\\\\", s)
            gsub(/\n/, "\\n", s)
            gsub(/\t/, "\\t", s)
            gsub(/\r/, "\\r", s)
            return s
        }
        # rest_ok — after a value, only blanks and a comment may remain.
        function rest_ok(s) { s = trim(s); return (s == "" || substr(s, 1, 1) == "#") }

        BEGIN { table = ""; bad = 0 }

        {
            line = $0
            sub(/\r$/, "", line)
            s = trim(line)

            if (s == "" || substr(s, 1, 1) == "#") next

            if (substr(s, 1, 2) == "[[") {
                err("arrays of tables ([[...]]) are not supported by this reader")
                next
            }

            if (substr(s, 1, 1) == "[") {
                if (s !~ /^\[[A-Za-z0-9_.-]+\][ \t]*(#.*)?$/) {
                    err("malformed table header: " s)
                    next
                }
                t = s
                sub(/^\[/, "", t)
                sub(/\].*$/, "", t)
                if (t in seen_table) { err("duplicate table header: [" t "]"); next }
                seen_table[t] = 1
                table = t
                next
            }

            if (substr(s, 1, 1) == "\"" || substr(s, 1, 1) == "'"'"'") {
                err("quoted keys are not supported by this reader: " s)
                next
            }

            eq = index(s, "=")
            if (eq == 0) { err("not a comment, table header, or key = value: " s); next }

            key = trim(substr(s, 1, eq - 1))
            raw = trim(substr(s, eq + 1))

            if (key !~ /^[A-Za-z0-9_-]+$/) { err("malformed key: " key); next }
            if (raw == "") { err("missing value for key: " key); next }

            # ---- value
            c = substr(raw, 1, 1)
            if (substr(raw, 1, 3) == "\"\"\"" || substr(raw, 1, 3) == "'"'''"'") {
                err("multi-line strings are not supported by this reader (key " key ")")
                next
            }
            if (c == "[") { err("arrays are not supported by this reader (key " key ")"); next }
            if (c == "{") { err("inline tables are not supported by this reader (key " key ")"); next }

            if (c == "\"") {
                val = ""
                i = 2
                closed = 0
                broke = 0
                n = length(raw)
                while (i <= n) {
                    ch = substr(raw, i, 1)
                    if (ch == "\\") {
                        e = substr(raw, i + 1, 1)
                        if      (e == "n")  { val = val "\n" }
                        else if (e == "t")  { val = val "\t" }
                        else if (e == "r")  { val = val "\r" }
                        else if (e == "\"") { val = val "\"" }
                        else if (e == "\\") { val = val "\\" }
                        else {
                            err("unsupported escape \\" e " in value for key " key)
                            broke = 1
                            break
                        }
                        i += 2
                        continue
                    }
                    if (ch == "\"") { closed = i; break }
                    val = val ch
                    i++
                }
                if (broke) next
                if (!closed) { err("unterminated string for key: " key); next }
                if (!rest_ok(substr(raw, closed + 1))) {
                    err("trailing junk after value for key: " key)
                    next
                }
            } else if (c == "'"'"'") {
                closed = index(substr(raw, 2), "'"'"'")
                if (closed == 0) { err("unterminated literal string for key: " key); next }
                val = substr(raw, 2, closed - 1)
                if (!rest_ok(substr(raw, closed + 2))) {
                    err("trailing junk after value for key: " key)
                    next
                }
            } else {
                tok = raw
                sub(/[ \t]+#.*$/, "", tok)
                tok = trim(tok)
                if (tok ~ /[ \t]/) { err("trailing junk after value for key: " key); next }
                if (tok == "true" || tok == "false") {
                    val = tok
                } else if (tok ~ /^[+-]?[0-9]+$/) {
                    val = tok
                    sub(/^\+/, "", val)
                } else {
                    err("only strings, integers, and booleans are supported (key " key " = " tok ")")
                    next
                }
            }

            full = (table == "" ? key : table "." key)
            if (full in seen_key) { err("duplicate key: " full); next }
            seen_key[full] = 1
            printf "%s\t%s\n", full, encode(val)
        }

        END { if (bad) exit 1 }
    '
}

# nw_config_parse [FILE] — encoded `key<TAB>value` lines for FILE (default:
# whatever nw_config_file resolves to). A missing/empty config is not an
# error: it prints nothing and succeeds, so a repo with no config falls
# through to the caller's built-in defaults. An UNREADABLE named file IS an
# error — "you pointed me at a file I cannot read" is never the same
# situation as "there is no config here".
#
# Not cached, deliberately. An earlier revision memoised the parse in two
# globals; they were dead weight, because every caller in this file reads
# nw_config_parse through a command substitution and a subshell's
# assignment does not survive back to the parent. A cache that only works
# on the one call path nothing uses is worse than none: it reads as a
# guarantee about repeat cost that it does not provide.
nw_config_parse() {
    local file="${1:-}"
    if [ -z "$file" ]; then file=$(nw_config_file); fi
    if [ -z "$file" ]; then
        printf '%s' ""
        return 0
    fi
    if [ ! -r "$file" ]; then
        echo "Error: config file is not readable: $file" >&2
        return 1
    fi
    local out
    # shellcheck disable=SC2094  # the file is only ever read: the name is
    # passed in for error messages, the bytes come in on stdin.
    out=$(_nw_config_awk "$file" < "$file") || return 1
    printf '%s' "$out"
}

# nw_config_decode — undo _nw_config_awk's encode(), on stdin.
nw_config_decode() {
    awk '{
        out = ""
        n = length($0)
        i = 1
        while (i <= n) {
            ch = substr($0, i, 1)
            if (ch == "\\" && i < n) {
                e = substr($0, i + 1, 1)
                if      (e == "n")  { out = out "\n"; i += 2; continue }
                else if (e == "t")  { out = out "\t"; i += 2; continue }
                else if (e == "r")  { out = out "\r"; i += 2; continue }
                else if (e == "\\") { out = out "\\"; i += 2; continue }
            }
            out = out ch
            i++
        }
        printf "%s", out
    }'
}

# nw_config_get KEY [DEFAULT] — the decoded value for a dotted key. Returns
# 1 (printing nothing) when the key is absent and no DEFAULT was given, so
# `if v=$(nw_config_get x); then` distinguishes absent from empty-string.
nw_config_get() {
    local key="$1" parsed line
    parsed=$(nw_config_parse) || return 2
    line=$(printf '%s\n' "$parsed" | awk -F'\t' -v k="$key" '$1 == k { print $2; found = 1; exit } END { if (!found) exit 3 }') || {
        if [ "$#" -ge 2 ]; then printf '%s' "$2"; return 0; fi
        return 1
    }
    printf '%s' "$line" | nw_config_decode
}

# nw_config_keys — every dotted key in the config in effect, one per line.
nw_config_keys() {
    local parsed
    parsed=$(nw_config_parse) || return 2
    [ -n "$parsed" ] || return 0
    printf '%s\n' "$parsed" | cut -f1
}
