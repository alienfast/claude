# Real-World Classification Examples

This document provides practical examples of version classifications from actual dependency updates.

## MAJOR Version Changes

### Example 1: React Router 5 → 6

```text
Version: 5.3.4 → 6.0.0
Classification: MAJOR
```

**Breaking Changes**:

- `<Switch>` replaced with `<Routes>`
- Route matching algorithm changed
- `useHistory()` replaced with `useNavigate()`
- Relative routes behavior changed

**Research Required**: Full migration guide review, API compatibility audit

**Time Investment**: 45-60 minutes

---

### Example 2: ESLint 7 → 8

```text
Version: 7.32.0 → 8.0.0
Classification: MAJOR
```

**Breaking Changes**:

- Dropped Node 10 support
- Changed default behavior for unused disable directives
- Removed deprecated rules
- Changed formatting of error messages

**Migration Path**: Update ESLint config, test all rules, update CI

---

### Example 3: TypeScript 4 → 5

```text
Version: 4.9.5 → 5.0.0
Classification: MAJOR
```

**Breaking Changes**:

- Stricter type checking for enums
- Removed legacy emit settings
- Changed module resolution defaults
- Updated JSX emit behavior

**Impact**: May require code changes to satisfy new type checks

## MINOR Version Changes

### Example 1: Next.js Feature Addition

```text
Version: 13.1.5 → 13.2.0
Classification: MINOR
```

**New Features**:

- Added App Router features
- New Image component optimizations
- Built-in SEO component
- Metadata API additions

**Backward Compatibility**: Full (existing code works unchanged)

**Research Required**: Feature overview, check deprecated APIs

---

### Example 2: Lodash Feature Update

```text
Version: 4.17.20 → 4.17.21
Classification: MINOR (technically PATCH in this case)
```

**Changes**:

- Added new utility methods
- Performance improvements
- No breaking changes

**Note**: Lodash uses PATCH for minor changes (their versioning strategy)

---

### Example 3: Material-UI Component Addition

```text
Version: 9.35.0 → 9.36.0
Classification: MINOR
```

**New Features**:

- New DateRangePicker component
- Additional theme customization options
- New CSS utility props

**Backward Compatibility**: Existing components unchanged

## PATCH Version Changes

### Example 1: Security Fix

```text
Version: 7.1.5 → 7.1.6
Classification: PATCH
```

**Changes**:

- Fixed XSS vulnerability in HTML sanitization
- No API changes
- Fully backward compatible

**Research Required**: Security advisory review only

---

### Example 2: Bug Fix

```text
Version: 24.5.1 → 24.5.2
Classification: PATCH
```

**Changes**:

- Fixed memory leak in event listeners
- Corrected TypeScript type definitions
- Fixed edge case in validation logic

**Impact**: None (fixes only, no behavior changes for correct usage)

---

### Example 3: Documentation Update

```text
Version: 1.0.0 → 1.0.1
Classification: PATCH
```

**Changes**:

- Updated README
- Fixed JSDoc comments
- Corrected package.json metadata

**Impact**: Zero code impact

## Pre-release Examples

### Example 1: Alpha to Beta

```text
Version: 2.0.0-alpha.1 → 2.0.0-beta.1
Classification: Pre-release progression
```

**Meaning**: More stable pre-release, not a semver bump

---

### Example 2: RC to Release

```text
Version: 3.0.0-rc.2 → 3.0.0
Classification: Release (MAJOR when compared to 2.x.x)
```

**Meaning**: Final release of version 3.0.0

## Range Notation Examples

### Example 1: Caret Range Update

```text
Declared: ^7.1.5
Installed: 7.1.5
Available: 7.1.6

Update: 7.1.5 → 7.1.6
Classification: PATCH
Range: Still satisfied by ^7.1.5
```

**Action**: Update within existing range, no package.json change needed

---

### Example 2: Caret Range Exceeded

```text
Declared: ^7.1.5
Installed: 7.1.6
Available: 8.0.0

Update: 7.1.6 → 8.0.0
Classification: MAJOR
Range: Exceeds ^7.1.5 range
```

**Action**: Requires package.json update to ^8.0.0, manual approval needed

---

### Example 3: Tilde Range Update

```text
Declared: ~13.1.5
Installed: 13.1.5
Available: 13.2.0

Update: 13.1.5 → 13.2.0
Classification: MINOR
Range: Exceeds ~13.1.5 range
```

**Action**: Tilde blocks MINOR updates, requires package.json change

## Complex Multi-Package Updates

