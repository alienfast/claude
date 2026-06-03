# Example Analysis Workflow

This document provides step-by-step examples for analyzing PR changes and verifying what's in the final state.

## Before You Start: Verify the Baseline Before Claiming a Fix

The diff shows the *net* change between `$BASE` and `HEAD` — it does **not** tell you
which side was production reality. Any "fixes / was broken / now works" sentence is a
claim about what shipped, so check the production baseline before writing it.

Resolve the baseline ref first. "What's live now" is the **remote** tip `origin/$BASE`
(the local `$BASE` can lag the remote and misreport the baseline), but a worktree PR's
base may exist only locally — fall back to local `$BASE` when `origin/$BASE` is absent:

```bash
git fetch --quiet origin "$BASE" 2>/dev/null || true
if git rev-parse --verify --quiet "origin/$BASE^{commit}" >/dev/null; then
  BASE_REF="origin/$BASE"
elif git rev-parse --verify --quiet "$BASE^{commit}" >/dev/null; then
  BASE_REF="$BASE"
else
  echo "ERROR: base '$BASE' resolves neither remotely nor locally — fetch or check out the base, then retry." >&2
  exit 1
fi
```

Worked example — a form submits an amount to an API:

```bash
git show "$BASE_REF":src/VerifyDialog.tsx | grep -A3 "verificationAmount ="
```

- If `$BASE_REF` shows the **buggy** behavior (e.g. sends raw dollars to a cents
  API), the PR genuinely fixes a shipped bug — describe the user impact.
- If `$BASE_REF` already shows the **correct** behavior (e.g. it already converts
  to cents), then a dollars-sending bug you see elsewhere in the branch history was
  introduced **and** fixed within this branch and never shipped. Do **not** write
  "verification was broken for every user." Reframe as the net change — e.g.
  "make `verification_amount` cohesive as integer cents (hardening + validation)."
  (`$BASE_REF` is a verified commit, so a `git show` error means the path is absent
  there — the file is new in this branch; if it succeeds but `grep` is empty, the
  pattern didn't match — widen it, don't conclude the behavior is absent.)

To confirm a line was actually changed by this branch (not just reformatted, or
changed-then-restored so the net diff hides it), inspect the **merge base** — where
the branch diverged. This answers "did this branch touch this line," not "what's in
production" (the merge base lags production when the base moved on after the branch
was cut). Capture it first so a failed resolution can't fall through to the index:

```bash
mb=$(git merge-base "$BASE_REF" HEAD) && git show "$mb":src/VerifyDialog.tsx | grep -A3 "verificationAmount ="
```

## Step 1: Quick Scope Check

```bash
echo "=== PR Scope Analysis ==="
echo "Commits: $(git log main..HEAD --oneline | wc -l)"
echo ""

echo "Major Areas Changed:"
git diff main...HEAD --name-only | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -10
```

## Step 2: Verify Infrastructure Changes

Check database configuration:

```bash
echo "Database Configuration:"
git show HEAD:cloud/database/src/SqlDatabase.ts | grep -E "(authentication_plugin|character_set|sslMode|edition)"
```

Check if DR/ETL replicas exist:

```bash
git show HEAD:cloud/database/src/sql.ts | grep -q "sqlDrReplica" && echo "DR Replica: YES" || echo "DR Replica: NO"
git show HEAD:cloud/database/src/sql.ts | grep -q "sqlEtlReplica" && echo "ETL Replica: YES" || echo "ETL Replica: NO"
```

## Step 3: Verify Documentation

```bash
echo "Documentation Structure:"
ls -la doc/stg/ 2>/dev/null | tail -n +4 | awk '{print "doc/stg/" $9}'
ls -la doc/prd/ 2>/dev/null | tail -n +4 | awk '{print "doc/prd/" $9}'
```

## Step 4: Verify CI/CD Changes

```bash
echo "CI/CD Job Names:"
git diff main...HEAD -- .circleci/config.yml | grep -E "^\+.*name:" | sed 's/^+//' | grep -v "^   #"
```

## Step 5: Check Developer Tooling

Check for new stack commands:

```bash
echo "New Stack Commands:"
git diff main...HEAD -- 'cloud/*/stack' | grep -E "^\+[a-z_]+\(\)" | sed 's/^+//'
```

Check for new documentation:

```bash
test -f packages/api/README.md && echo "API README: EXISTS" || echo "API README: MISSING"
```

## Verification Principles

1. **Always verify existence** - Don't assume anything from commit messages
2. **Use `git show HEAD:path`** - This shows the actual final state
3. **Establish the baseline, not just the final state** - A "fix" is a claim about what shipped; verify it with `git show "origin/$BASE":path` (the fetched remote tip — see "Before You Start" for the local-only-base fallback), not the diff, before describing impact
4. **Automate checks** - Scripts reduce errors and save time
5. **Document as you verify** - Take notes of what you find
6. **Check related files** - Configuration, docs, tests should all align
