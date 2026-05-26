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

### Step 1.5: Read Quality-Review Verdict + Sub-issues

```bash
~/.claude/scripts/finish-read-verdict.sh PL-12
```

Emits four `KEY=value` lines: `VERDICT_FILE`, `VERDICT`, `CYCLES`, `SUB_ISSUES`. **Read those values and carry them forward** — Step 4 embeds them in the completion comment, Step 8 gates the `Ready For Release` transition on `VERDICT`.

`VERDICT` is one of:

- `passed-clean` / `passed-after-fixes` — `/quality-review` converged cleanly. Step 8 proceeds without prompting.
- `terminated-with-open-items` / `escalated-to-architect` — non-passing. Step 8 hard-refuses by default (override prompt; see Step 8).
- `none-found` — no verdict file exists at either the current worktree's `tmp/` or the main checkout's `tmp/`. `/quality-review` was either never run for this issue or was run from a different repo. Step 8 warns and proceeds.

`SUB_ISSUES` is the parent's `children` array from Linear (comma-separated `PL-XX` identifiers). Step 4 lists these in the completion comment so deferred work filed during `/quality-review` is discoverable from the issue.

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

Write a markdown comment summarizing the work. Structure:

```markdown
## Implementation Complete

Branch: `<branch>`

### What was done
- Bullet points of key changes (files created/modified, features implemented)

### Design decisions
- Key technical choices and why they were made

### Verification
- What was verified (type checks, tests, dev server, etc.)

### Adversarial review
- Verdict: <VERDICT> (cycles: <CYCLES>)
- Sub-issues filed: <comma-list of SUB_ISSUES, or "none">
- Open items: <from verdict file, only when VERDICT=terminated-with-open-items or escalated-to-architect>

### Notes
- Any unchecked items with explanation of why
- Any follow-up work identified
```

Omit sections that have no content (e.g., skip "Notes" if everything was completed). Omit the **Adversarial review** section entirely when `VERDICT=none-found` (no `/quality-review` ran). When the verdict is passing, drop the `Open items` bullet but keep the other two.

### Step 5: Post Description Update + Completion Comment

Write both files:

1. `tmp/linear-description-<issue-id>.md` — full description with `- [ ]` flipped to `- [x]` for completed items. Preserve everything else exactly.
2. `tmp/linear-comment-<issue-id>.md` — completion-comment body from Step 4.

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
2. Write the commit message to `tmp/finish-commit-<issue-id>.md`. The issue ID **must** appear in the message (the script enforces it for Linear auto-linking):

   ```text
   PL-13: <short imperative summary>

   <optional body explaining the why>
   ```

3. Run the commit script:

```bash
~/.claude/scripts/finish-commit.sh PL-13 tmp/finish-commit-pl-13.md [--no-push]
```

Pass `--no-push` if the user requested `no push` / `don't push` / `skip push`. **Also pass `--no-push` whenever `ACTION=merge`** — the temp branch is about to be merged and deleted locally; pushing it pollutes origin with abandoned branches. The merge commit reaches origin later via the source branch.

The script handles all three states: pre-staged changes (commit + push), already-committed-but-ahead (push only), already-synced (no-op). If staging is missing for an unstaged-only state, it errors with exit 2 — go back and `git add` the files.

### Step 8: Mark Issue as Ready For Release

**Skip when `ACTION == "pr"`.** In PR mode, the work is not yet shipped — review and merge are still pending. Leave the issue in `In Progress`; the transition to `Ready For Release` happens after the PR merges (manually, or via a follow-up `/finish` once the worktree branch is merged into source).

In all other cases (no worktree, or `ACTION == "merge"`), gate the transition on the `VERDICT` from Step 1.5:

- **`passed-clean` / `passed-after-fixes`** — proceed:

  ```bash
  linear issues update PL-12 --state "Ready For Release"
  ```

- **`terminated-with-open-items` / `escalated-to-architect`** — **refuse by default.** The implementation has known unresolved findings per `/quality-review`. Prompt the user explicitly (single message, then wait for reply):

  > Quality-review verdict is `<VERDICT>` with open items:
  >
  > `<open items list from VERDICT_FILE>`
  >
  > Mark `Ready For Release` anyway? Reply `yes` to override, `re-run` to invoke `/quality-review` and try to converge, or `abort` to stop here.

  On `yes`: proceed with the state update AND post an additional Linear comment recording the override — body: `Override: marked Ready For Release despite verdict <VERDICT>. Open items at override time: <list>. User-acknowledged.` Use `~/.claude/scripts/linear-post.sh` to post.
  On `re-run`: stop `/finish` with the message `Re-run /quality-review <ISSUE-ID> to address open items, then retry /finish.` Do not change state.
  On `abort`: stop with no state change and no further output.

