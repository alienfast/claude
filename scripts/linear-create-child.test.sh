#!/usr/bin/env bash
# Regression suite for linear-create-child.sh's label handling (BF-1248 item 1). Pins the
# round trip the corruption broke — a multi-word label must reach `issues update -l` with its
# internal spacing intact (`tr -d '[:space:]'` turned `needs decision` into `needsdecision`,
# missed the canonical label case-insensitively but space-sensitively, then MINTED the
# corruption via `labels create`: BF-1109, BF-1243) — plus the normalized-identity healing
# lifted from linear-add-label.sh: a near-miss heals to the canonical label with a NOTE, an
# ambiguous near-miss is skipped with exit 2, and a genuinely novel name is refused with exit 2
# rather than minted (quality-review's `suggested` reply token, passed as a label, minted a
# label on 2026-08-19 that fourteen filings then carried in place of `specified`). Also pins the
# routing gate: a label slot carrying no routing label is refused before anything is created
# unless the call passes the leading --allow-unrouted. And the --search create-time re-search: an
# unacknowledged open hit filed inside the window refuses with exit 5 before anything is created,
# replaying the 2026-11-15 race (BF-3306 and BF-3310 filed minutes before BF-3311, off a search that
# predated both). linear-cli is a PATH shim that logs every invocation; HOME is an empty dir so the
# script's cargo-bin PATH prepend cannot resurrect the real CLI. The re-search runs the real
# linear-dedup-search.sh beside the script, so it hits the same shim.
#
# Search rows are verbatim from `linear-cli search issues transport -o json` (2026-11-15), with BF-3306
# and BF-3310 set to Backlog, their state when BF-3311 was filed. The recent-filings reply is the real
# `api query … --variable since=-PT60M -o json` shape, nodes {createdAt, identifier}, with their real
# createdAt. The rate-limit envelope is linear-dedup-search.test.sh's real one.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-create-child.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
PASS=0 FAIL=0

ck() { # ck <label> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — expected [$2] got [$3]"; fi
}
ck_has() { # ck_has <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 — missing [$2]"; fi
}
ck_lacks() { # ck_lacks <label> <needle> <haystack-file>
  if grep -qF -- "$2" "$3"; then FAIL=$((FAIL+1)); echo "FAIL: $1 — unexpected [$2]"; else PASS=$((PASS+1)); fi
}

FIX="$WORK/fix"
mkdir -p "$FIX" "$WORK/bin" "$WORK/home"

cat > "$FIX/labels-plain.json" <<'EOF'
{"labels":[{"name":"needs decision"},{"name":"specified"},{"name":"keeper"},{"name":"bug"},{"name":"sentry"},{"name":"dependencies"}]}
EOF
cat > "$FIX/labels-ambiguous.json" <<'EOF'
{"labels":[{"name":"needs decision"},{"name":"needs-decision"},{"name":"specified"}]}
EOF

cat > "$FIX/q-transport.json" <<'EOF'
[
{"id":"ae0deaa5-11fb-4057-b48c-f361ea67cc02","identifier":"BF-2417","priority":3,"state":{"name":"Done"},"title":"Transaction access Invite and Edit forms show the raw 403 transport text after the coordinator's grant narrows"},
{"id":"c3813d54-faba-46db-a7f1-30f638cf6f6d","identifier":"BF-3306","priority":3,"state":{"name":"Backlog"},"title":"Add Approval Organization shows raw transport text for a lost response or a denial while the form is open"},
{"id":"cb67afa5-9eaf-4e0e-9e68-4df4260e0751","identifier":"BF-3310","priority":3,"state":{"name":"Backlog"},"title":"Transaction-level dialogs show raw transport text for a lost or denied save and never re-read the page"},
{"id":"57935ff2-189d-42e3-903f-41213a50918f","identifier":"BF-3314","priority":3,"state":{"name":"Planned"},"title":"Two hooks bind page-owned failure copy and disagree on re-reading after the form is left"}
]
EOF
cat > "$FIX/q-prior.json" <<'EOF'
[{"id":"ae0deaa5-11fb-4057-b48c-f361ea67cc02","identifier":"BF-2417","priority":3,"state":{"name":"Done"},"title":"Transaction access Invite and Edit forms show the raw 403 transport text after the coordinator's grant narrows"}]
EOF
cat > "$FIX/recent-incident.json" <<'EOF'
{"data":{"issues":{"nodes":[{"createdAt":"2026-11-15T05:46:17.009Z","identifier":"BF-3306"},{"createdAt":"2026-11-15T05:47:52.512Z","identifier":"BF-3310"}]}}}
EOF
cat > "$FIX/recent-empty.json" <<'EOF'
{"data":{"issues":{"nodes":[]}}}
EOF
cat > "$FIX/ratelimited.err" <<'EOF'
{"code":4,"details":{"errors":[{"extensions":{"code":"RATELIMITED","statusCode":429,"type":"ratelimited"},"message":"Rate limit exceeded. Only 2500 requests are allowed per 1 hour."}]},"error":true,"message":"HTTP 400 Bad Request","retry_after":null}
EOF

