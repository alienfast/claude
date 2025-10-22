# Common Semver Errors and Patterns to Avoid

This document catalogs common semantic versioning mistakes and how to avoid them.

## Classification Errors

### Error 1: Range Notation Confusion

**Symptom**: Classifying based on range notation instead of version numbers

**Examples**:

```text
❌ WRONG: ^7.1.5 → ^7.1.6 = MAJOR (because of the caret symbol)
✅ RIGHT: ^7.1.5 → ^7.1.6 = PATCH (7.1.5 → 7.1.6 patch increment)

❌ WRONG: ~1.2.3 → ~1.3.0 = PATCH (same tilde notation)
✅ RIGHT: ~1.2.3 → ~1.3.0 = MINOR (1.2.3 → 1.3.0 minor increment)

❌ WRONG: >=2.0.0 → >=3.0.0 = MINOR (both use >=)
✅ RIGHT: >=2.0.0 → >=3.0.0 = MAJOR (2.0.0 → 3.0.0 major increment)
```

**Fix**: Always strip range notation before comparing versions. Focus only on X.Y.Z numbers.

**Detection Pattern**:

```text
If classification mentions "caret", "tilde", or range operator → ERROR
Classification should only reference X.Y.Z number changes
```

---

### Error 2: Package Importance Assumption

**Symptom**: Assuming critical packages always have major updates

**Examples**:

```text
❌ WRONG: react 18.2.0 → 18.3.0 = MAJOR (React is critical)
✅ RIGHT: react 18.2.0 → 18.3.0 = MINOR (minor version increment)

❌ WRONG: @types/node 16.0.0 → 16.0.1 = MINOR (types are important)
✅ RIGHT: @types/node 16.0.0 → 16.0.1 = PATCH (patch version increment)
```

**Fix**: Package importance is irrelevant to semver classification. Only version numbers matter.

**Detection Pattern**:

```text
If reasoning includes "critical package", "core dependency" → ERROR
Classification should be version-based only
```

---

### Error 3: Skipped Version Confusion

**Symptom**: Misclassifying when intermediate versions are skipped

**Examples**:

```text
❌ WRONG: 1.2.0 → 1.4.0 = MAJOR (skipped 1.3.0)
✅ RIGHT: 1.2.0 → 1.4.0 = MINOR (minor number changed)

❌ WRONG: 5.0.0 → 7.0.0 = MINOR (only 2 versions up)
✅ RIGHT: 5.0.0 → 7.0.0 = MAJOR (major number changed)
```

**Fix**: Skipping versions doesn't change classification. Compare version segments, not the magnitude of change.

**Detection Pattern**:

```text
If reasoning mentions "skipped version", "jumped versions" → ERROR
Focus on which segment changed, not how much
```

---

### Error 4: Pre-release Version Misclassification

**Symptom**: Treating pre-release changes as semver bumps

**Examples**:

```text
❌ WRONG: 1.0.0-alpha.1 → 1.0.0-beta.1 = MAJOR
✅ RIGHT: 1.0.0-alpha.1 → 1.0.0-beta.1 = Pre-release progression

❌ WRONG: 2.0.0-rc.1 → 2.0.0-rc.2 = PATCH
✅ RIGHT: 2.0.0-rc.1 → 2.0.0-rc.2 = Pre-release iteration

❌ WRONG: 1.0.0-beta.5 → 1.0.0 = MINOR
✅ RIGHT: 1.0.0-beta.5 → 1.0.0 = Release finalization
```

**Fix**: Pre-release to pre-release changes aren't semver bumps. RC to release isn't a bump either.

**Detection Pattern**:

```text
If versions contain -alpha, -beta, -rc → Check for pre-release rules
Pre-release → Pre-release = progression, not semver bump
Pre-release → Release = finalization, classify against previous stable
```

---

### Error 5: 0.x Version Mishandling

**Symptom**: Treating 0.x versions same as 1.x+ versions

**Examples**:

```text
❌ WRONG: 0.5.0 → 0.6.0 = MINOR (safe update)
✅ RIGHT: 0.5.0 → 0.6.0 = MINOR (but may be breaking, research deeply)

❌ WRONG: 0.0.3 → 0.0.4 = PATCH (definitely safe)
✅ RIGHT: 0.0.3 → 0.0.4 = PATCH (highly unstable, verify carefully)
```

**Fix**: 0.x versions are unstable. Classification is correct, but research depth should increase.

**Special Rules**:

