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
- Fix aligns with existing patterns and conventions

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

### A verification you never watched fail is not a verification

A sweep, checker, or audit whose passing result gates a decision — ship it, mark it fixed, declare convergence — must prove it can still fail before its verdict is worth anything:

- **Negative control.** Include a case that MUST be reported: a deliberately-broken fixture, a reverted fix, a relaxed clause. A run that flags nothing means something only if you have watched that same run flag something.
- **Zero discovery is an error, never a pass.** Zero files scanned, zero items parsed, zero matches — fail loudly. Report the counts (files scanned, items checked) next to the verdict so an empty run is visible rather than clean-looking.

A harness that silently matches nothing — a wrong glob, an ignore rule that excludes the fixtures, a parser regex that no longer matches the tool's output format — returns exactly the same "no problems found" as a genuinely clean run. That is the answer everyone wants, which makes it the one nobody questions.

### Complexity Response Pattern

When two or more attempts have failed, stop and hand the decision over with everything needed to make
it: what you tried and how each attempt failed, the specific ambiguity or decision point that remains,
the proper fix scoped concretely (which files, roughly how much work), the workaround alternative and
what it costs, and your recommendation — which is the non-workaround option unless there is a stated
reason otherwise. Then ask.

The failure mode this replaces is proposing the workaround alone ("let's downgrade to v1.2 to avoid
this"), which asks the user to approve a decision they cannot see the alternatives to.
