---
name: full
description: End-to-end Linear issue macro — runs /start, then /finish, gated on the /quality-review verdict. Tokens are `wt` (worktree mode), `auto` (unattended; what /auto dispatches — the token is defined here, in § Auto mode), `simple` (light review tier), `pr` and `push`. Use when the user says 'full PL-XX', 'ship PL-XX end-to-end', or invokes /full.
---

# Full Issue (Macro)

A thin composition over `/start` and `/finish`. The two underlying skills need user input at only two predictable
points — plan approval (`/start` Step 6) and the deferred-items filing decision (inside `/quality-review`, and only when
there are non-trivial items to file; trivial `fix-now` and `note-only` items are handled with no prompt). `/full`
removes the manual `/finish` invocation at the end, so once the review verdict passes the issue ships without further
input.

Worktree mode is **opt-in**, mirroring `/start`: `/full PL-13` runs in place on the current branch; `/full wt PL-13`
creates and works inside a per-issue worktree. `wt` is the single switch and passes through to `/start` unchanged.

`/full` does NOT alter any contract of `/start`, `/finish`, or `/quality-review`. It only sequences them and decides
whether to invoke `/finish` from the tagged final line `/start` emits.

**Handoff reliability is enforced by a Stop hook, not by skill prose.** The failure mode for this macro is the
orchestrator reading `/start`'s `READY-FOR-FINISH` line as a turn-ending summary and stopping before it dispatches
`/finish`. The `hooks/full-continue.sh` Stop hook detects exactly that state — an in-flight `/full` at
`READY-FOR-FINISH` with no `Skill(finish)` dispatched — blocks the stop and re-issues the dispatch (self-clearing once
`/finish` runs in any form; bounded retries). Because the hook is the safety net, Steps 1–3 are a plain linear flow with
**no** in-prose anti-stop scaffolding (no priming a task list, no state-signal flag); do not re-add any.

## Auto mode

The `auto` token makes every prompt in `/start`, `/quality-review` and `/finish` resolve to its documented conservative
default instead of asking: no plan approval (`/start auto` posts the plan to Linear as the audit record), no
deferred-items question (`/quality-review auto` files the `suggested` deferred group), and abort rather than override
at every `/finish` gate. Each skill lists only its own per-prompt defaults; this section is the token's one definition.
`/full auto` is a pure pass-through — the token goes to `/start` and `/finish`, and reaches `/quality-review` through
`/start` Step 9. The `/auto` loop runs `/full auto`, and that invocation carries the commit/push grant
(`standards/git.md`).

## Arguments

```text
/full <ISSUE-ID> [wt] [auto] [simple] [pr] [push]
```

All tokens are **position-agnostic and case-insensitive** (`WT`, `Wt`, `AUTO`, `PR`, `PUSH` are all accepted). Exactly
one token must be a valid issue ID; everything else is an optional modifier.

- `<ISSUE-ID>` — required, exactly one. Validated via `~/.claude/scripts/detect-issue-id.sh --validate-only --input
  <arg>` (`^[A-Z]+-[0-9]+$` after uppercasing; `pl-13` is accepted).
- `wt` — pass-through to `/start`; selects worktree mode. Omit for in-place mode on the current branch.
- `auto` — pass-through to BOTH `/start` and `/finish` (§ Auto mode). Compatible with every other token.
- `simple` — pass-through to `/start`, which forwards it to `/quality-review` at its Step 9; selects the simple review
  tier ([standards/issue-spec.md](../../standards/issue-spec.md) § The `simple` label). The issue's `simple` label
  implies it without the token.
- `pr` — pass-through to `/finish` (Step 3); opens a PR instead of the default finalize. Works in both modes: with `wt`
  the PR base is the recorded source branch and the worktree is preserved; without `wt` the base is the repo's default
  branch. The issue is marked `Ready For Release` once the PR is open — an open PR is work waiting for its release.
- `push` — pass-through to `/finish`; pushes the branch after the commit. **The default is no push** — the commit stays
  local and `/finish`'s closing message names the push. Meaningful only in place without `pr`: `pr` already implies the
  push (the token is accepted and not forwarded), and `wt` without `pr` is a merge, which never pushes — see fail-fast
  below. `no push` / `don't push` / `skip push` restate the default: accepted, nothing forwarded.
