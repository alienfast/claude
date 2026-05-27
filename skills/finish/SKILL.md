---
name: finish
description: Finish a Linear issue — check off requirements, add completion comment, commit/push, mark Ready For Release. Use when the user says 'finish issue', 'done with this issue', 'complete PL-XX', or invokes /finish.
---

# Finish Issue

Automates the post-completion workflow for a Linear issue using the `linear` CLI. The mechanical steps (worktree-mode detection, issue-ID resolution, Linear posts, git commit/push) are delegated to scripts in `~/.claude/scripts/`; this skill is the orchestrator + LLM-judgment surface (reading the description, composing the completion comment).

## Arguments

- Issue identifier (e.g., `PL-12`) — optional, auto-detected from branch/commit
- `no push` / `don't push` / `skip push` — optional, skips the git push step (commit still happens)
- `merge` — only meaningful inside a `/start wt` worktree. **Default when in a worktree.** Merge the worktree branch back into its recorded source branch, then remove the worktree.
- `pr` — only meaningful inside a `/start wt` worktree. Open a pull request with `base = source branch` and leave the worktree in place.

Examples: `/finish`, `/finish PL-12`, `/finish no push`, `/finish PL-12 no push`, `/finish merge`, `/finish pr PL-12`

## Invariant

**`pnpm check` must pass before committing or pushing code.** Check failures are always CRITICAL — never "pre-existing", never "out of scope", never deferred. Fix them before proceeding. Turborepo caching makes repeated runs cheap.

## Workflow

### Step 0: Detect Worktree Mode

Normalize the user's args before calling the script:

- Look for `merge` and `pr` tokens (case-insensitive, position-agnostic) — pass through whichever is present (if both, the script errors).
- Look for `no push` / `don't push` / `skip push` — translate to `--no-push` for the script.

```bash
~/.claude/scripts/finish-detect-mode.sh [merge|pr] [--no-push]
```

The script probes worktree state, validates incompatible argument combinations, and emits six `KEY=value` lines on stdout: `ACTION`, `SOURCE_BRANCH`, `WORKTREE_BRANCH`, `WT_DIR`, `REPO_ROOT`, `NO_PUSH`. **Read those values and carry them forward** — Step 9 substitutes them into bash commands as literal strings (each Bash tool call is a fresh shell).

**Exit codes:**

- 1 — incompatible args (e.g., `merge` + `pr`, or `pr` + `no push`). Surface the error and stop.
- 2 — `merge`/`pr` requested outside a `/start wt` worktree. Surface and stop.

