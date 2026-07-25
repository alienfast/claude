# Semantic Versioning (Semver) Standards

Semver itself (`MAJOR.MINOR.PATCH`, caret/tilde range expansion, pre-release precedence) needs no
restatement here. What this standard fixes is how much work a version change is worth.

## Research depth is set by the classification

Classify the change first, then match effort to it. Over-researching a patch bump wastes a run;
under-researching a major bump ships a breaking change blind.

| Change | Means | Research |
|---|---|---|
| **MAJOR** (`4.0.0 → 5.0.0`) | Incompatible API changes | Full changelog review, breaking-change analysis, migration guide |
| **MINOR** (`9.35.0 → 9.36.0`) | Backward-compatible additions | Feature overview, deprecated-API check |
| **PATCH** (`7.1.5 → 7.1.6`) | Backward-compatible fixes | None beyond the security check below |

Classify against the resolved versions, not the range prefix — `^7.1.5 → ^7.1.6` is a PATCH change.
Package importance is never inferred from the name.

## Security cuts across the classification

- A PATCH release may carry a security fix, so "PATCH = skip research" never means "skip the
  advisory check." Check advisories on every update regardless of type, and prioritize security
  updates even at PATCH.
- A security fix may itself be breaking. Review security-motivated MAJOR updates on their own
  merits rather than batching them with routine majors.

## Downstream expectations

- **Implementation**: plan the testing strategy and the rollback path from the classification —
  a MAJOR update needs both before it lands.
- **Reporting**: group updates by classification and surface MAJOR changes first.

## Tools

```bash
npm outdated                          # current vs wanted vs latest
pnpm outdated
ncu --jsonUpgraded                    # machine-readable upgrade info
semver diff 1.2.3 1.3.0               # → "minor"
semver satisfies 1.2.4 "^1.2.3"       # → true
```

For range-notation and pre-release edge cases, see the
[semver-advisor skill resources](../skills/semver-advisor/resources/range-notation.md).