# The shim logs each invocation as pipe-joined args (spaces inside one arg stay visible).
# LABELS_FIX selects the workspace label fixture per case; STATE_FIX is the state `issues get`
# reports back and PARENT_FIX the parent it reports. `search issues <q>` answers $FIX/q-<q>.json
# (an empty array when absent), or the rate-limit envelope on stderr for q=ratelimited. The
# `api query` carrying `since=` is the recent-filings read (RECENT_FIX; RECENT_FAIL=1 fails it);
# any other `api query` is the parent-chain read, answered with a one-deep chain.
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
LOG="$WORK/calls.log"
printf '%s\n' "\$(IFS='|'; printf '%s' "\$*")" >> "\$LOG"
case "\${1:-} \${2:-}" in
  "issues create") cat >/dev/null; printf '{"identifier":"TT-9"}\n' ;;
  "issues get")    printf '{"identifier":"TT-9","state":{"name":"%s"},"parent":{"identifier":"%s"}}\n' "\${STATE_FIX:-Backlog}" "\${PARENT_FIX:-}" ;;
  "labels list")   cat "\${LABELS_FIX:?}" ;;
  "labels create") exit 0 ;;
  "issues update") exit 0 ;;
  "relations parent") exit 0 ;;
  "search issues")
    if [ "\${3:-}" = ratelimited ]; then cat "$FIX/ratelimited.err" >&2; exit 1; fi
    if [ -f "$FIX/q-\${3:-}.json" ]; then cat "$FIX/q-\${3:-}.json"; else echo '[]'; fi ;;
  "api query")
    case "\$*" in
      *since=*)
        [ "\${RECENT_FAIL:-0}" = 1 ] && { echo 'Error: HTTP 500 Internal Server Error' >&2; exit 1; }
        cat "\${RECENT_FIX:-$FIX/recent-empty.json}" ;;
      *) printf '{"data":{"issue":{"identifier":"%s"}}}\n' "\${PARENT_FIX:-}" ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

BODY="$WORK/body.md"
printf 'test body\n' > "$BODY"

