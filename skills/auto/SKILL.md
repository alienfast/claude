---
name: auto
description: Autonomous Linear-backlog iteration — ships exactly ONE issue per invocation (preflight → /next specified → /full auto wt → record outcome), with a skip-and-circuit-breaker failure policy. Run continuously via `/loop /auto`; the loop ends itself on NO-CANDIDATES or AUTO-HALTED. Invoking /auto IS the run-scoped commit/push grant (standards/git.md). Use when the user says 'auto', 'work autonomously', 'work through the backlog', 'ship the next issue unattended', or invokes /auto (typically as /loop /auto).
---

# Auto (Autonomous Backlog Iteration)

Ships **exactly one Linear issue per invocation**, end-to-end and unattended: finish any in-flight work, pick the best next issue via `/next specified` (certified issues only), ship it via `/full auto wt`, record the outcome, emit a tagged final line. Continuous operation is `/loop /auto` — each loop iteration is one issue, and the loop ends itself when the backlog drains (`NO-CANDIDATES`) or the circuit breaker trips (`AUTO-HALTED`).

**Why one-issue-per-invocation instead of an internal "keep going" loop:** in-prose anti-stop scaffolding is the documented failure mode of autonomous macros (`/full` records it failing three times before its Stop hook existed). `/loop`'s wakeup machinery is the reliable recurrence mechanism; the `full-continue.sh` Stop hook already guards the intra-issue start→finish handoff. This skill adds no hooks and no scaffolding — it composes the trustworthy pieces.

**Why worktree mode is not optional:** in-place mode would leave the checkout on issue N's branch, and `/start`'s "already on a non-`main` branch → stay on it" rule would stack issue N+1 onto it — every subsequent issue cascading onto the first issue's branch. `wt` mode forks each issue from the source branch and `/finish merge` folds it back, so successive issues chain correctly (each fork sees the prior merges) with no stacking. `/auto` therefore ALWAYS dispatches `wt`.

## Authorization — read this first

**Invoking `/auto` (directly or via `/loop /auto`) is the explicit, run-scoped standing grant for commits and pushes.** `standards/git.md` forbids treating "commit" or "push" as a session-wide grant; `/auto` is the single named exception, because unattended issue-shipping is its entire documented contract. The grant covers exactly: the `/finish auto` commit+push of each issue this run ships. It does not cover force-pushes, history rewrites, or committing work that cannot be attributed to a Linear issue (see Preflight). Every shipped change is audited via the plan comment (`/start auto` Step 7) and completion comment (`/finish` Step 4) on its Linear issue.

## Unattended-run prerequisites

This skill cannot change permission modes. For a genuinely walk-away run:

- Run the session in a permissive mode (VSCode auto-accept edits, or `claude --permission-mode acceptEdits`); consider `/fewer-permission-prompts` first to seed a project allowlist.
- A permission prompt mid-run does not break anything — the run pauses until answered and `/loop` resumes normally. Expect occasional prompts on milestones that touch unusual commands (e.g., native-bridge/hardware work).
- Context growth across iterations is handled by the harness's automatic summarization. `/compact` and `/clear` are user commands — never attempt them; `tmp/auto-state.json` (Step 4) is the cross-iteration memory that survives summarization.

## Transient API failures are never failures

A Claude API error — overload (529), rate limit (429), or transient 5xx — from any tool call or delegated agent is **infrastructure, not an issue failure**. Never count it toward `consecutiveFailures`, never mark the issue failed, never emit `AUTO-HALTED` for it. Instead: retry with a short delay (respect a `Retry-After` header or stated reset time when one is given). If retries keep failing, fall back to a **15-minute wake-and-retry cadence** — under self-paced `/loop`, end the turn with a `ScheduleWakeup`-style ~900s delay and resume the same iteration on wake; under fixed-interval `/loop`, simply end the turn and let the next interval retry. A retry turn still ends with a tagged final line: `AUTO-CONTINUE: <ISSUE-ID> paused mid-issue (Claude API <error>); retrying in ~15m.` — or, when the failure hit before an issue was picked (Step 0/1/2, including `/next` itself), `AUTO-CONTINUE: paused pre-pick (Claude API <error>); retrying in ~15m.` The next iteration resumes where it left off — Step 1's preflight checks route back into the same issue (`/start`/`/full` are idempotent on it).

