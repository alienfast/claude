#!/usr/bin/env bash
# Regression suite for linear-remove-label.sh. Pins the exit contract around its verification read: Linear's label
# reads lag behind writes, so a read that still lists the removed label, or is missing one the helper meant to keep,
# is "could not confirm" (exit 2) and never a claim about a cause the helper cannot see — the messages once said the
# label "is still on" the issue and that the removal "dropped other labels … Re-add them manually", and a session
# reported two landed removals as failures on the strength of the first. Also pins the read-filter-set write, the
# last-label raw mutation, the already-absent no-op, and that a failing read never ends the script with linear-cli's
# own exit code. linear-cli is a PATH shim that logs every invocation; HOME is an empty dir so the script's cargo-bin
# PATH prepend cannot resurrect the real CLI.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/linear-remove-label.sh"
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

mkdir -p "$WORK/bin" "$WORK/home"

# READS scripts successive `issues get` answers, comma-separated, the last one repeating: a `+`-joined label set
# (`-` for none), or `!N` to exit N. UPDATE_RC is the exit code of `issues update`, MUTATE_RC of `api mutate`.
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
  "issues update") exit "${UPDATE_RC:-0}" ;;
  "api mutate")    exit "${MUTATE_RC:-0}" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$WORK/bin/linear-cli"

run() { # run <label> — resets the call log and removes <label> from TT-1 under the caller's READS
  : > "$WORK/calls.log"
  SHIM_LOG="$WORK/calls.log" HOME="$WORK/home" PATH="$WORK/bin:$PATH" \
    "$SCRIPT" TT-1 "$1" > "$WORK/out" 2> "$WORK/err"
  echo "$?"
}
writes() { grep -c -e '^issues|update' -e '^api|mutate' "$WORK/calls.log"; }

echo "linear-remove-label.sh the write —"

rc=$(READS='specified+needs decision+bug,specified+bug' run 'needs decision')
ck "confirmed: exit 0"                           "0" "$rc"
ck "confirmed: silent"                           "" "$(cat "$WORK/err")"
ck_has  "confirmed: the rest of the set is re-sent"            "issues|update|TT-1|-l|specified|-l|bug" "$WORK/calls.log"

rc=$(READS='Specified+bug,bug' run specified)
ck "case-insensitive match: exit 0"              "0" "$rc"
ck_has  "case-insensitive match: only the other label is sent" "issues|update|TT-1|-l|bug" "$WORK/calls.log"

rc=$(READS='specified+bug' run 'needs decision')
ck "already absent: exit 0"                      "0" "$rc"
ck "already absent: no write"                    "0" "$(writes)"

rc=$(READS='simple,-' run simple)
ck "last label: exit 0"                          "0" "$rc"
ck_has  "last label: cleared by the raw mutation"              "api|mutate" "$WORK/calls.log"
ck_lacks "last label: no flag-less update"                      "issues|update" "$WORK/calls.log"

rc=$(UPDATE_RC=1 READS='specified+bug' run bug)
ck "update fails: exit 2"                        "2" "$rc"
ck_has  "update fails: says the labels are unchanged"          "Labels unchanged" "$WORK/err"

echo "linear-remove-label.sh the verification read —"

rc=$(READS='specified+needs decision' run 'needs decision')
ck "read still lists it: exit 2"                 "2" "$rc"
ck "read still lists it: one write, no retry"    "1" "$(writes)"
ck_has  "read still lists it: says could not confirm"          "could not confirm 'needs decision' was removed from TT-1" "$WORK/err"
ck_has  "read still lists it: unconfirmed, not failed"         "Unconfirmed, not failed" "$WORK/err"
ck_has  "read still lists it: points at the gotcha"            "gotcha #17" "$WORK/err"
ck_lacks "read still lists it: no claim it is still on"         "is still on" "$WORK/err"
ck_lacks "read still lists it: no guess at a second writer"     "concurrent modification" "$WORK/err"

rc=$(READS='specified+needs decision+bug,specified' run 'needs decision')
ck "read misses a kept label: exit 2"            "2" "$rc"
ck_has  "read misses a kept label: says could not confirm"     "could not confirm TT-1 kept its other labels after removing 'needs decision'" "$WORK/err"
ck_has  "read misses a kept label: names what the read lacks"  "missing [bug]" "$WORK/err"
ck_has  "read misses a kept label: unconfirmed, not failed"    "Unconfirmed, not failed" "$WORK/err"
ck_lacks "read misses a kept label: no claim the write dropped it" "dropped other labels" "$WORK/err"
ck_lacks "read misses a kept label: prescribes no re-add"       "Re-add them manually" "$WORK/err"

# linear-cli exits 4 on a rate limit; the helper's own codes are 0, 1 and 2.
rc=$(READS='specified+bug,!4' run bug)
ck "verification read fails: exit 2"             "2" "$rc"
ck_has  "verification read fails: says so"                     "the verification re-read failed" "$WORK/err"

rc=$(READS='!4' run bug)
ck "first read fails: exit 1"                    "1" "$rc"
ck "first read fails: no write"                  "0" "$(writes)"

echo "linear-remove-label.sh usage —"

rc=$(READS='-' run '-l')
ck "label starting with a dash: exit 1"          "1" "$rc"
ck "label starting with a dash: nothing called"  "" "$(cat "$WORK/calls.log")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
