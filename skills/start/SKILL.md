---
name: start
description: Start working on a Linear issue — check blockers, assign, move to In Progress, create branch, plan implementation, execute with checkpoint updates, review and triage findings. Autonomous mode via the `auto` token (skips plan approval; converts prompts to documented defaults; used by /auto). The `interactive` token (implies worktree mode) sets up the worktree and claims the issue, then hands off to the user without planning/implementing, so you can work in an isolated worktree without interfering with background `wt` agents. Use when the user says 'start issue', 'work on PL-XX', 'begin PL-XX', or invokes /start.
---

# Start Issue

Automates the full workflow for starting and implementing a Linear issue using the `linear-cli` CLI.

## Working Application Contract

This is the non-negotiable rule that governs everything in this workflow:

**We are modifying a WORKING application. If the application stops working, that is OUR failure. Period.**

There is no such thing as a "pre-existing" failure during implementation. The baseline check in Step 5 establishes a clean starting point. From that moment forward, every failure in `pnpm check` is caused by our changes and is our responsibility to fix. If we go from a working application to a non-working application, we broke it — no excuses, no deflection, no deferral.

Rules that flow from this contract:

1. **`pnpm check` must pass at all times.** Turborepo caching makes repeated runs cheap. Run it early, run it often.
2. **Failures are never "pre-existing."** The baseline passed. Any failure after that is ours.
3. **Failures are never "out of scope."** If our changes cause a check to fail, fixing it IS our scope.
4. **Failures are never deferred.** We do not proceed with a broken application. We stop and fix.
5. **The contract is in effect from Step 5's baseline through Step 9's review.** Steps 1–4 gather context and claim the issue (assign + In Progress), Step 6 runs plan mode (read-only by definition), Step 7 posts the plan, Step 10 summarizes — none modify code. Steps 5, 8, and 9 are the ones that can break the application; they run in-session and must keep `pnpm check` green. Step 8's `developer` / `debugger` / `quality-reviewer` / `architect` delegations must include this contract verbatim in the delegation prompt.

Violating this contract — by shipping broken code, by claiming failures were pre-existing, by deferring breakage to a follow-up ticket — is the single worst outcome of this workflow. A partially-implemented feature on a working application is infinitely better than a "complete" feature on a broken one.

## Auto Mode (`auto` token)

`/start auto <ISSUE-ID>` runs the same workflow with **no user prompts** — every decision point that would normally ask the user resolves to a documented default. It exists for the `/auto` loop (via `/full auto`), where nobody is watching. The conversions, all specified inline at the step where each prompt lives:

- Step 2 unresolved blocker → `SKIPPED-BLOCKED`, stop (nothing claimed)
- Step 3 owned-by-someone-else or terminal state → `SKIPPED-BLOCKED`, stop (never reassign, never reopen)
- Step 6 plan approval → skipped entirely; the plan is still composed and posted to Linear (Step 7), which becomes the audit record
- Step 8.5 CANCELED-vs-ABANDONED ambiguity → default `ABANDONED`
- Step 9 passes `auto` through to `/quality-review`

Auto mode changes **no other contract** — the Working Application Contract, checkpointing, delegation rules, and tagged final lines all apply unchanged.

## Workflow

### Step 0: Worktree Mode (`wt` in args, or an existing worktree for this issue)

**Argument parsing.** Tokens are case-insensitive and position-agnostic; the recognized tokens are `wt`, `auto`, and `interactive`. Parse in this order: **(1)** strip the recognized tokens; **(2)** verify exactly one non-token argument remains, otherwise error; **(3)** pass that remaining argument through `~/.claude/scripts/detect-issue-id.sh --validate-only --input <arg>` to normalize and validate (the script enforces `^[A-Z]+-[0-9]+$` and uppercases). Multiple IDs or duplicated tokens are errors — **and so is `auto` together with `interactive`** (mutually exclusive: `auto` is unattended, `interactive` is user-driven — reject the pair with a usage error before proceeding, per rule (b) below). **A present `interactive` token implies `wt`:** normalize it to set `wt` for the rest of Step 0 — the worktree gate below and the `IS_WT` derivation both then read `wt` as present — so `/start <ISSUE-ID> interactive` takes the same worktree path as `/start wt <ISSUE-ID> interactive`.

**`interactive` token — set up the worktree, then hand off to the user.** `/start wt <ISSUE-ID> interactive` runs Step 0 in full (worktree create/enter, identity stamp, baseline, claim + In Progress) and then **STOPS before Step 6** — no planning, no implementation, no review. It leaves you cwd'd inside the isolated worktree so your interactive edits land there and the main checkout stays clean (the whole point: not interfering with background `wt` agents' merges). Three rules govern it: **(a) `interactive` implies worktree mode** — it arms Step 0's worktree path even when `wt` is absent (interactive-in-place on the main checkout would reintroduce the very interference it exists to avoid), so `/start <ISSUE-ID> interactive` behaves as `/start wt <ISSUE-ID> interactive`; **(b) `interactive` + `auto` is an error** — `auto` means unattended (no user), `interactive` means the user drives, so the combination is contradictory: reject it with a usage error rather than picking one; **(c)** it is otherwise position-agnostic and case-insensitive like the other tokens. The halt itself lives in sub-step 4 below.

**`IS_WT`** is the session-level flag Step 8 gates its worktree-isolation mitigation on (item 1, and the READ-SCOPING/WRITE-PLACEMENT delegation blocks). It is true whenever Step 0 fires this session — either this invocation's args contained `wt` (just parsed above — including when `interactive` implied it), or Step 0's widened gate below detected an existing worktree for this issue (the resumption case, invoked as plain `/start <ISSUE-ID>` with no token) — OR, as a backstop, when Step 5's per-worktree short-circuit fires later this session (see Step 5) even if Step 0's worktree-existence check was somehow missed. **The rule governing every `IS_WT` derivation in this skill: a POSITIVE result from a `git config --worktree --get start.source-branch` probe is always a valid trigger — it can only over-arm the mitigation, which is safe (running the isolation checks in a session that turns out not to need them just costs one extra check) — but a NEGATIVE result must never be used to conclude `IS_WT` is false and disarm it, because an absent or wiped `start.source-branch` config does not prove "not a worktree" (a hijack can wipe it).** This is exactly why Step 5's own copy of this probe — a positive-result check — is a valid second trigger (see Step 5). What is unsafe, and never permitted, is deriving `IS_WT` from that probe run **unscoped against bare cwd** somewhere a broken `EnterWorktree` registration could make a negative result look like confirmation of "not a worktree" — see Step 8 item 1 for exactly where that bites.

If the args contain `wt` (**including when `interactive` implied it** — see Argument parsing above), **or a worktree already exists for this issue** (check `git worktree list --porcelain` for an entry at `.claude/worktrees/<issue-id-lowercased>` — the resumption case, invoked as plain `/start <ISSUE-ID>` with no token):

1. **Run the worktree setup script.** It encapsulates the procedural setup: argument validation, source-branch capture, per-worktree config enable, issue fetch (title for branch-name composition, plus state/assignee for the Step 3 claim decision), worktree create/attach/reuse with branch-collision detection, source-branch recording, a **tamper-evident identity stamp** (branch + baseline SHA + owner session, written to per-worktree git config AND immune sidecars — `$CLAUDE_JOB_DIR` plus a repo-level `.claude/worktree-identity/` fallback so a *different* session's `/finish` can still detect a hijacked worktree), the **session-start dirty baseline capture** of the main checkout (via `~/.claude/scripts/wt-baseline.sh capture` — re-run every invocation, including resumption reuse, so the baseline is always fresh for THIS session), and digest pre-fetch into the worktree's `tmp/`. The git-mutating create + stamp runs inside `start-wt-create.sh` **under a repo lock** (`with-repo-lock.py`, the same key `/finish merge` uses), so concurrent `/start wt` runs can no longer race the create and clobber each other's worktree branch/HEAD/config.

   **Before running it, load every deferred-tool schema this workflow needs in ONE `ToolSearch` call** — `select:EnterWorktree,EnterPlanMode,ExitPlanMode` (auto mode needs only `EnterWorktree`) — rather than separate loads here and at Step 6.

   ```bash
   ~/.claude/scripts/start-wt-setup.sh PL-13
   ```

   **Read the tool output carefully.** Stdout contains these `KEY=value` lines. Sub-steps 2–3 consume `WT_ABS`, `DIGEST_FILE`, `STATE`, `ASSIGNEE`, `BASELINE_FILE`, and `ISSUE_ID` directly; `BRANCH` and `SOURCE_BRANCH` aren't needed until later in the session (Step 8.5's cleanup commands, the `/finish` dispatch), but carry all eight forward regardless — the last three lines below are the only purely informational ones:

   ```text
   WT_ABS=<absolute worktree path>
   BRANCH=<the worktree branch name>
   SOURCE_BRANCH=<the branch the worktree forks from>
   ISSUE_ID=<normalized (uppercased) issue ID>
   STATE=<issue state name, e.g. Planned>
   ASSIGNEE=<assignee email, or empty if unassigned>
   BASELINE_FILE=<absolute path to the captured dirty baseline, or empty if capture failed>
   DIGEST_FILE=<absolute path to pre-fetched digest, or empty if fetch failed>
   BASELINE_SHA=<fork-point commit; the identity anchor /finish verifies>   # informational
   OWNER_SESSION=<owning session id, or empty>                              # informational
   IDENTITY_SIDECAR=<path of the immune identity sidecar, or empty>         # informational
   ```

   Stderr contains diagnostics (drift warnings, progress, errors). It may briefly print `[finish-queue] waiting for <repo> ...` while another session holds the repo lock — that is the serialization working, not a hang; wait for it. It may also print a `WARN:` advising you to park the main checkout off the shared source branch (`git checkout --detach`) when it sees the main checkout on the source branch with other worktrees already active — heed it for parallel `/full wt` runs (it keeps every merge on the contention-free ref-only path). **If the script's exit code is non-zero, stop.** Do not proceed to sub-step 2 — the worktree is in an indeterminate state and the locked helper has already cleaned up via its EXIT trap. Surface the script's stderr to the user.

   **Foot-gun warning.** Do not manually set `start.source-branch` at common (non-`--worktree`) scope. The Step 5 short-circuit treats any value as evidence of a `/start wt` worktree, so a stray manual config would silently bypass branch creation in a regular `/start` session. The setup script writes only at per-worktree scope.

