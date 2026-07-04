---
name: finish
description: Finish a Linear issue — check off requirements, add completion comment, commit/push, mark Ready For Release. Autonomous mode via the `auto` token (every prompt resolves to the conservative default — abort, never override; used by /auto). Use when the user says 'finish issue', 'done with this issue', 'complete PL-XX', or invokes /finish.
---

# Finish Issue

Automates the post-completion workflow for a Linear issue using the `linear-cli` CLI. The mechanical steps (worktree-mode detection, issue-ID resolution, Linear posts, git commit/push) are delegated to scripts in `~/.claude/scripts/`; this skill is the orchestrator + LLM-judgment surface (reading the description, composing the completion comment).

## Arguments

- Issue identifier (e.g., `PL-12`) — optional, auto-detected from branch/commit
- `no push` / `don't push` / `skip push` — optional, skips the git push step (commit still happens)
- `merge` — only meaningful inside a `/start wt` worktree. **Default when in a worktree.** Merge the worktree branch back into its recorded source branch, then remove the worktree.
- `pr` — open a pull request for the current branch (works from **any** branch). Inside a `/start wt` worktree the base is the recorded source branch and the worktree is left in place; otherwise the base is the repo's GitHub default branch (in-place — no worktree touched). Optionally apply labels with `with label X` / `label X, Y`. The issue stays `In Progress` (the PR is open, not yet shipped).

- `auto` — optional token (case-insensitive, position-agnostic). **Autonomous mode**: every user prompt in this skill resolves to its conservative default instead of asking — abort rather than override, proceed-without rather than create. Each prompt site below documents its auto default inline. Passed through by `/full auto` for the `/auto` loop; the `/auto` invocation is the commit/push grant (see standards/git.md).

Examples: `/finish`, `/finish PL-12`, `/finish no push`, `/finish PL-12 no push`, `/finish merge`, `/finish auto PL-12 merge`, `/finish pr PL-12`, `/finish pr with label pr-deploy`

## Invariant

**`pnpm check` must pass before committing or pushing code.** Check failures are always CRITICAL — never "pre-existing", never "out of scope", never deferred. Fix them before proceeding. Turborepo caching makes repeated runs cheap.

## Workflow

### Preflight: Exit Plan Mode If Active

If the session is in plan mode when `/finish` is invoked, call `ExitPlanMode` **before any other step**. Every step from Step 0 onward needs Bash, Write, or Edit — all blocked in plan mode — so `finish-detect-mode.sh` would fail on its first call otherwise.

**Detection.** Use the harness's plan-mode indicator visible at skill entry (the same signal that was gating tool calls just before this skill loaded). If that indicator is ambiguous or unavailable, attempt Step 0; if `finish-detect-mode.sh` fails with a plan-mode block, return here, call `ExitPlanMode`, then retry Step 0. Do NOT speculatively call `ExitPlanMode` when plan mode is not active — it raises a spurious approval prompt the user must dismiss.

**Plan body.** Pass a one-line plan summarizing what `/finish` is about to do for the resolved issue. There is nothing to design — `/finish` is a fixed mechanical workflow — but `ExitPlanMode` is the only way to leave plan mode and it requires a plan body. For the `<ISSUE-ID>` substitution: only inline a user-supplied token if it matches `^[A-Z]+-[0-9]+$` (case-insensitive, uppercase it before substituting); otherwise use `the current branch's issue`. This keeps malformed tokens (e.g., `PL13`, stray `merge`/`pr` keywords) out of the plan body and out of any rejection-terminator that echoes the same value.

- Approved by the user: proceed to Step 0.
- Rejected by the user: proceed to the rejection terminator below.
- Tool-error / harness failure (not a user rejection — the tool itself returns an error, or the harness reports `ExitPlanMode` failed for a non-user-cancel reason): surface the error verbatim and stop with `BLOCKED-ON-REVIEW: <ISSUE-ID or "current branch"> — ExitPlanMode failed: <first line of error>. No state change.` Do NOT continue to Step 0; plan mode is still active and Step 0 will compound the failure.

**On user rejection** via the approval UI, treat as an abort and stop with:

```text
BLOCKED-ON-REVIEW: <ISSUE-ID or "current branch"> — user rejected /finish at the plan-mode preflight. No state change.
```

Do not retry, do not re-prompt, do not run any subsequent step. **Skip this preflight only when plan mode is NOT active** — `/finish` is normally invoked from a non-plan session after `/start` or manual development, in which case this section is a no-op.

### Step 0: Detect Worktree Mode

Normalize the user's args before calling the script:

- Look for the `auto` token (case-insensitive, position-agnostic) — it selects autonomous mode for this skill's prompt sites and is NOT passed to the script (its arg contract is `merge|pr|--no-push` only).
- Look for `merge` and `pr` tokens (case-insensitive, position-agnostic) — pass through whichever is present (if both, the script errors).
- Look for `no push` / `don't push` / `skip push` — translate to `--no-push` for the script.
- Look for label requests (`with label X`, `label X, Y`, `--label X`) — collect them into a list and **carry it forward to Step 9** (pr mode only). Labels are NOT passed to the script — its arg contract is `merge|pr|--no-push` only. **If labels were requested but the resolved `ACTION` is not `pr`** (i.e., `merge` or the standard flow), labels have no PR to attach to — warn the user once (`Labels apply only to /finish pr; ignoring: <list>.`) rather than silently dropping them.

```bash
~/.claude/scripts/finish-detect-mode.sh [merge|pr] [--no-push]
```

The script probes worktree state, validates incompatible argument combinations, and emits these `KEY=value` lines on stdout: `ACTION`, `SOURCE_BRANCH`, `WORKTREE_BRANCH`, `WT_DIR`, `REPO_ROOT`, `NO_PUSH`, plus `CORRUPTION` and `IDENTITY_SOURCE` (and, only on exit 4, `CORRUPTION_REASON` / `EXPECTED_BRANCH` / `EXPECTED_BASELINE` / `EXPECTED_SOURCE_BRANCH` — see exit 4 above and Step 0.5). **Read those values and carry them forward** — Step 9 substitutes them into bash commands as literal strings (each Bash tool call is a fresh shell).

