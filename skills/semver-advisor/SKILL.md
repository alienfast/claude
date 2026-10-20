---
name: Semantic Version Advisor
description: Classify a version change as MAJOR, MINOR or PATCH and advise on the bump a release needs; research depth, security and tooling rules live in standards/semver.md. Use when determining version numbers, analyzing dependency updates, or classifying version changes.
version: 1.1.0
model: haiku
allowed-tools:
  - Read
  - Grep
  - Glob
  - WebSearch
  - WebFetch
---

# Semantic Version Advisor

This skill helps classify version changes, determine appropriate version bumps, and validate semantic versioning decisions.

## Quick Reference

**Version Format**: `MAJOR.MINOR.PATCH`

- **MAJOR**: Breaking changes, incompatible API changes
- **MINOR**: New features, backward-compatible additions
- **PATCH**: Bug fixes, backward-compatible fixes

## Core Workflows

### Workflow 1: Classify Version Change

**Input**: Old version and new version
**Output**: Classification (MAJOR/MINOR/PATCH) with explanation

#### Decision Tree

```text
┌─────────────────────────────────┐
│  Compare versions X.Y.Z         │
└────────────┬────────────────────┘
             │
             v
    ┌────────────────┐
    │ X changed?     │─ YES ──> MAJOR (breaking changes)
    └────┬───────────┘
         │ NO
         v
    ┌────────────────┐
    │ Y changed?     │─ YES ──> MINOR (new features)
    └────┬───────────┘
         │ NO
         v
    ┌────────────────┐
    │ Z changed?     │─ YES ──> PATCH (bug fixes)
    └────┬───────────┘
         │ NO
         v
    Same version
```

#### Classification Steps

1. **Parse versions**: Extract `MAJOR.MINOR.PATCH` from both versions
2. **Strip notation**: Remove `^`, `~`, `>=` prefixes if present
3. **Compare MAJOR**: If different → MAJOR change
4. **Compare MINOR**: If different → MINOR change
5. **Compare PATCH**: If different → PATCH change
6. **Verify**: Confirm classification matches change type

#### Examples

```text
^4.0.0 → ^5.0.0     = MAJOR (4 → 5, breaking changes)
^13.1.5 → ^13.2.0   = MINOR (1 → 2, new features)
^7.1.5 → ^7.1.6     = PATCH (5 → 6, bug fixes)
9.35.0 → 9.36.0     = MINOR (35 → 36, new features)
1.0.0 → 1.0.1       = PATCH (0 → 1, bug fixes)
```

### Workflow 2: Determine Version Bump

**Input**: List of changes to be included in release
**Output**: Recommended version bump (MAJOR/MINOR/PATCH)

#### Change Classification

**MAJOR bump required if ANY of**:

- Breaking API changes (removed methods, changed signatures)
- Incompatible behavior changes
- Removed public APIs or interfaces
- Changed default behaviors that break existing code
- Renamed public modules or packages
- Dropped support for language/runtime versions

**MINOR bump required if ANY of**:

- New features or capabilities added
- New APIs or methods added
- New optional parameters added
- Deprecated APIs (but still functional)
- Performance improvements (non-breaking)
- New dependencies added

**PATCH bump if ALL of**:

- Bug fixes only
- Documentation updates
- Internal refactoring (no API changes)
- Security patches (backward-compatible)
- Test improvements
- Build process changes

#### Decision Process

```text
Start with PATCH (default)
  ↓
For each change:
  - Breaking change? → Upgrade to MAJOR, stop
  - New feature? → Upgrade to MINOR, continue
  - Bug fix? → Keep current level, continue
  ↓
Return highest level encountered
```

#### Example Analysis

**Changes**:

- Fixed null pointer exception in `getData()`
- Added new `fetchAsync()` method
- Updated documentation

**Analysis**:

1. Null pointer fix → PATCH candidate
2. New method → MINOR upgrade (overrides PATCH)
3. Documentation → No impact

**Result**: MINOR bump (new functionality added)

### Workflow 3: Validate Version Proposal

**Input**: Current version, proposed version, change list
**Output**: Validation result (valid/invalid) with reasoning

#### Validation Rules

1. **Version must increase**: New version > current version
2. **Only one segment increases**: Increment MAJOR OR MINOR OR PATCH
3. **Reset lower segments**: When incrementing, reset lower segments to 0
   - MAJOR bump: `1.5.3 → 2.0.0` ✅ (MINOR and PATCH reset)
   - MINOR bump: `1.5.3 → 1.6.0` ✅ (PATCH reset)
   - PATCH bump: `1.5.3 → 1.5.4` ✅ (no reset needed)
