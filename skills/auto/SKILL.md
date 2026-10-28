---
name: auto
description: Ship exactly one certified Linear issue per invocation, unattended — pick via `/next specified` (or ship a named `/auto BF-123`), run `/full auto wt`, record the outcome, end on a tagged line. Continuous operation is `/loop /auto`; `epic:<ID>` and `backlog` scope the pick. Use when the user says 'auto', 'work through the backlog', 'ship the next issue unattended', 'ship BF-123 unattended', or invokes /auto.
---

# Auto (Autonomous Backlog Iteration)

Ships exactly one Linear issue per invocation, end to end and unattended: finish any in-flight work, pick the best
certified issue via `/next specified` — or, in targeted mode (`/auto BF-123`), take the issue named — ship it via
`/full auto wt`, record the outcome, emit a tagged final line. Continuous operation is `/loop /auto`: each iteration is
one issue, and the loop ends itself on `NO-CANDIDATES` (backlog drained) or `AUTO-HALTED` (circuit breaker). Worktree
mode is always on. Read `references/rationale.md` when a rule here looks arbitrary.

## Authorization

Invoking `/auto` (directly or via `/loop /auto`) is the explicit, run-scoped standing grant for commits and pushes —
the single named exception to `standards/git.md`'s rule against session-wide grants, because unattended shipping is
this skill's entire contract. It covers exactly the `/finish auto` commit and push of each issue this run ships; never
force-pushes, history rewrites, or work that cannot be attributed to a Linear issue (Step 1). Every shipped change is
audited via the plan comment (`/start auto`) and completion comment (`/finish`) on its issue.

The `auto` token this skill forwards means every prompt site in the dispatched skills resolves to its documented
default (`skills/full/SKILL.md` § Auto mode). Model, effort, permission mode and the `loop-boundary` mod are set by
whoever launches the session: read `references/launch-prereqs.md` when launching or recovering an unattended run.

## Arguments

```text
/auto [pr] [backlog] [epic:EPIC-ID] [TEAM[,TEAM...] | ISSUE-ID]
```

Tokens are case-insensitive and order-insensitive. Parse order: strip `pr` and `backlog`; an `epic:` token is the epic
scope; a token matching `^[A-Za-z]+-[0-9]+$` is the issue ID (normalize via
`~/.claude/scripts/detect-issue-id.sh --validate-only --input <token>`); only then is a remaining bare token tried as a
team scope.

- `pr` opens a PR per issue instead of merging (pass-through to `/full`). The source branch then does not advance until
  PRs merge, so a dependent issue forks without its predecessor's code — use it only for independent issues or with a
  human merging promptly. Passed ONLY on the literal token — never inferred from how recent issues shipped, a project
  memory or `CLAUDE.md`, a sibling's choice, or a repo whose `main` is all PR merges. The unattended default is merge.
- `backlog` lets Step 2's pick fall through to Backlog once nothing Planned/Todo is pickable (forwarded to `/next`).
  Planned/Todo stays strictly first at every pick (`standards/linear-workflow.md` § Stage Priorities); the token only
  changes what an otherwise idle session does, and is what `/fleet-launch backlog` dispatches. Passed ONLY on the
  literal token — never inferred from a usage reading, the fleet marker, or a sibling's prompt. Composes with `pr` and
  either scope; with an issue ID it is an error. An epic scope implies it: `next-candidates.sh --root` opens the
  fallback for the epic's own Backlog members whether or not the token is passed, and `/fleet-launch epic:<ID>`
  dispatches the token so the ledger and the marker record the mode. The scope is unchanged — Backlog outside the
  graph is never offered.
- A team scope (`BF`, or `PL,BF`) restricts the run to those teams' certified backlogs (forwarded to Step 2 as
  `team:<KEYS>`); without it, scope follows `/next` (`$LINEAR_TEAM`, else every team). At most one, and it MUST
  validate: uppercase it and check every comma-part against the workspace's real team keys
  (`linear-cli teams list -o json`, case-insensitive). Any part that is not a real key — `wt`, `auto`, `team`, a typo
  — is an unrecognized argument: emit the error below and STOP (a run scoped to a nonexistent team would mark itself
  `drained` against an empty backlog). `pr` is reserved for the flag, so `pr,BF` fails by design; a team literally
  keyed `PR` scopes via `$LINEAR_TEAM`.
- An epic scope (`epic:BF-1826`) restricts every pick to the epic's graph — the epic, its transitive descendants, and
  the transitive blockers of any member, non-terminal, cross-team, recomputed at every pick (forwarded to Step 2 as
  `epic:<ID>`, which runs `next-candidates.sh --root <ID>`). It is what `/fleet-launch epic:<ID>` dispatches, with
  `backlog`, which the scope implies. At most
  one, and it MUST validate: `~/.claude/scripts/epic-graph.sh --ids <ID> >/dev/null` — exit 1 means no such issue or
  no `epic` label; emit its stderr and STOP. Composes with `pr` and a team scope (which only widens the fetch). Record
  it as `scope` in the run state (Step 4). When the epic's fleet marker (`tmp/fleet-deadline-<id-lower>.json`) records
  an integration `branch`, Steps 1 and 3 set a per-issue fork key before each dispatch, so the pick forks from and
  merges into the epic branch by ref while the main checkout stays wherever its human left it.
