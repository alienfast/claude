# Claude Code User Configuration

Reusable agents, skills, standards, hooks, and MCP configurations for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Drop this into your `~/.claude` directory to get an opinionated, productivity-focused setup.

## Why

LLMs suffer from context rot — too much information degrades response quality. This configuration addresses that through **agent delegation**: specialized agents get their own clean contexts while an architect orchestrates from above. Each agent reports back, keeping both the top-level and agent contexts small and focused.

The top-level orchestration and the architect run on Opus, while focused task agents (developer, debugger, reviewer) run on cheaper models (Sonnet/Haiku) that work well for scoped work.

For a deeper overview of this pattern, read [ClaudeLog: You Are the Main Thread](https://claudelog.com/mechanics/you-are-the-main-thread/).

## TL;DR developer workflow

Research-augmented workflow for implementing something large:

| Step | Command | Notes |
| ---- | ------- | ----- |
| Research | `/do research foo bar baz, write your analysis to doc/analysis-foo.md` | |
| Plan | `Read @doc/analysis-foo.md and create an implementation plan as doc/plan-foo.md` | Use plan mode. Consider workstreams and agent teams unless single-threaded |
| Linear setup | Check `.linear.yml` has the correct project/team default | |
| Create issues | `/prd @doc/plan-foo.md` | Should be done by Developer - need to review stages and accuracy. Approval creates issues in Linear |
| Triage | `/triage` | Reviews dependencies, identifies blockers, suggests priorities |
| Prioritize | Move stage 1 to "Planned", stage 2 to "Backlog" | |
| **Build loop** | `/start PL-12` | Assigns, creates branch, plans, implements |
| | Review | |
| | `/finish` | Commits, pushes, marks Ready For Release, calls `/next` |
| | Repeat from `/start` | |

Starting a new day/week? Just run `/next` for a suggestion.

## What's Included

### Agents

Specialized personas delegated to by the `/do` orchestrator.

| Agent | Role | Model |
|-------|------|-------|
| [architect](agents/architect.md) | Solution design, ADRs, technical recommendations | Opus (default) |
| [developer](agents/developer.md) | Code implementation from specifications | Sonnet |
| [debugger](agents/debugger.md) | Root cause analysis through systematic evidence gathering | Haiku |
| [quality-reviewer](agents/quality-reviewer.md) | Security, performance, and concurrency review | Haiku |
| [research](agents/research.md) | Multi-perspective research and synthesis | Haiku |
| [technical-writer](agents/technical-writer.md) | Concise documentation for completed features | Sonnet |

### Skills

Automated multi-step workflows invoked by trigger phrases or slash commands.

**Linear Integration:** ([see CLI](https://github.com/joa23/linear-cli?))

| Skill | Description |
|-------|-------------|
| [linear](skills/linear/) | Issue tracking CLI with semantic search and velocity analytics |
| [start](skills/start/) | Start a Linear issue — check blockers, assign, create branch, plan, execute |
| [finish](skills/finish/) | Finish an issue — check requirements, commit/push, mark Ready For Release |
| [next](skills/next/) | Suggest best next issue using cycle, dependency, and triage signals |
| [triage](skills/triage/) | Analyze backlog for staleness, blockers, and priority suggestions |
| [prd](skills/prd/) | Create agent-friendly tickets with PRDs and success criteria |
| [cycle-plan](skills/cycle-plan/) | Plan cycles using velocity analytics and historical capacity |
| [retro](skills/retro/) | Analyze completed cycles for retrospectives |
| [deps](skills/deps/) | Visualize issue dependency chains and circular dependencies |
| [link-deps](skills/link-deps/) | Discover and link related issues as dependencies |

**Development skills:**

| Skill | Description |
|-------|-------------|
| [pr-update](skills/pr-update/) | Generate PR titles and descriptions from actual code changes |
| [dependency-updater](skills/dependency-updater/) | Orchestrate dependency updates with research and validation |
| [deprecation-handler](skills/deprecation-handler/) | Migrate deprecated APIs with safe patterns |
| [semver-advisor](skills/semver-advisor/) | Classify version changes as MAJOR/MINOR/PATCH |
| [react-component-generator](skills/react-component-generator/) | Generate React 19+ components with TypeScript |

**External Skills (installed by `update.sh`):**

| Skill | Source | Description |
|-------|--------|-------------|
| [agent-browser](skills/agent-browser/) | vercel-labs/agent-browser | Browser automation for AI agents |
| [skill-creator](skills/skill-creator/) | vercel-labs/agent-browser | Guide for creating new skills |
| [vercel-react-best-practices](skills/vercel-react-best-practices/) | vercel-labs/agent-skills | React/Next.js performance optimization |
| [vercel-composition-patterns](skills/vercel-composition-patterns/) | vercel-labs/agent-skills | React composition patterns that scale |

### Standards

Universal rules governing agent behavior. See [standards/README.md](standards/README.md).

| Standard | Covers |
|----------|--------|
| [agent-coordination](standards/agent-coordination.md) | Parallel vs sequential execution patterns |
| [git](standards/git.md) | Commit messages, destructive command blocking, multi-session safety |
| [problem-solving](standards/problem-solving.md) | When to stop and ask vs proceed |
| [technical-debt-prevention](standards/technical-debt-prevention.md) | No backups, no duplicates, delete aggressively |
| [semver](standards/semver.md) | Version classification and compatibility rules |
| [version-aware-planning](standards/version-aware-planning.md) | Check actual versions before planning |
| [deprecation-handling](standards/deprecation-handling.md) | Proactively update deprecated code |
| [project-commands](standards/project-commands.md) | Always use project-specific scripts |

### Rules

Path-specific conventions applied automatically when editing matching files.

| Rule | Applies To |
|------|-----------|
| [typescript](rules/typescript.md) | `**/*.ts`, `**/*.tsx` |
| [react](rules/react.md) | `**/*.tsx`, `**/*.jsx` |
| [markdown](rules/markdown.md) | `**/*.md`, `**/*.mdx` |
| [package-manager](rules/package-manager.md) | `**/package.json`, lockfiles |

### Hooks

Automatic quality checks that run without manual invocation.

| Hook | Trigger | What It Does |
|------|---------|-------------|
| [git-permissions](hooks/git-permissions.sh) | Before git commands | Blocks destructive operations (`reset --hard`, `--force`, `clean -f`) |
| [lint-post-tool](hooks/lint-post-tool.sh) | After file edits | Runs Biome and markdownlint with auto-fix |
| [typecheck](hooks/typecheck.sh) | On stop | Runs `tsc -b` after TypeScript changes |

### Commands

| Command | Description |
|---------|-------------|
| [/do](commands/do.md) | Plan execution — breaks work into phases, delegates to specialized agents, validates each step |

## Setup

### 1. Install Claude Code

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

### 2. Clone into your user directory

Assuming you already have a `~/.claude` directory from using Claude Code, add this repo:

```sh
cd ~/.claude
git init
git remote add origin https://github.com/alienfast/claude.git
git fetch
git checkout -b main origin/main
git pull
```

> **Note:** This supplements your user directory with reusable configurations — it does not overwrite personal settings or data. Always check before committing to ensure no local user data is included, and adjust `.gitignore` accordingly.

### 3. Install skills and tools

```sh
~/.claude/update.sh
```

This installs:

- Vercel agent-browser and skill-creator
- Vercel React best practices and composition patterns
- Linear CLI and all Linear skills
- Runs markdown linting

### 4. Configure MCP servers (optional)

See [mcpServers.md](mcpServers.md) for available MCP server configurations. The current approach favors skills over MCP servers for context efficiency — most MCP servers have been removed in favor of CLI tools and skills.

## Usage

### The `/do` command

Primary entry point for complex, multi-step work:

```text
/do I want to update Traefik. Search traefik documents, compare the version
we are currently on, and what we might need to change to be up to date.
Implement the changes.
```

```text
/do this code was originally written for react 16. While some files have been
updated for react 19, I want you to take a look at a comprehensive review of
all react code, and implement the best practices for react 19.
```

### Skill invocations

Skills activate by trigger phrase or slash command:

- `/prd` for interactive linear issues creation with dependencies, subtasks etc or use existing research like `/prd @doc/my-research.md`
- `/start PL-123` — Start working on a Linear issue
- `/finish` — Complete the current issue
- `update the PR` — Generate/update PR title and description
- `update dependencies` — Run the dependency updater workflow
- `/triage` — Analyze and prioritize backlog

### Automatic hooks

No manual intervention needed — hooks run behind the scenes:

- Destructive git commands are blocked before execution
- Biome and markdownlint run after every file edit
- TypeScript type checking runs when Claude stops

## Customization

### Adding skills

Create a directory in `skills/` with a `SKILL.md` containing YAML frontmatter. See [skills/README.md](skills/README.md) for the full guide.

### Adding standards

Add a markdown file to `standards/`. It will be referenced by agents automatically. See [standards/README.md](standards/README.md).

### Adding rules

Add a markdown file to `rules/` and register the glob pattern in `CLAUDE.md` under "Path-Specific Rules."

## References

- [Anthropic Cookbook: Patterns](https://github.com/anthropics/anthropic-cookbook/tree/main/patterns/)
- [ClaudeLog: You Are the Main Thread](https://claudelog.com/mechanics/you-are-the-main-thread/)
- [Agent configuration inspiration: solatis/claude-config](https://github.com/solatis/claude-config)
- [Claude Code Best Practices](https://htdocs.dev/posts/claude-code-best-practices-and-pro-tips/)
- [Sub-Agent Task Management](https://htdocs.dev/posts/revolutionizing-ai-development-how-claude-codes-sub-agents-transform-task-management/)
