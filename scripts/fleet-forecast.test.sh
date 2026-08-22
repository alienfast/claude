#!/usr/bin/env bash
# Regression suite for fleet-forecast.py. Fixture-pins the simulation: stage-first picks (Backlog
# only when no Planned/Todo is available — Urgent does not pierce stage), unlock cascades on ship,
# clean in-flight blockers assumed to finish within one mean duration, gated/uncertified blockers
# → STRANDED (gates checked across all blockers before cascading), dependency cycles → STRANDED,
# horizon cuts (past-deadline in-flight finishes, capacity vs unlocks-past-deadline UNREACHED),
# claimed/epic exclusion from the pool, POOL-DRAINED as out-of-pickable-work, the STAGE
# Planned→Backlog crossover line, hours-per-issue calibration from fleet-metrics history, estimate
# weighting, and sessions/horizon defaults from fleet-recommendation.json. The FORECAST line makes
# an empty result distinguishable from a broken run.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/fleet-forecast.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/home"
export HOME="$WORK/home"
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

run() { # run <fixture> <outfile> [extra args...]
  local fix="$1" out="$2"; shift 2
  python3 "$SCRIPT" --fixture "$fix" --me me@x.com \
    --recommendation "$WORK/no-rec.json" --history "$WORK/no-history.jsonl" "$@" > "$out" 2> "$out.err"
  echo $?
}