- **`none-found`** — no verdict file located. Warn once: `No /quality-review artifact found for this issue. Proceeding without gate. Consider running /quality-review before /finish next time.` Then proceed with the state update. (Backward compatibility for issues finished before this gate existed.)

### Step 9: Worktree Finalization (only when `SOURCE_BRANCH` is set)

Runs only if Step 0 detected a worktree. Skip entirely otherwise.

**Step 9 is the terminal step of this session** — for both modes. After the merge (or `gh pr create`) completes, present the closing message and stop. Don't run further bash commands.

Substitute the values captured from Step 0 (`SOURCE_BRANCH`, `WORKTREE_BRANCH`, `WT_DIR`, `REPO_ROOT`) into the bash commands below as literal strings.

**If `ACTION == "merge"`:**

The merge fast-forwards when possible — the common case, since worktree branches are usually one commit ahead of source. That collapses to a single `PL-XXX: <summary>` line in `git log` with no merge commit. Only when the source branch has moved during the worktree's life does git create a merge commit; in that case it uses the prepared one-line `Merge PL-XXX` subject (avoiding the verbose default `Merge branch '<long-branch-name>' into <source>` boilerplate).

1. **Write the merge-commit message** to `<WT_DIR>/tmp/git-merge-msg-<issue-lower>.md` (substitute the actual `WT_DIR` value from Step 0). Use the `Write` tool — it requires an absolute path. A single line is all that's needed; it's only used in the rare divergent-merge case (or during conflict resolution), and the issue ID is what Linear auto-links on:

   ```text
   Merge PL-13
   ```

2. **Run the merge in a single Bash tool call** — `cd` to the main checkout (the script removes the worktree on success, so cwd must not be inside it), then call `finish-merge.sh`:

   ```bash
   cd '<REPO_ROOT from Step 0>'
   ~/.claude/scripts/finish-merge.sh '<WT_DIR>' '<SOURCE_BRANCH>' '<WORKTREE_BRANCH>' '<WT_DIR>/tmp/git-merge-msg-pl-13.md'
   ```

**Exit codes:**

- **0 (success)** — surface the script's output and present the closing message:

  ```text
  ✓ <WORKTREE_BRANCH> merged into <SOURCE_BRANCH>. Worktree removed.
  This agent-view session is done — close it and dispatch a new session for the next issue.
  ```

  Do not run further bash commands.

- **1 (precondition failure)** — surface the script's output and stop. Don't attempt recovery; precondition errors are setup issues (dirty checkout, missing branch, mid-merge state) that the user needs to resolve.

- **2 (merge conflict, state preserved)** — resolve inline. The main checkout is on `<SOURCE_BRANCH>` with an in-progress merge; conflicted files are listed on the script's stderr.

  1. For each conflicted file: read it from `<REPO_ROOT>/<path>`, understand both sides of the conflict, apply the resolution. When one side clearly subsumes the other (e.g., the worktree branch removed code the source side modified), take the subsuming side. Ask the user only when the right answer is genuinely ambiguous.
  2. `git -C '<REPO_ROOT>' add <resolved-files>`
  3. Run `pnpm check` from `<REPO_ROOT>` — must be green before committing.
  4. `git -C '<REPO_ROOT>' commit -F '<WT_DIR>/tmp/git-merge-msg-<issue>.md'` — reuse the prepared merge-commit message.
  5. `git -C '<REPO_ROOT>' worktree remove '<WT_DIR>'`
  6. `git -C '<REPO_ROOT>' branch -d '<WORKTREE_BRANCH>'`
  7. Present the closing message above.

  **Known limitation:** if this orchestrator is running in an isolated background session (bgIsolation guard active), edits to `<REPO_ROOT>` will be blocked. In that case, surface the conflict files and stop — the user will resolve from a foreground session.

**If `ACTION == "pr"`:**

The branch was pushed in Step 7 (the `no push` + `pr` combination was rejected in Step 0). Open a PR with the recorded source branch as base:

```bash
gh pr create --base '<SOURCE_BRANCH>' --head '<WORKTREE_BRANCH>' --fill
```

After the PR is created, present the closing message:

```text
✓ PR opened (base=<SOURCE_BRANCH>, head=<WORKTREE_BRANCH>).
This agent-view session is done — review/merge the PR, then `git worktree remove` from the main checkout when you're done.
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
