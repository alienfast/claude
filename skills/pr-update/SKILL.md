---
name: PR Title and Description Generator
description: "Generate or update a GitHub PR title and description from the code's final state, not its commit history. Use whenever a PR is being opened or its description written — 'open a PR', 'create a PR', 'update the PR', 'write the PR description'. No PR yet → pushes the branch and creates one; otherwise updates the open PR; a PR number or URL updates that PR without touching the checkout."
---

# PR Title and Description Generator

Generate or update a PR title and description based on the actual changes in the current branch, or in a PR named by
number or URL (§1).

## Core Principle

**Document ONLY what exists in the final state of the code, not the development history.**

**The "before" you describe is what the base branch shipped (`origin/$BASE`, or `<mergeCommit>^1` for a PR already
merged — §1) — never an intermediate branch commit.** A bug introduced and fixed within the same branch was never
shipped: describe the net effect, not the intra-branch detour. Any "fixes / was broken / now works / adds" statement is
implicitly a claim about the baseline — verify it against `origin/$BASE` (§4) before writing it.

## Bash Command Rule

**NEVER prefix bash commands with comment lines.** Permission patterns in `~/.claude/settings.json` match against the
start of the command; a leading `# comment` breaks the match and triggers a manual permission check. Put descriptions in
the Bash tool's `description` parameter instead.

## Analysis Process

### 1. Identify the PR

Run `gh pr view --json number,title,state,mergedAt,headRefName,baseRefName` and capture `pr_state`, `pr_merged_at`,
`pr_number`, `pr_title`, `pr_head`, `pr_base` (the block is in [references/gh-mechanics.md](references/gh-mechanics.md)
§ 1). Validate what comes back: a state outside `OPEN|CLOSED|MERGED|UNKNOWN` becomes `UNKNOWN`; a `mergedAt` that is
neither `null` nor an ISO-8601 timestamp becomes `null`; a missing or non-integer number means the PR data is
incomplete — treat it as no PR.

**Targeting a PR by number or URL** (`/pr-update 545`, or another skill passing one from an unrelated branch): the PR is
the subject, not the checkout. It must belong to this checkout's `origin`; a lookup that fails stops the skill (never
"no PR exists"); never check out, switch, or push — the update is Case B, title and body only. Every `HEAD` below is then
`<headRefOid>` and every `$BASE` is `origin/<base>`, or `<mergeCommit>^1` once the PR is MERGED (a merged PR's base
already carries the change, and after a merge-commit merge a three-dot diff against it is empty). The resolution
recipe, the fetch, and the rebase-merge caveat are in `references/gh-mechanics.md` § Targeting a PR by number or URL.

### 1.1. PR State Validation

**Before updating any PR, verify it is in a safe state to modify.** `OPEN` → proceed. `MERGED`, `CLOSED`, or `UNKNOWN`
→ stop and ask, with three options — create a new PR (recommended; **not offered** when the PR was named by number or
URL), update the non-open PR anyway, or cancel — and act only on the user's explicit choice (prompt text and the
variables it sets: `references/gh-mechanics.md` § 1.1). No PR and none named → skip validation; the skill creates one.
`gh pr view` failing with anything other than "no pull requests found" → treat as `UNKNOWN` and ask.

### 2. Analyze Final State Changes

**Resolve the base branch first.** Everything below diffs against `BASE`, not a hardcoded `main` — a PR targeting a
non-`main` base (a worktree PR against its source branch) is then documented accurately. Resolve it once, from the
*final* PR state (after the §1.1 decision):

```bash
if [[ -n "$pr_info" ]]; then
  BASE="$pr_base"
else
  BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"
fi
if [[ -z "$BASE" ]]; then
  echo "ERROR: could not resolve base branch (gh unauthenticated / no GitHub remote). Cannot analyze or open a PR." >&2
  exit 1
fi
```

Never proceed with an empty base: `git log`/`git diff` against `""..HEAD` exit 0 with empty output, so every diff
silently reads "no changes", and `gh pr create --base ""` falls through to gh's default-branch guess — a vacuous PR
instead of an error.

**Shell-variable persistence.** Each Bash tool call is a fresh shell — `BASE` and the `pr_*` variables do **not** survive
across calls. Resolve `BASE` in, or re-establish it within, the same invocation that consumes it. When updating a merged
PR via §1.1 option 2, use §1's merged pair (`<mergeCommit>^1` against `<headRefOid>`). A closed, unmerged PR's base is
the one it had; the diff against it may be approximate.

