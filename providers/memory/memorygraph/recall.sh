#!/bin/bash
#
# recall.sh — the `recall` verb. memorygraph's own `recall --query` finds
# nothing for a multi-word phrase: `recall --query "jira api auth"`
# returns zero results, `recall --query "jira"` returns six. This first
# fixed that with a plain per-word fan-out; a later change ports the source
# project's rank-fusion follow-up (scripts/dev/recall.sh, one commit past
# that fork point): tokenize the query into single-noun candidates
# (stopwords and sub-3-char words dropped, deduped, capped at
# --max-queries), run one `memorygraph recall --query WORD --limit N` per
# token, parse each token's prose result block, and fuse the per-token
# rankings with reciprocal rank fusion (RRF) instead of printing each
# token's raw output back to back. On the real store, tokens barely
# overlap, so ranking by match count alone degenerates to "sort by
# importance" and buries the memory that actually answers the query — RRF
# (score = sum over matching tokens of 1/(60 + rank_in_that_token)) fixes
# that by weighting each token's own relevance order. A zero-result
# multi-word recall is a malformed query, never evidence the graph is
# empty on a topic.
#
# bash 3.2 compatible (no associative arrays).

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/kit.sh
. "$DIR/../../lib/kit.sh"

# pipe_ok — swallow a pipeline's exit status so an explicit check
# afterward can report the failure instead of `set -e` killing the script
# first mid-pipeline.
pipe_ok() { return 0; }

usage() {
    cat >&2 <<'EOF'
usage: recall.sh QUERY [--limit N] [--top N] [--max-queries N] [--dry-run]

Splits QUERY into single-noun tokens (stopwords and words under 3 chars
dropped, deduped, capped at --max-queries, default 8) and runs one
`memorygraph recall --query WORD --limit N` per token (default limit 20)
-- memorygraph returns zero results for a multi-word --query, so this is
the fan-out that actually finds things. Results are merged across tokens
by reciprocal rank fusion (RRF: score = sum of 1/(60 + rank) over every
token that returned the memory) and the top --top (default 10) are
printed, ranked by score. --dry-run prints the planned per-token
commands, shell-quoted, instead of running them.
EOF
    exit 1
}

query=""
limit=20
top=10
max_queries=8
dry_run=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --limit)       [ "$#" -ge 2 ] || usage; limit="$2"; shift 2 ;;
        --top)         [ "$#" -ge 2 ] || usage; top="$2"; shift 2 ;;
        --max-queries) [ "$#" -ge 2 ] || usage; max_queries="$2"; shift 2 ;;
        --dry-run)     dry_run=1; shift ;;
        -h | --help)   usage ;;
        --) shift; [ "$#" -ge 1 ] && { query="$1"; shift; }; break ;;
        -*) echo "Error: unknown argument: $1" >&2; usage ;;
        *)  [ -z "$query" ] || { echo "Error: unexpected extra argument: $1" >&2; usage; }
            query="$1"
            shift ;;
    esac
done

[ -n "$query" ] || usage

# ------------------------------------------------------------- tokenising
#
# Stopwords: plain-English function words that carry no search signal on
# their own. Deliberately not exhaustive -- the goal is to stop "why does
# the api fail" wasting a query on "does" and "the", not to build an NLP
# pipeline.
STOPWORDS=" a an the is are was were does do did why how what when where who \
which for to of in on at and or but with from this that it its be been \
being can could should would will shall not no nor so than then too very \
about into over under again further out up down all any both each few more \
most other some such only own same as if because until while "

# Lowercase, then turn every run of non [a-z0-9] characters into a single
# space -- strips punctuation and does word-splitting in one pass. Pure
# POSIX tr, no bash 4 ${var,,}.
CANDIDATES=$(printf '%s' "$query" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9' ' ' \
    | tr -s ' ')

words=()
n_words=0
for w in $CANDIDATES; do
    [ "$n_words" -lt "$max_queries" ] || break
    [ "${#w}" -ge 3 ] || continue
    case "$STOPWORDS" in
        *" $w "*) continue ;;
    esac
    dupe=0
    if [ "${#words[@]}" -gt 0 ]; then
        for existing in "${words[@]}"; do
            [ "$existing" = "$w" ] && { dupe=1; break; }
        done
    fi
    [ "$dupe" -eq 1 ] && continue
    words=("${words[@]-}" "$w")
    # bash 3.2 quirk: appending to an array that was declared empty
    # (words=()) via "${words[@]-}" can leave a leading empty element on
    # some bash 3.2 builds; guard by only counting non-empty entries below.
    n_words=$((n_words + 1))
