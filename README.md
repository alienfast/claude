# Claude Code User Configuration

Reusable agents, skills, standards, rules, and hooks for [Claude Code](https://docs.anthropic.com/en/docs/claude-code). Drop this into your `~/.claude` directory to get an opinionated, productivity-focused setup — from a single edit up to a full Linear-driven, issue-to-merge workflow.

## Why

This started as a fix for one problem and grew into an opinionated operating system for agentic development.

**The original problem — context rot.** LLMs degrade as their context fills with too much information. The fix is **agent delegation**: specialized agents (developer, debugger, reviewer, researcher) each get their own clean context while you stay the main thread, orchestrating from above. Each agent reports back a tight summary, keeping both the top-level and the agent contexts small and focused. Opus drives orchestration and architecture; cheaper, faster models (Sonnet/Haiku) handle scoped task work. For a deeper overview of this pattern, read [ClaudeLog: You Are the Main Thread](https://claudelog.com/mechanics/you-are-the-main-thread/).

**What it became.** On top of that foundation, this repo is now a complete, mostly self-maintaining toolkit:

- A **Linear-native issue lifecycle** — plan → start → review → finish → next — driven by slash-command skills that assign issues, cut branches, run an adversarial review-and-fix loop, then mark work Ready For Release.
- **Worktree parallelism** so multiple issues (and multiple concurrent Claude sessions) run in isolation, with background **launchd daemons** that reap finished worktrees and drain deferred merges on their own.
- **Safety rails and quality gates** baked in as hooks — destructive git commands blocked, Biome and markdownlint auto-fixing every edit.
- **Codified standards and path-scoped rules** so every agent shares the same conventions for git, commenting, problem-solving, and language-specific style.

The [developer workflow](#developer-workflow) below ties these together end to end.

## Developer workflow

A research-augmented path for shipping something large, from raw idea to merged code.

### 1. Research & plan

| Step | Command | Notes |
| ---- | ------- | ----- |
| Research | `/do research foo bar baz, write your analysis to doc/analysis-foo.md` | Delegates to research agents; lands an analysis doc you can review |
| Plan | `Read @doc/analysis-foo.md and create an implementation plan as doc/plan-foo.md` | Use plan mode. Consider workstreams and agent teams unless single-threaded |

### 2. Create & prioritize issues

| Step | Command | Notes |
| ---- | ------- | ----- |
| Linear setup | Check `.linear.yml` has the correct project/team default | One-time per project |
| Create issues | `/prd @doc/plan-foo.md` | Review stages and accuracy before approving; approval creates the issues in Linear |
| Triage | `/triage` | Reviews dependencies, identifies blockers, suggests priorities |
| Prioritize | Move stage 1 to "Planned", stage 2 to "Backlog" | |

### 3. Build loop

Repeat per issue until the stage is done:

| Step | Command | Notes |
| ---- | ------- | ----- |
| Build | `/start PL-12` | Assigns, creates branch, plans, implements, then auto-runs `/quality-review`. Append `wt` to work in an isolated worktree |
| Checkpoint _(optional)_ | `/checkpoint` | Commits WIP, posts progress to Linear |
| Review _(standalone)_ | `/quality-review` | Adversarial review + triage/fix loop until convergence |
| Finish | `/finish` | Reads the verdict, commits, pushes, marks Ready For Release, calls `/next` |

### Or, one-shot

Skip the manual loop: `/full PL-12` runs `/start` → `/quality-review` → `/finish` end to end, gated on the review verdict, pausing only for plan approval and the deferred-items decision. Append `wt` to run it in an isolated worktree.

Starting a new day or week? Just run `/next` for a suggestion of what to pick up.

## What's Included

### Agents

Specialized personas the main thread delegates to — directly, or through skills like `/do`, `/start`, and `/quality-review`.

| Agent | Role | Model |
|-------|------|-------|
| [architect](agents/architect.md) | Solution design, ADRs, technical recommendations | Inherits (Opus) |
| [developer](agents/developer.md) | Code implementation from specifications | Sonnet |
| [debugger](agents/debugger.md) | Root cause analysis through systematic evidence gathering | Inherits |
| [quality-reviewer](agents/quality-reviewer.md) | Adversarial review — edge cases, contract violations, security | Inherits |
| [research-lead](agents/research.md) | Multi-perspective research and synthesis | Inherits |
| [technical-writer](agents/technical-writer.md) | Concise documentation for completed features | Sonnet |

### Skills

Automated multi-step workflows invoked by trigger phrases or slash commands.

**Linear Integration:** ([see CLI](https://github.com/joa23/linear-cli))

| Skill | Description |
|-------|-------------|
| [linear](skills/linear/) | Issue tracking CLI with semantic search and velocity analytics |
| [start](skills/start/) | Start a Linear issue — check blockers, assign, create branch, plan, execute, auto-review |
| [checkpoint](skills/checkpoint/) | Save progress — commit WIP and post progress update to Linear |
| [quality-review](skills/quality-review/) | Adversarial review + triage/fix loop until convergence (gates `pnpm check`) |
| [finish](skills/finish/) | Finish an issue — read verdict, commit/push, mark Ready For Release |
| [full](skills/full/) | End-to-end macro: `/start` → `/quality-review` → `/finish`, gated on verdict |
| [next](skills/next/) | Suggest best next issue using cycle, dependency, and triage signals |
| [triage](skills/triage/) | Analyze backlog for staleness, blockers, and priority suggestions |
| [prd](skills/prd/) | Create agent-friendly tickets with PRDs and success criteria |
| [cycle-plan](skills/cycle-plan/) | Plan cycles using velocity analytics and historical capacity |
| [retro](skills/retro/) | Analyze completed cycles for retrospectives |
| [deps](skills/deps/) | Visualize issue dependency chains and circular dependencies |
| [link-deps](skills/link-deps/) | Discover and link related issues as dependencies |
| [reap-worktrees](skills/reap-worktrees/) | Inspect and reclaim leftover `/start wt` worktrees (PR/branch merged, or issue Done/Canceled) |
| [merge-queue](skills/merge-queue/) | Inspect and drain `/finish` merges that were deferred, then retried by the launchd drainer |

**Development skills:**

| Skill | Description |
|-------|-------------|
| [pr-update](skills/pr-update/) | Generate PR titles and descriptions from actual code changes |
| [dependency-updater](skills/dependency-updater/) | Orchestrate dependency updates with research and validation |
| [deprecation-handler](skills/deprecation-handler/) | Migrate deprecated APIs with safe patterns |
| [semver-advisor](skills/semver-advisor/) | Classify version changes as MAJOR/MINOR/PATCH |
| [react-component-generator](skills/react-component-generator/) | Generate React components following project conventions |

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
| [commenting](standards/commenting.md) | Default to no comments; when WHY-comments earn their place |
| [problem-solving](standards/problem-solving.md) | When to stop and ask vs proceed |
| [technical-debt-prevention](standards/technical-debt-prevention.md) | No backups, no duplicates, delete aggressively |
| [linear-workflow](standards/linear-workflow.md) | Terminal states, dependency rules, Linear CLI quoting gotchas |
| [lifecycle-tags](standards/lifecycle-tags.md) | Final-line status tags for Linear-lifecycle skills |
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
| [git-permissions](hooks/git-permissions.sh) | Before git commands | Blocks destructive operations (`reset --hard`/`--mixed`, `restore`/`checkout <file>`, `clean -f`, `--force`) |
| [lint-post-tool](hooks/lint-post-tool.sh) | After file edits | Runs Biome and markdownlint with auto-fix |
| [full-continue](hooks/full-continue.sh) | On stop | Keeps `/full` going: re-dispatches `/finish` if the macro stalls after `READY-FOR-FINISH` |

### Background daemons

Local `launchd` agents installed by `update.sh` (macOS only) that keep the worktree and merge machinery tidy without any manual step.

| Daemon | Cadence | What It Does |
|--------|---------|-------------|
| [merge-queue-drain](launchd/com.alienfast.merge-queue-drain.plist) | Every 15 min | Lands `/finish` merges that were deferred — e.g. main was busy with another session's WIP |
| [worktree-reap](launchd/com.alienfast.worktree-reap.plist) | Hourly | Reclaims completed or abandoned `/start wt` worktrees |

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

- The TypeScript LSP plugin
- Vercel agent-browser and skill-creator
- Vercel React best practices and composition patterns
- Linear CLI via Homebrew (the Linear skills already ship with this repo)
- launchd background daemons on macOS — the merge-queue drainer and worktree reaper
- Runs markdown linting

### 4. Configure MCP servers (optional)

See [mcpServers.md](mcpServers.md) for _some_ available MCP server configurations. The current approach favors skills over MCP servers for context efficiency — most MCP servers have been removed in favor of CLI tools and skills.

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

### Automatic hooks

No manual intervention needed — hooks run behind the scenes:

- Destructive git commands are blocked before execution (`reset`, `restore`/`checkout <file>`, `clean -f`, `--force`)
- Biome and markdownlint run after every file edit
- On stop, `full-continue` keeps `/full` going — re-dispatching `/finish` if the macro stalls after `READY-FOR-FINISH`

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
