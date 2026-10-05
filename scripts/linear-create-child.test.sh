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
# unless the call passes the leading --allow-unrouted. linear-cli is a PATH shim that logs every
# invocation; HOME is an empty dir so the script's cargo-bin PATH prepend cannot resurrect the real CLI.
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

# The shim logs each invocation as pipe-joined args (spaces inside one arg stay visible) and
# answers the four subcommands the label path exercises. LABELS_FIX selects the workspace
# label fixture per case; STATE_FIX is the state `issues get` reports back.
cat > "$WORK/bin/linear-cli" <<EOF
#!/bin/bash
LOG="$WORK/calls.log"
printf '%s\n' "\$(IFS='|'; printf '%s' "\$*")" >> "\$LOG"
case "\${1:-} \${2:-}" in
  "issues create") cat >/dev/null; printf '{"identifier":"TT-9"}\n' ;;
  "issues get")    printf '{"identifier":"TT-9","state":{"name":"%s"}}\n' "\${STATE_FIX:-Backlog}" ;;
  "labels list")   cat "\${LABELS_FIX:?}" ;;
  "labels create") exit 0 ;;
  "issues update") exit 0 ;;
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

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