**Heartbeat re-entry mid-iteration.** Under self-paced `/loop`, a fallback wakeup may re-deliver this skill while the current iteration's delegated work is still in flight in this same session. That re-entry is a status check, not a new iteration: check on the outstanding work (ping stalled agents, verify state), re-arm the fallback, and continue waiting. **Do not run Step 0's re-anchor / `ExitWorktree`** — the in-flight iteration is still registered on its worktree, and releasing that registration would guard-block its outstanding `developer` writes (Step 0's `ExitWorktree` is only safe at a true iteration boundary, when no delegated work is live). Do not re-run preflight or dispatch /next, and do not treat the in-progress worktree as orphaned — Step 1's resumption path is for a new invocation after a died iteration, not for one still running here.

## Arguments

```text
/auto [pr] [TEAM[,TEAM...]]
```

Tokens are case-insensitive and order-insensitive.

- `pr` opens a PR per issue instead of merging (pass-through to `/full`). **Caveat:** in `pr` mode the source branch does not advance until PRs merge, so a dependent issue forks without its predecessor's code — use `pr` only when the queued issues are independent or a human is merging promptly.
- A team scope (`BF`, or a comma list `PL,BF`): restricts the whole run to those teams' certified backlogs — forwarded to Step 2's pick as `team:<KEYS>`. Without it, scope follows `/next`'s resolution (`$LINEAR_TEAM`, else every team in the workspace). **At most one** team token is accepted, and it MUST validate before it is trusted: uppercase it, then check every comma-part against the workspace's real team keys (`linear-cli teams list -o json`, case-insensitive). Any part that is not a real team key — `wt`, `auto`, `team`, a typo — is an unrecognized argument: emit the error below and STOP. An unattended run must never launch scoped to a nonexistent team (it would silently mark itself `drained` against an empty backlog). (`pr` is reserved for the PR flag, so `pr,BF` fails validation by design; a workspace whose team is literally keyed `PR` scopes via `$LINEAR_TEAM` instead.)

No issue ID is accepted — picking is `/next`'s job. Error on anything else — a second team-shaped token, an issue ID, or a token failing team validation: `Unrecognized argument 'X'. /auto accepts optional 'pr' and one optional team scope that must match a real team key (e.g. BF or PL,BF); worktree mode is always on.`

## Workflow (one iteration)

### Step 0: Entry gate — re-anchor and read the run state

**Re-anchor cwd to the main checkout first.** A prior iteration may have ended with cwd inside `.claude/worktrees/<id>` and the session still registered on that worktree (`/start wt` Step 0 enters via `EnterWorktree`, which switches cwd *and* registers it as the session's isolation root; only the merge path cd's back, and a shell `cd` never releases the registration). **Release it first:** call `ExitWorktree(action: "keep")` — a no-op when no registration is active, and it never removes a `path`-entered worktree — clearing a registration that may point at a worktree the prior iteration's `/finish merge` (or the reaper daemon) has since deleted, so the next `/start wt` `EnterWorktree` is a clean first entry rather than a switch away from a dangling root. Then resolve the main checkout (the first `worktree <path>` line of `git worktree list --porcelain`, unambiguous even with spaces in the path) and `cd` there before anything else. This skill's `tmp/auto-state.json` lives in the main checkout; write it via the shell (see the bgIsolation note below) — the shell bypasses the Write-tool guard, so it is safe whether or not a worktree is registered. (Reads are unaffected.) **Every read or write of `tmp/auto-state.json` — Step 0, Steps 1–2's terminal transitions, Step 4, and all Error Handling transitions — uses `<main-checkout>/tmp/auto-state.json`** (carry the resolved absolute path through the iteration); a state file touched inside a worktree would fragment the run state (resetting the breaker and skip lists, making halts non-sticky) and be deleted with the worktree.

**Background-job note (bgIsolation).** In a background session the harness's worktree-isolation guard refuses Write-tool edits outside the registered worktree — and `/start wt` Step 0 registers its worktree via `EnterWorktree`, so `<main-checkout>/tmp/auto-state.json` (which this skill REQUIRES to live in the main checkout) is outside it. That file is gitignored, run-scoped bookkeeping owned by this skill, not project code: write it via the shell — always, as Step 0's re-anchor prescribes (e.g. `printf '%s\n' '<json>' > <main-checkout>/tmp/auto-state.json`); the shell `printf` bypasses the Write-tool guard entirely, and unlike a Write-tool edit it never trips the read-before-Write requirement instead of relocating it into a worktree (fragments the run state) or setting `worktree.bgIsolation: none` (removes the guard for all code edits, not just this file — and `/start` Step 8 forbids it). Between issues, Step 0's re-anchor calls `ExitWorktree(action: "keep")` to release the prior iteration's registration before the next `/start wt` re-registers — so the next `EnterWorktree` is a clean first entry, never a switch away from an already-deleted worktree.

Read `tmp/auto-state.json` (see Step 4 for the shape). **One file = one run.** If it exists and `status` is `halted` or `drained`, do not proceed — re-emit the stored terminal condition using the `reason` field (every transition that sets a terminal `status` MUST also set `reason` to the one-line summary it emitted):

- `halted` → `AUTO-HALTED: run previously halted — <reason from state file>`
- `drained` → `NO-CANDIDATES: <reason from state file>`

The stored `reason` already ends with its next action (usually "delete tmp/auto-state.json…"), so append nothing. If a terminal state file predates the `reason` field (or it's empty), emit the tag with `reason unavailable — see the run's Linear comments and the shipped/skipped/failed lists in tmp/auto-state.json; delete it to start a fresh run.` — do not improvise a cause.

This makes the circuit breaker hold even under fixed-interval `/loop` (e.g., `/loop 15m /auto`), which re-invokes regardless of the previous iteration's tag. A human starts a new run by deleting the state file (its skip/fail exclusions are run-scoped and would otherwise wrongly suppress issues whose blockers have since been resolved). If the file is missing or unreadable/corrupt, recreate it empty with `status: "active"` and continue — worst case the breaker takes one extra failure to trip.

### Step 1: Preflight — finish in-flight work

Two checks, in order:

1. **Dirty main checkout.** Run `git status --short` and `git branch --show-current`. If dirty, attribute the work by **branch name only** — the branch must itself contain an issue ID (`[a-z]+-[0-9]+` segment). Do NOT use `detect-issue-id.sh`'s commit-subject fallback here: in this workflow every commit subject contains an issue ID, so the fallback would attribute *any* foreign WIP to whatever issue the last commit mentions and ship it. Additionally verify the resolved issue is `In Progress` and assigned to me.
   - Attributable and **not already in this run's `failed` list** → dispatch `Skill(skill: "finish", args: "auto <ISSUE-ID>")` — **no mode token**; `finish-detect-mode.sh` detects worktree-vs-standard from where the work actually lives. Treat its terminal tag as this iteration's outcome (Step 4) and do not also start a new issue.
   - Attributable but already in `failed` → the previous attempt to finish this same dirty tree failed and the tree is still dirty; retrying is a loop, not progress. Set `status: "halted"` and emit `AUTO-HALTED: dirty working tree for <ISSUE-ID> failed to finish and needs a human (see its Linear comment) — resolve, then delete tmp/auto-state.json and re-invoke /auto.` (Environment halt — does not touch `consecutiveFailures`.)
   - Not attributable (branch has no issue ID, or the issue isn't In Progress+mine) → set `status: "halted"` in the state file and emit `AUTO-HALTED: dirty working tree on <branch> not attributable to an in-progress Linear issue — inspect and commit/stash manually, then delete tmp/auto-state.json and re-invoke /auto.` (This is an environment halt — it does not touch `consecutiveFailures`.)
2. **Orphaned issue worktrees** (a prior `wt` iteration died mid-implementation — invisible to `git status` in the main checkout). Run `git worktree list`; for each `.claude/worktrees/<id>` whose issue is `In Progress` and assigned to me and not already in this run's `shipped`/`skipped`/`failed` lists (same exclusion as Step 2 — `shipped` matters here too: `DEFERRED-MERGE` and `SHIPPED-PR` deliberately leave an intact worktree with the issue In Progress, and "resuming" one would re-implement shipped work or race the queued merge), resume it: dispatch `Skill(skill: "full", args: "auto wt [pr] <ISSUE-ID>")` (idempotent resumption per `/full`'s edge cases) and treat its tag as this iteration's outcome. Resume at most one per iteration.

Clean tree and no resumable worktree → proceed to Step 2.

### Step 2: Pick — dispatch /next

Call `Skill(skill: "next", args: "specified")` — appending ` team:<KEYS>` when this run has a team scope from Arguments (e.g. `args: "specified team:BF"`). It ranks unblocked candidates restricted to issues carrying the `specified` label — only certified specs ship unattended (`standards/issue-spec.md`; `/prd` and `/spec` are the primary certification paths, plus `/reflect`'s auto-filed proposals and manual labeling). Without an explicit scope, team resolution follows `/next`: `$LINEAR_TEAM` when the project exports it, otherwise every team in the workspace — so one run drains all certified backlogs.

- **No candidates** → set `status: "drained"` in the state file and emit `NO-CANDIDATES: <team-scope> backlog drained of certified issues — <shipped>/<skipped>/<failed> this run. Run /spec to certify backlog issues (or /prd to seed new ones), then delete tmp/auto-state.json and re-invoke /auto.` (`<team-scope>` = the scope `/next` searched, e.g. `PL` or `PL+BF+MAR`.) Under `/loop` self-pacing this ends the loop — do not schedule another wakeup.
- **Candidates exist** → take the **top-ranked** one. Do not prompt the user to choose. Skip any candidate already in this run's `shipped`, `skipped`, or `failed` lists (`shipped` included: a `DEFERRED-MERGE` issue remains In Progress until the queue drains it, and re-picking it would race the queued merge). If every candidate is excluded that way, treat as no-candidates — including setting `status: "drained"` (the entry gate must hold under fixed-interval `/loop` here too) — but say so: `NO-CANDIDATES: all remaining candidates were already attempted this run (<shipped>/<skipped>/<failed>). Delete tmp/auto-state.json to re-attempt.`

### Step 3: Ship — dispatch /full auto wt

Call `Skill(skill: "full", args: "auto wt [pr] <ISSUE-ID>")`. `/full auto` runs `/start auto` (plan posted to Linear, no approval pause), `/quality-review auto`, and `/finish auto`, and terminates with exactly one lifecycle tag. Wait for that tag; do not narrate or race ahead.

### Step 4: Record outcome + emit the iteration tag

Maintain `tmp/auto-state.json` in the project. Shape:

```json
{
  "status": "active",
  "reason": "",
  "shipped": ["UI-3"],
  "skipped": ["UI-7"],
  "failed": ["UI-5"],
  "consecutiveFailures": 0
}
```

Read it (from the Step 0 pinned path), apply the outcome mapping below, write it back, then emit the tagged final line. The file — not conversation memory — is the source of truth across `/loop` iterations and context summarization. `status` transitions: `active` → `halted` (breaker or environment halt) / `drained` (no candidates); never back — a new run starts by deleting the file. Whichever step sets a terminal `status` also writes `reason` (the same one-line summary its tag carries) so Step 0's re-emission is verbatim, not improvised.

| Tag from Step 1/3 | Meaning | State update | Iteration tag |
| --- | --- | --- | --- |
| `RELEASED` / `SHIPPED-MERGE` / `SHIPPED-PR` / `DEFERRED-MERGE` | Shipped (DEFERRED-MERGE self-resolves via the merge queue) | append to `shipped`; `consecutiveFailures = 0` | `AUTO-CONTINUE` |
| `SKIPPED-BLOCKED` | Not startable without a human; nothing claimed | append to `skipped`; counter unchanged | `AUTO-CONTINUE` |
| `CANCELED` | Work already done/unneeded; issue closed by `/start` | append to `shipped` (the backlog shrank); `consecutiveFailures = 0` | `AUTO-CONTINUE` |
| `BLOCKED-ON-REVIEW` / `BLOCKED-ON-RECOVERY` / `ABANDONED` / `IN-PROGRESS` / unrecognized or missing tag | Failure — the issue needs a human | append to `failed`; `consecutiveFailures += 1`; **post a Linear comment** on the issue (via `~/.claude/scripts/linear-post.sh comment`) stating the terminal tag, the reason, and that `/auto` is moving on | `AUTO-CONTINUE` if `consecutiveFailures < 2`, else set `status: "halted"` and emit `AUTO-HALTED` |

Before applying the failure row, check the transient-API rule above — an iteration that died on API overload/rate-limit is retried, not recorded.

Iteration tags (per `standards/lifecycle-tags.md` — must be the LAST LLM-authored line, nothing after it):

- `AUTO-CONTINUE: <ISSUE-ID> <outcome> (<inherited tag>). <shipped>/<skipped>/<failed> this run; next /loop iteration proceeds.`
- `AUTO-CONTINUE: ... retrying in ~15m.` — the transient-API retry variants defined in "Transient API failures" above.
- `AUTO-HALTED: 2 consecutive failures (<ID> <tag>, <ID> <tag>) — likely systemic. See Linear comments on both issues; delete tmp/auto-state.json to start a fresh run.` Under `/loop`, ending on `AUTO-HALTED` or `NO-CANDIDATES` means: do NOT schedule another wakeup — the loop is over until a human intervenes (Step 0 enforces this even if a fixed-interval loop re-fires).

## Failure policy (why these defaults)

- **Skip, don't stall:** a single failed issue gets a Linear comment and preserved state (`/finish auto` never overrides its verdict gate; `/start auto` never reassigns/reopens); the loop tries the next candidate. One flaky issue must not end an overnight run. **One documented exception:** a failed issue that leaves the main checkout dirty (Step 1 check 1's `failed`-list branch) halts the run — there is no way to start the next candidate over someone's uncommitted failure without either shipping it or destroying it, and `/auto` does neither.
- **Circuit breaker at 2:** two *consecutive* failures usually mean something systemic (broken main, dead service, exhausted auth) — more unattended attempts just burn tokens and litter Linear. Any successful ship resets the counter; Step 0 makes the halt sticky across re-invocations.
- **Transient API errors are exempt:** infrastructure recovers on its own — retry on a delay (15-minute failsafe cadence), never count it, never halt for it.
- **Conservative everywhere:** every underlying `auto` default chooses abort/preserve over override/guess. The worst acceptable outcome of an unattended run is "nothing happened and Linear says why" — never "something wrong shipped."

## Error Handling

- `Skill(next)` errors (non-API: auth, missing dep) → set `status: "halted"`, emit `AUTO-HALTED: /next failed (<first error line>) — fix, delete tmp/auto-state.json, and re-invoke.` Do not count as an issue failure. (API overload/rate-limit → transient rule: retry instead.)
- `tmp/auto-state.json` unreadable/corrupt → recreate it empty (`status: "active"`) and note the reset in the iteration tag line's summary sentence.
- `linear-cli` unauthenticated → set `status: "halted"`, emit `AUTO-HALTED: linear-cli unauthenticated — run linear-cli auth oauth, delete tmp/auto-state.json, and re-invoke /auto.`
