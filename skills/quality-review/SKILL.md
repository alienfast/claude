---
name: quality-review
description: Adversarial implementation review with triage and fix loop. Hard-gates on `pnpm check`, delegates to the quality-reviewer agent for categorized findings (Critical/High/Medium/Nice-to-Have/Approved), then triages and fixes findings via the developer agent. Loops until a re-review surfaces no new Critical/High/Medium findings (convergence), with a soft ceiling of 5 cycles before asking the user how to proceed; option 3 of that prompt terminates with verdict `escalated-to-architect`. Use when the user says 'review my work', 'check this implementation', 'adversarial review', 'quality review', or invokes /quality-review.
---

# Quality Review

Run an adversarial review of the current implementation, then triage and fix findings until the implementation passes cleanly. Designed for use mid-development (before `/finish`) — either standalone, or delegated from `/start` Step 9.

## Arguments

- Issue identifier (e.g., `PL-13`) — optional. Auto-detected from branch/commit when omitted; if no issue can be resolved, the skill runs without requirements-conformance context.
- Positional file paths — optional override of the auto-detected scope.

Examples: `/quality-review`, `/quality-review PL-13`, `/quality-review src/foo.ts src/bar.ts`, `/quality-review PL-13 packages/api/`

Reject any bare argument that is neither an issue-ID (`[A-Z]+-[0-9]+`) nor a path that exists on disk. In particular, the tokens `merge`, `pr`, `no push`, `don't push`, `skip push` are `/finish` arguments — if seen here, error with: `Argument 'X' is a /finish argument, not a /quality-review argument` rather than silently treating it as a file path that doesn't exist (which would just produce an empty scope and warn about nothing to review).

## Invariant

**Working Application Contract.** This skill assumes the application was working before the changes under review. `pnpm check` is the gate that proves it still is. A check failure after our changes is never "pre-existing", never "out of scope" — it is our breakage and must be fixed before review proceeds. Turborepo caching makes repeated runs cheap.

## Workflow

### Preflight: Exit Plan Mode If Active

If the session is in plan mode when `/quality-review` is invoked standalone, call `ExitPlanMode` **before any other step**. Step 1 onward needs Bash (`detect-issue-id.sh`, `git diff`, `pnpm check`, etc.), Agent (for the `quality-reviewer`/`developer` delegations), and Write (verdict persistence) — all blocked in plan mode.

**Detection.** Use the harness's plan-mode indicator visible at skill entry (the same signal that was gating tool calls just before this skill loaded). If that indicator is ambiguous or unavailable, attempt Step 1; if `detect-issue-id.sh` fails with a plan-mode block, return here, call `ExitPlanMode`, then retry Step 1. Do NOT speculatively call `ExitPlanMode` when plan mode is not active — it raises a spurious approval prompt the user must dismiss.

**Plan body.** Pass a one-line plan summarizing what `/quality-review` is about to do. There is nothing to design — `/quality-review` is a fixed mechanical workflow — but `ExitPlanMode` is the only way to leave plan mode and it requires a plan body. For the `<ISSUE-ID>` substitution: only inline a user-supplied token if it matches `^[A-Z]+-[0-9]+$` (case-insensitive, uppercase it before substituting); otherwise use `the current change set`.

- Approved by the user: proceed to Step 1.
- Rejected by the user: stop with `/quality-review aborted at preflight: user rejected plan-mode exit. No review ran; no verdict persisted.` Do NOT emit a lifecycle tag — `/quality-review` does not normally emit one, and no skill-stage code ran. The absence of a persisted verdict file is the signal a later `/finish` will see (`VERDICT=none-found`).
- Tool-error / harness failure (not a user rejection — the tool itself returns an error, or the harness reports `ExitPlanMode` failed for a non-user-cancel reason): surface the error verbatim and stop with `/quality-review aborted at preflight: ExitPlanMode failed (<first line of error>). No review ran; no verdict persisted.` Do NOT continue to Step 1; plan mode is still active.