### Example 1: React Ecosystem Update

```text
Package          Old       New       Classification
-------          ---       ---       --------------
react            17.0.2    18.0.0    MAJOR
react-dom        17.0.2    18.0.0    MAJOR
react-router     5.3.4     6.0.0     MAJOR
react-query      3.39.0    4.0.0     MAJOR
```

**Coordinated Update**: All require MAJOR classification, coordinate timing

**Research Required**: Each package independently, plus integration testing

---

### Example 2: Mixed Update Batch

```text
Package          Old       New       Classification
-------          ---       ---       --------------
lodash           4.17.20   4.17.21   PATCH
axios            0.27.0    1.0.0     MAJOR
date-fns         2.28.0    2.29.0    MINOR
jest             28.1.0    28.1.3    PATCH
```

**Strategy**: Group by classification, prioritize MAJOR review

## 0.x Version Examples

### Example 1: Pre-1.0 Minor (Breaking)

```text
Version: 0.2.3 → 0.3.0
Classification: MINOR (but potentially breaking in 0.x)
```

**Note**: In 0.x versions, MINOR bumps may introduce breaking changes

**Research Required**: Treat as MAJOR for research depth

---

### Example 2: Pre-1.0 Patch

```text
Version: 0.2.3 → 0.2.4
Classification: PATCH (likely safe)
```

**Research Required**: Standard PATCH review, but verify no breaking changes

---

### Example 3: Pre-0.1 Changes

```text
Version: 0.0.3 → 0.0.4
Classification: PATCH (but highly unstable)
```

**Note**: 0.0.x versions are highly unstable, even patches may break

## Security-Related Examples

### Example 1: Security Patch

```text
Version: 5.2.1 → 5.2.2
Classification: PATCH
Advisory: CVE-2023-XXXXX (Moderate severity)
```

**Action**: Update immediately, despite being PATCH level

---

### Example 2: Breaking Security Fix

```text
Version: 3.5.0 → 4.0.0
Classification: MAJOR
Advisory: CVE-2023-YYYYY (Critical severity, requires API change)
```

**Breaking Change**: Security fix requires changing API contract

**Action**: Prioritize update, plan migration carefully

## Monorepo Package Examples

### Example 1: Coordinated Major Bump

```text
@company/core:      2.5.0 → 3.0.0   (MAJOR)
@company/utils:     2.5.0 → 3.0.0   (MAJOR - coordinated)
@company/ui:        2.5.0 → 2.6.0   (MINOR - independent)
```

**Strategy**: Core packages bump together, UI independent

---

### Example 2: Independent Versioning

```text
@mui/material:      5.11.0 → 5.12.0   (MINOR)
@mui/icons:         5.11.0 → 5.11.1   (PATCH)
@mui/lab:           5.0.0-alpha.120 → 5.0.0-alpha.121   (Pre-release)
```

**Strategy**: Each package versions independently based on changes

## Classification Mistakes to Avoid

### ❌ Mistake 1: Confusing Range with Version

```text
Wrong:  ^7.1.5 → ^7.1.6 is MAJOR (has caret)
Right:  7.1.5 → 7.1.6 is PATCH (ignore range notation)
```

---

### ❌ Mistake 2: Package Name Bias

```text
Wrong:  react update must be MAJOR (critical package)
Right:  17.0.2 → 17.0.3 is PATCH (classification by version)
```

---

### ❌ Mistake 3: Skipping 0.x Research

```text
Wrong:  0.5.0 → 0.6.0 is MINOR, skip research
Right:  0.5.0 → 0.6.0 is MINOR, but may break (research as MAJOR)
```

---

### ❌ Mistake 4: Ignoring Pre-release Status

```text
Wrong:  1.0.0-beta.1 → 1.0.0-beta.2 is PATCH
Right:  Both are pre-releases, not a semver bump
```

## Quick Reference Table

| Version Change     | Classification | Research Depth | Time Est.  |
|--------------------|----------------|----------------|------------|
| 4.0.0 → 5.0.0      | MAJOR          | Deep           | 30-60 min  |
| 13.1.5 → 13.2.0    | MINOR          | Moderate       | 10-20 min  |
| 7.1.5 → 7.1.6      | PATCH          | Minimal        | 2-5 min    |
| 0.2.3 → 0.3.0      | MINOR (0.x)    | Deep*          | 30-60 min  |
| 1.0.0-rc.1 → 1.0.0 | Release        | None           | 0 min      |

*0.x MINOR changes may be breaking, research as MAJOR