- An issue ID selects targeted mode (`/auto BF-123`, `/auto pr BF-123`): ship exactly that issue, skipping Step 2. At
  most one; with a team or epic scope or `backlog` it is an error:
  `Targeted mode takes no team or epic scope and no backlog token — /auto <ISSUE-ID> ships exactly that issue.`

Anything else — a second team-shaped token, issue ID or `epic:` token, or a token failing validation — errors:
`Unrecognized argument 'X'. /auto accepts optional 'pr', optional 'backlog', an optional epic scope (epic:BF-123), plus either one team scope matching a real team key (e.g. BF or PL,BF) or one issue ID for a targeted run; worktree mode is always on.`

### Targeted mode

`/auto` ships only certified specs, picked or targeted (`standards/issue-spec.md`). Before dispatching anything:

```bash
linear-cli issues get <ISSUE-ID> -o json | jq -r '.labels.nodes[].name' | grep -qix specified
```

- `specified` absent → refuse with a plain error — no lifecycle tag, no state change; the user just typed the ID:
  `<ISSUE-ID> is not certified (no specified label) — run /spec <ISSUE-ID> to certify it, or /full wt <ISSUE-ID> for an interactive run.`
  A probe failure from auth or network is Error Handling's `linear-cli` territory, never a silent pass.
- `human` present (same command, `grep -qix human`) → refuse the same way; that label marks work a person performs:
  `<ISSUE-ID> is human-owned work (human label) — assign a person, or /spec <ISSUE-ID> to split out an agent-shippable slice.`
- `solo` is legitimate: the label hides an issue from `/next` precisely so it arrives here by a typed ID. Never extend
  the probe beyond `specified` and `human`.

Targeted mode narrows the workflow in exactly four places, each marked at its step: Step 0's sticky terminal-state gate
is bypassed, Step 1 is scoped to the target, Step 2 is skipped, and Step 4 never transitions `status` or schedules a
wakeup. Everything else is identical. It is one-shot — run it directly, not under `/loop`. Its first user-visible line
is exactly `<ISSUE-ID>: ship`, before the probe and any other narration (Operating unattended says why).

## Operating unattended

Nobody is watching, so a question ends the run instead of resolving it. For any reversible action that follows from
the invocation, proceed — every prompt site in the dispatched skills documents an `auto` default, and taking it IS the
answer. The named exceptions halt with a tag: a dirty tree left by this run's own failed finish, a live sibling's
worktree, an uncertified target.

- Ground every progress claim in a tool result — a tag from the dispatched skill, a `git status`, an exit code. If a
  check failed, say so with its output; if a step was skipped, say that.
- Before ending a turn, read your last paragraph. If it is a plan, a question, or a promise about work not yet done, do
  that work now with tool calls. Every turn ends on a lifecycle tag or a genuine block.
- Context is not your concern: the `loop-boundary` mod resets it at every iteration boundary
  (`mods/loop-boundary/README.md`) and the ledger (Step 4) is the cross-iteration memory. `/compact` and `/clear` are
  user commands — never attempt them, and never stop, summarize, or propose a new session on account of context.
- Issue-keyed narration. The `claude agents` view names a session from its FIRST user-visible line and never renames
  it — hence a targeted run's `<ISSUE-ID>: ship`, with nothing else the namer could prefer. Its status line is
  re-summarized from recent activity, so from the moment the issue ID is fixed (Step 2's pick, or the targeted
  argument) until the iteration tag, begin every user-visible status line with `<ISSUE-ID>: `, kept short. This
  composes down through `/full`, `/start`, and `/quality-review`, which run in-session. Lifecycle-tag lines are exempt:
  their `<TAG>: <ISSUE-ID> — …` contract already carries the ID and stays TAG-first.

## Workflow (one iteration)

### Step 0: Entry gate — re-anchor and read the run state

1. **Release and re-anchor.** Call `ExitWorktree(action: "keep")` — a no-op when nothing is registered; it clears a
   registration that may point at a worktree the prior iteration's `/finish merge` or the reaper has deleted, so the
   next `/start wt` `EnterWorktree` is a clean first entry. Then resolve the main checkout (the first `worktree <path>`
   line of `git worktree list --porcelain`) and `cd` there.
2. **Session identity.** Run `~/.claude/scripts/session-identity.sh`; read `RUN_KEY` (the per-session id when the
   harness provides one, else the stable harness PID) and `HARNESS_PID`/`HARNESS_PID_START`. Never key on raw `$PPID`:
   under `claude agents` the tool shell's parent is a transient pool process, and a harness restart changes pids
   mid-session; the session id survives both.
3. **The run-state path** is `<main-checkout>/tmp/auto-state-<runKey>.json` — per-session, so parallel sessions never
   adopt or clobber each other's state. Carry the absolute path through the iteration for every read and write; a
   state file touched inside a worktree fragments the run and dies with the worktree. Write it via the shell
   (`printf '%s\n' '<json>' >| <path>`) — the worktree-isolation guard refuses Write-tool edits outside the registered
   worktree, and this is gitignored run bookkeeping, not project code; never relocate it into the worktree and never
   set `worktree.bgIsolation: none`. Wherever this skill says `tmp/auto-state-<runKey>.json`, tag texts included,
   substitute the actual value.