```bash
git log "$BASE"..HEAD --oneline | wc -l                                      # commit count
git diff "$BASE"...HEAD --stat                                               # file change summary
git diff "$BASE"...HEAD --name-only | cut -d/ -f1 | sort | uniq -c | sort -rn  # major areas
```

### 3. Code Impact Summary

A categorized line-count breakdown so reviewers see the scope and nature of the change. Raw totals with rename detection:

```bash
git diff --shortstat -M -l0 "$BASE"...HEAD
```

`-M` matches moved files so renames don't inflate counts; `-l0` lifts git's default rename cap so moves still net out on
large diffs (otherwise a pure move double-counts as add + remove).

Then categorize with the bundled script — never inline the awk:

```bash
"$HOME/.claude/skills/pr-update/scripts/code-impact.sh" "$BASE"
```

[scripts/code-impact.sh](scripts/code-impact.sh) runs [scripts/code-impact.awk](scripts/code-impact.awk) over one
`git diff --numstat -M -l0`, reconciles `TOTAL` against the same numstat, and on a mismatch exits 1 **without emitting
the table**. **Do not paste either program into this file**: in a Bash one-liner the shell expands awk's positional
field references away, and in a SKILL.md body the Skill tool substitutes the invocation arguments into every literal
dollar-digit token at load time; a script called by path is subject to neither. A second argument diffs against
something other than `HEAD` — for a PR analyzed from outside its checkout pass §1's pair: `code-impact.sh origin/<base>
<headRefOid>` while open, `code-impact.sh <mergeCommit>^1 <headRefOid>` once merged. Category patterns:
`references/description-template.md` § Code Impact category patterns.

Include the resulting table under a **Code Impact** section.

### 4. Verify What's Actually in the Code

#### Verify the baseline before describing what changed

**Before writing any "fixes / was broken / now works / adds" narrative, confirm what the base branch actually shipped.**
The diff shows the *net* change between `$BASE` and `HEAD`; it does **not** tell you which side was production reality.

Resolve the baseline ref once. "What's live now" is the **remote** tip `origin/$BASE` (the local `$BASE` can lag) — but a
worktree PR's base may exist only locally, so fall back to the local `$BASE` when the remote ref is absent. For a PR
already merged, `origin/$BASE` includes the PR itself — set `BASE_REF` to `<mergeCommit>^1` (§1) instead:

```bash
git fetch --quiet origin "$BASE" 2>/dev/null || true
if git rev-parse --verify --quiet "origin/$BASE^{commit}" >/dev/null; then
  BASE_REF="origin/$BASE"
elif git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  BASE_REF="$BASE"
else
  echo "ERROR: base '$BASE' resolves neither as origin/$BASE nor locally — cannot verify the baseline. Fetch or check out the base, then retry." >&2
  exit 1
fi
git show "$BASE_REF":path/to/file.ts | grep -A5 "relevant_logic"
```

`$BASE_REF` is a verified commit, so a `git show` **error** means the path doesn't exist at the baseline — the file is
new in this branch. If `git show` **succeeds** but `grep` is empty, the *pattern* didn't match (a renamed symbol,
reformatting) — widen the pattern; don't conclude the behavior is absent.

Decision rule:

- Broken behavior **is** in `$BASE_REF` → a real fix; describe the production impact.
- `$BASE_REF` already has the correct behavior → the bug was introduced **and** fixed within this branch and never
  shipped. Do **not** claim it broke production; describe the net change (refactor / hardening / cohesion).
- Behavior claimed as "added" already exists in `$BASE_REF` → a modification, not an addition; say so.

Separately, to confirm a line that *looks* changed was actually changed by this branch (not reformatted, or
changed-then-restored), inspect the **merge base**: `mb=$(git merge-base "$BASE_REF" HEAD) && git show "$mb":path/to/file.ts`.
This answers "did this branch touch this line," **not** "what's in production" (the merge base lags production whenever
the base advanced after the branch was cut). Capture `mb` first so a resolution failure can't fall through to the index
blob.

#### Verify the feature exists in the final state

For each area of apparent change: `git show HEAD:path/to/file.ts | grep -q "feature_name" && echo PRESENT || echo
REMOVED`. `./scripts/verify-feature.sh <path>
"<pattern>"` wraps this (an empty pattern checks file existence); it reads the local `HEAD` only, so when targeting a PR
by number use `git show <headRefOid>:<path>`. Worked examples: [resources/analysis-workflow.md](resources/analysis-workflow.md).

### 5. Categorize Changes by Impact

Infrastructure (cloud resources, deployments, architecture); Developer Experience (tooling, docs, local setup); CI/CD;
Breaking Changes (API changes, configuration requirements, migration needs); Dependencies (updates that remain in the
final manifests and lockfiles); Documentation (verify the files exist).

### 6. Document Only Present Changes

For each change area: verify existence (`git show HEAD:path/to/file`); link to files with repo-root-relative paths
(`[filename.ts](path/to/filename.ts)`, `[filename.ts:42](path/to/filename.ts#L42)`,
`[filename.ts:42-51](path/to/filename.ts#L42-L51)`); show actual values for configuration changes; explain why the
change was made, not just what changed.

