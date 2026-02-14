# CLAUDE.md

Global user-level guidance for Claude Code. This directory (`~/.claude/`) contains rules, skills, commands, and standards that apply to all projects unless overridden by project-specific configurations.

## Date

The year is 2026.

## Multi-Session Awareness

Multiple Claude Code sessions can work simultaneously. Never touch changes you didn't create. The git-permissions.sh hook blocks destructive commands automatically.

See [Git Standards](standards/git.md) for detailed rules and examples.

## Path-Specific Rules

Rules in `~/.claude/rules/` are automatically applied based on file type:

- `typescript.md` - Applied to `**/*.ts`, `**/*.tsx` files
- `react.md` - Applied to `**/*.tsx`, `**/*.jsx` files
- `markdown.md` - Applied to `**/*.md`, `**/*.mdx` files
- `package-manager.md` - Applied to `**/package.json` and lockfiles

## Available Skills

Skills activate automatically based on context. See [Skills README](skills/README.md) for details.

- `dependency-updater` - Package updates, ncu, version bumps
- `pr-update` - PR titles and descriptions from code changes
- `deprecation-handler` - Deprecated APIs and migrations (model: haiku)
- `semver-advisor` - Version bump classification (model: haiku)

## Standards

Universal standards in `~/.claude/standards/` apply across all contexts. See [Standards README](standards/README.md) for core principles.

Key standards:

- `agent-coordination.md` - Parallel vs sequential execution patterns
- `git.md` - Commit messages, PR descriptions, multi-session safety
- `problem-solving.md` - When to ask vs proceed
- `technical-debt-prevention.md` - No backups, no duplicates

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
- Always Read a file before using Write or Edit on it. Write rejects writes to existing files that haven't been Read first. If Write fails, do NOT work around it with Bash (`cat`, `tee`, `echo >`, `sed`, `awk`) — Read the file first, then retry. Never create duplicate/debug files as workarounds.

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
