#!/usr/bin/env bash
# Regression suite for linear-dedup-search.sh. Pins the five silent-empty failure modes the helper exists to make loud:
# a RATELIMITED envelope read as "no duplicate" (exit 3, empty stdout), a composed phrase (exit 2, no CLI call), a
# terminal hit judged by a `.state.type` the row does not carry (prior-art tag by state NAME), a bare-array reply
# indexed as `.nodes`, and the same issue surfacing from two tokens (deduped, first-seen order).
#
# Fixture rows have the real `search issues -o json` shape — {id, identifier, priority, state: {name}, title} — snapshotted
# 2026-11-04 from `linear-cli search issues StxHistory -o json | jq '.[0:2]'` (BF-2867 and BF-2872 verbatim); the
# Canceled / Duplicate / open rows reuse that shape with another state name.
#
# Isolation: linear-cli is a PATH shim dispatching on the query argument; HOME points at an empty dir so the script's
# `export PATH="$HOME/.cargo/bin:$PATH"` prepend cannot resurrect the real CLI. Every shim call appends its query to
# $WORK/calls.log, which is how the one-call-per-token and nothing-ran assertions read.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-dedup-search.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"
    grep -F -- "${2:0:12}" "$3" | head -1 | sed 's/^/  near: /'
  fi
}
ck_lacks() { # ck_lacks <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi
}

FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

row() { # row <uuid> <identifier> <state name> <title>
  jq -n --arg id "$1" --arg ident "$2" --arg st "$3" --arg t "$4" \
    '{id:$id, identifier:$ident, priority:3, state:{name:$st}, title:$t}'
}
# Fixture file per query, named by the query with spaces as underscores.
fixture() { # fixture <query> <row>...
  local q="$1"; shift
  jq -s '.' <(for r in "$@"; do printf '%s\n' "$r"; done) > "$FIX/q-${q// /_}.json"
}

R_DONE=$(row cefd775e-7bf8-4d45-90bf-fc8472373afa BF-2867 Done "Serve plain-language sources, never database names, in the public semver declaration")
R_DONE2=$(row 68b424a9-6e76-45c9-9252-22ac9ad903f8 BF-2872 Done "Versioning: show line identity-verification events in the transaction history from the records that carry their actor")
R_CANCELED=$(row 00000000-0000-4000-8000-000000000001 BF-3001 Canceled "A cancelled sibling")
R_CANCELLED=$(row 00000000-0000-4000-8000-000000000002 BF-3002 Cancelled "A British-spelled cancelled sibling")
R_DUP=$(row 00000000-0000-4000-8000-000000000003 BF-3003 Duplicate "A duplicate sibling")
R_OPEN=$(row 00000000-0000-4000-8000-000000000004 BF-3065 Backlog "Transaction history says the owner's identity check did not pass when their session only ended")
R_WIP=$(row 00000000-0000-4000-8000-000000000005 BF-3070 "In Progress" "An in-flight sibling")

fixture StxHistory "$R_DONE" "$R_OPEN"
fixture other "$R_OPEN" "$R_DONE2"
fixture terminals "$R_DONE" "$R_CANCELED" "$R_CANCELLED" "$R_DUP" "$R_WIP" "$R_OPEN"
fixture "verbatim title text" "$R_DONE"
fixture empty
fixture first "$R_WIP"

RL_JSON='{"code":4,"details":{"errors":[{"extensions":{"code":"RATELIMITED","statusCode":429,"type":"ratelimited"},"message":"Rate limit exceeded. Only 2500 requests are allowed per 1 hour."}]},"error":true,"message":"HTTP 400 Bad Request","retry_after":null}'
RL_TABLE='Error: HTTP 400 Bad Request: Rate limit exceeded. Only 2500 requests are allowed per 1 hour'

# Shim: `search issues <query> -o json`. A `rl-<query>` / `rltable-<query>` / `fail-<query>` / `object-<query>` marker in $FIX
# makes that query answer the rate-limit envelope (json / table mode), a generic CLI failure, or a `{nodes:[]}` object.
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
FIX="$FIX"
RL='$RL_JSON'
RLT='$RL_TABLE'
if [ "\${1:-}" != "search" ] || [ "\${2:-}" != "issues" ]; then echo "unexpected linear-cli call: \$*" >&2; exit 1; fi
q="\$3"
printf '%s\n' "\$q" >> "$WORK/calls.log"
k="\${q// /_}"
if [ -f "\$FIX/rl-\$k" ]; then printf '%s\n' "\$RL" >&2; exit 4; fi
if [ -f "\$FIX/rltable-\$k" ]; then printf '%s\n' "\$RLT" >&2; exit 1; fi
if [ -f "\$FIX/fail-\$k" ]; then echo "Error: network unreachable" >&2; exit 1; fi
if [ -f "\$FIX/object-\$k" ]; then printf '%s' '{"nodes":[]}'; exit 0; fi
if [ -f "\$FIX/q-\$k.json" ]; then cat "\$FIX/q-\$k.json"; else printf '[]'; fi
EOF
chmod +x "$WORK/bin/linear-cli"

run() { # run <label> <args...> — sets RC, OUT, ERR files; resets the call log
  local label="$1"; shift
  : > "$WORK/calls.log"
  HOME="$WORK/home" PATH="$WORK/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" bash "$SCRIPT" "$@" > "$WORK/$label.out" 2> "$WORK/$label.err"
  RC=$?
}

