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
# The contamination hard stop's tagged line (skills/start Step 8 item 1). Line-anchored like
# TERMINAL_TAG, and keyed by issue so repeated renders of one halt (chat print + Step 10 summary)
# count once. Counts HALTS only — the benign-continue branch posts a Linear note instead and is
# invisible here; /fleet-retro adjudicates each halt true/false-positive against those notes.
CONTAM_HALT = re.compile(r"^\s*BLOCKED-ON-REVIEW:\s*([A-Z][A-Z0-9]*-\d+)\b[^\n]*MAIN-CHECKOUT-CONTAMINATION", re.M)
LOOP_CMD = re.compile(r"<command-name>/loop</command-name>")
LOOP_AUTO_ARGS = re.compile(r"<command-args>[^<]*/auto")
GAP_MIN = 240  # seconds; a tool call slower than this is worth naming, not necessarily a fault

# $/MTok (input, output) at Claude API list prices, cached from the claude-api skill 2026-08-05.
# Sonnet 5 has a $2/$10 intro rate through 2026-08-31 — the sticker is used so fleets stay comparable
# across that boundary; current 1M-context models carry no long-context premium, so no per-request
# tier logic. Cache reads bill at 0.1x input; cache writes at 2x — Claude Code sessions write 1h-TTL
# cache entries (a 5m-TTL write would be 1.25x). Models are prefix-matched so dated ids
# (claude-haiku-4-5-20251001) resolve; unmatched models are reported unpriced, never silently dropped.
PRICES = {
    "claude-fable-5": (10.00, 50.00),
    "claude-opus-5": (5.00, 25.00),
    "claude-opus-4-8": (5.00, 25.00),
    "claude-opus-4-7": (5.00, 25.00),
    "claude-opus-4-6": (5.00, 25.00),
    "claude-sonnet-5": (3.00, 15.00),
    "claude-sonnet-4-6": (3.00, 15.00),
    "claude-haiku-4-5": (1.00, 5.00),
}
CACHE_READ_X, CACHE_WRITE_X = 0.1, 2.0
# Transcripts never carry thinking text (display defaults to omitted — verified on live fleet
# transcripts 2026-08-05, every thinking block empty), so thinking spend is estimated as the
# residual: output_tokens minus visible output (text + tool_use inputs) at ~4 chars/token. Good for
# "bulk or sliver", not for billing.
VISIBLE_CHARS_PER_TOKEN = 4

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
            agg["activity_times"].append(t)
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
                if t:
                    agg["token_events"].append((t.timestamp(), usage["output_tokens"]))
                    agg["cache_events"].append((
                        t.timestamp(),
                        usage.get("cache_read_input_tokens") or 0,
                        (usage.get("input_tokens") or 0)
                        + (usage.get("cache_creation_input_tokens") or 0)
                        + (usage.get("cache_read_input_tokens") or 0)
                        + usage["output_tokens"],
                    ))
                u = agg["usage"].setdefault((agent_type, model), Counter())
                u["input"] += usage.get("input_tokens") or 0
                u["cache_write"] += usage.get("cache_creation_input_tokens") or 0
                u["cache_read"] += usage.get("cache_read_input_tokens") or 0
                u["output"] += usage["output_tokens"]

        if r.get("type") == "user" and not r.get("isSidechain"):
            body = text_of(content)
            if LOOP_CMD.search(body) and LOOP_AUTO_ARGS.search(body):
                agg["loop_firings"] += 1
            if r.get("origin", {}).get("kind") == "human":
                agg["human_prompts"] += 1

        if not isinstance(content, list):
            continue
        # visible_chars backs the thinking-share estimate: assistant-emitted text + tool inputs are
        # the visible part of output_tokens; the residual is thinking, whose text is never recorded.
        # Rows sharing a message id each carry DISTINCT blocks of it (verified on live transcripts),
        # so blocks are counted per row with no message-id dedup.
        emitted = r.get("type") == "assistant"
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text":
                body = b.get("text", "")
                if emitted:
                    agg["visible_chars"][agent_type] += len(body)
                for _tag, issue in SHIPPED_TAG.findall(body):
                    agg["ship_tags"].add(issue)
                for issue in CANCELED_TAG.findall(body):
                    agg["cancel_tags"].add(issue)
                for issue in CONTAM_HALT.findall(body):
                    agg["contam_halts"].add(issue)
                if TERMINAL_TAG.search(body):
                    agg["terminal_tags"] += 1
            elif b.get("type") == "tool_use":
                name = b.get("name", "")
                inp = b.get("input") or {}
                if emitted:
                    agg["visible_chars"][agent_type] += len(json.dumps(inp))
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
        "dispatch": Counter(), "classifier_blocks": [], "gaps": [], "activity_times": [],
        "sleep_blind_s": 0.0, "sleep_blind_n": 0, "sleep_marker_s": 0.0, "sleep_marker_n": 0,
        "ship_tags": set(), "cancel_tags": set(), "contam_halts": set(), "subagents": 0,
        "tokens": Counter(), "seen_msg_ids": set(),
        # (epoch_seconds, output_tokens) per credited message — the time dimension the
        # (agent, model) Counter above throws away. Rolling-window burn needs it: the
        # account's rate limits meter a moving window, so a total tells you nothing about
        # whether a run ever approached one. See rolling_peak().
        "token_events": [],
        # (epoch, cache_read, total_billable) alongside token_events. Output tokens are what a fleet
        # gets SIZED on, and the 2026-08-06 run showed they are not what the 5h limit meters: it cut
        # the fleet off at 1.58M output, below the 2.12M a prior run had survived, while moving ~950x
        # that volume in cache reads. Recording both in the same window is what lets two runs settle
        # which quantity the limit actually tracks — reasoning about it settles nothing.
        "cache_events": [],
        "usage": {}, "visible_chars": Counter(),
    }


