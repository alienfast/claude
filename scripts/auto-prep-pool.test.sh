#!/usr/bin/env bash
# Regression suite for auto-prep-pool.sh's fetch mode. Pins the exit contract on a failed fetch: under `set -e` an
# unguarded `page=$(linear-cli …)` ended the script with linear-cli's own exit code, and that tool's 1, 3 and 4
# (general, auth, rate limit) read here as an argument error, a missing dependency and nothing documented. Also pins
# the pagination the script exists for: a second page is fetched with the first page's cursor and both land in the
# pool. Collision mode is not covered. linear-cli is a PATH shim that logs every invocation; HOME is an empty dir so the
# script's cargo-bin PATH prepend cannot resurrect the real CLI, and each run gets its own cwd because the script
# writes under a relative tmp/.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/auto-prep-pool.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}

mkdir -p "$WORK/bin" "$WORK/home"

# FETCH_RC fails every `api query` with that exit code. FETCH picks the answer otherwise: `one` (a single page of two
# issues), `two` (two issues with a next page, then one issue for the call carrying that cursor), `errors` (a GraphQL
# error envelope at exit 0) or `empty` (nothing at exit 0).
cat > "$WORK/bin/linear-cli" <<'EOF'
#!/bin/bash
printf '%s\n' "$(IFS='|'; printf '%s' "$*")" >> "${SHIM_LOG:?}"
[ "${1:-} ${2:-}" = "api query" ] || exit 1
if [ -n "${FETCH_RC:-}" ]; then echo "Error: the shim was told to fail" >&2; exit "$FETCH_RC"; fi
case "${FETCH:-one}" in
  empty)  ;;
  errors) printf '{"errors":[{"message":"boom"}]}\n' ;;
  two)
    case "$*" in
      *after=c1*) printf '{"data":{"issues":{"nodes":[{"identifier":"TT-3"}],"pageInfo":{"hasNextPage":false,"endCursor":"c2"}}}}\n' ;;
      *)          printf '{"data":{"issues":{"nodes":[{"identifier":"TT-1"},{"identifier":"TT-2"}],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}\n' ;;
    esac ;;
  *) printf '{"data":{"issues":{"nodes":[{"identifier":"TT-1"},{"identifier":"TT-2"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}\n' ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

run() { # run — a fetch for team TT in a fresh cwd, under the caller's FETCH / FETCH_RC
  rm -rf "$WORK/cwd"
  mkdir -p "$WORK/cwd"
  : > "$WORK/calls.log"
  ( cd "$WORK/cwd" && SHIM_LOG="$WORK/calls.log" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
      "$SCRIPT" --team TT > "$WORK/out" 2> "$WORK/err" )
  echo "$?"
}
pool_size() { jq '.nodes | length' "$WORK/cwd/tmp/pool.json" 2>/dev/null || echo none; }

echo "auto-prep-pool.sh fetch —"

rc=$(run)
ck "one page: exit 0"                            "0" "$rc"
ck "one page: pool size printed"                 "pool: 2 workable issues -> tmp/pool.json" "$(cat "$WORK/out")"
ck "one page: one fetch"                         "1" "$(grep -c '^api|query' "$WORK/calls.log")"

rc=$(FETCH=two run)
ck "two pages: exit 0"                           "0" "$rc"
ck "two pages: both pages land in the pool"      "3" "$(pool_size)"
ck_has  "two pages: the second fetch carries the cursor"       "after=c1" "$WORK/calls.log"

echo "auto-prep-pool.sh a failed fetch —"

# linear-cli's own codes: 1 general, 3 auth, 4 rate limit. Here 1 is an argument error and 3 a missing dependency.
for code in 1 3 4; do
  rc=$(FETCH_RC=$code run)
  ck "fetch exits $code: exit 2"                   "2" "$rc"
  ck_has  "fetch exits $code: says the fetch failed, with the code" "issue fetch failed (linear-cli exit $code)" "$WORK/err"
  ck_has  "fetch exits $code: linear-cli's own message survives"    "the shim was told to fail" "$WORK/err"
  ck "fetch exits $code: no pool written"          "none" "$(pool_size)"
done

rc=$(FETCH=errors run)
ck "error envelope: exit 2"                      "2" "$rc"
ck_has  "error envelope: prints the errors"                    "boom" "$WORK/err"

rc=$(FETCH=empty run)
ck "empty answer: exit 2"                        "2" "$rc"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
