---
name: reap-tmp
description: Inspect and reclaim aged scratch under a project's tmp/. Classifies every top-level entry by name into a lane — never (fleet-metrics history, fleet markers, auto ledgers, triage proposals, tmp/keep/), state-gated (the /quality-review → /finish verdict once its branch is merged, a sequence marker once its branch is gone), cache, handoff, scratch — and ages only the deletable lanes out, while a directory the manifest does not know is reported and never deleted. A daily launchd agent runs it unattended; `list` shows what it would do. Use when the user says 'reap tmp', 'clean up tmp', 'prune tmp', 'what's in tmp', 'tmp is full of junk', or invokes /reap-tmp.
---

# Reap Tmp

Every skill writes to `<project>/tmp/` (CLAUDE.md § Guidelines), and most of what lands there is dead the
moment its session ends: check logs, Linear staging bodies, fix-delta snapshots, test output. A small set of
named files is the opposite — read later by a different skill, often from a different session: the
`/quality-review` → `/finish` verdict, the fleet ledgers `/fleet-retro` measures, the triage scan → apply
proposals — or never safe to lose at all (`fleet-metrics-history.jsonl`, the six-fleet trend ledger). Age
is the wrong test for those and the only right test for the rest, so
[reap-tmp.sh](../../scripts/reap-tmp.sh) classifies by **name first** and applies a per-lane rule. Measured
before it existed: 359 files in `~/.claude/tmp`, 207 of them older than a month, and a project `tmp/` that
was being wiped by hand — which is exactly the `rm -rf tmp/` CLAUDE.md forbids, because it takes the
handoff files with it.

## The lanes

First match wins; the manifest is the `classify` function in the script.