done

[ "$n_words" -ge 1 ] \
    || { echo "Error: no usable search terms in '$query' (every word was a stopword or shorter than 3 characters)" >&2; exit 1; }

if [ "$dry_run" -eq 1 ]; then
    for w in "${words[@]}"; do
        [ -n "$w" ] || continue
        printf 'memorygraph recall --query %q --limit %q\n' "$w" "$limit"
    done
    exit 0
fi

need memorygraph perl

OUTF=$(tmpfile) || die "could not create a temp file"
ROWS=$(tmpfile) || die "could not create a temp file"
PARSER=$(tmpfile) || die "could not create a temp file"

# The prose parser. A memorygraph result block looks like:
#   **1. Title text** (ID: uuid)
#   Type: solution | Importance: 0.8
#   Match: ...
#   Content: text...
#   Tags: a, b, c
# Emits one TSV row per memory (id, title, type, importance, tags,
# content, rank), then a trailing "##HEADER<TAB>expected<TAB>found" line:
# expected is the count memorygraph's own "Found N relevant memories"
# header claimed (0 for its "No memories found" message, -1 if neither
# was recognised), and found is how many blocks this parser actually
# extracted. The caller compares them -- a mismatch is a format-drift
# signal, not a "no hits". `rank` is the block's own leading number
# ("**1.", "**2." ...) -- memorygraph's own relevance ordering for this
# one token's query, 1-based, and is what the RRF merge below fuses
# across tokens.
cat > "$PARSER" <<'PERL'
use strict;
use warnings;

my $file = shift @ARGV or die "usage: recall-parse.pl <file>\n";
local $/;
open(my $fh, '<', $file) or die "cannot open $file: $!\n";
my $text = <$fh>;
close $fh;

my $expected;
if ($text =~ /\*\*Found\s+(\d+)\s+relevant memories/) {
    $expected = $1;
} elsif ($text =~ /No memories found matching your query/) {
    $expected = 0;
} else {
    $expected = -1;
}

# A genuine block boundary is a header line IMMEDIATELY followed, on the
# very next line, by its "Type: ... | Importance: ..." line -- that is
# how memorygraph always renders one. A memory's own Content can quote a
# header-shaped line without also fabricating a matching Type/Importance
# line right after it, so requiring both together (not the header shape
# alone) avoids splitting one well-formed block into two.
my $header = qr/\*\*\d+\.\s+.*?\*\*\s*\(ID:\s*[0-9a-fA-F-]{36}\)\nType:\s*\S+\s*\|\s*Importance:\s*[\d.]+/s;

my $found = 0;
while ($text =~ /(?:\*\*(\d+)\.\s+(.*?)\*\*\s*\(ID:\s*([0-9a-fA-F-]{36})\)\nType:\s*(\S+)\s*\|\s*Importance:\s*([\d.]+))(.*?)(?=\n$header|\nNext steps:|\z)/gs) {
    my ($rank, $title, $id, $type, $importance, $rest) = ($1, $2, $3, $4, $5, $6);
    $title =~ s/\s+/ /g;
    $title =~ s/^\s+|\s+$//g;
    my $content = '';
    if ($rest =~ /Content:\s*(.*?)(?:\nTags:|\z)/s) {
        $content = $1;
        $content =~ s/\s+/ /g;
        $content =~ s/^\s+|\s+$//g;
    }
    my $tags = '';
    if ($rest =~ /Tags:\s*(.*?)\s*$/m) {
        $tags = $1;
    }
    for ($title, $id, $type, $importance, $tags, $content) {
        s/\t/ /g;
    }
    print join("\t", $id, $title, $type, $importance, $tags, $content, $rank), "\n";
    $found++;
}

print "##HEADER\t$expected\t$found\n";
PERL

tokens_hit=""
tokens_nohit=""

for w in "${words[@]}"; do
    [ -n "$w" ] || continue
    memorygraph recall --query "$w" --limit "$limit" > "$OUTF" 2>&1 \
        || die "memorygraph recall --query '$w' failed"

    PARSED=$(perl "$PARSER" "$OUTF") || die "recall.sh: internal parser error on token '$w'"

    HEADER_LINE=$(printf '%s\n' "$PARSED" | grep '^##HEADER' || pipe_ok)
    [ -n "$HEADER_LINE" ] || die "recall.sh: parser produced no ##HEADER line for token '$w' -- internal error"

    EXPECTED=$(printf '%s\n' "$HEADER_LINE" | cut -f2)
    FOUND=$(printf '%s\n' "$HEADER_LINE" | cut -f3)

    if [ "$EXPECTED" = "-1" ]; then
        die "recall.sh: memorygraph's output for '$w' did not match either known header shape ('**Found N relevant memories:**' or 'No memories found matching your query') -- the CLI's output format has likely changed and this parser needs updating. Raw output:
