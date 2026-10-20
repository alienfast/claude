---
name: start
description: Start working on a Linear issue — check blockers, claim it (assign + In Progress), set up the branch or worktree, plan, implement by delegation with checkpoints, then review. Tokens — `wt` (isolated worktree), `auto` (unattended; used by /auto), `simple` (simple review tier), `interactive` (worktree + claim, then hand off). Use when the user says 'start issue', 'work on PL-XX', 'begin PL-XX', or invokes /start.
---

# Start Issue

Automates the workflow for starting and implementing a Linear issue with the `linear-cli` CLI.

## Working Application Contract

This skill is the canonical home of the contract; `/quality-review` and the delegation template below point here.

**We are modifying a WORKING application. If the application stops working, that is OUR failure. Period.**

There is no "pre-existing" failure during implementation. Step 5's baseline establishes a clean starting point; from
that moment every `pnpm check` failure is caused by our changes and is ours to fix — no excuses, deflection or deferral.

1. **`pnpm check` must pass at all times.** Run it early and often; Turborepo caching keeps an unchanged tree cheap when
   the heavyweight lanes sit behind cached turbo tasks. It may not cover every suite a project has (the project's
   `CLAUDE.md` names any outside it); the contract anchors to what the baseline actually ran, so when this issue touches
   an outside suite the orchestrator — never a parallel delegate, which would run it against shared fixtures — captures
   that suite's own baseline too and records, never adopts, failures it shows at HEAD. It is owed before the first edit,
   not before planning: `~/.claude/scripts/suite-baseline-cache.sh lookup <suite>` first — a `HIT` *is* the baseline (its
   `SUMMARY` and `FAILING` lines). On a `MISS`, launch the run detached at once, do every read-only step while it runs
   (Step 6's exploration and plan, Step 7's post), and join its completion marker immediately before Step 8's first edit.
   After any *complete* full-suite run, `record` it before the next edit so sessions forked from the same tree skip it.
2. **Failures are never "pre-existing."** The baseline passed; any failure after it is ours, for what the baseline ran.
3. **Failures are never "out of scope."** If our changes cause a check to fail, fixing it IS our scope.
4. **Failures are never deferred.** We do not proceed with a broken application. We stop and fix.
5. **In effect from Step 5's baseline through Step 9's review.** Steps 1–4, 6, 7 and 10 modify no code; Steps 5, 8 and 9
   can break the application and must keep `pnpm check` green. Every Step 8 delegation (`developer`, `debugger`,
   `quality-reviewer`, `architect`) includes this contract verbatim in its prompt.

Shipping broken code, calling a failure pre-existing, or deferring breakage to a follow-up is the single worst outcome
of this workflow. A partially implemented feature on a working application beats a "complete" one on a broken one.

## Arguments

```text
/start <ISSUE-ID> [wt] [auto] [simple] [interactive]
```

Tokens are case-insensitive and position-agnostic. Parse in order: **(1)** strip the recognized tokens; **(2)** exactly
one non-token argument must remain, else error; **(3)** normalize it with
`~/.claude/scripts/detect-issue-id.sh --validate-only --input <arg>` (enforces `^[A-Z]+-[0-9]+$`, uppercases). Multiple
IDs, duplicated tokens, and `auto` with `interactive` (unattended vs user-driven — contradictory) are usage errors.

- `wt` — worktree mode (Step 0). Implied by `interactive`; an existing worktree for the issue arms it without the token.
- `auto` — unattended: every prompt resolves to its documented default (Auto Mode below).
- `simple` — `/quality-review`'s simple tier at Step 9 ([standards/issue-spec.md](../../standards/issue-spec.md) § The
  `simple` label); the issue's `simple` label implies it without the token (Step 1's Labels bullet). Inert under
  `interactive`, whose path never reaches Step 9 — pass `simple` to the `/quality-review` you run by hand.
- `interactive` — set up the worktree and claim the issue, then halt and hand off: no planning, implementation or
  review, so interactive work lands in an isolated worktree without disturbing background `wt` agents. Read
  `references/interactive.md` when the token is present.

## Auto Mode (`auto` token)

`/start auto <ISSUE-ID>` runs the same workflow with **no user prompts**: every prompt resolves to its documented
conservative default (`skills/full/SKILL.md` § Auto mode owns the token; `/auto` reaches it through `/full auto`). This
skill's defaults, each stated where the prompt lives: Step 2 unresolved blocker → `SKIPPED-BLOCKED`; Step 3 owned by
someone else, terminal state, `needs decision` or `human` → `SKIPPED-BLOCKED` (never reassign, reopen or decide); Step 5
red baseline → at most two fix delegations; Step 6 plan approval → skipped, the plan posted at Step 7 is the audit
record; Step 8.5 CANCELED-vs-ABANDONED doubt → `ABANDONED`; Step 9 passes `auto` (and `simple`) through to
`/quality-review`. Nothing else changes: the contract, checkpointing, delegation rules and tagged final lines all apply.

## Workflow

### Step 0: Worktree Mode (`wt` in args, or an existing worktree for this issue)

