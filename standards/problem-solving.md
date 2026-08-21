# Problem-Solving Standards

## When Encountering Technical Obstacles

### Decision Framework

**STOP and ASK when:**

- Root cause is unclear after thorough investigation
- Multiple valid solutions exist with significant trade-offs
- Solution requires choosing between competing design philosophies
- 2+ attempted solutions have failed
- Each attempt reveals new unexpected complexity
- Problem appears to have deeper architectural issues than initially visible
- Business logic decisions needed (e.g., how to handle edge cases with user impact)
- Performance vs. maintainability trade-offs with no clear winner
- Security vs. usability decisions
- Technical approach would deviate significantly from existing codebase patterns (when unclear if deviation is desired)

**RESEARCH DEEPER when:**

- Error messages are unclear or undocumented
- Technology/API is unfamiliar
- Best practices are not obvious from existing codebase
- Solution pattern doesn't exist in current codebase
- Documentation is sparse or contradictory

**PROCEED DIRECTLY when:**

- Solution is obvious from investigation
- Pattern exists in codebase to follow
- Change improves code quality (better abstractions, removes tech debt)
- Error messages provide clear guidance
- Standards explicitly cover the scenario
- Fix aligns with existing patterns and conventions (for the *shape* — see "A precedent is not a safety argument" below)

### A precedent is not a safety argument

"The sibling does it this way" establishes that a shape is *conventional*. It never establishes that it is *safe here* — it satisfies the PROCEED DIRECTLY bullets
above for the shape, never for the consequences.

Before copying a guard, lock, retry, timeout, cache, or self-healing mechanism from a sibling function, read the **new call site** and write one sentence: what happens
when this mechanism misfires here, and how that differs from when it misfires where you copied it from. Identical code carries different blast radii — a stolen lock
costing a redundant write is not a stolen lock costing an irreversible side effect (a customer email, a payment, a published record). When the consequences differ,
the precedent transfers nothing: the mechanism needs its own justification, or a different mechanism.

The sentence is the point. You cannot write it without leaving the function you are editing, and the invariant that forbids the copy is usually documented at the
caller rather than at the thing being copied. Measured 2026-08-20: a stuck-claim fix added the two sibling functions' `5 * 60 * 1000` staleness OR to a third, and the
justification written into both the code comment and the plan was that it should match the siblings. Adversarial review graded it **Critical** — the permanently-held
claim *was* the anti-double-send guard, said so in a comment one file away at the caller, and a TTL would have re-emailed customers who already had their invoice. The
inquiry never left the file because "match the siblings" had already terminated it.

This is not `/quality-review`'s "following an established codebase pattern is not an open design choice," which governs whether a *fix* needs a design decision before
it can auto-apply. A transplanted mechanism can be localized, small, and contract-free — clearing every one of those gates — and still be wrong at the new site,
which is exactly what makes a copied TTL eligible for a silent `fix-now` auto-apply.

## Anti-Patterns: Technical Workarounds

### ❌ NEVER Suggest These Without Explicit Approval

1. **Dependency Downgrading**: "Let's downgrade package X to avoid this issue"
   - ✅ Instead: Investigate why the new version breaks, fix the root cause
   - Exception: Security issues make newer version unusable (ASK FIRST)

2. **Error Suppression**: "Let's ignore/suppress this error for now"
   - ✅ Instead: Understand and fix the error properly
   - Exception: Known false positive with documented reasoning

3. **Type Casting to Bypass**: "Let's cast to 'any' to get past type errors"
   - ✅ Instead: Fix the type definitions properly
   - Exception: Third-party types are broken (must document and report)

4. **Incomplete Implementation**: "Let's skip tests/validation for now"
   - ✅ Instead: Complete the implementation fully
   - Exception: User explicitly requests incremental delivery

5. **Configuration Hacks**: "Let's disable this linter rule/check"
   - ✅ Instead: Fix the code to satisfy the rule
   - Exception: Rule is genuinely incorrect for this use case (document why)

6. **Partial Migrations**: "Let's migrate just part of the code"
   - ✅ Instead: Complete the migration or use feature flags
   - Exception: Incremental migration is the documented strategy

