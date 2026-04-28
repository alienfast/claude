---
name: quality-review
description: Adversarial implementation review with triage and fix loop. Hard-gates on `pnpm check`, delegates to the quality-reviewer agent for categorized findings (Critical/High/Medium/Nice-to-Have/Approved), then triages and fixes findings via the developer agent, looping up to 3 review cycles before escalating. Use when the user says 'review my work', 'check this implementation', 'adversarial review', 'quality review', or invokes /quality-review.
---

# Quality Review

Run an adversarial review of the current implementation, then triage and fix findings until the implementation passes cleanly. Designed for use mid-development (before `/finish`) — either standalone, or delegated from `/start` Step 9.

## Arguments

- Issue identifier (e.g., `PL-13`) — optional. Auto-detected from branch/commit when omitted; if no issue can be resolved, the skill runs without requirements-conformance context.
- Positional file paths — optional override of the auto-detected scope.

Examples: `/quality-review`, `/quality-review PL-13`, `/quality-review src/foo.ts src/bar.ts`, `/quality-review PL-13 packages/api/`

## Invariant

**Working Application Contract.** This skill assumes the application was working before the changes under review. `pnpm check` is the gate that proves it still is. A check failure after our changes is never "pre-existing", never "out of scope" — it is our breakage and must be fixed before review proceeds. Turborepo caching makes repeated runs cheap.

## Workflow

### Step 1: Resolve Scope

**Issue ID** (in priority order):

1. User input — e.g., `/quality-review PL-13`
2. Git branch name — extract from branch (e.g., `pl-13-add-foo` → `PL-13`)
3. Latest commit message — extract issue key from `git log --oneline -1` (only if working tree is clean)
4. None — proceed without issue context; the requirements-conformance bullet in the reviewer prompt is omitted

```bash
git branch --show-current
git log --oneline -1
```

**Changed files** (in priority order):

1. Explicit positional args from the invocation
2. Auto-detected via:

   ```bash
   git diff --name-only "$(git merge-base HEAD origin/main)"...HEAD
   git status --short
   ```

   Union the two sets. If the union is empty, warn the user and exit — there is nothing to review.

**Issue requirements** (only if an issue was resolved):

```bash
linear issues get PL-13 --format full
```

Cache the output for the entire run — do not re-fetch on each review cycle.

### Step 2: Working Application Gate

```bash
pnpm check
```

If it **fails**: we took a working application and broke it. That is our failure. Do not proceed to review. Do not rationalize. Delegate fixes to `developer` immediately with the explicit instruction: "The application was working before our changes. It is now broken. Fix it." Re-run `pnpm check`. Repeat until it passes. There is no path forward through a broken application.

If it **passes**: the Working Application Contract holds. Proceed to the adversarial review.

### Step 3: Delegate Adversarial Review

```md
Task for quality-reviewer: Adversarial implementation review for PL-13
Context: Implementation of [issue title or one-line summary of the change] is complete. Your job is to try to break it.
Issue requirements: [Paste requirement checkboxes from the issue — omit this line entirely if no issue was resolved in Step 1]
Files: [List every file in the resolved scope from Step 1]
Requirements:
- Verify every issue requirement is actually satisfied, not just approximately
- Find edge cases with concrete triggering scenarios
- Trace error paths for completeness (including partial failure)
- Check implicit assumptions about inputs, state, and ordering
- Identify concurrency/timing issues under load
- Assess security surface beyond obvious vulnerabilities
- Check integration boundaries with existing code
- Verify conformance against user-level and project-level conventions
Acceptance: Produce a categorized findings report with concrete scenarios for each finding.
```

For large changes spanning multiple domains, **always** spawn parallel reviewers scoped by domain in a single message (e.g., one for backend, one for frontend). The same parallelism principle applies here — reviews are independent and must run simultaneously. Consolidate findings before proceeding.

**Required findings format:**

```markdown
## Review Findings

### Critical (must fix before done)
- [Finding]: [File:line] — [concrete scenario that triggers it]

### High (should fix)
- [Finding]: [File:line] — [concrete scenario that triggers it]

### Medium (real risk, lower probability)
- [Finding]: [File:line] — [scenario and likelihood assessment]

### Nice-to-Have / Out-of-Scope
- [Finding]: [rationale for deferring]

### Approved
- [What survived adversarial review and why]
```