4. **Hygiene on entry.** If the file exists and `RUN_KEY` is a session id, refresh its `pid`/`pidStart` when they
   differ (a harness restart changed the pid, not the run). If `RUN_KEY` is the pid fallback, a mismatch means PID
   recycling — recreate it empty rather than inherit foreign state.
5. **GC has exactly one safe target:** a sibling `tmp/auto-state-*.json` whose `status` is `"active"`, whose embedded
   `pid` is not a live process, AND whose four outcome lists are all empty — a run that died before recording anything.
   Any file with a recorded outcome, and any `drained` or `halted` file, is a ledger and is never deleted
   (`/fleet-retro` discovers sessions from them; expiry is `/fleet-launch`'s job). Content protects a ledger, not
   liveness: under `claude agents` every session embeds the SAME fleet-root pid. A legacy un-suffixed
   `tmp/auto-state.json` belongs to no current run: ignore it (mention once that it can be deleted).
6. **Sticky terminal states.** Read the file (Step 4 has the shape). If `status` is `halted` or `drained`, do not
   proceed — re-emit the stored condition from `reason`, appending nothing (it already ends with its next action):
   `halted` → `AUTO-HALTED: run previously halted — <reason>`; `drained` → `NO-CANDIDATES: <reason>`. If `reason` is
   empty, emit
   `reason unavailable — see the run's Linear comments and the shipped/canceled/skipped/failed lists in tmp/auto-state-<runKey>.json; delete it to start a fresh run.`
   — never improvise a cause. This holds the breaker under fixed-interval `/loop`, which re-invokes regardless of the
   previous tag; a human starts a new run by deleting the file or starting a new session. Missing, unreadable, or
   corrupt → recreate it empty (`status: "active"`, this session's `pid`/`pidStart`) and continue.
7. **Targeted mode bypasses the re-emission** — a typed issue ID is the human intervention the halt asked for. Leave
   `status` untouched (it still governs the next bare invocation); the outcome still records into the lists.

### Step 1: Preflight — finish in-flight work

**Targeted mode scopes this step to the target.** Dirt attributable to the target is this run's resumption — dispatch
`Skill(skill: "finish", args: "auto <ISSUE-ID>")`; dirt attributable to a different issue refuses with a plain error
and no state change:
`Main checkout is dirty on <branch> with work for <OTHER-ID> — run bare /auto to preflight-finish it, then re-run /auto <ISSUE-ID>.`
Unattributable dirt proceeds as check 1's last row. Check 2 reduces to the target's own merge-queue guard: if
`<main-checkout>/.claude/merge-queue/<target-id-lowercased>.json` exists, refuse — it already shipped and the drainer
owns it (`/merge-queue`). Skip the orphan sweep; Step 3's `/full` resumes a dead owner's worktree and refuses a live
one.

Two checks, in order:

1. **Dirty main checkout.** Run `git status --short` and `git branch --show-current`. If dirty, re-run the status under
   the repo lock —
   `~/.claude/scripts/with-repo-lock.py "$(git rev-parse --path-format=absolute --git-common-dir)" git status --porcelain`
   — which waits out a sibling's in-flight `/finish merge` or locked create; clean → check 2. Still dirty → attribute
   by **branch name only** (an `[a-z]+-[0-9]+` segment) and verify the issue is In Progress and assigned to me. Never
   use `detect-issue-id.sh`'s commit-subject fallback here: every commit subject carries a real issue ID, so it would
   attribute foreign WIP to whatever the last commit mentions and ship it.
   - Attributable and not in this run's `failed` list → dispatch `Skill(skill: "finish", args: "auto <ISSUE-ID>")` with
     no mode token (`finish-detect-mode.sh` detects the mode from where the work lives). Its terminal tag is this
     iteration's outcome (Step 4); do not also start a new issue.
   - Attributable but already in `failed` → retrying is a loop, not progress. Set `status: "halted"` and emit
     `AUTO-HALTED: dirty working tree for <ISSUE-ID> failed to finish and needs a human (see its Linear comment) — resolve, then delete tmp/auto-state-<runKey>.json and re-invoke /auto.`
     (Environment halt — `consecutiveFailures` untouched.)
   - Not attributable → not this run's work and not in its way: proceed to check 2. Picks fork from the branch ref,
     and `finish-merge.sh` fast-forwards the checkout around uncommitted edits to files a merge leaves alone (a merge
     that changes a dirty path defers to the queue). Name the dirty paths once in the summary sentence and never touch
     them: committing someone's edit ships it, discarding it destroys it.
2. **Orphaned issue worktrees** (a prior `wt` iteration died mid-implementation; invisible to `git status`). Run
   `git worktree list`; a candidate is each `.claude/worktrees/<id>` whose issue is In Progress and assigned to me and
   not in this run's four outcome lists (`shipped` included: `DEFERRED-MERGE` and `SHIPPED-PR` leave an intact worktree
   with the issue In Progress). "In Progress + mine + worktree exists" does NOT mean orphaned — a sibling's live
   iteration looks identical. Two gates per candidate, in order:
   - **Queued merge:** `<main-checkout>/.claude/merge-queue/<issue-id-lowercased>.json` exists → it shipped as
     `DEFERRED-MERGE` (possibly from another session) and the drainer owns it. Skip; never resume.
   - **Owner liveness:** `~/.claude/scripts/wt-owner.sh <worktree-abs-path>`, reading `OWNER_ALIVE`/`OWNER_IS_ME`.
     Adjudicate `released` first — it outranks `OWNER_IS_ME`; a worktree this session released earlier is a candidate
     again. `released` or `dead` → resume: on an epic-scoped run set Step 3's fork key first (a reused worktree is
     re-stamped with the source branch `/start` resolves now), then dispatch
     `Skill(skill: "full", args: "auto wt [pr] <ISSUE-ID>")` and treat its tag as this iteration's outcome.
     `alive` + `OWNER_IS_ME=0` → a sibling is working it: skip silently, add it to no list. `alive` + `OWNER_IS_ME=1`
     → this session's own in-flight iteration: skip. `unknown` → never resume (a live owner cannot be ruled out);
     leave it parked and name it in the summary sentence for a human (`/full wt <ISSUE-ID>`).

   Resume at most one per iteration. **Flag the rest:** every further dead-owner candidate gets the `stalled` label
   (`~/.claude/scripts/linear-add-label.sh <ISSUE-ID> stalled`, best-effort, idempotent), then its stamp released
   (`~/.claude/scripts/wt-disown.sh <worktree-abs-path>`; no `--force` on a provably dead owner). Label before disown —
   a disown failure still leaves a labeled issue a human can force-release. Never label an `alive` or `unknown` owner's
   issue: downstream reads `stalled` as "ownership was released" (`/start` offers a force-takeover on it).