**Delegated invocation note.** When `/quality-review` is invoked by `/start` Step 9, the parent session has already exited plan mode at `/start` Step 6, so this preflight is a no-op in that path. The hazard only applies to ad-hoc standalone invocations of `/quality-review`.

**Skip this preflight only when plan mode is NOT active** (the common case).

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
linear-cli issues get PL-13
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
Acceptance: Produce a categorized findings report following the Required findings format below — markdown sections with `## Review Findings` heading and the five `### <severity>` subheadings, in that order. Do NOT emit JSON arrays of findings, tables, "Verification summary" sections, "Categorization" tallies, or any alternative structure. The format is parsed by sub-step 1 below; deviations break the consolidation step and surface raw output to the user.
```

For large changes spanning multiple domains, **always** spawn parallel reviewers scoped by domain in a single message (e.g., one for backend, one for frontend). The same parallelism principle applies here — reviews are independent and must run simultaneously. Consolidate findings before proceeding.

**Required findings format** (this is the parsed contract — the `quality-reviewer` agent's system prompt also specifies it; both must agree):

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

If the user picks option 1, resume the loop with the new ceiling raised by N. If `2`, terminate with `terminated-with-open-items`. If `3`, terminate with verdict `escalated-to-architect`: populate `Open items` with the surviving findings as of cycle N, skip Step 6 entirely, and surface the situation to the architect agent — its recommendation supersedes anything downstream consumers (`/start` Step 10, `/finish` Step 8) would otherwise do with the verdict block.

### Step 6: Deferred Items Triage

Runs once, only after the fix loop terminates with `passed-clean` or `passed-after-fixes`. On `terminated-with-open-items` this step is skipped, but the consolidated list from sub-step 1 is still appended to the verdict block under `Open items` so deferred findings are not silently lost.

**Substitution token.** `<ISSUE-ID>` in the templates below means the issue ID resolved in Step 1. If no issue was resolved, replace `for <ISSUE-ID>` with `for the current change set` and skip the dependency-link command in sub-step 6.

**Malformed user replies.** Sub-step 6 is the only prompt in this step. If the user replies to it with input you cannot parse (e.g., `1-3`, `the first three`, `sure`), re-prompt once with the exact accepted syntax — including the `suggested` shortcut — and a literal example. After a second malformed reply, fall back to the *safe default* `all` (filing extra Linear issues is recoverable, silently dropping findings is not). Note: `suggested` is an accepted input, never a fallback. On re-prompt, re-render the full template; do not abbreviate on retry.

**Verdict downgrade.** Step 6 can transition the run state from `passed-after-fixes` back to `terminated-with-open-items` (see sub-step 5 regression-cap path). When that happens, the new verdict overrides the verdict assigned at Step 4.

**1. Consolidate.** Collect every Nice-to-Have / Out-of-Scope finding reported across all review cycles. Deduplicate by `file:line + finding text`; if a finding was emitted without a file:line (a malformed-but-recoverable reviewer output, see Error Handling), fall back to deduplicating by finding text alone (trim, casefold, and collapse internal whitespace before comparison to absorb cosmetic differences). If the consolidated list is empty, skip the rest of this step.

**2. Classify.** Label each item `fix-now` or `defer-as-issue` using the criteria below. `fix-now` items are **applied automatically in-session with no approval prompt** (sub-steps 4–5) — they are gated to obviously-correct, localized, no-API-change changes, so the user has opted into fixing them without per-item review. Only `defer-as-issue` items reach a user prompt (sub-step 6, the filing decision), where the user can still choose to file or drop each one.

**Fix now** — *all* of the following hold:

- One obviously-correct change (no decision between valid alternatives)
- Localized (single file or small contiguous region)
- No change to public APIs, schemas, exported types, or contracts
- Small (~<30 lines diff, no new abstractions)
- Attach a one-word kind tag: `[mechanical]`, `[naming-only]`, `[missing-guard]`, `[typo]`, `[dead-code]`, `[comment-fix]`, etc.

**Defer as issue** — *any* of the following hold:

- Requires a design choice between valid alternatives
- Cross-cutting / touches multiple modules
- Changes public APIs, schemas, or external contracts
- Needs broader test, perf, or security strategy
- Significant scope (refactor, new abstraction)
- Attach a one-word kind tag: `[design TBD]`, `[cross-cutting]`, `[api-change]`, `[needs-perf-data]`, `[scope: multi-module]`, `[refactor]`, etc.

If an item triggers criteria from both sides (e.g., mechanical but touches a public type), the **defer-as-issue** side wins — design implications dominate size (except comment-only fixes — see the override below).

**Comment-only fixes are always `fix-now` — never `defer-as-issue` and never fileable.** When a finding's correct fix edits *only* comment or doc-string text (the comment is stale, incorrect, or misleading and the code it describes is already correct), it touches no behavior, API, schema, or contract — so it is trivially safe to apply in-session, and filing a Linear issue to correct a comment is pure overhead. This **overrides** the defer-as-issue criteria, the tiebreaker above, and any "out of scope" reasoning — even when the comment lives in a file you would otherwise leave untouched (e.g. an already-run migration: correcting its comment changes no checksum and no behavior, even under a rule that migrations are immutable history). It applies **wherever** a comment-only finding surfaces, including ones first raised by the sub-step 5 re-review. **Two exclusions:** a fix that edits *both* code and a comment is not comment-only — apply the standard criteria; and a comment that is wrong *because the code is wrong* is a code defect — fix the code at its real severity, never paper over it by rewording the comment.

**3. Present grouped lists.** Render the classification as two labeled sub-groups with continuous numbering across both. Omit a group header entirely if its group is empty (do not print "(none)").

```text
Deferred items surfaced during review:

Auto-fixing now (no approval needed):
  1. [Finding] — [file:line] — [tag] — [rationale]
  2. [Finding] — [file:line] — [tag] — [rationale]

Suggested defer as issue (needs research/planning):
  3. [Finding] — [file:line] — [tag] — [rationale]
  4. [Finding] — [file:line] — [tag] — [rationale]
```

**Prompt mechanism (applies to sub-step 6).** Sub-step 6 is the only prompt in Step 6 — it asks about exactly one action verb ("file as issue"). `fix-now` items are auto-applied in sub-steps 4–5 with no prompt, so there is no second prompt to disambiguate against. Specifically:

- Render the unfixed-items list from sub-step 6 as **plain text above the question**. Do not rewrite an item's label to encode the action verb — the [tag] communicates the recommendation; the label is the finding.
- The question itself MAY be an `AskUserQuestion` multiSelect, but if so:
  - Every option label must read as "file [finding]".
  - Pre-check (`[✔]`) the items the classification suggests (the `defer-as-issue` group) so the user can accept the suggestion with one click.
  - Do **not** add an "Other" / "type something" / "I have a different choice" option to the options array. The `AskUserQuestion` tool surfaces an "Other" capability automatically (per its tool description: "Users will always be able to select 'Other' to provide custom text input"; "There should be no 'Other' option, that will be provided automatically"). The chat is always available for the user to interject a different reply (e.g., `none`, a comma-list, or free-text). An explicit "type something" option is redundant clutter — the multiSelect must contain exactly the N finding options and nothing else.
- Equivalent plain-text reply is also acceptable per the existing `suggested / all / none / comma-list` semantics below.
- Item labels in the rendered list and in the `AskUserQuestion` option labels MUST use the same identifiers. Use Arabic numerals only (`1`, `2`, `3`, …) — never letters, never roman numerals, never any other scheme. An option labeled "Items 5, 6" must refer to items literally labeled `5.` and `6.` in the rendered list directly above.

**4. Select fix-now items for auto-apply.** No prompt — every item in the `fix-now` group is applied in-session automatically. These are gated to obviously-correct, localized, no-API-change changes, and the user has opted into fixing them without per-item approval. The set to fix = every `fix-now` item from sub-step 2.

**Entry gate — skip sub-steps 4–5 entirely if the `fix-now` group is empty.** With nothing to apply, proceed directly to sub-step 6.

Before delegating, emit a one-line chat note listing the items being auto-applied so the user has visibility (e.g., `Auto-fixing 3 deferred items in-session: #1, #2, #4`). Then proceed to sub-step 5.

