# Version Range Notation Guide

This document provides detailed rules for semantic version range notation.

## Caret Ranges (^)

**Meaning**: Compatible with version, won't introduce breaking changes

### Standard Versions (≥1.0.0)

```text
^1.2.3  = >=1.2.3 <2.0.0
  - Allows: 1.2.3, 1.2.4, 1.3.0, 1.99.99
  - Blocks: 2.0.0, 0.x.x

^1.2.x  = >=1.2.0 <2.0.0
  - Same as ^1.2.0

^1.x    = >=1.0.0 <2.0.0
  - Same as ^1.0.0
```

### Pre-1.0 Minor Versions (0.Y.Z where Y > 0)

```text
^0.2.3  = >=0.2.3 <0.3.0
  - Allows: 0.2.3, 0.2.4, 0.2.99
  - Blocks: 0.3.0, 1.0.0

^0.2.x  = >=0.2.0 <0.3.0
```

**Rationale**: In 0.x versions, minor bumps may be breaking

### Pre-0.1 Patch Versions (0.0.Z)

```text
^0.0.3  = >=0.0.3 <0.0.4
  - Allows: 0.0.3 only
  - Blocks: 0.0.4, 0.1.0, 1.0.0

^0.0.x  = >=0.0.0 <0.1.0
```

**Rationale**: In 0.0.x versions, even patch bumps may be breaking

## Tilde Ranges (~)

**Meaning**: Patch-level changes allowed if MINOR specified, or MINOR-level if not

### With Patch Version Specified

```text
~1.2.3  = >=1.2.3 <1.3.0
  - Allows: 1.2.3, 1.2.4, 1.2.99
  - Blocks: 1.3.0, 2.0.0

~1.2.0  = >=1.2.0 <1.3.0
  - Same as ~1.2.3
```

### Without Patch Version

```text
~1.2    = >=1.2.0 <1.3.0
  - Same as ~1.2.0

~1      = >=1.0.0 <2.0.0
  - Allows: 1.0.0, 1.1.0, 1.99.99
  - Blocks: 2.0.0
```

### Pre-1.0 Versions

```text
~0.2.3  = >=0.2.3 <0.3.0
~0.2    = >=0.2.0 <0.3.0
~0      = >=0.0.0 <1.0.0
```

## Exact Ranges

### Exact Version

```text
1.2.3   = exactly 1.2.3
=1.2.3  = exactly 1.2.3 (explicit)
```

### Wildcard Ranges

```text
1.2.x   = >=1.2.0 <1.3.0
1.x     = >=1.0.0 <2.0.0
*       = >=0.0.0 (any version)
```

## Comparison Operators

### Greater Than

```text
>1.2.3  = any version greater than 1.2.3
  - Allows: 1.2.4, 1.3.0, 2.0.0
  - Blocks: 1.2.3, 1.2.2

>=1.2.3 = version 1.2.3 or greater
  - Allows: 1.2.3, 1.2.4, 1.3.0, 2.0.0
  - Blocks: 1.2.2, 1.1.0
```

### Less Than

```text
<2.0.0  = any version less than 2.0.0
  - Allows: 1.99.99, 1.0.0, 0.1.0
  - Blocks: 2.0.0, 2.0.1

<=2.0.0 = version 2.0.0 or less
  - Allows: 2.0.0, 1.99.99, 1.0.0
  - Blocks: 2.0.1, 2.1.0
```

## Hyphen Ranges

```text
1.2.3 - 2.3.4 = >=1.2.3 <=2.3.4

1.2 - 2.3.4   = >=1.2.0 <=2.3.4

1.2.3 - 2.3   = >=1.2.3 <2.4.0

1.2.3 - 2     = >=1.2.3 <3.0.0
```

**Note**: Partial versions on the right are treated as inclusive maximums

## Logical OR (||)

```text
^1.2.3 || ^2.0.0
  - Allows: 1.2.3+, 2.0.0+ (but not 1.x < 1.2.3)

>=1.2.3 <2.0.0 || >=3.0.0
  - Allows: 1.2.3 to 1.99.99, or 3.0.0+
  - Blocks: 2.x.x
```

## Range Combination Examples

### Development Dependencies

```text
^1.2.3 || ^2.0.0 || ^3.0.0
  - Accepts multiple major versions
  - Common for dev tools
```

### Peer Dependencies

```text
>=1.2.3 <2.0.0
  - Explicit compatibility window
  - Common for library peer deps
```

### Security-Conscious

```text
~1.2.3
  - Only patch updates
  - Minimal risk
```

## Special Cases

### Pre-release Versions

```text
^1.2.3-beta.1
  - Matches: 1.2.3-beta.1, 1.2.3-beta.2, 1.2.3, 1.2.4
  - Must include pre-release tag to match pre-releases

^1.2.3 (without pre-release tag)
  - Matches: 1.2.3, 1.2.4, 1.3.0
  - Blocks: 1.2.3-beta.1, 1.2.4-alpha.1
```

### Build Metadata

```text
1.2.3+build.123
  - Build metadata is ignored in comparisons
  - 1.2.3+build.123 === 1.2.3+build.456
```

## Quick Reference Table

| Notation      | Meaning                        | Example Match           |
|---------------|--------------------------------|-------------------------|
| `^1.2.3`      | Compatible with 1.2.3          | 1.2.3, 1.3.0, 1.99.99   |
| `~1.2.3`      | Patch updates of 1.2.3         | 1.2.3, 1.2.4, 1.2.99    |
| `1.2.3`       | Exact version                  | 1.2.3 only              |
| `>=1.2.3`     | Greater than or equal          | 1.2.3, 1.3.0, 2.0.0     |
| `<2.0.0`      | Less than                      | 1.99.99, 1.0.0          |
| `1.2.x`       | Any patch of 1.2               | 1.2.0, 1.2.99           |
| `1.x`         | Any minor of 1                 | 1.0.0, 1.99.99          |
| `*`           | Any version                    | 0.0.1, 99.99.99         |
| `^0.2.3`      | Compatible with 0.2.3          | 0.2.3, 0.2.4            |
| `^0.0.3`      | Exact 0.0.3                    | 0.0.3 only              |
| `1.2.3 - 2.3` | Range inclusive-exclusive      | 1.2.3, 2.2.99           |

## Common Mistakes

### ❌ Wrong: Treating ^ as exact

```text
Thinking: ^1.2.3 means only 1.2.3
Reality:  ^1.2.3 allows 1.2.3 through 1.99.99
```

### ❌ Wrong: Ignoring 0.x special rules

```text
Thinking: ^0.2.3 allows 0.3.0
Reality:  ^0.2.3 blocks 0.3.0 (minor is breaking in 0.x)
```

### ❌ Wrong: Mixing tilde meanings

```text
Thinking: ~1.2 and ~1.2.3 are different
Reality:  They're the same: >=1.2.0 <1.3.0
```

### ❌ Wrong: Expecting pre-release matches

```text
Thinking: ^1.2.3 matches 1.2.4-beta.1
Reality:  Must explicitly include pre-release tag: ^1.2.3-beta.1
```

## Best Practices

1. **Use ^ for libraries**: Allows non-breaking updates
2. **Use ~ for applications**: More conservative, only patches
3. **Use exact for security-critical**: When updates need review
4. **Use >= < for peer deps**: Clear compatibility window
5. **Avoid * in production**: Too permissive, breaks reproducibility