# ---- single token with hits ----
run single StxHistory
ck "single: exit" 0 "$RC"
ck "single: lines" $'prior-art: BF-2867 | Done | Serve plain-language sources, never database names, in the public semver declaration\nBF-3065 | Backlog | Transaction history says the owner\'s identity check did not pass when their session only ended' "$(cat "$WORK/single.out")"
ck "single: one call" "StxHistory" "$(cat "$WORK/calls.log")"
ck "single: stderr quiet" "" "$(cat "$WORK/single.err")"

# ---- overlapping tokens: BF-3065 is in both; deduped, first-seen order, one call each ----
run overlap StxHistory other
ck "overlap: exit" 0 "$RC"
ck "overlap: ids in first-seen order" $'BF-2867\nBF-3065\nBF-2872' "$(sed -E 's/^prior-art: //; s/ \|.*//' "$WORK/overlap.out")"
ck "overlap: one call per token" $'StxHistory\nother' "$(cat "$WORK/calls.log")"

# ---- terminal names tagged, open names not ----
run terminals terminals
ck "terminals: exit" 0 "$RC"
ck_has "terminals: Done tagged" "prior-art: BF-2867 | Done | " "$WORK/terminals.out"
ck_has "terminals: Canceled tagged" "prior-art: BF-3001 | Canceled | " "$WORK/terminals.out"
ck_has "terminals: Cancelled tagged" "prior-art: BF-3002 | Cancelled | " "$WORK/terminals.out"
ck_has "terminals: Duplicate tagged" "prior-art: BF-3003 | Duplicate | " "$WORK/terminals.out"
ck_has "terminals: Backlog listed" "BF-3065 | Backlog | " "$WORK/terminals.out"
ck_lacks "terminals: Backlog untagged" "prior-art: BF-3065" "$WORK/terminals.out"
ck_has "terminals: In Progress listed" "BF-3070 | In Progress | " "$WORK/terminals.out"
ck_lacks "terminals: In Progress untagged" "prior-art: BF-3070" "$WORK/terminals.out"

# ---- whitespace token refused before any call ----
run ws "two words"
ck "whitespace: exit" 2 "$RC"
ck "whitespace: stdout empty" "" "$(cat "$WORK/ws.out")"
ck_has "whitespace: names gotcha 14" "gotcha #14" "$WORK/ws.err"
ck_has "whitespace: names --phrase" "--phrase" "$WORK/ws.err"
ck "whitespace: no CLI call" "" "$(cat "$WORK/calls.log")"

run ws2 StxHistory "two words"
ck "whitespace after a good token: exit" 2 "$RC"
ck "whitespace after a good token: nothing ran" "" "$(cat "$WORK/calls.log")"

# ---- --phrase is one query, whitespace intact ----
run phrase --phrase "verbatim title text"
ck "phrase: exit" 0 "$RC"
ck "phrase: one call, whole phrase" "verbatim title text" "$(cat "$WORK/calls.log")"
ck_has "phrase: hit printed" "prior-art: BF-2867 | Done | " "$WORK/phrase.out"

run phrase_tok --phrase "verbatim title text" StxHistory
ck "phrase + token: two calls" $'verbatim title text\nStxHistory' "$(cat "$WORK/calls.log")"

run phrase_missing --phrase
ck "phrase without value: exit" 2 "$RC"

# ---- rate limit: exit 3, empty stdout, envelope line on stderr, even after an earlier good answer ----
touch "$FIX/rl-other"
run rl StxHistory other
ck "ratelimit json: exit" 3 "$RC"
ck "ratelimit json: stdout empty" "" "$(cat "$WORK/rl.out")"
ck "ratelimit json: envelope relayed" "$RL_JSON" "$(cat "$WORK/rl.err")"
rm "$FIX/rl-other"

touch "$FIX/rltable-StxHistory"
run rlt StxHistory
ck "ratelimit table: exit" 3 "$RC"
ck "ratelimit table: stdout empty" "" "$(cat "$WORK/rlt.out")"
ck "ratelimit table: line relayed" "$RL_TABLE" "$(cat "$WORK/rlt.err")"
rm "$FIX/rltable-StxHistory"

# ---- another CLI failure: exit 1, stderr relayed, not mistaken for a rate limit ----
touch "$FIX/fail-StxHistory"
run fail StxHistory
ck "failure: exit" 1 "$RC"
ck "failure: stdout empty" "" "$(cat "$WORK/fail.out")"
ck_has "failure: stderr relayed" "network unreachable" "$WORK/fail.err"
rm "$FIX/fail-StxHistory"

# ---- a non-array reply is an error, not a clean search ----
touch "$FIX/object-StxHistory"
run object StxHistory
ck "object reply: exit" 1 "$RC"
ck "object reply: stdout empty" "" "$(cat "$WORK/object.out")"
rm "$FIX/object-StxHistory"

# ---- empty array is a clean search ----
run empty empty
ck "empty: exit" 0 "$RC"
ck "empty: stdout empty" "" "$(cat "$WORK/empty.out")"

# ---- usage ----
run noargs
ck "no args: exit" 2 "$RC"
run help --help
ck "help: exit" 0 "$RC"
ck_has "help: usage printed" "Usage: linear-dedup-search.sh" "$WORK/help.out"
run badflag --nope
ck "unknown flag: exit" 2 "$RC"
ck "unknown flag: no CLI call" "" "$(cat "$WORK/calls.log")"

echo "$PASS passed / $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