# ---- Fixture A: the ensemble — chains, gates, in-flight, backlog fill, claimed/epic ----
cat > "$WORK/a.json" <<'EOF'
[
 {"identifier":"TT-1","estimate":2,"priority":2,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-2"}}]}},
 {"identifier":"TT-2","estimate":2,"priority":3,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-3","estimate":1,"priority":1,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"},{"name":"needs decision"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-4"}}]}},
 {"identifier":"TT-4","estimate":3,"priority":2,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-5","estimate":2,"priority":1,"state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-6","estimate":2,"priority":2,"state":{"name":"In Progress","type":"started"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-7"}}]}},
 {"identifier":"TT-7","estimate":2,"priority":3,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-8","estimate":1,"priority":2,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-9"}}]}},
 {"identifier":"TT-9","estimate":2,"priority":2,"state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-10","estimate":2,"priority":2,"state":{"name":"Planned","type":"unstarted"},"assignee":{"email":"other@x.com"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-11","estimate":2,"priority":2,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"},{"name":"epic"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-12","estimate":2,"priority":2,"state":{"name":"In Review","type":"started"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}}
]
EOF
rc=$(run "$WORK/a.json" "$WORK/a.out" --sessions 2 --horizon-h 12 --hours-per-issue 2 --flat)
ck "A exit" 0 "$rc"
ck_has "A forecast"        "FORECAST: 2 sessions × 12.0h horizon — est. 4 ship · 0 unreached · 2 stranded — pool 6 shippable of 8 certified" "$WORK/a.out"
ck_has "A stage-first"     "PICK t=0.0h: TT-1 → s1" "$WORK/a.out"
ck_has "A backlog fill"    "PICK t=0.0h: TT-5 → s2" "$WORK/a.out"
ck_has "A unlock cascade"  "SHIP t=2.0h: TT-1 — unblocks TT-2" "$WORK/a.out"
ck_has "A pick via"        "PICK t=2.0h: TT-2 → s1 (~2.0h) (unblocked by TT-1)" "$WORK/a.out"
ck_has "A inflight"        "INFLIGHT: TT-6 [In Progress] — assumed to finish ≈t=2.0h (outside the fleet)" "$WORK/a.out"
ck_has "A inflight unlock" "PICK t=2.0h: TT-7 → s2 (~2.0h) (unblocked by TT-6)" "$WORK/a.out"
ck_has "A stranded gate"   "STRANDED: TT-4 — blocked by TT-3 [Planned] — needs decision" "$WORK/a.out"
ck_has "A stranded uncert" "STRANDED: TT-9 — blocked by TT-8 [Planned] — uncertified" "$WORK/a.out"
ck_has "A drained"         "POOL-DRAINED: t=4.0h — no pickable candidates remain (2 remain blocked); 8.0h of horizon unused" "$WORK/a.out"
ck_has "A stage line"      "STAGE: Planned/Todo NOT drained — 1 of 4 remain past the run (TT-4); first Backlog pick ≈t=0.0h" "$WORK/a.out"
ck_has "A lane"            "LANE s1: TT-1[0.0→2.0] TT-2[2.0→4.0]" "$WORK/a.out"
ck_lacks "A claimed out"   "TT-10" "$WORK/a.out"
ck_lacks "A epic out"      "TT-11" "$WORK/a.out"
ck_lacks "A inflight non-blocker suppressed" "TT-12" "$WORK/a.out"

# ---- Fixture B: Urgent Backlog does NOT pierce the stage — Planned Normal picked first ----
cat > "$WORK/b.json" <<'EOF'
[
 {"identifier":"TT-51","priority":3,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-52","priority":1,"state":{"name":"Backlog","type":"backlog"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}}
]
EOF
rc=$(run "$WORK/b.json" "$WORK/b.out" --sessions 1 --horizon-h 12 --hours-per-issue 2 --flat)
ck "B exit" 0 "$rc"
ck_has "B planned first"  "PICK t=0.0h: TT-51 → s1" "$WORK/b.out"
ck_has "B backlog second" "PICK t=2.0h: TT-52 → s1" "$WORK/b.out"
ck_has "B stage drains"   "STAGE: Planned/Todo (1 issues) drains ≈t=2.0h; first Backlog pick ≈t=2.0h" "$WORK/b.out"

# ---- Fixture C: horizon cuts — past-deadline finish, capacity vs unlocks-past-deadline ----
cat > "$WORK/c.json" <<'EOF'
[
 {"identifier":"TT-61","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-62","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-64"}}]}},
 {"identifier":"TT-63","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-64","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}}
]
EOF
rc=$(run "$WORK/c.json" "$WORK/c.out" --sessions 1 --horizon-h 3 --hours-per-issue 2 --flat)
ck "C exit" 0 "$rc"
ck_has "C late finish"    "SHIP t=4.0h: TT-62 — unblocks TT-64 (past deadline — in-flight finish)" "$WORK/c.out"
ck_has "C forecast late"  "est. 2 ship (1 past deadline)" "$WORK/c.out"
ck_has "C capacity"       "UNREACHED-CAPACITY: 1 ranked below what the run reaches — next in line: TT-63" "$WORK/c.out"
ck_has "C late unlock"    "UNREACHED: TT-64 — unlocks ≈t=4.0h — past the deadline" "$WORK/c.out"

# ---- Fixture D: dependency cycle → STRANDED, pool drained at t=0 ----
cat > "$WORK/d.json" <<'EOF'
[
 {"identifier":"TT-71","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-72"}}]}},
 {"identifier":"TT-72","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-71"}}]}}
]
EOF
rc=$(run "$WORK/d.json" "$WORK/d.out" --sessions 1 --horizon-h 12 --hours-per-issue 2 --flat)
ck "D exit" 0 "$rc"
ck_has "D cycle 71" "STRANDED: TT-71 — blocked by TT-72 — dependency cycle" "$WORK/d.out"
ck_has "D cycle 72" "STRANDED: TT-72 — blocked by TT-71 — dependency cycle" "$WORK/d.out"
ck_has "D drained"  "POOL-DRAINED: t=0.0h" "$WORK/d.out"

# ---- Calibration from history; malformed and zero-shipped rows skipped ----
cat > "$WORK/hist.jsonl" <<'EOF'
not json
{"shipped":0,"session_hours":10}
{"shipped":2,"session_hours":9}
{"shipped":3,"session_hours":9}
EOF
python3 "$SCRIPT" --fixture "$WORK/b.json" --me me@x.com --sessions 1 --horizon-h 12 --flat \
  --recommendation "$WORK/no-rec.json" --history "$WORK/hist.jsonl" > "$WORK/e.out" 2>&1
