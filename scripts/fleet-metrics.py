#!/usr/bin/env python3
"""Per-session metrics for a finished fleet of `/loop /auto` runs, so a retro measures instead of
recalling.

WHY THIS IS A SCRIPT AND NOT SKILL PROSE: the findings that mattered in the 2026-08-01 BF retro were
all quantities — blind-sleep hours, a run_in_background census, ScheduleWakeup compliance, a
517-vs-6 classifier split. Each was hand-rolled throwaway Python. Re-deriving them ad hoc every retro
means each run measures something slightly different and the numbers are not comparable across
fleets, which is where the real value is: drift. This emits a FIXED schema so two retros can be
diffed. Add columns; do not quietly change what an existing one means.

WHAT IT READS
  <checkout>/tmp/auto-state-<runKey>.json   run bookkeeping written by /auto Step 4
  ~/.claude/projects/<mangled-cwd>/*.jsonl  session transcripts, main + worktree dirs
  ~/.claude/projects/.../subagents/*.jsonl  delegated work — where classifier blocks actually land,
                                            invisible to the parent except as a slow Agent call

Sessions are discovered from state files, then matched to transcripts by runKey (a state file's key
is the leading segment of its session UUID). A session whose state file says nothing shipped may
still have shipped — that mismatch is itself a finding (BF-695), so both are reported.

Usage:
  fleet-metrics.py [--checkout DIR] [--since YYYY-MM-DD | --hours N | --all] [--json]

  --hours N   consider state files touched in the last N hours (default 36)
  --since D   consider state files touched on/after date D
  --all       every state file present
  --json      machine-readable; default is a markdown report
"""
import argparse
import json
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

PROJ = Path.home() / ".claude" / "projects"

# A wait that cannot end early. Mirrors hooks/no-blind-sleep.sh: any of these means the loop exits
# when the work does, so its duration is legitimate rather than burned. Kept deliberately generous —
# over-counting blind time would overstate the headline number this retro reports.
EARLY_EXIT = re.compile(
    r"until\s|\bbreak\b|\bif\s|\[\s*-[efsdrz]\s|\btest\s+-[efsdrz]\b"
    r"|grep\s+(-[A-Za-z]*\s+)*-[A-Za-z]*q|\bpgrep\b|(^|[;&|\n]|\bdo\s|\bthen\s)\s*wait\b"
    r"|\bcurl\b|\bnc\s|\bgh\s+run\s+watch\b"
)
SLEEP_RE = re.compile(r"(?:^|[^A-Za-z0-9_-])sleep\s+[0-9]")
QUOTED = re.compile(r"\x27[^\x27]*\x27|\"[^\"]*\"")
EXECUTOR = re.compile(r"\b(?:ba|z|k)?sh\s+-[A-Za-z]*c\b|\beval\b|\bxargs\b")
CLASSIFIER = re.compile(r"auto mode classifier|Blocked by classifier")
SHIPPED_TAG = re.compile(r"\b(SHIPPED-MERGE|SHIPPED-PR|RELEASED|DEFERRED-MERGE):\s*([A-Z]+-\d+)")
# Canceled is its own ledger, never a shipped variant: recording cancellations in shipped[] is what
# overstated the 2026-08-02 fleet's tally 29 vs 25 (skills/auto Step 4 now keeps a canceled[] list).
CANCELED_TAG = re.compile(r"\bCANCELED:\s*([A-Z]+-\d+)")
# Anchored to line start: these tags are also NAMED in prose all over skills/auto/SKILL.md and in the
# model's own reasoning about what it should emit. An unanchored match counts those discussions as
# emissions and reports a silently-dead loop as having ended cleanly.
TERMINAL_TAG = re.compile(r"^\s*(NO-CANDIDATES|AUTO-HALTED):", re.M)
LOOP_CMD = re.compile(r"<command-name>/loop</command-name>")
LOOP_AUTO_ARGS = re.compile(r"<command-args>[^<]*/auto")
GAP_MIN = 240  # seconds; a tool call slower than this is worth naming, not necessarily a fault


def ts(value):
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (ValueError, TypeError):
        return None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text")
    return ""


def result_text(block):
    c = block.get("content")
    return c if isinstance(c, str) else json.dumps(c)