def rolling_peak(events, window_h):
    """Max output tokens credited inside any `window_h`-long sliding window, fleet-wide.

    Rate limits meter a MOVING window, so a run total says nothing about whether the fleet ever
    approached one — only this does. Events are pooled across sessions on purpose: the limit is
    account-level, so two concurrent sessions burn one budget.

    Returns (peak_tokens, window_start) — and that peak is a FLOOR on the real ceiling, never the
    ceiling itself. It reports what was survived, and every observation to date comes from runs
    that were never throttled hard enough to notice. Read it as "at least this much fits".
    """
    if not events:
        return 0, None
    ev = sorted(events)
    span = window_h * 3600.0
    total, lo, best = 0, 0, (0, None)
    for t, n in ev:
        total += n
        while ev[lo][0] < t - span:
            total -= ev[lo][1]
            lo += 1
        if total > best[0]:
            best = (total, datetime.fromtimestamp(ev[lo][0], timezone.utc))
    return best


def longest_silence(agg, min_s=1800):
    """The session's longest stretch emitting nothing at all, as (start, end, seconds).

    Distinct from agg["gaps"], which times a single tool_use against its tool_result and so only
    ever sees a SLOW CALL. A quota cutoff produces no call to be slow — the session stops emitting
    rows entirely — so it is invisible there and visible only as wall-clock silence. Measured over
    the union of the session's own rows and its subagents': a delegate working for 40 minutes while
    the parent waits is not an idle fleet.
    """
    times = sorted(agg["activity_times"])
    if len(times) < 2:
        return None
    best = max(((times[i + 1] - times[i]).total_seconds(), times[i], times[i + 1])
               for i in range(len(times) - 1))
    return (best[1], best[2], best[0]) if best[0] >= min_s else None


