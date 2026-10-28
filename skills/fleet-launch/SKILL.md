---
name: fleet-launch
description: Launch a fleet of parallel /loop /auto sessions as `claude agents` background sessions, staggered, with an optional time budget; the count defaults to the fleet's own recommendation (/auto-prep for the team fleet, /epic-prep for an epic's). `epic:<ID>` scopes the fleet to one epic's integration branch (the epic's own Backlog members included) and runs beside any other fleet in the checkout; `backlog` opens the Backlog fallback team-wide. Use when the user says 'fleet launch', 'launch the fleet', 'spawn N auto loops', 'fleet epic', or invokes /fleet-launch.
---

# Fleet Launch

The middle bookend of the fleet workflow: `/auto-prep` or `/epic-prep` (groom + recommend a count) → **`/fleet-launch`**
(dispatch) → `/fleet-retro` (post-mortem). All logic lives in [scripts/fleet-launch.sh](../../scripts/fleet-launch.sh);
this skill dispatches to it and narrates. Each session is a `claude --bg "/loop /auto"` background agent in
`claude agents`. Dispatches are staggered on a new worktree under `.claude/worktrees/` whose identity sidecar names the
dispatched session (the stamp `/auto`'s live-owner probe excludes from the next pick), so sessions never race for the same
first issue and a sibling fleet's claim is never mistaken for this one's, capped at 180s per wait.

**Every fleet is keyed by a slug** — the lowercased epic id of an epic-scoped launch, `team` for a bare one — and owns its
two files under the project's `tmp/` ([lib/fleet-markers.sh](../../lib/fleet-markers.sh)): the marker
`tmp/fleet-deadline-<slug>.json` the launch writes and the recommendation `tmp/fleet-recommendation-<slug>.json` the prep
wrote. Fleets of different slugs run side by side in one checkout — an epic fleet beside the team fleet, two epics at
once — and a launch never touches another fleet's marker, deadline or sessions; a launch of a slug whose fleet is still
running tops that fleet up. The concurrency cap counts every fleet's live sessions. Read § Several fleets in one checkout.

This skill runs neither `/auto-prep` nor `/epic-prep` (their advice needs human eyes) nor `/fleet-retro`. A launch
expires only fleets `/fleet-retro` has already measured; an ended fleet nobody measured keeps its marker and ledgers
(§ Ledger expiry), so the retro can run whenever it suits.

## Arguments

`/fleet-launch [count] [duration] [epic:<ID>] [backlog] [stale-ok]`

- **(none)** — launch the team fleet at the count `/auto-prep` persisted, no deadline: loops run until the certified
  backlog drains (`NO-CANDIDATES`), or hold on `PLANNED-HOLD` while a Planned issue the fleet cannot ship holds the gate
  (`/fleet-stop` ends such a fleet; an epic fleet ends itself on `EPIC-DRAINED`). A bare launch reads only the team
  recommendation, so an `/epic-prep` lying around never changes what it does. No count and no recommendation for the
  fleet → the script says so and stops.
- `<count>` — exactly that many sessions — that many MORE when a fleet of the same slug is already running. The user's
  override of the recommendation in either direction; the FIRST token when given.
- `<duration>` (`10h`, `10 hours`, `90m`, `45 minutes`) — give the fleet's marker a `deadline_epoch`. Each session's
  `/auto` checks it before picking new work, never mid-issue: at the deadline every session finishes its in-flight issue,
  then ends with `NO-CANDIDATES: fleet deadline reached`.
- `epic:<ID>` — scope every session to that epic's graph: the prompt becomes `/loop /auto epic:<ID>`, so each pick runs
  `next-candidates.sh --root <ID>` against live membership. The count defaults from `tmp/fleet-recommendation-<id>.json`,
  which `/epic-prep <ID>` wrote (a recommendation whose `scope` is not this epic refuses the launch — it was moved by
  hand). Validated fail-closed through `scripts/epic-graph.sh` before anything is dispatched or written: a missing issue
  or one without the `epic` label refuses the launch. **An epic scope implies `backlog`**: the prompt is
  `/loop /auto epic:<ID> backlog` and the marker records `backlog: true`. Completing the epic is the goal, so a member
  deferred to Backlog — a review's sub-issue filing, an unpromoted member — is picked once nothing Planned/Todo in the
  scope is pickable. The scope cut bounds it: the epic's own members only, never the team's Backlog.
- `backlog` — the prompt gains ` backlog` (`next-candidates.sh --backlog-fallback`): a session with nothing Planned/Todo
  pickable takes Backlog instead of idling on `PLANNED-HOLD`; Planned/Todo stays strictly first at every pick. The opt-in
  for a day with spare usage (the gate is the default — `standards/linear-workflow.md` § Stage Priorities); it changes
  spending policy only, the headroom gate still parks near the 5h ceiling. Recorded as `backlog: true` in the marker. A
  session's mode is fixed at launch — open the fallback on an idling fleet with `/fleet-launch <n> <remaining duration>
  backlog`. Implied by `epic:<ID>`.
- `stale-ok` — launch although `~/.claude` is behind `origin/main` in a file the sessions load, with a one-line `WARN`.
  Without it that state stops the launch with `TOOLING-STALE` (exit 4). Composes with every other token.

Ending a running fleet early is [`/fleet-stop`](../fleet-stop/SKILL.md); the picture any time is
[`/fleet-status`](../fleet-status/SKILL.md). Both take the same `epic:<ID> | team` token to name a fleet.

### Epic-scoped launch — the integration branch

An epic ships as one PR, merged into as you go. `/epic-prep <ID>` creates the integration branch from the same source
`/start wt` would resolve (`start.wt-source-branch` when set, else the checkout's branch) and records `scope`, `members`
(the burn-down baseline `/fleet-status` reads), `branch`, and `base` in `tmp/fleet-recommendation-<id-lower>.json`. When
that epic launches, the script verifies the branch exists locally and that `start.wt-source-branch` is unset or already
names it (another value means another epic fleet's posture is in effect: refuse), **leaves the main checkout exactly
where it is** — no detach, no checkout-wide key — and records `scope`, `members`, `branch`, and `base` in the epic's marker.

Steering is per pick: each session's `/auto` runs `~/.claude/scripts/auto-fork-key.sh set <ISSUE-ID> <EPIC-ID>` before
every `/full auto wt` dispatch, pointing the per-issue `start.<id>.wt-source-branch` key at the epic marker's branch (the
script's header documents the key). Every fleet pick forks from the branch and every `/finish merge` advances it ref-only,
while the human's own `/start wt` still forks from the checkout's branch. A team-scoped or targeted `/auto` runs the same
script without an epic, and it scans the live epic markers for the fleet whose `members` list the issue — so a member
another fleet picks first still lands on its epic's branch. A checkout ON the integration branch launches with a `WARN`:
merges then fast-forward its tree and defer to the merge queue while it is dirty — check out the base.

After the fleet, `~/.claude/scripts/epic-pr.sh <EPIC-ID>` opens the PR from `branch` onto `base`, and `/pr-update <PR#>`
writes its description. Sessions clear the fork keys
of shipped members; `git config --get-regexp 'wt-source-branch'` lists any left by failed members (kept so a resume still
lands on the epic) — unset them once those issues are resolved. A token whose epic has no prepared branch launches on the
checkout's own branch with a WARN naming `/epic-prep <ID>`. `FLEET_PROMPT` still overrides the prompt; an override that
drops the scope is warned about, not corrected.

## Behavior

Run from the project the fleet should work on (a worktree cwd is fine):

```bash
~/.claude/scripts/fleet-launch.sh 5 10 hours
```

Surface the script's output: the `Concurrency cap:` line with its reason, the `Concurrency:` line when other fleets or
carried sessions are running, the deadline (if any), the `Kept un-retro'd fleet(s)` / `Expired retro'd fleet(s)` lines,
each dispatch line, each claim-landed/timeout line, and the closing `claude agents` pointer. A claim-wait timeout is a
WARN, not a failure — the session may be in preflight, resuming a dead worktree, or the pool may have drained mid-launch.

### Several fleets in one checkout

- **One marker per fleet.** `tmp/fleet-deadline-<slug>.json` is written by the launch of that slug alone; `/auto` reads
  the marker its own `epic:` argument names (none → `team`), `hooks/auto-deadline-gate.sh` reads the same one from the
  session's `/loop` delivery, and `auto-fork-key.sh` reads the epic a caller names. A team fleet's deadline never ends an
  epic fleet's session, and vice versa.
- **The cap is shared.** `Concurrency: <carried> carried session(s) + <k> in other fleet(s) (<slugs>) + <new> new = <n>
  running against the cap of <cap>` counts every live, non-retiring session in the checkout; over the cap the remedy
  names the other fleets (`/fleet-stop epic:<ID> | team`) beside the carried sessions.
- **Shared members: first picker wins** (keeper decision 2026-10-28). Two running fleets whose graphs share an issue (a
  common blocker; a team fleet beside an epic fleet shares every member) compete for it the way siblings do — the claim
  decides — and the picker lands it on the branch of the epic fleet it belongs to, because every `/auto` pick runs
  `auto-fork-key.sh`. Nothing is hidden from either fleet and nothing refuses the pairing.
- **Observers take the token.** `/fleet-status` renders every running fleet as its own section and `epic:<ID> | team`
  reads one; `/fleet-stop` needs the token once several run; `/fleet-retro` names the fleet with `--fleet <slug>` and
  `fleet-metrics.py --list-fleets` shows what is recorded.

**An epic fleet ends itself once only keeper-gated members remain.** `/epic-prep` promotes `human`, `needs decision` and
uncertified members beside the root, so once the workable members ship nothing in the scope can release without the
keeper: `next-candidates.sh --root <ID>` returns the drained headline with an `_EPIC-DRAINED: …_` note and every session
ends on `NO-CANDIDATES` as soon as no member is in flight — the deadline is an upper bound, not the expected end. A scope
whose remaining members are workable but withheld behind the gate keeps holding, and a team fleet always holds.

### Tooling confirmation — stale ~/.claude is asked about, never launched on

Every session runs the hooks, skills, rules and scripts in `~/.claude`, and nothing updates that checkout while the fleet
runs, so [scripts/claude-freshness.sh](../../scripts/claude-freshness.sh) fetches `origin main` (bounded at ~10 s) before
anything is written or dispatched. Current is silent; behind only in files no session loads, or a failed fetch, is one
`NOTE:` line and the launch proceeds — an offline launch is never blocked.

On `TOOLING-STALE` (exit 4 — behind in a session-loaded file, up to 8 commits listed) nothing was dispatched or written.
Relay the commits, then ask (AskUserQuestion): run `/update`, then re-launch (recommended); launch anyway with
`stale-ok`; or cancel. Re-run the same script line with the tokens kept. When the output ends `the ~/.claude pull will
refuse (…) — run /keeper first`, a local edit or commit would stop `/update`'s `--ff-only` pull: say `/keeper` comes
first.

### The count — 3 per account with room, settled before launch

**Concurrency is capped at 3 sessions per account with room, settled before launch: `scripts/fleet-cap.sh` owns the
arithmetic, `/auto-prep` and `/epic-prep` recommend under it, and the launch prints its line (`Concurrency cap: <n>
per_account=3 accounts_with_room=<k>/<total> <why>`) and WARNs above it, never refusing — an explicit count remains the
user's override.** The count is never derived from how full a window reads at dispatch. The account meters a 5h burst
window and a weekly window, and they resolve so:

- **The 5h burst window is per account, and 3 per account is the measured answer.** Burn per window is `n × 5 × rate` —
  duration never appears, so no deadline choice relieves it — and at opus/xhigh on this workload 3 sessions run for any
  duration without reliably exhausting one account's window while 4 do not. Saturating a window throttles every session
  at once (same wall-clock, less shipped, worktrees still held), so the cap is a ceiling to respect, not a target to creep
  past. A materially different workload (another backlog's burn rate, a lower-tier model mix) voids the bracket, and the
  account's own meter re-measures it per run: `/fleet-retro`'s Headroom verdict says how many sessions the window fit at
  the peak reading, and the same answer on consecutive unthrottled runs is the evidence to move the per-account figure.
- **A rotating machine multiplies the cap by its accounts with room.** Every session burns on the one account the login
  names, so on a machine rotating through cswap (`scripts/cswap-setup.sh`) the engine moves the login at its threshold
  to an account with room, that window fills next, and the first resets 5h after its block began: the pool refills at
  `accounts with room × one window's rate`, and the cap is `3 × accounts with room`, bounded by the script's count range
  of 12. "Room" is `fleet-headroom.sh`'s own predicate — an `ok` figure under 15 minutes old, the binding window under the
  engine's threshold, an engine event within 5 minutes — the active account included while it is under the threshold;
  `fleet-cap.sh` reads the count from the probe's `--json` verdict. An idle engine or an unreadable cswap is one account's
  window again, and the line says so (`/cswap log`). Nothing asks for `/cswap quota` to size a fleet: the cap is the pool
  as the engine sees it, and more sessions than lanes idle whatever the pool holds.
- **The weekly window is not a sizing input.** The keeper runs multiple accounts, so weekly-remaining sizes neither `n`
  nor duration — rotating to an account with room before launch is the lever. The script prints the active account's
  `Weekly (seven_day)` reading from `~/.claude/local/rate-limits.json` (the `rate-limits` mod's snapshot, last writer
  wins), never silently (`… no reading (<why>)`) and never blocking: a warning at 70% used when the reset falls after the
  deadline, a note when it falls inside the run. The `Burst (five_hour)` line warns past 80% used — every session would
  park at its first pick until the reset; a reset within 15 minutes, or already passed, is a note.
- **Runs longer than ~5h ride the ceiling deliberately; the protection is `/auto`'s headroom gate, not a smaller `n`.**
  Sessions probe `scripts/fleet-headroom.sh` at every pick and park with a wakeup pending when the account's 5h reading is
  within the reserve of full (on a cswap-rotating machine, only when no other account has room), so the fleet grazes the
  limit between issues instead of dying mid-issue (`hooks/auto-rewake.sh` recovers a mid-issue kill, but the killed turn's
  work is redone). The operator's own interactive session and an earlier fleet whose window has not rolled off draw on the
  same window outside the burn arithmetic: disclose them when choosing a duration, never as a reason to shrink `n` —
  parking is the designed response. Staggering does not substitute: saturation is a steady-state rate deficit, so a
  stagger only delays the first cutoff by its own length. If the gate is ever suspect, the zero-code fallback for an
  unattended long run is `n=2`, which never saturates.
- **A cutoff is attributed from the harness message, never inferred from the stall's shape** — the limits leave an
  identical synchronized-silence fingerprint. `/fleet-retro`'s `quota_stall_groups[].limit_kind` names it: `5-hour` at
  `n` within the cap re-opens the per-account bracket on a single-account machine, and on a rotating one means the swap
  landed late — the engine's blind spot is about 90s at the threshold and a fleet's climb rate scales with `n` — so the
  lever is a lower threshold (`cswap-setup.sh --no-enroll --threshold <N>`), measured by the next retro, before `n`
  shrinks; `weekly` means rotate accounts, not shrink the fleet; `session` IS the 5h window under another name (resets on
  exact 5h boundaries) and routes as `5-hour`.

Model, effort and permission-mode defaults are the script's own (added only for flags not already passed) and follow
`/auto`'s unattended-run prerequisites (`skills/auto/references/launch-prereqs.md`): permission mode `auto`, not
`acceptEdits`, which stalls a background session at the first gated Bash prompt.
No `--autocompact`: the `loop-boundary` mod compacts each session to one boundary message when an iteration ends with an
outcome line, so every iteration starts at the session floor (`mods/loop-boundary/README.md`); the launch refuses, exit 5,
where `loop-boundary@alienfast-claude` is not enabled (`scripts/mod-enabled.sh`), unless an explicit `--autocompact` after
`--` supplies a cap, which downgrades the refusal to a WARN. **Never restart or resume a deep fleet session** — recover
in-flight issues in fresh targeted sessions (`/auto BF-XXX` re-enters the existing worktree). Anything after `--` passes
through to `claude --bg`; `FLEET_PROMPT` overrides the dispatched prompt.

### Ledger expiry — a launch never discards a fleet the retro has not measured

Per-session ledgers (`tmp/auto-state-*.json`, shape in `skills/auto/SKILL.md` Step 4) and markers persist after a fleet
ends so the operator and `/fleet-retro` can read them; a launch is where they expire, by fleet (keeper decision
2026-10-28). Before dispatching, the script reads every marker in `tmp/`:

- A fleet with a session the registry (`claude agents --json`) still runs is left alone, ledgers included — a member that
  died mid-fleet stays listed and measurable.
- An ended fleet the history names (`tmp/fleet-metrics-history.jsonl` has a row sharing a session with its
  `fleet_sessions`) is **expired**: marker and the ledgers only it named are deleted, and the launch lists it under
  `Expired retro'd fleet(s)`.
- An ended fleet the history does not name is **kept** and listed under `Kept un-retro'd fleet(s)` — run `/fleet-retro`
  for it whenever it suits; `fleet-metrics.py --list-fleets` shows what waits. Nothing ever has to be retro'd before a
  launch.
- This slug's own marker, when its fleet has ended (deadline passed, stopped, or no live session), is archived as
  `tmp/fleet-deadline-<slug>.<launch_epoch>.json` instead of rewritten — the retro picks it with `--fleet
  <slug>@<launch_epoch>` — and its still-running sessions are carried as retiring. A running fleet of the same slug is
  topped up in place.
- A ledger no kept marker names (a targeted run's, a pre-2026-10-28 fleet's) is cleared once its session is dead —
  absent from the registry, or listed as ended (state `done`/`failed`/`stopped`, or the row `claude stop` leaves with
  `status` and `pid` gone). The ledger's recorded pid cannot answer liveness: in a daemon-backed fleet it is the daemon's
  own. A live **loop** ledger scoped to this slug and named by no marker pulls `launch_epoch` back to its mtime and is
  carried into `fleet_sessions`, so a top-up never hides a running sibling; a live single-run ledger (`mode: single`)
  does neither. Without a registry nothing is cleared or carried.

`/reap-tmp` flags an ended fleet nobody measured once it has sat 30 days, and never deletes one.

## The deadline contract (shared with /auto)

- Marker: `<main-checkout>/tmp/fleet-deadline-<slug>.json` — the slug is the lowercased epic id of an epic-scoped
  launch, `team` for a bare one — written on **every** launch of that slug as `{fleet_sessions, count, launch_epoch}`,
  plus `{deadline_epoch, deadline}` when the launch carried a duration, plus `{scope, members}` (and `{branch, base}`
  when prep recorded an integration branch) when epic-scoped, plus `{backlog: true}` under the `backlog` token or an
  epic scope, plus `{retiring: [keys]}` when a relaunch carried sessions out of a marker already winding down (deadline
  passed, or `stopped: true`). A retiring session stays in `fleet_sessions` but `hooks/auto-deadline-gate.sh` treats the
  deadline as passed for it whatever the new `deadline_epoch` says, so it finishes its in-flight issue and stops, and
  stays retired through later top-ups. The launch prints how many carried, other-fleet and new sessions will run, WARNs
  above the cap (`scripts/fleet-cap.sh`, § The count — 3 per account with room), and WARNs when a carried session's
  ledger `backlog` differs from the launch's.
- `fleet_sessions` is the session set — the short id each `claude --bg` prints (`backgrounded · <id>`), recorded per
  dispatch and carried across top-ups, every member the running fleet already listed included — and is what
  `/fleet-status` and `/fleet-retro` scope by; `launch_epoch` is the scoping fallback for a marker without the set.
- `/auto` reads its own fleet's marker at Step 2 (after preflight, before the pick), so in-flight work always completes,
  and targeted `/auto <ISSUE-ID>` ignores it by construction.
- [`/fleet-stop`](../fleet-stop/SKILL.md) adds `stopped: true`, preserving the other fields, and never moves a deadline
  that has already passed.
- Sessions never delete the marker (siblings still mid-issue must see it). A launch of the same slug rewrites a running
  fleet's marker (a top-up resets or erases its deadline: re-pass the remaining duration when adding sessions) and
  archives an ended one, so a no-duration launch never inherits a dead fleet's deadline. Another slug's launch never
  touches it.

## Error Handling

- Not in a git repo, or `claude`/`jq` missing → the script errors before dispatching; relay it.
- A dispatch failure stops further launches but leaves launched sessions running — say how many made it and point at
  `claude agents`.
- No count and no `tmp/fleet-recommendation-<slug>.json` → run `/auto-prep` (team) or `/epic-prep <ID>` (epic), or pass
  a count. A recommendation older than 24h gets a staleness WARN — offer to re-run the prep. One whose `scope` is not the
  launch's slug → exit 1: it was moved or renamed by hand; re-run the prep or remove it.
- `TOOLING-STALE` (exit 4) is not an error: run the confirmation above and re-launch. `team` is not a token any more (a
  bare launch is the team fleet) and reads as an unparseable duration.
- An `epic:` scope that refused, a recorded integration branch that no longer exists, or a checkout-wide
  `start.wt-source-branch` naming some other branch → exit 1 before dispatching or writing; relay it. The remedy is
  `/epic-prep <ID>` (or unsetting that config once its work is done), never a retry without the scope.
- **Host health under a long fleet (macOS):** file churn can pin `fseventsd` at a full core when Apple's `corecaptured`
  replays the FSEvents history. Diagnose with `sudo sample fseventsd 5` and the size of
  `/System/Volumes/Data/.fseventsd`; the relief is clearing that directory's **contents** — never the directory itself —
  immediately before a reboot.
- A `/fleet-sequence` running alongside is not a refusal: the launch proceeds with a `NOTE:` naming it, its queued
  issues are hidden from this fleet's picks, and its child sessions' ledgers survive the ledger expiry. Relay the note.
  Another fleet running alongside is not a refusal either — § Several fleets in one checkout.