4. **Match change severity**: Version bump matches most severe change
   - Breaking change → MAJOR required
   - New feature → MINOR minimum
   - Bug fix only → PATCH appropriate

#### Validation Examples

**Valid**:

- `1.2.3 → 2.0.0` with breaking changes ✅
- `1.2.3 → 1.3.0` with new features ✅
- `1.2.3 → 1.2.4` with bug fixes ✅

**Invalid**:

- `1.2.3 → 1.4.0` (skipped MINOR version) ❌
- `1.2.3 → 2.1.0` (MINOR not reset to 0) ❌
- `1.2.3 → 1.2.3` (no change) ❌
- `1.2.3 → 1.3.0` with breaking changes (under-versioned) ❌
- `1.2.3 → 2.0.0` with only bug fixes (over-versioned) ❌

## Common Pitfalls

- Range prefixes and package importance: classify against the resolved versions, never the `^`/`~` prefix or the
  package's name (`~/.claude/standards/semver.md` § Research depth is set by the classification).
- Reset rules: `1.5.3 → 2.0.0` for a MAJOR bump, never `1.5.3 → 2.1.0`; lower segments reset to 0.
- Security: a fix can land at any level, and a PATCH never skips the advisory check (`~/.claude/standards/semver.md`
  § Security cuts across the classification).

## Pre-release Versions

### Format

- `1.0.0-alpha.1` - Alpha pre-release
- `1.0.0-beta.2` - Beta pre-release
- `1.0.0-rc.1` - Release candidate

### Precedence

```text
1.0.0-alpha.1
  < 1.0.0-alpha.beta
  < 1.0.0-beta
  < 1.0.0-beta.2
  < 1.0.0-rc.1
  < 1.0.0
```

### Pre-release Classification

- `1.0.0 → 1.0.0-alpha.1` = Pre-release (no semver bump)
- `1.0.0-beta.1 → 1.0.0` = Release (no semver change)
- `1.0.0-rc.1 → 1.1.0` = MINOR release from RC

## Research Depth by Type

The classification sets the research depth; the table is in `~/.claude/standards/semver.md` § Research depth is set by
the classification, with the security and changed-defaults checks that cut across it.

## Tools

`pnpm outdated`, `ncu --jsonUpgraded`, `pnpm dlx semver diff <a> <b>` and `pnpm dlx semver satisfies <v> "<range>"`
(no global `semver` on this machine): `~/.claude/standards/semver.md` § Tools.

## Advisory Templates

### Template: Version Bump Recommendation

```markdown
**Recommended Version Bump**: [MAJOR/MINOR/PATCH]

**Current Version**: X.Y.Z
**Proposed Version**: A.B.C

**Change Summary**:

- [Breaking/Feature/Fix]: Description

**Reasoning**:
[Explain why this classification based on change types]

**Migration Notes** (if MAJOR):
[Required steps for consumers]
```

### Template: Dependency Update Classification

```markdown
**Package**: package-name
**Version Change**: X.Y.Z → A.B.C
**Classification**: [MAJOR/MINOR/PATCH]

**Impact Assessment**:

- Breaking Changes: [Yes/No]
- New Features: [Yes/No]
- Security Fixes: [Yes/No]

**Recommended Action**: [Update now/Test first/Review carefully]
```

## Quick Classification Chart

| Old Version | New Version | Change Type | Classification |
|-------------|-------------|-------------|----------------|
| 1.2.3       | 2.0.0       | X changed   | MAJOR          |
| 1.2.3       | 1.3.0       | Y changed   | MINOR          |
| 1.2.3       | 1.2.4       | Z changed   | PATCH          |
| ^4.0.0      | ^5.0.0      | X changed   | MAJOR          |
| ~1.2.3      | ~1.3.0      | Y changed   | MINOR          |
| 9.35.0      | 9.36.0      | Y changed   | MINOR          |
| 0.2.3       | 0.3.0       | Y changed   | MINOR (0.x)    |

## Resources

- [Version Range Notation Guide](resources/range-notation.md) - Detailed caret, tilde, and exact range rules
- [Classification Examples](resources/examples.md) - Real-world version change examples
- [Common Errors Reference](resources/errors.md) - Patterns to avoid

## Full Specification

For complete semver rules and standards, see:
`~/.claude/standards/semver.md`