def quota_stalls(sessions, cluster_s=120, min_silence_s=1800):
    """Sessions that stopped together — the allowance-exhaustion fingerprint, recovered or not.

    A fleet winding down on its deadline ends one session at a time, each emitting a terminal tag as
    its loop closes. An account-level cutoff stops every live session at once, mid-issue. Two shapes,
    and the earlier version of this function saw only the first:

      unrecovered — the sessions never come back, so the stall is their LAST activity and no terminal
        tag is ever written. Clustering last-activity times finds it.
      recovered — the allowance frees up hours later, the sessions wake, find the deadline passed and
        drain NORMALLY. They now carry terminal tags and their last activity is the tidy drain, so
        the unrecovered test rejects them and the stall vanishes from the report.

    The recovered shape is the common one, because a retro runs after the fleet has wound down — by
    which point a stall has usually resolved itself. Measured on the 2026-08-06 basefund fleet: three
    of four sessions stopped within 3 minutes of each other, resumed within 60 seconds of each other
    10.7h later, and drained cleanly; the unrecovered-only detector reported no stall at all while
    47% of the fleet's capacity had been lost. So cluster on where each session went QUIET — the
    start of its longest silence for a recovered stall, its last activity for an unrecovered one.
    """
    marks = []
    for s in sessions:
        if not s["agg"]["last"]:
            continue
        sil = longest_silence(s["agg"], min_silence_s)
        if sil:
            marks.append((sil[0], s, {"kind": "recovered", "resumed": sil[1], "seconds": sil[2]}))
        elif not s["agg"]["terminal_tags"]:
            marks.append((s["agg"]["last"], s, {"kind": "unrecovered", "resumed": None, "seconds": None}))
    if len(marks) < 2:
        return []
    marks.sort(key=lambda m: m[0])
    out, group = [], [marks[0]]
    for m in marks[1:]:
        if (m[0] - group[-1][0]).total_seconds() <= cluster_s:
            group.append(m)
        else:
            if len(group) >= 2:
                out.append(group)
            group = [m]
    if len(group) >= 2:
        out.append(group)
    return out


def price_of(model):
    return next((p for k, p in PRICES.items() if model.startswith(k)), None)


def est_cost(usage_by_key):
    """Dollar estimate for {(agent_type, model): usage Counter}; unmatched models come back named."""
    total, unpriced = 0.0, set()
    for (_typ, model), u in usage_by_key.items():
        p = price_of(model)
        if not p:
            unpriced.add(model)
            continue
        inp, out = p
        total += (u["input"] * inp + u["cache_write"] * inp * CACHE_WRITE_X
                  + u["cache_read"] * inp * CACHE_READ_X + u["output"] * out) / 1e6
    return total, unpriced


