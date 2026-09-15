#!/bin/bash
#
# Selftest for providers/memory/memorygraph/{provider,store,recall}.sh.
# Runs entirely against a stubbed `memorygraph` binary put on PATH for the
# duration of the test — nothing here touches the operator's real
# ~/.memorygraph store.
#
# What is asserted, in order:
#
#   1  store.sh --dry-run builds --tags from project/component/kind/extra
#      in that order, and never calls the stub.
#   2  store.sh with no --dry-run calls the stub exactly once, with the
#      arguments store.sh built.
#   3  store.sh refuses a call missing any of --type/--title/--content/
#      --project.
#   4  recall.sh --dry-run on a three-word query prints exactly three
#      single-noun `memorygraph recall` commands, none of them the
#      original multi-word phrase — this is the fan-out fix itself.
#   5  recall.sh --dry-run on a one-word query prints exactly one.
#   6  recall.sh with no --dry-run calls the stub once per word and
#      prints each call's output.
#   7  recall.sh drops stopwords and sub-3-char words from tokenising —
#      dry-run on "how do jira and api auth work" plans only jira/api/auth.
#   8  recall.sh fuses per-token rank with reciprocal rank
#      fusion: a multi-noun query where one memory is returned by two
#      tokens outranks a memory returned by only one token at rank 1 —
#      this is the rank-fusion port itself, not just the per-word fan-out.
#   9  provider.sh dispatches `store`/`recall` to the matching script and
#      refuses an unknown verb.
#
# Usage: providers/memory/memorygraph/selftest.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PROVIDER_SH="$HERE/provider.sh"
STORE_SH="$HERE/store.sh"
RECALL_SH="$HERE/recall.sh"

for f in "$PROVIDER_SH" "$STORE_SH" "$RECALL_SH"; do
    [ -x "$f" ] || { echo "$f is missing or not executable" >&2; exit 2; }
done

N=0
FAIL=0
ok()  { N=$((N + 1)); echo "ok - $1"; }
bad() { N=$((N + 1)); FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

eq() {
    if [ "$2" = "$3" ]; then ok "$1"; else
        bad "$1"
        printf '       expected: %s\n' "$2"
        printf '       actual:   %s\n' "$3"
    fi
}

contains() {
    case "$3" in
        *"$2"*) ok "$1" ;;
        *) bad "$1"; printf '       wanted substring: %s\n       in: %s\n' "$2" "$3" ;;
    esac
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# A stub `memorygraph` on PATH that records every invocation (one line per
# call, args tab-joined) to $WORK/calls.log and, for `recall`, prints
# memorygraph's real prose result format so recall.sh's own parser and RRF
# merge run for real against a fixture instead of a shortcut string. Three
# fixture memories:
#   ID_A "Jira auth flow"    — returned by tokens jira (rank 1) and api (rank 2)
#   ID_C "API rate limits"   — returned by tokens api (rank 1) and jira (rank 2)
#   ID_D "Standalone auth note" — returned only by token auth, at rank 1
# so a memory hit by two tokens (A, C) must outscore one hit by a single
# token at rank 1 (D) — the rank-fusion behavior this ports in.
mkdir -p "$WORK/bin"
cat > "$WORK/bin/memorygraph" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$WORK_LOG"

block() {
    # block RANK ID TITLE TYPE IMPORTANCE TAGS CONTENT
    printf '**%s. %s** (ID: %s)\nType: %s | Importance: %s\nMatch: fixture\nContent: %s\nTags: %s\n\n' \
        "$1" "$3" "$2" "$4" "$5" "$7" "$6"
}

