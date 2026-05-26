---
name: quality-review
description: Adversarial implementation review with triage and fix loop. Hard-gates on `pnpm check`, delegates to the quality-reviewer agent for categorized findings (Critical/High/Medium/Nice-to-Have/Approved), then triages and fixes findings via the developer agent. Loops until a re-review surfaces no new Critical/High/Medium findings (convergence), with a soft ceiling of 5 cycles before asking the user how to proceed. Use when the user says 'review my work', 'check this implementation', 'adversarial review', 'quality review', or invokes /quality-review.
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

**Issue ID** — delegate to the shared script (same one `/start` and `/finish` use):

```bash
~/.claude/scripts/detect-issue-id.sh [--input <USER-SUPPLIED-ID>]
```

Pass `--input` only when the user typed an explicit ID (e.g., `/quality-review PL-13`). The script tries `--input` → current branch → latest commit subject, in that order. On exit 1 (no ID resolvable), proceed without issue context — the requirements-conformance bullet in the reviewer prompt is omitted.

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
- [Finding]: [file:line] — [rationale for deferring]

### Approved
- [What survived adversarial review and why]
```

### Step 4: Evaluate Verdict

If findings contain **no Critical, High, or Medium items** → review passes. Proceed to Step 6 with verdict `passed-clean` (cycle 1) or `passed-after-fixes` (later cycles).

If **any** Critical, High, or Medium findings exist → proceed to Step 5.

Nice-to-Have / Out-of-Scope findings do not affect the verdict; they are handled in Step 6 once the loop terminates cleanly.

### Step 5: Triage & Fix Loop

If Critical, High, or Medium findings exist, triage, fix, and re-review until the implementation passes cleanly.

**1. Fix every Critical/High/Medium finding in scope, including pre-existing ones in touched files.** Leave code better than you found it. If the reviewer flagged it at this severity, it is not deferrable — Step 6 handles deferrable items via the Nice-to-Have category.

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

**Termination**: The loop terminates by **convergence** — when a re-review surfaces no new Critical, High, or Medium findings, exit Step 5 with verdict `passed-after-fixes` and proceed to Step 6.

**Soft ceiling**: After **5 review cycles** (initial review + up to 4 re-reviews), pause and ask the user how to proceed instead of looping silently. Reviewers tend to find *something* on every cycle, so an unbounded loop can run away even when the implementation is materially improving. The ceiling is not a hard cap — the user can extend it.

```text
The implementation has gone through 5 review cycles and still has unresolved findings:
[list current findings]

Cycle-by-cycle trend: [e.g., "5 → 3 → 2 → 2 → 2" so the user can see whether progress is stalling or converging]

Options:
1. Continue fixing — run another N cycles, default N=3
2. Accept current state — terminate with verdict `terminated-with-open-items` and treat surviving findings as Open items
3. Revisit the approach with the architect agent

