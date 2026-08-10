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

## Changed defaults cut across the classification

An upgrade ships every default that changed in the range it skips, adopted or not: a bump changes what
happens when you pass **nothing**, not only what is possible. An upgrade whose scope was "adopt none of
the new features" can therefore ship one anyway.

The classification does not aim you at it. A default-on feature lands in whatever release introduced the
feature — often a MINOR, where the table above buys only a feature overview — while the MAJOR's
breaking-change list covers something else. Upstream may or may not flag it: react-dropzone shipped
default-on paste-to-upload as a plain `### Features` entry in 19.2.0, and the 20.0.0 release that a
`17 → 20` consumer would research names exactly one breaking change, an unrelated Node bump.

- **Enumerate the defaults the new version sets for options the code does not pass**, as a step distinct
  from reading the breaking changes, and across the whole skipped range rather than only at the major.
  Reading the installed source settles it faster than the changelog does.
- **Where an issue's Out-of-Scope section names the new features, that list is the checklist.** Confirm
  each is opt-in; one that is default-on is a decision owed now, not a follow-up.
- **Passing the flag that restores the previous behavior is not adopting the feature** — it holds the line
  the scope drew, and belongs in the same change.

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