When `SOURCE_BRANCH` is set (we're in a worktree), the script defaults `ACTION` to `merge`. `/finish pr` is the only way to opt into the PR flow.

If both `SOURCE_BRANCH` and `ACTION` are empty, this is the standard `/finish` flow.

### Step 1: Identify the Issue

```bash
~/.claude/scripts/detect-issue-id.sh [--input <USER-SUPPLIED-ID>]
```

The script tries `--input` → current branch → latest commit subject, in that order. Pass `--input` only when the user typed an explicit ID (e.g., `/finish PL-12`). On exit 1, ask the user for the identifier explicitly.

**Cross-worktree sanity check (standard-flow only).** After the issue ID is resolved, if the standard flow was detected in Step 0 (no worktree config under the current cwd) but the issue's branch exists in a known linked worktree of this repo (`git worktree list` shows a path whose basename or branch contains `<issue-id-lower>`), warn the user before continuing:

> Issue `<ISSUE-ID>` appears to live in worktree `<path>`. Are you running `/finish` from the wrong cwd? Reply `yes` to proceed here anyway, or `abort` and `cd` into the worktree first.

Continue only on explicit `yes`. This catches the case where `/start wt` created a worktree, the user opened a fresh terminal in the main checkout, and ran `/finish PL-13` from there — which would otherwise push/commit on the wrong branch. Skip the check entirely when Step 0 detected a worktree (in which case `SOURCE_BRANCH` is set and we're already in the right place) or when no issue ID was resolved (nothing to check against).

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

`SUB_ISSUES_ERROR` is populated only if `linear i get` failed (CLI unauthenticated, missing issue, network blip). Step 1.5 does NOT abort on this — `linear auth login` is offered in Step 2's error handling if needed, and the rest of `/finish` can proceed without sub-issue context. Surface the warning text in chat once when populated.

`VERDICT_STALE=1` means the verdict file's mtime predates HEAD's commit time — additional commits landed AFTER `/quality-review` ran, so the verdict does not reflect current code. Step 8 escalates passing-but-stale to refuse-with-override (same shape as `malformed`), preventing the gate from sailing through on an out-of-date verdict. The `VERDICT_STALE_REASON` field carries diagnostic text for the override prompt.

### Step 2: Get Issue Details

```bash
linear issues get PL-12 --format full
```

Read the description carefully. Note:

- Requirement checkboxes (`- [ ]` items)
- Success criteria checkboxes
- Any "Nice to Have" vs "Must Have" distinctions

### Step 3: Read Current Description as JSON

```bash
linear issues get PL-12 --output json
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

If it **fails**: this is CRITICAL. Do not commit or push. Fix the failures first, then re-run until it passes.

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

In all other cases (no worktree, or `ACTION == "merge"`), gate the transition on the `VERDICT` from Step 1.5. **Every `<...>` token in the prompt and comment bodies below is a substitution site** — replace each with the resolved value before emitting; never write a literal `<placeholder>` to chat or to Linear. The Step 4 substitution rule applies here too.

**Step 8 termination contract — applies to ALL branches below.** Per `standards/lifecycle-tags.md`, every terminal path of `/finish` Step 8 ends with exactly one tagged final line. Mechanical mapping (do not skip):

- A branch that completed `linear issues update --state "Ready For Release"` AND `SOURCE_BRANCH` from Step 0 is empty (non-worktree flow, no Step 9 to follow) → emit `RELEASED: <ISSUE-ID> — <one-line summary>` as the last LLM-authored line.
- A branch that completed the state update AND `SOURCE_BRANCH` is non-empty (worktree flow) → do NOT emit a tag here; Step 9 owns the terminal line (`SHIPPED-MERGE:` or `SHIPPED-PR:`).
- A branch that exited via the user picking `abort` or `re-run` at the gate prompt → emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — <one-line reason>` as the last LLM-authored line. State was NOT changed.
- A branch that warned-and-proceeded (`none-found`) → same as the first/second bullets depending on `SOURCE_BRANCH`, **unless `linear issues update` itself fails, in which case bullet 5 supersedes**.
- **A branch where `linear issues update` itself failed** (API error, auth dropped mid-session, team's terminal state name differs from `Ready For Release`) → see the **State-update failure** section below for the recovery + terminator rule. **This bullet supersedes bullets 1, 2, and 4 whenever the state update doesn't succeed** — never emit `RELEASED:` on a failed update.

The per-branch instructions below indicate which terminator each branch uses; trust the contract above for the literal tag wording.

**State-update failure recovery (applies to every branch that attempts `linear issues update --state "Ready For Release"`).** If the call exits non-zero:

1. Inspect the error. If it's a "no such state" rejection (the team uses a different terminal state name), apply this probe-and-match fallback — analogous to `/start` Step 8.5's CANCELED/ABANDONED fallback and `/quality-review` sub-step 6's fallback:
   - Derive the team key from the issue ID prefix (e.g., `PL-13` → team `PL`). Then probe: `linear teams states PL`.
   - Pick the first state whose name matches `/^ready[ _-]?for[ _-]?(release|deploy|ship)$/i` (exact match — NOT a prefix match — to avoid latching onto `Ready For Review`; the `[ _-]?` separator class matches `Ready For Release`, `Ready_For_Release`, `Ready-For-Release`, `ReadyForRelease`).
   - If found, retry `linear issues update <ISSUE-ID> --state "<matched-name>"`. If it succeeds, proceed with the branch's stated `RELEASED:` terminator.
   - If no match, OR if the retry also fails, fall through to step 2.
   - **Note on bare `Ready`:** the regex deliberately requires `Ready For <release|deploy|ship>` and does NOT match a bare `Ready` state. A team's `Ready` state is too ambiguous (could mean ready-for-review, ready-for-QA, etc.) to auto-route into — the issue falls through to step 2's BLOCKED-ON-REVIEW. To use bare `Ready` as a release state, rename it to `Ready For Release` or add canonical config.
2. Surface the error to the user and emit `BLOCKED-ON-REVIEW: <ISSUE-ID> — linear issues update failed: <reason>. State NOT changed; this issue remains In Progress.` as the terminator. **Distill `<reason>` to a single line**: if the CLI returned a multi-line error (stack trace, JSON error body), take the first informative line (typically the error message) and drop the rest — the tag must fit on one line so the agents-list parser picks it up correctly. Do NOT silently emit `RELEASED:` (it would lie about the state) and do NOT continue to Step 9 (worktree flow can't ship an issue whose state didn't transition).

- **`passed-clean` / `passed-after-fixes`** — proceed, BUT first check `VERDICT_STALE`:
  - `VERDICT_STALE=0` → proceed with the state update:

    ```bash
    linear issues update PL-12 --state "Ready For Release"
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

### Step 9: Worktree Finalization (only when `SOURCE_BRANCH` is set)

Runs only if Step 0 detected a worktree. Skip entirely otherwise.

**Step 9 is the terminal step of this session** — for both modes. After the merge (or `gh pr create`) completes, present the closing message and stop. Don't run further bash commands.

Substitute the values captured from Step 0 (`SOURCE_BRANCH`, `WORKTREE_BRANCH`, `WT_DIR`, `REPO_ROOT`) into the bash commands below as literal strings.

**If `ACTION == "merge"`:**

The merge fast-forwards when possible — the common case, since worktree branches are usually one commit ahead of source. That collapses to a single `PL-XXX: <summary>` line in `git log` with no merge commit. Only when the source branch has moved during the worktree's life does git create a merge commit; in that case it uses the prepared one-line `Merge PL-XXX` subject (avoiding the verbose default `Merge branch '<long-branch-name>' into <source>` boilerplate).

1. **Write the merge-commit message** to `<WT_DIR>/tmp/git-merge-msg-<issue-id-lowercased>.md` (e.g., `<WT_DIR>/tmp/git-merge-msg-pl-13.md`; substitute the actual `WT_DIR` value from Step 0). Use the `Write` tool — it requires an absolute path. A single line is all that's needed; it's only used in the rare divergent-merge case (or during conflict resolution), and the issue ID is what Linear auto-links on:

   ```text
   Merge PL-13
   ```

2. **Run the merge in a single Bash tool call** — `cd` to the main checkout (the script removes the worktree on success, so cwd must not be inside it), then call `finish-merge.sh`:

   ```bash
   cd '<REPO_ROOT from Step 0>'
   ~/.claude/scripts/finish-merge.sh '<WT_DIR>' '<SOURCE_BRANCH>' '<WORKTREE_BRANCH>' '<WT_DIR>/tmp/git-merge-msg-pl-13.md'
   ```

**Exit codes:**

- **0 (success)** — surface the script's output and present the closing message. The tagged final line (per `standards/lifecycle-tags.md`) MUST be the last LLM-authored output:

  ```text
  This agent-view session is done — close it and dispatch a new session for the next issue.

  SHIPPED-MERGE: <ISSUE-ID> — <WORKTREE_BRANCH> merged into <SOURCE_BRANCH>, worktree removed, Ready For Release.
  ```

  Do not run further bash commands.

- **1 (precondition failure)** — surface the script's output and stop. Don't attempt recovery; precondition errors are setup issues (dirty checkout, missing branch, mid-merge state) that the user needs to resolve.

- **2 (merge conflict, state preserved)** — resolve inline. The main checkout is on `<SOURCE_BRANCH>` with an in-progress merge; conflicted files are listed on the script's stderr.

  1. For each conflicted file: read it from `<REPO_ROOT>/<path>`, understand both sides of the conflict, apply the resolution. When one side clearly subsumes the other (e.g., the worktree branch removed code the source side modified), take the subsuming side. Ask the user only when the right answer is genuinely ambiguous.
  2. `git -C '<REPO_ROOT>' add <resolved-files>`
  3. Run `pnpm check` from `<REPO_ROOT>` — must be green before committing. If it fails: the conflict resolution introduced a regression. Per the Working Application Contract, do **not** commit and do **not** proceed to step 4. Surface the failing output to the user; let them decide between fixing the resolution further, aborting the merge (`git -C '<REPO_ROOT>' merge --abort`), or escalating to architect. The mid-merge state is preserved on disk for inspection.
  4. `git -C '<REPO_ROOT>' commit -F '<WT_DIR>/tmp/git-merge-msg-<issue-id-lowercased>.md'` — reuse the prepared merge-commit message (e.g., `<WT_DIR>/tmp/git-merge-msg-pl-13.md`).
  5. `git -C '<REPO_ROOT>' worktree remove '<WT_DIR>'`
  6. `git -C '<REPO_ROOT>' branch -d '<WORKTREE_BRANCH>'`
  7. Present the closing message above.

  **Known limitation:** if this orchestrator is running in an isolated background session (bgIsolation guard active), edits to `<REPO_ROOT>` will be blocked. In that case, surface the conflict files and stop — the user will resolve from a foreground session.

**If `ACTION == "pr"`:**

The branch was pushed in Step 7 (the `no push` + `pr` combination was rejected in Step 0). Open a PR with the recorded source branch as base:

```bash
gh pr create --base '<SOURCE_BRANCH>' --head '<WORKTREE_BRANCH>' --fill
```

After the PR is created, present the closing message. The tagged final line (per `standards/lifecycle-tags.md`) MUST be the last LLM-authored output. The leading sentence and the tagged line should NOT duplicate the cleanup hint:

```text
This agent-view session is done. The worktree stays in place until the PR merges.

SHIPPED-PR: <ISSUE-ID> — PR opened (base=<SOURCE_BRANCH>, head=<WORKTREE_BRANCH>). After merge, run `git worktree remove .claude/worktrees/<issue-id-lowercased>` from the main checkout.
```

Leave the worktree in place — the PR is the lifecycle boundary. After the PR merges, the user removes the worktree manually from the main repo checkout:

```bash
# cd to the main repo checkout (parent of .claude/worktrees/), then:
git worktree remove .claude/worktrees/<issue-id-lowercased>
```

## Error Handling

- If the issue is already Ready For Release or Done, warn the user and ask if they want to proceed (add comment only)
- If there are no uncommitted changes and code is already pushed, skip the git steps
- If `linear` CLI is not authenticated, prompt: `linear auth login`
- If the issue identifier can't be found, ask the user explicitly
