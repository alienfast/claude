---
name: full
description: End-to-end Linear issue macro — runs /start then /finish in sequence, gated on the /quality-review verdict. Worktree mode is opt-in via the `wt` token, mirroring /start. Pauses only for plan approval and deferred-items triage; otherwise autonomous. Use when the user says 'full PL-XX', 'ship PL-XX end-to-end', or invokes /full.
---

# Full Issue (Macro)

A thin composition over `/start` and `/finish`. The two underlying skills are individually trustworthy and require user input at only two predictable points — plan approval (Step 6 of `/start`) and deferred-items triage (during `/quality-review`). `/full` removes the manual `/finish` invocation at the end so that, once the deferred-items gate clears with a passing verdict, the issue ships without further input.

Worktree mode is **opt-in**, mirroring `/start`: `/full PL-13` runs in-place on the current branch; `/full wt PL-13` creates and works inside a per-issue worktree. The `wt` token is the single switch — `/full` passes it through to `/start` unchanged.

`/full` does NOT alter any contract of `/start`, `/finish`, or `/quality-review`. It only sequences them and decides whether to invoke `/finish` based on the tagged final line `/start` emits.

## Arguments

```text
/full <ISSUE-ID> [wt] [pr] [no push|don't push|skip push]
```

All tokens are **position-agnostic and case-insensitive** (matching the convention `/start wt` and `/finish` use — `WT`, `Wt`, `PR`, `NO PUSH` are all accepted). Exactly one token must be a valid issue ID; everything else is an optional modifier.