## Quality Verification Checklist

Before finalizing the description, verify:

- [ ] Every feature mentioned exists in `git show HEAD:path/to/file`
- [ ] Every "fixes / was broken / now works" claim is verified against the §4 baseline ref (`origin/$BASE`, its local
  fallback, or `<mergeCommit>^1` for a merged PR) — not inferred from the diff
- [ ] No bug is described as production-affecting if it was introduced and resolved within this branch
- [ ] No references to features that were added then removed during development
- [ ] All file links use relative paths from repo root (not absolute paths)
- [ ] Configuration examples reflect actual current state in HEAD
- [ ] Breaking changes are clearly marked with a "Breaking Changes" section
- [ ] Testing sections describe actual tests that currently pass
- [ ] Code snippets are from actual files in HEAD, not from memory
- [ ] No issue ID other than this PR's own is preceded by a Linear close keyword
  ([standards/git.md](../../standards/git.md) § Linear auto-close keywords)
- [ ] Every shipped Linear ID from the census appears in the Executive Summary exactly once — a line under `### Issues in
  this release` or the internal line — and no referenced-only ID appears at all
- [ ] Every Executive Summary theme bullet and issue line goes live on merge — nothing under a mirror of an externally
  managed system (identity-provider snapshots, vendor-console exports) is claimed as in this release
- [ ] On a multi-issue PR the Executive Summary opens with a headline and themed `###` sections, carries no issue IDs in
  the themes, and puts `### Issues in this release` last before the PR link — never a roster as the Solution

## PR Title Formats

See [resources/title-patterns.md](resources/title-patterns.md). Quick reference — Infrastructure: "Enterprise [resource]
with [key feature] and [secondary feature]"; Features: "Add [feature] with [benefit]"; Bug Fixes: "Fix [specific issue]
in [area]"; Refactoring: "Refactor [area] to [improvement]". Avoid vague titles like "PR deployment", "Various fixes",
or "Update code".

## Description Structure

The full template, with the single-issue and multi-issue Executive Summary shapes and the Code Impact table, is
[references/description-template.md](references/description-template.md); per-type variants are under `templates/`.

### Executive Summary (lead with this)

Every description opens with an **`## Executive Summary`** — a self-contained, plain-language block the user can copy
out whole and share with the business team. It precedes the technical `## Summary` (business outcome vs. technical TL;DR
for reviewers). Voice, shape and concision follow the [exec-summary skill](../exec-summary/SKILL.md) — single-issue:
problem first, then the fix; multi-issue: a headline, a roll-up by theme, then the per-issue list last as a reference;
concise per item, complete per shipped issue; backticks for user-visible strings; no deferments or process detail. This
block is that skill's PR-description variant: it keeps the `## Executive Summary` heading, uses `###` for the theme and
reference headings, and ends with the PR link in place of the Slack-style underlined title. Plus:

- **Business language only.** Translate the change into its outcome. No file paths, no code, no line-count tables,
  minimal jargon. Issue IDs are the one identifier that stays — the business's handle for "did our customer's issue
  ship?".
- **Census first, roster on a multi-issue PR.** Run the exec-summary skill's census — every Linear ID in the commit
  subjects and bodies, the head branch name, and the existing body — and sort each ID: shipped-and-customer-visible,
  shipped-and-internal, or referenced-only. "Shipped" is two tests, and a commit subject satisfies neither on its own:
  the change is in the `$BASE...HEAD` diff (§4 — an issue whose content already reached `$BASE` through another PR nets
  to zero and is referenced-only, however many of its commits the branch carries), and merging makes it live (a file
  mirroring an externally managed system — an identity-provider snapshot, a vendor-console export — ships nothing on
  merge: a production mirror changed by export was live before the PR, a dev/staging-only change ships on a later
  promote; neither is release content, so leave it out or state it as already live). An ID Linear marks `Duplicate` or
  `Canceled` is referenced-only; credit its work to the absorbing issue. Every shipped ID appears exactly once —
  customer-visible ones as a line under `### Issues in this release`, internal-only ones on the trailing `Also in this
  release, with no customer-visible change:` line as bare IDs — and referenced-only IDs nowhere. Written from memory, a
  bundle's summary names zero of the issues it shipped.
