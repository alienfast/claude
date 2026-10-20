---
name: finish
description: Finish a Linear issue — check off requirements, add completion comment, commit (push only under the `push` token or in `pr` mode), mark Ready For Release. Autonomous mode via the `auto` token (every prompt resolves to the conservative default — abort, never override; used by /auto). Use when the user says 'finish issue', 'done with this issue', 'complete PL-XX', or invokes /finish.
---

# Finish Issue

Post-completion workflow for a Linear issue. Scripts in `~/.claude/scripts/` do the mechanical work (mode detection,
issue-ID resolution, Linear posts, commit, merge); this skill orchestrates them and supplies the judgment — reading the
description, composing the completion comment, gating the release on the review verdict.

## Arguments

- Issue identifier (e.g. `PL-12`) — optional; detected from the branch or the latest commit subject.
- `push` — push the branch after the commit. **The default is no push**: the commit stays local and the closing message
  names the push. `pr` implies `push`; `merge` refuses it (the worktree branch is deleted on merge). `no push` /
  `don't push` / `skip push` restate the default and change nothing.
- `merge` — only inside a `/start wt` worktree, where it is **the default**: merge the worktree branch into its recorded
  source branch, then remove the worktree.
- `pr` — open a pull request for the current branch, from **any** branch. In a worktree the base is the recorded source
  branch and the worktree stays; otherwise the base is the repo's GitHub default branch and no worktree is touched.
  Labels: `with label X` / `label X, Y`. The issue moves to Ready For Release once the PR is open.
- `auto` — autonomous mode (case-insensitive, position-agnostic): every prompt below resolves to its conservative default
  — abort rather than override, proceed-without rather than create; each prompt site states its default. The token and
  its `/full auto` pass-through: `skills/full/SKILL.md` § Auto mode. The `/auto` invocation is the commit/push grant:
  `standards/git.md` § Commit and Push Authorization.

Examples: `/finish`, `/finish PL-12`, `/finish push`, `/finish merge`, `/finish auto PL-12 merge`, `/finish pr PL-12`,
`/finish pr with label pr-deploy`

## Invariant

**`pnpm check` must pass before anything is committed or pushed.** A check failure is always CRITICAL — never
pre-existing, never out of scope, never deferred. Fix it first.

## Workflow

### Preflight: exit plan mode if active

If plan mode is active at skill entry, call `ExitPlanMode` before anything else (every step needs Bash, Write or Edit)
with a one-line plan naming what `/finish` will do — inline a user-typed issue token only when it matches
`^[A-Z]+-[0-9]+$`, uppercased; otherwise write `the current branch's issue`. Never call it when plan mode is off (it
raises a spurious approval prompt); if the indicator is ambiguous, try Step 0 and return here only when
`finish-detect-mode.sh` is blocked by plan mode.

- Approved → Step 0.
- Rejected → stop, no retry, no re-prompt: `BLOCKED-ON-REVIEW: <ISSUE-ID or "current branch"> — user rejected /finish at the plan-mode preflight. No state change.`
- Tool or harness error → surface it verbatim and stop: `BLOCKED-ON-REVIEW: <ISSUE-ID or "current branch"> — ExitPlanMode failed: <first line of error>. No state change.`

### Step 0: Detect Worktree Mode

Normalize the user's args first:

- `auto` → selects this skill's prompt defaults; not passed to the script (its contract is `merge|pr|--push`).
- `merge` / `pr` → pass through whichever is present (both → the script errors). **The token you were dispatched with is
  authoritative — never substitute the other flow** because recent issues in this repo shipped the other way; if it
  looks wrong for this repo, say so and stop.
- `push` → `--push`. The `no push` variants restate the default: pass nothing.
- Labels (`with label X`, `label X, Y`, `--label X`) → collect and carry to Step 9 (`pr` only); never passed to the
  script. Requested labels with a non-`pr` `ACTION` → warn once, `Labels apply only to /finish pr; ignoring: <list>.`

```bash
~/.claude/scripts/finish-detect-mode.sh [merge|pr] [--push]
```

