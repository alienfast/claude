#!/usr/bin/env python3
"""fleet-forecast.py — project what a fleet of /loop /auto sessions would ship over a time horizon,
as an ESTIMATE of the drain's shape, never a plan: pick order is decided at pick time by
next-candidates.sh against live state, and collisions, review churn, failures, and headroom parking
all move the real timeline. What the estimate is for: seeing which chains gate the run, when the
pool exhausts, and what a given horizon cannot reach.

WHY A SCRIPT: the wave walk (N sessions greedily draining a blocks-graph) is the same hand-derived
graph arithmetic that produced the 2026-08-13 roots-only promotion misread — mistranscribed
in-context walks emit plausible partial timelines at exit 0. Deterministic, fixture-testable, and
the FORECAST/STRANDED/UNREACHED lines make an empty result distinguishable from a broken run.

Eligibility mirrors fleet-blockers.sh gate_reasons: a fleet session ships only workable-state
(unstarted/backlog) + `specified`, unclaimed, non-epic, non-gate-labeled issues; run
fleet-blockers.test.sh alongside this suite when the classification rules move.

Usage:
  fleet-forecast.py --team KEY [--sessions N] [--horizon-h H] [--hours-per-issue X] [--flat]
                    [--recommendation PATH] [--history PATH] [--me EMAIL] [--fixture PATH]

  --sessions / --horizon-h default from tmp/fleet-recommendation.json (sessions / duration_h);
  horizon falls back to 12. --hours-per-issue overrides the calibration from
  tmp/fleet-metrics-history.jsonl (mean session_hours/shipped over recent runs; default 2.0).
  --flat disables estimate-point weighting of per-issue duration. --fixture bypasses the Linear
  fetch with a JSON array of issue nodes (test seam); --me sets the viewer email for claim checks.

Output: verdict lines to stdout — FORECAST / HOURS-PER-ISSUE / THROTTLE-RISK / INFLIGHT /
PICK / SHIP / POOL-DRAINED / LANE / STRANDED / UNREACHED. Exit 0 when fetched and simulated
(counts may be 0); non-zero on fetch/parse failure. Read-only — no Linear writes.
"""

import argparse
import heapq
import json
import os
import subprocess
import sys
from pathlib import Path

GATE_LABELS = ("human", "needs decision", "solo", "stalled")
QUERY = ('query($team:String!,$after:String){issues(filter:{team:{key:{eq:$team}},'
         ' state:{type:{nin:["completed","canceled"]}}}, first:250, after:$after){'
         'nodes{identifier estimate priority state{name type} assignee{email}'
         ' labels{nodes{name}} relations{nodes{type relatedIssue{identifier}}}}'
         ' pageInfo{hasNextPage endCursor}}}')


def cli(args):
    env = dict(os.environ, PATH=f"{Path.home()}/.cargo/bin:{os.environ.get('PATH', '')}")
    out = subprocess.run(["linear-cli", *args], capture_output=True, text=True, env=env)
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError(f"linear-cli {' '.join(args[:3])} failed: {out.stderr.strip() or 'empty output'}")
    return json.loads(out.stdout)


def fetch_nodes(team):
    nodes, after = [], None
    while True:
        args = ["api", "query", "-q", "-o", "json", "-v", f"team={team}"]
        if after:
            args += ["-v", f"after={after}"]
        data = cli(args + [QUERY])
        if "errors" in data:
            raise RuntimeError(f"API errors for team '{team}': {json.dumps(data['errors'])}")
        page = data["data"]["issues"]
        nodes += page["nodes"] or []
        info = page["pageInfo"]
        if not (info.get("hasNextPage") and info.get("endCursor")):
            return nodes
        after = info["endCursor"]


def viewer_email():
    try:
        return cli(["api", "query", "-q", "-o", "json", "query{viewer{email}}"])["data"]["viewer"]["email"] or ""
    except Exception:
        return ""  # unresolvable viewer → every assignment reads claimed, failing toward the claim