def thinking_share(aggs, agent_type="main"):
    """Estimated fraction of the tier's output tokens spent thinking (see VISIBLE_CHARS_PER_TOKEN)."""
    out = sum(n for a in aggs for (typ, _m), n in a["tokens"].items() if typ == agent_type)
    if not out:
        return None
    visible = sum(a["visible_chars"][agent_type] for a in aggs) / VISIBLE_CHARS_PER_TOKEN
    return max(0.0, round(1 - visible / out, 2))


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
            # A ledger that merely sorted out of the window in pass 1 is NOT a missing ledger. The two
            # passes filter on different mtimes — pass 1 on the state file's, this one on the transcript's
            # — so a session that worked in-window while its ledger last changed before the cutoff lands
            # here with the file still sitting on disk. Flagging it fires "ran without a surviving ledger",
            # which the retro reads as a real fault (/auto Step 4 never ran) and which costs a chase every
            # run: on the 2026-08-06 fleet it fired 6 times, more than every genuine fault that run
            # combined. Adopt the real ledger instead of guessing — recorded-vs-observed then still works,
            # so a genuine unrecorded ship is still caught.
            spath = checkout / "tmp" / f"auto-state-{run_key}.json"
            try:
                states.append((spath, json.loads(spath.read_text()),
                               datetime.fromtimestamp(spath.stat().st_mtime, timezone.utc)))
                continue
            except (json.JSONDecodeError, OSError):
                pass
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
    fleet_usage = {}
    for s in sessions:
        fleet_tokens.update(s["agg"]["tokens"])
        for k, u in s["agg"]["usage"].items():
            fleet_usage.setdefault(k, Counter()).update(u)
    fleet_cost, unpriced = est_cost(fleet_usage)
    fleet_think = thinking_share([s["agg"] for s in sessions])
    out_per_shipped = round(sum(fleet_tokens.values()) / len(all_shipped)) if all_shipped else None
    cost_per_shipped = round(fleet_cost / len(all_shipped), 2) if all_shipped else None

    # Burn against the moving windows the account actually meters. /auto-prep sizes a fleet from
    # these: the 5h peak caps CONCURRENCY (n x 5 x rate), the weekly caps total session-hours.
    all_events = [e for s in sessions for e in s["agg"]["token_events"]]
    peak_5h, peak_5h_at = rolling_peak(all_events, 5)
    peak_wk, peak_wk_at = rolling_peak(all_events, 168)
    session_hours = sum(((s["agg"]["last"] - s["agg"]["first"]).total_seconds() / 3600)
                        for s in sessions if s["agg"]["first"] and s["agg"]["last"])
    # A rate averaged over EVERY session in the window is the wrong number to size a fleet with: it
    # pools dense fleet sessions with idle and interactive ones and lands roughly half the truth
    # (measured 55.9k vs 84.9k on the same BF data). Scope it to the peak window instead — that is
    # the densest observed fleet activity, and the only place the rate reflects a session actually
    # working. Sizing then scales a proportion (peak x n/concurrency) rather than trusting a mean.
    peak_5h_concurrency, peak_5h_rate = 0, None
    peak_5h_cache_read, peak_5h_total = None, None
    if peak_5h_at:
        w0 = peak_5h_at.timestamp()
        w1 = w0 + 5 * 3600
        cache_events = [e for s in sessions for e in s["agg"]["cache_events"]]
        peak_5h_cache_read = sum(e[1] for e in cache_events if w0 <= e[0] < w1)
        peak_5h_total = sum(e[2] for e in cache_events if w0 <= e[0] < w1)
        peak_5h_concurrency = sum(
            1 for s in sessions
            if s["agg"]["first"] and s["agg"]["last"]
            and s["agg"]["first"].timestamp() < w1 and s["agg"]["last"].timestamp() > w0)
        if peak_5h_concurrency:
            peak_5h_rate = round(peak_5h / (peak_5h_concurrency * 5))
    burn_rate_all = round(sum(fleet_tokens.values()) / session_hours) if session_hours else None
    stall_groups = quota_stalls(sessions)

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
                "start_epoch": s["agg"]["first"].timestamp() if s["agg"]["first"] else None,
                "end_epoch": s["agg"]["last"].timestamp() if s["agg"]["last"] else None,
                "wakeups": s["agg"]["wakeups"], "wakeup_stops": s["agg"]["wakeup_stops"],
                "loop_firings": s["agg"]["loop_firings"], "human_prompts": s["agg"]["human_prompts"],
                "terminal_tags": s["agg"]["terminal_tags"],
                "dispatch": dict(s["agg"]["dispatch"]),
                "sleep_blind_h": round(s["agg"]["sleep_blind_s"] / 3600, 2),
                "sleep_marker_h": round(s["agg"]["sleep_marker_s"] / 3600, 2),
                "classifier_blocks": len(s["agg"]["classifier_blocks"]),
                "contamination_halts": sorted(s["agg"]["contam_halts"]),
                "dangling_tool_calls": s["agg"]["dangling"],
                "subagent_transcripts": s["agg"]["subagents"],
                "output_tokens": {f"{t}/{m}": n for (t, m), n in s["agg"]["tokens"].most_common()},
                "usage": {f"{t}/{m}": dict(u) for (t, m), u in s["agg"]["usage"].items()},
                "est_cost_usd": round(est_cost(s["agg"]["usage"])[0], 4),
                "main_thinking_share_est": thinking_share([s["agg"]]),
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
            "usage": {f"{t}/{m}": dict(u) for (t, m), u in
                      sorted(fleet_usage.items(), key=lambda kv: -kv[1]["output"])},
            "est_cost_usd": round(fleet_cost, 4),
            "unpriced_models": sorted(unpriced),
            "main_thinking_share_est": fleet_think,
            "per_shipped": {"output_tokens": out_per_shipped, "est_cost_usd": cost_per_shipped},
            "windows": {
                "peak_5h_output_tokens": peak_5h,
                "peak_5h_cache_read_tokens": peak_5h_cache_read,
                "peak_5h_total_billable_tokens": peak_5h_total,
                "peak_5h_window_start": peak_5h_at.isoformat() if peak_5h_at else None,
                "peak_168h_output_tokens": peak_wk,
                "peak_168h_window_start": peak_wk_at.isoformat() if peak_wk_at else None,
                "session_hours": round(session_hours, 2),
                "peak_5h_concurrency": peak_5h_concurrency,
                "output_tokens_per_session_hour_at_peak": peak_5h_rate,
                "output_tokens_per_session_hour_all_sessions": burn_rate_all,
                "quota_stall_groups": [{
                    "runs": [m[1]["run_key"] for m in g],
                    "kind": "recovered" if any(m[2]["kind"] == "recovered" for m in g) else "unrecovered",
                    "quiet_at": f"{g[0][0]:%Y-%m-%dT%H:%M:%SZ}",
                    "resumed_at": (f"{max(m[2]['resumed'] for m in g if m[2]['resumed']):%Y-%m-%dT%H:%M:%SZ}"
                                   if any(m[2]["resumed"] for m in g) else None),
                    "lost_session_hours": round(sum(m[2]["seconds"] or 0 for m in g) / 3600, 1),
                } for g in stall_groups],
            },
            "merge_reconciliation": merged,
        }, indent=2))
        return 0

    print(f"# Fleet metrics — {checkout.name}\n")
    print(f"Checkout: `{checkout}`  ·  sessions: {len(sessions)}"
          f"  ·  window: {'all' if not cutoff else cutoff.strftime('%Y-%m-%d %H:%M UTC')}\n")

    print("## Per session\n")
    print("| run | span | shipped (rec/obs) | canceled (rec/obs) | wakeups | dispatch bg/sync | blind sleep | marker | cls | contam | dangling |")
    print("|---|---|---|---|---|---|---|---|---|---|---|")
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
              f"{a['sleep_marker_s'] / 3600:.1f}h | {len(a['classifier_blocks'])} | "
              f"{len(a['contam_halts'])} | {a['dangling']} |")
        tot["span"] += span
        tot["blind"] += a["sleep_blind_s"]
        tot["marker"] += a["sleep_marker_s"]
        tot["cls"] += len(a["classifier_blocks"])
        tot["contam"] += len(a["contam_halts"])
        tot["bg"] += a["dispatch"]["background"]
        tot["sync"] += a["dispatch"]["sync"]
    blind_share = f"({100 * tot['blind'] / tot['span'] / 3600:.0f}% of fleet wall-clock)" if tot["span"] else "(no transcript window)"
    print(f"\n**Totals** — {tot['span']:.1f} session-hours · blind sleep {tot['blind'] / 3600:.1f}h "
          f"{blind_share} · marker polls "
          f"{tot['marker'] / 3600:.1f}h · dispatch {tot['bg']} background / {tot['sync']} sync · "
          f"{tot['cls']} classifier blocks · {tot['contam']} contamination halt(s) · "
          f"{sum(fleet_tokens.values()):,} output tokens\n")

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
        print("| agent type | model | output tokens | share | est cost |")
        print("|---|---|---|---|---|")
        for (typ, model), n in fleet_tokens.most_common():
            c, _ = est_cost({(typ, model): fleet_usage.get((typ, model), Counter())})
            print(f"| {typ} | {model} | {n:,} | {100 * n / total_out:.0f}% | "
                  f"{f'${c:,.2f}' if price_of(model) else 'unpriced'} |")
        per_ship = (f"${cost_per_shipped:,.2f} / {out_per_shipped:,} output tokens per shipped issue "
                    f"({len(all_shipped)} shipped)" if all_shipped else "no shipped issues to normalize against")
        think = (f"main-loop thinking ≈ {100 * fleet_think:.0f}% of its output tokens (residual estimate)"
                 if fleet_think is not None else "main-loop thinking share unmeasurable")
        unpriced_note = f" · excluded from $ (no price row): {', '.join(sorted(unpriced))}" if unpriced else ""
        print(f"\n**Cost estimate** — ${fleet_cost:,.2f} at list prices (input + cache + output; cache "
              f"writes at the 1h-TTL rate) · {per_ship} · {think}{unpriced_note}\n")
    else:
        print("- no usage data found in transcripts\n")

    print("## Rate-limit windows\n")
    if peak_5h:
        print(f"| window | peak output tokens | window started |")
        print(f"|---|---|---|")
        print(f"| 5h (burst) | {peak_5h:,} | {peak_5h_at:%Y-%m-%d %H:%M UTC} |")
        print(f"| 168h (weekly) | {peak_wk:,} | {peak_wk_at:%Y-%m-%d %H:%M UTC} |")
        if peak_5h_cache_read:
            print(f"\nIn that same 5h window: **{peak_5h_cache_read:,} cache-read** and "
                  f"**{peak_5h_total:,} total billable** tokens "
                  f"({peak_5h_cache_read / peak_5h:,.0f}x the output volume). Output tokens are the "
                  f"sizing unit by convention, not by evidence — on 2026-08-06 a fleet was cut off at "
                  f"an output peak BELOW one a previous run had survived, which is what a limit "
                  f"metering some other quantity looks like. Record both every run; two runs whose cutoffs "
                  f"agree on one column and not the other settle it.")
        print(f"\nAt the 5h peak: **{peak_5h_concurrency} concurrent sessions**, "
              f"**{peak_5h_rate:,} output tokens per session-hour**.  "
              f"Across all {len(sessions)} sessions ({session_hours:,.0f} session-hours) the mean is "
              f"{burn_rate_all:,} — lower because it pools idle and interactive sessions with fleet "
              f"ones. **Size with the peak rate, not the mean.**\n")
        print("Both peaks are FLOORS on the real ceilings — they record what was survived, and every "
              "observation comes from a run that was never throttled hard enough to notice. Size a "
              "fleet so its projected burn stays under the observed peak, never up to a limit these "
              "numbers do not establish. Scale by proportion — at concurrency `n` expect roughly "
              f"`{peak_5h:,} x n/{peak_5h_concurrency}` per 5h window — and treat that as an "
              "over-estimate: the rate sags as sessions are added, because merge-queue "
              "serialization buys idle time.\n")
    else:
        print("- no timestamped usage found; rolling-window burn not computable\n")
    if stall_groups:
        for g in stall_groups:
            keys = ", ".join(f"`{m[1]['run_key']}`" for m in g)
            when = g[-1][0]
            lost = sum(m[2]["seconds"] or 0 for m in g) / 3600
            resumed = [m[2]["resumed"] for m in g if m[2]["resumed"]]
            print(f"- **quota-stall fingerprint** — {len(g)} sessions ({keys}) went quiet within "
                  f"120s of each other at {when:%Y-%m-%d %H:%M UTC}. "
                  f"A deadline wind-down ends sessions one at a time, each tagged; an account-level "
                  f"cutoff stops them together, mid-issue.")
            if resumed:
                print(f"  They resumed by {max(resumed):%Y-%m-%d %H:%M UTC} and drained normally, so "
                      f"their terminal tags and end-of-run bookkeeping look clean — **{lost:.1f} "
                      f"session-hours produced nothing**. Size the next fleet against the allowance "
                      f"this run actually had, not the wall-clock it was given.\n")
            else:
                print("  None emitted a terminal tag, so they never recovered. Check those worktrees "
                      "for unfinished work before reaping anything.\n")

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
        if a["contam_halts"]:
            flagged = True
            print(f"- **`{s['run_key']}` hit {len(a['contam_halts'])} contamination halt(s)** "
                  f"({', '.join(sorted(a['contam_halts']))}) — adjudicate each true/false positive "
                  f"(mis-bound delegate vs concurrent main-checkout activity); the false-positive "
                  f"rate is what decides whether further relaxation of the contamination response "
                  f"is justified.")
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