- 0.Y.Z → 0.Y+1.Z: Technically MINOR, but may break (research as MAJOR)
- 0.0.Z → 0.0.Z+1: Technically PATCH, but highly unstable (verify all changes)

**Detection Pattern**:

```text
If major version is 0 → Apply special research rules
0.x.x MINOR = treat research depth as MAJOR
0.0.x PATCH = verify thoroughly, assume instability
```

## Version Bump Determination Errors

### Error 6: Incorrect Reset Rules

**Symptom**: Not resetting lower version segments when bumping higher ones

**Examples**:

```text
❌ WRONG: 1.5.3 → 2.5.0 (kept MINOR on MAJOR bump)
✅ RIGHT: 1.5.3 → 2.0.0 (reset MINOR and PATCH)

❌ WRONG: 3.7.2 → 3.8.2 (kept PATCH on MINOR bump)
✅ RIGHT: 3.7.2 → 3.8.0 (reset PATCH)
```

**Fix**: When incrementing a version segment, reset all lower segments to 0.

**Rules**:

- MAJOR bump: Reset MINOR and PATCH to 0
- MINOR bump: Reset PATCH to 0
- PATCH bump: No reset needed

**Detection Pattern**:

```text
If MAJOR changed and (MINOR ≠ 0 or PATCH ≠ 0) → ERROR
If MINOR changed and PATCH ≠ 0 → ERROR
```

---

### Error 7: Change Type Mismatch

**Symptom**: Version bump doesn't match severity of changes

**Examples**:

```text
Changes: Removed public API method
❌ WRONG: 1.5.0 → 1.6.0 (MINOR bump for breaking change)
✅ RIGHT: 1.5.0 → 2.0.0 (MAJOR bump required)

Changes: Added optional parameter to existing method
❌ WRONG: 2.3.0 → 3.0.0 (MAJOR bump for backward-compatible change)
✅ RIGHT: 2.3.0 → 2.4.0 (MINOR bump sufficient)

Changes: Fixed typo in error message
❌ WRONG: 5.1.2 → 5.2.0 (MINOR bump for trivial fix)
✅ RIGHT: 5.1.2 → 5.1.3 (PATCH bump appropriate)
```

**Fix**: Match version bump to most severe change type.

**Change Severity Hierarchy**:

1. Breaking change → MAJOR (highest priority)
2. New feature → MINOR
3. Bug fix → PATCH (lowest priority)

**Detection Pattern**:

```text
If breaking change exists and bump < MAJOR → ERROR
If only features exist and bump = MAJOR → ERROR (over-versioned)
If only fixes exist and bump > PATCH → ERROR (over-versioned)
```

---

### Error 8: Security Fix Assumptions

**Symptom**: Assuming security fixes are always PATCH level

**Examples**:

```text
Security Fix: Changed API to prevent XSS (breaks backward compatibility)
❌ WRONG: 3.2.0 → 3.2.1 (security fix = PATCH)
✅ RIGHT: 3.2.0 → 4.0.0 (breaking change = MAJOR)

Security Fix: Added input validation (backward-compatible)
❌ WRONG: 2.5.0 → 3.0.0 (security = MAJOR)
✅ RIGHT: 2.5.0 → 2.5.1 (backward-compatible fix = PATCH)
```

**Fix**: Security fixes follow normal semver rules. Breaking security fixes are MAJOR.

**Detection Pattern**:

```text
If security fix is mentioned → Check if breaking
Breaking security fix → MAJOR bump required
Non-breaking security fix → PATCH (or MINOR if adds features)
```

## Research Depth Errors

### Error 9: Under-researching MAJOR Changes

**Symptom**: Skipping detailed review of breaking changes

**Examples**:

```text
❌ WRONG: React 17 → 18 reviewed in 5 minutes
✅ RIGHT: React 17 → 18 requires 45+ min full changelog review

❌ WRONG: "Looks good, just a version bump"
✅ RIGHT: "Breaking changes: new concurrent features, strict mode changes..."
```

**Fix**: MAJOR changes always require deep research, regardless of package.

**Required for MAJOR**:

- Full changelog review
- Breaking change analysis
- Migration guide study
- Test plan creation
- Rollback strategy

---

### Error 10: Over-researching PATCH Changes

**Symptom**: Spending excessive time on bug fix releases

**Examples**:

```text
❌ WRONG: 30 minutes researching lodash 4.17.20 → 4.17.21
✅ RIGHT: 2 minutes checking security advisories only

❌ WRONG: Reading all commit messages for PATCH bump
✅ RIGHT: Security check, then approve
```

**Fix**: PATCH changes need minimal research unless security-related.