ck_has "E calibrated" "HOURS-PER-ISSUE: 3.75 (calibrated from 2 fleet runs in $WORK/hist.jsonl)" "$WORK/e.out"
rc=$(run "$WORK/b.json" "$WORK/f.out" --sessions 1 --horizon-h 12 --flat)
ck "F default exit" 0 "$rc"
ck_has "F default base" "HOURS-PER-ISSUE: 2.0 (default — no usable fleet history)" "$WORK/f.out"

# ---- Estimate weighting: base 2, estimates 1 and 3 (mean 2) → 1.0h and 3.0h ----
cat > "$WORK/g.json" <<'EOF'
[
 {"identifier":"TT-81","estimate":1,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}},
 {"identifier":"TT-82","estimate":3,"state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}}
]
EOF
rc=$(run "$WORK/g.json" "$WORK/g.out" --sessions 2 --horizon-h 12 --hours-per-issue 2)
ck "G exit" 0 "$rc"
ck_has "G light issue" "PICK t=0.0h: TT-81 → s1 (~1.0h)" "$WORK/g.out"
ck_has "G heavy issue" "PICK t=0.0h: TT-82 → s2 (~3.0h)" "$WORK/g.out"

# ---- Defaults from fleet-recommendation.json; hard error when neither source names a count ----
cat > "$WORK/rec.json" <<'EOF'
{"sessions":3,"duration_h":6}
EOF
python3 "$SCRIPT" --fixture "$WORK/b.json" --me me@x.com --hours-per-issue 2 --flat \
  --recommendation "$WORK/rec.json" --history "$WORK/no-history.jsonl" > "$WORK/h.out" 2>&1
ck_has "H rec defaults" "FORECAST: 3 sessions × 6.0h horizon" "$WORK/h.out"
python3 "$SCRIPT" --fixture "$WORK/b.json" --me me@x.com \
  --recommendation "$WORK/no-rec.json" --history "$WORK/no-history.jsonl" > "$WORK/i.out" 2> "$WORK/i.err"
ck "I no-count exit" 1 "$?"
ck_has "I no-count error" "no --sessions and no usable tmp/fleet-recommendation.json" "$WORK/i.err"

# ---- An In Review blocker is completed-in-substance: dependent free at t=0, no in-flight modeling ----
cat > "$WORK/k.json" <<'EOF'
[
 {"identifier":"TT-95","state":{"name":"In Review","type":"started"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[{"type":"blocks","relatedIssue":{"identifier":"TT-96"}}]}},
 {"identifier":"TT-96","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[{"name":"specified"}]},"relations":{"nodes":[]}}
]
EOF
rc=$(run "$WORK/k.json" "$WORK/k.out" --sessions 1 --horizon-h 12 --hours-per-issue 2 --flat)
ck "K exit" 0 "$rc"
ck_has "K dependent free at t=0" "PICK t=0.0h: TT-96 → s1 (~2.0h)" "$WORK/k.out"
ck_lacks "K no inflight modeling" "INFLIGHT" "$WORK/k.out"
ck_lacks "K in-review blocker absent" "TT-95" "$WORK/k.out"

# ---- Empty pool is distinguishable from a broken run ----
cat > "$WORK/j.json" <<'EOF'
[
 {"identifier":"TT-91","state":{"name":"Planned","type":"unstarted"},"labels":{"nodes":[]},"relations":{"nodes":[]}}
]
EOF
rc=$(run "$WORK/j.json" "$WORK/j.out" --sessions 2 --horizon-h 12 --hours-per-issue 2 --flat)
ck "J exit" 0 "$rc"
ck_has "J empty verdict" "est. 0 ship · 0 unreached · 0 stranded — pool 0 shippable of 0 certified" "$WORK/j.out"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