Reply with `1` (optionally `1 5` for a custom N), `2`, or `3`.
```

If the user picks option 1, resume the loop with the new ceiling raised by N. If `2`, terminate with `terminated-with-open-items`. If `3`, terminate and surface to architect — the architect's recommendation supersedes anything in the verdict block.

### Step 6: Deferred Items Triage

Runs once, only after the fix loop terminates with `passed-clean` or `passed-after-fixes`. On `terminated-with-open-items` this step is skipped, but the consolidated list from sub-step 1 is still appended to the verdict block under `Open items` so deferred findings are not silently lost.

**Substitution token.** `<ISSUE-ID>` in the templates below means the issue ID resolved in Step 1. If no issue was resolved, replace `for <ISSUE-ID>` with `for the current change set` and skip the dependency-link command in sub-step 6.

**Malformed user replies.** If the user replies to any prompt below with input you cannot parse (e.g., `1-3`, `the first three`, `sure`), re-prompt once with the exact accepted syntax — including the `suggested` shortcut — and a literal example. After a second malformed reply, fall back to a *safe default*: for sub-step 4, default to `none` (do not start unrequested work); for sub-step 6, default to `all` (filing extra Linear issues is recoverable, silently dropping findings is not). Note: `suggested` is an accepted input, never a fallback. On re-prompt at sub-step 6, re-render the full template; do not abbreviate on retry.

**Verdict downgrade.** Step 6 can transition the run state from `passed-after-fixes` back to `terminated-with-open-items` (see sub-step 5 regression-cap path). When that happens, the new verdict overrides the verdict assigned at Step 4.

**1. Consolidate.** Collect every Nice-to-Have / Out-of-Scope finding reported across all review cycles. Deduplicate by `file:line + finding text`; if a finding was emitted without a file:line (a malformed-but-recoverable reviewer output, see Error Handling), fall back to deduplicating by finding text alone (trim, casefold, and collapse internal whitespace before comparison to absorb cosmetic differences). If the consolidated list is empty, skip the rest of this step.

**2. Classify.** Label each item `fix-now` or `defer-as-issue` using the criteria below. The label routes the item to sub-step 4 (in-session fix) or sub-step 6 (Linear issue) by default — the user can override at either prompt.

**Fix now** — *all* of the following hold:

- One obviously-correct change (no decision between valid alternatives)
- Localized (single file or small contiguous region)
- No change to public APIs, schemas, exported types, or contracts
- Small (~<30 lines diff, no new abstractions)
- Attach a one-word kind tag: `[mechanical]`, `[naming-only]`, `[missing-guard]`, `[typo]`, `[dead-code]`, etc.

**Defer as issue** — *any* of the following hold:

- Requires a design choice between valid alternatives
- Cross-cutting / touches multiple modules
- Changes public APIs, schemas, or external contracts
- Needs broader test, perf, or security strategy
- Significant scope (refactor, new abstraction)
- Attach a one-word kind tag: `[design TBD]`, `[cross-cutting]`, `[api-change]`, `[needs-perf-data]`, `[scope: multi-module]`, `[refactor]`, etc.

If an item triggers criteria from both sides (e.g., mechanical but touches a public type), the **defer-as-issue** side wins — design implications dominate size.

**3. Present grouped lists.** Render the classification as two labeled sub-groups with continuous numbering across both. Omit a group header entirely if its group is empty (do not print "(none)").

```text
Deferred items surfaced during review:

Suggested fix now (no decisions required):
  1. [Finding] — [file:line] — [tag] — [rationale]
  2. [Finding] — [file:line] — [tag] — [rationale]

Suggested defer as issue (needs research/planning):
  3. [Finding] — [file:line] — [tag] — [rationale]
  4. [Finding] — [file:line] — [tag] — [rationale]