run() { # run <labels-fixture> <label-arg> [state [leading-flag...]] — resets the call log, runs a top-level create
  local fix="$1" lab="$2" st="${3:-Backlog}"
  shift 2
  [ $# -gt 0 ] && shift
  : > "$WORK/calls.log"
  LABELS_FIX="$FIX/$fix" STATE_FIX="$st" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
    "$SCRIPT" ${1+"$@"} - TT "$st" "Title" "$BODY" "$lab" > "$WORK/out" 2> "$WORK/err"
  echo "$?"
}

echo "linear-create-child.sh label handling —"

rc=$(run labels-plain.json "needs decision")
ck "round trip: exit"            "0" "$rc"
ck "round trip: id on stdout"    "TT-9" "$(cat "$WORK/out")"
ck_has  "round trip: internal space survives to -l" "-l|needs decision" "$WORK/calls.log"
ck_lacks "round trip: nothing minted"               "labels|create"     "$WORK/calls.log"

rc=$(run labels-plain.json "needsdecision")
ck "near-miss: exit"             "0" "$rc"
ck_has  "near-miss: heals to canonical label"       "-l|needs decision" "$WORK/calls.log"
ck_has  "near-miss: NOTE names the healing"         "normalized match"  "$WORK/err"
ck_lacks "near-miss: nothing minted"                "labels|create"     "$WORK/calls.log"

# `specified` rides along so the call clears the routing gate and reaches the attach path.
rc=$(run labels-plain.json "specified,brand-new")
ck "novel: exit 2 (filed-but-unlabelled)" "2" "$rc"
ck "novel: id still on stdout"            "TT-9" "$(cat "$WORK/out")"
ck_has  "novel: WARN refuses to mint"               "does not exist — not minting" "$WORK/err"
ck_lacks "novel: nothing minted"                    "labels|create"     "$WORK/calls.log"
ck_lacks "novel: not attached"                      "-l|brand-new"      "$WORK/calls.log"
ck_has  "novel: the known label still attaches"     "-l|specified"      "$WORK/calls.log"

rc=$(run labels-ambiguous.json "needsdecision")
ck "ambiguous: exit 2 (filed-but-unlabelled)" "2" "$rc"
ck "ambiguous: id still on stdout"            "TT-9" "$(cat "$WORK/out")"
ck_has  "ambiguous: WARN names the candidates"      "several existing labels normalize" "$WORK/err"
ck_lacks "ambiguous: nothing minted"                "labels|create"     "$WORK/calls.log"
ck_lacks "ambiguous: no update sent"                "issues|update"     "$WORK/calls.log"

rc=$(run labels-plain.json " specified ")
ck "padding: exit"               "0" "$rc"
ck_has  "padding: trimmed to exact label"           "-l|specified"      "$WORK/calls.log"

rc=$(run labels-plain.json "specified, needs decision")
ck "multi: exit"                 "0" "$rc"
ck_has  "multi: first label attached"               "-l|specified"      "$WORK/calls.log"
ck_has  "multi: second label keeps its space"       "-l|needs decision" "$WORK/calls.log"

echo "linear-create-child.sh routing gate —"

# A class label routes nothing. The refusal is pre-create: no id, and the shim saw no call at all.
rc=$(run labels-plain.json "bug")
ck "unrouted: exit 1"                    "1" "$rc"
ck "unrouted: empty stdout"              "" "$(cat "$WORK/out")"
ck_has  "unrouted: stderr names the refusal"        "refusing to file UNROUTED" "$WORK/err"
ck_lacks "unrouted: nothing created"                "issues|create"     "$WORK/calls.log"

rc=$(run labels-plain.json "-")
ck "empty slot: exit 1"                  "1" "$rc"
ck "empty slot: empty stdout"            "" "$(cat "$WORK/out")"
ck_lacks "empty slot: nothing created"              "issues|create"     "$WORK/calls.log"

rc=$(run labels-plain.json "bug" Backlog --allow-unrouted)
ck "flag: exit"                          "0" "$rc"
ck "flag: id on stdout"                  "TT-9" "$(cat "$WORK/out")"
ck_has  "flag: class label attached"                "-l|bug"            "$WORK/calls.log"

# Either order with --allow-planned; Planned reaching the create proves both flags were parsed.
rc=$(run labels-plain.json "bug" Planned --allow-planned --allow-unrouted)
ck "both flags, planned first: exit"     "0" "$rc"
ck_has  "both flags, planned first: state reached the create" "--state|Planned" "$WORK/calls.log"
rc=$(run labels-plain.json "bug" Planned --allow-unrouted --allow-planned)
ck "both flags, unrouted first: exit"    "0" "$rc"
ck_has  "both flags, unrouted first: state reached the create" "--state|Planned" "$WORK/calls.log"

rc=$(run labels-plain.json "Needs-Decision")
ck "routing label by normalization: exit" "0" "$rc"
ck_has  "routing label by normalization: canonical attached" "-l|needs decision" "$WORK/calls.log"

rc=$(run labels-plain.json "sentry")
ck "producer label sentry: exit"         "0" "$rc"
ck_has  "producer label sentry: attached"           "-l|sentry"         "$WORK/calls.log"

rc=$(run labels-plain.json "dependencies")
ck "producer label dependencies: exit"   "0" "$rc"
ck_has  "producer label dependencies: attached"     "-l|dependencies"   "$WORK/calls.log"

echo "linear-create-child.sh --search create-time re-search —"

runs() { # runs <parent> <body-text> [leading-flag...] — a certified create under <parent> with the given body
  local par="$1"
  printf '%s\n' "$2" > "$WORK/sbody.md"
  shift 2
  : > "$WORK/calls.log"
  LABELS_FIX="$FIX/labels-plain.json" PARENT_FIX="$par" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
    "$SCRIPT" ${1+"$@"} "$par" BF Backlog "Title" "$WORK/sbody.md" "bug,specified" 3 > "$WORK/out" 2> "$WORK/err"
  echo "$?"
}

rc=$(RECENT_FIX="$FIX/recent-incident.json" runs BF-3302 "Account forms show raw transport text." --search transport)
ck "race: exit 5"                        "5" "$rc"
ck "race: empty stdout"                  "" "$(cat "$WORK/out")"
ck_lacks "race: nothing created"                    "issues|create"     "$WORK/calls.log"
ck_has  "race: names the first sibling"             "BF-3306 | Backlog |" "$WORK/err"
ck_has  "race: names the second sibling"            "BF-3310 | Backlog |" "$WORK/err"
ck_has  "race: says when it was filed"              "filed 2026-11-15T05:47:52.512Z" "$WORK/err"
ck_lacks "race: an older open hit never refuses"    "BF-3314"           "$WORK/err"
ck_lacks "race: prior art never refuses"            "BF-2417"           "$WORK/err"
ck_has  "race: the read is windowed server-side"    "since=-PT60M"      "$WORK/calls.log"
ck_has  "race: stderr names the way through"        "--seen <ID>"       "$WORK/err"

rc=$(RECENT_FIX="$FIX/recent-incident.json" runs BF-3302 "Account forms show raw transport text." --search transport --seen BF-3306 --seen bf-3310)
ck "seen: exit 0"                        "0" "$rc"
ck "seen: id on stdout"                  "TT-9" "$(cat "$WORK/out")"
ck_has  "seen: created"                             "issues|create"     "$WORK/calls.log"

rc=$(RECENT_FIX="$FIX/recent-incident.json" runs BF-3302 "Same mechanism as BF-3310, at the account forms." --search transport --seen BF-3306)
ck "named in body: exit 0"               "0" "$rc"
ck_has  "named in body: created"                    "issues|create"     "$WORK/calls.log"

rc=$(RECENT_FIX="$FIX/recent-incident.json" runs BF-3310 "Follow-up at the account forms." --search transport --seen BF-3306)
ck "parent acknowledged: exit 0"         "0" "$rc"
ck_has  "parent acknowledged: created"              "issues|create"     "$WORK/calls.log"

rc=$(RECENT_FIX="$FIX/recent-incident.json" runs BF-3302 "Account forms show raw transport text." --search transport --seen BF-3306)
ck "one sibling left: exit 5"            "5" "$rc"
ck_has  "one sibling left: names it"                "BF-3310 | Backlog |" "$WORK/err"
ck_lacks "one sibling left: the seen one is quiet"  "BF-3306 |"         "$WORK/err"

rc=$(runs BF-3302 "Account forms show raw transport text." --search transport)
ck "no recent filings: exit 0"           "0" "$rc"
ck_has  "no recent filings: created"                "issues|create"     "$WORK/calls.log"

rc=$(runs BF-3302 "Account forms." --search prior)
ck "prior art only: exit 0"              "0" "$rc"
ck_lacks "prior art only: no recent read"           "since="            "$WORK/calls.log"

rc=$(RECENT_FIX="$FIX/recent-incident.json" LINEAR_CREATE_RECENT_MIN=15 runs BF-3302 "Account forms." --search transport)
ck "window override: exit 5"             "5" "$rc"
ck_has  "window override: carried to the read"      "since=-PT15M"      "$WORK/calls.log"

rc=$(LINEAR_CREATE_RECENT_MIN=0 runs BF-3302 "Account forms." --search transport)
ck "bad window: exit 1"                  "1" "$rc"
ck_lacks "bad window: no search"                    "search|issues"     "$WORK/calls.log"

rc=$(runs BF-3302 "Account forms." --search ratelimited)
ck "search rate limited: exit 1"         "1" "$rc"
ck "search rate limited: empty stdout"   "" "$(cat "$WORK/out")"
ck_has  "search rate limited: says wait"            "wait for the hourly window" "$WORK/err"
ck_lacks "search rate limited: nothing created"     "issues|create"     "$WORK/calls.log"

rc=$(runs BF-3302 "Account forms." --search "raw transport")
ck "phrase token: exit 1"                "1" "$rc"
ck_lacks "phrase token: nothing created"            "issues|create"     "$WORK/calls.log"

rc=$(RECENT_FAIL=1 runs BF-3302 "Account forms." --search transport)
ck "recent read fails: exit 1"           "1" "$rc"
ck_has  "recent read fails: says why"               "could not read the issues filed" "$WORK/err"
ck_lacks "recent read fails: nothing created"       "issues|create"     "$WORK/calls.log"

rc=$(runs BF-3302 "Account forms." --search)
ck "flag without value: exit 1"          "1" "$rc"
ck_lacks "flag without value: nothing created"      "issues|create"     "$WORK/calls.log"

rc=$(runs BF-3302 "Account forms.")
ck "no --search: exit 0"                 "0" "$rc"
ck_lacks "no --search: no search ran"               "search|issues"     "$WORK/calls.log"

rc=$(RECENT_FIX="$FIX/recent-incident.json" runs BF-3302 "Account forms." --allow-unrouted --search transport --allow-planned)
ck "mixed leading flags: still refuses"  "5" "$rc"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