### Step 4: Evaluate Verdict

If findings contain **no Critical, High, or Medium items** → review passes. Skip to the Output section with verdict `passed-clean` (cycle 1) or `passed-after-fixes` (later cycles).

If **any** Critical, High, or Medium findings exist → proceed to Step 5.

### Step 5: Triage & Fix Loop

If Critical, High, or Medium findings exist, triage, fix, and re-review until the implementation passes cleanly.

**1. Fix all findings in touched files — including pre-existing issues.** Leave code better than you found it. If the reviewer found it in a file this skill is reviewing, fix it. Do not defer pre-existing issues to new Linear tickets unless the fix is genuinely large scope (new files, new abstractions, estimated >30 min).

For large-scope pre-existing findings only, ask the user:

- **Default: fix it now** — even if pre-existing, the code is already open and the context is fresh
- If the user chooses to defer, create a Linear issue **and** link it back to the current issue (when one was resolved in Step 1). Both steps are required:

```bash
linear issues create --title "<title>" --description "<one-line summary>" --team <team>
linear issues update <new-issue-id> --depends-on PL-13
```

If no issue was resolved in Step 1, just create the deferred ticket — the dependency link is skipped.

**2. Fix all Critical/High/Medium items** — delegate to `developer`. If multiple findings are in independent files, launch parallel fix agents:

```md
Task for developer: Fix review findings for PL-13
Context: Quality reviewer identified the following issues.
Findings:
- [Finding 1]: [File:line] — [explanation]
- [Finding 2]: [File:line] — [explanation]
Requirements:
- Address each finding precisely — no unrelated changes
- Verify with type checks or tests as appropriate
Acceptance: All listed findings resolved, no regressions.
```

After fixes are applied, you MUST continue through items 3→4→5 below. Do not stop after fixing.

**3. Verify check passes** — after fixes, re-run `pnpm check`. If it fails, delegate further fixes before proceeding.

**4. Re-review (MANDATORY)** — fixes are not complete until re-reviewed. Spawn `quality-reviewer` scoped to only the changed files:

```md
Task for quality-reviewer: Adversarial re-review of fixes for PL-13
Context: Previous adversarial review findings were addressed. Your job is to verify fixes are correct and try to break them again.
Changed files: [list]
Previous findings addressed: [list]
Acceptance: Confirm findings resolved. Flag any new Critical, High, or Medium issues with concrete scenarios.
```

**5. Loop** — if the re-review surfaces new Critical, High, or Medium issues, return to the top of this step (triage → fix → check → re-review).

**Termination**: Maximum 3 review cycles total (initial review + up to 2 re-reviews). If Critical/High/Medium issues persist after 3 cycles, surface them to the user with verdict `terminated-with-open-items`:

> The implementation has gone through 3 review cycles and still has unresolved findings:
> [list findings]
>
> Options:
> - Continue fixing (another round)
> - Accept current state and create follow-up issues
> - Revisit the approach with the architect agent

## Output

When the skill returns to its caller (or to the user, when standalone), present a structured verdict block:

```text
Verdict: passed-clean | passed-after-fixes | terminated-with-open-items
Cycles: N (initial + N-1 re-reviews)
Findings resolved: [list, or "none" if passed-clean]
Deferred issues: [PL-XX, PL-YY, or "none"]
Open items: [list, only when terminated-with-open-items]
```

When delegated from `/start`, this block becomes the "Adversarial review" section of the completion summary verbatim.

## Error Handling

- **`pnpm check` repeatedly fails** after multiple `developer` delegations: surface to the user with the failing output. Do not proceed to review.
- **No changed files detected**: warn the user and exit. Nothing to review.
- **Issue ID provided but `linear` CLI not authenticated**: prompt `linear auth login`, then continue without issue context if the user skips.
- **`quality-reviewer` agent unavailable or returns malformed findings**: surface the raw output to the user; do not silently proceed.