It probes worktree state, validates argument combinations, and prints `KEY=value` lines: `ACTION`, `SOURCE_BRANCH`,
`WORKTREE_BRANCH`, `WT_DIR`, `REPO_ROOT`, `PUSH` (`1` under `push` or `pr`), `CORRUPTION`, `IDENTITY_SOURCE`, and on
exit 4 `CORRUPTION_REASON` / `CORRUPTION_OWNER_IS_ME` / `EXPECTED_BRANCH` / `EXPECTED_BASELINE` /
`EXPECTED_SOURCE_BRANCH`. **Carry the values forward** — later steps substitute them as literal strings (each Bash call
is a fresh shell).

Exit codes:

- 1 — incompatible args (`merge` + `pr`, or `merge` + `push`, the implicit worktree `merge` included). Surface and stop.
- 2 — `merge` outside a `/start wt` worktree. Surface and stop. (`pr` works from any branch.)
- 4 — **worktree identity mismatch.** The worktree does not match the identity `/start` stamped (branch swapped, HEAD
  reset off its baseline, source-branch config wiped, or `lineage-clobbered` / `lineage-unauditable` — committed work
  dropped by a same-lineage rewrite) while the identity sidecar still proves it is a `/start wt` worktree. A parallel
  session's hijack and this session's own un-restamped rewrite look identical; `CORRUPTION_OWNER_IS_ME=1` marks the
  latter as likely, never as proven. **Do not run the normal flow** — merging an unverified tree is the risk the stamp
  exists to stop. Go to Step 0.5.

`SOURCE_BRANCH` set (a worktree) → `ACTION` defaults to `merge`, and `pr` opts into the PR flow with
`base = SOURCE_BRANCH`. Outside a worktree `pr` emits `ACTION=pr` with an empty `SOURCE_BRANCH` and `merge` exits 2.
Both empty → the standard flow.

**Register isolation for a standalone `/finish merge` in a background session.** Steps 5, 7 and 9 write into `<WT_DIR>`
with the Write tool. Under `/full`, `/start` Step 0 entered the worktree via `EnterWorktree`, so those writes land under
the guard; a standalone background `/finish` never ran `/start`, so without registration they are guard-blocked. If this
session has not entered the worktree: `cd '<REPO_ROOT>'` first **only if** cwd is inside the worktree (the same-cwd
refusal), then `EnterWorktree(path=<WT_DIR>)`. **Never** weaken the guard (`worktree.bgIsolation: "none"`, a settings
edit); a still-blocked worktree write is a stop, never a partial merge. The guard: `standards/git-worktrees.md`
§ Worktree-isolated sessions.

### Step 0.5: Worktree Corruption Recovery (only when `finish-detect-mode.sh` exits 4)

Read `references/corruption-recovery.md` now and follow it. It is terminal — a recovered merge ends on `SHIPPED-MERGE`,
a declined or failed recovery on `BLOCKED-ON-RECOVERY` — except its self-rewrite fast path, where a clean Step 0 re-run
(`CORRUPTION=0`) re-enters the normal flow at Step 1 with every gate intact. **Auto mode:** do not ask, recover or
restamp — stop with `BLOCKED-ON-RECOVERY: <ISSUE-ID> — worktree identity mismatch (<CORRUPTION_REASON>); recovery
requires a human. Worktree preserved at <WT_DIR>.`

### Step 1: Identify the Issue

```bash
~/.claude/scripts/detect-issue-id.sh [--input <USER-SUPPLIED-ID>]
```

Tries `--input` → current branch → latest commit subject. Pass `--input` only when the user typed an explicit ID. On
exit 1, ask the user for the identifier (auto mode: Error Handling).

**Cross-worktree sanity check (standard flow only).** When `ACTION` is empty but the issue's branch lives in a linked
worktree of this repo (`git worktree list` shows a path whose basename or branch contains `<issue-id-lowercased>`), the
user has probably run `/finish` from the main checkout while the work sits in a `/start wt` worktree, which would commit
on the wrong branch. Ask, and continue only on an explicit `yes`:

> Issue `<ISSUE-ID>` appears to live in worktree `<path>`. Are you running `/finish` from the wrong cwd? Reply `yes` to proceed here anyway, or `abort` and `cd` into the worktree first.

