---
name: PR Title and Description Generator
description: "Generate or update GitHub Pull Request titles and descriptions from the actual code changes in the final state. Use whenever a PR is being opened or its title/description written — when the user says 'open a PR', 'create a PR', 'make/raise/submit a PR', 'update the PR', or mentions generating or writing PR descriptions, titles, or summaries. If no PR exists yet it pushes the branch and creates one; otherwise it updates the existing open PR. Analyzes the git diff to document what's actually in the code, not just commit history."
---

# PR Title and Description Generator

Generate or update a PR title and description based on the actual changes in the current branch.

## Core Principle

**Document ONLY what exists in the final state of the code, not the development history.**

**The "before" you describe is what the base branch shipped (`origin/$BASE`) — never an intermediate branch commit.** A bug introduced and fixed within the same branch was never shipped: describe the net effect, not the intra-branch detour. Any "fixes / was broken / now works / adds" statement is implicitly a claim about the baseline — verify it against `origin/$BASE` (§4) before writing it. (`$BASE` is resolved in §2.)

## Bash Command Rule

**NEVER prefix bash commands with comment lines.** Permission patterns in `~/.claude/settings.json` match against the start of the command. A leading `# comment` breaks the match and triggers a manual permission check. Put descriptions in the Bash tool's `description` parameter instead.

If a feature was added in one commit and removed in another, it should NOT be in the PR description. Always verify features exist in `HEAD` before documenting them.

## Analysis Process

### 1. Identify Current Branch and PR

```bash
git branch --show-current

# Fetch PR information including state for validation
pr_info=$(gh pr view --json number,title,state,mergedAt,headRefName,baseRefName 2>/dev/null)

if [[ -n "$pr_info" ]]; then
  # PR exists - extract state and metadata for validation
  pr_state=$(echo "$pr_info" | jq -r '.state // "UNKNOWN"')
  pr_merged_at=$(echo "$pr_info" | jq -r '.mergedAt // "null"')
  pr_number=$(echo "$pr_info" | jq -r '.number')
  pr_title=$(echo "$pr_info" | jq -r '.title')
  pr_head=$(echo "$pr_info" | jq -r '.headRefName')
  pr_base=$(echo "$pr_info" | jq -r '.baseRefName')

  # Security Fix #4: Validate pr_state is a known GitHub PR state (prevent injection)
  case "$pr_state" in
    OPEN|CLOSED|MERGED|UNKNOWN)
      # Valid state, proceed
      ;;
    *)
      echo "WARNING: Unexpected PR state from GitHub API: $pr_state" >&2
      pr_state="UNKNOWN"
      ;;
  esac

  # Security Fix #4: Validate pr_merged_at is either "null" or valid ISO 8601 timestamp
  if [[ "$pr_merged_at" != "null" ]] && [[ ! "$pr_merged_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    echo "WARNING: Unexpected mergedAt format from GitHub API: $pr_merged_at" >&2
    pr_merged_at="null"
  fi

# Security Fix #5: Validate pr_number is present and is a positive integer
  if [[ -z "$pr_number" ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
    if [[ -n "$pr_info" ]]; then
      echo "ERROR: PR data incomplete (missing or invalid PR number)" >&2
    fi
    pr_info=""  # Treat as no PR exists
  fi
fi
```

### 1.1. PR State Validation

**CRITICAL SAFEGUARD**: Before updating any PR, verify it is in a safe state to modify.

**When PR exists (pr_info is not empty):**

**Step 1: Check if PR is OPEN** - safe to proceed immediately:

```bash
if [[ "$pr_state" == "OPEN" ]]; then
  # Safe to proceed with normal update workflow
  # Continue to Step 2
fi
```

**Step 2: If PR is NOT OPEN** - stop and ask user for confirmation:

Determine the specific non-open state:

```bash
if [[ "$pr_state" == "MERGED" || "$pr_merged_at" != "null" ]]; then
  pr_status_type="MERGED"
  pr_status_detail="merged"
  pr_status_note="Note: Updating a merged PR only changes its historical record, not the code."
elif [[ "$pr_state" == "CLOSED" ]]; then
  pr_status_type="CLOSED"
  pr_status_detail="closed without merging"
  pr_status_note="Updating a closed PR is unusual. Most cases should create a new PR instead."
else
  pr_status_type="UNKNOWN"
  pr_status_detail="in an unclear state ($pr_state)"
  pr_status_note="Cannot verify PR state safely. Manual investigation recommended."
fi
```

