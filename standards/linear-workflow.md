# Linear Workflow States

## Terminal States for Dependency Resolution

When evaluating whether an issue's blockers are resolved (for triage, dependency analysis, next-issue suggestions, or any workflow that checks "is this issue unblocked?"), treat both of these states as **completed**:

- **Done** — Fully released
- **Ready For Release** — Implementation complete, code reviewed, PR ready to merge (merge triggers automated deployment)

**Ready For Release** means the work is finished from an implementation perspective. Downstream issues that depend on it can begin — they are unblocked. The remaining step is PR merge, which triggers automated deployment — an operational concern, not an implementation dependency.

## Implication for Skills

Any skill that checks whether blockers are resolved (triage, deps, next, cycle-plan) should treat "Ready For Release" identically to "Done" when determining if an issue is workable.