case "$1" in
    store)  echo "stored" ;;
    recall) shift; word=""
            while [ "$#" -gt 0 ]; do
                [ "$1" = "--query" ] && word="$2"
                shift
            done
            ID_A=11111111-1111-1111-1111-111111111111
            ID_C=33333333-3333-3333-3333-333333333333
            ID_D=44444444-4444-4444-4444-444444444444
            case "$word" in
                jira)
                    echo "**Found 2 relevant memories:**"
                    echo ""
                    block 1 "$ID_A" "Jira auth flow" solution 0.8 "jira,auth" "How jira auth works"
                    block 2 "$ID_C" "API rate limits" problem 0.5 "api" "API rate limit notes"
                    ;;
                api)
                    echo "**Found 2 relevant memories:**"
                    echo ""
                    block 1 "$ID_C" "API rate limits" problem 0.5 "api" "API rate limit notes"
                    block 2 "$ID_A" "Jira auth flow" solution 0.8 "jira,auth" "How jira auth works"
                    ;;
                auth)
                    echo "**Found 1 relevant memories:**"
                    echo ""
                    block 1 "$ID_D" "Standalone auth note" general 0.9 "auth" "Auth only, single hit"
                    ;;
                *)
                    echo "No memories found matching your query"
                    ;;
            esac
            ;;
esac
STUB
chmod +x "$WORK/bin/memorygraph"
export WORK_LOG="$WORK/calls.log"
export PATH="$WORK/bin:$PATH"
: > "$WORK_LOG"

# ---- 1. store.sh --dry-run builds --tags in the right order ------------

DRY=$("$STORE_SH" --type problem --title "T" --content "C" \
    --project nwm --component memory --kind fix --tags extra1,extra2 --dry-run)
contains "dry-run store prints the memorygraph command" "memorygraph store" "$DRY"
contains "dry-run tags: project first" "nwm" "$DRY"
contains "dry-run tags include component, kind, and extras in order" \
    "memory" "$DRY"
case "$DRY" in
    *'nwm\,memory\,fix\,extra1\,extra2'*|*'nwm,memory,fix,extra1,extra2'*)
        ok "dry-run tags are ordered project,component,kind,extras" ;;
    *) bad "dry-run tags are ordered project,component,kind,extras" ;;
esac
if [ -s "$WORK_LOG" ]; then bad "dry-run store never calls the stub"; else ok "dry-run store never calls the stub"; fi

# ---- 2. store.sh actually calls the stub once ---------------------------

: > "$WORK_LOG"
OUT=$("$STORE_SH" --type solution --title "T2" --content "C2" --project nwm)
eq "store.sh prints the stub's output" "stored" "$OUT"
eq "store.sh calls the stub exactly once" "1" "$(wc -l < "$WORK_LOG" | tr -d ' ')"
contains "the call carries the built tags" "--tags nwm" "$(cat "$WORK_LOG")"

# ---- 3. store.sh refuses a call missing a required flag -----------------

if "$STORE_SH" --type problem --title "T" --content "C" >/dev/null 2>&1; then
    bad "store.sh without --project is refused"
else
    ok "store.sh without --project is refused"
fi

# ---- 4. recall.sh --dry-run fans a 3-word query into 3 commands ---------

DRY=$("$RECALL_SH" "jira api auth" --dry-run)
LINES=$(printf '%s\n' "$DRY" | grep -c '^memorygraph recall')
eq "a three-word query prints three planned recall commands" "3" "$LINES"
contains "one planned command targets jira alone" "--query jira " "$DRY"
contains "one planned command targets api alone" "--query api " "$DRY"
contains "one planned command targets auth alone" "--query auth " "$DRY"
case "$DRY" in
    *"--query 'jira api auth'"*|*'--query "jira api auth"'*)
        bad "no planned command re-sends the whole multi-word phrase" ;;
    *) ok "no planned command re-sends the whole multi-word phrase" ;;
esac

# ---- 5. recall.sh --dry-run on one word prints exactly one --------------

DRY=$("$RECALL_SH" jira --dry-run)
LINES=$(printf '%s\n' "$DRY" | grep -c '^memorygraph recall')
eq "a one-word query prints exactly one planned command" "1" "$LINES"