class Issue:
    def __init__(self, node, me):
        self.id = node["identifier"]
        self.stype = (node.get("state") or {}).get("type", "?")
        self.sname = (node.get("state") or {}).get("name", "?")
        self.labels = {(n.get("name") or "").lower() for n in ((node.get("labels") or {}).get("nodes") or [])}
        self.estimate = node.get("estimate")
        self.priority = int(node.get("priority") or 0)
        assignee = ((node.get("assignee") or {}).get("email") or "")
        self.claimed = bool(assignee) and (not me or assignee != me)
        self.blockers = set()  # filled from edges

    def gate_reason(self):
        """First reason the fleet can never ship this issue, or None. Order mirrors what a keeper
        acts on first; one reason is enough for a forecast (fleet-blockers.sh reports them all)."""
        if self.claimed:
            return "claimed"
        if "epic" in self.labels:
            return "delegated epic"
        for g in GATE_LABELS:
            if g in self.labels:
                return g
        if self.stype == "triage":
            return "in Triage"
        if self.stype in ("unstarted", "backlog") and "specified" not in self.labels:
            return "uncertified"
        return None

    @property
    def shippable(self):
        return self.stype in ("unstarted", "backlog") and self.gate_reason() is None

    @property
    def inflight(self):
        return self.stype == "started" and self.gate_reason() is None

    def rank(self):
        """Within-availability order, approximating next-candidates.sh's within-tier rules: stage
        strictly first (Backlog only after Planned/Todo; Urgent does not pierce stage), then Urgent,
        then security/bug, then priority (Linear 0 = none, sorted last), then estimate, then ID.
        The tier system above these (assigned-to-me, newly-unblocked, sibling spread, parent
        weight) is deliberately not reproduced — pick-time authority stays with the shell script."""
        num = int(self.id.split("-")[1]) if "-" in self.id and self.id.split("-")[1].isdigit() else 0
        return (0 if self.stype == "unstarted" else 1,
                0 if self.priority == 1 else 1,
                0 if self.labels & {"security", "bug"} else 1,
                self.priority if self.priority > 0 else 5,
                self.estimate if self.estimate is not None else 99,
                num)


def calibrate(history_path, override):
    if override is not None:
        return override, "--hours-per-issue"
    rows = []
    try:
        for line in Path(history_path).read_text().splitlines():
            try:
                r = json.loads(line)
            except json.JSONDecodeError:
                continue
            if (r.get("shipped") or 0) > 0 and (r.get("session_hours") or 0) > 0:
                rows.append(r["session_hours"] / r["shipped"])
    except OSError:
        pass
    if rows:
        recent = rows[-6:]
        return round(sum(recent) / len(recent), 2), f"calibrated from {len(recent)} fleet runs in {history_path}"
    return 2.0, "default — no usable fleet history"


def duration_fn(pool, base, flat):
    ests = [i.estimate for i in pool if i.estimate]
    mean_est = sum(ests) / len(ests) if ests else None
    def hours(issue):
        if flat or not issue.estimate or not mean_est:
            return base
        return round(min(max(base * issue.estimate / mean_est, 0.5 * base), 2.5 * base), 2)
    return hours


def simulate(issues, n_sessions, horizon, hours):
    """Greedy list-scheduling: each free session picks the top-ranked available candidate; a pick
    happens whenever t < horizon and the issue finishes past it if it must — /auto checks the fleet
    deadline before each pick, never mid-issue, so in-flight work finishing late is faithful."""
    pool = {i.id: i for i in issues.values() if i.shippable}
    events, lanes = [], {k: [] for k in range(1, n_sessions + 1)}
    active = []  # heap of (end, issue-id, session-or-None)

    # Clean in-flight blockers finish outside the fleet; assume within one mean issue duration.
    # Only ones that block a pool member are tracked — the sim cares about in-flight work solely as
    # an unlocker, and a team's In Review shelf is otherwise dozens of noise lines (measured on BF).
    for i in issues.values():
        if i.inflight and any(i.id in p.blockers for p in pool.values()):
            end = hours(i)
            heapq.heappush(active, (end, i.id, None))
            events.append((0.0, 0, f"INFLIGHT: {i.id} [{i.sname}] — assumed to finish ≈t={end:.1f}h (outside the fleet)"))

    shipped, ship_time, picked = set(), {}, {}
    free = [(0.0, k) for k in range(1, n_sessions + 1)]
    heapq.heapify(free)
    drained_at = None

    def available():
        return sorted((p for p in pool.values() if p.id not in picked
                       and all(b in shipped or b not in issues for b in p.blockers)),
                      key=Issue.rank)

    while free:
        t, k = heapq.heappop(free)
        while active and active[0][0] <= t:
            end, iid, sess = heapq.heappop(active)
            shipped.add(iid)
            ship_time[iid] = end
            unblocks = sorted(p.id for p in pool.values() if iid in p.blockers and p.id not in picked)
            late = " (past deadline — in-flight finish)" if end > horizon else ""
            tail = f" — unblocks {', '.join(unblocks)}" if unblocks else ""
            events.append((end, 1, f"SHIP t={end:.1f}h: {iid}{tail}{late}"))
        if t >= horizon:
            continue
        avail = available()
        if avail:
            issue = avail[0]
            d = hours(issue)
            picked[issue.id] = (k, t, t + d)
            lanes[k].append((issue.id, t, t + d))
            via = next((b for b in sorted(issue.blockers) if b in ship_time), None)
            note = f" (unblocked by {via})" if via else ""
            events.append((t, 2, f"PICK t={t:.1f}h: {issue.id} → s{k} (~{d:.1f}h){note}"))
            heapq.heappush(active, (t + d, issue.id, k))
            heapq.heappush(free, (t + d, k))
        elif active:
            heapq.heappush(free, (active[0][0], k))  # wake at the next ship; ships ≤ t are already processed, so time advances
        else:
            if drained_at is None:
                drained_at = t  # no available candidate and nothing in flight: the fleet is out of pickable work

    while active:  # in-flight finishes with no session waiting on them
        end, iid, sess = heapq.heappop(active)
        shipped.add(iid)
        ship_time[iid] = end
        if sess is not None or any(iid in p.blockers for p in pool.values()):
            late = " (past deadline — in-flight finish)" if end > horizon and sess is None else ""
            events.append((end, 1, f"SHIP t={end:.1f}h: {iid}{late}"))

    return pool, picked, shipped, ship_time, events, lanes, drained_at


