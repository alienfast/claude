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

### Complexity Response Pattern

When encountering complexity after 2+ attempts:

1. **Document what you've tried**: List attempted solutions and why they failed
2. **Explain the uncertainty**: What specific decision point or ambiguity exists?
3. **Present options**: Show the "right way" (proper solution) vs. alternatives with trade-offs
4. **Recommend forward**: Explicitly recommend the non-workaround option
5. **Ask for direction**: "This will take more work to do properly. Should I proceed with the proper solution, or do you have other constraints?"

### Example Response to Complexity

❌ **DON'T**:

"I'm running into issues with the new API version. Let's downgrade to v1.2 to avoid this."

✅ **DO**:

"I've attempted to migrate to the new v2 API twice:

1. First attempt failed because the auth signature changed
2. Second attempt revealed the response format is different

The proper solution requires:

- Updating auth middleware (~2 files)
- Updating response handlers (~4 files)
- Adding tests for new format

Alternative: Downgrade to v1.2 (not recommended - loses new features and security fixes)

**Recommendation**: Proceed with proper v2 migration. This improves security and enables new features.

Should I continue with the full migration?"