- **On a multi-issue PR the themes are the summary and the issue list is the reference.** A bundle has many problems, so
  no single **Problem:** block. Open with a headline paragraph (1–3 sentences, what this release is about in the
  business's words), then 3–6 `###` theme headings named for what the reader does or gets ("Managing an organization",
  "Support and admin tools" — never a component, subsystem or route), each opening with one sentence of the problem that
  theme solves and followed by 2–6 outcome bullets. No issue IDs in the themes. Then `### Issues in this release` — one
  line per shipped customer-visible ID, `BF-1763: short label`, sorted by ID and last in the block: a lookup, not a
  second narrative, so each label only has to make the issue recognizable. A rode-along change with no ID lives in a
  theme bullet and nowhere else. Concision cuts within a bullet, never a theme's problem sentence or a reference line.
  One Problem paragraph over a long ID-first roster is what no business user reads. A single-issue PR keeps
  **Problem:** / **Solution:**.
- **ID first, colon after, never a close verb before it.** The PR body is a surface Linear scans — `Fixed BF-1763` in a
  roster line moves that issue on merge ([standards/git.md](../../standards/git.md) § Linear auto-close keywords).
- **Lead with impact** — what is better for users or the business now.
- The **For users / Business impact / Security & quality** lines are *suggestions, not required sections*. Include only
  those that genuinely apply, one line each. A simple change may be 2–3 sentences with no bullets. On a multi-issue PR
  they sit after the last theme and before the issue list, and the themes already say what changed for users — drop
  **For users** rather than restate it.
- **Accuracy is paramount here.** This is the most-shared, highest-visibility text, so over-claiming is the worst case —
  every impact / "fixes" statement passes §4's baseline check before it is written.
- **End with the PR link** so the shared block is self-contained (resolved as "After Generating Description" says) — on a
  multi-issue PR it follows the issue list.
- **Don't pad.** On a small PR where the technical `## Summary` would merely restate the Executive Summary, drop the
  `## Summary` and go straight to the detailed sections. Keep both only when the technical Summary adds reviewer-facing
  detail the Executive Summary deliberately omits.

## Writing Rules

Beyond §4's two verifications (feature in `HEAD`; baseline before any "fixes" claim) and §6's links: **focus on
outcomes, not process** — the result, not the development journey; **be specific** — "Add MySQL native password
authentication", not "Update database config"; **test your claims** — "CI runs connectivity checks" means the CI file
actually shows that; **use present tense** — "Adds X", "Implements Y"; **quantify when possible** — "3x performance
improvement", "99.99% SLA", "$460/month cost".

## After Generating Description

**Quote title and description assignments** — `title="Generated title text"`,
`description="$(cat <<'EOF' … EOF)"`. An unquoted `title=$(some_command)` could execute commands in the title.

Create or update with the GitHub CLI — branch on whether a PR exists. The shell blocks are in
[references/gh-mechanics.md](references/gh-mechanics.md); the rules:

- **Case A — no PR exists (create).** `pr_info` is empty (none found in §1, or the user chose "create new" in §1.1 —
  never for a PR named by number or URL). Refuse a detached HEAD; `git push -u origin HEAD` gated with `if !` so a
  failed push (diverged remote — never force-push) stops before `gh pr create`; pass `--base "$BASE" --head "$branch"`
  so `gh` never falls into its interactive push prompt. The new PR's URL does not exist yet, so create with a placeholder
  on the Executive Summary link line, then resolve `gh pr view --json url -q .url` and patch the body in one
  **required** follow-up `gh pr edit` — skipped, the PR permanently shows the placeholder in its most-shared line.
- **Case B — a PR exists (update).** Resolve `pr_url` first and write its resolved value into the link line, so one
  `gh pr edit "$pr_number" --title … --body …` carries it. Immediately before the edit, in the same Bash call as §1's
  capture (the variables do not survive across calls), re-check the PR state (TOCTOU): a state that changed, a PR that
  no longer exists, a recorded cancellation, or a non-open PR without `user_confirmed_update` each abort.
- **Both cases:** the body heredoc is **quoted** (`<<'EOF'`) and does not expand variables — write the *resolved* URL
  text into the link line, never the literal `$pr_url` or the template's `<pr-url>`.
- **Confirm** with `gh pr view` (current branch) or `gh pr view <number>` (named).
