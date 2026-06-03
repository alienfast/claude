# Bug Fix PR Template

Use this template when fixing bugs or resolving issues.

> **Verify the baseline first.** The **Root Cause**, the **Before** snippet, and
> **Affected Users** are all claims about what the base branch shipped — ground them
> in §4's baseline check (`git show "origin/$BASE":path`, or its local fallback when
> the base isn't on origin), not an intermediate branch state (see SKILL.md §4,
> "Verify the baseline before describing what changed"). If `origin/$BASE` already behaves
> correctly, the bug was introduced and fixed within this branch and never reached
> production — this is **not** a production bug fix. Drop the bug-fix framing and use
> the feature/refactor template instead.

```markdown
## Executive Summary

[2–4 plain sentences for a business audience: what was going wrong for users or the
business, and what is now resolved. No file paths, no code, minimal jargon. Only claim
production impact if the broken behavior is confirmed in the base branch's shipped
state (§4 baseline check).]

[Optional one-liners — include only those that apply, omit the rest:]
- **For users:** [what they experienced before vs. now]
- **Business impact:** [risk, cost, or reliability effect of the fix]
- **Security & quality:** [regression tests added, hardening]

🔗 **Pull request:** [#<number> — <title>](<pr-url>)

## Summary

[1-2 sentence overview: What bug was fixed and what the impact was]

## Problem Description

### Symptoms

- [Observable behavior that was wrong]
- [Error messages or unexpected outputs]
- [User impact]

### Root Cause

[Detailed explanation of what was causing the bug]

**Affected Code**:

- [link to problematic file](path/to/file.ts#L42-L51)

**Why it happened**:

- [Technical explanation]
- [Any conditions that triggered it]

## Solution

### What Changed

- [Specific change made to fix the issue]
- [Any related changes for robustness]

**Fixed Code**:

- [link to fixed file](path/to/file.ts#L42-L51)

### Code Comparison

**Before**:

```typescript
// Problematic code
function buggyFunction() {
  // Missing error handling
  return data.value;
}
```

**After**:

```typescript
// Fixed code
function fixedFunction() {
  if (!data || data.value === undefined) {
    throw new Error('Invalid data');
  }
  return data.value;
}
```

## Impact Analysis

### Affected Users

- [Who was experiencing this issue]
- [How many users/how often]
- [Severity of impact]

### Affected Features

- [List of features that were broken]
- [List of features now working correctly]

## Testing

**Regression Tests**:

- ✅ Added test for original bug scenario
- ✅ Added test for edge cases that could cause similar issues
- ✅ Verified fix doesn't break existing functionality

**Test Cases**:

```typescript
describe('buggyFunction', () => {
  it('handles missing data gracefully', () => {
    expect(() => fixedFunction(null)).toThrow('Invalid data');
  });

  it('returns value when data is valid', () => {
    expect(fixedFunction({ value: 42 })).toBe(42);
  });
});
```

**Manual Verification**:

- ✅ Reproduced original bug
- ✅ Verified fix resolves the issue
- ✅ Tested related scenarios
- ✅ Checked error logs cleared up

## Related Issues

- Fixes #123 - [Issue title]
- Related to #456 - [How it relates]

## Side Effects

[If none, write "None"]

- [Any unintended consequences of the fix]
- [Any performance implications]
- [Any behavioral changes users might notice]

## Dependencies

- Updated `package-name` to x.y.z - [If bug was in dependency]
- [Any other dependency changes]

## Monitoring

**Metrics to watch**:

- [Error rate for this function/endpoint]
- [Performance metrics]
- [User feedback]

**Alerts**:

- [Any new alerts added]
- [Modified alert thresholds]

## Rollback Plan

If this fix causes issues:

1. [Immediate rollback steps]
2. [How to revert safely]
3. [What to monitor]

## Documentation

- [Updated error handling docs](docs/errors.md)
- [Updated troubleshooting guide](docs/troubleshooting.md)
- [Added to known issues (if partial fix)](docs/known-issues.md)

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>

```
