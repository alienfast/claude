# Linear Workflow

## Passing File Content to Linear CLI

**Never use shell operators (`<`, `|`, `$()`, heredocs) in Bash commands with the `linear-cli` CLI.** Claude Code's permission wildcards don't match through shell operators, so these commands always trigger permission prompts regardless of allow-list rules.

For the two most common operations — updating a description or adding a comment — prefer `~/.claude/scripts/linear-post.sh`, which wraps the stdin plumbing and picks the right flag for each kind:

```bash
# Update issue description
~/.claude/scripts/linear-post.sh description PL-13 tmp/linear-description-pl-13.md

# Add comment from file
~/.claude/scripts/linear-post.sh comment PL-13 tmp/linear-comment-pl-13.md
```

For other operations (most notably `i create` with a file body), use the underlying `~/.claude/scripts/linear-stdin.sh` helper directly:

```bash
# Usage: ~/.claude/scripts/linear-stdin.sh <file> <linear-args...>

# Create issue with description from file
~/.claude/scripts/linear-stdin.sh tmp/description.md i create "Title" --team PL -d -
```

**Workflow** for any command that passes file content:

1. `mkdir -p tmp` (once per session)
2. `Write` content to `tmp/<descriptive-name>.md`
3. `~/.claude/scripts/linear-post.sh <comment|description> <issue-id> tmp/<file>.md`
   (or `~/.claude/scripts/linear-stdin.sh tmp/<file>.md <linear-args> -d -` for non-comment/description ops)

Short inline values can be passed directly: `linear-cli issues create "Bug" --team PL -d "Brief description"`

**This overrides any examples in the linear skill** that use `cat file | linear-cli`, `< file`, or `$(cat <<EOF)`. Those patterns will trigger permission prompts.

## Workflow States

## Terminal States for Dependency Resolution

When evaluating whether an issue's blockers are resolved (for triage, dependency analysis, next-issue suggestions, or any workflow that checks "is this issue unblocked?"), treat both of these states as **completed**:

- **Done** — Fully released
- **Ready For Release** — Implementation complete, code reviewed, PR ready to merge (merge triggers automated deployment)

**Ready For Release** means the work is finished from an implementation perspective. Downstream issues that depend on it can begin — they are unblocked. The remaining step is PR merge, which triggers automated deployment — an operational concern, not an implementation dependency.

## Implication for Skills

Any skill that checks whether blockers are resolved (triage, next) should treat "Ready For Release" identically to "Done" when determining if an issue is workable.

## Certified Specs (the `specified` label)

The `specified` issue label marks a certified spec — problem, desired outcome, and testable success criteria, human-reviewed or produced by a trusted pipeline — and gates autonomous pickup: `/auto` dispatches `/next specified`, so only certified issues ship unattended. The canonical template, quality bar, and read-merge-set label mechanics live in [issue-spec.md](issue-spec.md); `/prd` certifies on create, `/spec` grooms existing issues into shape.

## Spawned Issues Must Link to Their Parent

Any Linear issue created as a follow-up from another issue's workflow (deferred items from `/quality-review`, sub-tasks from `/prd`, etc.) MUST be linked to its originating issue. Use `~/.claude/scripts/linear-create-child.sh <parent> <team> <state> <title> <body-file>` — `linear-cli issues create` has no `--parent` flag (you can set the parent's UUID via `--data` `parentId`, but that path performs no verification), so the helper creates the issue, links the parent with `relations parent`, and **verifies the link, failing hard on an orphan**.

Do not hand-roll create-then-link in a skill (`linear-cli issues create ...` followed by a separate `relations parent`/`issues update --data '{"parentId":...}'`). An un-verified second call is easy to skip when filing several issues in a row, easy to silently fail (the new issue already exists, so the workflow looks successful), and easy to mis-substitute when `<ISSUE-ID>` is a literal placeholder — leaving the issue orphaned in Linear's UI (no "Sub-issues" entry under the parent, no breadcrumb on the child). The helper exists precisely so the link is always made AND verified in one invocation; always route through it.

If the originating context has no issue ID, file the new issue without `--parent` — never invent a parent.
