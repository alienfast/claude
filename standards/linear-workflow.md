# Linear Workflow

## Passing File Content to Linear CLI

**Never use shell operators (`<`, `|`, `$()`, heredocs) in Bash commands with the `linear` CLI.** Claude Code's permission wildcards don't match through shell operators, so these commands always trigger permission prompts regardless of allow-list rules.

Instead, use the `~/.claude/scripts/linear-stdin.sh` helper:

```bash
# Usage: ~/.claude/scripts/linear-stdin.sh <file> <linear-args...>

# Create issue with description from file
~/.claude/scripts/linear-stdin.sh tmp/description.md i create "Title" --team PL -d -

# Update issue description
~/.claude/scripts/linear-stdin.sh tmp/linear-description-pl-13.md i update PL-13 -d -

# Add comment from file
~/.claude/scripts/linear-stdin.sh tmp/linear-comment-pl-13.md i comment PL-13 -b -
```

**Workflow** for any command that passes file content:

1. `mkdir -p tmp` (once per session)
2. `Write` content to `tmp/<descriptive-name>.md`
3. `~/.claude/scripts/linear-stdin.sh tmp/<file>.md <linear-args> -d -` (or `-b -` for comments)

Short inline values can be passed directly: `linear i create "Bug" --team PL -d "Brief description"`

**This overrides any examples in the linear skill** that use `cat file | linear`, `< file`, or `$(cat <<EOF)`. Those patterns will trigger permission prompts.

## Workflow States

## Terminal States for Dependency Resolution

When evaluating whether an issue's blockers are resolved (for triage, dependency analysis, next-issue suggestions, or any workflow that checks "is this issue unblocked?"), treat both of these states as **completed**:

- **Done** — Fully released
- **Ready For Release** — Implementation complete, code reviewed, PR ready to merge (merge triggers automated deployment)

**Ready For Release** means the work is finished from an implementation perspective. Downstream issues that depend on it can begin — they are unblocked. The remaining step is PR merge, which triggers automated deployment — an operational concern, not an implementation dependency.

## Implication for Skills

Any skill that checks whether blockers are resolved (triage, deps, next, cycle-plan) should treat "Ready For Release" identically to "Done" when determining if an issue is workable.