def is_blind_sleep(cmd):
    """True when the command sleeps but nothing in it can cut the wait short."""
    if not SLEEP_RE.search(cmd):
        return False
    scan = cmd if EXECUTOR.search(cmd) else QUOTED.sub(" ", cmd)
    return bool(SLEEP_RE.search(scan)) and not EARLY_EXIT.search(scan)


def load(path):
    rows = []
    with path.open(errors="replace") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue  # a half-flushed final line is normal on a live session
    return rows


def scan_transcript(path, agg):
    """Fold one transcript (session or subagent) into agg. Subagents share the parent's totals on
    purpose: a classifier block inside a delegated reviewer is the parent's lost time."""
    rows = load(path)
    pending, times = {}, []
    for r in rows:
        t = ts(r.get("timestamp"))
        if t:
            times.append(t)
        msg = r.get("message")
        content = msg.get("content") if isinstance(msg, dict) else None

        if r.get("type") == "user" and not r.get("isSidechain"):
            body = text_of(content)
            if LOOP_CMD.search(body) and LOOP_AUTO_ARGS.search(body):
                agg["loop_firings"] += 1
            if r.get("origin", {}).get("kind") == "human":
                agg["human_prompts"] += 1

        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                body = b.get("text", "")
                for _tag, issue in SHIPPED_TAG.findall(body):
                    agg["ship_tags"].add(issue)
                for issue in CANCELED_TAG.findall(body):
                    agg["cancel_tags"].add(issue)
                if TERMINAL_TAG.search(body):
                    agg["terminal_tags"] += 1
            elif b.get("type") == "tool_use":
                name = b.get("name", "")
                inp = b.get("input") or {}
                pending[b.get("id")] = (t, name, inp)
                agg["tool_calls"] += 1
                if name == "Agent":
                    bg = inp.get("run_in_background")
                    agg["dispatch"]["background" if bg is None or bg is True else "sync"] += 1
                elif name == "ScheduleWakeup":
                    agg["wakeups"] += 1
                    if inp.get("stop") is True:
                        agg["wakeup_stops"] += 1
            elif b.get("type") == "tool_result":
                use = pending.pop(b.get("tool_use_id"), None)
                if not use:
                    continue
                t0, name, inp = use
                body = result_text(b)
                if CLASSIFIER.search(body):
                    agg["classifier_blocks"].append(str(inp.get("command", ""))[:160])
                if t and t0:
                    secs = (t - t0).total_seconds()
                    if name == "Bash":
                        cmd = str(inp.get("command", ""))
                        if SLEEP_RE.search(cmd):
                            key = "blind" if is_blind_sleep(cmd) else "marker"
                            agg[f"sleep_{key}_s"] += secs
                            agg[f"sleep_{key}_n"] += 1
                    if secs >= GAP_MIN:
                        agg["gaps"].append((secs, name, str(inp.get("description") or inp.get("command") or "")[:90]))
    agg["dangling"] += len(pending)
    if times:
        agg["first"] = min([agg["first"], min(times)]) if agg["first"] else min(times)
        agg["last"] = max([agg["last"], max(times)]) if agg["last"] else max(times)


def new_agg():
    return {
        "first": None, "last": None, "tool_calls": 0, "wakeups": 0, "wakeup_stops": 0,
        "loop_firings": 0, "human_prompts": 0, "terminal_tags": 0, "dangling": 0,
        "dispatch": Counter(), "classifier_blocks": [], "gaps": [],
        "sleep_blind_s": 0.0, "sleep_blind_n": 0, "sleep_marker_s": 0.0, "sleep_marker_n": 0,
        "ship_tags": set(), "cancel_tags": set(), "subagents": 0,
    }