- Any other token — error: `Unrecognized argument 'X'. /full accepts <ISSUE-ID>, optionally with 'wt', 'auto',
  'simple', 'pr', or 'push'.`

**Fail-fast validation — before invoking `/start`.** Mechanical refusals (errors, not prompts), so they do not add a
third gate:

1. **`wt` + `push` without `pr`** — refuse: `/finish merge never pushes: the merge commit reaches origin when the source
   branch is pushed. Remove 'push' or add 'pr'.`
2. **Multiple issue IDs** — refuse: `/full accepts exactly one issue identifier.`

Examples: `/full PL-13` (in place, commit only), `/full PL-13 push`, `/full PL-13 pr` (in-place PR to the default
branch), `/full wt PL-13` (worktree merge), `/full wt PL-13 pr` (worktree PR), `/full WT pl-13`, `/full PL-13 simple`.

## Workflow

### Step 1: Invoke /start

Compose `/start`'s args from the mode:

- `wt` mode → `args = "wt <ISSUE-ID>"`; in place → `args = "<ISSUE-ID>"`
- `auto` → prepend `auto ` to either form (`"auto wt <ISSUE-ID>"`)
- `simple` → append ` simple` (`/start` also infers it from the issue's label, so omitting it is never an error)

Do NOT pass `pr` or `push` — those are `/finish` arguments and `/start` rejects unknown tokens.

**Dispatch via the Skill tool.** Call `Skill(skill: "start", args: <args>)` — do NOT emit the literal `/start ...` as
chat text (slash commands in chat output are not re-parsed; the skill never runs), and do NOT inline `/start`'s workflow
text into this context (that bypasses dispatch and plan mode's tool flow). `/start` Step 9 invokes `/quality-review`
the same way.

`/start` runs end-to-end: worktree setup (`wt` only) and branch creation; context, blocker check, assignment, baseline
`pnpm check`; **Gate 1 — plan approval** via `EnterPlanMode`/`ExitPlanMode`; implementation via delegation;
`/quality-review`; **Gate 2 — deferred-items filing** inside `/quality-review`; the Step 10 tagged final line.

Wait for `/start`'s tagged final line — the LAST LLM-authored line of its output, after any intermediate `IN-PROGRESS`
lines from sub-skills like `/checkpoint` — before beginning Step 2.

### Step 2: Branch on /start's tagged final line

`/start` always ends with exactly one tag per `standards/lifecycle-tags.md`. Parse the first token of the final line —
mechanical mapping, no judgment. The macro never prompts on a non-pass tag: on those paths it stops cleanly and lets the
user drive recovery (`/quality-review`, manual `/finish`, escalation, cleanup).

| Tag from /start | Action |
| --- | --- |
| `READY-FOR-FINISH` | Continue to Step 3. |
| `SKIPPED-BLOCKED` | Stop. Terminal, and **expected in auto mode** — `/start auto` emits it instead of the blocker/reassign/reopen prompts. Nothing was claimed or modified. `/auto` treats it as a skip. |
| `BLOCKED-ON-REVIEW` | Stop. The tagged line `/start` emitted is the macro's terminal output — do not re-render it or add prose. State unchanged; branch (and worktree, if `wt`) left intact. |
| `CANCELED` | Stop. Inherit `/start` Step 8.5: in `wt` mode cleanup commands are surfaced, not auto-run, so uncommitted scratch survives; in place the branch remains until the user disposes of it. |
| `ABANDONED` | Stop. `/start` Step 8.5 preserves session state for resumption. Do not clean up. |
| `IN-PROGRESS` | Unexpected at `/start` completion (this tag is `/checkpoint`'s). Stop and surface as an anomaly; state preserved. |
| Anything else / missing | Stop. The unrecognized line IS the macro's terminal output — do **not** synthesize a `BLOCKED-ON-REVIEW: ...` line on top of it (`lifecycle-tags.md` does not list `/full` as a tag authority, and a new line pushes `/start`'s real last line off the agents-list parser). Surface the anomaly in chat *before* the line if needed. |

### Step 3: Invoke /finish (only on READY-FOR-FINISH)

**Cwd safety check (worktree mode only).** In `wt` mode `/start` Step 0 entered the worktree at `<WT_ABS>` via
`EnterWorktree` (cwd and isolation root). If cwd has been lost (`pwd`), `cd '<WT_ABS>'` before dispatching `/finish` —
the isolation registration persists at session level and needs no re-entry. `start.source-branch` is recorded at
per-worktree scope only, so `/finish` run from the main checkout falls into the standard flow and surfaces `/finish`
Step 1's cross-worktree sanity prompt, which the macro is supposed to avoid.

Compose `/finish`'s args (in `auto` mode, prepend `auto ` to every form):

**The flow is the caller's, not yours.** `pr` appears below only because the macro was *given* `pr`; never add it because
recent issues shipped as PRs, a `CLAUDE.md` says so, or a PR seems safer. Absent the token, `wt` mode is `merge`.

- **In place, no `pr`** — `args = "<ISSUE-ID>"`, plus ` push` if passed. Standard flow: commit (pushed only under
  `push`), mark `Ready For Release`.
- **In place with `pr`** — `args = "<ISSUE-ID> pr"`. PR against the default branch; `pr` implies the push.
- **`wt` without `pr`** — `args = "<ISSUE-ID> merge"`. Never append ` push`. Pass `merge` explicitly even though it is
  `/finish`'s worktree default, to keep the dispatch self-documenting.
- **`wt` with `pr`** — `args = "<ISSUE-ID> pr"`. `pr` implies the push.

**Dispatch via the Skill tool** — `Skill(skill: "finish", args: <args>)`. `/finish` owns everything from here: mode
detection, issue-ID resolution, verdict re-validation (its Step 8 handles a stale verdict with the user if it fires),
completion comment and description update, the `pnpm check` gate, commit and conditional push, the state transition,
merge serialization across parallel `/finish merge` sessions (`scripts/with-repo-lock.py`, `wt` only), and worktree
removal (`wt` merge) or `gh pr create` with a `/pr-update` title and body.

**`/finish` terminal-tag handling** — mechanical, uninterpreted. Which tags are legitimate depends on mode:

| Tag from /finish | Legitimate in | Action |
| --- | --- | --- |
| `RELEASED` | In place without `pr` | Stop. Issue is `Ready For Release`; no worktree. Anomaly in `wt` mode (source branch lost) or when `pr` was passed (expected `SHIPPED-PR`) — still terminal; surface the mismatch. |
| `SHIPPED-MERGE` | `wt` without `pr` | Stop. Worktree removed by `/finish` — or, on a `CLEANUP-FAILED:` from `finish-merge.sh`, left on disk and named in the tag (still a ship; the reaper reports it until cleared). Anomaly in place. |
| `SHIPPED-PR` | Either mode with `pr` | Stop. The PR is the lifecycle boundary; in `wt` mode the worktree is preserved for post-merge cleanup. Anomaly when `pr` was NOT passed — terminal; surface the mismatch. |
| `DEFERRED-MERGE` | `wt` without `pr` (`finish-merge.sh` exit 3) | Stop. A transient block; self-enqueued to the local merge queue, which a launchd drainer retries until it lands and then marks Ready For Release. Issue **remains In Progress**; worktree intact. **Self-resolving — do NOT retry `/finish` or touch other sessions' changes.** Anomaly in place. |
| `BLOCKED-ON-RECOVERY` | `wt` (`finish-detect-mode.sh` exit 4) | Stop. The worktree no longer matches its stamped identity (hijacked by a parallel session, or rewritten without `wt-restamp.sh`), and the user declined recovery or `finish-recover.sh` could not complete. State unchanged; worktree preserved. **No auto-retry** — recovery is confirm-gated. (A successful recovery emits `SHIPPED-MERGE`.) |
| `BLOCKED-ON-REVIEW` | Either mode | Stop. State unchanged; branch (and worktree) intact — e.g. `abort` at the stale-verdict prompt, or a failed `linear-cli issues update`. |

That tagged line is `/full`'s terminal output: no wrap, no closing summary, no re-emitted title. "Stop. Terminal."
means `/full` adds nothing after the tag — not that the turn must end there (the Nesting rule in
`standards/lifecycle-tags.md`): standalone, stop; under `/auto`, control returns to `/auto` Step 4 in the same turn, and
ending the turn on the tag instead kills a self-paced loop.

### No Step 4

The last line the user sees is whichever skill last spoke. The agents-list display reads the tagged line directly; a
summary line above it pushes the tag off-screen.

## Edge cases

- **Resumption on a paused issue.** `/start` is idempotent on the same issue (existing branch + In Progress; recorded
  source branch in `wt` mode). Re-running `/full [wt] PL-13` on a paused issue picks up where `/start` left off.
- **Mode switch across re-runs.** `/full wt PL-13` paused, then `/full PL-13` resumes in place on the *current* branch —
  whatever the cwd is on — and either no-ops or creates duplicate state. Keep the mode consistent across re-runs.
- **Re-run after a successful `/full`.** An issue already `Ready For Release` or `Done` fires `/start`'s reopen prompt —
  a third prompt, tolerable because it only fires on misuse. Do not bypass it.
- **In-place `/full` from inside a worktree directory.** `finish-detect-mode.sh` sees that worktree's `start.source-branch`,
  defaults to `merge`, and tries to merge a foreign branch; the mismatch surfaces only through `/finish` Step 1's
  sanity check with misleading text. Run in-place `/full` only from the main checkout.
- **Session killed between `/start` and `/finish`.** While alive, the Stop hook prevents the stall. If the session is
  dead, recover with `/finish <ISSUE-ID> [merge]` by hand (`merge` for a `wt` issue): `/finish` Step 1.5 reads the
  persisted `tmp/quality-review-verdict-<issue-id-lowercased>.md` and proceeds without re-running the review. Do NOT
  re-invoke `/full` — it re-runs all of `/start` on a completed issue.
- **User aborts plan approval.** Plan mode just doesn't exit; the macro never reaches Step 2.
- **`/quality-review` returns `escalated-to-architect`.** `/start` Step 10 maps it to `BLOCKED-ON-REVIEW`; the
  architect's recommendation is already in chat.
- **Stale-verdict prompt / merge conflict in `/finish`.** `/finish` handles both (conflicts are resolved in the
  worktree, then `finish-merge.sh` re-runs). The macro doesn't intervene.
- **Concurrent `/full` runs on DIFFERENT issues, `wt` mode.** Each worktree's setup self-serializes under the parent-repo
  lock (`start-wt-create.sh` under `with-repo-lock.py`, the key `/finish merge` uses), closing the create race that let
  parallel sessions clobber each other's branch/HEAD/config; `/start wt` may print `[finish-queue] waiting for
  <REPO_ROOT> ...` — surface and wait. For many parallel runs, park the main checkout on a detached branch
  (`git checkout --detach`), not the shared source branch, so every merge takes `finish-merge.sh`'s ref-only fast path
  (`standards/git-worktrees.md` § Posture for high-concurrency runs); `start-wt-setup.sh` warns when it sees otherwise.
- **Concurrent `/full` runs on DIFFERENT issues, in place.** Both sessions share one checkout and the macro provides no
  serialization; the user owns branch correctness. Not recommended.
- **Concurrent `/full` runs on the SAME issue.** The second session reuses the worktree (same branch name) or refuses
  with `exists but is on '<other>'`; but plans, implementations and reviews diverge, comments post twice, and the
  sessions race on one branch. A reset of one by the other is detected at `/finish` (the identity sidecar no longer
  matches) and routed to confirm-gated recovery (`BLOCKED-ON-RECOVERY`) instead of shipping a hijacked tree. Do not
  launch two; if you must, `/checkpoint`-and-stop one first.
- **`wt`-mode isolation is best-effort.** `EnterWorktree`'s registration can silently fail to bind a delegate's writes
  to the worktree, so a delegate's success report is not evidence its writes landed there
  (`standards/git-worktrees.md` § Delegation placement). `/start` Step 8 carries the READ-SCOPING / WRITE-PLACEMENT
  scoping and the dirty-in-worktree confirmation. Never disable the isolation guard (`worktree.bgIsolation: "none"`),
  never weaken settings, never let the orchestrator implement the code itself; a still-blocked delegate write is a
  STOP-and-surface.

## Error Handling

- **Missing issue ID** — `/full requires an issue identifier (e.g., /full PL-13 or /full wt PL-13).`
- **Invalid issue ID format** — defer to `detect-issue-id.sh --validate-only` and surface its stderr.
- **Multiple issue IDs** — `/full accepts exactly one issue identifier.`
- **`wt` + `push` without `pr`** — the fail-fast message above.
- **`/start` or `/finish` errors mid-flight** (baseline `pnpm check` red, worktree setup failure, merge precondition
  failure, a failed `linear-cli issues update`) — those skills surface their own contracts; the macro never reaches the
  next step and does not re-attempt.