**Exit codes:**

- 1 — incompatible args (e.g., `merge` + `pr`, or `pr` + `no push`). Surface the error and stop.
- 2 — `merge` requested outside a `/start wt` worktree. Surface and stop. (`pr` is **not** rejected here — it works from any branch; see below.)
- 4 — **worktree corruption detected.** A parallel session hijacked this worktree (branch swapped, HEAD reset off its stamped baseline, or `start.source-branch` config wiped) while the immune identity sidecar still proves it's a `/start wt` worktree — the PL-454/PL-460 failure mode. The script emits `CORRUPTION=1`, `CORRUPTION_REASON`, `IDENTITY_SOURCE`, and `EXPECTED_BRANCH` / `EXPECTED_BASELINE` / `EXPECTED_SOURCE_BRANCH` alongside the usual context. **Do NOT run the normal flow** — merging would ship a hijacked tree. Jump straight to **Step 0.5**, carrying those `EXPECTED_*` values forward.

When `SOURCE_BRANCH` is set (we're in a worktree), the script defaults `ACTION` to `merge`; `/finish pr` is the way to opt into the PR flow with `base = SOURCE_BRANCH`. Outside a worktree, `pr` is allowed (it emits `ACTION=pr` with an empty `SOURCE_BRANCH`, and Step 9 targets the repo's default branch), while `merge` is rejected (exit 2).

If both `SOURCE_BRANCH` and `ACTION` are empty, this is the standard `/finish` flow.

### Step 0.5: Worktree Corruption Recovery (only when `finish-detect-mode.sh` exits 4)

A parallel `/start wt` session reset this worktree out from under us — exactly what happened to PL-454 and PL-460 when ~8 `/full wt` ran in parallel. The session's intended work is typically uncommitted edits that survived the reset, recoverable by `finish-recover.sh`: it salvages that work to a patch, re-forks a fresh branch off the **current** source tip, re-applies, gates on `pnpm check`, commits, and merges.

**Posture: detect-and-stop with ONE confirmation.** Recovery infers which-files-are-mine heuristically when the branch was reset, so never run it unattended. **Auto mode:** do not ask and do not recover — stop immediately with `BLOCKED-ON-RECOVERY: <ISSUE-ID> — worktree hijacked (<CORRUPTION_REASON>); recovery requires a human. Corrupted worktree preserved at <WT_DIR>.`

1. **Surface the corruption** from Step 0's output: `CORRUPTION_REASON`, `IDENTITY_SOURCE`, `EXPECTED_BRANCH` vs the current `WORKTREE_BRANCH`, `EXPECTED_BASELINE`, `EXPECTED_SOURCE_BRANCH`. State plainly what recovery will do (salvage → fresh `.claude/worktrees/<id>-recovered` off `EXPECTED_SOURCE_BRANCH` → re-apply → `pnpm check` → commit → merge → retire the corrupted worktree).

2. **Ask the user (single message, then wait):**

   > Worktree for `<ISSUE-ID>` was hijacked by a parallel session (`<CORRUPTION_REASON>`). Recover automatically? Reply `yes` to run `finish-recover.sh`, or `abort` to stop and inspect manually.

   On `abort`: stop with `BLOCKED-ON-RECOVERY: <ISSUE-ID> — worktree hijacked (<CORRUPTION_REASON>); recovery declined. Corrupted worktree preserved at <WT_DIR>.` No state change. Do not run any further step.

3. **On `yes`:** Write the work-commit message (must contain the issue ID, e.g. `PL-13: <summary>`) to `<REPO_ROOT>/tmp/finish-commit-<issue-id-lowercased>.md` using the **Write** tool (absolute path). Then run from the MAIN checkout:

   ```bash
   cd '<REPO_ROOT from Step 0>'
   ~/.claude/scripts/finish-recover.sh '<WT_DIR>' '<EXPECTED_BASELINE>' '<EXPECTED_SOURCE_BRANCH>' '<EXPECTED_BRANCH>' '<REPO_ROOT>/tmp/finish-commit-<issue-id-lowercased>.md'
   ```

   Route on `finish-recover.sh`'s exit code (it prints `RECOVER_DIFF_STRATEGY=<strategy>` on stderr — quote it in the closing line):

   - **0** — recovered + merged. The merge owns the Ready-For-Release transition (as in Step 9 exit-0): run `~/.claude/scripts/mark-ready-for-release.sh <ISSUE-ID>`, then emit `SHIPPED-MERGE: <ISSUE-ID> — worktree was hijacked; work salvaged (<strategy>), re-forked off <EXPECTED_SOURCE_BRANCH>, merged, Ready For Release.` Terminal.
   - **2** — conflict applying/merging in `.claude/worktrees/<id>-recovered`. Resolve there (read the conflicted files listed on stderr, fix, `git -C '.claude/worktrees/<id>-recovered' add <files>`, `pnpm check`), then **re-run the same `finish-recover.sh` line** (it resumes the recovered worktree). If genuinely unresolvable, emit `BLOCKED-ON-RECOVERY: <ISSUE-ID> — recovery conflict in .claude/worktrees/<id>-recovered; resolve and re-run finish-recover.sh.`
   - **3** — merge deferred to the queue (transient). Emit `DEFERRED-MERGE: <ISSUE-ID> — recovered work queued (<reason>); will retry automatically. Check with /merge-queue.` (The drainer marks Ready For Release when it lands.)
   - **4** — `pnpm check` failed in the recovered worktree. Emit `BLOCKED-ON-RECOVERY: <ISSUE-ID> — pnpm check failed in the recovered worktree; fix in .claude/worktrees/<id>-recovered and re-run finish-recover.sh.`
   - **1** — setup failure (source branch gone, nothing salvageable). Surface the script's stderr and emit `BLOCKED-ON-RECOVERY: <ISSUE-ID> — recovery setup failed: <first stderr line>. Inspect <WT_DIR> manually.`