**Auto mode:** stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — issue appears to live in worktree <path>; wrong cwd for an
unattended /finish. No state change.` Skip the check when Step 0 detected a worktree (`SOURCE_BRANCH` set), when
`ACTION` is `pr` (an explicit choice, never a wrong-cwd accident), or when no ID resolved.

### Step 1.5: Read Quality-Review Verdict + Sub-issues

```bash
~/.claude/scripts/finish-read-verdict.sh PL-12
```

Emits `VERDICT_FILE`, `VERDICT`, `CYCLES`, `SUB_ISSUES`, `SUB_ISSUES_ERROR`, `VERDICT_STALE`, `VERDICT_STALE_REASON`.
Carry them forward: Step 4 embeds them in the completion comment; Step 8 gates on `VERDICT` and `VERDICT_STALE`. The
file is `/quality-review`'s persisted verdict block (schema and publish route: `skills/quality-review/SKILL.md`
§ Output); this skill only reads it.

- `VERDICT`: `passed-clean` / `passed-after-fixes` (converged; Step 8 proceeds unless stale);
  `terminated-with-open-items` / `escalated-to-architect` (non-passing; Step 8 refuses with an override prompt);
  `malformed` (a file exists with no recognized verdict — no `Verdict:` line, the pipe-separated schema example, or a
  value outside the four enums; Step 8 refuses, since the handoff is broken and passing silently would defeat the
  gate); `none-found` (no file at the worktree's or the main checkout's `tmp/` — the review never ran for this issue, or
  ran from another repo; Step 8 refuses with an override prompt).
- `SUB_ISSUES`: the parent's **current `children` array in Linear** — every sub-issue under it now, not only ones this
  review filed; Step 4 labels it so.
- `SUB_ISSUES_ERROR`: set only when `linear-cli issues get` failed. Surface it once and continue — the rest of `/finish`
  does not need sub-issue context, and auth is handled in Step 2's error path.
- `VERDICT_STALE=1`: the file's mtime predates HEAD's commit time, so commits landed after the review and the verdict
  does not describe current code. Step 8 treats a stale pass as refuse-with-override; `VERDICT_STALE_REASON` carries the
  diagnostic for the prompt.

### Step 2: Get Issue Details

```bash
linear-cli issues get PL-12
```

Read the description: requirement checkboxes (`- [ ]`), success criteria, Must Have versus Nice to Have.

### Step 3: Read Current Description as JSON

```bash
linear-cli issues get PL-12 --output json
```

Decide which `- [ ]` items this session completed. Post nothing yet — Step 5 sends description and comment together.

### Step 4: Generate Completion Comment

**Every `<...>` token is a substitution site — resolve it before posting; never send a literal placeholder to Linear.**

```markdown
## Implementation Complete

Branch: `<actual branch name>`

### What was done
- Key changes (files created/modified, features implemented)

### Design decisions
- Key technical choices and why they were made

### Verification
- What was verified (type checks, tests, dev server, etc.)

### Adversarial review
- Verdict: <VERDICT> (cycles: <CYCLES>)
- Sub-issues (current children of this issue): <comma-list of SUB_ISSUES, or the bare word `none` when empty>
- Open items: <text from VERDICT_FILE's Open items: section — only when VERDICT is terminated-with-open-items, escalated-to-architect or malformed>