$(cat "$OUTF")"
    fi
    if [ "$EXPECTED" != "$FOUND" ]; then
        die "recall.sh: parser mismatch for token '$w' -- memorygraph's header claimed $EXPECTED memories but only $FOUND were parsed out. Treating this as a parser break, not zero hits. Raw output:
$(cat "$OUTF")"
    fi

    if [ "$FOUND" -gt 0 ]; then
        tokens_hit="$tokens_hit $w"
        printf '%s\n' "$PARSED" | grep -v '^##HEADER' >> "$ROWS" || pipe_ok
    else
        tokens_nohit="$tokens_nohit $w"
    fi
done

TOTAL_ROWS=$(wc -l < "$ROWS" | tr -d ' ')

if [ "$TOTAL_ROWS" -eq 0 ]; then
    echo "0 unique memories across $n_words token(s) queried (hit: none)"
else
    # RRF merge: score(memory) = sum over every token that returned it of
    # 1/(k + rank_in_that_token), k=60. Rewards ranking well in one list
    # AND appearing in several, and degrades gracefully to "just use
    # per-token rank" when every memory matches only one token -- the
    # common case on a real store where tokens barely overlap. Importance
    # is kept only as the final tiebreak among equal scores.
    #
    # Not a pipeline -- a single awk command with a plain output redirect
    # -- so this deliberately does NOT use `|| pipe_ok`: `set -e` catching
    # awk's own exit status directly is what catches awk dying partway
    # through after already emitting some rows, which the downstream
    # `[ -s "$MERGED" ]` check alone would not.
    MERGED=$(tmpfile) || die "could not create a temp file"
    awk -F'\t' -v k=60 '
        {
            id = $1; rank = $7 + 0;
            contrib = 1.0 / (k + rank);
            if (!(id in seen)) { seen[id] = $0; order[++n] = id; score[id] = 0; best[id] = rank }
            score[id] += contrib;
            cnt[id]++;
            if (rank < best[id]) best[id] = rank;
        }
        END {
            for (i = 1; i <= n; i++) { id = order[i]; printf "%.6f\t%d\t%d\t%s\n", score[id], cnt[id], best[id], seen[id] }
        }
    ' "$ROWS" > "$MERGED" \
        || die "recall.sh: internal error -- the RRF merge (awk) failed while processing $TOTAL_ROWS hit row(s)"
    [ -s "$MERGED" ] || die "recall.sh: internal error -- merging $TOTAL_ROWS hit row(s) produced nothing"

    UNIQUE_COUNT=$(wc -l < "$MERGED" | tr -d ' ')
    if [ "$UNIQUE_COUNT" -gt "$top" ]; then
        echo "$UNIQUE_COUNT unique memories across $n_words token(s) queried -- showing top $top by score"
    else
        echo "$UNIQUE_COUNT unique memories across $n_words token(s) queried"
    fi
    echo ""
    # Fields after the awk merge: rrf-score(1) matched-count(2)
    # best-rank(3) id(4) title(5) type(6) importance(7) tags(8) content(9)
    # then the original per-row rank(10), unused here. Sort keys: RRF
    # score desc, importance desc (tiebreak), title asc (final tiebreak).
    sort -t "$(printf '\t')" -k1,1gr -k7,7gr -k5,5f "$MERGED" \
        | head -n "$top" \
        | while IFS=$'\t' read -r score matched bestrank id title type importance tags content _origrank; do
            [ "${#content}" -le 220 ] && short="$content" || short="${content:0:220}..."
            printf '[score %s, matched %s/%s tokens, best rank %s, importance %s] %s (ID: %s)\n  Type: %s | Tags: %s\n  %s\n\n' \
                "$score" "$matched" "$n_words" "$bestrank" "$importance" "$title" "$id" "$type" "$tags" "$short"
        done \
        || pipe_ok
    if [ "$UNIQUE_COUNT" -gt "$top" ]; then
        echo "($((UNIQUE_COUNT - top)) more not shown -- raise --top to see them)"
    fi
fi

if [ -n "$tokens_hit" ]; then
    echo "hit:    $tokens_hit" >&2
else
    echo "hit:    (none)" >&2
fi
[ -n "$tokens_nohit" ] && echo "no hit: $tokens_nohit" >&2