# ---- 6. recall.sh without --dry-run calls the stub per word -------------

: > "$WORK_LOG"
OUT=$("$RECALL_SH" "jira auth" --limit 5)
eq "recall.sh calls the stub once per word" "2" "$(wc -l < "$WORK_LOG" | tr -d ' ')"
contains "recall.sh's output includes the jira-token memory" "Jira auth flow" "$OUT"
contains "recall.sh's output includes the auth-token memory" "Standalone auth note" "$OUT"
contains "each call carries the given --limit" "--limit 5" "$(cat "$WORK_LOG")"

# ---- 7. recall.sh tokenising drops stopwords and sub-3-char words -------

DRY=$("$RECALL_SH" "how do jira and api auth" --dry-run)
LINES=$(printf '%s\n' "$DRY" | grep -c '^memorygraph recall')
eq "stopword-laden query still plans exactly three commands" "3" "$LINES"
contains "the plan targets jira" "--query jira " "$DRY"
contains "the plan targets api" "--query api " "$DRY"
contains "the plan targets auth" "--query auth " "$DRY"
case "$DRY" in
    *"--query how"*|*"--query do"*|*"--query and"*)
        bad "no planned command queries a dropped stopword" ;;
    *) ok "no planned command queries a dropped stopword" ;;
esac

# ---- 8. recall.sh fuses per-token rank with RRF -----------------
#
# Fixture: "Jira auth flow" (ID_A) is returned by both jira (rank 1) and
# api (rank 2); "Standalone auth note" (ID_D) is returned only by auth, at
# rank 1. A plain "best single-token rank" merge would rank ID_D above
# ID_A (rank 1 beats rank 2); RRF, which rewards a memory found by more
# than one token, must rank ID_A first instead — that is the fix this
# ticket ports.

: > "$WORK_LOG"
OUT=$("$RECALL_SH" "jira api auth")
eq "recall.sh calls the stub once per token" "3" "$(wc -l < "$WORK_LOG" | tr -d ' ')"

A_LINE=$(printf '%s\n' "$OUT" | grep -n "Jira auth flow" | head -1 | cut -d: -f1)
D_LINE=$(printf '%s\n' "$OUT" | grep -n "Standalone auth note" | head -1 | cut -d: -f1)
if [ -n "$A_LINE" ] && [ -n "$D_LINE" ] && [ "$A_LINE" -lt "$D_LINE" ]; then
    ok "the memory matched by two tokens (score-fused) ranks above the single-token rank-1 memory"
else
    bad "the memory matched by two tokens (score-fused) ranks above the single-token rank-1 memory"
    printf '       jira/api hit at line %s, auth-only hit at line %s\n       output:\n%s\n' "$A_LINE" "$D_LINE" "$OUT"
fi
contains "the fused memory reports matching 2 of 3 tokens" "matched 2/3 tokens" "$OUT"
contains "the single-token memory reports matching 1 of 3 tokens" "matched 1/3 tokens" "$OUT"

# ---- 9. provider.sh dispatches verbs and refuses unknown ones -----------

: > "$WORK_LOG"
OUT=$("$PROVIDER_SH" store --type problem --title T --content C --project nwm)
eq "provider.sh store dispatches to store.sh" "stored" "$OUT"

OUT=$("$PROVIDER_SH" recall jira --dry-run)
contains "provider.sh recall dispatches to recall.sh" "memorygraph recall --query jira" "$OUT"

if "$PROVIDER_SH" bogus 2>/dev/null; then
    bad "provider.sh refuses an unknown verb"
else
    ok "provider.sh refuses an unknown verb"
fi

echo
echo "$N assertion(s), $((N - FAIL)) passed" >&2
if [ "$FAIL" -ne 0 ]; then
    echo "providers/memory/memorygraph/selftest.sh: FAILED" >&2
    exit 1
fi
echo "providers/memory/memorygraph/selftest.sh: all assertions passed" >&2
exit 0