```

**Prompt mechanism (applies to sub-steps 4 and 6).** Sub-steps 4 and 6 are **two independent prompts** — never combine them into one. Each prompt asks about exactly one action verb (sub-step 4 = "fix now", sub-step 6 = "file as issue"); using both verbs in a single checklist makes the selection state ambiguous. Specifically:

- Render the grouped list from sub-step 3 as **plain text above the question**. Do not rewrite an item's label to encode the action verb (e.g., never render `defer-as-issue` items as "File X as a Linear issue" inside sub-step 4 — the [tag] communicates the recommendation; the label is the finding).
- The question itself MAY be an `AskUserQuestion` multiSelect, but if so:
  - Every option label must read as "fix [finding]" at sub-step 4, and as "file [finding]" at sub-step 6 — one verb per prompt.
  - Pre-check (`[✔]`) the items the classification suggests (`fix-now` group at sub-step 4; `defer-as-issue` group at sub-step 6) so the user can accept the suggestion with one click.
  - Do **not** add description text that previews sub-step 6 (no "items not selected will be filed as issues") — sub-step 6 is a *separate* decision where items can still be dropped. Pre-announcing one outcome hides the drop option.
- Equivalent plain-text reply is also acceptable per the existing `suggested / all / none / comma-list` semantics below.
- Item labels in the rendered list and in the `AskUserQuestion` option labels MUST use the same identifiers. Use Arabic numerals only (`1`, `2`, `3`, …) — never letters, never roman numerals, never any other scheme. An option labeled "Items 5, 6" must refer to items literally labeled `5.` and `6.` in the rendered list directly above.

**4. Offer in-session fixes.** Ask **only about the fix-now decision** — do not preview, hint at, or pre-allocate the filing decision from sub-step 6.

> Which of these would you like to fix now? Reply with comma-separated numbers (e.g., `1, 3`), `suggested` to accept the fix-now group, `all`, or `none`.

Reply semantics:

- `suggested` → select exactly the items in the "Suggested fix now" group. If that group is empty, treat as `none` and skip to sub-step 6.
- `all` → select every item in the consolidated list (both groups).
- `none` → skip in-session fixes; proceed to sub-step 6 with all items unfixed.
- Numeric list → select the listed numbers verbatim.

**5. Fix selected items.** If the user picked any:

- Delegate to `developer` with the chosen findings (parallel agents if findings are in independent files, same pattern as Step 5).
- Re-run `pnpm check`. If it fails after a single corrective `developer` delegation, surface the failure via the Error Handling path and stop — do not loop indefinitely.
- Spawn a single `quality-reviewer` re-review scoped to **only** the files touched by the deferred fixes:

  ```md
  Task for quality-reviewer: Adversarial re-review of deferred-item fixes for <ISSUE-ID>
  Context: Previously deferred Nice-to-Have items were just fixed. Verify correctness; try to break them.
  Changed files: [list]
  Previous deferred findings addressed: [list]
  Acceptance: Confirm fixes are correct. Flag any new findings (any severity) with concrete scenarios.
  ```

- If the re-review surfaces new **Nice-to-Have** findings, append them to the remaining unfixed list for sub-step 6.
- If the re-review surfaces new **Critical/High/Medium** findings (regressions caused by the deferred-item fixes), make exactly **one** corrective pass: delegate to `developer` to fix the regressions, then re-run `pnpm check`. Do **not** spawn another `quality-reviewer` cycle and do **not** re-enter the Step 5 loop. If `pnpm check` still fails or any of those findings remain unaddressed in the diff, terminate Step 6 immediately. On termination, populate the verdict block as follows:
  - **Verdict:** `terminated-with-open-items` (overriding the Step 4 verdict).
  - **Deferred fixed in-session:** deferred items whose fixes are not implicated in the regression. If causation cannot be cleanly attributed (the developer landed multiple fixes in one delegation and the re-review surfaced regressions from "this delta"), list **none** of them as fixed and route every chosen item to `Open items` — readers should not see "fixed" labels on changes that broke the application.
  - **Open items:** the surviving Critical/High/Medium regressions, **plus** the implicated deferred-item fixes per the rule above, **plus** any not-yet-offered unfixed Nice-to-Have items (the user never reached sub-step 6, so those items are not "dropped" — they are surfaced for manual follow-up).
  - **Deferred dropped:** `none` (this field is reserved for items the user explicitly declined to fix and declined to file in sub-step 6).
  - Skip sub-step 6.

**6. Offer Linear issues for unfixed items.** Render the remaining unfixed items using the template below, then ask the question that follows. The render is REQUIRED regardless of prompt mechanism (markdown body, AskUserQuestion description, etc.) — do not collapse to a single sentence; assume the user is context-switching across parallel sessions and cannot scroll back to sub-step 3. Preserve original sub-step 3 numbering (items already fixed in sub-step 5 become gaps, e.g., 1, 3, 4 if item 2 was fixed). Omit a sub-group header entirely if empty; do not print "(none)".

```text
Quality review verdict: <passed-clean | passed-after-fixes>  (cycles: N)
Deferred items still unfixed after sub-step 5:

Fixed in-session (for context, not actionable here):
  2. [Finding] — [file:line] — [tag]

Suggested defer as issue (recommended to file):
  3. [Finding] — [file:line] — [tag] — [rationale]

Suggested fix now but skipped (filing as issue is unusual but allowed):
  1. [Finding] — [file:line] — [tag] — [rationale]

New Nice-to-Have findings from sub-step 5 re-review (appended, no group label):
  5. [Finding] — [file:line] — [tag] — [rationale]