def git_merged(checkout, issues):
    """Which shipped issues have a commit in history, and which have a merge commit. A shipped issue
    with neither is the loud case; merge-commit-absent alone is usually just a fast-forward."""
    out = {}
    for issue in sorted(issues):
        try:
            commits = subprocess.run(
                ["git", "-C", str(checkout), "log", "--oneline", "--all", f"--grep={issue}"],
                capture_output=True, text=True, timeout=30,
            ).stdout
        except (subprocess.SubprocessError, OSError):
            commits = ""
        out[issue] = {
            "commit": bool(re.search(rf"\b{issue}\b", commits)),
            "merge": bool(re.search(rf"Merge {issue}\b", commits)),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkout", default=".")
    ap.add_argument("--hours", type=float, default=36.0)
    ap.add_argument("--since")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    checkout = Path(args.checkout).resolve()
    try:
        checkout = Path(subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=15, check=True).stdout.strip())
    except (subprocess.SubprocessError, OSError):
        pass

    if args.all:
        cutoff = None
    elif args.since:
        cutoff = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc)
    else:
        cutoff = datetime.now(timezone.utc) - timedelta(hours=args.hours)

    states = []
    for p in sorted((checkout / "tmp").glob("auto-state-*.json")):
        mtime = datetime.fromtimestamp(p.stat().st_mtime, timezone.utc)
        if cutoff and mtime < cutoff:
            continue
        try:
            states.append((p, json.loads(p.read_text()), mtime))
        except (json.JSONDecodeError, OSError):
            continue

    if not states:
        print(f"No auto-state files under {checkout}/tmp matching the window. "
              f"Try --hours/--since/--all.", file=sys.stderr)
        return 1

    mangled = str(checkout).replace("/", "-")
    dirs = [d for d in PROJ.glob(f"{mangled}*") if d.is_dir()]

    sessions = []
    for path, state, mtime in states:
        run_key = path.stem.replace("auto-state-", "")
        agg = new_agg()
        transcripts = []
        for d in dirs:
            transcripts += list(d.glob(f"{run_key}*.jsonl"))
            transcripts += list(d.glob(f"{run_key}*/subagents/*.jsonl"))
        for tpath in transcripts:
            if "/subagents/" in str(tpath):
                agg["subagents"] += 1
            scan_transcript(tpath, agg)
        sessions.append({"run_key": run_key, "state": state, "state_mtime": mtime,
                         "transcripts": len(transcripts), "agg": agg})

    all_shipped = set()
    for s in sessions:
        all_shipped |= set(s["state"].get("shipped") or []) | s["agg"]["ship_tags"]
    merged = git_merged(checkout, all_shipped)

    if args.json:
        print(json.dumps({
            "checkout": str(checkout),
            "sessions": [{
                "run_key": s["run_key"],
                "recorded_shipped": s["state"].get("shipped") or [],
                "observed_shipped": sorted(s["agg"]["ship_tags"]),
                "recorded_canceled": s["state"].get("canceled") or [],
                "observed_canceled": sorted(s["agg"]["cancel_tags"]),
                "status": s["state"].get("status"), "reason": s["state"].get("reason"),
                "span_h": round(((s["agg"]["last"] - s["agg"]["first"]).total_seconds() / 3600), 2)
                          if s["agg"]["first"] and s["agg"]["last"] else None,
                "wakeups": s["agg"]["wakeups"], "wakeup_stops": s["agg"]["wakeup_stops"],
                "loop_firings": s["agg"]["loop_firings"], "human_prompts": s["agg"]["human_prompts"],
                "terminal_tags": s["agg"]["terminal_tags"],
                "dispatch": dict(s["agg"]["dispatch"]),
                "sleep_blind_h": round(s["agg"]["sleep_blind_s"] / 3600, 2),
                "sleep_marker_h": round(s["agg"]["sleep_marker_s"] / 3600, 2),
                "classifier_blocks": len(s["agg"]["classifier_blocks"]),
                "dangling_tool_calls": s["agg"]["dangling"],
                "subagent_transcripts": s["agg"]["subagents"],
                "long_gaps": [{"minutes": round(g[0] / 60, 1), "tool": g[1], "what": g[2]}
                              for g in sorted(s["agg"]["gaps"], reverse=True)[:5]],
            } for s in sessions],
            "merge_reconciliation": merged,
        }, indent=2))
        return 0

    print(f"# Fleet metrics — {checkout.name}\n")
    print(f"Checkout: `{checkout}`  ·  sessions: {len(sessions)}"
          f"  ·  window: {'all' if not cutoff else cutoff.strftime('%Y-%m-%d %H:%M UTC')}\n")

    print("## Per session\n")
    print("| run | span | shipped (rec/obs) | canceled (rec/obs) | wakeups | dispatch bg/sync | blind sleep | marker | cls | dangling |")
    print("|---|---|---|---|---|---|---|---|---|---|")
    tot = Counter()
    for s in sessions:
        a = s["agg"]
        span = ((a["last"] - a["first"]).total_seconds() / 3600) if a["first"] and a["last"] else 0.0
        rec, obs = len(s["state"].get("shipped") or []), len(a["ship_tags"])
        crec, cobs = len(s["state"].get("canceled") or []), len(a["cancel_tags"])
        blind_pct = f"{a['sleep_blind_s'] / 3600:.1f}h ({100 * a['sleep_blind_s'] / (span * 3600):.0f}%)" if span else "-"
        unrecorded = a["ship_tags"] - set(s["state"].get("shipped") or [])
        flag = "  ⚠" if (a["wakeups"] == 0 and a["loop_firings"]) or unrecorded else ""
        print(f"| `{s['run_key']}`{flag} | {span:.1f}h | {rec}/{obs} | {crec}/{cobs} | "
              f"{a['wakeups']} ({a['wakeup_stops']} stop) | "
              f"{a['dispatch']['background']}/{a['dispatch']['sync']} | {blind_pct} | "
              f"{a['sleep_marker_s'] / 3600:.1f}h | {len(a['classifier_blocks'])} | {a['dangling']} |")
        tot["span"] += span
        tot["blind"] += a["sleep_blind_s"]
        tot["marker"] += a["sleep_marker_s"]
        tot["cls"] += len(a["classifier_blocks"])
        tot["bg"] += a["dispatch"]["background"]
        tot["sync"] += a["dispatch"]["sync"]
    blind_share = f"({100 * tot['blind'] / tot['span'] / 3600:.0f}% of fleet wall-clock)" if tot["span"] else "(no transcript window)"
    print(f"\n**Totals** — {tot['span']:.1f} session-hours · blind sleep {tot['blind'] / 3600:.1f}h "
          f"{blind_share} · marker polls "
          f"{tot['marker'] / 3600:.1f}h · dispatch {tot['bg']} background / {tot['sync']} sync · "
          f"{tot['cls']} classifier blocks\n")

    print("## Flags\n")
    flagged = False
    for s in sessions:
        a, st = s["agg"], s["state"]
        rec, obs = set(st.get("shipped") or []), a["ship_tags"]
        if a["loop_firings"] and a["wakeups"] == 0:
            flagged = True
            print(f"- **`{s['run_key']}` never armed a ScheduleWakeup** across {a['loop_firings']} "
                  f"loop firing(s) — the silent loop-death shape. Recorded status "
                  f"`{st.get('status')}`, terminal tags emitted: {a['terminal_tags']}.")
        # Only an UNRECORDED ship is a fault. The reverse — recorded issues absent from the
        # transcript — is the ordinary result of a compacted session losing its earlier tags, and
        # flagging it buries the real signal under a false one on every long-running session.
        if obs - rec:
            flagged = True
            print(f"- **`{s['run_key']}` shipped without recording it** — transcript shows "
                  f"{sorted(obs - rec)}, absent from the state file (recorded {sorted(rec) or '[]'}). "
                  f"Step 4 never ran; the run's own tally undercounts.")
        if a["dangling"]:
            flagged = True
            print(f"- `{s['run_key']}` has {a['dangling']} tool call(s) with no result — an "
                  f"unanswered prompt or a killed turn.")
        if a["classifier_blocks"]:
            flagged = True
            print(f"- `{s['run_key']}` hit {len(a['classifier_blocks'])} classifier block(s):")
            for c in a["classifier_blocks"][:3]:
                print(f"    - `{c}`")
    missing = [i for i, m in merged.items() if not m["commit"]]
    if missing:
        flagged = True
        print(f"- **Shipped but no commit found**: {', '.join(missing)} — verify before trusting the count.")
    no_merge = [i for i, m in merged.items() if m["commit"] and not m["merge"]]
    if no_merge:
        print(f"- Landed without a `Merge <ID>` commit (usually a fast-forward, worth one check): "
              f"{', '.join(no_merge)}")
    if not flagged:
        print("- None. Every session armed its heartbeat, recorded its outcome, and hit no blocks.")

    print("\n## Slowest calls\n")
    for s in sessions:
        gaps = sorted(s["agg"]["gaps"], reverse=True)[:3]
        if gaps:
            print(f"- `{s['run_key']}`: " + "; ".join(f"{g[0] / 60:.0f}m {g[1]} ({g[2][:52]})" for g in gaps))
    return 0


if __name__ == "__main__":
    sys.exit(main())