### Notes
- Unchecked items with the reason
- Follow-up work identified
```

Omit sections with no content. Omit **Adversarial review** entirely when `VERDICT=none-found`; on a passing verdict drop
the `Open items` bullet and keep the other two.

**Reconcile filing promises before posting.** Re-read this issue's plan and checkpoint comments for promised filings
("a follow-up will be filed", an out-of-scope census "recorded, not skipped", work named for later). Each resolves to an
issue ID named in this comment, or is filed now through `standards/linear-filing.md` — nothing downstream re-reads the
plan, so an unfiled promise vanishes with the session. The same recipe governs every other filing this run makes, the
post-merge ones included (a flake record a project convention asks for, say): nothing frames those, which is exactly when
a bare, unlabeled create duplicates something already filed. Search first, file through the standard, end on a routing
label.

**A production-readiness act recorded only in Notes is an unfiled promise.** The spec's `### Out of Scope` may name a
human act the shipped code needs in production — an operator-set secret or env var, a vendor-console setting, a webhook
or DNS registration. Notes is a record, not a tracker: no ranking or triage pass re-reads a shipped issue's comment, and
Step 8 gates on the verdict alone, so the issue ships either way. Resolve any such act to an issue ID named here, or
file it now through the same recipe: label `human` (`standards/issue-spec.md` § The `human` label; keep `specified` when
the body meets the bar), `Backlog` (this run may be unattended), the release it gates named in the body, and wired by
what each issue does without the act — `related` to one that merely goes dark (this issue, whose spec required the clean
degradation), `blocks` toward any unshipped dependent whose behavior is wrong without it. When the act is performed
**on** what this issue ships (a hand-deploy of its stack, a verification on an environment running its code) the
direction reverses: this issue `blocks` the `human` tail. Never `blocks` toward a dark dependent — a `human` issue never
ships unattended, so that edge strands it for nothing. Unlike the Nice to Have rule below, which declines an
opportunity, this is a prerequisite the release scope has to carry.

**An unimplemented `### Nice to Have`: one line in Notes, and stop.** It never files, never blocks, never carries
forward — not when a dependency gates it (a gated opportunity is simply not opportune), and not when the plan promised a
follow-up for it (the promise was wrong; the Notes line recording the decline is the correction). The only path from a
skipped Nice to Have to tracked work is a human promoting it to `### Must Have` through `/spec`.

### Step 5: Post Description Update + Completion Comment

Write both files, then post them in one call:

1. `tmp/linear-description-<issue-id-lowercased>.md` — the full description with completed `- [ ]` flipped to `- [x]`,
   everything else preserved exactly.
2. `tmp/linear-comment-<issue-id-lowercased>.md` — the Step 4 comment body.

```bash
~/.claude/scripts/finish-post-update.sh PL-12 tmp/linear-description-pl-12.md tmp/linear-comment-pl-12.md
```

Exit codes: 1 (validation — missing or empty files), 2 (Linear API failure).

### Step 6: Verify Check Passes

```bash
pnpm check
```

A failure is CRITICAL: do not commit or push; fix and re-run until green. **Auto mode:** at most **2** fix delegations;
still red → stop with `BLOCKED-ON-REVIEW: <ISSUE-ID> — pnpm check failing at /finish gate after 2 unattended fix
attempts. Nothing committed.`

### Step 7: Git Commit (push is opt-in)

1. Stage files by name — never `git add -A` / `git add .`. **Derive the list from a fresh `git status --short` now**,
   never from a list captured earlier: review-fix cycles touch files beyond the original set, and a stale list ships a
   commit whose halves don't match (the working tree passes `pnpm check`, the committed tree fails CI). Confirm no
   unstaged tracked modification belonging to this issue remains.
2. Write the message to `tmp/finish-commit-<issue-id-lowercased>.md`. The issue ID **must** appear (the script enforces
   it for Linear auto-linking), and **only `<ISSUE-ID>` may follow a close keyword** — Linear scans commit messages too,
   so "fixes PL-14" in the body moves PL-14 on merge while "follow-up to PL-14" is safe
   ([`standards/git.md`](../../standards/git.md) § Linear auto-close keywords).

   ```text
   PL-13: <short imperative summary>

   <optional body explaining the why>
   ```

3. Commit:

   ```bash
   ~/.claude/scripts/finish-commit.sh PL-13 tmp/finish-commit-pl-13.md [--push]
   ```

**Pass `--push` only when Step 0 emitted `PUSH=1`** (the user typed `push`, or `ACTION=pr`). Otherwise the commit stays
local and a human, or a later separate grant, pushes it. `ACTION=merge` never pushes (Step 0 refuses `merge` + `push`):
the temp branch is deleted on merge, and the merge commit reaches origin only when the source branch is pushed, which
this skill never does — a human pushes it, or a project that sets `AUTO_PUSH_MAIN=lazy` in its committed
`.claude/settings.json` hands it to `/auto`'s `auto-push-main.sh` (at a deploy-gated pick and at deadline wind-down,
never per merge: every push is a CI build). The grant: `standards/git.md` § Commit and Push Authorization.