**5. Fix the fix-now items.** If the `fix-now` group is non-empty:

- Delegate to `developer` with all `fix-now` findings (parallel agents if findings are in independent files, same pattern as Step 5).
- Re-run `pnpm check`. If it fails after a single corrective `developer` delegation, surface the failure via the Error Handling path and stop — do not loop indefinitely.
- Spawn a single `quality-reviewer` re-review scoped to **only** the files touched by the deferred fixes:

  ```md
  Task for quality-reviewer: Adversarial re-review of deferred-item fixes for <ISSUE-ID>
  Context: Previously deferred Nice-to-Have items were just fixed. Verify correctness; try to break them.
  Changed files: [list]
  Previous deferred findings addressed: [list]
  Acceptance: Confirm fixes are correct. Flag any new findings (any severity) with concrete scenarios.
  ```

- If the re-review surfaces new **Nice-to-Have** findings:
  - **Comment-only findings** (sub-step 2's comment-only rule) are never fileable. Fix each in its **own** `developer` delegation scoped to the comment text, then re-run `pnpm check` (cheap and turbo-cached — it catches a delegation that strayed beyond comment text). **On a clean check**, record them under `Deferred fixed in-session`; a clean-check comment-only edit touches only comment text, so it cannot be implicated in any Critical/High/Medium regression and stays listed as fixed regardless of how the next bullet resolves. **If the check fails**, the delegation strayed beyond comment text and is no longer comment-only — treat that breakage as a regression and handle it through the Critical/High/Medium bullet below, whose single corrective pass and verdict population then apply unchanged (the strayed change is routed to `Open items` if unrecovered, with no "fixed" label on a broken build). No further re-review cycle of its own is needed.
  - All **other** new Nice-to-Have findings are appended to the remaining unfixed list for sub-step 6.
- If the re-review surfaces new **Critical/High/Medium** findings (regressions caused by the deferred-item fixes), make exactly **one** corrective pass: delegate to `developer` to fix the regressions, then re-run `pnpm check`. Do **not** re-enter the Step 5 loop.
  - **Upgrade-on-success exception.** If the corrective pass produces a clean `pnpm check` AND the diff stays scoped to the regression area, an OPTIONAL single confirmatory `quality-reviewer` re-review MAY be spawned (scoped to just the corrective-pass files). If that re-review returns no new Critical/High/Medium findings, **restore the verdict to `passed-after-fixes`** rather than terminating with open items, and continue to sub-step 6. This prevents the regression-cap path from forcing a downgrade on a genuinely successful recovery.
  - If the confirmatory re-review is skipped, or surfaces new findings, or the corrective `pnpm check` still fails, or any of the original regressions remain unaddressed in the diff, terminate Step 6 immediately. On termination, populate the verdict block as follows:
  - **Verdict:** `terminated-with-open-items` (overriding the Step 4 verdict).
  - **Deferred fixed in-session:** deferred items whose fixes are not implicated in the regression. If causation cannot be cleanly attributed (the developer landed multiple fixes in one delegation and the re-review surfaced regressions from "this delta"), list **none** of them as fixed and route every auto-applied item to `Open items` — readers should not see "fixed" labels on changes that broke the application. This carve-out does **not** sweep in *clean-check* comment-only fixes from the independent delegation above: having passed their `pnpm check`, they touch no code in the implicated delta, so they remain listed under `Deferred fixed in-session`. (A comment-only delegation whose check *failed* is not one of these — per the Nice-to-Have bullet above it is itself treated as a regression and routed to `Open items`.)
  - **Open items:** the surviving Critical/High/Medium regressions, **plus** the implicated deferred-item fixes per the rule above, **plus** any not-yet-offered unfixed Nice-to-Have items (the user never reached sub-step 6, so those items are not "dropped" — they are surfaced for manual follow-up).
  - **Deferred dropped:** `none` (this field is reserved for items the user explicitly declined to file in sub-step 6).
  - Skip sub-step 6.

**6. Offer Linear issues for unfixed items.**

**Entry gate — skip sub-step 6 entirely if no *fileable* items remain.** Fileable items are the `defer-as-issue` items plus any new Nice-to-Have findings appended by sub-step 5's re-review (comment-only findings are never appended and never fileable — see sub-step 2 and sub-step 5). Auto-applied `fix-now` items are already fixed and are not fileable. If both are empty there is nothing to file — skip the prompt and emit the Output-section verdict block (the schema under `## Output`, not the sub-step 6 template below). Skipping sub-step 6 does **not** exempt the auto-applied items from the verdict: they MUST still be listed in that block's `Deferred fixed in-session:` field. (This is the common case when every deferred item was `fix-now`: they all auto-apply and the run reaches Output with no prompt at all.)

Render the remaining unfixed items using the template below, then ask the question that follows. The render is REQUIRED regardless of prompt mechanism (markdown body, AskUserQuestion description, etc.) — do not collapse to a single sentence; assume the user is context-switching across parallel sessions and cannot scroll back to sub-step 3. Preserve original sub-step 3 numbering: auto-applied `fix-now` items are shown under "Auto-fixed in-session (for context)" with their original numbers (e.g., 1, 2), and the fileable `defer-as-issue` items keep theirs (e.g., 3, 4), with any new sub-step 5 re-review findings appended after. Omit a sub-group header entirely if empty; do not print "(none)".

**Every `<...>` token below is a substitution site** — replace each with the resolved value before emitting; never emit the literal pipe-separated schema (`<passed-clean | passed-after-fixes>`) to the user. The verdict header line should read e.g. `Quality review verdict: passed-after-fixes (cycles: 3)`. The Step 4-class substitution rule applies here too.

```text
Quality review verdict: <one of: passed-clean | passed-after-fixes>  (cycles: N)
Deferred items still unfixed after sub-step 5:

Auto-fixed in-session (for context, not actionable here):
  1. [Finding] — [file:line] — [tag]
  2. [Finding] — [file:line] — [tag]

Suggested defer as issue (recommended to file):
  3. [Finding] — [file:line] — [tag] — [rationale]
  4. [Finding] — [file:line] — [tag] — [rationale]

New Nice-to-Have findings from sub-step 5 re-review (appended, no group label):
  5. [Finding] — [file:line] — [tag] — [rationale]
```

Every actionable item MUST include: finding text (verbatim from reviewer, not paraphrased), file:line, tag, and rationale. If the reviewer emitted no file:line, render `file:line: unknown` rather than omitting the field. Then ask:

> For which of the unfixed items should I create Linear issues? Reply with comma-separated numbers (e.g., `3, 4`), `suggested` to file the defer-as-issue group, `all`, or `none`. Items declined here become `Deferred dropped` in the verdict block — they are not silently re-added to any other category.

Reply semantics:

- `suggested` → file every item still in the "Suggested defer as issue" group at this point (items already fixed in sub-step 5 are excluded automatically). If the remaining group is empty, treat as `none`.
- `all` → file every remaining unfixed item.
- `none` → file nothing; remaining items become `Deferred dropped` in the verdict block.
- Numeric list → file the listed numbers verbatim, **excluding any that reference the "Auto-fixed in-session" context group** — those items are already fixed and not fileable (the same exclusion `suggested` applies); silently skip such numbers rather than filing a redundant issue.

For each chosen item, create the issue and link its parent via `linear-create-child.sh` (it creates the issue, links the parent with `relations parent`, and **verifies the link** — `linear-cli issues create` has no `--parent` flag and its `--data` silently drops `parentId`, and a hand-rolled after-the-fact `issues update` is fragile: it can be skipped, silently fail, or orphan the new issue with no "Sub-issues" entry under the parent — see standards/linear-workflow.md "Spawned Issues Must Link to Their Parent"). Use `mktemp` for the body file so concurrent `/quality-review` runs in different sessions or worktrees do not race on a shared path. **macOS BSD `mktemp` does not replace `XXXXXX` if a suffix follows it**, so omit the extension on the template. Ensure `tmp/` exists first:

```bash
mkdir -p tmp
# 1. Write description to a unique tmp file. Body shape:
#    "<finding>\n\nLocation: <file:line>\n\nRationale: <rationale>"
body_file=$(mktemp tmp/deferred-XXXXXX)
# ...write body to "$body_file" via the Write tool...

# 2. Create the issue under the resolved parent (the helper links it + verifies).
#    --state Planned: deferred items have a known design intent and a documented
#    location/rationale (sub-step 1's consolidated list). They should not need
#    triage — they're triaged the moment we file them. Filing them into Triage
#    instead would queue them for re-evaluation that's already been done.
#    If no issue was resolved in Step 1, pass "-" as the parent (a top-level issue) —
#    do not invent a parent.
new_id=$(~/.claude/scripts/linear-create-child.sh <ISSUE-ID> <team> Planned "<short title>" "$body_file")
```

If `--state Planned` is rejected (the team uses different state names), follow this explicit fallback algorithm:

1. Derive the team key from the issue ID prefix (e.g., `PL-13` → team `PL`). Then probe: `linear-cli statuses list -t PL`.
2. Pick the first state whose name matches `/^(planned|backlog|to.?do)$/i` (case-insensitive, exact match — NOT a prefix match). **Deliberately exclude `ready` from this regex**: a prefix match on `ready` would latch onto `Ready For Release` or `Ready For Review` on teams that have those states, silently filing new deferred issues into a release/review state.
3. If none match, surface the available states to the user and ask which to use (`Available: Backlog, In Review, Done … which is the "ready-to-work, not-yet-prioritized" state for this team?`) rather than silently falling through to the team default — most teams default to `Triage`, which defeats the purpose of filing deferred items that are already triaged.

Do NOT silently fall through to the default.

After creation, verify the parent link took (`linear-cli issues get "$new_id" -o json | jq -r '.parent.identifier'` should print the parent's ID). If it did not, surface the failure rather than proceeding — an orphaned deferred issue defeats the purpose of filing it.

Items the user explicitly declined to file in this prompt go to `Deferred dropped` — record them as a list for the verdict block. (Items that never reached this prompt because Step 6 terminated early in sub-step 5 are routed to `Open items` instead — see sub-step 5.)

## Output

When the skill returns to its caller (or to the user, when standalone), present a structured verdict block. The schema is:

```text
Verdict: <one of: passed-clean | passed-after-fixes | terminated-with-open-items | escalated-to-architect>
Cycles: N (initial + N-1 re-reviews)
Findings resolved: [list, or the bare word none if passed-clean]
Deferred fixed in-session: [list of items applied in-session, including auto-applied fix-now items even when sub-step 6 was skipped; or the bare word none]
Deferred filed as issues: [PL-XX, PL-YY (sub-issues of <PARENT>), or the bare word none]
Deferred dropped: [list, or the bare word none]
Open items: [list, or the bare word none — populated only on terminated-with-open-items or escalated-to-architect; includes any deferred items not handled above]
```

**Substitute resolved values before rendering — never emit the schema verbatim.** The `Verdict:` line MUST contain exactly one of the four enum values, with no `|` separators and no remaining angle-bracket placeholders. A concrete passing example:

```text
Verdict: passed-after-fixes
Cycles: 3 (initial + 2 re-reviews)
Findings resolved: 2 (CRIT: null-pointer in handler; HIGH: race in retry loop)
Deferred fixed in-session: 1 (dead-code in spec_helper.rb)
Deferred filed as issues: PL-299, PL-300 (sub-issues of PL-190)
Deferred dropped: none
Open items: none
```

The persisted file (see "Persist the verdict" below) is parsed by `finish-read-verdict.sh`, which extracts the first whitespace-separated token after `Verdict:`. Writing the pipe-separated schema verbatim would silently produce `Verdict=passed-clean` downstream — the most permissive value — and bypass `/finish` Step 8's gate. The file MUST contain resolved values only.

The `(sub-issues of <PARENT>)` suffix is required when issues are filed and a parent issue was resolved in Step 1 — it gives the user a one-glance audit that the parent link from sub-step 6 was set. Omit the suffix only when no parent issue was resolved (in which case the newly-filed issues are intentionally not sub-issues).

When delegated from `/start`, this block becomes the "Adversarial review" section of the completion summary verbatim.

**Persist the verdict for `/finish`.** After the block is composed, also write it to a file so a later `/finish` run (potentially in a different session or a different worktree of the same repo) can find it. Skip this step entirely if no issue ID was resolved in Step 1.

1. Use the `Write` tool to save the resolved verdict block (every placeholder substituted; no `|`-separated schema lines) to `tmp/quality-review-verdict-<issue-id-lowercased>.md`. This is the same filename the persistence script will publish to both `tmp/` locations — staging and final artifact share one name so an LLM debugging the handoff doesn't have to follow a rename.
2. Persist atomically to both the current worktree's `tmp/` AND the main checkout's `tmp/` for cross-worktree handoff (the script reads the staging file and rewrites it in place at both locations):

   ```bash
   ~/.claude/scripts/quality-review-write-verdict.sh <ISSUE-ID> tmp/quality-review-verdict-<issue-id-lowercased>.md
   ```

The persisted file is the canonical `/quality-review` → `/finish` handoff. The contents are the verdict block verbatim — downstream readers (`/finish` Step 1.5) parse the `Verdict:` line and the `Open items:` list.

## Error Handling

- **`pnpm check` repeatedly fails** after multiple `developer` delegations (Step 2 gate): surface to the user with the failing output. Do not proceed to review.
- **Sub-step 5 corrective pass leaves `pnpm check` failing or regressions unaddressed**: the deferred-item fixes broke the application and the single corrective `developer` pass did not restore it. Set the run verdict to `terminated-with-open-items`, route per sub-step 5's verdict-population rules, and surface the failing output to the user along with the `Open items` list. Do not loop further or roll back automatically — let the user decide whether to revert, re-run `/quality-review`, or escalate to architect.
- **No changed files detected**: warn the user and exit. Nothing to review.
- **Issue ID provided but `linear-cli` not authenticated**: prompt `linear-cli auth oauth`, then continue without issue context if the user skips.
- **`quality-reviewer` agent returns malformed findings**: a response is malformed if ANY of the following hold:
  - Missing the `## Review Findings` heading.
  - Missing any of the five required subheadings (in order: `### Critical`, `### High`, `### Medium`, `### Nice-to-Have / Out-of-Scope`, `### Approved`). Match by line-prefix with a narrow tail: the heading word(s) must be followed by either end-of-line OR ` (` (single space + opening paren, for the optional parenthetical like `(must fix before done)`). Examples that match: `### Critical`, `### Critical (must fix before done)`. Examples that do NOT match (treated as malformed under criterion 4 below): `### Critical findings`, `### Critical:`, `### CRITICAL`. Subheadings appearing out of order also count as malformed (downstream consumers scan positionally).
  - Contains a JSON array of findings (`[{...}, {...}]`) in ANY form — including as an appendix alongside the required headings, not only "instead of" them.
  - Uses non-standard headings ("Verification summary", "Categorization", "Final findings", or any other heading not in the Required findings format).
  - Contains free-form prose between or around the required sections (preamble before `## Review Findings`, appendix after `### Approved`, or commentary between subheadings).

  On detection:
  1. Surface the raw agent output to the user (so the work isn't lost).
  2. Re-spawn the agent ONCE with a corrective prompt prepended: `Your previous response did not follow the Required findings format from your system prompt. Your entire response MUST consist of ONLY the Required structure: ## Review Findings heading, then exactly five ### subheadings in the prescribed order (Critical, High, Medium, Nice-to-Have / Out-of-Scope, Approved), each followed by bullet items or the literal "- None". Do NOT emit JSON arrays, JSON objects, or any other non-markdown structure. Do NOT emit tables, alternative section headings, preamble, appendix, or prose between sections — markdown bullets only.`
  3. Route the re-spawn's outcome:
     - **Re-spawn produced a well-formed response** → continue normally with its findings.
     - **Re-spawn still malformed** → terminate `/quality-review` with the verdict body below.
     - **Re-spawn failed to return at all** (subagent crashed, infrastructure error, timeout) → route to the agent-unavailable branch below (use its verdict body).

  **Verdict body for malformed-fallthrough** (write this verbatim to the staging file before calling `quality-review-write-verdict.sh`; all seven Output schema fields populated so `/finish` Step 4 has consistent shape to template):

  ```text
  Verdict: terminated-with-open-items
  Cycles: 1 (initial review malformed; one corrective re-spawn also malformed)
  Findings resolved: none
  Deferred fixed in-session: none
  Deferred filed as issues: none
  Deferred dropped: none
  Open items: agent output malformed across two attempts; manual review required (see chat above for raw outputs)
  ```

- **`quality-reviewer` agent unavailable** (subagent type missing, infrastructure error, or re-spawn from the malformed branch failed to return): surface the failure to the user. Terminate with one of the two verdict bodies below — pick by route, write the chosen body verbatim with no further substitution.

  **Route A — initial spawn returned unavailable** (no cycles ran):

  ```text
  Verdict: terminated-with-open-items
  Cycles: 0
  Findings resolved: none
  Deferred fixed in-session: none
  Deferred filed as issues: none
  Deferred dropped: none
  Open items: review could not run; quality-reviewer agent unavailable on initial spawn (see chat above for failure details)
  ```

  **Route B — re-spawn from the malformed branch returned unavailable** (one malformed cycle ran):

  ```text
  Verdict: terminated-with-open-items
  Cycles: 1
  Findings resolved: none
  Deferred fixed in-session: none
  Deferred filed as issues: none
  Deferred dropped: none
  Open items: review could not run; initial output was malformed and the corrective re-spawn returned unavailable (see chat above for failure details)
  ```

- **`quality-review-write-verdict.sh` itself fails** (disk full, perms, mktemp/mv error, missing `tmp/` parent unreachable): the persistence layer cannot record the verdict, so `/finish` Step 1.5 would see `VERDICT=none-found` and proceed with only a warning — defeating the gate that the fallthrough verdict was meant to establish. On detection (script exit code non-zero):
  1. Surface the script's stderr to the user immediately.
  2. Do NOT silently proceed. Print an explicit warning: `WARNING: /quality-review verdict could not be persisted (see above). /finish for this issue will not be gated by this verdict. Either resolve the persistence failure and re-run /quality-review, or run /finish with explicit awareness that Step 8's gate cannot read the verdict you just produced.`
  3. Continue with the in-memory verdict (still surface the verdict block to the user / caller) so `/start` Step 10 has something to render, but understand that `/finish` cannot enforce it. The user must decide whether to re-run or proceed manually.
