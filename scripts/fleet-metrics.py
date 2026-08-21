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
  .../subagents/agent-<id>.meta.json        the dispatch's agentType + description, for exact token
                                            and lane (implementation vs fix-batch) attribution
  <checkout>/tmp/fleet-shipped-issues.json  optional Linear export of the SHIPPED issues (identifier,
                                            createdAt, creator) for the provenance join; see
                                            --linear-issues
  <checkout>/tmp/fleet-linear-window.json   retro Step 3's created-in-window census — provenance
                                            fallback: a shipped issue found HERE was filed by the
                                            run it shipped in

WHAT IT WRITES
  <checkout>/tmp/fleet-metrics-history.jsonl  one headline row per measured fleet, keyed by session
                                            set (re-runs replace, never duplicate; --all sweeps are
                                            not recorded) — the cross-run trend the report's tail
                                            renders. THIS is where the fixed schema pays off: the
                                            2026-08-14 cost-per-issue regression ($90 → $161 over
                                            five fleets) sat fully measured in per-run reports that
                                            nothing ever diffed.

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
  --linear-issues P [P ...]   Linear export(s) for the shipped-issue provenance join; default
                              tmp/fleet-shipped-issues.json + tmp/fleet-linear-window.json
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
from statistics import median

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
# WHICH allowance actually cut a run off, read from the harness message rather than inferred from the
# stall's shape. There are three distinct limits and they carry different sizing levers, so guessing
# routes the whole retro at the wrong one: `weekly` caps total session-hours (lever: duration), while
# the 5h burst caps concurrency (lever: n). Measured on the 2026-08-08 basefund fleet, whose sessions
# all printed "You have hit your weekly limit - resets Aug 11 at 5pm": a retro that assumed the 5h burst
# compared that cutoff against 2026-08-07's *session*-limit event and found their trailing-5h
# total-billable volumes agreed to 0.08% — a coincidence between two different limits that read exactly
# like the meter had been identified.
#
# `session` is NOT per-session, whatever the word suggests — measured 2026-08-14. Both that fleet's
# cutoffs reported `session`, and both were account-level 5h windows: the named resets fell on exact 5h
# boundaries (12:10am, 5:10am, 10:10am CDT) and every session then making a request was refused within
# 9s and 32s respectively. The one session that missed both was idle at those instants, so it made no
# request to be refused — absence from a cutoff measures activity, not scope. Route `session` as `5-hour`.
LIMIT_HIT = re.compile(r"hit your (weekly|session|5-hour|usage) limit", re.I)
# The reset the harness names alongside the refusal — the only source for how long the allowance itself
# was going to bind, which is what separates unavoidable wait from avoidable recovery lag. Two forms:
# 5h/session cutoffs name a clock time ("resets 5:10am (America/Chicago)"); weekly cutoffs name a DATE
# with an often minute-less time ("resets Aug 18 at 2am (America/Chicago)") — the 2026-08-16 weekly
# stall had a computable recovery lag that went unmeasured because only the first form parsed (BF-1206).
LIMIT_RESET = re.compile(r"resets\s+(\d{1,2}):(\d{2})\s*([ap])m\s*\(([^)]+)\)", re.I)
LIMIT_RESET_DATE = re.compile(
    r"resets\s+([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+(\d{1,2})(?::(\d{2}))?\s*([ap])m\s*\(([^)]+)\)", re.I)