Fires when the args contain `wt` (including when `interactive` implied it) **or a worktree already exists for this
issue** — `git worktree list --porcelain` has an entry at `.claude/worktrees/<issue-id-lowercased>`; that is a
resumption, so also read `references/resumption.md`. If neither holds, proceed to Step 1 in place, on the current branch.

**`IS_WT`** — the session flag Step 8's isolation scoping gates on — is true whenever Step 0 fires this session or Step 5's
`git config --worktree --get start.source-branch` probe returns a value later. A POSITIVE probe always arms it; a NEGATIVE
probe never disarms it (a hijack can wipe the value, and a broken `EnterWorktree` registration can fake a negative).

**Keeper issues.** A `keeper`-labeled issue's deliverable lives in the shared `~/.claude` repo: the project worktree is the
process anchor only and correctly ends with **zero** project commits. Edit `~/.claude` directly and leave it
**uncommitted** (the keeper's review is the gate; `/auto`'s commit grant never extends there). `/quality-review`,
`/finish` (`already-synced (no-op)`) and `finish-merge.sh` (`already-merged: nothing to advance`) expect that state.

1. **Run the setup script** — after loading every deferred-tool schema this workflow needs in ONE `ToolSearch` call,
   `select:EnterWorktree,EnterPlanMode,ExitPlanMode` (auto mode needs only `EnterWorktree`). Under a repo lock
   (`with-repo-lock.py`, the key `/finish merge` uses) it creates, attaches or reuses the worktree, records the source
   branch, writes the tamper-evident identity stamp `/finish` verifies, carries gitignored local files in
   (`.worktreeinclude` paths, else every gitignored `.env*`, templates excluded, with a `NOTE:` asking for an explicit
   list), and pre-fetches the digest.

   ```bash
   ~/.claude/scripts/start-wt-setup.sh PL-13
   ```

   Stdout is `KEY=value` lines; carry all of them forward: `WT_ABS` (absolute worktree path), `BRANCH`, `SOURCE_BRANCH`,
   `ISSUE_ID` (uppercased), `STATE`, `ASSIGNEE` (empty if unassigned), `DIGEST_FILE` (absolute path; empty if the fetch
   failed), plus the informational `BASELINE_SHA`, `OWNER_SESSION` and `IDENTITY_SIDECAR`. Sub-steps 2–3 consume the
   first group; `BRANCH` and `SOURCE_BRANCH` feed Step 8.5 and the `/finish` dispatch.

   Stderr is diagnostics: `[finish-queue] waiting for <repo> ...` is the lock serializing, not a hang; heed a `WARN:` to
   park the main checkout off the shared source branch (`git checkout --detach`) for parallel runs. **Non-zero exit →
   stop; read `references/wt-failures.md`** (it maps the `owned by another live session` refusal). Never set
   `start.source-branch` by hand at common scope — Step 5's short-circuit reads any value as a `/start wt` worktree.

   **Source branch.** The script forks from — and records for `/finish` — `start.<id-lower>.wt-source-branch` when set
   (the per-issue key `/fleet-sequence` and an epic fleet's `/auto` set before dispatching that one issue), else the
   checkout's current branch, else (detached HEAD) `start.wt-source-branch`; from the branch's ref, not HEAD, so a running
   sequence or fleet never steers another issue's `/start wt`. Stderr notes a per-issue key in use and warns when your own
   epic-member `/start wt` will land off the epic's PR.

2. **Enter the worktree with `EnterWorktree(path=<WT_ABS>)` and, in the SAME message, `Read` the digest at
   `DIGEST_FILE`** (Step 1's digest read, a turn early). Note the `**Labels:**` line — `simple` sets the `simple` token
   for Step 9. If `DIGEST_FILE=` is empty, run Step 1's generate-then-read after entering, as its own call.

   Call `EnterWorktree` **while cwd is still the main checkout**, before any `cd`: the `path` form switches the session
   into the worktree **and** registers it as the harness-level isolation root, which a shell `cd` does not — the guard
   then blocks a background `developer` subagent's Write-tool edits. Entering from the main checkout never trips the
   same-cwd refusal; cwd persists for every later Bash call. Sub-step 3's script confirms cwd first (canonicalizing both
   sides); on a mismatch the registration did not take — **STOP and surface**, never fall back to a bare `cd`.

3. **Run the verification script — Steps 2–5's actions in one call — with Step 6's exploration dispatched in the SAME
   message.** Decide FIRST from the digest and `STATE=`/`ASSIGNEE=`: an unresolved blocker (Step 2) or an unavailable
   issue (Step 3: owned by someone else, terminal state, `needs decision`, `human`) → do NOT run the script; take that
   step's prompt or auto exit. Already In Progress and mine → `--no-claim` in place of `--claim`. On the happy path, with
   an explicit Bash timeout ≥ 300000ms (`pnpm check` runs inside), redirecting **stderr only**:

   ```bash
   ~/.claude/scripts/start-wt-verify.sh '<WT_ABS>' <ISSUE-ID> --claim 2>tmp/start-wt-verify-<issue-id-lowercased>.err
   ```

   Stdout is exactly one line, the verdict; stderr holds everything else (`pnpm check`'s output, `WARN:`, `SOURCE_BRANCH=`).
   A `2>&1` capture buries the verdict as the LAST of hundreds of lines and overflows the inline output limit; if you did
   merge them, recover it with `grep -nE '^(VERIFIED|FAILED-[A-Z-]+)' <file> | tail -n 1`, never from the file's head.

   **Dispatch Step 6's exploration agents in the SAME message** (Step 6 sizes them): read-only, needing only the digest
   and the worktree; the claim lands seconds into the script's run, so claim-before-research holds. Under `IS_WT` every
   exploration prompt carries Step 8's READ-SCOPING block — Step 8's isolation rules apply to EVERY delegation this skill
   makes, in any step. **Two exceptions dispatch none:** a resumption whose posted plan still applies
   (`references/resumption.md`), and the `interactive` token.

   **`VERIFIED`** → Steps 1–5 complete, the contract is in effect; proceed to Step 6 (or sub-step 4's halt under
   `interactive`). The claim is **read back**, not trusted from the write's exit status (linear skill gotcha #8); a
   failed read-back is a `WARN:` and proceeds, so `VERIFIED` means *claimed, or claimed-and-unconfirmable* — on that
   WARN, re-check before implementing if siblings may contend. The script runs `pnpm check` only: an outside suite this
   change touches still owes contract rule 1's baseline — start it now, join at Step 8's first edit. **Any other verdict
   → read `references/wt-failures.md`** (`FAILED-CHECK` is Step 5's baseline-failure path).

4. **`interactive` token → halt here**: on `VERIFIED`, read `references/interactive.md` and follow its hand-off (open the
   worktree in its own editor window, emit `INTERACTIVE-READY` as the session's only tag; nothing after Step 0 runs).
   Otherwise **continue in this same session — no subagent wrapper**: the `EnterWorktree` registration is the isolation,
   and a wrapper would hide plan-mode prompts and `/quality-review` output. Steps 1–5 are satisfied by sub-steps 2–3;
   Steps 6, 8 (scoped `developer` delegations, not whole-workflow dispatch) and 9 run unchanged.

### Step 1: Gather Issue Context

**Worktree mode:** sub-step 2 read the digest and sub-step 3 folded Steps 2–5 in — on `VERIFIED`, skip to Step 6 (whose
exploration is already running). Steps 1–5 run as written in place, or when Step 0's happy path did not complete.

The digest (`tmp/linear-context-<issue-id-lowercased>.md`) summarizes the issue, parent chain, dependency graph, comments
and attachment URLs. If the file exists and contains a `**Labels:**` line, read it; otherwise (`mkdir -p tmp` first)
generate it: `~/.claude/scripts/linear-context.sh PL-13 | tee tmp/linear-context-pl-13.md`. A cached digest without a
Labels line predates the label read, and one cached before a label attached misses it — regenerate when in doubt. Note:

- **Description** — requirement checkboxes (`- [ ]`), success criteria, "Nice to Have" vs "Must Have"
- **Parent chain** — each ancestor's title and state; ancestors often carry architectural decisions and scope bounds
- **Dependencies** — blockers with states; comments summary; **Attachments** — `uploads.linear.app` URLs (Step 4)
- **Labels** — `simple` present → carry the `simple` token to Step 9 exactly as if typed (the label is how a fleet run,
  whose only input is Linear, selects the review tier), without adjudicating co-labels — `/quality-review`'s guard 2
  escalates on `security`/`human`/`needs decision`/`epic` and removes the mislabel. Step 3's `needs decision`, `human`
  and `stalled` checks read the same line.

### Step 2: Check for Blockers

The digest's **Blockers (issues blocking this)** section lists each blocker's state. A blocker is resolved only when its
state is terminal for the team (typically `Done`, `Canceled`, `Ready For Release`, plus team-custom terminal states such
as `Released`, `Shipped`, `Won't Do`); in doubt treat it as unresolved — a false positive is recoverable, silently passing
a real blocker is not. List each unresolved blocker with its state and ask whether to proceed anyway or address it first.
**Auto mode:** do not ask — emit `SKIPPED-BLOCKED: <ISSUE-ID> — blocked by <BLOCKER-ID> (<state>)` and stop; nothing is
claimed or modified, and `/auto` records a skip, not a failure (`/next` pre-filters blocked issues, so this is rare).

### Step 3: Claim the Issue — Assign & Move to In Progress

**Claim before you research** — the first action after availability is verified, before any deepen-context, exploration
or implementation, so ownership is broadcast the moment work begins. The assignee signals other *people* and does nothing
to a session sharing your Linear identity (`standards/linear-workflow.md` § A self-claim does not hide an issue); the
**state** is what removes it from every ranking (`WORKABLE_STATES` is Backlog/Planned/Todo) — so both halves are read
back rather than inferred from the write's exit status. (Worktree mode: sub-step 3's script claims early in its run, in
the same message as Step 6's exploration — the documented exception to strict sequencing; availability still precedes it.)

Verify availability from the digest's `**State:**`, `**Assignee:**` and `**Labels:**` lines (no extra call):

- `In Progress`, assigned to **someone else** → warn and ask whether to reassign. **Auto:** never reassign — emit
  `SKIPPED-BLOCKED: <ISSUE-ID> — In Progress, assigned to <assignee>` and stop.
- `Done` / `Ready For Release` / other terminal state → warn and ask whether to reopen. **Auto:** never reopen — emit
  `SKIPPED-BLOCKED: <ISSUE-ID> — already <state>` and stop.
- `needs decision` label → a human decision is pending (`standards/issue-spec.md`; the comments name it). Warn with the
  reason and ask whether to proceed — proceeding IS the decision: on yes, remove the label
  (`~/.claude/scripts/linear-remove-label.sh <ISSUE-ID> 'needs decision'`) and claim. **Auto:** never proceed — emit
  `SKIPPED-BLOCKED: <ISSUE-ID> — needs decision (see issue comments); decide and clear the label, or /spec <ISSUE-ID>.
  Nothing claimed.` and stop. Outranks the resumption bullet — a pending decision gates even an idempotent resume.
- `human` label → human-performed work (`standards/issue-spec.md`); nothing for an implementation session to ship. Warn
  and ask whether to proceed anyway — proceeding means assisting the human owner, so **keep the label** on yes (it
  resolves nothing and the issue must stay hidden from ranking). **Auto:** never proceed — emit
  `SKIPPED-BLOCKED: <ISSUE-ID> — human-owned work (human label); assign a person, or /spec <ISSUE-ID> to split out an
  agent-shippable slice. Nothing claimed.` and stop.
- `In Progress`, assigned to **me** → idempotent resumption; skip the update and continue (either mode).

Otherwise claim it immediately: `linear-cli issues update PL-13 --assignee me --state "In Progress"`.

**`stalled` label cleanup (claim or resumption, either mode).** `/auto` applies `stalled` when it abandons an In Progress
issue; being picked up again is the attention it asked for, so remove it now —
`~/.claude/scripts/linear-remove-label.sh <ISSUE-ID> stalled` — best-effort, never blocking the claim (worktree mode: run
it after sub-step 3 returns `VERIFIED`; the script does not touch labels). Only after the claim do you proceed to Step 4.

### Step 4: Deepen Context (only as needed)

The digest covers most context. Reach for these only when its summary is insufficient:

- **Full standalone comment bodies** (the digest truncates *standalone* comments to their first line; *anchored* ones
  show whole): `linear-cli comments list PL-13 -o json | jq -r '.comments.nodes[].body'`
- **Project description** (the digest's `**Project ID:**` line; none means no project): `linear-cli projects get <uuid>`
- **Inline images** — `uploads.linear.app` URLs need authentication, so never `WebFetch` or `curl` them:
  `linear-cli uploads fetch "https://uploads.linear.app/..." -f tmp/linear-img.png`, then `Read` the downloaded path.

### Step 5: Ensure Correct Git Branch

Settles which branch the work lands on and runs the `pnpm check` baseline that brings the contract into effect; in place,
its `start.source-branch` probe is also `IS_WT`'s second trigger. In-place mode (no `wt`): read
`references/in-place-path.md` § Step 5.

**Worktree short-circuit.** If sub-step 3 returned `VERIFIED` this session, Step 5 is complete — proceed to Step 6.

**If the user overrode a Step 2/3 decision** (proceed past a blocker, reassign, reopen), return to Step 0 sub-step 3 and
run `start-wt-verify.sh` (`--claim` or `--no-claim` per the outcome) — do not fall through to in-place branch selection.

**Baseline fails** (sub-step 3's `FAILED-CHECK`, or a red `pnpm check` in place) → STOP; do not plan. Delegate the fix to
`developer` or `debugger` (under `IS_WT` these carry Step 8's isolation blocks and placement check like any other
delegation) and re-run until clean. **Auto mode:** at most **2** fix delegations — a broken baseline in an unattended run
is systemic, not this issue's scope. If still red, post a Linear comment (baseline failure, first failing lines), return
the issue per `references/early-exit.md` § ABANDONED, and emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — baseline pnpm check
failing before any implementation; likely systemic. No changes made.` (`/auto` counts the failure; two in a row trip its
breaker.)

### Step 6: Enter Plan Mode

**Exploration starts BEFORE plan mode**, dispatched in the same message as the baseline (sub-step 3 in worktree mode,
Step 5 in place): read-only `Explore` agents needing only the digest, carrying READ-SCOPING in worktree mode. Split by
AREA, not by question — a narrow, well-located change gets ONE agent (a fan-out re-finds the same files); a multi-area
issue (component + theme + i18n + stories; API + UI + tests) gets **2–3 focused agents in one message**, each named an
area and concrete starting points; more than 3 buys little. If exploration was not pre-dispatched (a non-happy-path
re-entry, a stale resumed plan), dispatch it now — never read exploration targets yourself.

**Auto mode: skip the plan-mode tools entirely.** Nobody can approve, so do NOT call `EnterPlanMode`/`ExitPlanMode` (an
unanswered prompt stalls the loop). Do items 1–6 below, compose the plan in Step 7's format, and go **directly to
Step 7**: the posted plan is the audit record. The rest of this step is interactive only.

**Call `EnterPlanMode` once exploration returns.** Do not write the plan inline in chat — plan mode's tool flow surfaces
the approval UI (in VS Code a side pane that supports annotation); inline text bypasses it. In plan mode:

1. Requirements are the description, checkboxes and parent context — **plus any comment that amends them.** The digest
   truncates each *standalone* comment to 140 chars, and a comment can carry binding requirements (`/auto-prep`
   consolidates an issue family by appending each absorbed issue's Problem and Success Criteria as a checklist comment on
   the canonical issue). **Whenever the Comments section is non-empty, read the standalone bodies before planning**
   (Step 4's `comments list` command — the only prompt on the worktree path, which never passes Step 4). A comment that
   says its criteria are live here, or supersedes the description, is a requirement. **`### Nice to Have` checkboxes are
   NOT requirements** (`standards/issue-spec.md`): attempt one only when it falls out in-path, else leave it out — never
   "defer" one or promise a follow-up filing, which `/finish`'s reconciliation would convert into manufactured work.
2. **Search the tracker for adjacent open issues before designing.** The digest surfaces no *sibling* naming the same
   file, predicate or resolver without a relation edge — routinely a duplicate, the systemic fix your point fix instances,
   or in-flight overlapping work; `/quality-review`'s search-before-filing runs after scope is fixed. Run two or three
   `linear-cli search issues "<token>"` calls on the change's most distinctive identifiers, **one token per call** — it
   matches a contiguous phrase, so a composed multi-word query matches nothing and exits 0 (linear skill gotcha #14).
   Read every open hit, then set scope knowing what is filed: dedup, narrow, or record the overlap in the Step 7 comment.
3. **Read an either/or Desired Outcome as ordered, not as a menu** (`standards/issue-spec.md` § An either/or Desired
   Outcome is ordered): plan the stronger arm and record which arm and why. It binds mid-implementation too — when the
   work's own findings prove the stronger arm reachable (evidence in hand, within file scope, no human decision pending),
   delivering it is in-mandate, never scope expansion to defer. A *fork* offering two complete end-states is co-equal.
4. **Read Out of Scope as bounding the deliverable, never the evidence** (`standards/issue-spec.md` § Out of Scope bounds
   the deliverable, never the evidence — authoritative, with its `(decided:)` rule, three gates and two overlays). A
   crossing those gates admit is in-mandate, auto mode included: plan it, recording the crossing and evidence in the plan
   (or a checkpoint comment if it surfaces during Step 8) and in the completion comment. Otherwise route out, never
   silently comply: if the outcome still ships and verifies within bounds, plan the in-scope work and file the excluded
   fix with its evidence through `/quality-review`'s filing recipe (`standards/linear-filing.md`), labeled by `/auto`'s
   shape test (decision-shaped → `needs decision`, `specified` withheld; human-performed → `human`, `specified` kept when
   the body meets the bar) — unless nothing is pending, where the either/or rule's no-automatic-filing governs. If the
   outcome cannot ship or verify without the crossing, stop: surface it interactively; in auto mode return the issue per
   `references/early-exit.md` § ABANDONED and emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — decision required: <the pick, one
   sentence>; root cause sits inside a spec exclusion, evidence posted to the issue.` This binds through Step 8; from
   Step 9 on, a collision routes by `/quality-review`'s own machinery.
5. Synthesize the exploration into relevant files, patterns and dependencies — a follow-up `Explore` only for a gap.
6. Design a step-by-step plan, marking independent (parallelizable) vs dependent (sequential) tasks.
7. Write the plan to the plan file named in the plan-mode system message.

**Call `ExitPlanMode` when the plan is complete** — that is what requests approval and surfaces the annotation pane. On
pushback, incorporate it, update the plan file, and call `ExitPlanMode` again until approved; never ask "is this plan
okay?" through `AskUserQuestion`. After approval go **immediately** to Step 7 — no reads, grep or research before the post.

### Step 7: Post Approved Plan to Linear

**This step MUST complete before any implementation work begins — no exceptions.** No file reads, no grep, no dependency
research: post first, then stop. The comment is the permanent record from which anyone, a future session included, can
reconstruct intent if the session is interrupted.

1. `Write` the plan to `tmp/linear-comment-<issue-id-lowercased>.md` (e.g. `tmp/linear-comment-pl-13.md`), headed
   `## Implementation Plan` and `_Approved before implementation started._`, with three sections: `### Approach` (a 1–3
   sentence summary of the strategy), `### Steps` (numbered — what will be done and why), `### Key Files` (the paths
   identified during planning).
2. Post it: `~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md`

### Step 8: Implement via Delegation

**Your role is orchestrator only.** Do not read source files, write code, run grep, or edit. Every implementation action
is delegated through the Agent tool; you dispatch, verify with `pnpm check`, update Linear (checkboxes, comments), and
decide what to delegate next. If you catch yourself reading a source file or editing code, stop — delegate it.

**Agents:** `developer` (implements, tests, fixes), `quality-reviewer` (security, performance, best practices),
`debugger` (errors, root causes), `architect` (designs when implementation reveals architectural questions).

**Parallel is the default, not the exception.** Tasks that do not depend on each other's output launch in one message
with multiple Agent calls; sequential needs a justification. Before dispatching a batch, enumerate each agent's write
targets ([standards/agent-coordination.md](../../standards/agent-coordination.md) § Write-target exclusivity). Dispatch
synchronously (`run_in_background: false`) whenever the next step consumes the result — every implementation and fix
dispatch here; a backgrounded dispatch reports in a completion notification (same file, § Background-agent completion
reports — the spawn-policy mod forces synchronous dispatch for `developer`, `quality-reviewer` and `quality-verifier`
under the `auto` permission mode).

**Derive and carry `WT_ABS` and `MAIN_CHECKOUT` before composing any delegation** when `IS_WT` is true — the template
substitutes them into the very first prompt; both live in the orchestrator's context, never in shell state. `WT_ABS` came
from sub-step 1's stdout; if either is missing, run the two plain probes in `standards/git-worktrees.md`
§ Worktree-isolated sessions, **each its own Bash call**. Check by inspection before substituting the **literal absolute
paths**: both non-empty, existing directories, and `WT_ABS != MAIN_CHECKOUT` (equality means isolation was never
registered); STOP and surface on any violation — an empty value would silently scope every delegation to the wrong tree.

**Delegation format.** Every delegation includes the Working Application Contract; subagents do not get to claim
ignorance of it. Under `IS_WT`, every delegation of any agent type (`Explore` and `general-purpose` included — a read-only
search can leak another session's uncommitted content) carries READ-SCOPING, and every write-capable one (`developer`,
`debugger`) carries WRITE-PLACEMENT too; omit both when `IS_WT` is false. Why:
[standards/git-worktrees.md](../../standards/git-worktrees.md) § Delegation placement.

```markdown
Task for [agent]: [Specific, focused task]
Context: [Why this task matters, relevant issue context]
Files: [Exact paths and lines]

WORKING APPLICATION CONTRACT: We are modifying a working application. The baseline `pnpm check` passed before this work began. If your changes cause `pnpm check` to fail, that is your failure — not a pre-existing issue, not out of scope, not someone else's problem. You must leave the application in a working state. Run `pnpm check` before reporting your task as complete — in the foreground of your own turn, never backgrounded, giving the Bash call a generous explicit timeout (it can exceed the 120s default on a cold cache): a backgrounded check ends your turn with a waiting message as your entire report, leaving your work unverified. If it fails, fix it — except a red confined to files outside your write scope while a parallel delegate is editing them, which follows the sibling-in-flight line this dispatch carries (`standards/agent-coordination.md` § Write-target exclusivity).

READ-SCOPING:
Your working tree is <WT_ABS>; it is nested UNDER the main checkout, so a bare relative path can resolve in BOTH trees — use absolute paths rooted at <WT_ABS> for every Read/Edit/Write/Glob/Grep.
Never read, edit, or write anything under <MAIN_CHECKOUT> outside <WT_ABS> — it holds other sessions' uncommitted work.

WRITE-PLACEMENT:
In your final message, list every file you changed as bare repo-relative paths, one per line — built from your OWN RECORD of the Edit/Write calls you made this task, never from `git status` output. An empty list is legitimate ONLY if you made no Edit/Write calls at all; if an edit was a deliberate no-op or you reverted it, say so next to that path. Do not probe either tree and do not attempt any recovery — the orchestrator confirms these paths landed in the worktree (Step 8 item 1).

Requirements:
- [Specific requirement 1]
- [Specific requirement 2]
- Use dedicated tools: Read (not cat/head/tail). Prefer Glob/Grep over find/grep/rg via Bash if those tools are available in your environment — check once; if they are not (some environments only provide Bash search), Bash find/grep/rg is an acceptable fallback, not a violation.
- Do NOT commit, push, or open PRs — even if your session/harness defaults say shipping is part of the task. The orchestrating /start→/finish workflow owns commit, push, and PR creation; shipping happens only at /finish after the review gate.
- Run `pnpm check` before reporting completion. If it fails, fix the failures — except a red confined to files outside your write scope while a parallel delegate is editing them, which follows the sibling-in-flight line this dispatch carries (`standards/agent-coordination.md` § Write-target exclusivity). Do not report success with a failing check.
Acceptance: [How to verify success — MUST include "pnpm check passes"]
```

**After each delegation completes:**

1. **Confirm the edits landed in the worktree — after every write-capable delegation, gated on `IS_WT`** — per
   `standards/git-worktrees.md` § Delegation placement: probe each WRITE-PLACEMENT path with
   `git -C <WT_ABS> status --porcelain --untracked-files=all -- <path>`; empty output for a path not marked no-op is a
   failed delegation (a green `pnpm check` is no evidence either) — re-confirm the `EnterWorktree` registration,
   re-dispatch scoped to the missing paths with the same blocks, and if that misses too, STOP and surface; never hunt in
   the main checkout, never implement it yourself. **Auto mode:** first `Write` the detail (which delegation, both
   reports, the missing paths) to `tmp/misrouted-write-comment-<issue-id-lowercased>.md` and post it with
   `~/.claude/scripts/linear-post.sh comment`. Both modes then emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — delegate's reported
   edits missing from the worktree after re-dispatch (<bare paths>); manual investigation required.` and stop, state
   unchanged. A write-capable report with no path list is a protocol failure: check the worktree's whole dirty set
   against its scope. **A Write blocked by the isolation guard is a hard stop: read `references/blocked-write.md`.**
2. **A self-resolved deviation is design feedback, not a note.** When a delegate reports it departed from the plan (a
   rename to dodge a collision, an uncalled-for guard, a split step), ask what made it necessary and whether the plan's
   shape did; where the report does not say, dispatch `architect` rather than reading the code yourself. Accepting the
   workaround silently costs a review cycle — the reviewer reads the same evidence and files the finding you already had.
3. Verify the result (type checks, tests, dev server — whatever applies).
4. If validation fails, the delegate broke the working application: delegate the fix back to `developer` or `debugger`
   framed as "The application was working before our changes. Your changes broke it. Fix it." Never accept
   "pre-existing" — the baseline passed.
5. Check off completed checkboxes: `linear-cli issues get PL-13 --output json` for the current description, `Write` the
   full description to `tmp/linear-description-<issue-id-lowercased>.md` changing only `- [ ]` → `- [x]` (no rewrite
   or reformat), then `~/.claude/scripts/linear-post.sh description PL-13 tmp/linear-description-pl-13.md`.

**Do NOT change the issue state during implementation.** It stays In Progress for this whole skill; `/finish` alone
moves it to Ready For Release, even with every checkbox checked. The only exceptions are the two terminal exits in
`references/early-exit.md`; a third state-transitioning exit is added there, never invented elsewhere.

**Progress checkpoints.** On significant decisions or unexpected blockers, `Write` a brief comment to
`tmp/linear-comment-<issue-id-lowercased>.md` and post it with `~/.claude/scripts/linear-post.sh comment PL-13 <file>`;
the next session resumes per `references/resumption.md`.

**Implementation is finished only when Step 9's review passes.**

### Step 8.5: Early-Termination Exits (CANCELED / ABANDONED)

Two state-transitioning terminal exits can fire before Step 9: **CANCELED** — the requested change already shipped
(another issue, the source branch, a parallel session), the requirement was dropped, or the issue duplicates in-progress
work — and **ABANDONED** — the user halts before completion (an explicit "move it back to Planned", a blocker the user
defers, a session parked for resumption). ABANDONED is always user-initiated; a session never self-invokes it, and the
fleet deadline is never a trigger — it gates new picks only, so finish the pipeline, gates uncut. Both exits bypass
Steps 9–10 and end on their own tag. When either applies, read `references/early-exit.md` and follow it exactly. In
doubt, ask once; **auto mode** uses `CANCELED` only when the evidence clearly shows the work shipped or is unneeded,
else `ABANDONED` (it preserves all state).

### Step 9: Adversarial Review and Triage

Invoke `/quality-review` with the issue ID: it enforces the `pnpm check` gate, delegates to `quality-reviewer`, and loops
up to 5 review/fix cycles before escalating. On `passed-clean` or `passed-after-fixes`, proceed to Step 10. On
`terminated-with-open-items`, print its verdict block to chat as a single message — no `AskUserQuestion`; Step 10
re-renders the same block deliberately. On `escalated-to-architect`, surface the open items and the architect
recommendation in chat, then proceed to Step 10, whose item 6 handles it — never invent a separate exit.

**Dispatch via the Skill tool** — `Skill(skill: "quality-review", args: "<ISSUE-ID>")`; in auto mode
`args: "auto <ISSUE-ID>"`. Add `simple` (`"simple <ISSUE-ID>"`, `"auto simple <ISSUE-ID>"`) whenever the token was given
or the digest **file** on disk names it on its `**Labels:**` line — re-read the file (`grep -m1 '^\*\*Labels:\*\*'
<digest>`) rather than trusting a memory of Step 0/1, which a long Step 8 routinely compacts away. Never emit the literal
`/quality-review PL-13` as chat text (slash commands in output are not re-parsed, so the skill never runs), and pass the
ID positionally so `/quality-review` Step 1 does not fall back to branch parsing.

**Step 10 ALWAYS fires**, even when `/quality-review` failed to produce a clean verdict. A run that completed and wrote a
verdict file (malformed reviewer output and an unavailable agent both write `Verdict: terminated-with-open-items`) takes
item 6's open-items branch; a run that crashed with no verdict file renders `Verdict: unavailable (see chat above for
/quality-review failure details)` and takes the missing/unavailable branch.

### Step 10: Completion Summary

Present a summary that includes:

1. **Issue**: ID and title
2. **What was implemented**: brief description of the changes
3. **Files changed**: created/modified files
4. **Adversarial review**: reproduce `/quality-review`'s verdict block verbatim, in its canonical field order — verdict;
   review cycles; Critical/High/Medium findings resolved; deferred items fixed in-session, filed (with IDs) and dropped;
   open items (only on `terminated-with-open-items` or `escalated-to-architect`); the trailing `Review tier:` note when
   the run took the simple tier.
5. **Checks**: confirm `pnpm check` passes — with four exceptions, by where `/quality-review` ended: terminated at its
   sub-step 5 regression cap → the check may be red, surface that; terminated at Step 3+ Error Handling → report
   `pnpm check passed at /quality-review Step 2 gate (review terminated at Error Handling after Step 2; fix loop did not
   run)`; terminated at its Step 2 gate → red, report the failing output and direct the user to fix first; never ran or
   crashed before Step 2 → report the last `pnpm check` state from implementation, or that the gate was not exercised.
6. **Next steps — the tagged final line** ([standards/lifecycle-tags.md](../../standards/lifecycle-tags.md)): ONE line,
   `<TAG>: <ISSUE-ID> — <one-line summary including the recommended next command>`, keyed mechanically off the verdict:
   - `passed-clean` / `passed-after-fixes` → `READY-FOR-FINISH: <ISSUE-ID> — <impl summary>. Run /finish <ISSUE-ID>[ merge]`
     (append ` merge` in a `/start wt` worktree). Emitted regardless of caller: when `/full` dispatched `/start`, the
     `full-continue.sh` Stop hook keys off `READY-FOR-FINISH:` to drive the `/finish` handoff — no variant needed.
   - `terminated-with-open-items` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — open items unresolved after N cycles. Re-run
     /quality-review or file follow-up issues before /finish.`
   - `escalated-to-architect` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — escalated to architect agent. Review its recommendation
     before any further action; do NOT run /finish.`
   - missing/unavailable verdict → `BLOCKED-ON-REVIEW: <ISSUE-ID> — /quality-review verdict unavailable (likely
     malformed reviewer output or infrastructure error). Investigate before /finish.`
   - **Any other value** (defense in depth) → `BLOCKED-ON-REVIEW: <ISSUE-ID> — unrecognized /quality-review verdict
     <value>. Investigate before /finish; do NOT guess.` — `<value>` is a substitution site: emit the literal verdict
     string received, never the `<value>` token.

**The tagged line MUST be the final line, emitted BARE** — the only scannable lifecycle signal in the agents-list display,
scanned bottom-up across parallel sessions. No trailing summary, recap or prose after it, and no code fence around it (a
closing fence would become the last line and defeat the `full-continue.sh` hook; the ` ```text ` examples in this skill
are documentation formatting). The Step 10 block IS the end-of-turn summary; only the harness's own `※ recap:` line,
which you cannot suppress, may follow.

## Error Handling

- Issue In Progress assigned to someone else → warn, ask whether to reassign (auto: `SKIPPED-BLOCKED`, never reassign)
- Issue already Done or Ready For Release → warn, ask whether to reopen (auto: `SKIPPED-BLOCKED`, never reopen)
- Unresolved blockers → list them and ask how to proceed (auto: `SKIPPED-BLOCKED`)
- `linear-cli` not authenticated → prompt `linear-cli auth oauth` (auto: do not prompt — stop with
  `BLOCKED-ON-REVIEW: <ISSUE-ID> — linear-cli unauthenticated. No state change.`)
- A git branch for this issue already exists → switch to it instead of creating a new one

## References

Each file is read at the step that names it and nowhere else.

- `references/interactive.md` — the `interactive` token's hand-off: Arguments; Step 0 sub-step 4.
- `references/resumption.md` — re-running `/start` on an issue it already began: Step 0's existing-worktree gate and
  sub-step 3's exploration exception; Step 5's `IS_WT`-arming probe; Step 8's checkpoints.
- `references/wt-failures.md` — the setup script's `owned by another live session` refusal and every
  `start-wt-verify.sh` verdict other than `VERIFIED`: Step 0 sub-steps 1 and 3.
- `references/in-place-branch.md` — branch selection, naming, and fetch-before-baseline for a non-worktree run: Step 5.
- `references/in-place-path.md` — the in-place (no `wt`) body of Step 5: the `start.source-branch` probe that arms
  `IS_WT` without Step 0, the `in-place-branch.md` hand-off, and the baseline check that establishes the contract; read
  from Step 5 when Step 0 did not fire.
- `references/blocked-write.md` — a delegate's Write blocked by the worktree isolation guard: Step 8 item 1.
- `references/early-exit.md` — the CANCELED and ABANDONED exits: Step 8.5; ABANDONED's return-to-availability mechanics
  from Step 5's auto-mode baseline failure and Step 6 item 4's auto-mode boundary stop.
