# Semantic Versioning (Semver) Standards

This document defines semantic versioning standards for all agents working with package dependencies, version comparisons, and release management.

## Semver Format

Semantic versions follow the format: `MAJOR.MINOR.PATCH`

- **MAJOR**: Incompatible API changes, breaking changes
- **MINOR**: Backward-compatible functionality additions
- **PATCH**: Backward-compatible bug fixes

## Version Classification Rules

### MAJOR Version Changes (X.y.z → X+1.y.z)

**Indicates**: Breaking changes, incompatible API changes

**Examples**:

- `4.0.0 → 5.0.0` = MAJOR
- `1.15.2 → 2.0.0` = MAJOR
- `12.1.0 → 13.0.0` = MAJOR

**Research Required**: Full changelog review, breaking change analysis, migration guides

### MINOR Version Changes (x.Y.z → x.Y+1.z)

**Indicates**: New features, backward-compatible additions

**Examples**:

- `9.35.0 → 9.36.0` = MINOR
- `13.1.5 → 13.2.0` = MINOR
- `2.4.1 → 2.5.0` = MINOR

**Research Required**: Feature overview, deprecated API checks

### PATCH Version Changes (x.y.Z → x.y.Z+1)

**Indicates**: Bug fixes, backward-compatible fixes

**Examples**:

- `7.1.5 → 7.1.6` = PATCH
- `24.5.1 → 24.5.2` = PATCH
- `1.0.0 → 1.0.1` = PATCH

**Research Required**: None (assume safe), security advisory check only

## Common Classification Errors

### ❌ WRONG Classifications

- `^7.1.5 → ^7.1.6` labeled as "Major" (actually PATCH)
- `^9.35.0 → ^9.36.0` labeled as "Major" (actually MINOR)
- `^24.5.1 → ^24.5.2` labeled as "Major" (actually PATCH)

### ✅ CORRECT Classifications

- `^4.0.0 → ^5.0.0` = MAJOR (breaking changes)
- `^13.1.5 → ^13.2.0` = MINOR (new features)
- `^7.1.5 → ^7.1.6` = PATCH (bug fixes)

## Version Range Notation

### Caret Ranges (^)

- `^1.2.3` = `>=1.2.3 <2.0.0` (compatible within major version)
- `^0.2.3` = `>=0.2.3 <0.3.0` (compatible within minor for 0.x)
- `^0.0.3` = `>=0.0.3 <0.0.4` (exact patch for 0.0.x)

### Tilde Ranges (~)

- `~1.2.3` = `>=1.2.3 <1.3.0` (compatible within minor version)
- `~1.2` = `>=1.2.0 <1.3.0` (same as above)
- `~1` = `>=1.0.0 <2.0.0` (compatible within major)

### Exact Ranges

- `1.2.3` = exactly `1.2.3`
- `=1.2.3` = exactly `1.2.3` (explicit)

## Pre-release Versions

### Alpha/Beta/RC Format

- `1.0.0-alpha.1` = pre-release alpha
- `1.0.0-beta.2` = pre-release beta
- `1.0.0-rc.1` = release candidate

### Precedence Rules

1. `1.0.0-alpha.1` < `1.0.0-alpha.beta`
2. `1.0.0-alpha.beta` < `1.0.0-beta`
3. `1.0.0-beta` < `1.0.0-beta.2`
4. `1.0.0-beta.2` < `1.0.0-rc.1`
5. `1.0.0-rc.1` < `1.0.0`

## Agent Guidelines

### For Research Agents

- ALWAYS classify versions before researching
- Match research depth to semver type (MAJOR = deep, PATCH = skip)
- Never assume package importance from name

### For Development Agents

- Understand compatibility implications of each change type
- Plan testing strategy based on semver classification
- Consider rollback complexity for MAJOR changes

### For Documentation Agents

- Group updates by semver classification in reports
- Highlight MAJOR changes prominently
- Use consistent terminology (Major/Minor/Patch Version Updates)

## Verification Process

1. **Parse**: Extract current and target versions
2. **Compare**: Check X.Y.Z numbers digit by digit
3. **Classify**: Determine MAJOR, MINOR, or PATCH
4. **Verify**: Confirm classification before proceeding
5. **Document**: Use consistent semver terminology

## Tools and Commands

### NPM/pnpm Commands

- `npm outdated` - shows current vs wanted vs latest
- `ncu --jsonUpgraded` - machine-readable upgrade info
- `pnpm outdated` - pnpm's version of outdated check

### Semver Utilities

- `semver diff 1.2.3 1.3.0` - returns "minor"
- `semver gt 1.3.0 1.2.3` - returns true
- `semver satisfies 1.2.4 "^1.2.3"` - returns true

## Security Considerations

### Security Patches

- PATCH versions may include security fixes
- Always check security advisories regardless of semver type
- Prioritize security updates even for PATCH versions

### Breaking Security Changes

- Security fixes may introduce breaking changes
- Review security-related MAJOR updates carefully
- Consider immediate vs staged rollout for security patches

This standard ensures consistent semver understanding across all agents and prevents classification errors that lead to incorrect research depth and documentation.
