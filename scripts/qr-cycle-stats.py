#!/usr/bin/env python3
"""Aggregate /quality-review reviewer-dispatch counts per issue across session transcripts,
split by auto vs interactive, to answer "are auto runs burning more review cycles?".

Parses assistant tool_use blocks only — raw grep overcounts badly, because SKILL.md template
text (PL-13 placeholders, lifecycle-tag vocabularies) is injected into transcripts as
documentation. Counts are reviewer DISPATCHES, not cycles: a multi-domain review spawns
parallel domain-scoped reviewers, so dispatches >= cycles. Per-issue exact cycle counts live
in each run's verdict file (`Cycles:` line) and /finish completion comment; this script is
the cross-run rollup those per-issue records don't give you.

Usage: qr-cycle-stats.py <project-slug-substring> [worktree-dir-substring]
  e.g.  qr-cycle-stats.py basefund           # aggregate + per-issue table
        qr-cycle-stats.py basefund bf-470    # also dump that dir's dispatch sequence
"""
import json
import re
import sys
from pathlib import Path

PROJ = Path.home() / ".claude" / "projects"
INIT_RE = re.compile(r"Task for quality-reviewer: Adversarial implementation review for ([A-Z]+-\d+)")
# BF-576 moved re-reviews and confirmations to the quality-verifier agent; transcripts from before it carry quality-reviewer.
REREV_RE = re.compile(r"Task for quality-(?:reviewer|verifier): Adversarial re-review of fixes for ([A-Z]+-\d+)")
CONF_RE = re.compile(r"Task for quality-(?:reviewer|verifier): Targeted fix confirmation for ([A-Z]+-\d+)")
FIX_RE = re.compile(r"Task for developer: Fix review findings for ([A-Z]+-\d+)")

if len(sys.argv) < 2:
    sys.exit(f"usage: {Path(sys.argv[0]).name} <project-slug-substring> [worktree-dir-substring]")
project = sys.argv[1]
detail_target = sys.argv[2] if len(sys.argv) > 2 else None

sessions = {}
issues = {}
detail_lines = []

for f in sorted(PROJ.glob(f"*{project}*/*.jsonl")):
    s = {"init": 0, "rerev": 0, "conf": 0, "auto": False, "plan": False, "issues": set()}
    is_detail = detail_target and detail_target in str(f.parent)
    with open(f, errors="replace") as fh:
        for line in fh:
            if "command-name>/auto<" in line:
                s["auto"] = True
            try:
                ev = json.loads(line)
            except json.JSONDecodeError:
                continue
            if ev.get("isSidechain"):
                continue
            content = (ev.get("message") or {}).get("content")
            if not isinstance(content, list):
                continue
            for blk in content:
                if not isinstance(blk, dict) or blk.get("type") != "tool_use":
                    continue
                name = blk.get("name", "")
                inp = blk.get("input") or {}
                if name == "ExitPlanMode":
                    s["plan"] = True
                elif name == "Skill":
                    if inp.get("skill") == "auto" or str(inp.get("args", "")).strip().startswith("auto"):
                        s["auto"] = True
                elif name in ("Agent", "Task"):
                    prompt = str(inp.get("prompt", ""))
                    m = INIT_RE.search(prompt)
                    kind = "init" if m else None
                    if not m:
                        m = REREV_RE.search(prompt)
                        kind = "rerev" if m else None
                    if not m:
                        m = CONF_RE.search(prompt)
                        kind = "conf" if m else None
                    if m:
                        s[kind] += 1
                        key = m.group(1)
                        s["issues"].add(key)
                        rec = issues.setdefault(key, {"init": 0, "rerev": 0, "conf": 0, "classes": set(), "files": set()})
                        rec[kind] += 1
                        rec["files"].add(f.name[:8])
                    if is_detail:
                        fm = FIX_RE.search(prompt)
                        ts = (ev.get("timestamp") or "")[5:16]
                        if m:
                            detail_lines.append(f"{ts}  {kind.upper():5s} {m.group(1)}")
                        elif fm:
                            findings = prompt.split("Findings:", 1)[-1][:300].replace("\n", " | ")
                            detail_lines.append(f"{ts}  FIX   {fm.group(1)}: {findings}")
    if s["init"] or s["rerev"] or s["conf"]:
        cls = "AUTO" if s["auto"] else ("INTER" if s["plan"] else "OTHER")
        sessions[f.name[:8]] = s | {"cls": cls, "dir": f.parent.name[-12:]}
        for key in s["issues"]:
            issues[key]["classes"].add(cls)

print(f"{'SESSION':10s} {'DIR':>12s} {'CLASS':5s} {'init':>4s} {'rerev':>5s} {'conf':>4s}  issues")
for name, s in sessions.items():
    print(f"{name:10s} {s['dir']:>12s} {s['cls']:5s} {s['init']:4d} {s['rerev']:5d} {s['conf']:4d}  {','.join(sorted(s['issues']))}")

agg = {}
for rec in issues.values():
    cls = "AUTO" if "AUTO" in rec["classes"] else ("INTER" if "INTER" in rec["classes"] else "OTHER")
    a = agg.setdefault(cls, [0, 0, 0, 0])
    a[0] += 1
    a[1] += rec["init"]
    a[2] += rec["rerev"]
    a[3] += rec["conf"]

print("\nPer-issue reviewer dispatches (init + re-review; parallel domain reviewers count each; conf = targeted fix confirmations, not cycles):")
for key, rec in sorted(issues.items(), key=lambda kv: -(kv[1]["init"] + kv[1]["rerev"]))[:15]:
    cls = "AUTO" if "AUTO" in rec["classes"] else ("INTER" if "INTER" in rec["classes"] else "OTHER")
    conf = f" conf={rec['conf']}" if rec["conf"] else ""
    print(f"  {key:8s} {cls:5s} dispatches={rec['init'] + rec['rerev']:2d} (init={rec['init']}, rerev={rec['rerev']}){conf} sessions={len(rec['files'])}")

print("\nAggregate by class (issue-level; avg excludes conf — confirmations are deliberately not cycles):")
for cls, (n, ni, nr, nc) in sorted(agg.items()):
    print(f"  {cls:5s} issues={n:3d}  reviewer-dispatches={ni + nr:3d}  confirmations={nc:3d}  avg dispatches/issue={(ni + nr) / n:.2f}")

if detail_lines:
    print(f"\n--- dispatch sequence for {detail_target} ---")
    for line in detail_lines:
        print(line)