Clean tree and no resumable worktree → Step 2.

### Step 2: Pick — dispatch /next

**Targeted mode skips this step** — the typed ID is the pick, already validated. Proceed to Step 3.

**Fleet gates** apply when a fleet marker exists — `<main-checkout>/tmp/fleet-deadline-<slug>.json`, one per fleet,
written by every `/fleet-launch` and `/fleet-stop` and absent outside fleets. **This run's own marker** is the slug its
arguments name: the lowercased epic id of its `epic:` scope, else `team`; an archived `fleet-deadline-<slug>.<epoch>.json`
is never read. The deadline gate reads that marker alone (a sibling fleet's deadline is not this run's budget); the
headroom gate applies while any marker exists. Read `references/fleet-gates.md` for both gates' mechanics; the rules:

1. **Deadline.** If `date +%s` ≥ the marker's `deadline_epoch`, or this session's run key is in its `retiring` list,
   the budget is spent: run `~/.claude/scripts/auto-push-main.sh` from the main checkout, set `status: "drained"` with
   `reason`, and emit
   `NO-CANDIDATES: fleet deadline reached (<deadline field>) — <shipped>/<canceled>/<skipped>/<failed> this run; push: <the script's line>. Delete tmp/fleet-deadline-<slug>.json (or re-run /fleet-launch for this fleet) and delete tmp/auto-state-<runKey>.json to run again.`
   (`ScheduleWakeup(stop: true)` under self-paced `/loop`). The gate is the deadline's only point of contact with the
   run: a picked issue runs its full pipeline however far past the deadline that lands, and the marker is never deleted
   from this skill. `hooks/auto-deadline-gate.sh` backs it.
2. **Headroom.** Run `~/.claude/scripts/fleet-headroom.sh --session "$RUN_KEY"`. Exit 0 (`PICK-OK`) → proceed. Exit 2
   (`THROTTLE`) → a pick now would likely be killed mid-issue by the account's 5-hour limit: do not pick. A pause, not
   an outcome — touch no `status`; end as an `AUTO-CONTINUE` no-pick whose summary is the probe's line, and under
   self-paced `/loop` arm `ScheduleWakeup` (`noop: true`, `delaySeconds` = the line's `resets_in` + 60, clamped to
   [60, 1800]). The probe fails open when no reading exists. It governs every pick, the hot handoff included.

**Hot handoff — a certified child the just-shipped issue filed preempts the ranking, once.** When the immediately
preceding iteration in THIS session shipped its issue and that run filed deferred children, and one is `specified`,
unblocked, and carries no gating label (`needs decision`, `human`, `solo`), take the highest-priority such child as
this iteration's pick instead of dispatching `/next` — the session still holds the parent's loaded context, which a
cold pick discards. Bounds: consecutive iterations of the same session only (a compaction does not disqualify; a
different intervening pick does); one hop — a hot-picked child's own filings never qualify; the child takes Step 3's
normal claim path, so losing it to a sibling is an ordinary `SKIPPED-BLOCKED`.