**Step 3: Present confirmation prompt to user**:

Stop execution and display this message (substitute variables with actual values):

```text
⚠️ **PR State Warning**

The detected pull request is **{pr_status_type}**:

- **PR**: #{pr_number} - {pr_title}
- **Branch**: {pr_head} → {pr_base}
- **State**: {pr_status_detail}

**Options:**
1. **Create new PR** - Open a fresh pull request for these changes (recommended for most cases)
2. **Update {pr_status_type} PR anyway** - Modify the PR's title/description (rarely needed)
3. **Cancel** - Stop without making changes

{pr_status_note}

**What would you like to do?**
```

**Step 4: Wait for explicit user response and validate input**:

```bash
# Read user choice
read -p "Enter your choice (1, 2, or 3): " user_choice

# Security Fix #2: Validate input is exactly 1, 2, or 3
if [[ ! "$user_choice" =~ ^[123]$ ]]; then
  echo "Invalid choice. Please enter 1, 2, or 3." >&2
  exit 1
fi
```

**Step 5: Handle user choice based on validated input**:

```bash
case "$user_choice" in
  1)
    # Option 1: Create new PR
    pr_info=""
    echo "Creating new PR instead..."
    ;;
  2)
    # Option 2: Update anyway
    user_confirmed_update="true"
    echo "Proceeding with update to $pr_status_type PR..."
    ;;
  3)
    # Option 3: Cancel
    user_cancelled="true"
    echo "PR update cancelled by user. No changes made."
    exit 0
    ;;
esac
```

**Note on Interactive vs Non-Interactive Handling**:

If implementing this skill as a non-interactive script, Claude should directly handle the user's verbal choice without prompting:

- If user says "create new PR": Set `pr_info=""`
- If user says "update anyway": Set `user_confirmed_update="true"`
- If user says "cancel": Exit gracefully

**When no PR exists (pr_info is empty):**
Skip validation entirely - the skill will create a new PR (normal workflow).

**API Failure Handling:**
If `gh pr view` returns an error OTHER than "no pull requests found", treat as UNKNOWN state and ask user before proceeding.

### 2. Analyze Final State Changes

**Resolve the base branch first.** All analysis below diffs against `BASE`, not a hardcoded `main` — so a PR targeting a non-`main` base (e.g. a worktree PR against its source branch) is documented accurately. Resolve it once, from the *final* PR state (after the §1.1 decision):

```bash
if [[ -n "$pr_info" ]]; then
  BASE="$pr_base"   # updating an existing PR — use its actual base
else
  BASE="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)"   # no PR / creating — default branch
fi

# Guard: never proceed with an empty base. An empty $BASE silently turns every diff
# below into "no changes" (git log/diff against ""..HEAD exit 0 with empty output) and
# makes `gh pr create --base ""` fall through to gh's default-branch guess — shipping a
# vacuous PR instead of erroring. Stop instead (mirrors /finish Step 9 sub-step 1).
if [[ -z "$BASE" ]]; then
  echo "ERROR: could not resolve base branch (gh unauthenticated / no GitHub remote). Cannot analyze or open a PR." >&2
  exit 1
fi
```

**Shell-variable persistence.** Each Bash tool call is a fresh shell — `BASE` (and the `pr_*` variables captured in §1) do **not** survive across calls. Resolve `BASE` in, or re-establish it within, the same Bash invocation that consumes it (the analysis commands below, and the final `gh pr create` / `gh pr edit` step). When updating a non-open PR via §1.1 option 2, `$pr_base` is the base the PR *had* — the diff against it may be approximate; this is rare and updating a non-open PR is already discouraged.

Get commit count:

```bash
git log "$BASE"..HEAD --oneline | wc -l
```

Get file change summary:

```bash
git diff "$BASE"...HEAD --stat
```

Identify major areas of change:

```bash
git diff "$BASE"...HEAD --name-only | cut -d/ -f1 | sort | uniq -c | sort -rn
```

### 3. Code Impact Summary

Generate a categorized line-count breakdown to quantify the PR's impact. This section helps reviewers quickly understand the scope and nature of changes.

