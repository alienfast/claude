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

Skills activate automatically based on context. See [Skills README](skills/README.md) for the full list and creation guide.

Linear workflow:

- `linear` - Issue tracking CLI with semantic search
- `start` / `finish` / `next` - Start, complete, and find next Linear issues
- `prd` - Create agent-friendly tickets with PRDs and sub-issues
- `triage` - Backlog analysis and prioritization
- `cycle-plan` / `retro` - Cycle planning and retrospectives
- `deps` / `link-deps` - Dependency visualization and linking

Development workflow:

- `dependency-updater` - Package updates, ncu, version bumps
- `pr-update` - PR titles and descriptions from code changes
- `deprecation-handler` - Deprecated APIs and migrations (model: haiku)
- `semver-advisor` - Version bump classification (model: haiku)
- `react-component-generator` - React 19+ components with TypeScript

External skills installed via `update.sh`: `agent-browser`, `skill-creator`, `vercel-react-best-practices`, `vercel-composition-patterns`

## Standards

Universal standards in `~/.claude/standards/` apply across all contexts. See [Standards README](standards/README.md) for core principles.

Key standards:

- `agent-coordination.md` - Parallel vs sequential execution patterns
- `git.md` - Commit messages, PR descriptions, multi-session safety
- `problem-solving.md` - When to ask vs proceed
- `linear-workflow.md` - Terminal states, dependency resolution rules
- `technical-debt-prevention.md` - No backups, no duplicates

## Automatic Quality Checks

Hooks run automatically after edits:

- Linting (biome, markdownlint) after each file modification
- Type checking (tsc) after TypeScript changes

**NEVER run biome, markdownlint, or tsc manually.** No `pnpm exec biome`, no `npx biome`, no `biome check`, no `markdownlint` — not for single files, not for auto-fixing, not for any reason. The hooks handle all linting and formatting automatically after every edit. Running them manually wastes time and triggers unnecessary permission prompts.

## Mandatory Tool Usage

**NEVER use `grep`, `rg`, `find`, `cat`, `ls`, `head`, `tail`, or `touch` via the Bash tool.** These are denied in settings and will be rejected. Always use:

- **Grep tool** instead of `grep` or `rg` — for all content searching
- **Glob tool** instead of `find` or `ls` — for all file finding
- **Read tool** instead of `cat`, `head`, `tail` — for reading file contents
- **Write tool** instead of `touch` — for creating files

This applies to all contexts: direct calls, piped commands, subagents, and delegated tasks. No exceptions.

## Guidelines

- Save screenshots to `tmp/screenshots/` relative to the project root. Never save to `/tmp` or `/private/tmp`.
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

## Memory

Auto memory persists learned context across sessions in `~/.claude/projects/<project>/memory/`.

- **MEMORY.md** = Descriptive knowledge (what has been discovered). First 200 lines auto-loaded.
- **CLAUDE.md** = Prescriptive rules (what to do). This file.
- **Topic files** = Detailed notes in memory/ for specific domains.

### Boundary Rule

If the information is an instruction or rule → CLAUDE.md or standards/.
If the information is a discovered fact, pattern, or quirk → memory/.

### Multi-Session Safety

Memory files follow the same principles as git working tree protection:

- Only write memory entries relevant to your current work
- Do not overwrite or delete entries another session is actively writing
- Correct outdated or inaccurate entries when discovered
