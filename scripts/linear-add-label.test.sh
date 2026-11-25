#!/usr/bin/env bash
# Regression suite for linear-add-label.sh. Pins the exit contract around its verification read: Linear's label reads
# lag behind writes, so a read missing a label the helper sent is "could not confirm" (exit 2), worded as that and not
# as a guess at a second writer — the message once said the set "may have been modified concurrently", which
# skills/linear/references/labels.md had to translate for every caller. Also pins the read-merge-set write, the
# probe-free no-op, the near-miss healing that never mints, the ambiguous near-miss refusal, and that a failing read
# never ends the script with linear-cli's own exit code. linear-cli is a PATH shim that logs every invocation; HOME is
# an empty dir so the script's cargo-bin PATH prepend cannot resurrect the real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-add-label.sh"
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

# The `labels list -t issue -o json` shape: a bare array of {color, id, name, parent}.
cat > "$FIX/labels-plain.json" <<'EOF'
[{"color":"#eb5757","id":"l-1","name":"needs decision","parent":null},{"color":"#4cb782","id":"l-2","name":"specified","parent":null},{"color":"#f2c94c","id":"l-3","name":"bug","parent":null},{"color":"#95a2b3","id":"l-4","name":"simple","parent":null}]
EOF
cat > "$FIX/labels-ambiguous.json" <<'EOF'
[{"color":"#eb5757","id":"l-1","name":"needs decision","parent":null},{"color":"#eb5757","id":"l-5","name":"needs-decision","parent":null},{"color":"#4cb782","id":"l-2","name":"specified","parent":null}]
EOF

# READS scripts successive `issues get` answers, comma-separated, the last one repeating: a `+`-joined label set
# (`-` for none), or `!N` to exit N. LABELS_FIX is the workspace label list; UPDATE_RC the exit code of `issues update`.
cat > "$WORK/bin/linear-cli" <<'EOF'
#!/bin/bash
LOG="${SHIM_LOG:?}"
printf '%s\n' "$(IFS='|'; printf '%s' "$*")" >> "$LOG"
case "${1:-} ${2:-}" in
  "issues get")
    IFS=, read -ra reads <<< "${READS:?}"
    i=$(( $(grep -c '^issues|get' "$LOG") - 1 ))
    [ "$i" -ge "${#reads[@]}" ] && i=$(( ${#reads[@]} - 1 ))
    set="${reads[$i]}"
    case "$set" in '!'*) exit "${set#!}" ;; esac
    nodes=""
    if [ "$set" != "-" ]; then
      IFS=+ read -ra names <<< "$set"
      for n in "${names[@]}"; do nodes="$nodes${nodes:+,}{\"color\":\"#000000\",\"name\":\"$n\"}"; done
    fi
    printf '{"id":"u-1","identifier":"%s","labels":{"nodes":[%s]}}\n' "${3:-}" "$nodes" ;;
  "labels list")   cat "${LABELS_FIX:?}" ;;
  "issues update") exit "${UPDATE_RC:-0}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

run() { # run <label> — resets the call log and adds <label> to TT-1 under the caller's READS
  : > "$WORK/calls.log"
  SHIM_LOG="$WORK/calls.log" LABELS_FIX="${LABELS_FIX:-$FIX/labels-plain.json}" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
    "$SCRIPT" TT-1 "$1" > "$WORK/out" 2> "$WORK/err"
  echo "$?"
}
writes() { grep -c '^issues|update' "$WORK/calls.log"; }

echo "linear-add-label.sh the write —"

rc=$(READS='bug,bug+specified' run specified)
ck "confirmed: exit 0"                           "0" "$rc"
ck "confirmed: silent"                           "" "$(cat "$WORK/err")"
ck_has  "confirmed: the current set is re-sent with the new label" "issues|update|TT-1|-l|bug|-l|specified" "$WORK/calls.log"

rc=$(READS='bug+specified' run specified)
ck "already present: exit 0"                     "0" "$rc"
ck "already present: no write"                   "0" "$(writes)"
ck_lacks "already present: no workspace probe"                  "labels|list" "$WORK/calls.log"

rc=$(READS='bug,bug+specified' run Specified)
ck "case differs: exit 0"                        "0" "$rc"
ck_has  "case differs: the workspace's casing is sent"         "-l|specified" "$WORK/calls.log"

rc=$(READS='bug,bug+needs decision' run needsdecision)
ck "near-miss: exit 0"                           "0" "$rc"
ck_has  "near-miss: heals to the existing label"               "-l|needs decision" "$WORK/calls.log"
ck_has  "near-miss: NOTE names the healing"                    "normalized match" "$WORK/err"

rc=$(READS='needs decision' run needsdecision)
ck "near-miss already on the issue: exit 0"      "0" "$rc"
ck "near-miss already on the issue: no write"    "0" "$(writes)"

rc=$(LABELS_FIX="$FIX/labels-ambiguous.json" READS='bug' run needsdecision)
ck "ambiguous near-miss: exit 2"                 "2" "$rc"
ck "ambiguous near-miss: no write"               "0" "$(writes)"
ck_has  "ambiguous near-miss: names the candidates"            "several existing labels normalize" "$WORK/err"

rc=$(UPDATE_RC=1 READS='bug' run brand-new)
ck "attach fails: exit 2"                        "2" "$rc"
ck_has  "attach fails: says the existing labels stand"         "Existing labels were preserved" "$WORK/err"
ck_lacks "attach fails: nothing minted"                         "labels|create" "$WORK/calls.log"

echo "linear-add-label.sh the verification read —"

rc=$(READS='bug' run specified)
ck "read lacks the new label: exit 2"            "2" "$rc"
ck "read lacks the new label: one write, no retry" "1" "$(writes)"
ck_has  "read lacks the new label: says could not confirm"     "could not confirm the label set on TT-1 after attaching 'specified'" "$WORK/err"
ck_has  "read lacks the new label: names what the read lacks"  "missing [specified]" "$WORK/err"
ck_has  "read lacks the new label: unconfirmed, not failed"    "Unconfirmed, not failed" "$WORK/err"
ck_has  "read lacks the new label: points at the gotcha"       "gotcha #17" "$WORK/err"
ck_lacks "read lacks the new label: no guess at a second writer" "modified concurrently" "$WORK/err"

rc=$(READS='bug+simple,bug+specified' run specified)
ck "read lacks a kept label: exit 2"             "2" "$rc"
ck_has  "read lacks a kept label: names it"                    "missing [simple]" "$WORK/err"
ck_has  "read lacks a kept label: unconfirmed, not failed"     "Unconfirmed, not failed" "$WORK/err"

# linear-cli exits 4 on a rate limit; the helper's own codes are 0, 1 and 2.
rc=$(READS='bug,!4' run specified)
ck "verification read fails: exit 2"             "2" "$rc"
ck_has  "verification read fails: says so"                     "the verification re-read failed" "$WORK/err"

rc=$(READS='!4' run specified)
ck "first read fails: exit 1"                    "1" "$rc"
ck "first read fails: no write"                  "0" "$(writes)"

echo "linear-add-label.sh usage —"

rc=$(READS='-' run '-l')
ck "label starting with a dash: exit 1"          "1" "$rc"
ck "label starting with a dash: nothing called"  "" "$(cat "$WORK/calls.log")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