The script handles pre-staged changes (commit, then push only under `--push`), already-committed-but-ahead (push under
`--push`, otherwise a reminder naming the push) and already-synced (no-op). Unstaged-only → exit 2: go back and
`git add`. In the standard flow with `PUSH=0`, the `RELEASED:` line says the commit is local and names the push
(`git push` from `<WORKTREE_BRANCH>`), so nobody reads the tag as "on origin" — `Ready For Release` describes the
commit, as it does for an unpushed merge.

### Step 8: Verdict Gate and Ready For Release

**Every `<...>` token in a prompt or comment body is a substitution site**, as in Step 4.

**Who performs the transition** — whoever completes the lifecycle, so Linear never shows `Ready For Release` for
unmerged code:

- `ACTION` empty (standard flow): Step 8 runs `linear-cli issues update <ISSUE-ID> --state "Ready For Release"` itself.
- `ACTION=merge`: Step 8 is the **gate only**. Step 9 runs `~/.claude/scripts/mark-ready-for-release.sh` after
  `finish-merge.sh` exits 0, and the launchd drainer runs the same script when it lands a deferred merge — a deferred
  issue stays **In Progress**, which is the truth.
- `ACTION=pr`: gate only, likewise. Step 9 transitions after `gh pr create` succeeds — an open PR is work waiting for
  its release; `In Review` is a human-review request, never a ship's landing state.

"Proceed" below means: standard flow → run the update; `merge` / `pr` → go to Step 9 without touching Linear state.
Discriminate on `ACTION`, not `SOURCE_BRANCH` — a non-worktree `pr` has an empty `SOURCE_BRANCH` and still reaches
Step 9.

**The gate**, on Step 1.5's values:

- `passed-clean` / `passed-after-fixes` with `VERDICT_STALE=0` → proceed. Standard flow:

  ```bash
  linear-cli issues update PL-12 --state "Ready For Release"
  ```

  On success end on `RELEASED:` (§ Terminal tags); never emit it when the update failed — see below.

- Anything else — a stale pass, `terminated-with-open-items`, `escalated-to-architect`, `malformed`, `none-found`, or an
  unrecognized value (treat as `malformed`) → **refuse with override.** Read `references/verdict-overrides.md` now: each
  branch's prompt, the override-comment wording and its merge/pr-mode variant, the `re-run` procedure (it dispatches
  `/quality-review` and resumes at Step 1.5 — never a stop), and the `abort` terminators. **Auto mode:** never prompt,
  override or re-run — emit that branch's `abort` terminator with `auto mode refused the override` as the reason and
  stop; `none-found` keeps its own line,
  `BLOCKED-ON-REVIEW: <ISSUE-ID> — no /quality-review artifact; unattended runs never ship unreviewed. Run /quality-review then /finish manually.`
  The failing tag is `/auto`'s signal to count a failure and surface the issue to a human.

**State-update failure (standard flow only).** If `linear-cli issues update` exits non-zero:

1. On a "no such state" rejection, probe `linear-cli statuses list -t <TEAM>` (team key = the ID prefix) and pick the
   first state matching `/^ready[ _-]?for[ _-]?(release|deploy|ship)$/i` — an exact match, never a prefix (it must not
   latch onto `Ready For Review`), and never a bare `Ready`, too ambiguous to route into (rename it to
   `Ready For Release` to use it). Retry with the matched name; success → `RELEASED:`.
2. No match, or the retry fails → surface the error and end on `BLOCKED-ON-REVIEW: <ISSUE-ID> — linear-cli issues update
   failed: <reason>. State NOT changed; this issue remains In Progress.`, with `<reason>` distilled to one line (the
   first informative line of a multi-line error) so the agents-list parser reads the tag. Do not continue to Step 9.

`merge` and `pr` run no update here; `mark-ready-for-release.sh` carries the same fallback.

### Step 9: Finalization (`merge` or `pr` only)