**Step 1: Get the raw totals** (with rename detection):

```bash
git diff --shortstat -M -l0 "$BASE"...HEAD
```

**Step 2: Categorize by purpose** using `git diff --numstat`.

The categorization program lives in [`scripts/code-impact.awk`](scripts/code-impact.awk) and is run with
`awk -f` — **do not paste the program inline.** Keeping it in a file is what removes the old shell-quoting
hazard: transcribed into a Bash one-liner, awk's `$1`/`$2`/`$3` get expanded away by the shell and the
counts silently corrupt. `awk -f` never passes the program through the shell, so the fields are safe. The
block below captures the table, reconciles its `TOTAL` against the same numstat (filtered by the *same*
`$3` test, so renames like `{a => b}/pnpm-lock.yaml` are handled identically on both sides), and on a
mismatch prints an error and **exits without emitting the table** — cheap insurance that the awk file
resolved and ran. It is a total-reconciliation check, not a per-category validator:

```bash
AWK="$HOME/.claude/skills/pr-update/scripts/code-impact.awk"
impact=$(git diff --numstat -M -l0 "$BASE"...HEAD | awk -f "$AWK")
expected=$(git diff --numstat -M -l0 "$BASE"...HEAD | awk '$3 ~ /lock\.yaml$|lock\.json$|\.lock$/ {next} {s+=$1+$2} END{print s+0}')
got=$(echo "$impact" | awk '/^TOTAL/{print $2+$3}')
if [[ "${expected:-0}" -gt 0 && "${got:-0}" -ne "${expected:-0}" ]]; then
  echo "ERROR: Code Impact total ($got) does not reconcile with the diff ($expected) — check that $AWK exists and ran." >&2
  exit 1
fi
echo "$impact"
```

**Notes:**

- Use `-M -l0` for rename detection: `-M` matches moved files so renames don't inflate counts, and `-l0` lifts git's default ~1000-file rename cap so moves still net out on large diffs (otherwise git gives up and a pure move double-counts as add + remove)
- "App code" captures source code files (ts, tsx, rb, etc.) — config/asset files (yml, json, css, lock, svg, md) are separated into "Config/Assets" to keep the signal clean, and test code is split into its own **Unit tests** / **E2E tests** buckets so production churn reads true
- Category patterns live in `code-impact.awk` (first-match-wins, most-specific first) — edit them there to match project structure:
  - `\.stories\.` — Storybook story files
  - `mock|Mock` — Test mocks
  - `generated|packages\/graphql\/` — Generated code (GraphQL codegen, etc.)
  - `packages\/e2e\/` — E2E tests (whole Playwright package: specs, page objects, fixtures, support, config)
  - `\.test\.[jt]sx?$|_spec\.rb$` — Unit tests (Vitest `*.test.ts[x]` + RSpec `*_spec.rb`)
  - `ops\/` — Infrastructure/operations
  - `lock\.yaml$|lock\.json$|\.lock$` — Lock files (skipped entirely)
  - `\.(yml|yaml|json|css|scss|svg|md)$` — Config, locales, styles, assets
- The categorized breakdown often reveals a different story than raw totals (e.g., production code reduced while test coverage increased)
- If `cloc` is available, `cloc --diff "$BASE" HEAD --git` provides an alternative per-language breakdown, but lacks categorization and doesn't handle renames

Include the resulting table in the PR description under a **Code Impact** section.

### 4. Verify What's Actually in the Code

#### Verify the baseline before describing what changed

**Before writing any "fixes / was broken / now works / adds" narrative, confirm what the base branch actually shipped.** The diff shows the *net* change between `$BASE` and `HEAD`, but it does **not** tell you which side was production reality — infer that wrong and you describe a bug that never shipped (or an "add" that already existed).

Resolve the baseline ref once. "What's live in production now" is the **remote** tip `origin/$BASE` (the local `$BASE` can lag the remote and would then misreport the baseline) — but a worktree PR's base may exist only locally with no `origin/` counterpart (§2 permits `BASE="$pr_base"`), so fall back to the local `$BASE` when the remote ref is absent:

```bash
git fetch --quiet origin "$BASE" 2>/dev/null || true
if git rev-parse --verify --quiet "origin/$BASE^{commit}" >/dev/null; then
  BASE_REF="origin/$BASE"   # normal case: fetched remote tip == production
elif git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  BASE_REF="$BASE"          # base-only-local (e.g. a worktree PR's source branch)
else
  echo "ERROR: base '$BASE' resolves neither as origin/$BASE nor locally — cannot verify the baseline. Fetch or check out the base, then retry." >&2
  exit 1
fi
```

Read the claimed-broken (or claimed-new) behavior at `$BASE_REF`:

```bash
git show "$BASE_REF":path/to/file.ts | grep -A5 "relevant_logic"
```

`$BASE_REF` is a verified commit (above), so a `git show` **error** here means the `path` doesn't exist at the baseline — the file is new in this branch (a genuine addition), not an unresolved ref. If `git show` **succeeds** but `grep` is empty, the *pattern* didn't match (a renamed symbol, reformatting) — widen the pattern; don't conclude the behavior is absent.

Decision rule:

- Broken behavior **is** in `$BASE_REF` → it's a real fix; describe the production impact.
- `$BASE_REF` already has the correct behavior → the bug was introduced **and** fixed within this branch and never shipped. Do **not** claim it broke production; describe the net change (refactor / hardening / cohesion) instead.
- Behavior claimed as "added" already exists in `$BASE_REF` → it's a modification, not an addition; say so.

Separately, to confirm a line that *looks* changed was actually changed by this branch (not just reformatted, or changed-then-restored so the net diff hides it), inspect the **merge base** — where this branch diverged. This answers "did this branch touch this line," **not** "what's in production" (the merge base lags production whenever the base advanced after the branch was cut, so never use it for production-impact claims). Capture the merge base first so a resolution failure can't silently fall through to the index blob:

```bash
mb=$(git merge-base "$BASE_REF" HEAD) && git show "$mb":path/to/file.ts
```

#### Verify the feature exists in the final state

**CRITICAL**: For each area of apparent change, verify if it's in the final state:

Check if a feature is in final code:

```bash
git show HEAD:path/to/file.ts | grep -q "feature_name" && echo "PRESENT" || echo "REMOVED"
```

Example — check for authentication plugin:

```bash
git show HEAD:cloud/database/src/SqlDatabase.ts | grep "authentication_plugin"
```

Example — check if a function exists:

```bash
git show HEAD:src/utils.ts | grep -A10 "function myFunction"
```

**If a feature doesn't appear in the final state, DO NOT include it in the PR description.**

### 5. Categorize Changes by Impact

Organize changes into categories based on what's actually present:

- **Infrastructure Changes**: Cloud resources, deployments, architecture
- **Developer Experience**: Tooling, documentation, local development setup
- **CI/CD**: Pipeline changes, automation workflows
- **Breaking Changes**: API changes, configuration requirements, migration needs
- **Dependencies**: Package updates that remain in final package.json/lock files
- **Documentation**: New or updated docs (verify files exist)

### 6. Document Only Present Changes

For each change area:

1. **Verify existence**: Run `git show HEAD:path/to/file` to confirm
2. **Link to files**: Use markdown links with relative paths from repo root
   - Files: `[filename.ts](path/to/filename.ts)`
   - Specific lines: `[filename.ts:42](path/to/filename.ts#L42)`
   - Line ranges: `[filename.ts:42-51](path/to/filename.ts#L42-L51)`
3. **Include code snippets**: For configuration changes, show actual values
4. **Provide context**: Explain why the change was made, not just what changed

## Quality Verification Checklist

Before finalizing the description, verify:

- [ ] Every feature mentioned exists in `git show HEAD:path/to/file`
- [ ] Every "fixes / was broken / now works" claim is verified against the §4 baseline ref (`origin/$BASE`, or its local fallback when the base isn't on origin) — not inferred from the diff
- [ ] No bug is described as production-affecting if it was introduced and resolved within this branch
- [ ] No references to features that were added then removed during development
- [ ] All file links use relative paths from repo root (not absolute paths)
- [ ] Configuration examples reflect actual current state in HEAD
- [ ] Breaking changes are clearly marked with "Breaking Changes" section
- [ ] Testing sections describe actual tests that currently pass
- [ ] Code snippets are from actual files in HEAD, not from memory

## PR Title Formats

See [resources/title-patterns.md](resources/title-patterns.md) for comprehensive title format examples and patterns.

Quick reference:

- Infrastructure: "Enterprise [resource] with [key feature] and [secondary feature]"
- Features: "Add [feature] with [benefit]"
- Bug Fixes: "Fix [specific issue] in [area]"
- Refactoring: "Refactor [area] to [improvement]"

Avoid vague titles like "PR deployment", "Various fixes", or "Update code".

## Description Structure

For detailed templates, see:

- [templates/feature.md](templates/feature.md) - Feature additions
- [templates/bugfix.md](templates/bugfix.md) - Bug fixes
- [templates/infrastructure.md](templates/infrastructure.md) - Infrastructure changes

### Executive Summary (lead with this)

Every description opens with an **`## Executive Summary`** — a self-contained,
plain-language block the user can copy out whole and share with the business team.
It precedes the technical `## Summary` (the two serve different audiences: Executive
Summary = business outcome; Summary = technical TL;DR for reviewers).

Rules for the Executive Summary:

- **Business language only.** Translate the change into its outcome. No file paths, no
  code, no line-count tables, minimal jargon.
- **Lead with impact** — what is better for users or the business now.
- The **For users / Business impact / Security & quality** lines are *suggestions, not
  required sections*. Include only those that genuinely apply; keep each to one line;
  omit the rest. A simple change may be 2–3 sentences with no bullets at all.
- **Accuracy is paramount here.** This is the most-shared, highest-visibility text, so
  over-claiming is the worst case — every impact / "fixes" statement must pass the same
  baseline check from §4 before it's written.
- **End with the PR link** so the shared block is self-contained (see "After Generating
  Description" for how the URL is resolved).
- **Don't pad.** On a small PR where the technical `## Summary` would merely restate the
  Executive Summary, drop the `## Summary` and go straight to the detailed sections —
  two near-identical openers read as bloat. Keep both only when the technical Summary
  adds reviewer-facing detail the Executive Summary deliberately omits.

Use this general template structure:

```markdown
## Executive Summary

[2–4 plain sentences for a business audience: the user-facing or business outcome and
why it matters. No file paths, no code, minimal jargon. Lead with impact.]

[Optional one-liners — include only those that genuinely apply, omit the rest:]
- **For users:** [what changes in their experience]
- **Business impact:** [revenue, risk, cost, compliance, or operational effect]
- **Security & quality:** [notable hardening, test coverage, or reliability gains]

🔗 **Pull request:** [#<number> — <title>](<pr-url>)

## Summary

[1-2 sentence overview of what this PR accomplishes and why]

## [Major Category 1 - e.g., Infrastructure Changes]

### [Subcategory - e.g., Cloud SQL Enterprise Plus]

**[Feature Name]:**
- [Implementation detail verified in HEAD]
- [Configuration detail with actual values]
- [Benefit or impact]

**Implementation:**
- File: [link to main file](path/to/file.ts)
- Configuration: [link to config](path/to/config.yaml)

**Stack Commands:**
- `./stack command_name` - Description

**Documentation:**
- [Link to relevant docs](doc/path/to/doc.md)

[Repeat structure for each major category]

## Code Impact

| Category | Added | Removed | Net |
|---|---|---|---|
| App code | X | X | X |
| Unit tests | X | X | X |
| E2E tests | X | X | X |
| Stories | X | X | X |
| Mocks | X | X | X |
| Generated | X | X | X |
| Ops/Infra | X | X | X |
| Config/Assets | X | X | X |
| **Total** | **X** | **X** | **X** |

[1-2 sentence interpretation of what the numbers mean — e.g., "Production code reduced by X lines through Y. Net increase driven by new test coverage."]

## Breaking Changes

### [Area Affected]
- **What changed**: [Specific change]
- **Migration**: [Steps to migrate]
- **Impact**: [Who/what is affected]

## Dependencies

- Updated `package-name` to version X.Y.Z
- Added `new-package` for [specific purpose]
- Removed `old-package` (no longer needed)

## Testing

**[Test Category]:**
- ✅ [Specific test that validates the change]
- ✅ [Another specific test]
- ✅ [Integration test description]

**[Another Test Category]:**
- ✅ [Test description]

## Cost Impact

[If applicable - infrastructure cost changes]

**Production:**
- Current: $X/month
- Planned: $Y/month (with optimization Z)
- Benefit: [SLA/performance/reliability improvements]

**[Environment]:**
- Base: $X/month (shared infrastructure)
- Per-[unit]: +$Y/month
```

## Verification Workflow

For step-by-step examples of how to analyze and verify PR changes, see [resources/analysis-workflow.md](resources/analysis-workflow.md).

You can also use the verification script:

Check if a feature exists in final state:

```bash
./scripts/verify-feature.sh path/to/file.ts "feature_name"
```

Check if a file exists:

```bash
./scripts/verify-feature.sh packages/api/README.md ""
```

## Important Rules

1. **Verify before documenting** - Always use `git show HEAD:file` to confirm features exist in final state
2. **Verify the baseline before claiming a fix** - Before writing "fixes X" / "was broken" / "now works", confirm the broken behavior actually exists in production via §4's baseline check (`git show "origin/$BASE":file`, with a local fallback when the base isn't on origin). A bug introduced and fixed within this branch never shipped — don't describe it as a production failure
3. **Never mention removed features** - If a commit added something but it was later removed or reverted, don't include it
4. **Focus on outcomes, not process** - Describe the result, not the development journey
5. **Link to actual code** - Every major feature should have a file reference that users can click
6. **Be specific** - "Add MySQL native password authentication" not "Update database config"
7. **Test your claims** - If you say "CI runs connectivity checks", verify the CI file actually shows that
8. **Use present tense** - "Adds X", "Implements Y", not "Added X", "Implemented Y"
9. **Quantify when possible** - "3x performance improvement", "99.99% SLA", "$460/month cost"

## Common Mistakes to Avoid

### ❌ Documenting Removed Features

```
# Commit history shows:
# - Commit A: Add feature X
# - Commit B: Remove feature X
# Final state: No feature X

# WRONG: "Added feature X"
# RIGHT: Don't mention feature X at all
```

### ❌ Vague Descriptions

```
# WRONG: "Updated database configuration"
# RIGHT: "Set default_authentication_plugin to mysql_native_password for Cloud SQL Proxy v2 compatibility"
```

### ❌ Missing Verification

```
# WRONG: Assume a feature exists because you saw it in commit messages
# RIGHT: git show HEAD:path/to/file.ts | grep "feature_name"
```

### ❌ Broken Links

```
# WRONG: [config.ts](/Users/kross/project/src/config.ts)
# RIGHT: [config.ts](src/config.ts)
```

## After Generating Description

**Security Fix #1 - Command Injection Prevention**: When generating `title` and `description` variables, ensure they are assigned using proper quoting to prevent command injection:

Safe assignment (use quotes):

```bash
title="Generated title text"
description="$(cat <<'EOF'
Multi-line description
EOF
)"
```

UNSAFE — never do this: `title=$(some_command)` without quotes could execute commands in the title.

Create or update the PR using GitHub CLI — branch on whether a PR already exists.

### Case A — no PR exists (create)

`pr_info` is empty: either none was found in §1, or the user chose "create new" in §1.1. Push the branch (idempotent), then create the PR against the resolved `$BASE`:

```bash
branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
  echo "ERROR: detached HEAD — check out a branch before opening a PR." >&2
  exit 1
fi

if ! git push -u origin HEAD; then
  echo "ERROR: push failed (diverged remote, or no write access). Resolve manually — do NOT force-push — then retry." >&2
  exit 1
fi

gh pr create --base "$BASE" --head "$branch" --title "$title" --body "$(cat <<'EOF'
[Full description. The Executive Summary link line is a placeholder on this first pass — e.g. 🔗 **Pull request:** _(link below)_ — patched to the real URL in the required follow-up edit below.]
EOF
)"
```

`git push -u origin HEAD` sets the upstream on first push and is a no-op when the branch is already up to date with its remote. It is **not** unconditionally safe — so the `if !` gate stops before `gh pr create` runs whenever the push fails (a diverged remote rejects it non-fast-forward; never force-push to recover). The `branch` guard above rejects a detached HEAD up front (so `--head` can never collapse to an empty value) and supplies `--head "$branch"`, which also keeps `gh` from dropping into its interactive "where should I push this branch?" prompt that would hang a non-interactive session. `$BASE` is the base resolved in §2 (the repo's default branch when creating).

**Fill the Executive Summary PR link.** A new PR's URL doesn't exist until it's created, so create the PR with the Executive Summary's link line as a placeholder (e.g. `🔗 **Pull request:** _(link below)_`), then resolve the real URL and patch the body in one **required** follow-up edit — skip it and the PR permanently shows the placeholder in its most-shared line:

```bash
pr_url=$(gh pr view --json url -q .url)
if [[ -z "$pr_url" ]]; then
  echo "ERROR: could not resolve the new PR's URL — leave the placeholder and retry the edit; do not ship it." >&2
  exit 1
fi
gh pr edit "$pr_url" --body "$(cat <<'EOF'
[Full description with the real PR URL written into the Executive Summary link line]
EOF
)"
```

`gh pr view` with no argument resolves the PR for the current branch. The body heredoc is **quoted** (`<<'EOF'`), so it does **not** expand shell variables — write the *resolved* URL text into the Executive Summary link line (e.g. `[#42 — Title](https://github.com/org/repo/pull/42)`), never the literal token `$pr_url` or the template's `<pr-url>`, which would ship verbatim. This second edit is create-only; an update (Case B) already knows the URL and writes it on the first pass.

### Case B — a PR already exists (update)

`pr_info` is non-empty: an OPEN PR, or a non-open PR the user confirmed updating in §1.1.

**Fill the Executive Summary PR link.** The URL is already known here — resolve it before composing the body and write its *resolved value* straight into the Executive Summary link line, so the single `gh pr edit` below carries it (no second pass needed):

```bash
pr_url=$(gh pr view "$pr_number" --json url -q .url)
if [[ -z "$pr_url" ]]; then
  echo "ERROR: could not resolve PR #$pr_number URL — resolve before composing the body; do not ship an empty link." >&2
  exit 1
fi
```

The `gh pr edit` body below is a **quoted** heredoc (`<<'EOF'`) and will not expand variables — paste the actual URL text (e.g. `https://github.com/org/repo/pull/42`) into the link line, not the token `$pr_url` or the template placeholder `<pr-url>`.

**Pre-Update State Verification** (prevent TOCTOU race condition) — re-check PR state immediately before the edit:

```bash
# $pr_number / $pr_state were captured in §1, possibly in an earlier (now-gone) Bash
# call. If they didn't persist into this shell, stop cleanly — otherwise the TOCTOU
# guard below is silently skipped and the later checks emit a misleading "non-open PR"
# error. Re-run §1's capture and this block together in one Bash invocation.
if [[ -z "$pr_number" || -z "$pr_state" ]]; then
  echo "ERROR: PR identity not present in this shell — re-run §1's capture and this block in a single Bash call." >&2
  exit 1
fi

if [[ -n "$pr_number" ]]; then
  current_pr_info=$(gh pr view "$pr_number" --json state 2>/dev/null)

  if [[ -n "$current_pr_info" ]]; then
    current_state=$(echo "$current_pr_info" | jq -r '.state // "UNKNOWN"')

    # Verify state hasn't changed since initial check
    if [[ "$current_state" != "$pr_state" ]]; then
      echo "ERROR: PR state changed during processing" >&2
      echo "  Initial state: $pr_state" >&2
      echo "  Current state: $current_state" >&2
      echo "  Aborting update to prevent unintended modification" >&2
      exit 1
    fi
  else
    echo "ERROR: PR no longer exists (may have been deleted)" >&2
    exit 1
  fi
fi

if [[ "$user_cancelled" == "true" ]]; then
  echo "ERROR: Attempted to continue after user cancellation" >&2
  exit 1
fi

if [[ "$pr_state" != "OPEN" ]] && [[ "$user_confirmed_update" != "true" ]]; then
  echo "ERROR: Attempted to update non-open PR #$pr_number (state: $pr_state) without user confirmation."
  echo "This indicates a bug in the PR state validation logic."
  exit 1
fi

gh pr edit "$pr_number" --title "$title" --body "$(cat <<'EOF'
[Your full description here]
EOF
)"
```

### Confirm

Either path — view the PR for the current branch:

```bash
gh pr view
```