- **never** — kept whatever its age: `keep/` (the operator's hatch — move a file there to keep it),
  `fleet-metrics-history.jsonl`, `fleet-linear-window.json` and `fleet-shipped-issues.json` (retro inputs),
  `fleet-deadline.json`, `fleet-recommendation.json`, `auto-state-<runKey>.json` (ledger expiry is
  `/fleet-launch`'s, against the agents registry), `triage-proposals/` (the next scan's skip check reads
  `applied/`), and any registered git worktree parked under `tmp/` (`/reap-worktrees` owns it).
- **state** — deleted only when the owner's own state says consumed, and never inside 7 days:
  - `quality-review-verdict-<issue>.md`: every local branch of that issue (`<user>/<issue>-…`) is merged into
    the default branch, or none exists; and the file was not written during a fleet window that
    `/fleet-retro` has not measured yet (`fleet_sessions` in the deadline marker ∩ a history row's
    `session_set` is empty). `quality-review-verdict-no-issue.md` is plain scratch.
  - `fleet-sequence*.json` (+ its `.log`/`.pid`): not `running` under a live runner pid, and its
    integration branch is gone — resume needs the branch.
- **handoff** (30 days) — the triage cheap-pass inputs the interactive apply reads later
  (`triage-cheap.ndjson`, `triage-pool.ndjson`, `triage-head.sha`, `triage-commit-*.txt`, `triage-ls-files.txt`).
- **cache** (1 day) — reused on presence alone with no freshness check (`linear-context-*.md`,
  `triage-digest-*.md`) or poll markers a leftover copy would trip (`*.done`, `wait-*.sh`). A stale copy is
  worse than an absent one; every writer re-fetches when the file is missing.
- **scratch** (7 days) — everything else at the top level, plus the known scratch directories
  (`qr-fix-base-*`, `qr-probe-*`, `screenshots`, `triage-markers`, `triage-apply-bodies`,
  `triage-proposals/raw`, `pool-pages-*`, `epic-merge`, `proposal-*`). A directory's age is its newest file.
- **unknown** — a directory not in the manifest. **Never deleted.** Reported (`UNKNOWN`) once it is 30 days
  old so you add a rule or remove it by hand. A top-level file is scratch by construction, so a name the
  manifest does not know still ages out; a directory is structure someone built, so it does not.

## Guards that outrank every lane

- **Fresh**: nothing modified in the last 24h is touched — another session may be mid-write. While a fleet
  is running (`fleet-deadline.json` not stopped, deadline in the future or launched within 48h) the guard
  widens to everything written since the launch.
- **Open**: a file some process holds open (`lsof`) is kept — a detached job's log is being written however
  old its mtime looks. Without `lsof` the guard stands down for the pass, with one `WARN`.
- **Symlink**: never followed, never removed. **`tmp/` itself** is never removed, and `rm -rf` is issued
  only for a directory a scratch-dir rule named.
- **Lock**: `reap` serializes per repo on the same common-git-dir lock `/finish merge` and
  `/reap-worktrees` take, so a sweep never runs while a merge is landing.

Two `FLAG` lines call out files that are never deleted but hold a gate up when stale: a
`fleet-recommendation.json` carrying an epic `scope` and older than a day (a bare `/fleet-launch` would
relaunch that epic — re-run `/auto-prep` or `/epic-prep`), and a `fleet-deadline.json` with no deadline, never
stopped, past the fleet horizon (it keeps the git-permissions gate up — `rm` it or re-run `/fleet-launch`).

## Usage

**Inspect (dry run — mutates nothing, takes no lock):**

```bash
~/.claude/scripts/reap-tmp.sh list            # every registered repo, ~/.claude, and the repo you are in
~/.claude/scripts/reap-tmp.sh list <repo>     # one root (its tmp/)
```

Each entry prints one of `ELIGIBLE`, `KEEP` (with the lane or guard that kept it), `UNKNOWN`, or `FLAG`,
then a summary line.

**Reap (mutating — removes eligible entries under the repo lock):**

```bash
~/.claude/scripts/reap-tmp.sh reap            # every registered repo, ~/.claude, and the repo you are in
~/.claude/scripts/reap-tmp.sh reap <repo>
```

`reap` prints only `REAPED`, `UNKNOWN` (30 days or older), `FLAG`, and `WARN` lines plus the summary, so
the daily log stays readable.

When the user asks to inspect, run `list` and summarize: what is eligible, what is kept and why, every
`UNKNOWN` and `FLAG`. When they ask to clean up, run `list` first, show what will be removed, and on
confirmation run `reap`. An `UNKNOWN` directory is a decision for the user: add it to the manifest (a rule
in `classify`, a row in the test), move it under `tmp/keep/`, or delete it by hand — never on their behalf.

Thresholds are env-overridable for a one-off run: `REAP_TMP_FRESH_H` (24), `REAP_TMP_CACHE_D` (1),
`REAP_TMP_SCRATCH_D` (7), `REAP_TMP_HANDOFF_D` (30), `REAP_TMP_UNKNOWN_D` (30), `REAP_TMP_FLEET_MAX_H` (48).

## Adding a handoff file

The manifest is the safety boundary for the unattended runs, so
[reap-tmp.test.sh](../../scripts/reap-tmp.test.sh) (`bash ~/.claude/scripts/reap-tmp.test.sh`) sweeps the
corpus — every skill, script, hook, standard, agent, and CLAUDE.md — for each `tmp/<name>` it writes and
fails when one resolves to the default scratch rule rather than a named one. A skill that starts writing a
file another session reads later therefore fails `pnpm check` until the name is classified on purpose: add a
`case` arm to `classify` in the lane it belongs to, and a row to the test's manifest table. A generic example
in prose (`tmp/<name>.sh`) goes in the test's `EXPECT_DEFAULT` list instead.

## The launchd agent

`~/.claude/update.sh` installs and refreshes the agent (daily, `com.alienfast.tmp-reap`) automatically —
renders the `__HOME__` template and bootstraps it idempotently, see
[the plist header](../../launchd/com.alienfast.tmp-reap.plist) for the by-hand commands — and runs one
sweep itself on every platform, since launchd exists only on macOS. The log is `~/.claude/logs/tmp-reap.log`.
To remove the agent:

```bash
launchctl bootout gui/$(id -u)/com.alienfast.tmp-reap
rm ~/Library/LaunchAgents/com.alienfast.tmp-reap.plist
```
