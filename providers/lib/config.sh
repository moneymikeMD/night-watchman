#!/bin/bash
#
# config.sh — a deliberately small TOML *subset* reader for
# `.night-watchman/config.toml`, plus the discovery rule that finds that
# file. Sourced by providers/lib/provider.sh; not a CLI of its own.
#
#   SUPPORTED
#     # comment lines, and trailing comments after a value
#     bare_key = "basic string"        \" \\ \n \t \r escapes
#     bare_key = 'literal string'      no escapes
#     bare_key = 12  /  -3             integers
#     bare_key = true / false          booleans
#     [table]                          one level or dotted, e.g. [tracker.jira]
#
#   REJECTED, each an error naming the file, line number and reason
#     [[array.of.tables]]              arrays of tables
#     key = [1, 2]                     arrays
#     key = { a = 1 }                  inline tables
#     key = """..."""                  multi-line strings
#     key = 1.5 / 1979-05-27           floats, dates, times
#     "quoted key" = 1                 quoted keys
#     a duplicate bare key, or a duplicate [table] header
#
# Rejecting rather than skipping is the point: a reader that quietly
# skipped an unparsable line would let a typo three lines above
# `tracker = "jira"` fall back to a built-in default, silently running
# against the wrong provider.
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

# Discovery: $NW_CONFIG, else the nearest `.night-watchman/config.toml` walking
# UP from ${NW_ROOT:-$PWD} to /, else nothing. Deliberately no ~/ step:
# selection is a property of the repo, reviewed in its history.
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

# _nw_config_awk — config on stdin, `key<TAB>encoded-value` on stdout,
# complaints on stderr. Exits 1 if it complained, having still printed the
# keys it did understand, so one run reports every error.
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

# nw_config_parse [FILE] — encoded `key<TAB>value` lines; a missing config is
# not an error, an UNREADABLE named one is. Deliberately not cached: callers
# read it through a substitution, so a memo would never reach the parent.
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
    # shellcheck disable=SC2094  # read-only: name for messages, bytes on stdin
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

# nw_config_get KEY [DEFAULT] — the decoded value for a dotted key. Returns 1
# printing nothing when absent with no DEFAULT, so absent differs from empty.
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