- `<ISSUE-ID>` — required, exactly one. Validated via `~/.claude/scripts/detect-issue-id.sh --validate-only --input <arg>` (enforces `^[A-Z]+-[0-9]+$` after uppercasing). Lowercase IDs (`pl-13`) are accepted; the script uppercases.
- `wt` — optional. Pass-through to `/start`; selects worktree mode. Omit for in-place mode on the current branch.
- `pr` — optional, **worktree-only**. Pass-through to `/finish` Step 3 below; opens a PR instead of merging. Requires `wt` (since `/finish pr` rejects non-worktree mode at `finish-detect-mode.sh` exit 2).
- `no push` / `don't push` / `skip push` — optional. Pass-through to `/finish`; commit still happens, push is skipped. Compatible with both modes (worktree-merge accepts `no push` implicitly via the macro's gating in Step 3; worktree-pr does not — see fail-fast below).
- Any other token — error. Surface: `Unrecognized argument 'X'. /full accepts <ISSUE-ID>, optionally with 'wt', 'pr', or a 'no push' variant.`

**Fail-fast validation — catch incompatible combinations before invoking `/start`.** These are mechanical refusals (errors, not interactive prompts), so they do NOT violate the "two gates only" design constraint:

1. **`pr` without `wt`** — refuse: `/full pr requires worktree mode. Add 'wt' or remove 'pr'.` (`/finish pr` is worktree-only by contract; without `wt`, the macro would invoke `/start` in-place, succeed, then crash at `/finish` after the user already spent N minutes on plan approval and review.)
2. **`pr` + `no push`** — refuse: `/finish pr requires pushing the branch. Remove 'no push' or use plain /full <ISSUE-ID> [wt].`
3. **Multiple issue IDs** — refuse: `/full accepts exactly one issue identifier.`

Examples: `/full PL-13` (in-place), `/full wt PL-13` (worktree merge), `/full wt PL-13 pr` (worktree PR), `/full PL-13 no push` (in-place, commit only), `/full wt PL-13 no push` (worktree merge, commit only), `/full WT pl-13` (case-insensitive, position-agnostic, lowercase ID).

## Workflow

### Step 1: Invoke /start

Compose the args string for `/start`:

- If the user passed `wt`: `args = "wt <ISSUE-ID>"` (worktree mode).
- Otherwise: `args = "<ISSUE-ID>"` (in-place mode on the current branch).

**Dispatch via the Skill tool.** Call `Skill(skill: "start", args: <args>)` directly — do NOT emit the literal `/start ...` as chat text. Slash commands in chat output are not re-parsed by the harness; they render as plain text and the skill never runs. The Skill tool is the only programmatic invocation path. (`/start` Step 9 invokes `/quality-review` the same way.)

Do NOT inline `/start`'s workflow text into this skill's execution context — that would skip dispatch and bypass plan mode's tool flow. Do NOT pass `pr` or `no push` tokens through — those are `/finish` arguments and `/start` will reject unknown tokens.

`/start` runs end-to-end:

1. Worktree setup (only in `wt` mode, via `start-wt-setup.sh`); branch creation in both modes
2. Context gathering, blocker check, assignment, baseline `pnpm check`
3. **Gate 1 — plan approval via `EnterPlanMode`/`ExitPlanMode`** (user input)
4. Implementation via delegation
5. `/quality-review` invocation
6. **Gate 2 — deferred-items triage inside `/quality-review`** (user input, sub-steps 4 and 6)
7. Step 10 tagged final line

`/full` does not narrate progress, does not inject extra prompts, and does not race ahead. The next `/full` step does not begin until `/start` has emitted its tagged final line — that is, the LAST LLM-authored line of `/start`'s output, after any intermediate `IN-PROGRESS` lines from sub-skills like `/checkpoint`.

**Step 1 → Step 2 transition is automatic, not user-prompted.** When the `Skill(skill: "start", ...)` call returns, the `/full` orchestrator MUST immediately proceed to Step 2, parse the tagged final line, and (on `READY-FOR-FINISH`) dispatch Step 3 — no user confirmation, no "ready to finish?" prompt, no pause. The whole point of the macro is automation across this boundary. If the orchestrator finds itself unsure what to do after `/start` returns, the answer is always "proceed to Step 2", never "ask the user".

**Session interruption between Step 1 and Step 3.** If the session is killed between `/start` emitting `READY-FOR-FINISH` and `/full` dispatching `/finish` (terminal closed, machine slept, overnight pause, etc.), the `/full` orchestrator is dead and cannot resume on its own. The user must dispatch `/finish` manually — typing `/finish <ISSUE-ID> [merge]` (with `merge` if the issue was started in `wt` mode) at the prompt picks up cleanly: `/finish` Step 1.5 reads the persisted `tmp/quality-review-verdict-<issue-id-lowercased>.md` written by `/quality-review`, and Step 8's gate proceeds without re-running the review. Re-invoking `/full <ISSUE-ID> [wt]` is **not** the right recovery — it would re-run all of `/start` (plan mode, implementation, review) on an already-completed issue.

### Step 2: Branch on /start's tagged final line

`/start` always ends with exactly one tag per `~/.claude/standards/lifecycle-tags.md`. Parse the first token of the final line. Mechanical mapping — no LLM judgment:

| Tag from /start | Action |
| --- | --- |
| `READY-FOR-FINISH` | Continue to Step 3. |
| `BLOCKED-ON-REVIEW` | Stop. The tagged line `/start` already emitted is the macro's terminal output — do not re-render it, do not add prose. State unchanged; branch (and worktree, if `wt`) left intact for re-running `/quality-review`, escalating, or filing follow-ups. |
| `CANCELED` | Stop. Inherit `/start` Step 8.5's behavior. In `wt` mode the cleanup commands are surfaced (not auto-run) so any uncommitted scratch notes in the worktree survive. In non-`wt` mode there is no worktree to clean; the branch remains until the user disposes of it. |
| `ABANDONED` | Stop. `/start` Step 8.5 deliberately preserves session state for resumption (worktree in `wt` mode, branch in either). Do not clean up. |
| `IN-PROGRESS` | Unexpected at `/start` completion (this tag is `/checkpoint`'s). Stop and surface as anomaly. State preserved for resumption; do not clean up. |
| Anything else / missing | Stop. The unrecognized line `/start` emitted IS the macro's terminal output — do **not** synthesize a new `BLOCKED-ON-REVIEW: ...` line on top of it. Doing so would (a) lie about the emitter (`lifecycle-tags.md` does not list `/full` as a tag authority), and (b) push `/start`'s real last-line off-screen of the agents-list parser. Surface the anomaly in chat *preceding* the unrecognized line if you want, but the unrecognized line stays the terminal LLM-authored output. |

The macro does NOT prompt the user on non-pass tags. The whole point of `/full` is autonomous flow when things go well; on non-pass paths it stops cleanly and lets the user drive the recovery (`/quality-review`, manual `/finish`, escalation, or cleanup).

### Step 3: Invoke /finish (only on READY-FOR-FINISH)

**Cwd safety check (worktree mode only).** Skip this paragraph entirely in non-`wt` mode — there is no worktree to be in, and `/finish` will run from the current branch as expected. When `wt` is in effect, `/start` Step 0 sub-step 2 `cd`s into the worktree at `<WT_ABS>`. The Bash tool's cwd persists across tool calls within a single session, but if cwd has been lost (verify with `pwd`), `cd '<WT_ABS>'` back into it before dispatching `/finish`. The `start.source-branch` config is recorded at per-worktree scope only (`/start` Step 0 sub-step 1, "Foot-gun warning" paragraph); running `/finish` from the main checkout would make `finish-detect-mode.sh` see no source branch, fall into the standard (non-worktree) flow, and surface `/finish` Step 1's "Cross-worktree sanity check" prompt — an unexpected user prompt the macro is supposed to avoid.

Compose the args string for `/finish` based on mode:

- **Non-`wt` mode** — `args = "<ISSUE-ID>"`. Append ` no push` if the user passed it.
- **`wt` mode without `pr`** — `args = "<ISSUE-ID> merge"`. Append ` no push` if the user passed it. Pass `merge` explicitly even though it is `/finish`'s worktree default — keeps the dispatch self-documenting. (`/finish` Step 0 short-circuits when `SOURCE_BRANCH` is set anyway.)
- **`wt` mode with `pr`** — `args = "<ISSUE-ID> pr"`. No `no push` is possible here (fail-fast in Arguments rejects the combination upstream).

**Dispatch via the Skill tool.** Call `Skill(skill: "finish", args: <args>)` — same mechanism as Step 1, not chat-text emission. `/finish` handles everything from here:

- Mode detection (`finish-detect-mode.sh`)
- Issue ID resolution
- Quality-review verdict re-validation (already passing — `/start` would not have emitted `READY-FOR-FINISH` otherwise; the stale-verdict prompt is a rare reach in this flow but `/finish` Step 8 handles it directly with the user if it fires)
- Completion comment composition + description update
- `pnpm check` gate
- Commit + (conditional) push
- State transition to `Ready For Release`
- Merge serialization across parallel `/finish merge` sessions on the same parent repo (`scripts/with-repo-lock.py`) — `wt` mode only
- Worktree removal (`wt` merge) or `gh pr create` (`wt` pr); no worktree touch in non-`wt` mode

**`/finish` terminal-tag handling.** Mechanical mapping for whatever tag `/finish` emits — `/full` does not interpret, does not wrap. Which tags are legitimate depends on mode:

| Tag from /finish | Legitimate in | Action |
| --- | --- | --- |
| `RELEASED` | Non-`wt` mode (`/finish` Step 8 "termination contract" enumeration, first bullet — non-worktree happy path) | Stop. Terminal. Issue moved to `Ready For Release`; no worktree to clean. **Anomaly in `wt` mode** — should not occur because `/start wt` recorded a source branch; if it does (e.g., per-worktree git config lost, or `cd` safety check was skipped), the issue did still transition cleanly — stop, treat as terminal, surface the unexpected mode in chat. |
| `SHIPPED-MERGE` | `wt` mode without `pr` (`/finish` Step 9 `ACTION == "merge"` block) | Stop. Terminal. Worktree removed by `/finish`. **Anomaly in non-`wt` mode** — should not occur because `finish-detect-mode.sh` exit 2 would have rejected `merge`. |
| `SHIPPED-PR` | `wt` mode with `pr` (`/finish` Step 9 `ACTION == "pr"` block) | Stop. Terminal. Worktree preserved by `/finish` (PR is the lifecycle boundary). **Anomaly in non-`wt` mode** — same as above. |
| `BLOCKED-ON-REVIEW` | Either mode | Stop. Terminal. State unchanged; branch (and worktree, if `wt`) intact. (E.g., user picked `abort` at the stale-verdict prompt, or `linear issues update` failed.) |

That tagged line is `/full`'s terminal output. Do not wrap it, do not add a closing summary, do not re-emit the issue title.

### No Step 4

`/full` is a pure passthrough macro. The last line the user sees is whichever skill last spoke (`/start` on non-pass, `/finish` on pass). The agents-list display reads the tagged line directly; an extra summary line above it just pushes the tag off-screen.

## Edge cases

- **Resumption on a paused issue.** `/start` is idempotent on the same issue (existing branch + In Progress state in both modes; recorded source branch in `wt` mode — see `/start` Step 5's short-circuit and Step 8's resumption note). Re-running `/full [wt] PL-13` on a paused (still `In Progress`) issue picks up where `/start` left off, then proceeds normally.
- **Mode switch across re-runs.** If `/full wt PL-13` paused and the user re-runs `/full PL-13` (no `wt`), `/start` would attempt in-place resumption on the *current* branch — which is whatever the user's cwd is on, not the worktree's branch. This either no-ops (already on the issue's branch via a separate checkout) or creates duplicate state. **Recommendation:** keep the mode consistent across re-runs of the same issue.
- **Re-run after a successful `/full`.** If the issue has already moved to `Ready For Release` or `Done`, `/start`'s Error Handling fires ("If the issue is already Done or Ready For Release, warn the user and ask if they want to reopen it"). That's a third user prompt beyond plan approval and deferred-items triage — narrowly tolerable as it only fires on misuse. The macro inherits the prompt; do not bypass it.
- **Non-`wt` `/full` invoked from inside an existing worktree directory.** Operator error: the user's cwd is `.claude/worktrees/pl-99/` (a leftover from a separate `/start wt PL-99` session) and they type `/full PL-13` (no `wt`). `finish-detect-mode.sh` will see PL-99's `start.source-branch` config, default `ACTION` to `merge`, and try to merge a foreign worktree branch — the issue-ID mismatch surfaces only through `/finish` Step 1's cross-worktree sanity check, but the user is already in a foreign worktree so the warning text is misleading. **Recommendation:** run non-`wt` `/full` only from the main checkout, not from any `.claude/worktrees/*` directory.
- **Session killed between `/start` finishing and `/finish` dispatching.** The macro orchestrator is dead and cannot resume on its own (terminal closed, machine slept, overnight pause). See Step 1's "Session interruption" paragraph for the recovery: type `/finish <ISSUE-ID> [merge]` manually. Do NOT re-invoke `/full` — it would re-run the entire `/start` workflow on an already-finished issue.
- **User aborts plan approval.** Plan mode just doesn't exit. The macro never reaches Step 2. Nothing special to do.
- **`/quality-review` returns `escalated-to-architect`.** `/start` Step 10 maps this to `BLOCKED-ON-REVIEW`. Macro stops at Step 2 with the inherited tag; the architect's recommendation is already in chat per `/start` Step 9.
- **Stale-verdict prompt in `/finish` Step 8.** `/finish` itself handles the override/re-run/abort prompt. The macro doesn't intervene. Stale verdict is uncommon in this flow because `/start` just produced the verdict and HEAD typically hasn't moved.
- **Merge conflict in `/finish` Step 9** (`wt` merge mode only). `/finish` resolves it inline using `with-repo-lock.py`-wrapped git mutations. The macro doesn't intervene.
- **Concurrent `/full` runs on DIFFERENT issues, `wt` mode.** Each session's `/start wt` creates its own worktree (isolated). Each session's `/finish merge` self-serializes via the parent-repo lock — `[finish-queue] waiting for <REPO_ROOT> ...` may print on stderr; surface as-is and wait.
- **Concurrent `/full` runs on DIFFERENT issues, non-`wt` mode.** Both sessions share the same checkout. The user is responsible for ensuring each session is on the correct branch (e.g., separate terminals after explicit `git checkout`). The macro provides no serialization here — running two non-`wt` `/full` sessions in the same checkout is risky and not recommended.
- **Concurrent `/full` runs on the SAME issue.** Both sessions will succeed at `/start` (idempotent reuse of branch and, in `wt` mode, worktree), but their plans, implementations, and reviews will diverge — comments and description updates get posted twice, and the two sessions race on the same branch. The first to reach `/finish` wins (merge lock in `wt` merge mode; bare race in other modes); the loser hits a precondition failure and emits a confusing `BLOCKED-ON-REVIEW`. **Recommendation:** do not launch two `/full` sessions on the same issue. If you must, `/checkpoint`-and-stop one (and manually update Linear state if needed) before letting the other proceed.

## Error Handling

- **Missing issue ID** — error: `/full requires an issue identifier (e.g., /full PL-13 or /full wt PL-13).`
- **Invalid issue ID format** — defer to `detect-issue-id.sh --validate-only` and surface its stderr.
- **Multiple issue IDs** — error: `/full accepts exactly one issue identifier.`
- **`pr` without `wt`** — error: `/full pr requires worktree mode. Add 'wt' or remove 'pr'.` See Arguments fail-fast rule 1.
- **`pr` + `no push`** — error: `/finish pr requires pushing the branch. Remove 'no push' or use plain /full <ISSUE-ID> [wt].` See Arguments fail-fast rule 2.
- **`/start` errors mid-flight (e.g., baseline `pnpm check` fails, worktree setup fails in `wt` mode)** — those are `/start`'s contracts to surface. The macro never reaches Step 2; nothing to do.
- **`/finish` errors mid-flight (e.g., merge precondition failure, `linear issues update` fails)** — those are `/finish`'s contracts to surface (BLOCKED-ON-REVIEW with the failure reason). The macro does not re-attempt.
