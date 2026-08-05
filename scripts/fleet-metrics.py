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
  <checkout>/tmp/quality-review-verdict-*.md  per-issue review outcomes written by /quality-review —
                                            cycles, findings with SEVERITY/origin tags, deferred filings
  ~/.claude/projects/<mangled-cwd>/*.jsonl  session transcripts, main + worktree dirs
  ~/.claude/projects/.../subagents/*.jsonl  delegated work — where classifier blocks actually land,
                                            invisible to the parent except as a slow Agent call
  .../subagents/agent-<id>.meta.json        the dispatch's agentType, for exact token attribution

Sessions are discovered from state files, then matched to transcripts by runKey (a state file's key
is the leading segment of its session UUID). A session whose state file says nothing shipped may
still have shipped — that mismatch is itself a finding (BF-695), so both are reported. A SECOND pass
then sweeps the same transcript dirs for /auto sessions with no state file at all and reports them
flagged: /auto's Step 0 GC can delete a finished run's ledger, and a fleet measured only from the
survivors reads as smaller and healthier than it was (2026-08-04: 2 of 4 sessions, 7 of 12 ships).

Usage:
  fleet-metrics.py [--checkout DIR] [--since YYYY-MM-DD | --hours N | --all] [--json]

  --hours N   consider state files touched in the last N hours (default 36)
  --since D   consider state files touched on/after date D
  --all       every state file present
  --json      machine-readable; default is a markdown report
"""
import argparse
import json
import os
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

# Overridable so the regression suite can point at a fixture tree instead of the live transcripts.
PROJ = Path(os.environ.get("CLAUDE_PROJECTS_DIR", str(Path.home() / ".claude" / "projects")))

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

# Verdict-file fields (skills/quality-review Output block). Severity tags may carry a /origin class
# (SEVERITY/origin, added 2026-08-04); files written before that render bare severities, so origin
# coverage is reported as tagged/total rather than assumed complete.
V_VERDICT = re.compile(r"^Verdict:\s*(\S+)", re.M)
V_CYCLES = re.compile(r"^Cycles:\s*(\d+)", re.M)
V_RESOLVED = re.compile(r"^Findings resolved:\s*(\d+|none)", re.M)
V_RESOLVED_BLOCK = re.compile(r"^Findings resolved:.*?(?=^\S|\Z)", re.M | re.S)
V_FILED_LINE = re.compile(r"^Deferred filed as issues:\s*(.+?)$", re.M)
V_SEVERITY = re.compile(r"\b(CRIT(?:ICAL)?|HIGH|MED(?:IUM)?)\b")
V_ORIGIN = re.compile(r"\b(?:CRIT(?:ICAL)?|HIGH|MED(?:IUM)?)/(plan|impl|spec|test|latent)\b")
V_ISSUE_ID = re.compile(r"\b[A-Z][A-Z0-9]*-\d+\b")
SEV_SHORT = {"CRITICAL": "CRIT", "MEDIUM": "MED"}


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


def is_auto_session(path, probe_lines=60):
    """True when this transcript's opening prompt is /auto or /loop /auto.

    Session discovery cannot rest on state files alone: /auto's Step 0 GC deletes sibling state
    files, so a finished run's ledger can be gone before the retro reads it — and then the whole
    session, transcripts included, is invisible here. Reported as a smaller, healthier fleet, which
    is the worst possible failure for a tool whose one job is to measure. Observed 2026-08-04: two
    of four sessions (10.2h, 7 of 12 ships) vanished exactly this way. Streams the head of the file
    rather than load()ing it — this runs over every transcript in every matching project dir."""
    try:
        with path.open(errors="replace") as fh:
            for _ in range(probe_lines):
                line = fh.readline()
                if not line:
                    break
                try:
                    row = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if row.get("type") != "user":
                    continue
                text = text_of((row.get("message") or {}).get("content"))
                if not text:
                    continue
                if "<command-name>/auto</command-name>" in text:
                    return True
                if "<command-name>/loop</command-name>" in text and "/auto" in text:
                    return True
                return False  # first human turn was something else — not an /auto run
    except OSError:
        return False
    return False


def subagent_type_of(path):
    """agent-<id>.jsonl sits next to agent-<id>.meta.json, which records the Agent dispatch's
    agentType — exact attribution, vs. guessing the type from prompt text."""
    try:
        meta = json.loads(path.with_name(path.stem + ".meta.json").read_text())
        return meta.get("agentType") or "unknown"
    except (OSError, json.JSONDecodeError):
        return "unknown"


def scan_transcript(path, agg, agent_type="main"):
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

        # A message's usage repeats verbatim on every transcript row sharing its message id, so a
        # row-wise sum double-counts — credit each id once. `<synthetic>` rows carry no API usage.
        if isinstance(msg, dict):
            usage = msg.get("usage") or {}
            mid = msg.get("id")
            model = msg.get("model") or "?"
            if usage.get("output_tokens") is not None and mid and mid not in agg["seen_msg_ids"] \
                    and not model.startswith("<"):
                agg["seen_msg_ids"].add(mid)
                agg["tokens"][(agent_type, model)] += usage["output_tokens"]

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
        "tokens": Counter(), "seen_msg_ids": set(),
    }


def parse_verdicts(checkout, cutoff):
    """One row per quality-review verdict file in the window: the review-churn half of the retro.
    Counts are self-reported by the review pipeline — the audit record, not independent ground truth."""
    rows = []
    for p in sorted((checkout / "tmp").glob("quality-review-verdict-*.md")):
        mtime = datetime.fromtimestamp(p.stat().st_mtime, timezone.utc)
        if cutoff and mtime < cutoff:
            continue
        try:
            text = p.read_text(errors="replace")
        except OSError:
            continue
        m = V_RESOLVED.search(text)
        resolved = int(m.group(1)) if m and m.group(1).isdigit() else 0
        block = V_RESOLVED_BLOCK.search(text)
        blob = block.group(0) if block else ""
        sev = Counter(SEV_SHORT.get(s, s) for s in V_SEVERITY.findall(blob))
        m = V_FILED_LINE.search(text)
        # Parenthetical annotations name OTHER issues — `(sub-issues of TT-9)`, `(collision edge to
        # TT-8 not wired)` — so ids are extracted only from the unparenthesized remainder.
        filed = [] if not m or m.group(1).strip().lower().startswith("none") \
            else V_ISSUE_ID.findall(re.sub(r"\([^)]*\)", " ", m.group(1)))
        # A free-form body (Verdict: present, schema lines absent) parses as 0 findings, which is
        # indistinguishable from a quiet review — 4 of the 2026-08-03 fleet's verdicts were composed
        # off-schema and silently deflated the totals. Name the missing fields so the flag can fire.
        missing = [name for name, rx in (("Findings resolved", V_RESOLVED), ("Cycles", V_CYCLES))
                   if not rx.search(text)]
        rows.append({
            "issue": p.stem.replace("quality-review-verdict-", "").upper(),
            "mtime": mtime,
            "verdict": (V_VERDICT.search(text) or [None, "?"])[1],
            "cycles": int(V_CYCLES.search(text).group(1)) if V_CYCLES.search(text) else None,
            "resolved": resolved,
            "sev": sev,
            "origin": Counter(V_ORIGIN.findall(blob)),
            "filed": filed,
            "missing_fields": missing,
        })
    return rows


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

    mangled = str(checkout).replace("/", "-")
    dirs = [d for d in PROJ.glob(f"{mangled}*") if d.is_dir()]

    def measure(run_key, state, mtime, ledger_missing=False):
        agg = new_agg()
        transcripts = []
        for d in dirs:
            transcripts += list(d.glob(f"{run_key}*.jsonl"))
            transcripts += list(d.glob(f"{run_key}*/subagents/*.jsonl"))
        for tpath in transcripts:
            if "/subagents/" in str(tpath):
                agg["subagents"] += 1
                scan_transcript(tpath, agg, subagent_type_of(tpath))
            else:
                scan_transcript(tpath, agg)
        return {"run_key": run_key, "state": state, "state_mtime": mtime,
                "ledger_missing": ledger_missing,
                "transcripts": len(transcripts), "agg": agg}

    # Second discovery pass: an /auto session whose ledger no longer exists. See is_auto_session —
    # a deleted state file must surface as a flagged session, never as a fleet that was one session
    # smaller than it really was. Keyed on the transcript stem's leading segment, which is what
    # /auto uses for <runKey>.
    ledgerless = []
    state_keys = {p.stem.replace("auto-state-", "") for p, _, _ in states}
    seen_keys = set(state_keys)
    for d in dirs:
        for tpath in sorted(d.glob("*.jsonl")):
            run_key = tpath.stem.split("-")[0]
            if run_key in seen_keys:
                continue
            mtime = datetime.fromtimestamp(tpath.stat().st_mtime, timezone.utc)
            if cutoff and mtime < cutoff:
                continue
            if not is_auto_session(tpath):
                continue
            seen_keys.add(run_key)
            ledgerless.append((run_key, mtime))

    if not states and not ledgerless:
        print(f"No auto-state files or /auto transcripts under {checkout}/tmp matching the window. "
              f"Try --hours/--since/--all.", file=sys.stderr)
        return 1

    sessions = []
    for path, state, mtime in states:
        sessions.append(measure(path.stem.replace("auto-state-", ""), state, mtime))
    for run_key, mtime in ledgerless:
        sessions.append(measure(run_key, {}, mtime, ledger_missing=True))
    sessions.sort(key=lambda s: s["agg"]["first"] or datetime.max.replace(tzinfo=timezone.utc))

    all_shipped = set()
    issue_run = {}
    for s in sessions:
        shipped = set(s["state"].get("shipped") or []) | s["agg"]["ship_tags"]
        all_shipped |= shipped
        for issue in shipped:
            issue_run.setdefault(issue, s["run_key"])
    merged = git_merged(checkout, all_shipped)

    verdicts = parse_verdicts(checkout, cutoff)
    filed_total = sum(len(v["filed"]) for v in verdicts)
    # The ratio pairs this fleet's filings with this fleet's ships: verdicts for issues no session in
    # the window shipped (run `-` in the table) stay out of the numerator, or a window that catches an
    # earlier run's reviews inflates the rate.
    filed_matched = sum(len(v["filed"]) for v in verdicts if v["issue"] in all_shipped)
    filed_per_shipped = round(filed_matched / len(all_shipped), 2) if all_shipped else None
    # Verdict existence is checked against every file on disk, not just the window — the filename
    # alone names the issue, and a review persisted just before the cutoff is not a missing verdict.
    verdict_issues_all = {p.stem.replace("quality-review-verdict-", "").upper()
                          for p in (checkout / "tmp").glob("quality-review-verdict-*.md")}
    fleet_tokens = Counter()
    for s in sessions:
        fleet_tokens.update(s["agg"]["tokens"])

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
                "ledger_missing": s["ledger_missing"],
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
                "output_tokens": {f"{t}/{m}": n for (t, m), n in s["agg"]["tokens"].most_common()},
                "long_gaps": [{"minutes": round(g[0] / 60, 1), "tool": g[1], "what": g[2]}
                              for g in sorted(s["agg"]["gaps"], reverse=True)[:5]],
            } for s in sessions],
            "review_churn": [{
                "issue": v["issue"], "run": issue_run.get(v["issue"]),
                "verdict": v["verdict"], "cycles": v["cycles"], "findings_resolved": v["resolved"],
                "severity": dict(v["sev"]), "origin": dict(v["origin"]), "filed": v["filed"],
                "missing_fields": v["missing_fields"],
            } for v in verdicts],
            "filed_per_shipped": filed_per_shipped,
            "output_tokens": {f"{t}/{m}": n for (t, m), n in fleet_tokens.most_common()},
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
        if s["ledger_missing"]:
            rec, crec = "-", "-"   # no ledger to record against; obs is the only truth for this row
        blind_pct = f"{a['sleep_blind_s'] / 3600:.1f}h ({100 * a['sleep_blind_s'] / (span * 3600):.0f}%)" if span else "-"
        unrecorded = a["ship_tags"] - set(s["state"].get("shipped") or [])
        flag = "  ⚠" if (a["wakeups"] == 0 and a["loop_firings"]) or unrecorded or s["ledger_missing"] else ""
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
          f"{tot['cls']} classifier blocks · {sum(fleet_tokens.values()):,} output tokens\n")

    print("## Review churn\n")
    if verdicts:
        print("| issue | run | verdict | cycles | findings | C/H/M | origins | filed |")
        print("|---|---|---|---|---|---|---|---|")
        for v in verdicts:
            origins = " ".join(f"{k}:{n}" for k, n in v["origin"].most_common()) or "-"
            findings = "?" if "Findings resolved" in v["missing_fields"] else v["resolved"]
            print(f"| {v['issue']} | `{issue_run.get(v['issue'], '-')}` | {v['verdict']} | "
                  f"{v['cycles'] if v['cycles'] is not None else '?'} | {findings} | "
                  f"{v['sev']['CRIT']}/{v['sev']['HIGH']}/{v['sev']['MED']} | {origins} | "
                  f"{len(v['filed'])} |")
        cyc = [v["cycles"] for v in verdicts if v["cycles"] is not None]
        resolved_total = sum(v["resolved"] for v in verdicts)
        tagged = sum(sum(v["origin"].values()) for v in verdicts)
        origin_tot = Counter()
        for v in verdicts:
            origin_tot.update(v["origin"])
        origins = " ".join(f"{k}:{n}" for k, n in origin_tot.most_common()) or "none"
        ratio = (f"{filed_per_shipped} filed per shipped issue ({filed_matched} from this fleet's reviews)"
                 if filed_per_shipped is not None else "no shipped issues to pair against")
        print(f"\n**Churn totals** — {len(verdicts)} reviews · avg cycles "
              f"{sum(cyc) / len(cyc):.1f} (max {max(cyc)}) · {resolved_total} findings resolved · "
              f"severity C/H/M {sum(v['sev']['CRIT'] for v in verdicts)}/"
              f"{sum(v['sev']['HIGH'] for v in verdicts)}/{sum(v['sev']['MED'] for v in verdicts)} · "
              f"origin-tagged {tagged}/{resolved_total} ({origins}) · "
              f"{filed_total} deferred filings in window → {ratio}. Review-pipeline filings only — "
              f"the Linear window query (retro Step 3) is the full filing census.\n")
    else:
        print("- no verdict files in the window\n")

    print("## Output tokens by agent type\n")
    if fleet_tokens:
        total_out = sum(fleet_tokens.values())
        print("| agent type | model | output tokens | share |")
        print("|---|---|---|---|")
        for (typ, model), n in fleet_tokens.most_common():
            print(f"| {typ} | {model} | {n:,} | {100 * n / total_out:.0f}% |")
        print()
    else:
        print("- no usage data found in transcripts\n")

    print("## Flags\n")
    flagged = False
    for s in sessions:
        a, st = s["agg"], s["state"]
        rec, obs = set(st.get("shipped") or []), a["ship_tags"]
        if s["ledger_missing"]:
            flagged = True
            span = ((a["last"] - a["first"]).total_seconds() / 3600) if a["first"] and a["last"] else 0.0
            print(f"- **`{s['run_key']}` ran without a surviving ledger** — an /auto session spanning "
                  f"{span:.1f}h with {len(obs)} observed ship(s) ({', '.join(sorted(obs)) or 'none'}) and "
                  f"no `tmp/auto-state-{s['run_key']}.json`. Its run bookkeeping was deleted (usually by "
                  f"a sibling's /auto Step 0 GC) or never written; the shipped/canceled/skipped/failed "
                  f"counts for this row come from transcript tags alone and undercount if the session "
                  f"was compacted.")
        if a["loop_firings"] and a["wakeups"] == 0:
            flagged = True
            print(f"- **`{s['run_key']}` never armed a ScheduleWakeup** across {a['loop_firings']} "
                  f"loop firing(s) — the silent loop-death shape. Recorded status "
                  f"`{st.get('status')}`, terminal tags emitted: {a['terminal_tags']}.")
        # Only an UNRECORDED ship is a fault. The reverse — recorded issues absent from the
        # transcript — is the ordinary result of a compacted session losing its earlier tags, and
        # flagging it buries the real signal under a false one on every long-running session.
        # Skipped when the ledger is gone entirely: "Step 4 never ran" would be a wrong diagnosis
        # (it did run; the file it wrote was deleted), and the ledger-missing flag above says it.
        if (obs - rec) and not s["ledger_missing"]:
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
    no_verdict = sorted(i for i in all_shipped if i not in verdict_issues_all)
    if no_verdict:
        flagged = True
        print(f"- **Shipped with no persisted review verdict**: {', '.join(no_verdict)} — either "
              f"/quality-review never persisted (its Output-block mandate failed) or the issue shipped "
              f"outside the review pipeline. The churn table undercounts by these.")
    malformed = [v for v in verdicts if v["missing_fields"]]
    if malformed:
        flagged = True
        detail = "; ".join(f"{v['issue']} (no {', '.join(v['missing_fields'])} line)" for v in malformed)
        print(f"- **Off-schema verdict body**: {detail} — composed as free-form prose instead of the "
              f"Output-block schema, so its findings data is unparseable and the churn totals "
              f"undercount. The review ran; only the machine-readable record is lost.")
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