def unreached_reason(issue, issues, pool, shipped, ship_time, horizon, seen=None):
    """STRANDED (a blocker the fleet can never resolve — direct, by cascade, or a cycle) vs
    UNREACHED (capacity or the horizon). Gates are checked across ALL blockers before cascading so
    a gated co-blocker is never hidden behind a merely-unshipped one; `seen` guards cycles."""
    seen = seen or {issue.id}
    for b in sorted(issue.blockers):
        blocker = issues.get(b)
        if blocker is None:
            continue  # terminal states are excluded from the fetch → resolved by construction
        reason = blocker.gate_reason()
        if reason is not None:
            return "STRANDED", f"blocked by {b} [{blocker.sname}] — {reason}"
    for b in sorted(issue.blockers):
        if b not in pool or b in shipped:
            continue
        if b in seen:
            return "STRANDED", f"blocked by {b} — dependency cycle"
        kind, sub = unreached_reason(pool[b], issues, pool, shipped, ship_time, horizon, seen | {b})
        if kind == "STRANDED" and sub.endswith("dependency cycle"):
            return "STRANDED", f"blocked by {b} — dependency cycle"
        return kind, f"blocked by {b} (itself {'stranded' if kind == 'STRANDED' else 'unshipped this run'})"
    if issue.blockers and any(b in ship_time and ship_time[b] >= horizon for b in issue.blockers):
        t = max(ship_time[b] for b in issue.blockers if b in ship_time)
        return "UNREACHED", f"unlocks ≈t={t:.1f}h — past the deadline"
    return "UNREACHED", "capacity — ranked below what the sessions reached before the deadline"