Step 0.5 is terminal for the corruption case — do NOT continue to Steps 1–9. (The work being recovered is the same code `/quality-review` already passed in `/start`, so no separate verdict gate runs here; the user's `yes` is the gate.)

### Step 1: Identify the Issue

```bash
~/.claude/scripts/detect-issue-id.sh [--input <USER-SUPPLIED-ID>]
```

The script tries `--input` → current branch → latest commit subject, in that order. Pass `--input` only when the user typed an explicit ID (e.g., `/finish PL-12`). On exit 1, ask the user for the identifier explicitly.

**Cross-worktree sanity check (standard-flow only).** After the issue ID is resolved, if the standard flow was detected in Step 0 (`ACTION` empty — no worktree config and no explicit `pr`) but the issue's branch exists in a known linked worktree of this repo (`git worktree list` shows a path whose basename or branch contains `<issue-id-lowercased>`, e.g., `pl-13`), warn the user before continuing:

> Issue `<ISSUE-ID>` appears to live in worktree `<path>`. Are you running `/finish` from the wrong cwd? Reply `yes` to proceed here anyway, or `abort` and `cd` into the worktree first.

Continue only on explicit `yes`. **Auto mode:** never proceed here — stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — issue appears to live in worktree <path>; wrong cwd for an unattended /finish. No state change.` This catches the case where `/start wt` created a worktree, the user opened a fresh terminal in the main checkout, and ran `/finish PL-13` from there — which would otherwise push/commit on the wrong branch. Skip the check entirely when Step 0 detected a worktree (in which case `SOURCE_BRANCH` is set and we're already in the right place), when `ACTION` is `pr` (an explicit `/finish pr` is a deliberate choice to open a PR for the current branch — never a wrong-cwd accident), or when no issue ID was resolved (nothing to check against).

### Step 1.5: Read Quality-Review Verdict + Sub-issues

```bash
~/.claude/scripts/finish-read-verdict.sh PL-12
```

Emits seven `KEY=value` lines: `VERDICT_FILE`, `VERDICT`, `CYCLES`, `SUB_ISSUES`, `SUB_ISSUES_ERROR`, `VERDICT_STALE`, `VERDICT_STALE_REASON`. **Read those values and carry them forward** — Step 4 embeds them in the completion comment, Step 8 gates the `Ready For Release` transition on `VERDICT` and `VERDICT_STALE`.

`VERDICT` is one of:

- `passed-clean` / `passed-after-fixes` — `/quality-review` converged cleanly. Step 8 proceeds without prompting.
- `terminated-with-open-items` / `escalated-to-architect` — non-passing. Step 8 hard-refuses by default (override prompt; see Step 8).
- `malformed` — verdict file exists but cannot be parsed (no `Verdict:` line, the line contains the pipe-separated schema example, or the value is not one of the four recognized enums). Step 8 hard-refuses; the user clearly ran `/quality-review` but the handoff is broken, so silently passing the gate would defeat the safety check.
- `none-found` — no verdict file exists at either the current worktree's `tmp/` or the main checkout's `tmp/`. `/quality-review` was either never run for this issue or was run from a different repo. Step 8 warns and proceeds.

`SUB_ISSUES` is the parent issue's **current `children` array from Linear** — i.e., every sub-issue that exists under this parent right now, not necessarily ones filed by this `/quality-review` run. Step 4 surfaces this list as context (labeled accordingly), not as a "filed this run" claim.

`SUB_ISSUES_ERROR` is populated only if `linear-cli issues get` failed (CLI unauthenticated, missing issue, network blip). Step 1.5 does NOT abort on this — `linear-cli auth oauth` is offered in Step 2's error handling if needed, and the rest of `/finish` can proceed without sub-issue context. Surface the warning text in chat once when populated.

`VERDICT_STALE=1` means the verdict file's mtime predates HEAD's commit time — additional commits landed AFTER `/quality-review` ran, so the verdict does not reflect current code. Step 8 escalates passing-but-stale to refuse-with-override (same shape as `malformed`), preventing the gate from sailing through on an out-of-date verdict. The `VERDICT_STALE_REASON` field carries diagnostic text for the override prompt.

### Step 2: Get Issue Details

```bash
linear-cli issues get PL-12
```

Read the description carefully. Note:

- Requirement checkboxes (`- [ ]` items)
- Success criteria checkboxes
- Any "Nice to Have" vs "Must Have" distinctions

### Step 3: Read Current Description as JSON

```bash
linear-cli issues get PL-12 --output json
```

Identify each `- [ ]` checkbox and decide which were completed this session. Don't post anything yet — Step 5 sends the updated description and the completion comment together.

### Step 4: Generate Completion Comment

Write a markdown comment summarizing the work. **Every `<...>` token below is a substitution site — replace each one with the resolved value before posting; never emit a literal `<placeholder>` to Linear.** Template:

```markdown
## Implementation Complete

Branch: `<actual branch name>`

### What was done
- Bullet points of key changes (files created/modified, features implemented)

### Design decisions
- Key technical choices and why they were made

### Verification
- What was verified (type checks, tests, dev server, etc.)

### Adversarial review
- Verdict: <VERDICT value from Step 1.5> (cycles: <CYCLES value from Step 1.5>)
- Sub-issues (current children of this issue): <comma-list of SUB_ISSUES from Step 1.5, or the bare word `none` (no quotes) when empty>
- Open items: <text extracted from VERDICT_FILE's Open items: section, only when VERDICT=terminated-with-open-items, escalated-to-architect, or malformed>

### Notes
- Any unchecked items with explanation of why
- Any follow-up work identified
```

Omit sections that have no content (e.g., skip "Notes" if everything was completed). Omit the **Adversarial review** section entirely when `VERDICT=none-found` (no `/quality-review` ran). When the verdict is passing, drop the `Open items` bullet but keep the other two.

### Step 5: Post Description Update + Completion Comment

Write both files:

1. `tmp/linear-description-<issue-id-lowercased>.md` (e.g., `tmp/linear-description-pl-12.md`) — full description with `- [ ]` flipped to `- [x]` for completed items. Preserve everything else exactly.
2. `tmp/linear-comment-<issue-id-lowercased>.md` (e.g., `tmp/linear-comment-pl-12.md`) — completion-comment body from Step 4.

Then post both in one call:

```bash
~/.claude/scripts/finish-post-update.sh PL-12 tmp/linear-description-pl-12.md tmp/linear-comment-pl-12.md
```

Exit codes: 1 (validation — missing/empty files), 2 (Linear API failure).

### Step 6: Verify Check Passes

Run `pnpm check` as a hard gate before committing:

```bash
pnpm check
```

If it **fails**: this is CRITICAL. Do not commit or push. Fix the failures first, then re-run until it passes. **Auto mode:** bound to **2** fix delegations; if still red, stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — pnpm check failing at /finish gate after 2 unattended fix attempts. Nothing committed.`

If it **passes**: proceed to commit.

### Step 7: Git Commit & Push

1. Stage relevant files by name (`git add <files>`). Never `git add -A` / `git add .` (per CLAUDE.md).
2. Write the commit message to `tmp/finish-commit-<issue-id-lowercased>.md` (e.g., `tmp/finish-commit-pl-13.md`). The issue ID **must** appear in the message (the script enforces it for Linear auto-linking):

   ```text
   PL-13: <short imperative summary>

   <optional body explaining the why>
   ```

3. Run the commit script:

```bash
~/.claude/scripts/finish-commit.sh PL-13 tmp/finish-commit-pl-13.md [--no-push]
```

**`--no-push` is required in TWO cases — easy to miss the second:**

1. The user requested `no push` / `don't push` / `skip push` (Step 0 translates these to `NO_PUSH=1`).
2. **`ACTION=merge`** — the temp branch is about to be merged into source and deleted locally; pushing it pollutes origin with abandoned branches. The merge commit reaches origin later via the source branch.

If either condition holds, pass `--no-push`. The script does NOT enforce this rule (it has no awareness of `ACTION`), so the orchestrator MUST gate on `NO_PUSH=1 OR ACTION=merge`.

The script handles all three states: pre-staged changes (commit + push), already-committed-but-ahead (push only), already-synced (no-op). If staging is missing for an unstaged-only state, it errors with exit 2 — go back and `git add` the files.

### Step 8: Mark Issue as Ready For Release

**Skip when `ACTION == "pr"`.** In PR mode, the work is not yet shipped — review and merge are still pending. Leave the issue in `In Progress`; the transition to `Ready For Release` happens after the PR merges (manually, or via a follow-up `/finish` once the worktree branch is merged into source).

**Auto mode — the gate below never prompts.** Every refuse-with-override branch (`VERDICT_STALE=1`, `terminated-with-open-items`, `escalated-to-architect`, `malformed`) resolves to `abort`: emit that branch's `abort` terminator (`BLOCKED-ON-REVIEW: ... — <reason>, auto mode refused the override. No state change.`) and stop. Never override, never re-run unattended. **`none-found` also aborts in auto mode** — the interactive flow's warn-and-proceed assumes a human read the warning; unattended, "no review artifact" means unreviewed code, which never ships (`BLOCKED-ON-REVIEW: <ISSUE-ID> — no /quality-review artifact; unattended runs never ship unreviewed. Run /quality-review then /finish manually.`). The failing tag is `/auto`'s signal to count a failure and surface the issue to a human.

In all other cases (no worktree, or `ACTION == "merge"`), gate the transition on the `VERDICT` from Step 1.5. **Every `<...>` token in the prompt and comment bodies below is a substitution site** — replace each with the resolved value before emitting; never write a literal `<placeholder>` to chat or to Linear. The Step 4 substitution rule applies here too.

**Who performs the `Ready For Release` transition (read before any branch below).** The transition belongs to whoever *completes the lifecycle*, so Linear never shows `Ready For Release` for code that is not yet merged:

- **Standard flow (`ACTION` empty):** Step 8 runs `linear-cli issues update --state "Ready For Release"` inline (the commands in the branches below) — there is no merge to wait for.
- **`ACTION == "merge"`:** Step 8 runs the verdict **gate only** (the proceed / abort / override decisions below) and does **NOT** run `linear-cli issues update`. The merge owns the transition: Step 9 runs it via `~/.claude/scripts/mark-ready-for-release.sh <ISSUE-ID>` **only after `finish-merge.sh` exits 0** (the merge actually landed), and the launchd drainer runs the same script when it lands an async deferral. So wherever a branch below says "proceed with the state update", in `merge` mode that means **proceed to Step 9 without changing Linear state** — the gate passed; the merge (now, or later via the queue) transitions it. On a deferred merge (exit 3) the issue therefore stays **In Progress**, which is the truth: it is not released until it is merged. **Override-comment wording in merge mode:** the override comments in the branches below — posted when the user accepts a stale/failing verdict — still post here at gate time, but in `merge` mode they must record *authorization*, not a completed transition. Replace the literal `marked Ready For Release` in any such comment body with `authorized Ready For Release (the merge applies it when it lands)` — otherwise the comment re-tells the very lie this ordering exists to prevent (asserting a release state while the code is unmerged and the issue is still In Progress). The standard flow (`ACTION` empty) keeps `marked Ready For Release` — there the state really is changed here.
- **`ACTION == "pr"`:** Step 8 is skipped entirely (handled above).

**Step 8 termination contract — applies to ALL branches below.** Per `standards/lifecycle-tags.md`, every terminal path of `/finish` Step 8 ends with exactly one tagged final line. (The Preflight has its own independent terminator — `BLOCKED-ON-REVIEW` on plan-mode rejection or `ExitPlanMode` tool failure — and never reaches Step 8.) Mechanical mapping (do not skip):

- A branch that completed `linear-cli issues update --state "Ready For Release"` AND `ACTION` from Step 0 is empty (standard flow, no Step 9 to follow) → emit `RELEASED: <ISSUE-ID> — <one-line summary>` as the last LLM-authored line.
- A branch that passed the verdict gate AND `ACTION == "merge"` → do NOT change Linear state and do NOT emit a tag here (per "Who performs the transition" above, merge mode defers the state update). Step 9 owns BOTH the Ready-For-Release transition (after the merge lands) and the terminal line (`SHIPPED-MERGE:` on a completed merge, or `DEFERRED-MERGE:` when `finish-merge.sh` exits 3 and the merge is queued — the issue stays In Progress until it lands). (`ACTION == "pr"` never reaches a state update — Step 8 is skipped for it — so it isn't in these bullets; Step 9 owns `SHIPPED-PR:`. Discriminate on `ACTION`, not `SOURCE_BRANCH`: a non-worktree `pr` has an empty `SOURCE_BRANCH` yet still flows to Step 9.)
- A branch that exited via the user picking `abort` or `re-run` at the gate prompt → emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — <one-line reason>` as the last LLM-authored line. State was NOT changed.
- A branch that warned-and-proceeded (`none-found`) → same as the first/second bullets depending on `ACTION`, **unless `linear-cli issues update` itself fails, in which case bullet 5 supersedes**.
- **A branch where `linear-cli issues update` itself failed** (API error, auth dropped mid-session, team's terminal state name differs from `Ready For Release`) → see the **State-update failure** section below for the recovery + terminator rule. **This bullet supersedes bullets 1, 2, and 4 whenever the state update doesn't succeed** — never emit `RELEASED:` on a failed update.

The per-branch instructions below indicate which terminator each branch uses; trust the contract above for the literal tag wording.

**State-update failure recovery (applies to every branch that attempts `linear-cli issues update --state "Ready For Release"`).** If the call exits non-zero:

1. Inspect the error. If it's a "no such state" rejection (the team uses a different terminal state name), apply this probe-and-match fallback — analogous to `/start` Step 8.5's CANCELED/ABANDONED fallback and `/quality-review` sub-step 6's fallback:
   - Derive the team key from the issue ID prefix (e.g., `PL-13` → team `PL`). Then probe: `linear-cli statuses list -t PL`.
   - Pick the first state whose name matches `/^ready[ _-]?for[ _-]?(release|deploy|ship)$/i` (exact match — NOT a prefix match — to avoid latching onto `Ready For Review`; the `[ _-]?` separator class matches `Ready For Release`, `Ready_For_Release`, `Ready-For-Release`, `ReadyForRelease`).
   - If found, retry `linear-cli issues update <ISSUE-ID> --state "<matched-name>"`. If it succeeds, emit the standard-flow terminator `RELEASED:`. **This whole recovery applies only to the standard flow** (`ACTION` empty) — per "Who performs the transition" above, `ACTION == "merge"` does not run `linear-cli issues update` in Step 8 at all, so there is no Step-8 update to recover here; the merge owns the transition (Step 9 / the drainer via `mark-ready-for-release.sh`, which carries this same fallback).
   - If no match, OR if the retry also fails, fall through to step 2.
   - **Note on bare `Ready`:** the regex deliberately requires `Ready For <release|deploy|ship>` and does NOT match a bare `Ready` state. A team's `Ready` state is too ambiguous (could mean ready-for-review, ready-for-QA, etc.) to auto-route into — the issue falls through to step 2's BLOCKED-ON-REVIEW. To use bare `Ready` as a release state, rename it to `Ready For Release` or add canonical config.
2. Surface the error to the user and emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — linear-cli issues update failed: <reason>. State NOT changed; this issue remains In Progress.` as the terminator. **Distill `<reason>` to a single line**: if the CLI returned a multi-line error (stack trace, JSON error body), take the first informative line (typically the error message) and drop the rest — the tag must fit on one line so the agents-list parser picks it up correctly. Do NOT silently emit `RELEASED:` (it would lie about the state) and do NOT continue to Step 9 (worktree flow can't ship an issue whose state didn't transition).

- **`passed-clean` / `passed-after-fixes`** — proceed, BUT first check `VERDICT_STALE`:
  - `VERDICT_STALE=0` → proceed with the state update:

    ```bash
    linear-cli issues update PL-12 --state "Ready For Release"
    ```

    **Terminator:** `RELEASED:` (non-worktree) or none (worktree; Step 9 emits).

  - `VERDICT_STALE=1` → **refuse with override.** The verdict says "passing" but was produced before the latest commits — it may not reflect current code. Prompt the user:

    > Quality-review verdict is `<VERDICT>` but is **stale**: `<VERDICT_STALE_REASON>`. Additional commits landed after `/quality-review` ran, so the verdict may not reflect current code.
    >
    > Mark `Ready For Release` anyway? Reply `yes` to override (the prior verdict was passing and you've verified the new commits don't introduce findings), `re-run` to invoke `/quality-review` and produce a fresh verdict for current HEAD, or `abort` to stop here.

    On `yes`: proceed with the state update AND post an override comment: `Override: marked Ready For Release on stale verdict <VERDICT> (additional commits since /quality-review ran). User-acknowledged.` **Terminator:** `RELEASED:` (non-worktree) or none (worktree).
    On `re-run`: stop with `Re-run /quality-review <ISSUE-ID> to produce a fresh verdict for current HEAD, then retry /finish.` **Terminator:** `BLOCKED-ON-REVIEW: <ISSUE-ID> — stale verdict, user opted to re-run /quality-review against current HEAD before /finish.`
    On `abort`: stop with no state change. **Terminator:** `BLOCKED-ON-REVIEW: <ISSUE-ID> — stale verdict, user aborted at /finish gate. No state change.`

- **`terminated-with-open-items` / `escalated-to-architect`** — **refuse by default.** The implementation has known unresolved findings per `/quality-review`. Before composing the prompt, `Read` the file at `VERDICT_FILE` and extract the `Open items:` line (and any continuation lines, if `Open items:` is followed by an indented bullet list). Substitute that text into the prompt below — never emit the literal placeholder `<open items list from VERDICT_FILE>`. **If `VERDICT_STALE=1`, prepend a staleness note to the prompt** so the user knows the open-items list may not reflect current code (recent commits may have resolved some). Then prompt the user (single message, wait for reply):

  > Quality-review verdict is `<VERDICT>` with open items:
  >
  > `<text extracted from VERDICT_FILE's Open items: section>`
  >
  > [If `VERDICT_STALE=1`, include: `Note: the verdict is stale — <VERDICT_STALE_REASON>. The open items above may have already been resolved by the more recent commits.`]
  >
  > Mark `Ready For Release` anyway? Reply `yes` to override, `re-run` to invoke `/quality-review` and try to converge, or `abort` to stop here.

  On `yes`: proceed with the state update AND post an additional Linear comment recording the override — body: `Override: marked Ready For Release despite verdict <VERDICT>. Open items at override time: <list>. User-acknowledged.` (If `VERDICT_STALE=1`, append: ` Verdict was stale; user explicitly accepted the risk of overriding without a fresh /quality-review.`) Use `~/.claude/scripts/linear-post.sh` to post. **Terminator:** `RELEASED:` (non-worktree) or none (worktree).
  On `re-run`: stop `/finish` with the message `Re-run /quality-review <ISSUE-ID> to address open items, then retry /finish.` Do not change state. **Terminator:** `BLOCKED-ON-REVIEW: <ISSUE-ID> — verdict <VERDICT>, user opted to re-run /quality-review before /finish.`
  On `abort`: stop with no state change and no further output. **Terminator:** `BLOCKED-ON-REVIEW: <ISSUE-ID> — verdict <VERDICT>, user aborted at /finish gate. No state change.`

- **`malformed`** — verdict file exists at `VERDICT_FILE` but cannot be parsed (no `Verdict:` line, or value is the pipe-separated schema example, or value is not one of the four recognized enums). **Refuse with the same prompt as the non-passing path above**, but with this preamble instead of the open-items list:

  > Quality-review verdict file exists at `<VERDICT_FILE>` but is malformed (no recognized verdict value). The user clearly ran /quality-review, but the handoff is broken — silently marking Ready For Release would defeat the safety check.
  >
  > Mark `Ready For Release` anyway? Reply `yes` to override (consider inspecting the file first), `re-run` to invoke `/quality-review` and produce a fresh artifact, or `abort` to stop here.

  Same response handling as the non-passing path: `yes` posts an override comment (body: `Override: marked Ready For Release despite malformed /quality-review verdict file. User-acknowledged.` — do NOT include `VERDICT_FILE`'s absolute path in the comment body, since Linear comments are not necessarily private and the path leaks the user's home directory and project layout); `re-run` stops with the re-run suggestion; `abort` stops. **Terminators:** `yes` → `RELEASED:` (non-worktree) or none (worktree); `re-run` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — malformed verdict, user opted to re-run /quality-review.`; `abort` → `BLOCKED-ON-REVIEW: <ISSUE-ID> — malformed verdict, user aborted at /finish gate. No state change.`

- **`none-found`** — no verdict file located. Warn once: `No /quality-review artifact found for this issue. Proceeding without gate. Consider running /quality-review before /finish next time.` Then proceed with the state update. **Terminator:** `RELEASED:` (non-worktree) or none (worktree). (Backward compatibility for issues finished before this gate existed.)

- **Any other value** (defense in depth — shouldn't happen since the script normalizes everything else to `malformed`) → treat as `malformed`. Do NOT proceed silently. **Terminators:** same as `malformed`.

### Step 9: Finalization (only when `ACTION` is `merge` or `pr`)

Runs only when `ACTION` is `merge` or `pr`. Skip entirely when `ACTION` is empty (the standard flow ended at Step 8). `merge` always implies a worktree (`SOURCE_BRANCH` set); `pr` runs with or without one.

**Step 9 is the terminal step of this session** — for all modes. After the merge (or `gh pr create`) completes, present the closing message and stop. Don't run further bash commands.

Substitute the values captured from Step 0 (`SOURCE_BRANCH`, `WORKTREE_BRANCH`, `WT_DIR`, `REPO_ROOT`) into the bash commands below as literal strings.

**If `ACTION == "merge"`:**

The script brings the worktree branch up to source's tip **inside the worktree** (where this session can edit even under bgIsolation, and where no lock is needed because the worktree is private to this session), then **advances source to it** — by `git merge --ff-only` when the main checkout is on source, or by an atomic ref update (`git update-ref`, compare-and-swap) when it's on another branch. Either way the advance never merges in the main checkout, never leaves it mid-merge, and never switches its HEAD. The common case — worktree branch one commit ahead, source unmoved — collapses to a single `PL-XXX: <summary>` line in `git log` with no merge commit. Only when source moved during the worktree's life is a merge commit created (with the prepared one-line `Merge PL-XXX` subject, avoiding the verbose default boilerplate); any conflicts from that are resolved **in the worktree**, never the main checkout. This is what makes the merge safe to run concurrently and from a background session.

1. **Write the merge-commit message** to `<WT_DIR>/tmp/git-merge-msg-<issue-id-lowercased>.md` (e.g., `<WT_DIR>/tmp/git-merge-msg-pl-13.md`; substitute the actual `WT_DIR` value from Step 0). Use the `Write` tool — it requires an absolute path. A single line is all that's needed; it's only used in the rare divergent-merge case (or during conflict resolution), and the issue ID is what Linear auto-links on:

   ```text
   Merge PL-13
   ```

2. **Run the merge in a single Bash tool call** — `cd` to the main checkout (the script removes the worktree on success, so cwd must not be inside it), then call `finish-merge.sh`:

   ```bash
   cd '<REPO_ROOT from Step 0>'
   ~/.claude/scripts/finish-merge.sh '<WT_DIR>' '<SOURCE_BRANCH>' '<WORKTREE_BRANCH>' '<WT_DIR>/tmp/git-merge-msg-pl-13.md'
   ```

   The script self-serializes against other `/finish merge` sessions targeting the same parent repo. If another session holds the merge slot, the Bash call will print `[finish-queue] waiting for <REPO_ROOT> ...` on stderr and block until its turn — surface that output to the user as-is and wait. The lock is released by the OS when the script exits (success, error, or crash); no manual cleanup is needed.

**Exit codes:**

- **0 (success)** — the merge landed, so **now** perform the Ready-For-Release transition that Step 8 deferred (the merge owns it):

  1. Run `~/.claude/scripts/mark-ready-for-release.sh <ISSUE-ID>` — moves the issue to Ready For Release with the same team-state fallback Step 8 documents.
     - **Exit 0** → proceed to the closing message below.
     - **Non-zero** → the merge succeeded but the Linear update failed. Do **NOT** undo the merge. Surface the script's error and emit, as the terminal line, `SHIPPED-MERGE: <ISSUE-ID> — <WORKTREE_BRANCH> merged into <SOURCE_BRANCH>, worktree removed, but Linear state update FAILED: <reason>. Mark Ready For Release manually.` (still `SHIPPED-MERGE` — the code shipped; only the bookkeeping needs a manual touch). Then stop.
  2. On success, surface the merge output and present the closing message. The tagged final line (per `standards/lifecycle-tags.md`) MUST be the last LLM-authored output:

     ```text
     This agent-view session is done — close it and dispatch a new session for the next issue.

     SHIPPED-MERGE: <ISSUE-ID> — <WORKTREE_BRANCH> merged into <SOURCE_BRANCH>, worktree removed, Ready For Release.
     ```

  Do not run further bash commands.

- **1 (hard precondition failure)** — surface the script's output and stop. Don't attempt recovery; these are genuine setup problems the user must resolve (source branch missing, worktree gone or on the wrong branch, worktree mid-unrelated-operation or with uncommitted tracked changes, or the merge couldn't be verified). The terminal tagged line is `BLOCKED-ON-REVIEW: <ISSUE-ID> — <reason from the script>. <recovery>.` Do not run further bash commands. (Transient blocks — dirty/on-source main checkout, source checked out elsewhere, main mid-operation, contention — are **exit 3**, not 1; see below.)

- **3 (transient block — deferred to the merge queue)** — the merge can't advance the source branch *right now* but will succeed later untouched (the main checkout is on the source branch with uncommitted WIP, the source branch is checked out in another worktree, the main checkout is mid-operation, or the source branch is under continuous contention). The script has **already self-enqueued** the merge to the local queue (`scripts/merge-queue.sh`); a launchd drainer retries until it lands, and **the drainer marks the issue Ready For Release when it does**. The worktree is intact and the issue **remains In Progress** — Step 8 deliberately did NOT mark it Ready For Release (the merge owns that transition, and the merge hasn't landed). That is the honest state: it is not released until it is merged. So there is **nothing more to do** here — do **not** retry, commit, mark the issue Ready For Release, or touch any other session's changes. Surface the script's `DEFERRED:` output and present the terminal tagged line (substitute the script's reason):

  ```text
  Merge deferred — it'll retry automatically once the blocker clears. Inspect any time with /merge-queue.

  DEFERRED-MERGE: <ISSUE-ID> — merge queued (<reason>); will retry automatically. Check with /merge-queue.
  ```

  Do not run further bash commands.

- **2 (merge conflict — resolve in the worktree)** — the script merged `<SOURCE_BRANCH>` into the worktree branch **inside `<WT_DIR>`** and hit conflicts. The main checkout is untouched and clean; the conflict lives in the worktree, which this session **owns** (edits there are permitted even under bgIsolation) and which is **private** (no lock needed — do **not** wrap these in `with-repo-lock.py`). Conflicted files are listed on the script's stderr as worktree-relative paths.

  1. For each conflicted file: read it from `<WT_DIR>/<path>`, understand both sides of the conflict, apply the resolution. When one side clearly subsumes the other (e.g., the worktree branch removed code the source side modified), take the subsuming side. Ask the user only when the right answer is genuinely ambiguous. **Auto mode:** when genuinely ambiguous, do not guess — run `git -C '<WT_DIR>' merge --abort` and stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — merge conflict needs a human (<files>). Worktree preserved.`
  2. `git -C '<WT_DIR>' add <resolved-files>`
  3. Run `pnpm check` from `<WT_DIR>` — must be green before committing. If it fails: the conflict resolution introduced a regression. Per the Working Application Contract, do **not** commit and do **not** re-invoke. Surface the failing output to the user; let them decide between fixing the resolution further, aborting the merge (`git -C '<WT_DIR>' merge --abort`), or escalating to architect. The mid-merge state is preserved in the worktree for inspection. **Auto mode:** do not wait for a decision — run `git -C '<WT_DIR>' merge --abort` and stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — conflict resolution broke pnpm check; merge aborted, worktree preserved for a human.`
  4. `git -C '<WT_DIR>' commit -F '<WT_DIR>/tmp/git-merge-msg-<issue-id-lowercased>.md'` — reuse the prepared merge-commit message (e.g., `<WT_DIR>/tmp/git-merge-msg-pl-13.md`).
  5. **Re-invoke the same Step 2 `finish-merge.sh` line.** It re-acquires the lock and fast-forwards the main checkout, then removes the worktree and branch. If source advanced during your resolution, it re-merges the new delta — which may return **2 again** with a fresh conflict on that delta; if so, **repeat steps 1–5**. This is expected under concurrent `/finish merge` sessions and converges (each round reconciles only the latest source delta).
  6. Present the closing message above once the re-invocation exits 0.

**If `ACTION == "pr"`:**

The branch was pushed in Step 7 (the `no push` + `pr` combination was rejected in Step 0). Open a PR for the current branch — this works whether or not we're in a worktree.

1. **Resolve the base branch:**
   - `SOURCE_BRANCH` is set (we're in a `/start wt` worktree) → base = `SOURCE_BRANCH`.
   - `SOURCE_BRANCH` is empty (plain-branch PR) → base = the repo's GitHub default branch:

     ```bash
     gh repo view --json defaultBranchRef -q .defaultBranchRef.name
     ```

     If this fails (no GitHub remote, `gh` unauthenticated), surface the error and stop with the terminator `BLOCKED-ON-REVIEW: <ISSUE-ID> — cannot resolve PR base (<first error line>). Branch pushed; open the PR manually.` — there's nowhere to open the PR. Don't guess a base. The base is the default branch by design even when the branch was forked off another branch; the user can retarget the PR in GitHub if it should land elsewhere.

2. **Verify any requested labels exist** (only if Step 0 collected labels). Check each label with an exact-equality `jq` filter (a substring like `deploy` must NOT match an existing `pr-deploy`) — the command prints the label name if it exists and nothing if it doesn't:

   ```bash
   gh label list --limit 200 --json name -q '.[].name | select(. == "<label>")'
   ```

   If a requested label is missing (empty output), do NOT silently drop it. Surface it and ask the user: proceed without that label / create it (`gh label create '<label>'`) / abort. Apply only labels that exist (or that the user just created). **Auto mode:** proceed without the missing label; note the omission in the closing message.

3. **Generate the PR title and body from the actual diff** — do NOT use `--fill` (it only echoes the commit message). Apply the `pr-update` skill's methodology directly: read [`~/.claude/skills/pr-update/SKILL.md`](../pr-update/SKILL.md) and follow its Analysis Process (§2–6), PR Title Formats, and Description Structure. **Skip pr-update's own base-resolution** (its §2 `if [[ -n "$pr_info" ]]; … BASE=…` prologue) and substitute the `<BASE>` you already resolved in sub-step 1 wherever its commands reference `$BASE` — in a worktree that base is `SOURCE_BRANCH`, **not** the default branch, and letting pr-update re-resolve `$BASE` would diff the worktree PR against the wrong base. This is a **by-reference** use of that methodology — read its sections and apply them here — **not** a `Skill`-tool dispatch of `pr-update`: `/finish` must stay the authority over the base, labels, and the terminal `SHIPPED-PR` tag, and must not trigger `pr-update`'s own interactive PR-state prompts. The branch is already pushed (Step 7), so no push here. (pr-update's own empty-`$BASE` guard lives in the §2 prologue you're skipping; sub-step 1 above is the backstop for this path — it already stops if it cannot resolve a base, so the substituted `<BASE>` is non-empty by the time you reach here.)

4. **Write the body** to `<WT_DIR>/tmp/pr-body-<issue-id-lowercased>.md` (worktree mode) or `<REPO_ROOT>/tmp/pr-body-<issue-id-lowercased>.md` (in-place) using the **Write** tool (it requires an absolute path) — the same pattern as the merge-commit message file in the `merge` branch above.

5. **Create the PR** — pass `--base` explicitly, the generated title, the body file, and one `--label` per verified label:

   ```bash
   gh pr create --base '<BASE>' --head '<WORKTREE_BRANCH>' --title '<generated title>' --body-file '<path from step 4>' [--label '<label>' ...]
   ```

After the PR is created, present the closing message. The tagged final line (per `standards/lifecycle-tags.md`) MUST be the last LLM-authored output. Substitute the actual resolved `<BASE>`, branch, and label list (or the bare word `none` when no labels were applied). The message branches on whether a worktree is involved:

- **`SOURCE_BRANCH` set (worktree PR)** — leave the worktree in place; it's the lifecycle boundary. The leading sentence and the tagged line should NOT duplicate the cleanup hint:

  ```text
  This agent-view session is done. The worktree stays in place until the PR merges.

  SHIPPED-PR: <ISSUE-ID> — PR opened (base=<BASE>, head=<WORKTREE_BRANCH>), labels: <list|none>. After merge, run `git worktree remove .claude/worktrees/<issue-id-lowercased>` from the main checkout.
  ```

  After the PR merges, the user removes the worktree manually from the main repo checkout:

  ```bash
  # cd to the main repo checkout (parent of .claude/worktrees/), then:
  git worktree remove .claude/worktrees/<issue-id-lowercased>
  ```

- **`SOURCE_BRANCH` empty (plain-branch PR)** — there is no worktree to clean up; omit the worktree hint entirely:

  ```text
  This agent-view session is done. The PR is open against <BASE> — review and merge it there.

  SHIPPED-PR: <ISSUE-ID> — PR opened (base=<BASE>, head=<WORKTREE_BRANCH>), labels: <list|none>. Review/merge the PR.
  ```

## Error Handling

- If the issue is already Ready For Release or Done, warn the user and ask if they want to proceed (add comment only). Auto mode: do not re-finish a terminal issue — stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — already <state>; nothing to finish.`
- If there are no uncommitted changes and code is already pushed, skip the git steps
- If `linear-cli` is not authenticated, prompt: `linear-cli auth oauth` (auto mode: do not prompt — stop with `BLOCKED-ON-REVIEW: <ISSUE-ID or "current branch"> — linear-cli unauthenticated. Nothing committed, no state change.`)
- If the issue identifier can't be found, ask the user explicitly (auto mode: stop with `BLOCKED-ON-REVIEW: current branch — no issue ID resolvable. No state change.`)