Skip when `ACTION` is empty — the standard flow ended at Step 8. `merge` always has a worktree (`SOURCE_BRANCH` set);
`pr` runs with or without one. **Step 9 is terminal:** after the closing message, `/finish` runs no further bash.
Whether the *session* ends is the Nesting rule in `standards/lifecycle-tags.md`: standalone or under a bare `/full`,
stop; under `/auto`, the tag ends `/finish` and control returns to `/auto` Step 4 in the same turn — ending the turn on
the tag kills a self-paced loop, since no wakeup is armed. That scoping covers every tag `/finish` emits in auto mode,
`BLOCKED-ON-REVIEW` aborts included. Substitute Step 0's values into the commands below as literal strings.

#### `ACTION=merge`

`finish-merge.sh` brings the worktree branch up to source's tip **inside the worktree** (private to this session, so no
lock, and conflicts are resolved there, never in the main checkout) and then advances source without ever merging in
the main checkout, leaving it mid-merge, or switching its HEAD — the mechanism, its self-serialization, which blocks
are transient, and the posture for high-concurrency runs are `standards/git-worktrees.md` § `/finish merge` between
worktrees. The common case (one commit ahead, source unmoved) lands as a single `PL-XXX: <summary>` line with no merge
commit; when source moved, a merge commit is created and the script stops (exit 5) so the **merged** tree is gated
before it lands — Step 7's `pnpm check` proved this branch alone, and `related` siblings ship in parallel on the strength
of this gate.

1. **Write the merge-commit message** to `<WT_DIR>/tmp/git-merge-msg-<issue-id-lowercased>.md` with the `Write` tool
   (absolute path). It is used only in the divergent-merge case and during conflict resolution; keep it to the bare
   subject — any other issue ID behind a close keyword here moves that issue when the merge lands
   ([`standards/git.md`](../../standards/git.md) § Linear auto-close keywords):

   ```text
   Merge PL-13
   ```

2. **Run the merge in a single Bash call** — `cd` to the main checkout first (the script removes the worktree on
   success, so cwd must not be inside it):

   ```bash
   cd '<REPO_ROOT from Step 0>'
   ~/.claude/scripts/finish-merge.sh '<WT_DIR>' '<SOURCE_BRANCH>' '<WORKTREE_BRANCH>' '<WT_DIR>/tmp/git-merge-msg-pl-13.md'
   ```

   `[finish-queue] waiting for …` on stderr means another session holds the merge slot: surface it and wait. The OS
   releases the lock when the script exits, however it exits.

**Exit 0 — the merge landed; now perform the transition Step 8 deferred:**

1. **Release the worktree registration first.** With the worktree removed, this session's isolation root (registered by
   `EnterWorktree` at `/start` Step 0, or at Step 0 here) points at a deleted directory and cwd has reset to
   `<REPO_ROOT>`, so the guard would refuse the next Bash command with an instruction that cannot be followed (re-run
   from `<WT_DIR>`). Call `ExitWorktree(action: "keep")` **unconditionally** — it releases the registration, returns the
   session to `<REPO_ROOT>`, removes nothing, and is a no-op without a registration, so it is right in the
   `CLEANUP-FAILED:` sub-case too. Afterwards a background session's Write-tool edits outside a worktree are refused;
   nothing here needs one, and `/auto` Step 4's state write goes through the shell.
2. Run `~/.claude/scripts/mark-ready-for-release.sh <ISSUE-ID>` (same team-state fallback as Step 8). Exit 0 → the
   closing message. Non-zero → the merge succeeded but Linear did not update: do **not** undo the merge; surface the
   error and end on
   `SHIPPED-MERGE: <ISSUE-ID> — <WORKTREE_BRANCH> merged into <SOURCE_BRANCH>, worktree removed, but Linear state update FAILED: <reason>. Mark Ready For Release manually.`
   — still `SHIPPED-MERGE`, since the code shipped (with a `CLEANUP-FAILED:` line, sub-step 3's wording replaces
   `worktree removed` here too).