**Dispatch** `Skill(skill: "next", args: "specified")`, appending ` team:<KEYS>` for a team scope, ` epic:<ID>` for
an epic scope (the ranking and every hold note then cover the epic's members only), and ` backlog` for the fallback
token (Backlog is then offered once nothing Planned/Todo is pickable, under a `_BACKLOG-FALLBACK: …_` note — carry it
verbatim into the iteration tag's summary so the ledger says the pick was fallback work). Handle the result:

- **`PLANNED-HOLD` with nothing pickable** → wait; never `drained`. Every Planned/Todo issue is worked before any
  Backlog issue (`standards/linear-workflow.md` § Stage Priorities). Touch no `status`, change no lists, skip the
  double-run rule (this is an explicit verdict, not an empty fetch). End as an `AUTO-CONTINUE` no-pick whose summary
  is the note verbatim; under self-paced `/loop` arm `ScheduleWakeup` with `noop: true` — **600s** when the note lists
  issues that will release on their own (a sibling's ship is the wake signal), **1800s** when only *need the keeper*
  entries hold it. Under `backlog` this hold arrives only when Backlog has nothing pickable either; same waits.
- **`BLOCKED-HOLD` with nothing pickable** → wait exactly as above, **600s**: the pool is chained behind a sibling's
  in-flight issue (`blocks` edges) — the normal shape of a fleet's first picks, not a drained pool.
- **No candidates** (the drained headline, *No workable issues*, with neither hold note) → **re-run the identical
  `Skill(skill: "next", …)` once, back-to-back,** and latch `drained` only if BOTH runs come back empty — a transient
  empty fetch prints the same text and exits 0. If the second returns candidates, take the top-ranked one and note the
  discrepancy in the summary. Once both agree, set `status: "drained"` and emit
  `NO-CANDIDATES: <team-scope> backlog drained of certified issues — <shipped>/<canceled>/<skipped>/<failed> this run. Run /spec to certify backlog issues (or /prd to seed new ones), then delete tmp/auto-state-<runKey>.json and re-invoke /auto.`
  `<team-scope>` is the scope `/next` searched (`PL`, `PL+BF+MAR`, or `epic BF-1826` — a drained epic must never read
  as a drained team). Under self-paced `/loop`, `ScheduleWakeup(stop: true)`.
- **Candidates exist** → take the top-ranked one; never prompt the user to choose. Skip any candidate already in this
  run's `shipped`, `canceled`, `skipped`, or `failed` lists (a `DEFERRED-MERGE` issue stays In Progress until the
  queue drains it). If every candidate is excluded that way, set `status: "drained"` and emit
  `NO-CANDIDATES: all remaining candidates were already attempted this run (<shipped>/<canceled>/<skipped>/<failed>). Delete tmp/auto-state-<runKey>.json to re-attempt.`
  **Under an epic scope, not while a member is in flight**: the ranking's `_In flight: …_` line names the members
  siblings are shipping, and each landing's review can file certified sub-issues into the scope that this session
  would take. While that line is present, end as an `AUTO-CONTINUE` no-pick whose summary names the attempted
  candidates and the in-flight members — **600s** under self-paced `/loop`, `noop: true` — and latch `drained` only
  when the line is absent (`references/pick-edge-cases.md`).
  Then **drop a candidate whose worktree a sibling live-owns**: if
  `<main-checkout>/.claude/worktrees/<issue-id-lowercased>` exists and `~/.claude/scripts/wt-owner.sh` on it reads
  `OWNER_ALIVE=alive` with `OWNER_IS_ME=0` (the condition `start-wt-create.sh` refuses on), walk down the ranked list
  until one passes. A drop is not a skip — write nothing to `skipped`; if it empties the list, end `AUTO-CONTINUE`
  with no pick and do NOT set `drained` (a live sibling is transient).

Read `references/pick-edge-cases.md` when the result is an epic-scoped run's `_EPIC-DRAINED: …_` or in-flight hold
note, or when the top candidate's blocker must be live in production rather than merged (a deploy-gated candidate).

### Step 3: Ship — dispatch /full auto wt

**Point the fork key first, in every mode.** Epic-scoped: `~/.claude/scripts/auto-fork-key.sh set <ISSUE-ID> <EPIC-ID>`
reads that epic's marker. Team-scoped or targeted: `~/.claude/scripts/auto-fork-key.sh set <ISSUE-ID>` scans the live
epic markers for the fleet whose `members` list the issue, so a member this run claims before the epic's own fleet does
still lands on the epic's branch (first picker wins; `skills/fleet-launch/SKILL.md` § Several fleets in one checkout).
Carry its `FORK-KEY:` line into the summary sentence. With an integration `branch` recorded it sets
`start.<id-lower>.wt-source-branch`, so `/start wt` forks from that branch's ref and `/finish merge` advances it
ref-only; the main checkout never moves. `FORK-KEY: none …` (no marker, no fleet listing the issue, no branch, or a
`WARN` that the recorded branch is missing locally) is not an error — the pick forks from the checkout's branch. Exit 1
(a `/fleet-sequence` holds this issue's key) → do not dispatch; a transient `SKIPPED-BLOCKED` with the script's message.

Call `Skill(skill: "full", args: "auto wt [pr] <ISSUE-ID>")` — `pr` only when the invocation carried the literal
token. `/full auto` runs `/start auto`, `/quality-review auto`, and `/finish auto`, and terminates with exactly one
lifecycle tag. Wait for it; do not narrate ahead. Do NOT arm a heartbeat before this dispatch — `ScheduleWakeup` ends
the turn, so arming here would skip `/full` entirely; a turn that stalls inside `/full` is recovered by
`hooks/auto-heartbeat.sh`. The tag is Step 4's input — never end the turn on it (`standards/lifecycle-tags.md`,
Nesting).

A `simple`-labeled pick gets the simple review tier with no token here: `/start` reads the label and forwards it
(`standards/issue-spec.md` § The `simple` label). `simple` is not an `/auto` argument — the label is the mechanism.

### Step 4: Record outcome + emit the iteration tag

This skill is the canonical home of the ledger `tmp/auto-state-<runKey>.json` (Step 0's pinned path):

```json
{
  "pid": 50330,
  "pidStart": "Tue Jul 21 14:46:01 2026",
  "mode": "loop",
  "scope": "BF-1826",
  "backlog": true,
  "status": "active",
  "reason": "",
  "shipped": ["UI-3"],
  "canceled": ["UI-9"],
  "skipped": ["UI-7"],
  "failed": ["UI-5"],
  "consecutiveFailures": 0,
  "reviewBlocks": 0
}
```

- `pid`/`pidStart`: the GC liveness anchor (Step 0's `HARNESS_PID`/`HARNESS_PID_START`), written at creation, refreshed
  by Step 0 after a harness restart. In a fleet the pair is the fleet root's, shared by every session — it identifies
  the fleet's liveness, never this session's, and `pidStart` is the daemon's start, not the session's age (that is the
  ledger's birth time, `stat -f '%SB'`). Write your own resolved values; never copy a sibling's. `runKey` (the
  filename) is the per-session identity.
- `mode`: written once — `loop` when the invocation arrived through `/loop` (its command block, or a wakeup
  re-delivering it), `single` for a direct invocation (targeted, or a one-shot bare `/auto`); absent reads as `loop`.
  `scope` (the epic's id) is present only on an epic-scoped run; `backlog: true` only under the `backlog` token, which
  `/fleet-launch epic:<ID>` always dispatches.
- `status`: `active` → `halted` (breaker or environment halt) / `drained` (no candidates); never back — a new run
  starts by deleting the file. Whichever step sets a terminal `status` also writes `reason` (the one-line summary its
  tag carries) so Step 0's re-emission is verbatim.
- `shipped`/`canceled`/`skipped`/`failed`: bare issue ids. `canceled` is its own list, never a `shipped` variant, so
  the tally reconciles against git. A file predating `reviewBlocks` reads as 0; one predating `canceled` as `[]`.

Read the file, apply the mapping below, write it back, then emit the tagged final line. The file — not conversation
memory — is the source of truth across iterations and compactions. Before applying a failure row, check
`references/api-failures.md`: an iteration that died on a transient API error is retried, not recorded. On an
epic-scoped run, after a Shipped or `CANCELED` row run `~/.claude/scripts/auto-fork-key.sh unset <ISSUE-ID>`; leave
the key on every other row so a resumed member keeps merging into the epic branch.

| Tag from Step 1/3 | Meaning | State update | Iteration tag |
| --- | --- | --- | --- |
| `RELEASED` / `SHIPPED-MERGE` / `SHIPPED-PR` / `DEFERRED-MERGE` | Shipped (`DEFERRED-MERGE` self-resolves via the merge queue) | append to `shipped`; `consecutiveFailures = 0` | `AUTO-CONTINUE` |
| `SKIPPED-BLOCKED` | Not startable now; nothing claimed | durable decline → append to `skipped`; transient → write nothing, so the issue stays eligible once the condition clears; unsure → append to `skipped` without a label; counters unchanged | `AUTO-CONTINUE` |
| `CANCELED` | Work already done or unneeded; `/start` closed the issue | append to `canceled`; `consecutiveFailures = 0` | `AUTO-CONTINUE` |
| `BLOCKED-ON-REVIEW` | The quality gate stopped the ship and flagged a human; the pipeline itself worked | append to `failed`; `reviewBlocks += 1`; `consecutiveFailures` unchanged; failure marking | `AUTO-CONTINUE` if `reviewBlocks < 4`, else `status: "halted"` and the review-cap `AUTO-HALTED` |
| `BLOCKED-ON-RECOVERY` / `ABANDONED` / `IN-PROGRESS` / unrecognized or missing tag | Something beyond the quality gate broke; the issue needs a human | append to `failed`; `consecutiveFailures += 1`; failure marking | `AUTO-CONTINUE` if `consecutiveFailures < 2`, else `status: "halted"` and `AUTO-HALTED` |

**Failure marking, in this order: comment → label → ownership release → state file.** Post a Linear comment
(`~/.claude/scripts/linear-post.sh comment`) stating the terminal tag, the reason, and that `/auto` is moving on; apply
the `stalled` label (`~/.claude/scripts/linear-add-label.sh <ISSUE-ID> stalled`) — the issue stays In Progress, and
the label is what distinguishes it from live work; release the worktree stamp
(`~/.claude/scripts/wt-disown.sh <main-checkout>/.claude/worktrees/<issue-id-lowercased>`, best-effort) — otherwise it
reads `alive` for this harness process's lifetime and every other session's create gate refuses the resume the comment
advertises; then write the state file. Outward markers first: an interruption then leaves a flagged, documented issue
the ledger has not yet counted, never a counted failure with no trace on the issue. `/start` removes `stalled` on
resumption, `mark-ready-for-release.sh` on ship.

**Human-gated stops are parks, not failures.** When a terminal tag's reason is something the pipeline may not or cannot
do itself, do not apply `stalled`: a **decision** the pipeline may not make parks under `needs decision`; a
**human-performed step** (credentials, console or vendor-UI work, outreach, production data remediation, a product
sign-off) parks under `human`. Park mechanics, in the failure marking's slots: comment naming the specific decision or
step; the routed label; move the issue back to `Planned` and unassign it; release the stamp, worktree preserved; write
the state file — the tag's row still governs counters and lists. A refusal of the pipeline's own step (the permission
classifier, a pre-commit hook, a merge guard) is a stall, never a park. A **durable** `SKIPPED-BLOCKED` (the issue as
written is not unattended-shippable) takes the same routed label and keeps `specified`; a **transient** one (a live
sibling, an open blocker `/next` missed) writes nothing to the ledger; unsure → `skipped` with no label. Read
`references/parks-and-declines.md` before recording any `SKIPPED-BLOCKED` or any stop whose reason names a human.

**Iteration tags** (`standards/lifecycle-tags.md` — the LAST LLM-authored line, nothing after it):

- `AUTO-CONTINUE: <ISSUE-ID> <outcome> (<inherited tag>). <shipped>/<canceled>/<skipped>/<failed> this run; next /loop iteration proceeds.`
  — under self-paced `/loop`, paired with a 60s `ScheduleWakeup` (Loop pacing below).
- Targeted mode: same mapping and list/counter updates, but `status` never transitions (`drained` is impossible with
  no pick; a failure does not set `halted` — the breaker protects recurrence, which a one-shot lacks; the incremented
  `consecutiveFailures` still counts toward a later bare run this session) and no wakeup is scheduled:
  `AUTO-CONTINUE: <ISSUE-ID> <outcome> (<inherited tag>). <shipped>/<canceled>/<skipped>/<failed> this run; targeted run complete.`
- `AUTO-CONTINUE: … retrying in ~15m.` — the transient-API variants in `references/api-failures.md`.
- `AUTO-CONTINUE: no pick — <PLANNED-HOLD or BLOCKED-HOLD note verbatim>. <shipped>/<canceled>/<skipped>/<failed> this run; waiting for the Planned/Todo column to drain.`
  (or `…; waiting for a sibling to ship.` under `BLOCKED-HOLD`) — no counters move.
- `AUTO-HALTED: 2 consecutive failures (<ID> <tag>, <ID> <tag>) — likely systemic. See Linear comments on both issues; delete tmp/auto-state-<runKey>.json to start a fresh run.`
- `AUTO-HALTED: 4 review-blocked issues this run (<ID>, <ID>, <ID>, <ID>) — a human needs to work the review queue (each is labeled stalled with a Linear comment); delete tmp/auto-state-<runKey>.json to start a fresh run.`

Ending on `AUTO-HALTED` or `NO-CANDIDATES` ends the loop until a human intervenes: under self-paced `/loop`, call
`ScheduleWakeup(stop: true)`; under fixed-interval `/loop`, schedule nothing (Step 0's sticky state absorbs re-fires).

## Loop pacing

Under self-paced `/loop` (no interval), every iteration must end with a `ScheduleWakeup` or the loop dies, and the
delay is this skill's call. Read `references/pacing.md` for the mechanics behind each figure.

- `AUTO-CONTINUE` after a pick → the minimum, **60s**. The backlog is the work queue; nothing external is awaited.
- The only other delays: ~900s API-error retry (`references/api-failures.md`), ~1800s fallback heartbeat, the headroom
  park (`resets_in` + 60, ≤1800s), `PLANNED-HOLD` (600s / 1800s), `BLOCKED-HOLD` and deploy-gated holds (600s).
- **No wakeup this skill arms exceeds 1800s.** Wait out anything longer as a chain of ≤1800s ticks.
- `NO-CANDIDATES` or `AUTO-HALTED` → `ScheduleWakeup(stop: true)`. It cancels the pending heartbeat and is what ends
  the background session (`hooks/auto-rewake.sh` retires it); `scripts/auto-stall-watch.sh --retire` is the backstop.
- **The fallback heartbeat is armed at turn end, never mid-turn.** `ScheduleWakeup` ends the turn, so arming it before
  an iteration's work idles the session for the full delay. Arm ~1800s as the last action of any turn that ends
  mid-iteration; the 60s tick supersedes it when the iteration completes. `hooks/auto-heartbeat.sh` blocks a turn
  ending inside an iteration with no wakeup armed and re-drives the arming. Fixed-interval and targeted runs get no
  heartbeat.
- A wakeup that re-delivers this skill mid-iteration is a status check, not a new iteration; one that finds no work in
  flight and no tag is a stall to resume; an `auto-rewake:` system reminder is a hook's recovery prompt, not a human's.
  All three are in `references/api-failures.md`.

## User stop semantics

A user instruction to stop the loop ("do not run another loop", "stop after this one", "no more iterations") ends
recurrence, not the in-flight iteration: schedule no further wakeup, write `status: "halted"` with the instruction as
`reason`, and complete the current issue normally — every inner loop keeps its documented budget. A red re-review
during wind-down enters `/quality-review`'s fix loop as it would have before; "not shippable yet" is the fix loop's
input, never a reason to park. Parking the in-flight issue requires explicit words — "park it", "stop now", "abandon
it" — and is never inferred from a stop instruction, a failing verdict, or their combination. Once you have announced a
wind-down default ("I'll finish this issue unless you say otherwise"), new information reopens it only through the
user; any surprise decision point during wind-down is asked, not improvised — the user is present, so "ask" dominates
"abort". A human prompt that recovers a stalled run resumes the iteration, Step 4 included
(`references/api-failures.md`).

## Parallel sessions

Multiple `/loop /auto` sessions on one repo coordinate through shared state, never through each other: Linear is the
claim registry (In Progress is invisible to every other pick; the residual race is closed by `start-wt-create.sh` under
the repo lock, the loser exiting `SKIPPED-BLOCKED`); worktree owner liveness distinguishes died from live (Step 1); run
state is per-session; the merge queue is cross-session. Never run an in-place (non-`wt`) `/start` on the same repo
while `/auto` runs — use `/start interactive <ISSUE-ID>`. Worktree rules: `standards/git-worktrees.md`. Why each
holds: `references/rationale.md`.

## Failure policy

- **Skip, don't stall:** a failed issue gets a Linear comment and preserved state; the loop tries the next candidate.
  The one exception is Step 1's dirty tree from this run's own failed finish, which halts.
- **Circuit breaker at 2** consecutive failures; any ship resets the counter; Step 0 makes the halt sticky.
- **Review blocks** (`BLOCKED-ON-REVIEW`) are exempt from the consecutive breaker but count as failures everywhere
  else; the **review-block cap** is 4 per run, total, never reset by ships.
- **Transient API errors** are never failures — retried on a ~900s cadence, never counted, never halted for — except a
  quota whose stated reset is materially beyond 3600s, which is an environment halt (`references/api-failures.md`).
- **Conservative everywhere:** every `auto` default chooses abort/preserve over override/guess. The worst acceptable
  outcome is "nothing happened and Linear says why" — never "something wrong shipped."

## Error Handling

- `Skill(next)` errors (non-API: auth, missing dep) → `status: "halted"`, emit
  `AUTO-HALTED: /next failed (<first error line>) — fix, delete tmp/auto-state-<runKey>.json, and re-invoke.` Not an
  issue failure. (Claude API overload or rate limit, or `/next` exit 4 / `RATELIMITED` → the transient rule: no pick,
  `AUTO-CONTINUE: paused pre-pick (Linear RATELIMITED); retrying in ~15m.` with a ~900s wakeup — never an immediate
  re-rank.)
- `tmp/auto-state-<runKey>.json` unreadable or corrupt → recreate it empty (`status: "active"`) and note the reset in
  the tag line's summary sentence.
- `linear-cli` unauthenticated → `status: "halted"`, emit
  `AUTO-HALTED: linear-cli unauthenticated — run linear-cli auth oauth, delete tmp/auto-state-<runKey>.json, and re-invoke /auto.`

## References

- [references/api-failures.md](references/api-failures.md) — transient API failures, the beyond-ceiling quota halt,
  heartbeat re-entry, stall recovery, human and `auto-rewake:` recovery prompts. Read when a call fails on
  infrastructure, a wakeup re-delivers mid-iteration, or a recovery prompt arrives (Step 4, Loop pacing, User stop).
- [references/fleet-gates.md](references/fleet-gates.md) — the deadline and headroom gates' mechanics: marker fields,
  the wind-down push's lines, cswap tails, fail-open, why parking beats dying. Read when the fleet marker exists
  (Step 2).
- [references/launch-prereqs.md](references/launch-prereqs.md) — model, effort, permission mode, the `loop-boundary`
  mod, recovering a halted deep session. Read when launching or recovering an unattended run (Authorization).
- [references/pacing.md](references/pacing.md) — the mechanics behind each wakeup figure: daemon retirement, lost
  wakeups, why `stop: true` ends the session, heartbeat arming. Read when choosing a delay (Loop pacing).
- [references/parks-and-declines.md](references/parks-and-declines.md) — routing a human-gated stop (`needs decision`
  vs `human`), why a refused step is a stall, durable vs transient `SKIPPED-BLOCKED`. Read before recording either
  (Step 4).
- [references/pick-edge-cases.md](references/pick-edge-cases.md) — epic-scoped drains and in-flight holds, the
  deploy-gated candidate's push-then-wait. Read when `/next` returns one of those (Step 2).
- [references/rationale.md](references/rationale.md) — why one issue per invocation, why always `wt`, how parallel
  sessions coordinate, the failure-policy defaults, the pick-time rules. Read when a rule looks arbitrary.