```

Every actionable item MUST include: finding text (verbatim from reviewer, not paraphrased), file:line, tag, and rationale. If the reviewer emitted no file:line, render `file:line: unknown` rather than omitting the field. Then ask:

> For which of the unfixed items should I create Linear issues? Reply with comma-separated numbers (e.g., `1, 2`), `suggested` to file the defer-as-issue group, `all`, or `none`. Items declined here become `Deferred dropped` in the verdict block — they are not silently re-added to any other category.

Reply semantics:

- `suggested` → file every item still in the "Suggested defer as issue" group at this point (items already fixed in sub-step 5 are excluded automatically). If the remaining group is empty, treat as `none`.
- `all` → file every remaining unfixed item.
- `none` → file nothing; remaining items become `Deferred dropped` in the verdict block.
- Numeric list → file the listed numbers verbatim.

For each chosen item, create the issue with the parent link set atomically. Use `linear-stdin.sh` to safely pass the description (which contains backticks, colons, and other shell-significant characters from file:line refs and rationale). Use `mktemp` for the body file so concurrent `/quality-review` runs in different sessions or worktrees do not race on a shared path. **macOS BSD `mktemp` does not replace `XXXXXX` if a suffix follows it**, so omit the extension on the template; Linear accepts the body without one. Ensure `tmp/` exists first:

```bash
mkdir -p tmp
# 1. Write description to a unique tmp file. Body shape:
#    "<finding>\n\nLocation: <file:line>\n\nRationale: <rationale>"
body_file=$(mktemp tmp/deferred-XXXXXX)
# ...write body to "$body_file" via the Write tool...

# 2. Create the issue with --parent set at create time so the sub-issue link is
#    atomic. A separate `linear i update --parent` follow-up is fragile — it can
#    be skipped, silently fail, or have its <ISSUE-ID> placeholder mis-substituted,
#    leaving the new issue orphaned (no "Sub-issues" entry under the parent).
#    See standards/linear-workflow.md "Spawned Issues Must Link to Their Parent".
#    --state Planned: deferred items have a known design intent and a documented
#    location/rationale (sub-step 1's consolidated list). They should not need
#    triage — they're triaged the moment we file them. Filing them into Triage
#    instead would queue them for re-evaluation that's already been done.
#    If no issue was resolved in Step 1, omit the `--parent` line entirely
#    (do not invent a parent).
new_id=$(~/.claude/scripts/linear-stdin.sh "$body_file" i create "<short title>" --team <team> --state Planned --parent <ISSUE-ID> -d - | grep -oE '[A-Z]+-[0-9]+' | head -1)
```

If `--state Planned` is rejected (the team uses different state names), fall back to the team's equivalent "ready-to-work, not-yet-prioritized" state — verify with `linear teams states <TEAM>`. Do NOT silently fall through to the default (most teams default to Triage, which defeats the purpose).

After creation, verify the parent link took (`linear i view "$new_id"` should show the parent). If it did not, surface the failure rather than proceeding — an orphaned deferred issue defeats the purpose of filing it.

Items the user explicitly declined to file in this prompt go to `Deferred dropped` — record them as a list for the verdict block. (Items that never reached this prompt because Step 6 terminated early in sub-step 5 are routed to `Open items` instead — see sub-step 5.)

## Output

When the skill returns to its caller (or to the user, when standalone), present a structured verdict block:

```text
Verdict: passed-clean | passed-after-fixes | terminated-with-open-items
Cycles: N (initial + N-1 re-reviews)
Findings resolved: [list, or "none" if passed-clean]
Deferred fixed in-session: [list, or "none"]
Deferred filed as issues: [PL-XX, PL-YY (sub-issues of <PARENT>), or "none"]
Deferred dropped: [list, or "none"]
Open items: [list, or "none" — populated only on terminated-with-open-items; includes any deferred items not handled above]
```

The `(sub-issues of <PARENT>)` suffix is required when issues are filed and a parent issue was resolved in Step 1 — it gives the user a one-glance audit that the parent link from sub-step 6 was set. Omit the suffix only when no parent issue was resolved (in which case the newly-filed issues are intentionally not sub-issues).

When delegated from `/start`, this block becomes the "Adversarial review" section of the completion summary verbatim.

## Error Handling

- **`pnpm check` repeatedly fails** after multiple `developer` delegations (Step 2 gate): surface to the user with the failing output. Do not proceed to review.
- **Sub-step 5 corrective pass leaves `pnpm check` failing or regressions unaddressed**: the deferred-item fixes broke the application and the single corrective `developer` pass did not restore it. Set the run verdict to `terminated-with-open-items`, route per sub-step 5's verdict-population rules, and surface the failing output to the user along with the `Open items` list. Do not loop further or roll back automatically — let the user decide whether to revert, re-run `/quality-review`, or escalate to architect.
- **No changed files detected**: warn the user and exit. Nothing to review.
- **Issue ID provided but `linear` CLI not authenticated**: prompt `linear auth login`, then continue without issue context if the user skips.
- **`quality-reviewer` agent unavailable or returns malformed findings**: surface the raw output to the user; do not silently proceed.