3. **A `CLEANUP-FAILED:` line on stdout means the merge landed and the worktree stayed** — `git worktree remove` refused
   over untracked or modified files, and the script never forces, since a blocking file can be work this session forgot
   to commit. The issue still ships (sub-step 2 and the `SHIPPED-MERGE` tag stand, so `/auto` records a ship), but exit 0
   alone carries the leftover nowhere, so put it where a human reads:
   - a follow-up `### Notes` comment naming the worktree path, the blocking paths and the remedy line the script
     printed — write the body to `<REPO_ROOT>/tmp/linear-cleanup-<issue-id-lowercased>.md` via the shell (heredoc or
     `printf`; the registration was just released, so a Write-tool edit under `<REPO_ROOT>` is guard-blocked in a
     background session), then `~/.claude/scripts/linear-post.sh comment <ISSUE-ID> <that path>`;
   - the tag: replace `worktree removed` with
     `worktree NOT removed (CLEANUP-FAILED: <blocking paths>; see the completion comment)`, so `/auto`'s ledger line
     carries the leftover.

   Do not clear it yourself — no deleting the blocking paths, no `--force`, no re-run: scratch or forgotten work is the
   human's call, and the hourly reaper reports the worktree as merged-but-dirty until it is cleared
   (`skills/reap-worktrees/SKILL.md`). Interactively, surface the paths and ask once.
4. Surface the merge output and emit the `SHIPPED-MERGE` closing message (§ Terminal tags). Standalone: stop. Under
   `/auto`: continue with `/auto` Step 4.

**Other exit codes** — read `references/merge-exit-codes.md` for the full handler of each:

- **1** — hard precondition failure (source branch missing, worktree gone or on the wrong branch, uncommitted tracked
  changes, merge unverifiable). Surface and stop on `BLOCKED-ON-REVIEW: <ISSUE-ID> — <reason from the script>.
  <recovery>.`; attempt no recovery.
- **3** — transient block. The script has already self-enqueued the merge; the drainer lands it and marks Ready For
  Release, and the issue stays In Progress meanwhile. Do nothing else: emit the `DEFERRED-MERGE` closing message.
- **2** — the worktree needs work in place: `GENERATED-DISCARD:` (a `merge=ours` driver dropped source's generated
  hunks — measure the dropped delta before regenerating anything) or `CONFLICT:` / `RESUME:` (resolve in the worktree
  with `Edit`, gate, commit, re-invoke).
- **5** — `MERGED-SOURCE:`, the merged-tree gate. `pnpm check` from `<WT_DIR>`; green → re-invoke the same line (it
  finalizes, or returns 5 or 2 again if source moved meanwhile); red → the reference's exit-5 handler.

#### `ACTION=pr`

The branch is already on origin (Step 7 pushed under `PUSH=1`). Resolve the base: `SOURCE_BRANCH` when set (a
`/start wt` worktree), otherwise the repo's default branch:

```bash
gh repo view --json defaultBranchRef -q .defaultBranchRef.name
```

If that fails (no GitHub remote, `gh` unauthenticated) there is nowhere to open the PR — never guess a base; stop on
`BLOCKED-ON-REVIEW: <ISSUE-ID> — cannot resolve PR base (<first error line>). Branch pushed; open the PR manually.` The
default branch is the base by design even when the branch forked elsewhere; the user retargets in GitHub if needed.

Then read `references/pr-mode.md` and follow it: label verification, title and body from the diff, `gh pr create`,
`mark-ready-for-release.sh`, and the `SHIPPED-PR` closing message.

## Terminal tags

