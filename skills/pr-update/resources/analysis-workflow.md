# Example Analysis Workflow

This document provides step-by-step examples for analyzing PR changes and verifying what's in the final state.

## Step 1: Quick Scope Check

```bash
echo "=== PR Scope Analysis ==="
echo "Commits: $(git log main..HEAD --oneline | wc -l)"
echo ""

echo "Major Areas Changed:"
git diff main...HEAD --name-only | cut -d/ -f1-2 | sort | uniq -c | sort -rn | head -10
```

## Step 2: Verify Infrastructure Changes

```bash
# Check database configuration
echo "Database Configuration:"
git show HEAD:cloud/database/src/SqlDatabase.ts | grep -E "(authentication_plugin|character_set|sslMode|edition)"

# Check if DR replica exists
git show HEAD:cloud/database/src/sql.ts | grep -q "sqlDrReplica" && echo "DR Replica: YES" || echo "DR Replica: NO"

# Check if ETL replica exists
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

```bash
# Check for new stack commands
echo "New Stack Commands:"
git diff main...HEAD -- 'cloud/*/stack' | grep -E "^\+[a-z_]+\(\)" | sed 's/^+//'

# Check for new documentation
test -f packages/api/README.md && echo "API README: EXISTS" || echo "API README: MISSING"
```

## Verification Principles

1. **Always verify existence** - Don't assume anything from commit messages
2. **Use `git show HEAD:path`** - This shows the actual final state
3. **Automate checks** - Scripts reduce errors and save time
4. **Document as you verify** - Take notes of what you find
5. **Check related files** - Configuration, docs, tests should all align