2. **Enter the worktree with `EnterWorktree(path=<WT_ABS>)` — and, in the SAME message, `Read` the digest at `DIGEST_FILE`.** The two calls are independent (the digest path is already known from sub-step 1's output), so issue them as parallel tool calls in one message — this is Step 1's digest read, done a turn early. If `DIGEST_FILE=` came back empty, fall back to Step 1's generate-then-read after entering, as its own call.

   Read `WT_ABS` from sub-step 1's stdout and pass it as the tool's `path`. Call this **while cwd is still the main checkout** — i.e. right here, before any `cd`. The `path` form switches the session into the existing worktree **and** registers it as the session's harness-level isolation root. A shell `cd` alone would move only the Bash cwd; it does **not** register isolation, so in a **background session** the worktree-isolation guard blocks a `developer` subagent's Write-tool edits (the guard tracks the `EnterWorktree` registration, not the shell cwd). Registering here makes subagent writes land in the worktree with the guard **on** — no lever, no settings change. Because we enter from the main checkout at first entry, this is *not* the rejected "cd back to main, then `EnterWorktree`" recovery recipe and never trips the same-cwd refusal. `EnterWorktree` also switches cwd (persisting across subsequent Bash calls for Steps 1–10), so no separate `cd` is needed — sub-step 3's `start-wt-verify.sh` call confirms cwd as its first stage.

   If that confirmation fails (canonicalized `pwd -P` ≠ `realpath <WT_ABS>` — canonicalize both sides, since a symlinked path component otherwise makes a successful entry look like a failure), the `EnterWorktree` registration did not take — **STOP and surface** rather than continue. Steps 1–10 would otherwise run against the main checkout (wrong baseline SHA, wrong Step 5 branch short-circuit, wrong tree for every delegation), and a background session's `developer` writes would still hit the guard. Do **not** fall back to a bare shell `cd`: that would fix cwd but leave isolation unregistered — the original bug.

   **Session-start dirty baseline — captured by sub-step 1's setup script, fresh every session, never reused across sessions.** The script runs `~/.claude/scripts/wt-baseline.sh capture <WT_ABS> <issue-id-lowercased>` on every invocation (fresh create AND resumption reuse), overwriting any previous session's file — so `BASELINE_FILE=` in its output names a snapshot of the main checkout's already-dirty state taken *this session*, before any delegation can exist. **This baseline is the primary contamination-detection signal, not a report-only footnote** — Step 8 item 1 diffs the main checkout's current dirty state against it (`wt-baseline.sh diff`) after every delegation to compute exactly what changed in the main checkout *this session*, independent of anything a delegate reports. The baseline tells us what changed; it never tells us what is safe to destroy — recovery stays fully manual (Step 8 item 1, "On contamination"). The measurement mechanics (content-hash lines so a stray write onto an *already-dirty* path is still caught, `LC_ALL=C` collation pinning, worktree/merge-queue pathspec exclusions, fail-closed hashing) live in `wt-baseline.sh` — the script is authoritative; do not re-implement them inline.

   **Any skill that arms this mitigation — not only this invocation of `/start` — must ensure this baseline is fresh for ITS OWN session.** A standalone `/quality-review PL-13` run inside a worktree (a supported invocation with no `/start` this session) exercises the same Step 8 item 1 detection machinery; it must run `wt-baseline.sh capture` at the start of its own session, overwriting whatever was there — a stale baseline would silently misjudge everything dirtied between sessions as "already there."

   **One honest limitation:** this baseline is per-*session*, not per-repo-lifetime. If a *previous* session already left contamination behind in the main checkout before this session's baseline was taken, that pre-existing contamination is captured as "already there" (its hash matches) and will NOT be re-flagged by this session's delta unless its content changes again — only new dirt or new changes introduced by *this session's* delegations are detected. **A missing or unreadable baseline at Step 8 detection time is a fail-closed condition** — see Step 8 item 1.

3. **Run the verification script — Steps 2–5's actions in one call, with Step 6's exploration dispatched in the same message** (except with the `interactive` token, which dispatches no exploration — see the exceptions below). The digest (sub-step 2) and `STATE=`/`ASSIGNEE=` (sub-step 1) are already in hand, so make the decisions FIRST, before composing the call:

   - **Blockers (Step 2's rules):** check the digest's Blockers section. Any unresolved blocker → do NOT run this script; fall back to Step 2's prompt (interactive) or its auto-mode `SKIPPED-BLOCKED` exit.
   - **Availability (Step 3's rules):** owned-by-someone-else or terminal state → do NOT run this script; fall back to Step 3's prompts or auto-mode exits. Already In Progress and mine → run the script with `--no-claim` in place of `--claim` (idempotent resumption).

   On the happy path, run exactly this — substituting `<WT_ABS>`, `<BASELINE_FILE>` (from sub-step 1), and the issue ID, and giving the Bash call an explicit timeout ≥ 300000ms (`pnpm check` runs inside the script and can exceed the 120s default on a cold cache):

   ```bash
   ~/.claude/scripts/start-wt-verify.sh '<WT_ABS>' <ISSUE-ID> --claim --baseline-file '<BASELINE_FILE>'
   ```

   - **Claim flag:** happy-path claim → `--claim`. Idempotent resumption (already In Progress and mine, per the Availability bullet above) → `--no-claim`.
   - **`--baseline-file`:** pass it only when sub-step 1 emitted a non-empty `BASELINE_FILE=`. When sub-step 1's capture failed (`BASELINE_FILE=` came back empty), OMIT the flag entirely so the script re-captures on its own.

   **In the SAME message, dispatch Step 6's exploration agents** (see Step 6 for how many and how to focus them) — **except when the `interactive` token was given, in which case dispatch NO exploration at all** (per the exceptions below): the run halts at sub-step 4 before Step 6, so exploration would be pure waste with nothing to feed, and dispatching it contradicts interactive mode's no-planning contract. They are read-only and need only the digest and the worktree, both already in hand; the claim executes early in the script's run, seconds after dispatch, so Step 3's claim-before-research intent (broadcast ownership the moment work begins) is preserved. Do not wait for the script to return before exploring — a red baseline stops the workflow before any implementation regardless, and the exploration output is simply discarded in that case. When `IS_WT` is true, these are delegations like any other: every exploration prompt carries the READ-SCOPING block from Step 8's delegation format (Step 8's blockquote applies to EVERY delegation `/start` makes, in any step — not only Step 8's own), and the item-1 placement check (`wt-baseline.sh diff`) runs after the explorers return, before their findings are used.

   **Three exceptions to same-message dispatch:** when you must omit `--baseline-file` (sub-step 1's capture failed), do NOT dispatch exploration in the same message — run the script alone first (its re-capture restores the baseline invariant), then dispatch exploration in the next message. When resuming an issue whose approved plan is already posted (see **Resumption**, Step 8), skip the exploration dispatch entirely — that resumption path goes straight to Step 8 with no new exploration to feed; if that plan is later judged stale (see **Resumption**, Step 8), dispatch the exploration then — at Step 6, before `EnterPlanMode`. And when the `interactive` token was given, skip the exploration dispatch entirely — sub-step 4 halts the skill before Step 6 ever runs, so run `start-wt-verify.sh` alone (its cwd-confirm, dirty-baseline verify, claim, source-branch probe, and green `pnpm check` baseline are all interactive mode needs) and proceed to the halt with no exploration to consume.

   Failure handling by verdict (the first line of the script's stdout is the verdict — see its header docblock for the full contract):

   - `VERIFIED` → Steps 1–5 complete, the Working Application Contract is in effect; proceed to Step 6 (whose exploration is already running) — **unless the `interactive` token was given, in which case sub-step 4 halts the skill here instead of continuing to Step 6.**
   - `FAILED-CWD` → sub-step 2's STOP-and-surface. Auto mode: emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — EnterWorktree registration did not take (cwd mismatch); manual investigation required. No state change.` and stop.
   - `FAILED-BASELINE` → STOP, fail closed (same posture as Step 8 item 1, triggered earlier). Auto mode: emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — session-start dirty baseline could not be captured; manual investigation required. No state change.` and stop.
   - `FAILED-CLAIM` → the update command itself failing (auth expired, network, unknown state name) is distinct from Step 3's ordinary availability decisions (made BEFORE this script runs, per the bullets above) — STOP and surface; do not proceed unclaimed. Auto mode: emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — claim update failed (linear-cli error). No state change.` and stop.
   - `FAILED-SOURCE-BRANCH` → empty output is unexpected here (sub-step 1 recorded the value this session); treat as a possible hijack/corruption signal — STOP and surface; do NOT continue to implementation. Auto mode: emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — start.source-branch missing from worktree config (possible parallel-session interference); manual investigation required.` (By this point the claim has already run — or, on the `--no-claim` idempotent-resumption path, the issue was already claimed by a prior session — so this entry carries no "No state change." clause either way.)
   - `FAILED-CHECK` → Step 5's baseline-failure path (including its auto-mode 2-delegation bound).
   - **Any other output** — a `FAILED-USAGE` verdict (a malformed invocation, which should never happen if this step composed the command correctly), no verdict line at all, or empty stdout — is a FAILED check: fail closed, STOP (same posture as Step 8 item 1's rule — never treat unrecognized or missing output as success). Auto mode: emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — start-wt-verify.sh returned no recognizable verdict (<first output line, or 'empty stdout'>); fail closed, manual investigation required.` and stop. (This branch can fire before OR after the claim stage ran — or with the claim skipped entirely on the `--no-claim` resumption path — so this entry carries no "No state change." clause; on the `--claim` path Linear state is indeterminate until a human checks.)

4. **Interactive token — halt here; the user drives from now on.** If the `interactive` token was given (Step 0 header) and sub-step 3 returned `VERIFIED`, this is where Step 0 ends the skill. Do **NOT** proceed to any later step — not Step 1, and not Steps 6–10 (this includes Step 10: the `INTERACTIVE-READY` line below **is** this session's completion summary and its single lifecycle tag, so do not also run Step 10's Completion Summary — doing so would emit a second, contradictory tag, since Step 10 keys off a `/quality-review` verdict that never ran here and would wrongly map to `BLOCKED-ON-REVIEW`). Everything the setup needed is done — the worktree exists and is entered (cwd registered via `EnterWorktree`, so edits made through *this Claude session* land in the worktree, not the main checkout — but note `EnterWorktree` moves only the session's cwd, **not** the VS Code editor's file tree, which stays rooted on the main checkout; the halt therefore opens the worktree in its own editor window, see below), its identity is stamped, the session-start baseline is captured, the issue is claimed (In Progress, assigned to you), and the baseline `pnpm check` is green. The worktree is a first-class `/start wt` worktree — the reaper keeps it while unstarted-or-unmerged and `/finish` merges/removes it later exactly as for any other, so no special cleanup applies. Open the worktree in its own **new VS Code window** with the `code` CLI (best-effort — guard on `code` being present; never fail the halt if it is absent or errors; do this yourself, do NOT tell the user to run it), then emit the tag:

   ```bash
   command -v code >/dev/null 2>&1 && code -n "<WT_ABS>" || true   # <WT_ABS> from sub-step 1's stdout; -n opens a NEW window, so this session survives
   ```

   Then emit the tagged final line as the session's last output and stop (substitute `ISSUE_ID` and `BRANCH` from sub-step 1's stdout; the path is `.claude/worktrees/<issue-id-lowercased>`). The ` ```text ` fence below is illustrative — emit the tag **bare**, as the last non-empty line, with no fence around it (see `standards/lifecycle-tags.md`):

   ```text
   INTERACTIVE-READY: <ISSUE-ID> — worktree ready at .claude/worktrees/<issue-id-lowercased> (branch <BRANCH>), claimed In Progress, baseline green. Work here; run /finish <ISSUE-ID> merge when done (or /quality-review <ISSUE-ID> first).
   ```

   This is a genuine terminal state per `standards/lifecycle-tags.md` (`INTERACTIVE-READY`), not a `/checkpoint`-style `IN-PROGRESS` pause: `/start` has finished its job and there is no further `/start` work to resume — the user continues in the live session. The token changes ONLY what happens after a `VERIFIED` sub-step 3; every guard before it still fires (a blocker, an owned-by-someone-else issue, a terminal state, or a red baseline all route to their normal Step 2/Step 3/Step 5 handling and stop with their own tags, never reaching this halt). **Resumption composes for free:** re-running `/start <ISSUE-ID> interactive` later hits Step 0's widened worktree-exists gate, reuses the same worktree, re-enters it, re-baselines, and claims idempotently (`--no-claim`) — then halts here again. The rest of this sub-step (the continuation into planning/implementation/review below) applies only when `interactive` was NOT given.

   **Continue in this same session — no subagent.** The user is already in an isolated agent-view session; the worktree — now registered via `EnterWorktree` — provides the isolation. Do **not** additionally wrap `/start` itself in an isolation *subagent*: the `EnterWorktree` registration is session-level and keeps plan-mode prompts and `/quality-review` output visible to the user, whereas a subagent wrapper would hide them. Steps 1–5 were satisfied by sub-steps 2–3 (digest read; blockers checked; claim; branch short-circuit; baseline check); the remaining steps run unchanged:

   - Step 6 (`EnterPlanMode`) surfaces the approval UI to the user once exploration returns (skipped in auto mode — see Auto Mode above).
   - Step 8 delegates implementation to `developer` subagents (those are appropriate — they're scoped tasks, not whole-workflow dispatch).
   - Step 9 (`/quality-review`) runs with visible findings, fix loop, and deferred-items triage.

If neither condition holds, proceed to Step 1 as today (in-place on the current branch).

### Step 1: Gather Issue Context

**Worktree mode:** Step 0 sub-step 2 already read the pre-fetched digest, and sub-step 3's `start-wt-verify.sh` call folded Steps 2–5's actions in — if it returned `VERIFIED`, skip ahead to Step 6 (whose exploration is already running), **or, when the `interactive` token was given, stop at sub-step 4's halt instead of reaching this step at all.** Steps 1–5 below run as written in plain (in-place) mode, or when Step 0's happy path did not complete.

The issue digest is a markdown summary of the issue, parent chain, dependency graph, comments summary, and attachment URLs. Generate or read it:

```bash
mkdir -p tmp
DIGEST=tmp/linear-context-pl-13.md   # use the actual lowercased issue ID
# In `/start wt` mode, Step 0's setup script already cached the digest here.
# In plain `/start` mode (or if the pre-fetch failed), generate it now.
if [ -s "$DIGEST" ]; then
  cat "$DIGEST"
else
  ~/.claude/scripts/linear-context.sh PL-13 | tee "$DIGEST"
fi
```

Read the digest carefully. Note:

- **Description** — requirement checkboxes (`- [ ]` items), success criteria checkboxes, "Nice to Have" vs "Must Have" distinctions
- **Parent chain** — each ancestor's title and state; higher-level issues often contain architectural decisions and scope boundaries
- **Dependencies** — blockers with states; comments summary
- **Attachments** — `uploads.linear.app` URLs to inspect (download separately when needed)

### Step 2: Check for Blockers

The digest from Step 1 includes a **Blockers (issues blocking this)** section listing each blocker's state. Decide whether each blocker is resolved by checking its state against the team's terminal states (typically `Done`, `Canceled`, `Ready For Release`, plus any team-custom terminal states like `Released`, `Shipped`, `Won't Do`). When in doubt, treat the state as unresolved — false positives are recoverable; silently proceeding past a real blocker is not.

For each unresolved blocker:

- List it with its state
- Ask the user whether to proceed anyway or address the blocker first
- Do not silently skip

**Auto mode:** do not ask. Emit the tagged final line `SKIPPED-BLOCKED: <ISSUE-ID> — blocked by <BLOCKER-ID> (<state>)` and stop. Nothing has been claimed or modified; `/auto` treats this as a skip (not a failure) and tries the next candidate. `/next` pre-filters blocked issues, so this fires only when the digest reveals a blocker `/next`'s ranking missed.

### Step 3: Claim the Issue — Assign & Move to In Progress

**Claim before you research.** This is the first action after availability is verified, and it happens **before** any deepen-context, codebase exploration, or implementation. Assigning + moving to In Progress immediately broadcasts to the team that the issue is owned; researching first leaves it looking unclaimed while work is already underway — a bad signal in a multi-person workspace. (Worktree mode: Step 0 sub-step 3 executes this claim early in its `start-wt-verify.sh` call. On the non-interactive happy path that call is dispatched in the same message as Step 6's exploration agents — the documented exception to strict sequencing; with the `interactive` token the script is dispatched alone, per sub-step 3's third dispatch exception, but the claim still lands early in its run. Either way the claim lands seconds after dispatch, and the availability check still precedes it.)

Verify availability from the Step 1 digest's `**State:**` and `**Assignee:**` line (already fetched — no extra call):

- Already `In Progress` assigned to **someone else** → warn and ask whether to reassign (Error Handling) before claiming. **Auto mode:** never reassign — emit `SKIPPED-BLOCKED: <ISSUE-ID> — In Progress, assigned to <assignee>` and stop.
- Already `Done` / `Ready For Release` / other terminal state → warn and ask whether to reopen (Error Handling) before claiming. **Auto mode:** never reopen — emit `SKIPPED-BLOCKED: <ISSUE-ID> — already <state>` and stop.
- Already `In Progress` assigned to **me** → idempotent resumption; the issue is already claimed. Skip the update and continue (matches the Step 8 resumption note). Applies in auto mode too.

Otherwise, claim it immediately:

```bash
linear-cli issues update PL-13 --assignee me --state "In Progress"
```

Only after the issue is claimed do you proceed to Step 4 (deepen context, only if needed) and the rest of the workflow.

### Step 4: Deepen Context (only as needed)

The digest covers most context. Reach for these only when its summary is insufficient for the work at hand:

**Full standalone comment bodies** (the digest shows *anchored* comments in full, but truncates *standalone* comments to their first line):

```bash
linear-cli comments list PL-13
```

**Project description** (digest does not include the project body; the digest's `**Project ID:**` line is the project UUID). Use the project ID directly from the Step 1 digest:

```bash
# Read the **Project ID:** value from the digest you printed in Step 1.
# If the digest had no Project ID line, the issue has no project — skip.
linear-cli projects get <project-uuid-from-digest>
```

**Inline images** — `uploads.linear.app` URLs from the digest's Attachments section require authentication; do NOT use `WebFetch` or `curl`:

```bash
linear-cli uploads fetch "https://uploads.linear.app/..." -f tmp/linear-img.png
```

Then `Read` the downloaded path (`tmp/linear-img.png`) to view the image.

### Step 5: Ensure Correct Git Branch

**Worktree mode short-circuit.** If Step 0 ran this session and its sub-step 3 `start-wt-verify.sh` call returned `VERIFIED`, Step 5 is complete; proceed to Step 6 (or, when the `interactive` token was given, Step 0 sub-step 4 already halted the skill — this step is never reached). This whole step applies whenever that isn't the case — Step 0 did not run this session, or it ran but its `start-wt-verify.sh` call did not execute (a blocker or availability issue routed to Step 2/Step 3's fallback prompts instead). Check at per-worktree scope (`--worktree`) so a manual `start.source-branch` at common scope can't false-trigger this from outside a `/start wt` worktree. If `git config --worktree --get start.source-branch` returns a value, the branch is already correct and the source branch is recorded for `/finish`. Skip the branch-selection logic below and jump directly to the **Baseline check** at the end of this step. **This is also the second `IS_WT` trigger** (see Step 0): when this probe returns a value, `IS_WT` is true for the rest of the session even though this invocation's args never carried `wt` — the mechanism that keeps Step 8's isolation mitigation armed on a resumed `/start <ISSUE-ID>`. This is a POSITIVE result arming `IS_WT`, always valid per Step 0's `IS_WT` rule — it never disarms anything.

**If a non-happy-path decision at Step 2/Step 3 was overridden by the user** (proceed-anyway on a blocker, reassign, or reopen a terminal-state issue), return to Step 0 sub-step 3 and run `start-wt-verify.sh` then (with `--claim` or `--no-claim` per the availability outcome) — do not fall through to the branch-selection logic below.

**If this probe is what arms `IS_WT` this session — Step 0's own worktree-existence gate did not fire** (e.g., cwd started this session already inside a leftover worktree directory such as `.claude/worktrees/pl-99/`, and the user ran a plain `/start <ISSUE-ID>`) **— no baseline has been captured yet.** Do not let Step 8's mitigation arm with nothing to diff against: a bare `IS_WT`-true with a missing baseline fails Step 8 item 1 closed on the very first delegation, and the session can never do any work. Before doing anything else, capture it now. Unlike Step 0's `start-wt-verify.sh` call (sub-step 3) — where `pwd -P` is safe because its first stage cross-checks it against the setup script's own `WT_ABS` output — this path has no such cross-check: cwd may be a **subdirectory** of the worktree (e.g. `.claude/worktrees/pl-99/src`) rather than its root, so derive `WT_ABS` with the canonical `git rev-parse --show-toplevel` form instead of `pwd -P`; using `pwd -P` here would silently substitute the wrong root into every later delegation's READ-SCOPING:

```bash
WT_ABS="$(git rev-parse --show-toplevel)"
~/.claude/scripts/wt-baseline.sh capture "$WT_ABS" <issue-id-lowercased>
```

The script derives and guards `MAIN_CHECKOUT` itself and fails closed (`FAILED: ...`, exit 1) on any precondition it can't prove — including `WT_ABS == MAIN_CHECKOUT`, which here means isolation was never registered. Continue below only on `CAPTURED <file>`; on `FAILED` — **STOP and surface**.

```bash
# Probe only — interpret the printed value, not the exit code. `|| true` is
# unnecessary here (unlike the capture-assignment sites in /finish) because
# this isn't being captured into a variable; a non-zero exit from the lookup
# is fine for the orchestrator to read as "no value set".
git config --worktree --get start.source-branch 2>/dev/null
```

```bash
git branch --show-current
```

- **If already on a non-`main` branch**: stay on it and skip to Step 6. **Do NOT create a new branch** — not even when the current branch looks wrong for this issue (unrelated name, far ahead of `main`, or you'd prefer a "cleaner" dedicated branch). In a shared in-place checkout, `git checkout -b` moves the shared working tree's HEAD and can drag or strand a concurrent session's uncommitted work (see standards/git.md, "Branch operations mutate the SHARED working tree — never reach for them unasked"). If the branch genuinely seems wrong for this issue, STOP and ASK the user which branch to use — never decide unilaterally.
- **If on `main`**: create or switch to a feature branch:

```bash
# Check for existing branch
git branch --list "*pl-13*"

# If found, switch to it
git checkout <existing-branch>

# If not found, get GitHub username and create branch
gh api user --jq .login
git checkout -b <username>/pl-13-short-kebab-title
```

**Branch naming rules:**

- Prefix with your GitHub username (from `gh api user --jq .login`)
- Issue key in lowercase (e.g., `pl-13`)
- Kebab-case title, truncated to keep the branch name reasonable

**Baseline check — THIS ESTABLISHES THE CONTRACT.** Run `pnpm check` to prove the application works before we touch anything:

```bash
pnpm check
```

**Dispatch Step 6's exploration agents in the SAME message as this Bash call** (see Step 6 for how many and how to focus them) — they are read-only, the digest is already in hand, and a red baseline stops the workflow before any implementation regardless (the exploration output is simply discarded in that case). Waiting for the check before exploring serializes the two longest pre-plan waits for no benefit.

- If it **passes**: the Working Application Contract is now in effect. The application works. From this moment forward, any failure in `pnpm check` is caused by our implementation and is our responsibility to fix. No exceptions.
- If it **fails**: STOP. Do NOT proceed with planning. The application must be working before we begin. Investigate and fix the failures first — delegate to `developer` or `debugger` as needed (when `IS_WT` is true: these fix delegations carry the same READ-SCOPING/WRITE-PLACEMENT blocks and item-1 placement check as any other Step 8 delegation — see Step 8's blockquote). Re-run until the baseline is clean. The contract cannot be established on a broken baseline. **Auto mode:** bound this to **2** fix delegations — a broken baseline in an unattended run is pre-existing, likely systemic breakage, not this issue's scope. If still red, post a Linear comment (baseline failure, first failing output lines), return the issue to availability per Step 8.5's ABANDONED mechanics, and emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — baseline pnpm check failing before any implementation; likely systemic. No changes made.` (`/auto` counts the failure; two such in a row trip its breaker — the correct response to a broken main.)

### Step 6: Enter Plan Mode

**Exploration starts BEFORE plan mode — dispatched in the same message as the baseline `pnpm check`** (Step 0 sub-step 3 in worktree mode; Step 5's baseline check in-place), so the two longest pre-plan waits overlap instead of serializing. The agents are read-only (`Explore` type) and need only the digest, already in hand. In worktree mode these agents get READ-SCOPING in their prompts and the Step 8 item-1 placement check after they return, like every other delegation. Scale the fan-out to the issue, splitting by AREA rather than by question:

- **Narrow, well-located change** (one component, one file cluster): ONE agent — a fan-out would just re-find the same files.
- **Multi-area issue** (e.g. component + theme + i18n + stories, or API + UI + tests): **2–3 focused agents in a single message**, each named a specific area and concrete starting points (paths, symbols, conventions to map). Wall-clock becomes the slowest agent instead of one agent's serial sweep; overlap in findings is fine. More than 3 buys little — synthesis cost grows faster than coverage.

If exploration was not pre-dispatched (a non-happy-path re-entry, a plain-mode flow that skipped the note in Step 5, or a worktree resumption whose posted-but-stale plan suppressed sub-step 3's dispatch), dispatch it now — do not begin reading exploration targets yourself.

**Auto mode: skip the plan-mode tools entirely.** There is no user present to approve, so do NOT call `EnterPlanMode`/`ExitPlanMode` (an unanswered approval prompt would stall the loop). Do the same planning work — items 1–4 of the list below — compose the plan in the Step 7 comment format, and proceed **directly to Step 7**: the plan posted to Linear is the audit record a human reviews after the fact. Everything below this paragraph is interactive mode only.

**Call the `EnterPlanMode` tool once the exploration results are back** to transition into plan mode. Do not write the plan inline in chat — plan mode has a dedicated tool flow that surfaces an approval UI (in VSCode: a side pane that supports annotation), and the inline-text path bypasses it.

While in plan mode:

1. Use the issue description, checkboxes, and parent context as requirements
2. Synthesize the exploration results into relevant files, patterns, and dependencies — dispatch a follow-up `Explore` only for genuine gaps
3. Design a step-by-step implementation plan
4. Identify which tasks are independent (parallelizable) vs dependent (sequential)
5. Write the plan to the plan file specified in the plan-mode system message

**When the plan is complete, call the `ExitPlanMode` tool.** This is what requests user approval and surfaces the annotation pane. If the user annotates or pushes back, incorporate the feedback, update the plan file, and call `ExitPlanMode` again — repeat until approved. Do NOT use `AskUserQuestion` to ask "is this plan okay?" — `ExitPlanMode` is the approval mechanism.

Do not start implementation until the user approves the plan via `ExitPlanMode`. After approval, proceed **immediately** to Step 7 — do not read files, grep, or do any implementation research until the plan is posted to Linear.

### Step 7: Post Approved Plan to Linear

**This step MUST complete before any implementation work begins — no exceptions.** No file reads, no grep, no dependency research. Post first, then stop.

Record the approved plan as a comment on the issue before starting work. This creates a permanent record so that if the session is interrupted, anyone (including a future session) can reconstruct intent from Linear.

1. Use the `Write` tool to save the plan as a structured comment to `tmp/linear-comment-<issue-id-lowercased>.md` (e.g., `tmp/linear-comment-pl-13.md`):

```markdown
## Implementation Plan

_Approved before implementation started._

### Approach
[1–3 sentence summary of the overall strategy]

### Steps
1. [Step — what will be done and why]
2. ...

### Key Files
- [File paths identified during planning]
```

1. Run:

```bash
~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md
```

### Step 8: Implement via Delegation

**Your role is orchestrator only.** Do not read source files, write code, run grep, or make edits yourself. Every implementation action must be delegated to a subagent. You only:

- Dispatch tasks to subagents (via the Agent tool)
- Verify results by running `pnpm check`
- Update Linear (checkboxes, comments)
- Decide what to delegate next based on results

If you catch yourself reading a source file or editing code, stop — delegate it instead.

**Available agents:**

- `developer` — Implements code, writes tests, fixes bugs
- `quality-reviewer` — Reviews for security, performance, best practices
- `debugger` — Investigates errors, analyzes root causes
- `architect` — Designs solutions when implementation reveals architectural questions

**Parallel execution is the default, not the exception.** If two tasks don't depend on each other's output, launch them simultaneously in a single message with multiple Agent calls. This applies to implementation tasks, fix tasks, and review tasks equally. Sequential execution requires justification (e.g., task B needs task A's output). Refer to [Agent Coordination Standards](~/.claude/standards/agent-coordination.md) for the parallel vs sequential decision matrix.

**Pre-delegation baseline.** Captured once, every session — by Step 0 sub-step 1's setup script (verified — or re-captured on sub-step 1 failure — in sub-step 3), or by Step 5's backstop when cwd began the session inside another issue's worktree — never here. It is the primary contamination-detection signal: item 1 below diffs the main checkout's current dirty state against it (`wt-baseline.sh diff` — content hashes, not just which paths are dirty, so a stray write landing on top of an already-dirty path is caught too) after every delegation. `~/.claude/scripts/wt-baseline.sh` is authoritative for the snapshot mechanics.

**Derive and carry `WT_ABS` and `MAIN_CHECKOUT` before composing any delegation.** The READ-SCOPING/WRITE-PLACEMENT template below substitutes `<WT_ABS>` and `<MAIN_CHECKOUT>` into the very first delegation prompt this step composes — both values must be known before that composition, not derived lazily inside "After each delegation completes" (by then the first prompt would already have had nothing to substitute). Step 0 sub-step 1 emitted `WT_ABS=` on stdout (and `wt-baseline.sh capture` printed `MAIN_CHECKOUT=` on stderr), and those values are carried in the orchestrator's own context (for `<WT_ABS>`/`<MAIN_CHECKOUT>` prompt substitution) — not in shell state, which never survives across separate Bash tool calls. So re-derive them canonically in a fresh, self-contained bash block before composing the first delegation — the same derivation "After each delegation completes" item 1 uses:

```bash
WT_ABS="$(git rev-parse --show-toplevel)"
MAIN_CHECKOUT="$(dirname "$(git -C "$WT_ABS" rev-parse --path-format=absolute --git-common-dir)")"

# Hard precondition guard — see Step 8 item 1 for the full rationale: `git -C ""` is a documented
# no-op (leaves cwd unchanged, exits 0), so an empty/wrong path here would silently substitute the
# wrong tree into every delegation's READ-SCOPING instead of failing loudly.
[ -n "$WT_ABS" ] && [ -d "$WT_ABS" ] || { echo "FAILED: WT_ABS unset or not a directory" >&2; exit 1; }
[ -n "$MAIN_CHECKOUT" ] && [ -d "$MAIN_CHECKOUT" ] || { echo "FAILED: MAIN_CHECKOUT unset or not a directory" >&2; exit 1; }
[ "$WT_ABS" != "$MAIN_CHECKOUT" ] || { echo "FAILED: WT_ABS == MAIN_CHECKOUT (isolation not registered)" >&2; exit 1; }
```

**Delegation format:**

Every delegation MUST include the Working Application Contract. Subagents do not get to claim ignorance of it.

When `IS_WT` is true, split the isolation instructions by what the delegation actually does. The READ-SCOPING block below is required on **every** delegation this skill dispatches, regardless of agent type — the four agent types named below (`developer`, `debugger`, `quality-reviewer`, `architect`) are a floor, not the set; a delegation to `Explore`, `general-purpose`, or any other type still gets it, since even a read-only search can leak another session's uncommitted file content into its output. The WRITE-PLACEMENT block (self-check plus changed-path report) is required only for delegations that can write — `developer` and `debugger` here — since `quality-reviewer` and `architect` are expected to change nothing and a write-placement check in their prompt would be dead prose. Omit both blocks entirely when `IS_WT` is false.

```md
Task for [agent]: [Specific, focused task]
Context: [Why this task matters, relevant issue context]
Files: [Exact paths and lines]

WORKING APPLICATION CONTRACT: We are modifying a working application. The baseline `pnpm check` passed before this work began. If your changes cause `pnpm check` to fail, that is your failure — not a pre-existing issue, not out of scope, not someone else's problem. You must leave the application in a working state. Run `pnpm check` before reporting your task as complete. If it fails, fix it.

READ-SCOPING:
Your working tree is <WT_ABS>. Run `pwd` first and confirm you are there — if it is not <WT_ABS>, STOP and report the actual cwd; do not `cd`, do not proceed.
Do NOT read, edit, or write anything under <MAIN_CHECKOUT> — it holds other sessions' uncommitted work. The only exception is the read-only `git -C <MAIN_CHECKOUT> status --porcelain` probes in WRITE-PLACEMENT below.
The worktree is nested UNDER the main checkout, so a bare relative path can resolve in BOTH trees: use absolute paths rooted at <WT_ABS> for every Read/Edit/Write/Glob/Grep.

WRITE-PLACEMENT:
1. Build your changed-path list from your OWN RECORD of the Edit/Write calls you made this task — the files you intended to change — never from `git status` output. One bare repo-relative path per line. An empty list is legitimate ONLY if you made no Edit/Write calls at all.
2. For each path in that list, probe both trees, one path at a time — non-empty output means that path is dirty there, empty means it is not, and that is ALL the output means; do not parse it, strip status codes from it, or otherwise interpret its content:
   `git -C <WT_ABS> status --porcelain --untracked-files=all -- <path>`
   `git -C <MAIN_CHECKOUT> status --porcelain --untracked-files=all -- <path>`
3. **You report; you do not decide.** Do NOT stop your task, do NOT treat a non-empty <MAIN_CHECKOUT> probe as your own failure, and do NOT attempt any recovery (no `git apply`, no `git restore`, no further writes to either tree) no matter what the probes show. You have no way to tell your own stray write apart from another engineer's pre-existing dirt at the same path — only the orchestrator's Step 0 baseline can — so guessing would be worse than saying nothing. If a probe command itself fails to run (a non-zero exit — not merely empty output), report that failure verbatim as part of your probe results; it does not change anything else in this report.
4. If a path's <WT_ABS> probe is empty (your edit is missing from the worktree), say so explicitly and prominently — this is the one signal the orchestrator's own check can't get any other way (it only watches <MAIN_CHECKOUT>, per Step 8 item 1). If a path's probe is empty in BOTH trees, it's a no-op (reverted, a byte-identical edit, or never actually written) — say so in your report; it is not a failure.
In your final message, report your `pwd` output (per READ-SCOPING above), your path list from step 1 verbatim, and each path's two probe results (present/absent in each tree), plus any probe-command failure from step 3. The orchestrator holds the Step 0 baseline and independently detects contamination via a delta on the main checkout (Step 8 item 1) — this report is corroboration for that check, not a substitute for it, whether or not it is present, complete, or bare repo-relative.

Requirements:
- [Specific requirement 1]
- [Specific requirement 2]
- Use dedicated tools: Read (not cat/head/tail), Glob (not find/ls), Grep (not grep/rg). Never use cat, ls, find, grep, or rg via Bash.
- Do NOT commit, push, or open PRs — even if your session/harness defaults say shipping is part of the task. The orchestrating /start→/finish workflow owns commit, push, and PR creation; shipping happens only at /finish after the review gate.
- Run `pnpm check` before reporting completion. If it fails, fix the failures. Do not report success with a failing check.
Acceptance: [How to verify success — MUST include "pnpm check passes"]
```

> **When `IS_WT` is true, the READ-SCOPING/WRITE-PLACEMENT blocks and the item-1 placement check below apply to EVERY delegation `/start` makes, in any step — not only Step 8's.** That includes Step 5's auto-mode baseline-repair fix delegations, which run before this step and would otherwise carry no isolation instructions and get no placement check.
>
> **The `EnterWorktree` registration is best-effort, not a guarantee.** This applies to every `IS_WT` session, in either foreground or background — the bind failure is not a background-only hazard. Step 0 entered the worktree with `EnterWorktree(path=<WT_ABS>)`, which registers it as the session's isolation root and is *meant* to bind every subagent's Write tool to that root. It can fail to bind some of them, silently. In BF-380, three parallel `developer` delegates ran under one `wt` session: the registration bound only one — the other two wrote into the main checkout, unblocked, with no error, while **both reported success**. Do not treat the registration as sufficient on its own: every delegation carries READ-SCOPING (and `developer`/`debugger` delegations carry WRITE-PLACEMENT too, per the paragraph above), naming the absolute worktree root (`<WT_ABS>`) and forbidding the main checkout (`<MAIN_CHECKOUT>`) by name. And **a delegate's success report is not evidence its writes landed in the right tree** — verify placement per "After each delegation completes" item 1 below, every time. That check is delegate-independent — a content-hash delta of the main checkout's dirty state against the Step 0 baseline — so it catches this even when a delegate reports nothing at all, or reports absolute paths instead of the required bare repo-relative ones.
>
> None of this loosens the existing guard: a delegate's Write being *blocked* is still a **hard stop, not a license to weaken isolation** — do **not** set `worktree.bgIsolation: "none"`, do **not** edit `settings.json` / `settings.local.json` to change isolation (the auto-mode self-modification classifier is right to block that), and — above all — do **not** take over the implementation yourself. The orchestrator-only rule at the top of this step is absolute and is **never** suspended by a delegation-mechanics failure. If a delegate reports writes are blocked: re-confirm Step 0's `EnterWorktree` registration succeeded (cwd is the worktree; it was entered from the main checkout, not via a shell `cd` — Step 0 sub-step 2); if writes are still blocked, **STOP**. Compose the failure detail — which delegation, what it reported, the registration re-confirmation result.
>
> - **Interactive mode:** surface all of the above in chat before the tagged line.
> - **Auto mode:** write it to a Linear comment first, the same mechanism as the contamination path below — save the body with the `Write` tool to `tmp/blocked-write-comment-<issue-id-lowercased>.md`, then run `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/blocked-write-comment-<issue-id-lowercased>.md`. Without this comment, auto mode's tagged line would be the ONLY durable record of what happened — posting first gives a human something to act on beyond a single line.
>
> Both modes then emit the tagged line and stop: `BLOCKED-ON-REVIEW: <ISSUE-ID> — delegate writes blocked by the worktree isolation guard; manual investigation required.` A stopped session must never end with no tag (`standards/lifecycle-tags.md`, "every session ends with exactly one").

**After each delegation completes:**

1. **Verify placement — run after EVERY delegation, gated on `IS_WT` alone, never on agent type.** Do not skip this for `quality-reviewer`/`architect` delegations just because their prompt carries no WRITE-PLACEMENT block — that scoping (the "Delegation format" intro above, "split the isolation instructions by what the delegation actually does") is a decision about what goes in the *prompt*, not about what the orchestrator itself verifies. Every agent type is provisioned with Write/Edit tools; any of them — including a reviewer that "helpfully" applies a one-line fix under a mis-bound registration — can write into the main checkout, and this check costs one `git status`-equivalent pass regardless of what the delegate reports or doesn't report. Gate purely on `IS_WT` (defined in Step 0; also armed by Step 5's short-circuit, which as of the fix above always pairs it with a baseline). If `IS_WT` is false, skip this item entirely: there is no separate main checkout, and running this check anyway would misread the delegate's own legitimate diff as contamination (a false `BLOCKED-ON-REVIEW` halt in auto mode).

   Do not derive `IS_WT` here by running `git config --worktree --get start.source-branch` against cwd and treating a NEGATIVE result as proof `IS_WT` is false — if Step 0's `EnterWorktree` registration silently failed and cwd is still the main checkout, that cwd-scoped probe reads the *main* checkout's config, finds nothing, and concludes "plain `/start`" — skipping this entire check exactly when it matters most. Per Step 0's `IS_WT` rule, a negative probe result must never disarm; a positive result, from anywhere, only ever arms (safe). `git -C "$WT_ABS" config --worktree --get start.source-branch`, explicitly scoped to a known worktree root, is safe from anywhere within `/start`'s own `IS_WT` derivation. **This is NOT how `/quality-review` determines it's in a worktree, and must not become that.** `/quality-review`'s own gate is `WT_ABS != MAIN_CHECKOUT` — necessary and sufficient on its own — precisely because a wiped `start.source-branch` is a documented hijack scenario the config probe cannot see through; requiring the config probe there would make that hijack undetectable. Step 5's own copy of this probe runs the cwd-scoped form too and is unaffected by any of this: at the point Step 5 runs it, cwd genuinely IS the worktree by construction (Step 5 short-circuits before any branch-switching), so a positive result there is trustworthy and is exactly the second `IS_WT` trigger from Step 0 — it is a positive-arms case, not the unscoped-negative-disarms case this paragraph warns against.

   **The check is one self-contained call to `~/.claude/scripts/wt-baseline.sh diff`** — the script derives and guards `MAIN_CHECKOUT` itself (including the `git -C ""`-is-a-no-op hazard and the space-in-path `awk` truncation hazard that older inline versions of this check had to defend against in prose), computes the current dirty map with the same content-hash mechanics as the capture, and classifies the delta. Nothing is "carried" into it from Step 0 or Step 5 — only the worktree root and the issue token are passed:

   ```bash
   WT_ABS="$(git rev-parse --show-toplevel)"
   ~/.claude/scripts/wt-baseline.sh diff "$WT_ABS" <issue-id-lowercased>   # or `no-issue` when no issue ID was resolved — see /quality-review
   ```

   **Branch on the FIRST line of stdout — never on empty output** (both a broken redirect and a broken `comm` print only to stderr, indistinguishable from "clean" if you only look at stdout; the script's verdict line exists precisely so there is always something on stdout to branch on). A green `pnpm check` is not evidence either — a worktree missing a delegate's changes still type-checks.

   - **`CLEAN`** (exit 0) → nothing changed in the main checkout this delegation. Continue.
   - **`CONTAMINATED`** (exit 2) → one classified line per path follows; go to "On contamination" below with those paths:
     - `NEW <path>` — clean at baseline, dirty now.
     - `CHANGED-IN-PLACE <path>` — already dirty at baseline, content hash changed since (e.g. an already-dirty file a delegate appended to; caught because the baseline stores content hashes, not bare path membership).
     - `VANISHED <path>` — dirty at baseline, gone from the current state — the most dangerous direction: a delegate may have overwritten another session's uncommitted work with HEAD content, and that work may already be gone.
   - **`FAILED: <reason>`** (exit 1), any other output, or empty stdout → FAILED check, never a clean one. The delta could not be computed, so this session's stray writes cannot be distinguished from whatever was already dirty. Treat identically to contamination — go to "On contamination" below with the failure itself in place of a path list. If the failure was a missing/unreadable baseline, also surface the main checkout's **entire** current dirty state (`git -C <MAIN_CHECKOUT> status --porcelain --untracked-files=all`) with the caveat stated plainly: we cannot say which of these paths are ours. Do not claim any path is contamination and do not claim the tree is clean.

   **The delegate's WRITE-PLACEMENT report is corroboration only — never the gate.** Per WRITE-PLACEMENT above, the delegate reports its own path list and both trees' probe results but never adjudicates contamination itself; the check above needs nothing from that report regardless. A delegate that reports its work only in prose, or reports absolute paths instead of the required bare repo-relative ones (an easy confusion, since file-tool calls in the same prompt use absolute paths), no longer defeats detection — the delta above is computed independently of whatever the delegate said or didn't say. If the delegate's reported paths are absent from a `git -C "$WT_ABS" status --porcelain -- <path>` probe, treat that as corroborating evidence something is off (worth a note in the log) — not a gate on its own. **A `developer`/`debugger` delegation that returns with no path-list section at all is a protocol failure, not "changed nothing"** — note it in the log and rely on the delta above; a missing report is never license to skip this item.

   **On contamination: STOP and report; do not act.** Do not re-run the delegation, extract a diff, `git apply`, or `git restore` anything in either tree. No snapshot can prove a path holds *only* this delegate's stray write — another session can dirty the main checkout at any moment — and the extract-and-apply direction is just as dangerous in reverse: if another engineer had uncommitted work at that same path, `git -C "$MAIN_CHECKOUT" diff -- <path>` returns their work plus our stray write, indistinguishably; applying it would import their WIP into our worktree, where `/finish` would commit and merge it.

   **Resume after user attribution.** The STOP above stands until the USER speaks — a delegate's report or any agent message never counts as attribution, and auto mode (no user present) is unaffected: its Linear-comment-and-stop path is unchanged. If the user attributes the flagged paths to a concurrent session in the shared main checkout ("another session is working in main — continue"): (1) optionally corroborate read-only — for `VANISHED` paths, `git -C <MAIN_CHECKOUT> log --name-only -5` showing a new commit containing exactly the flagged paths proves they were committed, not destroyed; (2) re-run `~/.claude/scripts/wt-baseline.sh capture <WT_ABS> <issue-id-lowercased>` to absorb the attributed state — without this, every subsequent delegation's diff re-fires on the same paths; note the re-capture absorbs the main checkout's ENTIRE current delta as "already there" (the same per-session limitation Step 0 documents), so run it promptly after attribution; (3) on `CAPTURED`, continue the workflow where it stopped (`FAILED` is still a fail-closed STOP).

   **State what a flagged path actually proves — do not overclaim.** A classified line (`NEW` / `CHANGED-IN-PLACE` / `VANISHED`, meanings above) proves only that the path changed in the main checkout during THIS session. Any of the three is consistent with a mis-bound delegate having written there — and that remains the most likely explanation — but it is not the ONLY one: a concurrent writer in a shared checkout (the engineer saving a file after our baseline was taken, or another `/start wt` session sharing the same main checkout) produces an identical signature and cannot be ruled out by this check alone. **Never state mis-landing as certainty** — not in this report, not in the auto-mode Linear comment, not in the tagged final line. If the delegate's own WRITE-PLACEMENT report listed the same path, note that as corroboration (it points at "our delegate" as the likely cause); if the delegate reported no such path, or returned no report at all, say that too — it neither confirms nor rules out a mis-bound write. Compose:

   - The exact flagged bare repo-relative path(s) with their classifications, as the diff reported them (or, on a FAILED-check STOP, the failure itself in place of a path list).
   - Whether each flagged path appears in the delegate's own WRITE-PLACEMENT changed-path report, if one was returned — corroborating, not conclusive.
   - The two read-only inspection commands, for a human to run: `git -C "$MAIN_CHECKOUT" status --porcelain --untracked-files=all -- <path>` and `git -C "$MAIN_CHECKOUT" diff -- <path>`. **If the status output for a path starts with `??` (untracked), `git diff` prints nothing for it** — a mis-landed new file (the typical `developer` output: a new component plus test) is untracked, so the diff command alone would wrongly read as "nothing to recover." For any `??` path, tell the human to read the file directly instead (e.g. the `Read` tool, or `cat -- "$MAIN_CHECKOUT/<path>"`).
   - An explicit warning that the main checkout may hold **other sessions' uncommitted work at other paths, and that a flagged path itself may ALSO be a concurrent writer's change rather than this session's delegate** — so attribution, not just separation, must happen by hand — and that `git restore` is destructive and hook-blocked (`standards/git.md` "Working Tree Protection"); this skill will not run it and does not vouch for any path being safe to restore.

   - **Interactive mode:** surface all of the above in chat.
   - **Auto mode:** write it to a Linear comment instead — save the body with the `Write` tool to `tmp/contamination-comment-<issue-id-lowercased>.md`, then run `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/contamination-comment-<issue-id-lowercased>.md`. The comment body is the same composed content above — it inherits the same honesty requirement; it must not assert mis-landing as fact either.

   Both modes then:

   - **Leave the issue `In Progress` and preserve the worktree and branch.** Do not return the issue to the backlog — an available issue invites another agent to pick it up and re-contaminate the same main checkout.
   - Emit the single terminal line and stop:

     ```text
     BLOCKED-ON-REVIEW: <ISSUE-ID> — MAIN-CHECKOUT-CONTAMINATION: path(s) changed in the main checkout during this session (<bare paths>) — most likely a mis-bound delegate, though a concurrent writer in a shared checkout cannot be ruled out; manual recovery required.
     ```

   - This is a STOP, not a Step 8.5 terminal transition — it performs no Linear state change (see Step 8.5).
   - If this same check instead fires inside `/quality-review`'s fix loop: `/quality-review` is not a lifecycle-tag authority — it terminates with `Verdict: terminated-with-open-items` and an `Open items:` entry containing the exact literal substring `MAIN-CHECKOUT-CONTAMINATION`; `/start` Step 10 keys off that substring (see Step 10).

2. Verify the result (type checks, tests, dev server — whatever is appropriate)
3. If validation fails: the subagent broke the working application. Delegate the fix back to `developer` or `debugger` with this framing: "The application was working before our changes. Your changes broke it. Fix it." Do not accept "pre-existing" as an explanation — the baseline passed.
4. Check off the corresponding checkbox(es) in the issue description:

```bash
# Get current description
linear-cli issues get PL-13 --output json
```

Update completed checkboxes (`- [ ]` → `- [x]`) and push the update:

1. Use the `Write` tool to save the full updated description to `tmp/linear-description-<issue-id-lowercased>.md` (e.g., `tmp/linear-description-pl-13.md`)
2. Run:

```bash
~/.claude/scripts/linear-post.sh description PL-13 tmp/linear-description-pl-13.md
```

**Important**: Preserve the entire description — only change `- [ ]` to `- [x]` for completed items. Do not rewrite or reformat the description.

**Do NOT change the issue state** during implementation. The issue stays "In Progress" throughout this entire skill. Moving to "Ready For Release" is handled exclusively by the `/finish` skill after commit and push. Even if all checkboxes are checked, do not transition the state.

**The only exceptions** to this rule are Step 8.5's two state-transitioning terminal-exit paths (CANCELED / ABANDONED), which move the issue to `Canceled` or `Planned` respectively. Those are explicit terminal contracts — when one of the Step 8.5 triggers fires (work already shipped / no longer needed; user halting before completion), Step 8.5 supersedes this prohibition. Item 1's contamination STOP above is not a third exception: it performs no state change at all, so it never conflicts with this rule. Outside Step 8.5, the rule above holds with no further exceptions: no state changes during implementation. A future skill or subagent invoked from /start MUST NOT change the issue state on its own; if a third *state-transitioning* terminal-exit path becomes necessary, add it to Step 8.5 (not invented elsewhere) — a stop that leaves state unchanged, like item 1's, needs no entry there.

**Progress Checkpoints** — As implementation progresses, add brief comments on significant design decisions or unexpected blockers:

1. Use the `Write` tool to save the comment to `tmp/linear-comment-<issue-id-lowercased>.md` (e.g., `tmp/linear-comment-pl-13.md`)
2. Run:

```bash
~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md
```

This ensures progress is visible in Linear even if the session is interrupted, and enables picking up where we left off.

**Resumption.** `/start` is idempotent on the same issue: re-running `/start PL-13` after a `/checkpoint`-and-stop hits Step 0's widened gate (a worktree already exists for this issue — see Step 0), so Step 0 runs the same procedure as a fresh start rather than being skipped. Sub-step 1's setup script safely reuses the existing worktree and branch (its create/attach/reuse logic handles this) and retakes the dirty baseline fresh for this session (`wt-baseline.sh capture` runs on reuse too — the baseline is never reused across sessions), and sub-step 2 re-enters via `EnterWorktree(path=<WT_ABS>)` so the resumed session's isolation is registered (else a background resumption's `developer` writes hit the guard). Sub-step 2's cwd precondition applies exactly as written: **re-anchor cwd to the main checkout first** if a manual resumption launched with cwd already inside the worktree (that would trip the same-cwd refusal), passing the **absolute** path `git worktree list` reports for the issue-keyed `.claude/worktrees/<id>` (the tool rejects a relative path as not a registered worktree).

After Step 0 — whose sub-step 3 `start-wt-verify.sh` call re-verifies cwd, re-baselines, and re-probes availability, running with `--no-claim` per its idempotent-resumption rule (the issue is already claimed by me) rather than skipping Step 3 wholesale (its availability check still runs) — check the digest's comments for an already-posted implementation plan. If one exists and still applies, skip Step 6/7 entirely (no new exploration — sub-step 3's own exploration dispatch is SKIPPED on this path, per its "Three exceptions" note) and resume directly at Step 8. Otherwise — the plan is judged STALE, or none was ever posted — continue at Step 6, but the exploration state differs by which: if a plan was posted but is STALE, sub-step 3 already skipped its exploration dispatch (per its "Three exceptions" note), so dispatch exploration now, at Step 6 before `EnterPlanMode` (Step 6's re-dispatch fallback covers exactly this case); if no plan was ever posted, sub-step 3 dispatched exploration as usual and it is already running. If Step 9 (review) had previously run, the existing `tmp/quality-review-verdict-<issue-id-lowercased>.md` file (e.g., `tmp/quality-review-verdict-pl-13.md`) is still consulted by `/finish` Step 1.5 — the user can decide to re-run `/quality-review` to refresh it, or skip ahead to `/finish` if the prior verdict still applies.

**After all implementation tasks are complete, proceed to Step 9.** Implementation is not finished until the review passes.

### Step 8.5: Early-Termination Exit Paths (CANCELED / ABANDONED)

Two state-transitioning terminal exits can fire BEFORE the normal Step 9 → Step 10 flow: CANCELED and ABANDONED. (Step 8 item 1's contamination STOP is a different thing — it halts the session but changes no Linear state, so it is not one of these and needs no entry here.) Both CANCELED and ABANDONED bypass Step 9 entirely and emit a tagged final line per `standards/lifecycle-tags.md`. Use these explicitly rather than ad-hoc'ing an exit; they are documented contracts other sessions (and the user) can scan.

**CANCELED — "the work is already done or no longer needed."** Fires when implementation discovery reveals that:

- The change the issue requested already shipped (under another issue, on the source branch, or via a parallel session — the PL-292 case).
- The change is no longer wanted (requirements changed, design pivot).
- The issue is a duplicate of work currently in progress elsewhere.

Steps:

1. Post a Linear comment summarizing what was found and why no code is shipping. Use `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/canceled-comment-<issue-id-lowercased>.md` (e.g., `tmp/canceled-comment-pl-292.md`). Body should name the issues/PRs that already cover the work (if applicable) and note any out-of-scope findings worth filing as separate issues.
2. Move the Linear issue state to a "canceled" terminal state. Try the canonical name first, then fall back per `/quality-review` sub-step 6's fallback pattern:

   ```bash
   linear-cli issues update <ISSUE-ID> --state Canceled
   ```

   If the team's canceled-state name differs (rejected), derive the team key from the issue ID prefix (e.g., `PL-13` → team `PL`), then probe `linear-cli statuses list -t PL` and pick the first state whose name matches `/^(canceled|cancelled|won.?t.?do|abandoned)/i` (case-insensitive, prefix). If none match, surface the available states to the user and ask which to use — do not silently fall through to the team default. **Auto mode:** do not ask — leave the state unchanged, name the intended state in the Linear comment from sub-step 1 (a human re-states it later), and continue to the tagged line.

   After the state transition succeeds, clear the assignee so the Step 3 claim does not linger on a terminal issue (mirrors `mark-ready-for-release.sh`'s unassign-on-terminal behavior — a Canceled issue should not clutter anyone's "my issues" view):

   ```bash
   linear-cli issues assign <ISSUE-ID>   # no user arg unassigns
   ```

3. Surface the cleanup commands to the user (do NOT run them automatically — the worktree might contain in-progress notes worth saving):

   ```bash
   git worktree remove .claude/worktrees/<issue-id-lowercased>
   git branch -D <worktree-branch-name>
   ```

4. Emit the tagged final line and stop. Do NOT run Step 9 or Step 10:

   ```text
   CANCELED: <ISSUE-ID> — <one-line reason>. Run git worktree remove .claude/worktrees/<issue-id-lowercased> && git branch -D <worktree-branch-name>.
   ```

**ABANDONED — "user is halting the session before completion."** Fires when:

- The user explicitly asks to pause and return the issue to the backlog ("move PL-322 back to Planned").
- A blocker emerges that the user wants to defer (waiting on external decision, dependency not ready).
- The session is being intentionally parked for resumption later (different context, different person).

Steps:

1. Post a Linear comment noting where things stand: what's done, what's not, any decisions made, where the implementation left off. Use `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> tmp/abandoned-comment-<issue-id-lowercased>.md` (e.g., `tmp/abandoned-comment-pl-322.md`).
2. Move the Linear issue state back to a "ready-to-work" state. Try the canonical name first, then fall back per `/quality-review` sub-step 6's fallback pattern:

   ```bash
   linear-cli issues update <ISSUE-ID> --state Planned
   ```

   If the team's planned-state name differs (rejected), derive the team key from the issue ID prefix (e.g., `PL-13` → team `PL`), then probe `linear-cli statuses list -t PL` and pick the first state whose name matches `/^(planned|backlog|to.?do)$/i` (exact match on these four; NOT a prefix match) — preferring `Planned` if present, since it preserves the "we intend to do this" signal more strongly than `Backlog`. **Deliberately exclude `ready` from the regex** — a prefix match on `ready` would latch onto `Ready For Release` or `Ready For Review` on teams that have those states, silently moving an abandoned issue into a release/review state. If none match, surface the available states to the user and ask which to use — do not silently fall through to the team default. **Auto mode:** do not ask — leave the state unchanged (the issue stays In Progress), name the intended state in the Linear comment from sub-step 1, and continue to the tagged line.
3. **Preserve the worktree** — the whole point of `ABANDONED` (vs `CANCELED`) is that resumption is expected. Do not run `git worktree remove` and do not delete the branch.
4. Emit the tagged final line and stop:

   ```text
   ABANDONED: <ISSUE-ID> — <one-line reason>. Worktree preserved at .claude/worktrees/<issue-id-lowercased> for resumption.
   ```

**Distinguishing the two:** if the user (or implementation discovery) determined the work is done or unneeded → `CANCELED`. If the user is pausing with intent to resume → `ABANDONED`. When in doubt, ask the user once which they intend; do not silently pick. **Auto mode:** do not ask — when the evidence clearly shows the work already shipped or is unneeded, use `CANCELED`; in every other doubtful case default to `ABANDONED` (it preserves all state for a human to inspect).

### Step 9: Adversarial Review and Triage

Use the `/quality-review` skill to run the adversarial implementation review and triage/fix loop, passing the current issue ID as context. The `/quality-review` skill enforces the `pnpm check` gate, delegates to `quality-reviewer`, and loops up to 5 review/fix cycles before escalating. When it returns a passing verdict (`passed-clean` or `passed-after-fixes`), proceed to Step 10. If it returns `terminated-with-open-items`, print the verdict block (as composed by `/quality-review`) to chat as a single message — no `AskUserQuestion` prompt at this point. Step 10 will re-render the same block as part of the structured summary; the duplication is intentional (chat-visibility now, structured artifact later).

**Dispatch via the Skill tool.** Call `Skill(skill: "quality-review", args: "<ISSUE-ID>")` (e.g., `Skill(skill: "quality-review", args: "PL-13")`) — in auto mode, `args: "auto <ISSUE-ID>"` so `/quality-review`'s own prompts resolve to their auto defaults. Do NOT emit the literal `/quality-review PL-13` as chat text. Slash commands in chat output are not re-parsed by the harness; they render as plain text and the skill never runs. The Skill tool is the only programmatic invocation path. Pass the issue ID positionally so `/quality-review` Step 1 doesn't fall back to branch parsing.

If `/quality-review` returns `escalated-to-architect`, surface the open items and the architect-agent recommendation in chat, then proceed to Step 10. Step 10 item 6's verdict-conditional Next-steps branch handles this verdict correctly (it emits the "architect recommendation supersedes — do NOT suggest /finish" line). Do not invent a separate exit path here — go through Step 10 like any other verdict.

**Step 10 ALWAYS fires** — even when `/quality-review` failed to produce a clean verdict. The user must always see Step 10's structured summary including the Next-steps line; silently ending the session at a broken `/quality-review` violates the "Next steps MUST be the final line" rule.

Two distinct failure modes route Step 10 differently:

- **`/quality-review` ran to completion and wrote a verdict file** — even with malformed reviewer output (Error Handling fallthrough writes `Verdict: terminated-with-open-items`) or unavailable agent (writes the same). In this case Step 10 item 4 reads the persisted verdict block normally and item 6 takes the `terminated-with-open-items` branch (`Re-run /quality-review to address open items, or open follow-up issues, before /finish`). This is the common failure path.

- **`/quality-review` crashed mid-flight without writing any verdict file** (orchestrator killed, OOM, network blip during the Output step, etc.) — narrow window. In this case Step 10 item 4 renders `Verdict: unavailable (see chat above for /quality-review failure details)` and item 6 takes the missing/unavailable branch (`Investigate /quality-review failure ... before /finish`).

Do not skip Step 10 to "save the user from noise" — the structured summary IS the contract.

### Step 10: Completion Summary

When implementation and review are complete, present a summary to the user that includes:

1. **Issue**: ID and title
2. **What was implemented**: Brief description of changes made
3. **Files changed**: List of created/modified files
4. **Adversarial review**: Confirm the adversarial quality review ran. Reproduce the verdict block from `/quality-review` verbatim — its field order is the canonical order:
   - Final review verdict (`passed-clean` / `passed-after-fixes` / `terminated-with-open-items` / `escalated-to-architect`)
   - Number of review cycles (initial + re-reviews)
   - Critical/High/Medium findings resolved
   - Deferred (Nice-to-Have) items fixed in-session
   - Deferred items filed as Linear issues (with issue IDs)
   - Deferred items dropped (user declined to fix and declined to file)
   - Open items (only on `terminated-with-open-items` or `escalated-to-architect`; includes any deferred items not handled above)
5. **Checks**: Confirm `pnpm check` passes. Four exception paths to handle explicitly, mutually exclusive by `/quality-review` termination point:
   - **Terminated at sub-step 5 regression-cap** (verdict = `terminated-with-open-items` from the deferred-items regression path) → `pnpm check` may be red. Surface that failure here rather than asserting passes.
   - **Terminated at Step 3+ Error Handling** (malformed reviewer output across two attempts, OR agent unavailable returned after Step 2's gate passed) → `pnpm check` is green as last observed at Step 2's gate. Report explicitly: `pnpm check passed at /quality-review Step 2 gate (review terminated at Error Handling after Step 2; fix loop did not run)`.
   - **Terminated at Step 2 itself** (`pnpm check` failed and Error Handling escalated to the user without proceeding) → `pnpm check` is red. Report the failing output and direct the user to fix before any further action.
   - **`/quality-review` never ran or crashed before reaching Step 2** (verdict = unavailable per the Step 9 always-fires fallback, no verdict file written) → report the most recent `pnpm check` state from the implementation phase, or note that the gate was not exercised.
6. **Next steps (tagged final line — see `standards/lifecycle-tags.md`)**: Emit ONE line, structured as `<TAG>: <ISSUE-ID> — <one-line summary including the recommended next command>`. Tag is mechanical, keyed off the verdict from Step 9:
   - `passed-clean` / `passed-after-fixes` → `READY-FOR-FINISH: <ISSUE-ID> — <impl summary>. Run /finish <ISSUE-ID>[ merge]` (append ` merge` when in a `/start wt` worktree). `/start` emits this same line regardless of caller. When `/full` dispatched `/start`, the `full-continue.sh` Stop hook keys off this `READY-FOR-FINISH:` line to drive the handoff to `/finish` automatically — `/start` needs no `/full`-specific variant.
   - `terminated-with-open-items` — check whether `Open items:` contains the exact literal substring `MAIN-CHECKOUT-CONTAMINATION` (mechanical, not interpretive, per `standards/lifecycle-tags.md` — do not pattern-match the surrounding prose). That substring marks an entry from a `/quality-review` delegation that hit the same main-checkout-contamination hazard Step 8 item 1 guards against; `/quality-review` is not a tag authority, so it routes contamination through this verdict instead of emitting its own tag. If present → `BLOCKED-ON-REVIEW: <ISSUE-ID> — MAIN-CHECKOUT-CONTAMINATION: path(s) changed in the main checkout during /quality-review (<paths>) — most likely a mis-bound delegate, though a concurrent writer in a shared checkout cannot be ruled out; manual recovery required. Do NOT re-run /quality-review — it would dispatch fresh delegations through the same broken binding into the same main checkout.` Otherwise → `BLOCKED-ON-REVIEW: <ISSUE-ID> — open items unresolved after N cycles. Re-run /quality-review or file follow-up issues before /finish.`
   - `escalated-to-architect` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — escalated to architect agent. Review its recommendation before any further action; do NOT run /finish.`
   - missing/unavailable verdict (subagent emitted malformed output, infrastructure error, etc.) → `BLOCKED-ON-REVIEW: <ISSUE-ID> — /quality-review verdict unavailable (likely malformed reviewer output or infrastructure error). Investigate before /finish.`
   - **Any other value** (defense in depth — `/quality-review` should normalize to one of the four above) → `BLOCKED-ON-REVIEW: <ISSUE-ID> — unrecognized /quality-review verdict <value>. Investigate before /finish; do NOT guess.` (`<value>` is a substitution site — see `/quality-review` Step 6 sub-step 6's "Every `<...>` token below is a substitution site" paragraph for the general rule — replace with the literal verdict string the orchestrator received, e.g., if `/quality-review` returned `Verdict: passed-after-fixes-extra`, emit `unrecognized /quality-review verdict passed-after-fixes-extra` — never the literal `<value>` token.)

**Ordering — the tagged line MUST be the final line, emitted BARE.** The tagged line is the only scannable lifecycle signal in the agents-list display; the user scans bottom-up when running parallel sessions. Do not emit a separate end-of-turn `result:` summary, a one-line recap, or any trailing prose after the tagged line — and do **not** wrap the tag in a ` ```text ` (or any) code fence: a trailing closing ` ``` ` becomes the last line, which reads as a summary close and defeats the `full-continue.sh` handoff hook (see `standards/lifecycle-tags.md`). Any ` ```text ` tag examples above are documentation formatting only. The Step 10 block IS your end-of-turn summary — nothing follows the bare tag. (The harness may append its own `※ recap:` line, which you cannot suppress; the goal is that no LLM-authored text comes between the tagged line and that harness line.)

## Error Handling

- If the issue is already In Progress assigned to someone else, warn the user and ask whether to reassign (auto mode: `SKIPPED-BLOCKED`, never reassign)
- If the issue is already Done or Ready For Release, warn the user and ask if they want to reopen it (auto mode: `SKIPPED-BLOCKED`, never reopen)
- If there are unresolved blockers, list them and ask the user how to proceed (auto mode: `SKIPPED-BLOCKED`)
- If `linear-cli` is not authenticated, prompt: `linear-cli auth oauth` (auto mode: do not prompt — stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — linear-cli unauthenticated. No state change.`)
- If a git branch for this issue already exists, switch to it instead of creating a new one
