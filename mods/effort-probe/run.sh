#!/usr/bin/env bash
# run.sh — one scripted `claude -p` conversation of four model requests (three chained Reads and the answer),
# with the effort-probe mod loaded. Mode `switch` rewrites the second request's effort to `low`; `control` leaves
# every request alone. Compare the two ledgers' cache_read_input_tokens on index 1 and 2.
#
# Usage: run.sh [switch|control] [model]      model defaults to the fleet's opus[1m]
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
mode=${1:-switch}
model=${2:-opus[1m]}
mkdir -p "$root/tmp"
out="$root/tmp/effort-probe-$mode-$(date +%Y%m%dT%H%M%S).jsonl"
cd "$here/chain"
EFFORT_PROBE_MODE="$mode" EFFORT_PROBE_OUT="$out" claude -p \
  --model "$model" --effort high --plugin-dir "$here" --allowedTools Read --max-turns 8 \
  'Read the file 1.txt in this directory and follow the instruction inside it exactly, one tool call at a time.' \
  >"$out.answer" 2>"$out.stderr" || echo "claude exited $?" >&2
echo "$out"
cat "$out"
