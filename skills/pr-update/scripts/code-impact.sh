#!/bin/bash
# Categorized Code Impact table for a PR, reconciled against the raw numstat it was built from.
#
# Usage:  code-impact.sh <base> [<head>]      diffs "<base>...<head>", <head> defaults to HEAD
#
# Lives in a script rather than inline in SKILL.md because the Skill tool rewrites every literal dollar-digit
# token of a SKILL.md body from the invocation arguments at load time (measured: the former inline block
# rendered as `s+=existing+PR`), and because a shell one-liner expands awk's field references away. Neither
# touches a file called by path. The reconciliation is a total check only — it proves code-impact.awk resolved
# and ran, not that any one bucket is right.
set -euo pipefail

BASE="${1:?usage: code-impact.sh <base> [<head>]}"
HEAD_REF="${2:-HEAD}"
AWK="$(cd "$(dirname "$0")" && pwd)/code-impact.awk"

numstat="$(git diff --numstat -M -l0 "$BASE...$HEAD_REF")"
impact="$(printf '%s\n' "$numstat" | awk -f "$AWK")"
expected="$(printf '%s\n' "$numstat" | awk '$3 ~ /lock\.yaml$|lock\.json$|\.lock$/ {next} {s+=$1+$2} END{print s+0}')"
got="$(printf '%s\n' "$impact" | awk '/^TOTAL/{print $2+$3}')"

if [[ "${expected:-0}" -gt 0 && "${got:-0}" -ne "${expected:-0}" ]]; then
  echo "ERROR: Code Impact total ($got) does not reconcile with the diff ($expected) — check that $AWK exists and ran." >&2
  exit 1
fi
printf '%s\n' "$impact"