def throttle_line(rec, n_sessions):
    try:
        rate = (rec.get("sizing") or {}).get("rate_tok_per_session_hour")
        cal = json.loads((Path.home() / ".claude/telemetry/five-hour-ceiling.json").read_text())
        ceiling = cal.get("ceiling_output_tokens")
        if rate and ceiling and n_sessions * rate * 5 > 0.9 * ceiling:
            return (f"THROTTLE-RISK: {n_sessions} sessions × {rate / 1000:.0f}k tok/session-hour ≈ "
                    f"{n_sessions * rate * 5 / 1e6:.2f}M per 5h window vs ceiling {ceiling / 1e6:.2f}M — "
                    f"expect fleet-headroom parking to stretch this timeline")
    except Exception:
        pass
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--team")
    ap.add_argument("--sessions", type=int)
    ap.add_argument("--horizon-h", type=float)
    ap.add_argument("--hours-per-issue", type=float)
    ap.add_argument("--flat", action="store_true")
    ap.add_argument("--recommendation", default="tmp/fleet-recommendation.json")
    ap.add_argument("--history", default="tmp/fleet-metrics-history.jsonl")
    ap.add_argument("--me")
    ap.add_argument("--fixture")
    args = ap.parse_args()

    rec = {}
    try:
        rec = json.loads(Path(args.recommendation).read_text())
    except (OSError, json.JSONDecodeError):
        pass
    n_sessions = args.sessions or rec.get("sessions")
    if not n_sessions:
        print("ERROR: no --sessions and no usable tmp/fleet-recommendation.json — run /auto-prep or pass a count", file=sys.stderr)
        return 1
    horizon = args.horizon_h or rec.get("duration_h") or 12.0

    try:
        if args.fixture:
            nodes = json.loads(Path(args.fixture).read_text())
            me = args.me or ""
        else:
            if not args.team:
                print("ERROR: --team is required (or use --fixture)", file=sys.stderr)
                return 1
            nodes = fetch_nodes(args.team)
            me = args.me or viewer_email()
    except (RuntimeError, OSError, json.JSONDecodeError, KeyError) as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1

    issues = {}
    for node in nodes:
        i = Issue(node, me)
        # "In Review" is completed-in-substance (keeper ruling 2026-08-21): work done, awaiting human
        # review — dropped here like the terminal states the fetch filter excludes, so its outgoing
        # blocks resolve by construction and dependents are available at t=0. Matched by name because
        # Linear registers the state as type `started` and a state's type cannot be changed after
        # creation; a kick-back moves the issue out of the state, reinstating its blocks.
        if i.sname.strip().lower() == "in review":
            continue
        issues[i.id] = i
    for node in nodes:
        for r in ((node.get("relations") or {}).get("nodes") or []):
            if r.get("type") == "blocks" and r.get("relatedIssue"):
                blocked = r["relatedIssue"]["identifier"]
                if blocked in issues:
                    issues[blocked].blockers.add(node["identifier"])

    base, source = calibrate(args.history, args.hours_per_issue)
    certified = [i for i in issues.values()
                 if i.stype in ("unstarted", "backlog") and "specified" in i.labels and "epic" not in i.labels]
    hours = duration_fn([i for i in issues.values() if i.shippable], base, args.flat)
    pool, picked, shipped, ship_time, events, lanes, drained_at = simulate(issues, n_sessions, horizon, hours)

    shipped_pool = [iid for iid in pool if iid in shipped]
    late = [iid for iid in shipped_pool if ship_time[iid] > horizon]
    leftovers = [pool[iid] for iid in sorted(pool) if iid not in shipped]
    verdicts = {iid: unreached_reason(pool[iid], issues, pool, shipped, ship_time, horizon)
                for iid in sorted(pool) if iid not in shipped}
    stranded = [iid for iid, v in verdicts.items() if v[0] == "STRANDED"]
    unreached = [iid for iid, v in verdicts.items() if v[0] == "UNREACHED"]

    print(f"FORECAST: {n_sessions} sessions × {horizon:.1f}h horizon — est. {len(shipped_pool)} ship"
          f"{f' ({len(late)} past deadline)' if late else ''}"
          f" · {len(unreached)} unreached · {len(stranded)} stranded — pool {len(pool)} shippable of {len(certified)} certified")
    print(f"HOURS-PER-ISSUE: {base} ({source}{'' if args.flat else '; estimate-weighted'})")
    unstarted_ids = [iid for iid in pool if pool[iid].stype == "unstarted"]
    backlog_ids = [iid for iid in pool if pool[iid].stype == "backlog"]
    backlog_starts = [s for iid, (_k, s, _e) in picked.items() if pool[iid].stype == "backlog"]
    if not unstarted_ids:
        stage = "STAGE: no Planned/Todo candidates in the pool — Backlog picks from t=0.0h"
    else:
        left = sorted(iid for iid in unstarted_ids if iid not in shipped)
        if left:
            stage = (f"STAGE: Planned/Todo NOT drained — {len(left)} of {len(unstarted_ids)} "
                     f"remain past the run ({', '.join(left)})")
        else:
            stage = (f"STAGE: Planned/Todo ({len(unstarted_ids)} issues) "
                     f"drains ≈t={max(ship_time[iid] for iid in unstarted_ids):.1f}h")
        if backlog_starts:
            stage += f"; first Backlog pick ≈t={min(backlog_starts):.1f}h"
        elif backlog_ids:
            stage += f"; Backlog ({len(backlog_ids)} candidates) never reached this run"
        else:
            stage += "; no Backlog candidates in the pool"
    print(stage)
    tl = throttle_line(rec, n_sessions)
    if tl:
        print(tl)
    for _, _, line in sorted(events, key=lambda e: (e[0], e[1], e[2])):
        print(line)
    if drained_at is not None and drained_at < horizon:
        blocked_note = f" ({len(leftovers)} remain blocked)" if leftovers else ""
        print(f"POOL-DRAINED: t={drained_at:.1f}h — no pickable candidates remain{blocked_note}; "
              f"{horizon - drained_at:.1f}h of horizon unused")
    for k in sorted(lanes):
        segs = " ".join(f"{iid}[{a:.1f}→{b:.1f}]" for iid, a, b in lanes[k]) or "(idle)"
        print(f"LANE s{k}: {segs}")
    for iid in stranded:
        print(f"STRANDED: {iid} — {verdicts[iid][1]}")
    capacity = [iid for iid in unreached if verdicts[iid][1].startswith("capacity")]
    for iid in unreached:
        if iid not in capacity:
            print(f"UNREACHED: {iid} — {verdicts[iid][1]}")
    if capacity:  # one rollup — per-issue capacity rows carry nothing beyond the ID, and a deep Backlog emits hundreds
        nxt = sorted(capacity, key=lambda i: pool[i].rank())[:5]
        more = f" (+{len(capacity) - len(nxt)} more)" if len(capacity) > len(nxt) else ""
        print(f"UNREACHED-CAPACITY: {len(capacity)} ranked below what the run reaches — next in line: {', '.join(nxt)}{more}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
