#!/usr/bin/env bash
# Regression suite for fleet-headroom.sh.
#
# Fixture entries carry the REAL transcript row shape (timestamp + message.usage.output_tokens +
# requestId) so the jq extraction is pinned against what the harness actually writes. The suite's
# clock is fixed via --now; the window boundary, the requestId dedup, the calibration fallback chain,
# and the fail-open error path are each pinned by a case.

set -uo pipefail
SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fleet-headroom.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
NOW=1787000000   # fixed epoch; entries are stamped relative to it

PROJ="$TMP/projects/-tmp-repo"
mkdir -p "$PROJ"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%S.000Z; }

row() { # <epoch> <requestId> <output_tokens>
  printf '{"type":"assistant","timestamp":"%s","requestId":"%s","message":{"role":"assistant","usage":{"output_tokens":%s}}}\n' "$(iso "$1")" "$2" "$3"
}

t() { # <name> <want-exit> <want-substr> <args...>
  local name="$1" want_rc="$2" want_sub="$3"; shift 3
  local out rc
  out=$("$SCRIPT" --projects-dir "$TMP/projects" --now "$NOW" "$@" 2>&1); rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q "$want_sub"; then
    echo "  PASS  $name"; PASS=$((PASS+1))
  else
    echo "  FAIL  $name — want rc=$want_rc match='$want_sub', got rc=$rc: $(head -1 <<<"$out")"; FAIL=$((FAIL+1))
  fi
}

echo "fleet-headroom.sh"

# 100k in-window + 999k OUT of window (>5h ago) → trailing = 100k, huge headroom.
{ row $(( NOW - 600 ))   req-a 60000
  row $(( NOW - 1200 ))  req-b 40000
  row $(( NOW - 19000 )) req-old 999000; } > "$PROJ/s1.jsonl"
touch "$PROJ/s1.jsonl"
t "window boundary: old burn excluded"        0 'trailing-5h=100000' --ceiling 1500000

# Same requestId mirrored into a second transcript counts once; a no-requestId row always counts.
{ row $(( NOW - 600 )) req-a 60000
  printf '{"type":"assistant","timestamp":"%s","message":{"role":"assistant","usage":{"output_tokens":5000}}}\n' "$(iso $(( NOW - 700 )))"; } > "$PROJ/s2.jsonl"
touch "$PROJ/s2.jsonl"
t "requestId dedup across files (+bare row)"  0 'trailing-5h=105000' --ceiling 1500000

# Reserve gate: ceiling 160k vs trailing 105k → headroom 55k < 250k reserve → THROTTLE, exit 2.
t "throttle when headroom < reserve"          2 'THROTTLE' --ceiling 160000

# Reserve is tunable: 50k reserve fits in the same 55k headroom → PICK-OK.
t "reserve flag respected"                    0 'PICK-OK' --ceiling 160000 --reserve 50000

# Calibration file supplies the ceiling when no flag is passed.
printf '{"ceiling_output_tokens": 170000}\n' > "$TMP/cal.json"
t "calibration file read"                     2 'ceiling=170000(calibration)' --calibration "$TMP/cal.json"

# Missing calibration file → conservative default, named as such.
t "default ceiling when uncalibrated"         0 'ceiling=1500000(default)' --calibration "$TMP/nope.json"

# A malformed line must not abort the sum (fromjson? tolerance).
printf 'NOT JSON AT ALL\n' >> "$PROJ/s1.jsonl"
touch "$PROJ/s1.jsonl"
t "malformed transcript line tolerated"       0 'trailing-5h=105000' --ceiling 1500000

# Empty projects dir → zero burn, pick OK (a fresh machine must not throttle).
mkdir -p "$TMP/empty"
out=$("$SCRIPT" --projects-dir "$TMP/empty" --now "$NOW" --ceiling 1500000 2>&1); rc=$?
if [ "$rc" = "0" ] && printf '%s' "$out" | grep -q 'trailing-5h=0'; then
  echo "  PASS  empty projects dir → pick OK"; PASS=$((PASS+1))
else
  echo "  FAIL  empty projects dir → pick OK — got rc=$rc: $out"; FAIL=$((FAIL+1))
fi

# --json emits the machine shape /auto reads.
out=$("$SCRIPT" --projects-dir "$TMP/projects" --now "$NOW" --ceiling 1500000 --json 2>/dev/null)
if printf '%s' "$out" | jq -e '.pick_ok == true and .trailing_5h_output == 105000' >/dev/null 2>&1; then
  echo "  PASS  json shape"; PASS=$((PASS+1))
else
  echo "  FAIL  json shape — got: $out"; FAIL=$((FAIL+1))
fi

echo ""
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
