# Multi-Session Safety

When multiple Claude Code sessions work simultaneously on the same repository, coordination is critical to prevent data loss.

## Core Rules

1. **Never touch changes you didn't create** - If `git status` shows files you didn't modify, leave them alone
2. **Destructive git commands require explicit permission** - The git-permissions.sh hook blocks: `git reset --hard`, `git restore <files>`, `git clean`, `--force` flags
3. **Ask about unexpected changes** - Don't assume, don't delete, don't stage with `git add .`
4. **Only stage files you modified** - Use `git add <specific-file>`, never `git add .` or `git add -A`

## When You See Unexpected Changes

**Say this:**

> "I notice changes to X files that I didn't modify. Should I:
>
> 1. Include them in this commit?
> 2. Leave them unstaged?
> 3. Something else?"

**Don't do this:**

- `git restore <files>` - Permanent data loss
- `git reset --hard` - Permanent data loss
- `git add .` - Stages other work
- Assume they're "mistakes"

## Why This Matters

**October 2025 incident**: Session B deleted Session A's API work by running `git restore` on "unrelated" files, then destroyed its own work with `git reset --hard`. Total permanent loss. Recovery impossible.

**Key lesson**: You are not alone. Other sessions and user's WIP exist. Ask, don't delete.

## Git Commands to Avoid

| Command | Risk | Alternative |
|---------|------|-------------|
| `git reset --hard` | Destroys all uncommitted work | `git stash` or ask user |
| `git restore <files>` | Discards changes permanently | Ask user first |
| `git clean -f` | Deletes untracked files | `git clean -n` (dry run) first |
| `git push --force` | Rewrites remote history | `git push --force-with-lease` |
| `git add .` or `git add -A` | Stages others' work | `git add <specific-file>` |

## Safe Patterns

### Before committing

```bash
# Check what you're about to commit
git status
git diff --staged

# Only stage files you modified
git add path/to/your/file.ts
git add path/to/another/file.ts
```

### When you see unexpected files

```bash
# List what's changed
git status

# Ask user about unexpected files rather than discarding
```

### Before any destructive operation

```bash
# Stash instead of reset
git stash push -m "WIP before operation"

# Or simply ask the user
```

## Hook Protection

The `~/.claude/hooks/git-permissions.sh` hook automatically blocks destructive commands:

- Runs on PreToolUse for Bash commands
- Blocks commands matching dangerous patterns
- Requires explicit user approval to override

This provides a safety net, but understanding why these commands are dangerous is more important than relying on the hook.

## Related Standards

- [Git Standards](git.md) - Commit messages, PR workflows, CI considerations