**Required for PATCH**:

- Security advisory check (2 minutes)
- Skip detailed changelog unless flagged

## Validation Errors

### Error 11: Accepting Invalid Version Sequences

**Symptom**: Not catching version number errors

**Examples**:

```text
❌ WRONG: Accepting 1.2.3 → 1.2.3 (no change)
✅ RIGHT: Rejecting - version must increase

❌ WRONG: Accepting 1.2.3 → 1.4.0 (skipped 1.3.x)
✅ RIGHT: Questioning - why skip minor version?

❌ WRONG: Accepting 2.5.0 → 3.1.0 (MINOR not reset)
✅ RIGHT: Rejecting - should be 3.0.0
```

**Fix**: Validate version sequences follow semver rules.

**Validation Checklist**:

- [ ] Version increased
- [ ] Only one segment incremented (unless coordinated)
- [ ] Lower segments reset appropriately
- [ ] No skipped versions (or documented reason)

---

### Error 12: Ignoring Monorepo Version Coordination

**Symptom**: Not checking related package versions in monorepos

**Examples**:

```text
❌ WRONG: Updating @company/core to 3.0.0, @company/utils stays at 2.5.0
✅ RIGHT: Coordinating both packages to 3.0.0 for breaking changes

❌ WRONG: Independent versioning without checking dependencies
✅ RIGHT: Verify @company/ui doesn't depend on old @company/core API
```

**Fix**: Check for coordinated versioning requirements in monorepos.

## Quick Error Detection Guide

### Red Flags in Classification

1. **Range notation mentioned** → Strip ranges, reclassify
2. **Package importance cited** → Ignore importance, use version numbers
3. **"Skipped version" reasoning** → Focus on segment change, not magnitude
4. **Pre-release as semver bump** → Check for pre-release rules
5. **0.x treated as stable** → Apply special 0.x research rules

### Red Flags in Version Bumps

1. **MAJOR bump without breaking changes** → Over-versioned
2. **MINOR/PATCH bump with breaking changes** → Under-versioned
3. **Non-zero lower segments after bump** → Reset rule violation
4. **Security fix assumes PATCH** → Check if breaking
5. **No version increase** → Invalid bump

### Red Flags in Research

1. **MAJOR with <15 min research** → Under-researched
2. **PATCH with >10 min research** → Over-researched
3. **"Looks fine" without changelog** → Insufficient review
4. **Ignoring migration guides** → Missing critical info

## Error Prevention Checklist

Before finalizing any semver classification:

- [ ] Stripped all range notation (^, ~, >=, etc.)
- [ ] Compared only X.Y.Z numbers
- [ ] Ignored package name/importance
- [ ] Checked for pre-release versions
- [ ] Applied special 0.x rules if needed
- [ ] Verified reset rules for bumps
- [ ] Matched bump to change severity
- [ ] Planned appropriate research depth
- [ ] Validated version sequence
- [ ] Checked monorepo coordination if applicable

## Common Anti-Patterns

### Anti-Pattern 1: Gut Feeling Classification

```text
❌ "This feels like a major update"
✅ "X changed from 4 to 5, this is a MAJOR update"
```

### Anti-Pattern 2: Name-Based Assumptions

```text
❌ "Core packages are always major"
✅ "Version numbers determine classification"
```

### Anti-Pattern 3: Research Shortcuts

```text
❌ "MAJOR update, but I trust this team, skip research"
✅ "MAJOR update requires full changelog review regardless"
```

### Anti-Pattern 4: Version Bump Guessing

```text
❌ "Probably should bump to 2.1.0"
✅ "Breaking change present, must bump to 3.0.0"
```

## Debugging Misclassifications

When classification seems wrong:

1. **Write out the versions**: `7.1.5 → 7.1.6`
2. **Label segments**: `MAJOR=7, MINOR=1, PATCH=5 → MAJOR=7, MINOR=1, PATCH=6`
3. **Identify change**: `PATCH changed (5 → 6)`
4. **Apply rule**: `PATCH change = PATCH classification`
5. **Verify**: Does this match the actual changes made?

If step 5 fails, either:

- Changes don't match version (version should be higher/lower)
- Changes weren't correctly categorized (review change types)

## Summary

Most semver errors fall into three categories:

1. **Classification errors**: Focusing on wrong signals (ranges, names, importance)
2. **Bump errors**: Not matching version to changes or not resetting properly
3. **Research errors**: Wrong depth for change type

**Golden Rule**: Version numbers tell you the classification. Changes tell you the required bump. Neither should involve guessing.