7. **Silent Defaults for Required Config**: "Let's default to X if the env var isn't set"
   - ✅ Instead: Keep the throw/error. Required means required — silent fallbacks mask misconfiguration.
   - Exception: The value is genuinely optional with a documented default (rare for required-by-name config)

### Asserting a capability does not exist

Never record that a tool, flag, or command is unavailable — and never skip a required step on that basis — without having **run the check**: `--help`, `command -v`,
the tool's own listing, or the documented call itself. A capability claim is a factual claim about this machine, cheap to verify and expensive to get wrong: it
converts a skipped step into a documented impossibility that no reviewer re-examines, and it can send a follow-up issue after tooling that already works. When a call
genuinely fails, record the command and its exact error, never the generalization ("the toolchain cannot do this").

This is worse than ignoring a rule, because the agent concludes compliance is *impossible* and documents the reasoning persuasively enough to pass its own review.
Measured 2026-08-21: a `/quality-review` verdict recorded *"Collision edges: none wired — could not be created with available tooling. linear-cli exposes no relation
subcommand… no script in ~/.claude/scripts/ can create a Linear issue relation"*, skipped a step Step 6 mandates, and recommended a `/reflect` to fix a toolchain gap
that does not exist — `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` is in the linear skill's own command map, and `relations --help` settles it in one call.
A mechanical guard now covers that one choke point (`scripts/quality-review-write-verdict.sh`), but the shape generalizes to any skipped step justified by an unchecked
capability claim.

### A workaround's premise can expire — and the change that expires it owns its removal

Scaffolding built around a missing value, an unavailable dependency, or an unfinished decision usually **states its own precondition** — in a comment, a docblock, or the issue that added it. That sentence is an expiry condition. When your change is what supplies the missing thing, the scaffolding is dead as of your commit, and deleting it is part of the change — not a follow-up, not ops work, not someone else's ticket. This is the recognition step in front of [technical-debt-prevention.md](technical-debt-prevention.md)'s *Delete Aggressively*: the hard part is never the deletion, it is noticing that your own change is what killed it. Distinct from a stale *issue* premise, which someone else's work invalidates and which is answered by descoping, not deleting.

The failure is a mis-framed question. Facing existing scaffolding, "how do I feed this design the new value?" and "does this design still have a reason to exist?" produce completely different work, and only the first one looks like configuration. Ask the second question first, and re-read the scaffolding's own comment before answering it.

Two tells that you asked the wrong one:

- **The remedy turns into infrastructure or process work** — a config key to set, an environment to update, a person to ask — when what you actually obtained was a value with an obvious home in code you already have open.
- **You find yourself hardening the scaffolding** — adding a test, a guard, or a comment to machinery whose premise your change just retired. Effort spent there is spent on code that should be deleted in the same commit.

Removal is inside the change's blast radius, not adjacent work: your commit is what made the code dead, so the issue's scope boundary — written before the premise expired — does not exclude it. Its tests go with it; they only ever pinned the workaround's behavior, and leaving them is what makes the next reader believe it is load-bearing. **Keep any invariant the scaffolding was incidentally enforcing**, in generalized form — a fail-closed guard that happened to live inside it is worth relocating and re-testing, not deleting along with it.

Worked case: an env-sourced template id, a nil-returning reader, a fail-closed operation guard, and Pulumi wiring, all built because the id did not exist yet — the reader's own docblock said as much ("every other send here hardcodes an id that was verified in the console, and there is no id to guess for this one"). The issue whose entire purpose was to obtain that id shipped without deleting any of it: it filed a ticket asking an operator to set the config key, and during review added an assertion to a spec arm titled "enqueues against the configured template" — an arm whose subject was about to be deleted. Unwinding it by hand touched 17 files, and hardcoding the id immediately exposed a collision with a sibling send that the indirection had kept invisible.

### A verification you never watched fail is not a verification

A sweep, checker, or audit whose passing result gates a decision — ship it, mark it fixed, declare convergence — must prove it can still fail before its verdict is worth anything:

- **Negative control.** Include a case that MUST be reported: a deliberately-broken fixture, a reverted fix, a relaxed clause. A run that flags nothing means something only if you have watched that same run flag something.
- **Zero discovery is an error, never a pass.** Zero files scanned, zero items parsed, zero matches — fail loudly. Report the counts (files scanned, items checked) next to the verdict so an empty run is visible rather than clean-looking.

A harness that silently matches nothing — a wrong glob, an ignore rule that excludes the fixtures, a parser regex that no longer matches the tool's output format — returns exactly the same "no problems found" as a genuinely clean run. That is the answer everyone wants, which makes it the one nobody questions.

### Measure the quantity that moves, not the call you are deleting

An invalidation — a cache clear, a memo reset, a connection flush — is cheap *at the call* and expensive *downstream*, in the re-population it forces on everything after it. A stopwatch around the call therefore times bookkeeping, can understate the real cost by orders of magnitude, and reads like evidence. When the change is "stop doing X," measure the whole workload with and without X — back to back on one machine, with X as the only variable. Reach for a stopwatch around X only when nothing downstream re-derives what X discarded.

The A/B also survives being wrong about *why*. Attribution to the single changed variable is what the measurement establishes; the mechanism behind it is a separate claim, and pinning the number does not license asserting the mechanism.

### Two measurements agree only if they measured the same kind of thing

A close numeric agreement between two observations is evidence of nothing until you have established that both are instances of the same *kind* of event. Agreement is seductive in proportion to its tightness: the closer it is, the more it reads as having found the mechanism, and the less likely anyone is to re-check what was actually compared. Internal consistency checks do not catch this — they test the arithmetic, not the identity of the things being compared. So before drawing a conclusion from a match, name what each observation *is*, and confirm the two names are the same. Where the system reports that kind — an error class, a limit name, a status code, a build variant — read it rather than inferring it from the observation's shape.

Worked case: two rate-limit cutoffs whose trailing-5h billable volumes agreed to **0.08%** while diverging 23% on output tokens, which read unmistakably as having identified the quantity the limit meters. The harness messages named two *different* limits — a weekly allowance and a per-session one — so unrelated ceilings had merely coincided. Three consistency checks passed, none of them testing what each event was, and the conclusion reached two shared config files before the premise was checked.

### A guard keyed on someone else's signal inherits their coverage decisions

When a condition your code cares about — "more than one file was dropped on a single-file target", "the request was throttled", "the record was superseded" — is detected by reading a signal a **dependency** emits (an error code, a status enum, a flag) rather than by deriving it from inputs you already hold, the dependency decides which cases raise that signal. Confirming it fires in the obvious case measures nothing about the cases it stays silent in, and a guard that acts only when the signal arrives does nothing in exactly those — failing open, for the common suppress-on-signal shape. The measurement is true and the inference from it is false, so re-reading the measurement never surfaces the error.

Before keying on such a signal, enumerate the ways your condition can hold and check the signal fires for each. Where the condition is derivable from what you already have, derive it — the guard then no longer turns on the dependency's judgement about which cases are worth signalling.

Worked case: `react-dropzone` v20 emits `too-many-files` only when the count of *accepted* files exceeds the limit, and a file already rejected for its type (or its size, or a custom validator) never becomes accepted. A single-file dropzone given one valid file plus one wrong-type file therefore saw no `too-many-files` at all, and a suppression guard keyed on that code uploaded the valid file. The callback already received both arrays; `accepted.length + rejections.length > 1` is the condition, and it rests on no coverage decision of the library's.

### Complexity Response Pattern

When two or more attempts have failed, stop and hand the decision over with everything needed to make
it: what you tried and how each attempt failed, the specific ambiguity or decision point that remains,
the proper fix scoped concretely (which files, roughly how much work), the workaround alternative and
what it costs, and your recommendation — which is the non-workaround option unless there is a stated
reason otherwise. Then ask.

The failure mode this replaces is proposing the workaround alone ("let's downgrade to v1.2 to avoid
this"), which asks the user to approve a decision they cannot see the alternatives to.
