# CLAUDE.md

Global user-level guidance for Claude Code. This directory (`~/.claude/`) contains agents, commands, and standards that apply to all projects unless overridden by project-specific configurations.

## Date

The year is 2025.

## Multi-Session Awareness

Multiple Claude Code sessions can work simultaneously. Never touch changes you didn't create. The git-permissions.sh hook blocks destructive commands automatically.

See [Multi-Session Safety](standards/multi-session-safety.md) for detailed rules and examples.

## Available Skills

Skills activate automatically based on context. See [Skills README](skills/README.md) for details.

- `dependency-updater` - Package updates, ncu, version bumps
- `pr-update` - PR titles and descriptions from code changes
- `deprecation-handler` - Deprecated APIs and migrations
- `semver-advisor` - Version bump classification

## Standards

Apply standards from `~/.claude/standards/` based on context. See [Standards README](standards/README.md) for core principles and precedence rules.

## Automatic Quality Checks

Hooks run automatically after edits:

- Linting (biome, markdownlint) after each file modification
- Type checking (tsc) after TypeScript changes

Do not run these manually; they're handled automatically.

## Guidelines

- Never create backup files (.backup, .old, .v2) - Git is the only backup needed
- Modify existing files rather than creating duplicates
- Delete unused code, old implementations, empty directories immediately
- Create documentation only when explicitly requested
- Do not modify generated or build artifact files (e.g., `src/generated/`, `dist/`)
- Do not create git commits unless explicitly requested
- Embrace breaking changes - this is private code, no compatibility layers needed
- Prefer proper solutions over workarounds, even if they require more work

## Anti-Pattern Red Flags

Before suggesting ANY of these, stop and investigate the root cause:

- Version pins or downgrades to avoid compatibility issues
- Error/warning suppression
- Type casting to `any` to bypass checks
- Disabling linter rules
- Partial migrations
- Workarounds instead of proper fixes

These are signals to dig deeper, not shortcuts to take.

## Complexity & Decision Thresholds

Stop and ask for direction when encountering genuine uncertainty, not based on mechanical rules.

### Stop and Ask When

- Root cause unclear after thorough investigation
- Multiple valid solutions with significant trade-offs
- 2+ attempted solutions have failed
- Business/product decisions needed
- Security vs. usability trade-offs

### Proceed With Confidence When

- Solution is obvious from investigation
- Pattern exists in codebase to follow
- Change improves code quality
- Standards explicitly cover the scenario

You have autonomy to make architectural improvements, create new abstractions, change schemas, update APIs, and refactor across many files. Don't ask permission for good engineering decisions.

### When Stopping to Ask

Provide: what you tried, why you're uncertain, options with trade-offs, your recommendation, and a clear question.

## Delegation

For complex multi-step tasks (>5 steps, multiple domains, high context usage), use the `/do` command pattern with TodoWrite and agent delegation.
