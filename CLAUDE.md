# CLAUDE.md

Global user-level guidance for Claude Code. This directory (`~/.claude/`) contains rules, skills, commands, and standards that apply to all projects unless overridden by project-specific configurations.

## Multi-Session Awareness

Multiple Claude Code sessions can work simultaneously. Never touch changes you didn't create. The git-permissions.sh hook blocks destructive commands automatically.

See [Git Standards](standards/git.md) for detailed rules and examples.

## Path-Specific Rules

Rules in `~/.claude/rules/` are automatically applied based on file type:

- `typescript.md` - Applied to `**/*.ts`, `**/*.tsx` files
- `react.md` - Applied to `**/*.tsx`, `**/*.jsx` files
- `markdown.md` - Applied to `**/*.md`, `**/*.mdx` files
- `package-manager.md` - Applied to `**/package.json` and lockfiles
- `env-vars.md` - Applied to `**/*.ts`, `**/*.tsx`, `**/*.mts` files (required-env-var handling; `assertEnvVariable`, no silent defaults)
- `biome.md` - Applied to `**/*.ts`, `**/*.tsx`, `**/*.js`, `**/*.jsx`, `**/*.mjs`, `**/*.cjs`, `**/*.json`, `**/*.jsonc` files (Biome projects only — self-nullifies elsewhere; auto-fix output is post-fix, not a TODO, so re-read before editing)

These are generic, file-type-scoped, and shared across all projects via `alienfast/claude.git`. Projects layer their own domain rules in `<project>/.claude/rules/` — committed to the project repo and shared with the team (e.g. basefund's `descope.md`, `nextjs.md`, `apollo.md`, `mui-*.md`, `storybook.md`).

## Available Skills

Skills activate automatically based on context, and the harness lists the full available set each session — so this file does not enumerate them (the list drifts otherwise). See [Skills README](skills/README.md) for the catalog, grouping (Linear workflow vs development workflow), and creation guide. External skills are installed via `update.sh`.

## Standards

Universal standards in `~/.claude/standards/` apply across all contexts and are indexed in [Standards README](standards/README.md) — read the relevant file when its domain comes up. `git.md` (multi-session safety, commit/PR conventions) is the broadest and most safety-critical; read it before any git operation.

## Quality Checks

Lint and type-check before committing — see [Project Commands](standards/project-commands.md) for the commands.

Type checking is hard-gated in `/quality-review` and re-gated in `/finish`; run it directly otherwise.

## Guidelines

- Save screenshots to `tmp/screenshots/` relative to the project root. Never save to `/tmp` or `/private/tmp`.
- Create documentation only when explicitly requested.
- Do not modify generated or build artifact files (e.g., `src/generated/`, `dist/`).
- Do not create git commits unless explicitly requested — see [Git Standards](standards/git.md) for commit/push authorization.
- Always Read a file before using Write or Edit on it. Write rejects writes to existing files that haven't been Read first. If Write fails, do NOT work around it with Bash (`cat`, `tee`, `echo >`, `sed`, `awk`) — Read the file first, then retry. Never create duplicate/debug files as workarounds.
- When writing or editing comments: default to none; add one only when the WHY is non-obvious; size to what the reader needs, not the effort it took to discover; wrap at ~160 chars, never 80. Full guidance auto-injects on source edits — see [rules/comments.md](rules/comments.md).

Own the code and move forward: modify in place, delete aggressively, embrace breaking changes, and never leave backups, duplicates, or compatibility layers behind. See [Technical Debt Prevention](standards/technical-debt-prevention.md) for the full rules.

## Decision-Making & Anti-Patterns

You have autonomy to make good engineering decisions — architectural improvements, new abstractions, schema changes, API updates, cross-file refactors — without asking permission. Proceed directly when the solution is obvious, a codebase pattern exists, or a standard covers the scenario.

Stop and ask when genuine uncertainty remains: root cause still unclear after investigation, multiple valid solutions with significant trade-offs, 2+ attempts failed, or a business / security / usability call is needed. When you stop, give what you tried, the trade-offs, your recommendation, and a clear question.

Before reaching for a workaround — version pin/downgrade, error suppression, `any` cast, disabling a lint rule, partial migration, silent default for required config — stop and fix the root cause. These are signals to dig deeper, not shortcuts.

See [Problem-Solving Standards](standards/problem-solving.md) for the full decision framework, the seven workaround anti-patterns with their narrow exceptions, and the complexity-response template.

## Delegation

For complex multi-step tasks (>5 steps, multiple domains, high context usage), use the `/do` command pattern with TodoWrite and agent delegation.

## Memory

Auto memory persists learned context across sessions in `~/.claude/projects/<project>/memory/`. It is **gitignored and machine-local — never shared with the team.** Treat it as private scratch space, not a knowledge base.

- **MEMORY.md** — index of private notes; first 200 lines auto-loaded each session.
- **Topic files** — detailed private notes for specific domains.

### Where Knowledge Goes

The first question is **shared or private**, not *rule or fact*. Both rules *and* discovered facts usually belong in shared config — only transient, personal context belongs in memory.

**Shared** — committed to git, the whole team gets it:

- `~/.claude/` config (`CLAUDE.md`, `rules/`, `standards/`, `skills/`) → pushed to `alienfast/claude.git`. Cross-project, generic.
- Project config (`<project>/CLAUDE.md`, `<project>/.claude/rules/`) → committed to the project repo. Project-specific.

**Private** — gitignored, only on this machine:

- `~/.claude/projects/<project>/memory/` and `<project>/.claude/agent-memory/`.

Route by what the information is:

- Durable convention or "never do X here," project-specific → that project's `CLAUDE.md` or a `<project>/.claude/rules/*.md`.
- Durable rule that applies everywhere → `~/.claude/CLAUDE.md`, `standards/`, or a file-type `~/.claude/rules/*.md`.
- Durable discovered fact, pattern, or quirk the team should know → the shared layer too. Most of `<project>/CLAUDE.md` is exactly this. A useful discovery is **not** automatically "memory."
- Temporary, personal, or session-spanning context not worth committing → `memory/`.

Memory is the destination of last resort: if it's worth keeping and the team would benefit, promote it to shared config instead.

The `/reflect` skill automates this routing: at the `/quality-review` tail it turns session friction (thrashing, silently-worked-around skills, repeated corrections) into shared-config edits — auto-applying the small/safe ones to the working tree (never committed) and proposing the rest. `/reflect sweep` audits a project's config against the actual codebase and de-duplicates accumulated drift.

### Multi-Session Safety

Memory files follow the same principles as git working tree protection:

- Only write memory entries relevant to your current work
- Do not overwrite or delete entries another session is actively writing
- Correct outdated or inaccurate entries when discovered