Every terminal path of `/finish` ends on exactly one tagged line (`standards/lifecycle-tags.md` owns the vocabulary).
Emit it **bare**: the closing messages below sit in fences for readability, but the real tag is the last non-empty line
of the message that carries it, with no fence around it and nothing after it — the `full-continue.sh` hook anchors on
that line (of each message, not of the turn, so `/auto` Step 4's later output does not defeat it). Each closing
message's leading sentence is standalone-only; under `/auto` omit it and continue with `/auto` Step 4 after the tag.
`re-run` at the Step 8 gate has no tag — it dispatches and resumes — and a failed state update never emits `RELEASED:`.

| Tag | Emitted at | Line |
| --- | --- | --- |
| `RELEASED` | Step 8, standard flow, after a successful state update | `RELEASED: <ISSUE-ID> — <one-line summary>`; with `PUSH=0` the summary says the commit is local and names the push |
| `SHIPPED-MERGE` | Step 9, merge exit 0 (also a successful corruption recovery) | closing message below |
| `DEFERRED-MERGE` | Step 9, merge exit 3 | closing message below |
| `SHIPPED-PR` | Step 9, after `gh pr create` and the transition | closing messages below |
| `BLOCKED-ON-REVIEW` | preflight; Step 1; Step 6; Step 8 `abort` or failed update; Step 9 stops; every auto-mode conservative stop | `BLOCKED-ON-REVIEW: <ISSUE-ID> — <one-line reason>`; state unchanged |
| `BLOCKED-ON-RECOVERY` | Step 0.5 | `BLOCKED-ON-RECOVERY: <ISSUE-ID> — worktree identity mismatch (<CORRUPTION_REASON>); <declined, or the failure>. Worktree preserved at <WT_DIR>.` |

```text
This agent-view session is done — close it and dispatch a new session for the next issue.

SHIPPED-MERGE: <ISSUE-ID> — <WORKTREE_BRANCH> merged into <SOURCE_BRANCH>, worktree removed, Ready For Release.
```

```text
Merge deferred — it'll retry automatically once the blocker clears. Inspect any time with /merge-queue.

DEFERRED-MERGE: <ISSUE-ID> — merge queued (<reason>); will retry automatically. Check with /merge-queue.
```

Worktree PR (`SOURCE_BRANCH` set — the worktree stays until the PR merges, and the tag names the cleanup once):

```text
This agent-view session is done. The worktree stays in place until the PR merges.

SHIPPED-PR: <ISSUE-ID> — PR opened (base=<BASE>, head=<WORKTREE_BRANCH>), labels: <list|none>, issue Ready For Release. After merge, run `git worktree remove .claude/worktrees/<issue-id-lowercased>` from the main checkout.
```

Plain-branch PR (`SOURCE_BRANCH` empty — nothing to clean up):

```text
This agent-view session is done. The PR is open against <BASE> — review and merge it there.

SHIPPED-PR: <ISSUE-ID> — PR opened (base=<BASE>, head=<WORKTREE_BRANCH>), labels: <list|none>, issue Ready For Release. Review/merge the PR.
```

## Error Handling

- Issue already Ready For Release or Done: warn and ask whether to proceed (comment only). Auto mode: stop with
  `BLOCKED-ON-REVIEW: <ISSUE-ID> — already <state>; nothing to finish.`
- No uncommitted changes: Step 7 is a no-op (the script reports the branch's state against upstream); the rest runs.
- `linear-cli` unauthenticated: prompt `linear-cli auth oauth`. Auto mode: stop with
  `BLOCKED-ON-REVIEW: <ISSUE-ID or "current branch"> — linear-cli unauthenticated. Nothing committed, no state change.`
- No issue ID resolvable: ask the user. Auto mode: stop with
  `BLOCKED-ON-REVIEW: current branch — no issue ID resolvable. No state change.`

## References

Read each at the step that names it; none is loaded otherwise.

- [`references/corruption-recovery.md`](references/corruption-recovery.md) — Step 0.5, when `finish-detect-mode.sh`
  exits 4: surfacing the mismatch, the self-rewrite restamp fast path, the recovery question, `finish-recover.sh` exits.
- [`references/verdict-overrides.md`](references/verdict-overrides.md) — Step 8, when the verdict is not a fresh pass:
  per-branch prompts, override comments, the `re-run` dispatch, terminators.
- [`references/merge-exit-codes.md`](references/merge-exit-codes.md) — Step 9 merge, when `finish-merge.sh` exits 1, 2,
  3 or 5: `GENERATED-DISCARD:` measurement, conflict resolution, the merged-tree gate.
- [`references/pr-mode.md`](references/pr-mode.md) — Step 9 `pr`, once the base resolves: labels, title and body from the
  diff, `gh pr create`, the transition, the closing message.