MONTHS = {m: i + 1 for i, m in enumerate(
    ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"])}
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
# Paired with quality-review-write-verdict.sh's WARN: a verdict that filed issues owes a record of the
# sibling collision edges it wired (or `none owed`) — a never-attempted wiring was indistinguishable
# from none-owed, and unwired same-mechanism siblings recurred on two consecutive fleets (BF-1226).
V_EDGES_LINE = re.compile(r"^Collision edges:\s*(.+?)$", re.M)
V_SEVERITY = re.compile(r"\b(CRIT(?:ICAL)?|HIGH|MED(?:IUM)?)\b")
# NICE-TO-HAVE is in the origin alternation but deliberately not in V_SEVERITY: the C/H/M columns and
# crit_high_per_review count the substantive tiers only, while the origin mandate covers "wherever a
# severity tag renders" — the 2026-08-17 fleet's BF-837 authored 9 compliant tags of which 3
# NICE-TO-HAVE/plan were silently dropped from the aggregate (BF-1248). Keep in sync with
# quality-review-write-verdict.sh's origin_re, which warns at write time on the same pattern.
V_ORIGIN = re.compile(r"\b(?:CRIT(?:ICAL)?|HIGH|MED(?:IUM)?|NICE-TO-HAVE)/(plan|impl|spec|test|latent)\b")
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


def _census_dispatch_typed(agg, bg):
    """Typed-intent fallback for dispatches whose result cannot testify (errored or dangling)."""
    if bg is False:
        agg["dispatch"]["sync"] += 1
    elif bg is None or bg is True:
        agg["dispatch"]["background"] += 1
    else:
        agg["dispatch"]["ignored"] += 1


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


def subagent_meta(path):
    """agent-<id>.jsonl sits next to agent-<id>.meta.json, which records the Agent dispatch's
    agentType and description — exact attribution, vs. guessing the type from prompt text."""
    try:
        meta = json.loads(path.with_name(path.stem + ".meta.json").read_text())
        return meta.get("agentType") or "unknown", meta.get("description") or ""
    except (OSError, json.JSONDecodeError):
        return "unknown", ""


def scan_transcript(path, agg, agent_type="main", description=""):
    """Fold one transcript (session or subagent) into agg. Subagents share the parent's totals on
    purpose: a classifier block inside a delegated reviewer is the parent's lost time."""
    rows = load(path)
    pending, times = {}, []
    d_model, d_out, d_first_user = None, 0, None
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
                # Prompt context per call (input + cache write + cache read), bucketed by size — the
                # autocompact-tuning gauge. Cache reads scale linearly with context, so the share of
                # volume in the top buckets is what fleet-launch's --autocompact default moves; it is
                # also the usage screen's "N% of your usage was at >150k context" number, measured
                # from our own transcripts instead of read off a UI.
                ctx = ((usage.get("input_tokens") or 0)
                       + (usage.get("cache_creation_input_tokens") or 0)
                       + (usage.get("cache_read_input_tokens") or 0))
                if ctx:
                    agg["ctx_volume"][
                        "ge400k" if ctx >= 400_000 else
                        "200_400k" if ctx >= 200_000 else
                        "150_200k" if ctx >= 150_000 else
                        "50_150k" if ctx >= 50_000 else "lt50k"] += ctx
                if agent_type != "main":
                    d_out += usage["output_tokens"]
                    if d_model is None:
                        d_model = model

        if agent_type != "main" and d_first_user is None and r.get("type") == "user":
            body = text_of(content)
            if body:
                d_first_user = body

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
                for kind in LIMIT_HIT.findall(body):
                    agg["limit_hits"][kind.lower()] += 1
                    if t and (agg["first_limit_hit"] is None or t < agg["first_limit_hit"][0]):
                        agg["first_limit_hit"] = (t, kind.lower())
                    if t:
                        agg["limit_hit_times"].append(t)
                if t:
                    for hh, mm, ampm, tzname in LIMIT_RESET.findall(body):
                        hour = int(hh) % 12 + (12 if ampm.lower() == "p" else 0)
                        agg["limit_resets"].append((t, tzname.strip(), hour, int(mm), None, None))
                    for mon, day, hh, mm, ampm, tzname in LIMIT_RESET_DATE.findall(body):
                        hour = int(hh) % 12 + (12 if ampm.lower() == "p" else 0)
                        agg["limit_resets"].append((t, tzname.strip(), hour, int(mm or 0),
                                                    MONTHS.get(mon.lower()), int(day)))
            elif b.get("type") == "tool_use":
                name = b.get("name", "")
                inp = b.get("input") or {}
                if emitted:
                    agg["visible_chars"][agent_type] += len(json.dumps(inp))
                pending[b.get("id")] = (t, name, inp)
                agg["tool_calls"] += 1
                # Agent dispatches are censused at RESULT time, not here: the typed run_in_background
                # value records intent, and the parameter is feature-flagged — on a harness without it
                # a typed False is silently accepted and the dispatch backgrounds anyway. Only the tool
                # result discriminates what actually happened (an "Async agent launched successfully"
                # line vs the agent's report inline). Dispatches whose result never arrives fall back
                # to the typed value at end-of-transcript, below.
                if name == "ScheduleWakeup":
                    agg["wakeups"] += 1
                    if inp.get("stop") is True:
                        agg["wakeup_stops"] += 1
                        if t:
                            agg["stop_times"].append(t)
            elif b.get("type") == "tool_result":
                use = pending.pop(b.get("tool_use_id"), None)
                if not use:
                    continue
                t0, name, inp = use
                body = result_text(b)
                if name == "Agent":
                    bg = inp.get("run_in_background")
                    if b.get("is_error"):
                        _census_dispatch_typed(agg, bg)   # an errored dispatch never ran either way
                    elif "Async agent launched successfully" in body:
                        # Backgrounded in fact. A typed boolean False here means the harness ignored
                        # the parameter — the "ignored" bucket is the per-dispatch signal that this
                        # session ran on a harness without run_in_background.
                        agg["dispatch"]["ignored" if bg is False else "background"] += 1
                    else:
                        # The report came back inline: the dispatch genuinely blocked.
                        agg["dispatch"]["sync"] += 1
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
    # Dispatches with no surviving result (session died, transcript truncated) census by typed
    # intent — the only evidence left.
    for (_t0, p_name, p_inp) in pending.values():
        if p_name == "Agent":
            _census_dispatch_typed(agg, p_inp.get("run_in_background"))
    agg["dangling"] += len(pending)
    if times:
        agg["first"] = min([agg["first"], min(times)]) if agg["first"] else min(times)
        agg["last"] = max([agg["last"], max(times)]) if agg["last"] else max(times)
    if agent_type != "main":
        # The issue id comes from the meta description when it names one, else the modal id in the
        # dispatch prompt (Counter ties keep the first-mentioned, which is the task's own issue in
        # every observed prompt shape — context sections cite other issues, but later and less often).
        m = V_ISSUE_ID.search(description)
        ids = [m.group(0)] if m else V_ISSUE_ID.findall(d_first_user or "")
        agg["dispatches"].append({
            "agent_type": agent_type, "description": description,
            "issue": Counter(ids).most_common(1)[0][0] if ids else None,
            "first": min(times) if times else None,
            "model": d_model, "output_tokens": d_out,
        })


def new_agg():
    return {
        "first": None, "last": None, "tool_calls": 0, "wakeups": 0, "wakeup_stops": 0,
        "loop_firings": 0, "human_prompts": 0, "terminal_tags": 0, "dangling": 0,
        "dispatch": Counter(), "classifier_blocks": [], "gaps": [], "activity_times": [],
        "sleep_blind_s": 0.0, "sleep_blind_n": 0, "sleep_marker_s": 0.0, "sleep_marker_n": 0,
        "ship_tags": set(), "cancel_tags": set(), "contam_halts": set(), "subagents": 0,
        "limit_hits": Counter(), "first_limit_hit": None, "limit_resets": [],
        "limit_hit_times": [], "stop_times": [],
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
        "usage": {}, "visible_chars": Counter(), "ctx_volume": Counter(),
        # One record per subagent transcript (agentType, issue, start, model, output) — the
        # per-dispatch dimension the (agent, model) Counter throws away. The developer-lanes split
        # needs it: WHICH dispatches were implementation is invisible in aggregate.
        "dispatches": [],
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


def all_silences(agg, min_s=1800):
    """EVERY stretch this session spent emitting nothing at all, as [(start, end, seconds), ...].

    Distinct from agg["gaps"], which times a single tool_use against its tool_result and so only
    ever sees a SLOW CALL. A quota cutoff produces no call to be slow — the session stops emitting
    rows entirely — so it is invisible there and visible only as wall-clock silence. Measured over
    the union of the session's own rows and its subagents': a delegate working for 40 minutes while
    the parent waits is not an idle fleet.

    ALL of them, not the longest: an allowance that refills on a fixed period cuts a long fleet off
    once per period, and reporting only the worst hides every other cutoff — including the ones whose
    recovery WORKED, which are precisely the control that says whether the bad one was avoidable.
    Measured on the 2026-08-14 basefund fleet: cutoffs at 04:48 and 10:05 UTC (5h-spaced resets), and
    a longest-only detector saw only the second. The first was the informative one — all three sessions
    had a wakeup pending and resumed 1-8 min after reset, against 2h29m for the two that did not.
    """
    times = sorted(agg["activity_times"])
    out = []
    for a, b in zip(times, times[1:]):
        secs = (b - a).total_seconds()
        if secs >= min_s:
            out.append((a, b, secs))
    return out


def longest_silence(agg, min_s=1800):
    """The single longest silence, or None. Retained for callers wanting one representative stall."""
    sils = all_silences(agg, min_s)
    return max(sils, key=lambda s: s[2]) if sils else None


def reset_named_at(agg, when, grace_s=900):
    """The wall-clock reset the harness NAMED in the limit message nearest `when`, as a datetime.

    The limit text carries its own reset ("resets 5:10am (America/Chicago)"), which is the only way to
    separate the two costs a stall bundles together: the allowance's own duration, which nothing can
    avoid, and the RECOVERY LAG after it frees up, which is the avoidable part and the whole finding.
    Without it a 2h29m stall against a 4-minute wait reads the same as one against a 2h25m wait.

    Resolved against the limit hit's own date, taking the next occurrence of that clock time — resets
    are always ahead of the refusal that reports them, and the harness states no date.
    """
    hits = [h for h in agg.get("limit_resets", [])
            if abs((h[0] - when).total_seconds()) <= grace_s]
    if not hits:
        return None
    t, tzname, hh, mm, month, day = min(hits, key=lambda h: abs((h[0] - when).total_seconds()))
    try:
        from zoneinfo import ZoneInfo
        local = t.astimezone(ZoneInfo(tzname)) if tzname else t
    except Exception:
        local = t
    if month is not None:
        # Date-form reset (weekly limits): the date is explicit, only the year is inferred — the hit's
        # own year, rolled forward when that lands in the past (the Dec 31 -> Jan 1 wrap).
        cand = local.replace(month=month, day=day, hour=hh, minute=mm, second=0, microsecond=0)
        if cand < local - timedelta(hours=1):
            cand = cand.replace(year=cand.year + 1)
    else:
        cand = local.replace(hour=hh, minute=mm, second=0, microsecond=0)
        if cand <= local:
            cand += timedelta(days=1)
    return cand.astimezone(timezone.utc)


def trailing_at(token_events, cache_events, at, window_h=5):
    """Output / cache-read / total-billable credited in the `window_h` hours ENDING at `at` (datetime).

    The peak window and the CUTOFF window are different windows, and only the second bounds the
    allowance. Measured on the 2026-08-08 basefund fleet: the output peak sat in 03:20-08:20 UTC while
    the cutoff landed at 09:23, so the peak reported a burn the limit had already tolerated an hour
    earlier.

    COMPARE ONLY CUTOFFS OF THE SAME `limit_kind`, and check that field before reading anything into
    these numbers. A 5h window is the wrong instrument for a weekly cutoff, and the resulting
    coincidences are convincing: this function was first written after observing that trailing-5h
    total-billable agreed to 0.08% across the 2026-08-06 and 2026-08-08 basefund cutoffs (1,548,673,552
    against 1,547,413,211) where output differed 23% (1,597,508 against 1,301,178) — which looked like
    the meter had finally been identified. It was not. The transcripts name two DIFFERENT limits:
    2026-08-08 was `weekly`, and the 2026-08-07 04:47 UTC event compared against it was a per-`session`
    limit. Two unrelated ceilings agreeing to 0.08% is noise that survived three consistency checks.
    The 5h columns stay here because they are the right instrument once a genuine 5h-burst cutoff is
    observed; until then they are recorded, not interpreted.
    """
    lo = at.timestamp() - window_h * 3600
    hi = at.timestamp()
    return {
        "output_tokens": sum(n for t, n in token_events if lo <= t <= hi),
        "cache_read_tokens": sum(e[1] for e in cache_events if lo <= e[0] <= hi),
        "total_billable_tokens": sum(e[2] for e in cache_events if lo <= e[0] <= hi),
    }


def _ended_loop_by(agg, when, grace_s=120):
    """Did this session deliberately end its loop at or just before `when`?

    The grace window absorbs the tail a clean wind-down emits after its stop call — the final summary
    message lands a few seconds later, so the silence starts slightly after the stop rather than on it.
    """
    return any((when - st).total_seconds() >= -grace_s for st in agg["stop_times"])


def _hit_limit_by(agg, when):
    """Had the harness already refused this session on an allowance by `when`?

    A limit hit outranks a stop call: a session can be throttled mid-turn and then wind down, and that
    is a stall with a tidy ending, not a voluntary exit.
    """
    fl = agg["first_limit_hit"]
    return bool(fl) and fl[0] <= when


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
    47% of the fleet's capacity had been lost.

    Cluster on BOTH timestamps a stall exposes, because which one is tight varies by run and the
    loose one alone finds nothing. Going quiet is not synchronized: a session keeps emitting rows
    until its own last in-flight delegate drains, so onset records when that session ran out of work
    to finish, not when the allowance bound. Resuming IS synchronized — the allowance frees at one
    wall-clock moment for the whole account. Measured on the 2026-08-08 basefund fleet, where all
    three sessions stalled: onset spread 56.2 min (consecutive deltas 3013s and 359s, so a
    120s onset-only rule grouped nothing and the run reported no stall while 26.1 session-hours were
    dead), against a resume spread of 2.1 min (deltas 19s and 107s, which groups cleanly). The
    2026-08-06 fleet was the reverse — tight on both — which is why onset-only survived that run.
    Single-linkage over the union of the two dimensions catches either shape and can only ever add
    to what onset-only found.
    """
    # An `unrecovered` mark means "stopped and never came back", which cannot be asserted about a
    # session whose last activity is minutes old — that is what a LIVE session looks like, and two of
    # them are always within cluster_s of each other, so they always form a group. The group is
    # visibly empty (0 lost hours, no limit_kind, no resume) but nothing keys on that, so it still
    # fires the CEILINGS banner that /fleet-launch sizes the next fleet against. Require the silence
    # to have lasted at least min_silence_s before calling it a stall, exactly as the recovered arm
    # already does via longest_silence().
    now = datetime.now(timezone.utc)
    marks = []
    for s in sessions:
        if not s["agg"]["last"]:
            continue
        sils = all_silences(s["agg"], min_silence_s)
        # Anchored stalls are found by the limit message, not by duration, so they need the unfiltered
        # gap list — 60s keeps out the ordinary tick without imposing a duration judgement.
        sils_any = all_silences(s["agg"], 60)
        # A silence that STARTS at a deliberate loop end is not a stall — an ended loop has no wakeup
        # pending, so going quiet is the contract, not a fault. Without this, such a session joins the
        # group on its resume time and its whole quiet stretch is billed as lost capacity. Measured on
        # the 2026-08-08 basefund fleet: ed644317 read the deadline with 18 minutes left, judged it too
        # little to ship an issue averaging 1.5-2.5h, emitted AUTO-HALTED and called
        # ScheduleWakeup(stop: true) — textbook wind-down — and its 9.3h of correct silence inflated the
        # group's lost total from 16.8 to 26.1 session-hours, making exemplary judgement look like a
        # 9.3h fault. The two genuinely-stalled siblings printed a harness limit message instead.
        sil = max(sils, key=lambda x: x[2]) if sils else None
        if sil and not _hit_limit_by(s["agg"], sil[0]) and _ended_loop_by(s["agg"], sil[0]):
            sil = None
        # Limit-ANCHORED stalls, in addition to the longest-silence one above. A duration threshold is
        # the wrong instrument for a cutoff whose allowance resets soon: on 2026-08-14 the 04:48 cutoff
        # produced 27-30 min silences — under the 30-min floor, and shorter than the same sessions'
        # ordinary delegate waits — so no duration rule could separate it from normal work. The limit
        # message can: a session that printed one and then went quiet is stalled by definition, however
        # briefly. Keeping that cutoff is what makes the expensive one interpretable, since it is the
        # control showing recovery worked when a wakeup happened to be pending.
        # Match the gap that STARTS at the refusal, never the one that ends there. An inclusive match on
        # both ends picks up the preceding gap too, which credits the stall to whatever the session was
        # last doing before it was refused — off by one whole gap, and in a sparse transcript that can be
        # hours. The grace absorbs the couple of rows a session emits after the message (a second
        # refusal, a turn_duration) before it truly goes dark.
        anchored = []
        for hit_t in s["agg"]["limit_hit_times"]:
            nxt = next((x for x in sils_any
                        if 0 <= (x[0] - hit_t).total_seconds() <= 300), None)
            if nxt and (sil is None or nxt[0] != sil[0]) and nxt not in anchored:
                anchored.append(nxt)
        for x in ([sil] if sil else []) + anchored:
            # The reset the harness named is what the wait SHOULD have been; anything past it is
            # recovery lag, and recovery lag is the only part a fix can reach.
            reset = reset_named_at(s["agg"], x[0])
            lag = (x[1] - reset).total_seconds() if reset else None
            marks.append((x[0], s, {"kind": "recovered", "resumed": x[1], "seconds": x[2],
                                    "reset_at": reset, "recovery_lag_s": lag}))
        if not sil and not anchored and (not s["agg"]["terminal_tags"]
                                         and (now - s["agg"]["last"]).total_seconds() >= min_silence_s):
            marks.append((s["agg"]["last"], s, {"kind": "unrecovered", "resumed": None, "seconds": None}))
    if len(marks) < 2:
        return []
    marks.sort(key=lambda m: m[0])
    parent = list(range(len(marks)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    def union(i, j):
        ri, rj = find(i), find(j)
        if ri != rj:
            parent[max(ri, rj)] = min(ri, rj)

    for key in (lambda m: m[0], lambda m: m[2]["resumed"]):
        pts = sorted((key(m), i) for i, m in enumerate(marks) if key(m) is not None)
        for (t0, i0), (t1, i1) in zip(pts, pts[1:]):
            if (t1 - t0).total_seconds() <= cluster_s:
                union(i0, i1)
    groups = {}
    for i, m in enumerate(marks):
        groups.setdefault(find(i), []).append(m)
    # Count DISTINCT SESSIONS, not marks. Now that every qualifying silence is marked, one session can
    # contribute several to a cluster; the fingerprint this function exists to find is "sessions stopped
    # TOGETHER", which one session's own two gaps do not evidence.
    return sorted((sorted(g, key=lambda m: m[0]) for g in groups.values()
                   if len({id(m[1]) for m in g}) >= 2),
                  key=lambda g: g[0][0])


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


def developer_lanes(sessions):
    """Split developer output by lane — pre-review implementation vs post-review fix batches — and
    name the tier that implemented each issue.

    The by-model token table cannot answer "what tier implements": /quality-review pins fix batches
    to sonnet-tier developer agents, so developer/sonnet dominates that table no matter what wrote
    the initial implementation. Measured on the 2026-08-09 basefund fleet, whose retro read that
    table as "72% of developer output ran on sonnet": 86% of the developer/sonnet row was fix
    batches, and 14 of 23 issues were implemented at the opus agent default — the impl-heavy origin
    mix sat on issues already implemented at the top tier, and the flag table routed it at developer
    model anyway. A dispatch lands in `impl` when it starts before the issue's first
    quality-reviewer dispatch anywhere in the fleet, in `fix` at or after.

    Returns (lanes, impl_models, runs_with_records): {lane: Counter(model -> output tokens)},
    {issue: sorted models that ran its implementation dispatches}, and the run keys with surviving
    subagent transcripts. An issue shipped by a run in that last set with no impl dispatch was
    implemented by the main loop directly; without surviving records that claim would be a guess, so
    callers report unknown instead.
    """
    review_start = {}
    for s in sessions:
        for d in s["agg"]["dispatches"]:
            if d["agent_type"] == "quality-reviewer" and d["issue"] and d["first"]:
                cur = review_start.get(d["issue"])
                review_start[d["issue"]] = min(cur, d["first"]) if cur else d["first"]
    lanes = {"impl": Counter(), "fix": Counter(), "unattributed": Counter()}
    impl_models = {}
    runs_with_records = set()
    for s in sessions:
        if s["agg"]["dispatches"]:
            runs_with_records.add(s["run_key"])
        for d in s["agg"]["dispatches"]:
            if d["agent_type"] != "developer":
                continue
            model = d["model"] or "?"
            if not d["issue"]:
                lanes["unattributed"][model] += d["output_tokens"]
                continue
            rs = review_start.get(d["issue"])
            lane = "impl" if not rs or (d["first"] and d["first"] < rs) else "fix"
            lanes[lane][model] += d["output_tokens"]
            if lane == "impl":
                impl_models.setdefault(d["issue"], set()).add(model)
    return lanes, {k: sorted(v) for k, v in impl_models.items()}, runs_with_records


def tier_short(model):
    for t in ("opus", "sonnet", "haiku", "fable"):
        if t in model:
            return t
    return model


CTX_BUCKETS = ("lt50k", "50_150k", "150_200k", "200_400k", "ge400k")
CTX_LABELS = {"lt50k": "<50k", "50_150k": "50-150k", "150_200k": "150-200k",
              "200_400k": "200-400k", "ge400k": ">=400k"}


def ctx_shares(vol):
    """(share of prompt volume at >=150k context, at >=200k, total volume) for one ctx_volume Counter."""
    total = sum(vol.values())
    if not total:
        return None, None, 0
    ge150 = sum(vol[b] for b in ("150_200k", "200_400k", "ge400k"))
    return ge150 / total, (vol["200_400k"] + vol["ge400k"]) / total, total


def linear_issue_index(paths):
    """({identifier: {created_at, creator}}, files actually read) from Linear issue exports.

    Accepts a raw GraphQL response ({data:{issues:{nodes:[...]}}}) or a bare node list — the shapes
    retro Step 3's queries produce. Earlier files win on conflicts, so the precise per-issue export
    (fleet-shipped-issues.json) is passed ahead of the created-in-window census."""
    idx, read = {}, []
    for p in paths:
        p = Path(p)
        try:
            data = json.loads(p.read_text())
        except (OSError, json.JSONDecodeError):
            continue
        nodes = data if isinstance(data, list) else \
            ((((data.get("data") or {}).get("issues") or {}).get("nodes"))
             or data.get("nodes") or [])
        if not isinstance(nodes, list):
            continue
        read.append(str(p))
        for n in nodes:
            if isinstance(n, dict) and n.get("identifier"):
                creator = n.get("creator") or {}
                idx.setdefault(n["identifier"], {
                    "created_at": ts(n.get("createdAt")),
                    "creator": creator.get("displayName") or creator.get("name"),
                })
    return idx, read


def record_history(checkout, headline, record):
    """Append `headline` to tmp/fleet-metrics-history.jsonl and return the full history.

    The whole point of this script's fixed schema is that runs can be diffed — and until this ledger
    existed the diff step was manual, so it never happened: the 2026-08-14 cost-per-issue regression
    climbed monotonically across five fleets' saved reports with nothing comparing them. Rows are
    keyed by the sorted session set, so re-running a retro over the same fleet (different flags,
    --json vs markdown) replaces its row instead of duplicating it. `record=False` (the --all sweep:
    an all-time pool is not a fleet, and one row of it would dwarf the trend) still returns the
    stored history so the trend renders."""
    path = checkout / "tmp" / "fleet-metrics-history.jsonl"
    rows = []
    try:
        for line in path.read_text().splitlines():
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    except OSError:
        pass
    if record:
        rows = [r for r in rows if r.get("session_set") != headline["session_set"]]
        rows.append(headline)
    rows.sort(key=lambda r: r.get("fleet_start") or "")
    if record:
        try:
            path.write_text("".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
        except OSError as e:
            print(f"WARN: could not write {path}: {e}", file=sys.stderr)
    return rows


def parse_verdicts(checkout, cutoff, launch_epoch=None, until=None):
    """One row per quality-review verdict file in the window: the review-churn half of the retro.
    Counts are self-reported by the review pipeline — the audit record, not independent ground truth.

    launch_epoch drops verdicts written by a PRIOR fleet. The session filter alone does not reach these:
    verdict files are globbed off disk, not attributed through the session set, so a prior run's reviews
    keep landing in the churn totals after its ledger is correctly excluded — which is how the 2026-08-21
    retro read 7 reviews / 58 findings / severity 1/5/28 for a fleet whose real numbers were 5 / 46 / 0/3/19."""
    rows = []
    for p in sorted((checkout / "tmp").glob("quality-review-verdict-*.md")):
        mtime = datetime.fromtimestamp(p.stat().st_mtime, timezone.utc)
        if cutoff and mtime < cutoff:
            continue
        if isinstance(launch_epoch, (int, float)) and int(p.stat().st_mtime) <= launch_epoch:
            continue
        if until and mtime > until:
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
            "edges_recorded": bool(V_EDGES_LINE.search(text)),
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
            # Two landing shapes, and the flag must accept both or it fires on every ship of the
            # other one: `/finish merge` writes `Merge <ID>`, while `/finish pr` lands through
            # GitHub as `Merge pull request #N from <owner>/<branch>` — where the issue id appears
            # only inside the branch name, lowercased. Measured on JA 2026-08-20: three PR-flow
            # ships (JA-291, JA-321, JA-367), three false flags, each cleared by a hand `gh pr view`.
            "merge": bool(
                re.search(rf"Merge {issue}\b", commits)
                or re.search(rf"Merge pull request #\d+ from \S*{issue.lower()}\b", commits)
            ),
        }
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkout", default=".")
    ap.add_argument("--hours", type=float, default=36.0)
    ap.add_argument("--since")
    ap.add_argument("--until",
                    help="ISO date/datetime (UTC); exclude sessions whose activity starts after it. "
                         "With --since, scopes to exactly one fleet when another starts inside the "
                         "window.")
    ap.add_argument("--sessions",
                    help="Comma-separated run keys (e.g. 7d1f4d17,40a56675,9c0e0a3b). Overrides "
                         "every window flag — the exact-set escape hatch for overlapping fleets.")
    ap.add_argument("--all", action="store_true")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--linear-issues", nargs="*", default=None,
                    help="Linear issue export(s) — a GraphQL response or bare node list with "
                         "identifier/createdAt/creator — joined against the shipped set for the "
                         "provenance split")
    args = ap.parse_args()

    checkout = Path(args.checkout).resolve()
    try:
        checkout = Path(subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=15, check=True).stdout.strip())
    except (subprocess.SubprocessError, OSError):
        pass

    # A fleet is a session set, not a time range — an explicit --sessions set overrides every
    # window flag, including the recent-end bound.
    req_keys = {k.strip() for k in args.sessions.split(",") if k.strip()} if args.sessions else None

    if req_keys or args.all:
        cutoff = None
    elif args.since:
        cutoff = datetime.fromisoformat(args.since).replace(tzinfo=timezone.utc)
    else:
        cutoff = datetime.now(timezone.utc) - timedelta(hours=args.hours)
    until = datetime.fromisoformat(args.until).replace(tzinfo=timezone.utc) \
        if args.until and not req_keys else None

    # A ledger whose last write lands at or before launch_epoch belongs to a PRIOR fleet: fleet-launch
    # stamps that epoch as it dispatches, so such a session had not started when the write happened.
    # The tie is the trap — measured 2026-08-21, a prior session's ledger matched launch_epoch to the
    # second and rode a whole retro as a fleet member, inflating shipped 5→7, session-hours 7.4→12.0,
    # and severity/origin mixes with a run nobody was measuring. Mirrors fleet-status.sh's -le.
    launch_epoch = None
    try:
        launch_epoch = json.loads((checkout / "tmp" / "fleet-deadline.json").read_text()).get("launch_epoch")
    except (json.JSONDecodeError, OSError, AttributeError):
        pass

    states = []
    prior_run_keys = set()
    for p in sorted((checkout / "tmp").glob("auto-state-*.json")):
        if req_keys is not None and p.stem.replace("auto-state-", "") not in req_keys:
            continue
        mtime = datetime.fromtimestamp(p.stat().st_mtime, timezone.utc)
        if cutoff and mtime < cutoff:
            continue
        # int() the mtime: launch_epoch is whole seconds while st_mtime carries a fraction, so a raw
        # `<=` lets a same-second ledger through on the sub-second remainder (…573.448 > …573) and the
        # filter silently does nothing. fleet-status.sh compares `stat -f %m`, which truncates already.
        if isinstance(launch_epoch, (int, float)) and int(p.stat().st_mtime) <= launch_epoch:
            prior_run_keys.add(p.stem.replace("auto-state-", ""))
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
                scan_transcript(tpath, agg, *subagent_meta(tpath))
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
    # Seed with the prior-run keys too, or this pass re-adopts every ledger the launch_epoch filter just
    # dropped: its adopt-the-real-ledger branch below reads the same state file straight back off disk,
    # so filtering pass 1 alone silently changes nothing.
    seen_keys = set(state_keys) | prior_run_keys
    for d in dirs:
        for tpath in sorted(d.glob("*.jsonl")):
            run_key = tpath.stem.split("-")[0]
            if run_key in seen_keys:
                continue
            if req_keys is not None and run_key not in req_keys:
                continue
            mtime = datetime.fromtimestamp(tpath.stat().st_mtime, timezone.utc)
            if cutoff and mtime < cutoff:
                continue
            # An explicitly requested key skips the is_auto_session probe — the operator named it.
            if req_keys is None and not is_auto_session(tpath):
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

    # A requested key with nothing on disk is a hard error, never a silent drop — a silently
    # smaller set is exactly the mislabeled-fleet failure --sessions exists to fix.
    if req_keys is not None:
        missing = sorted(req_keys - seen_keys)
        if missing:
            print(f"--sessions: no auto-state file or transcript found for: {', '.join(missing)}",
                  file=sys.stderr)
            return 1

    if not states and not ledgerless:
        print(f"No auto-state files or /auto transcripts under {checkout}/tmp matching the window. "
              f"Try --hours/--since/--until/--all, or --sessions <run-keys>.", file=sys.stderr)
        return 1

    sessions = []
    for path, state, mtime in states:
        sessions.append(measure(path.stem.replace("auto-state-", ""), state, mtime))
    for run_key, mtime in ledgerless:
        sessions.append(measure(run_key, {}, mtime, ledger_missing=True))
    sessions.sort(key=lambda s: s["agg"]["first"] or datetime.max.replace(tzinfo=timezone.utc))

    # A file mtime is not activity: transcript trailing metadata (ai-title/agent-name rows) can touch
    # a long-finished session's file days later, and the adoption pass above then pools that session
    # into this fleet's totals (2026-08-13: a run whose last message was Aug 10 05:56 UTC entered an
    # Aug 13 retro through an Aug 13 00:58 metadata touch — 25 shipped reported for a fleet that
    # shipped 19, 49.8 session-hours for 36.9). The window means activity, so gate on the measured
    # last message timestamp — and report who was dropped rather than shrinking the fleet silently.
    # Sessions with no measurable activity (agg.last is None) are kept: absence of transcripts is a
    # fault to surface, not staleness.
    excluded_stale = []
    if cutoff or until:
        kept = []
        for s in sessions:
            if cutoff and s["agg"]["last"] is not None and s["agg"]["last"] < cutoff:
                excluded_stale.append({"run_key": s["run_key"],
                                       "end_epoch": s["agg"]["last"].timestamp(),
                                       "ended": f"{s['agg']['last']:%Y-%m-%dT%H:%M:%SZ}"})
            # --until means "started after the window": a later fleet's session, measured by its
            # own first activity — a state-file or transcript mtime is a last-write, not a start.
            elif until and s["agg"]["first"] is not None and s["agg"]["first"] > until:
                excluded_stale.append({"run_key": s["run_key"],
                                       "end_epoch": s["agg"]["first"].timestamp(),
                                       "started": f"{s['agg']['first']:%Y-%m-%dT%H:%M:%SZ}"})
            else:
                kept.append(s)
        sessions = kept
    if not sessions:
        print(f"All matched sessions fell outside the window "
              f"({', '.join(e['run_key'] for e in excluded_stale)}). "
              f"Try --hours/--since/--until/--all, or --sessions <run-keys>.",
              file=sys.stderr)
        return 1

    all_shipped = set()
    issue_run = {}
    for s in sessions:
        shipped = set(s["state"].get("shipped") or []) | s["agg"]["ship_tags"]
        all_shipped |= shipped
        for issue in shipped:
            issue_run.setdefault(issue, s["run_key"])
    merged = git_merged(checkout, all_shipped)

    # Shipped-issue provenance: how much of the throughput is work the pipeline minted for itself
    # (review deferrals, /reflect filings) vs pre-existing backlog. Issues/hour looks identical
    # either way — this join is what tells a draining backlog from a treadmill.
    fleet_first = min((s["agg"]["first"] for s in sessions if s["agg"]["first"]), default=None)
    linear_paths = [Path(p) for p in args.linear_issues] if args.linear_issues else \
        [checkout / "tmp" / "fleet-shipped-issues.json", checkout / "tmp" / "fleet-linear-window.json"]
    linear_idx, linear_read = linear_issue_index(linear_paths)
    provenance, prov_counts, prov_creators = {}, Counter(), Counter()
    for issue in sorted(all_shipped):
        rec = linear_idx.get(issue)
        created = rec["created_at"] if rec else None
        if not created or not fleet_first:
            klass = "unknown"
        elif created >= fleet_first:
            klass = "during_run"
        elif fleet_first - created <= timedelta(days=7):
            klass = "week_before"
        else:
            klass = "older"
        provenance[issue] = {"class": klass,
                             "created_at": created.strftime("%Y-%m-%dT%H:%M:%SZ") if created else None,
                             "creator": (rec or {}).get("creator")}
        prov_counts[klass] += 1
        if rec and rec.get("creator"):
            prov_creators[rec["creator"]] += 1
    prov_known = len(all_shipped) - prov_counts["unknown"]
    fresh_share = round((prov_counts["during_run"] + prov_counts["week_before"]) / prov_known, 3) \
        if prov_known else None

    # With an explicit session set there is no time window — scope the verdict sweep to the
    # selected sessions' own activity span instead, or every verdict on disk pools into this run.
    v_cutoff, v_until = cutoff, until
    if req_keys is not None:
        firsts = [s["agg"]["first"] for s in sessions if s["agg"]["first"]]
        lasts = [s["agg"]["last"] for s in sessions if s["agg"]["last"]]
        v_cutoff = min(firsts) if firsts else None
        v_until = max(lasts) if lasts else None
    verdicts = parse_verdicts(checkout, v_cutoff, launch_epoch, v_until)
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

    lanes, impl_models, runs_with_records = developer_lanes(sessions)
    for v in verdicts:
        if v["issue"] in impl_models:
            v["implemented_by"] = impl_models[v["issue"]]
        elif issue_run.get(v["issue"]) in runs_with_records:
            v["implemented_by"] = ["main-loop"]
        else:
            v["implemented_by"] = None
    # Impl-origin findings per issue grouped by implementing tier — the join that adjudicates the
    # flag table's impl-heavy row. Zero-impl issues count (a tier's clean record IS the signal);
    # verdicts with findings but no origin tags stay out, since their impl count is unknown, not 0.
    tier_join = {}
    for v in verdicts:
        if v["implemented_by"] and (v["origin"] or v["resolved"] == 0):
            label = "+".join(dict.fromkeys(tier_short(m) for m in v["implemented_by"]))
            tier_join.setdefault(label, []).append(v["origin"].get("impl", 0))
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

    fleet_ctx = Counter()
    for s in sessions:
        fleet_ctx.update(s["agg"]["ctx_volume"])
    ctx_ge150_share, ctx_ge200_share, ctx_total_vol = ctx_shares(fleet_ctx)

    # The headline row this run contributes to the cross-run trend. Cost-per-issue decomposes as
    # output-tokens-per-issue (work per issue: churn, or harder issues) x $-per-output-token (context
    # weight per unit of work) — the two move independently, so both are carried.
    total_out = sum(fleet_tokens.values())
    cyc_all = [v["cycles"] for v in verdicts if v["cycles"] is not None]
    resolved_all = sum(v["resolved"] for v in verdicts)
    tagged_all = sum(sum(v["origin"].values()) for v in verdicts)
    headline = {
        "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "fleet_start": fleet_first.strftime("%Y-%m-%dT%H:%M:%SZ") if fleet_first else None,
        "session_set": ",".join(sorted(s["run_key"] for s in sessions)),
        "sessions": len(sessions),
        "session_hours": None,  # filled below once session_hours exists
        "shipped": len(all_shipped),
        "est_cost_usd": round(fleet_cost, 2),
        "cost_per_shipped_usd": cost_per_shipped,
        "output_tokens_per_shipped": out_per_shipped,
        "usd_per_mtok_output": round(fleet_cost / total_out * 1e6, 2) if total_out else None,
        "avg_cycles": round(sum(cyc_all) / len(cyc_all), 2) if cyc_all else None,
        "findings_per_review": round(resolved_all / len(verdicts), 1) if verdicts else None,
        "crit_high_per_review": round(sum(v["sev"]["CRIT"] + v["sev"]["HIGH"] for v in verdicts)
                                      / len(verdicts), 2) if verdicts else None,
        "plan_origin_share": round(sum(v["origin"].get("plan", 0) for v in verdicts) / tagged_all, 3)
                             if tagged_all else None,
        "ctx_share_ge150k": round(ctx_ge150_share, 3) if ctx_ge150_share is not None else None,
        "ctx_share_ge200k": round(ctx_ge200_share, 3) if ctx_ge200_share is not None else None,
        "filed_per_shipped": filed_per_shipped,
        "fresh_shipped_share": fresh_share,
    }

    # Burn against the moving windows the account actually meters. /auto-prep sizes a fleet from
    # these: the 5h peak caps CONCURRENCY (n x 5 x rate), the weekly caps total session-hours.
    all_events = [e for s in sessions for e in s["agg"]["token_events"]]
    peak_5h, peak_5h_at = rolling_peak(all_events, 5)
    peak_wk, peak_wk_at = rolling_peak(all_events, 168)
    session_hours = sum(((s["agg"]["last"] - s["agg"]["first"]).total_seconds() / 3600)
                        for s in sessions if s["agg"]["first"] and s["agg"]["last"])
    headline["session_hours"] = round(session_hours, 1)
    history = record_history(checkout, headline, record=not args.all)
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

    # A stall gap that straddles the fleet deadline is only "lost" up to the deadline — quiet after it
    # is wind-down the run owed anyway (2026-08-16 pm: ~0.9 of a reported 4.2 lost session-hours were
    # post-deadline; BF-1206). The marker may be gone by retro time; clipping is best-effort.
    fleet_deadline_dt = None
    try:
        dl = json.loads((checkout / "tmp" / "fleet-deadline.json").read_text())
        if isinstance(dl.get("deadline_epoch"), (int, float)):
            fleet_deadline_dt = datetime.fromtimestamp(dl["deadline_epoch"], tz=timezone.utc)
    except Exception:
        pass

    def lost_seconds(g):
        """Sum of a stall group's gap seconds, each gap clipped at the fleet deadline when known."""
        total = 0
        for m in g:
            secs = m[2]["seconds"] or 0
            if fleet_deadline_dt is not None and secs:
                if m[0] >= fleet_deadline_dt:
                    secs = 0
                elif m[0] + timedelta(seconds=secs) > fleet_deadline_dt:
                    secs = (fleet_deadline_dt - m[0]).total_seconds()
            total += secs
        return total
    # Only a group the harness actually refused (a limit message in some member's transcript) rewrites
    # the sizing basis — an unattributed stall may be a machine sleep or daemon restart, and a ceiling
    # taken from one would under-size the next fleet against a limit that never bound.
    cutoff_groups = [g for g in stall_groups if any(m[1]["agg"]["first_limit_hit"] for m in g)]
    # Read the meters where the allowance actually bound: the EARLIEST quiet time in the group, since
    # every later one is already draining as siblings sit idle.
    all_cache_events = [e for s in sessions for e in s["agg"]["cache_events"]]
    cutoff_meters = [dict(runs=[m[1]["run_key"] for m in g], at=g[0][0],
                          **trailing_at(all_events, all_cache_events, g[0][0]))
                     for g in cutoff_groups]

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
                "context_volume_tokens": {b: s["agg"]["ctx_volume"][b] for b in CTX_BUCKETS
                                          if s["agg"]["ctx_volume"][b]},
                "ctx_share_ge200k": (lambda sh: round(sh[1], 3) if sh[1] is not None else None)(
                    ctx_shares(s["agg"]["ctx_volume"])),
                "est_cost_usd": round(est_cost(s["agg"]["usage"])[0], 4),
                "main_thinking_share_est": thinking_share([s["agg"]]),
                "long_gaps": [{"minutes": round(g[0] / 60, 1), "tool": g[1], "what": g[2]}
                              for g in sorted(s["agg"]["gaps"], reverse=True)[:5]],
            } for s in sessions],
            "review_churn": [{
                "issue": v["issue"], "run": issue_run.get(v["issue"]),
                "verdict": v["verdict"], "cycles": v["cycles"], "findings_resolved": v["resolved"],
                "severity": dict(v["sev"]), "origin": dict(v["origin"]), "filed": v["filed"],
                "missing_fields": v["missing_fields"], "implemented_by": v["implemented_by"],
            } for v in verdicts],
            "filed_per_shipped": filed_per_shipped,
            "developer_lanes": {lane: {m: n for m, n in c.most_common()}
                                for lane, c in lanes.items()},
            "impl_origin_by_tier": {label: {
                "n": len(vals), "mean": round(sum(vals) / len(vals), 2),
                "median": median(vals), "values": sorted(vals),
            } for label, vals in sorted(tier_join.items())},
            "output_tokens": {f"{t}/{m}": n for (t, m), n in fleet_tokens.most_common()},
            "usage": {f"{t}/{m}": dict(u) for (t, m), u in
                      sorted(fleet_usage.items(), key=lambda kv: -kv[1]["output"])},
            "est_cost_usd": round(fleet_cost, 4),
            "unpriced_models": sorted(unpriced),
            "main_thinking_share_est": fleet_think,
            "per_shipped": {"output_tokens": out_per_shipped, "est_cost_usd": cost_per_shipped},
            "context_distribution": {
                "volume_tokens": {b: fleet_ctx[b] for b in CTX_BUCKETS if fleet_ctx[b]},
                "share_ge150k": headline["ctx_share_ge150k"],
                "share_ge200k": headline["ctx_share_ge200k"],
            },
            "shipped_provenance": {
                "issues": provenance,
                "counts": dict(prov_counts),
                "fresh_shipped_share": fresh_share,
                "sources_read": linear_read,
            },
            "history": history,
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
                    # Distinct sessions, first-quiet order — one session contributes several MARKS to a
                    # cluster (its longest silence plus each limit-anchored gap), and a mark list read
                    # as a session list overcounted a 4-session fleet as 8 (BF-1206).
                    "runs": list(dict.fromkeys(m[1]["run_key"] for m in g)),
                    "kind": "recovered" if any(m[2]["kind"] == "recovered" for m in g) else "unrecovered",
                    "quiet_at": f"{g[0][0]:%Y-%m-%dT%H:%M:%SZ}",
                    "resumed_at": (f"{max(m[2]['resumed'] for m in g if m[2]['resumed']):%Y-%m-%dT%H:%M:%SZ}"
                                   if any(m[2]["resumed"] for m in g) else None),
                    "lost_session_hours": round(lost_seconds(g) / 3600, 1),
                    "lost_clipped_at_deadline": fleet_deadline_dt is not None,
                    # Which allowance refused the run, straight from the harness message. Decides the
                    # sizing lever: weekly -> duration, 5-hour -> concurrency, session -> neither.
                    "limit_kind": sorted({m[1]["agg"]["first_limit_hit"][1] for m in g
                                          if m[1]["agg"]["first_limit_hit"]}) or None,
                } for g in stall_groups],
                # Present ONLY when the run was cut off, and then the peaks above are ceilings rather
                # than floors. This is the column to size the next fleet against.
                "cutoff_trailing_5h": [{**{k: v for k, v in c.items() if k != "at"},
                                        "at": f"{c['at']:%Y-%m-%dT%H:%M:%SZ}"} for c in cutoff_meters],
            },
            "merge_reconciliation": merged,
            "excluded_stale": excluded_stale,
        }, indent=2))
        return 0

    print(f"# Fleet metrics — {checkout.name}\n")
    print(f"Checkout: `{checkout}`  ·  sessions: {len(sessions)}"
          f"  ·  window: {'all' if not cutoff else cutoff.strftime('%Y-%m-%d %H:%M UTC')}\n")
    if excluded_stale:
        print("Excluded from the window (stale: last activity before it; late: started after --until): "
              + ", ".join(f"`{e['run_key']}` (" + (f"ended {e['ended']}" if "ended" in e
                          else f"started {e['started']}") + ")" for e in excluded_stale) + "\n")

    print("## Per session\n")
    print("| run | span | ctx>=200k | shipped (rec/obs) | canceled (rec/obs) | wakeups | dispatch bg/sync/ign | blind sleep | marker | cls | contam | dangling |")
    print("|---|---|---|---|---|---|---|---|---|---|---|---|")
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
        _, s_ge200, s_ctx_total = ctx_shares(a["ctx_volume"])
        ctx_cell = f"{100 * s_ge200:.0f}%" if s_ctx_total else "-"
        print(f"| `{s['run_key']}`{flag} | {span:.1f}h | {ctx_cell} | {rec}/{obs} | {crec}/{cobs} | "
              f"{a['wakeups']} ({a['wakeup_stops']} stop) | "
              f"{a['dispatch']['background']}/{a['dispatch']['sync']}/{a['dispatch']['ignored']} | {blind_pct} | "
              f"{a['sleep_marker_s'] / 3600:.1f}h | {len(a['classifier_blocks'])} | "
              f"{len(a['contam_halts'])} | {a['dangling']} |")
        tot["span"] += span
        tot["blind"] += a["sleep_blind_s"]
        tot["marker"] += a["sleep_marker_s"]
        tot["cls"] += len(a["classifier_blocks"])
        tot["contam"] += len(a["contam_halts"])
        tot["bg"] += a["dispatch"]["background"]
        tot["sync"] += a["dispatch"]["sync"]
        tot["ign"] += a["dispatch"]["ignored"]
    blind_share = f"({100 * tot['blind'] / tot['span'] / 3600:.0f}% of fleet wall-clock)" if tot["span"] else "(no transcript window)"
    ign_note = f" / {tot['ign']} ignored (run_in_background absent on harness)" if tot["ign"] else ""
    print(f"\n**Totals** — {tot['span']:.1f} session-hours · blind sleep {tot['blind'] / 3600:.1f}h "
          f"{blind_share} · marker polls "
          f"{tot['marker'] / 3600:.1f}h · dispatch {tot['bg']} background / {tot['sync']} sync{ign_note} · "
          f"{tot['cls']} classifier blocks · {tot['contam']} contamination halt(s) · "
          f"{sum(fleet_tokens.values()):,} output tokens\n")
    if ctx_total_vol:
        buckets = " · ".join(f"{CTX_LABELS[b]} {100 * fleet_ctx[b] / ctx_total_vol:.0f}%"
                             for b in CTX_BUCKETS if fleet_ctx[b])
        print(f"**Context distribution** — {ctx_total_vol:,} billable prompt tokens, by context size "
              f"at call time: {buckets} → **{100 * ctx_ge150_share:.0f}% at >=150k, "
              f"{100 * ctx_ge200_share:.0f}% at >=200k**. The autocompact gauge: fleet-launch pins "
              f"`--autocompact 500000` (since 2026-08-15; the session floor is ~115-177k so the "
              f"sawtooth runs ~135k→~450k and a large >=200k shoulder is EXPECTED — the engagement "
              f"signal is nothing above ~460k). If volume appears above ~460k, compaction did not "
              f"engage (check the dispatch flags). Size distribution alone cannot show compaction "
              f"THRASH — also check cadence: compact_boundary rows per session should be a handful "
              f"per issue, tens of minutes apart; spacing collapsing to minutes is the orbit "
              f"signature (band ≈ live working set) and means the threshold is too low.\n")

    print("## Review churn\n")
    if verdicts:
        print("| issue | run | verdict | cycles | findings | C/H/M | origins | filed | impl by |")
        print("|---|---|---|---|---|---|---|---|---|")
        for v in verdicts:
            origins = " ".join(f"{k}:{n}" for k, n in v["origin"].most_common()) or "-"
            findings = "?" if "Findings resolved" in v["missing_fields"] else v["resolved"]
            impl_by = "+".join(dict.fromkeys(tier_short(m) for m in v["implemented_by"])) \
                if v["implemented_by"] else "-"
            print(f"| {v['issue']} | `{issue_run.get(v['issue'], '-')}` | {v['verdict']} | "
                  f"{v['cycles'] if v['cycles'] is not None else '?'} | {findings} | "
                  f"{v['sev']['CRIT']}/{v['sev']['HIGH']}/{v['sev']['MED']} | {origins} | "
                  f"{len(v['filed'])} | {impl_by} |")
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
        if tier_join:
            parts = " | ".join(
                f"{label} n={len(vals)} · mean {sum(vals) / len(vals):.1f} · median {median(vals):.1f}"
                for label, vals in sorted(tier_join.items()))
            print(f"**Implementing-tier join** — impl-origin findings per issue, grouped by the tier "
                  f"that ran that issue's implementation dispatch: {parts}. This is the precondition "
                  f"for the flag table's impl-heavy row: fix batches are pinned to sonnet-tier by "
                  f"/quality-review, so the by-agent token table cannot answer what tier implements — "
                  f"route an impl-heavy mix at developer model/effort only when the impl findings sit "
                  f"on the lower tier HERE.\n")
    else:
        print("- no verdict files in the window\n")

    print("## Shipped-issue provenance\n")
    if not all_shipped:
        print("- no shipped issues in the window\n")
    elif not linear_read:
        print(f"- no Linear export found ({', '.join(p.name for p in linear_paths)}) — provenance "
              f"unknown for all {len(all_shipped)} shipped issue(s). Retro Step 3 writes "
              f"`tmp/fleet-linear-window.json` (created-in-window census); for full coverage also "
              f"write `tmp/fleet-shipped-issues.json` — the shipped set queried by identifier with "
              f"`createdAt` and `creator {{ name displayName }}`.\n")
    else:
        creators = ", ".join(f"{name} ({n})" for name, n in prov_creators.most_common(4))
        fresh = (f"Fresh share **{100 * fresh_share:.0f}%** of the {prov_known} known — the treadmill "
                 f"gauge: work the pipeline minted for itself vs pre-existing backlog. "
                 if fresh_share is not None else "")
        by_creator = (f"Top creators: {creators}. " if prov_creators else
                      "No creator field in the export — include `creator { name displayName }` in the "
                      "query for the by-creator split. ")
        print(f"Of {len(all_shipped)} shipped: **{prov_counts['during_run']} created during this run**, "
              f"{prov_counts['week_before']} in the 7 days before launch, {prov_counts['older']} older, "
              f"{prov_counts['unknown']} unknown (absent from the export). {fresh}{by_creator}"
              f"Sources: {', '.join(Path(p).name for p in linear_read)}.\n")

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
        if any(lanes.values()):
            def lane_cell(c):
                return ", ".join(f"{m} {n:,}" for m, n in c.most_common()) or "none"
            unattr = (f" · unattributed {sum(lanes['unattributed'].values()):,}"
                      if lanes["unattributed"] else "")
            print(f"**Developer lanes** — implementation {sum(lanes['impl'].values()):,} "
                  f"({lane_cell(lanes['impl'])}) · post-review fix {sum(lanes['fix'].values()):,} "
                  f"({lane_cell(lanes['fix'])}){unattr}. The developer rows above sum both lanes; "
                  f"tier questions about /start Step 8 read the implementation lane only.\n")
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
                  f"metering some other quantity looks like. Record every column every run, and compare "
                  f"across runs ONLY within one `limit_kind`: three cutoffs once agreed on total "
                  f"billable to 0.08% while diverging 23% on output, and two of them were weekly limits "
                  f"against one per-session limit — unrelated ceilings coinciding.")
        # Mean exceeding the at-peak rate fingerprints a peak window that landed OUTSIDE the run under
        # review (overlap-counted concurrency inflates the divisor — e.g. an unscoped --since admitting
        # the morning-after interactive sessions). Heuristic, not proof: an idle-heavy fleet can trip it
        # legitimately, so WARN and let the operator re-scope; never refuse or alter a figure.
        rate_inverted = (burn_rate_all is not None and peak_5h_rate is not None
                         and burn_rate_all > peak_5h_rate)
        print(f"\nAt the 5h peak: **{peak_5h_concurrency} concurrent sessions**, "
              f"**{peak_5h_rate:,} output tokens per session-hour**.  "
              f"Across all {len(sessions)} sessions ({session_hours:,.0f} session-hours) the mean is "
              f"{burn_rate_all:,}"
              + (".\n" if rate_inverted else
                 " — lower because it pools idle and interactive sessions with fleet "
                 "ones. **Size with the peak rate, not the mean.**\n"))
        if rate_inverted:
            print(f"> **The peak 5h window probably falls OUTSIDE the run under review — do not size "
                  f"on {peak_5h_rate:,}.** The all-sessions mean ({burn_rate_all:,}) EXCEEDS the "
                  f"at-peak rate, which the sizing guidance assumes cannot happen: "
                  f"`peak_5h_concurrency` counts sessions whose lifespan merely overlaps the window, "
                  f"so a window landing on post-fleet interactive sessions inflates the divisor and "
                  f"collapses the rate. The window starts {peak_5h_at:%Y-%m-%d %H:%M UTC} — check it "
                  f"against the fleet's own span and re-run with `--sessions` (or `--until`) if it "
                  f"falls outside.\n")
        if cutoff_groups:
            print("**This run was CUT OFF, so both peaks above are CEILINGS, not floors** — they bound "
                  "the allowance from above where an un-throttled run bounds it from below. This is the "
                  "one observation that can LOWER the next fleet's size; reporting it as a floor raises "
                  "the next fleet on evidence that argues for shrinking it. Size against the "
                  "cutoff-window meters below, not against the peak.\n")
        elif stall_groups:
            print("A stall group exists but no member's transcript carries a harness limit message, so "
                  "whether this run was cut off is NOT established — a machine sleep or daemon restart "
                  "leaves the same fingerprint. Treat the peaks as floors only after ruling out a quota "
                  "cutoff (see the stall fingerprint below); size nothing on this run until the cause "
                  "is known.\n")
        else:
            print("Both peaks are FLOORS on the real ceilings — they record what was survived, and every "
                  "observation comes from a run that was never throttled hard enough to notice. Size a "
                  "fleet so its projected burn stays under the observed peak, never up to a limit these "
                  "numbers do not establish. Scale by proportion — at concurrency `n` expect roughly "
                  f"`{peak_5h:,} x n/{peak_5h_concurrency}` per 5h window — and treat that as an "
                  "over-estimate: the rate sags as sessions are added, because merge-queue "
                  "serialization buys idle time.\n")
    else:
        print("- no timestamped usage found; rolling-window burn not computable\n")
    for c in cutoff_meters:
        print(f"- **cutoff-window meters** — in the 5h ENDING at {c['at']:%Y-%m-%d %H:%M UTC}, when the "
              f"allowance bound: **{c['output_tokens']:,} output**, "
              f"**{c['cache_read_tokens']:,} cache-read**, "
              f"**{c['total_billable_tokens']:,} total billable**. Carry all three to the next retro, "
              f"but compare them ONLY against a cutoff with the same `limit_kind` — a 5h window is the "
              f"wrong instrument for a weekly cutoff, and two different limits agreeing closely on one "
              f"column is a coincidence that reads exactly like a discovery (it happened: see "
              f"`trailing_at`).\n")
    if stall_groups:
        for g in stall_groups:
            # Distinct sessions, not marks — one session contributes several marks (longest silence
            # plus each limit-anchored gap), and the mark list printed as "8 sessions" on a 4-session
            # fleet (BF-1206).
            run_keys = list(dict.fromkeys(m[1]["run_key"] for m in g))
            keys = ", ".join(f"`{k}`" for k in run_keys)
            when = g[-1][0]
            lost = lost_seconds(g) / 3600
            clip_note = (f" (gaps clipped at the fleet deadline {fleet_deadline_dt:%H:%M UTC} — "
                         f"post-deadline quiet is wind-down)" if fleet_deadline_dt is not None else "")
            resumed = [m[2]["resumed"] for m in g if m[2]["resumed"]]
            kinds = sorted({m[1]["agg"]["first_limit_hit"][1] for m in g
                            if m[1]["agg"]["first_limit_hit"]})
            print(f"- **quota-stall fingerprint** — {len(run_keys)} sessions ({keys}) went quiet within "
                  f"120s of each other at {when:%Y-%m-%d %H:%M UTC}. "
                  f"A deadline wind-down ends sessions one at a time, each tagged; an account-level "
                  f"cutoff stops them together, mid-issue.")
            if kinds:
                lever = {"weekly": "**duration / total session-hours**, NOT concurrency",
                         "5-hour": "**concurrency (`n`)**",
                         "session": "**concurrency (`n`)** — despite the name. Measured 2026-08-14: "
                                    "`session` cutoffs reset on exact 5h boundaries and refuse every "
                                    "session then making a request, so it is the account-level 5h "
                                    "window; route it as `5-hour`",
                         "usage": "unknown — read the message text"}
                print(f"  Limit named by the harness: **{'/'.join(kinds)}**. "
                      + " ".join(f"The lever for `{k}` is {lever.get(k, 'unknown')}." for k in kinds)
                      + " Do not infer this from the stall's shape — the limits produce the same "
                        "synchronized-silence fingerprint and carry different levers.")
            lags = [m[2].get("recovery_lag_s") for m in g if m[2].get("recovery_lag_s") is not None]
            if lags:
                worst = max(lags) / 3600
                avoidable = sum(l for l in lags if l > 0) / 3600
                print(f"  **Recovery lag: {avoidable:.2f} session-hours idle AFTER the allowance had "
                      f"already reset** (worst single session {worst:.2f}h). The allowance's own "
                      f"duration is unavoidable; this is not. A session cut off mid-iteration has no "
                      f"ScheduleWakeup pending (it is turn-ending by contract) and fires no Stop hook "
                      f"(an API-killed turn fires none), so nothing wakes it — check "
                      f"`~/.claude/logs/auto-stall-watch.log` for whether the watcher flagged it, and "
                      f"whether anyone acted.")
            elif kinds:
                # This branch is the else of `if lags:` — it means NO RECOVERY LAG WAS COMPUTABLE, not
                # that no limit message exists (the kind two lines up came from one). Printing "no
                # limit message found" here contradicted the weekly limit the same block had just
                # named, on a run whose transcripts carried the message in every session (BF-1206).
                print("  Recovery lag not computable for this group: the limit message's reset time "
                      "did not parse to a wall-clock instant, or resume preceded the reset — the "
                      "cutoff itself IS established by the limit kind above.")
            else:
                print("  No harness limit message found in these transcripts, so the cause is NOT "
                      "established as an allowance cutoff — check for a machine sleep, a daemon "
                      "restart, or a network outage before sizing anything on this.")
            if resumed:
                print(f"  They resumed by {max(resumed):%Y-%m-%d %H:%M UTC} and drained normally, so "
                      f"their terminal tags and end-of-run bookkeeping look clean — **{lost:.1f} "
                      f"session-hours produced nothing**{clip_note}. Size the next fleet against the "
                      f"allowance this run actually had, not the wall-clock it was given.\n")
            else:
                print("  None emitted a terminal tag, so they never recovered. Check those worktrees "
                      "for unfinished work before reaping anything.\n")

    print("## Cross-run trend\n")
    if args.all:
        print("- not recorded for --all sweeps (an all-time pool is not a fleet); each windowed run "
              "adds one row to `tmp/fleet-metrics-history.jsonl`. Stored history:\n")
    if history:
        def cell(v, fmt="{}"):
            return fmt.format(v) if v is not None else "-"

        def pct(v):
            return f"{round(100 * v)}%" if v is not None else "-"
        print("| fleet start | n | hours | shipped | $/issue | ktok/issue | $/Mtok out | cycles | "
              "find/rev | C+H/rev | plan% | ctx>=200k% | filed/ship | fresh% |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in history[-6:]:
            mark = " ←" if r.get("session_set") == headline["session_set"] and not args.all else ""
            fs = (r.get("fleet_start") or "?")[:16].replace("T", " ")
            ktok = round(r["output_tokens_per_shipped"] / 1000) if r.get("output_tokens_per_shipped") else None
            print(f"| {fs}{mark} | {cell(r.get('sessions'))} | {cell(r.get('session_hours'))} | "
                  f"{cell(r.get('shipped'))} | {cell(r.get('cost_per_shipped_usd'), '${}')} | "
                  f"{cell(ktok)} | {cell(r.get('usd_per_mtok_output'), '${}')} | "
                  f"{cell(r.get('avg_cycles'))} | {cell(r.get('findings_per_review'))} | "
                  f"{cell(r.get('crit_high_per_review'))} | {pct(r.get('plan_origin_share'))} | "
                  f"{pct(r.get('ctx_share_ge200k'))} | {cell(r.get('filed_per_shipped'))} | "
                  f"{pct(r.get('fresh_shipped_share'))} |")
        if len(history) > 6:
            print(f"\n({len(history) - 6} earlier row(s) in the ledger, not shown)")
        print("\nRead $/issue as its two factors: ktok/issue is work per shipped issue (churn or harder "
              "issues — cycles, find/rev and plan% say which), $/Mtok out is billable context per unit "
              "of work (ctx>=200k% names the driver — the autocompact lever). fresh% is the treadmill "
              "gauge: the share of shipped issues created during or within 7 days before the run.\n")
    elif not args.all:
        print("- first recorded fleet — the trend accrues one row per windowed run in "
              "`tmp/fleet-metrics-history.jsonl`\n")

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
        # A session killed mid-loop arms wakeups normally and simply never terminates, so the
        # "never armed" flag above cannot see it (it requires wakeups == 0, making the two
        # mutually exclusive). Its signature is a still-`active` ledger with zero stop-wakeups.
        # Killing a session in `claude agents` is the documented way to abort in-flight work
        # (skills/fleet-status/SKILL.md), so this is routine — and it always strands a Linear
        # claim and a preserved worktree for a human to clean up.
        if st.get("status") == "active" and a["wakeups"] > 0 and a["wakeup_stops"] == 0:
            flagged = True
            print(f"- **`{s['run_key']}` ended without recording an outcome** — ledger still "
                  f"`active` after {a['wakeups']} wakeup(s) and no stop-wakeup, so it was killed "
                  f"mid-loop or died. Check for a stranded Linear claim and a preserved worktree.")
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
    no_edges = [v["issue"] for v in verdicts if v["filed"] and not v["edges_recorded"]]
    if no_edges:
        flagged = True
        print(f"- **Filed issues with no `Collision edges:` record**: {', '.join(sorted(no_edges))} — "
              f"the verdict names deferred filings but never says whether sibling edges were wired or "
              f"none were owed, so retro Step 4's edge audit starts blind on these (unwired "
              f"same-mechanism siblings recurred on two consecutive fleets; BF-1226).")
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
