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
| Linear setup | Set `$LINEAR_TEAM` (or pass `--team`) to the project's team key | One-time per project |
| Create issues | `/prd @doc/plan-foo.md` | Review stages and accuracy before approving; approval creates the issues in Linear |
| Triage | `/triage` | Reviews dependencies, identifies blockers, suggests priorities |
| Prioritize | Move stage 1 to "Planned", stage 2 to "Backlog" | |

### 3. Build loop

Per issue, the loop is two commands — `/start` then `/finish`:

| Step | Command | Notes |
| ---- | ------- | ----- |
| Build | `/start PL-12` | Assigns, creates branch, plans, implements, then auto-runs `/quality-review`. Append `wt` to work in an isolated worktree |
| Finish | `/finish` | Reads the review verdict, commits, pushes, marks Ready For Release, then calls `/next` |

Or collapse both into one: `/full PL-12` runs `/start` → `/quality-review` → `/finish` end to end, gated on the review verdict, pausing only for plan approval and the deferred-items decision. Append `wt` to run it in an isolated worktree.

### Parallelism

The `wt` token is what makes fan-out safe. Spin up several concurrent Claude agents — one per issue — and let each drive a `wt` run at the same time:

```text
agent 1:  /full wt PL-1
agent 2:  /full wt PL-2
agent 3:  /full wt PL-3
```

Each runs end to end independently, and the machinery keeps them from colliding:

- **Isolation by worktree.** `/start wt` checks out the issue's branch in its own git worktree under `<repo>/.claude/worktrees/<issue>`, so every agent gets a private working tree and branch — edits, installs, and checkpoints never step on each other or on your main checkout.
- **Serialized merge.** When each `/finish` lands, it advances the shared source branch under a per-repo lock ([scripts/with-repo-lock.py](scripts/with-repo-lock.py)): the worktree branch is first brought up to source's tip _inside its own worktree_ (any conflicts resolved there, never in the main checkout), then source moves by a clean `git merge --ff-only` or an atomic `git update-ref`. Concurrent finishes block briefly and merge in turn, so source is only ever advanced cleanly.
- **Deferred, never forced.** A merge that can't advance right now — e.g. the main checkout is sitting on the shared branch with another session's WIP — is enqueued rather than failed: it leaves the worktree intact and a launchd drainer retries every ~15 min until it lands. Inspect with `/merge-queue`; conflicts are never resolved unattended.
- **Self-cleanup.** Finished worktrees are reclaimed by the hourly reaper — check with `/reap-worktrees`.

For heavy fan-out, keep your main checkout parked on a quiet branch (not the shared integration branch) so every merge advances source by a ref-only update and the queue rarely engages. The full merge protocol lives in [standards/git.md](standards/git.md).

### Standalone skills

Reach for these as needed — between loop steps or on their own:

| Skill | When |
| ----- | ---- |
| `/checkpoint` | Mid-task — commits WIP and posts a progress update to Linear |
| `/quality-review` | On demand — adversarial review + triage/fix loop until convergence (also auto-runs inside `/start`) |
| `/next` | Starting a day or week — suggests the best next issue to pick up |

## Autonomous

The developer workflow above is hands-on: you pick issues and drive `/full` per issue. `/auto` is the same machinery with the human taken out of the pick-and-ship loop, and `/loop` is what keeps it running unattended.

- **`/auto`** ships **exactly one Linear issue per invocation**, end to end: finish any in-flight work, pick the best unblocked issue via `/next`, ship it via `/full auto wt`, record the outcome. Worktree mode is always on (so successive issues chain without stacking branches), and every underlying `auto` default chooses abort/preserve over guess — the worst acceptable outcome is "nothing happened and Linear says why," never "something wrong shipped." Invoking `/auto` **is** the run-scoped grant for the commits and pushes it makes (see [standards/git.md](standards/git.md)).
- **`/loop /auto`** is the way you actually run it. `/loop` supplies the recurrence — its wakeup machinery re-invokes `/auto` for the next issue — while each `/auto` call stays a single, self-contained iteration. (Deliberately: in-prose "keep going" scaffolding is the documented failure mode of autonomous macros, so `/auto` leans on `/loop`'s reliable recurrence instead of inventing its own.)

Point it at a seeded, prioritized backlog and walk away. It works the queue one issue at a time and **ends itself** — no runaway loop:

- **`NO-CANDIDATES`** — the backlog drained. Seed more issues to resume.
- **`AUTO-HALTED`** — the circuit breaker tripped (two consecutive failures, likely systemic) or an environment halt (e.g. a dirty tree it can't attribute). Each failing issue gets a Linear comment explaining why before the loop stops.

`/loop /auto` never clears or compacts the session — the harness's automatic summarization keeps context in check as it grows (`/compact` and `/clear` are user commands the loop must never invoke). Because summarization can drop detail, the run's actual memory lives in `tmp/auto-state.json` (shipped / skipped / failed lists + the failure counter), not the conversation — so the run survives summarization across iterations, and the terminal halt stays sticky even under a fixed-interval `/loop 15m /auto`. A human starts a fresh run by deleting that file.

```text
   /loop /auto  ──  the autonomous driver: re-invokes /auto each iteration
        │
        ▼
  ┌───────────────────────  one iteration  =  one issue  ───────────────────────┐
  │                                                                             │
  │  0  re-anchor + read  tmp/auto-state.json   (cross-iteration run memory)    │
  │  1  preflight ......... finish any in-flight work / resume orphaned wt      │
  │  2  /next ............. rank unblocked candidates, take the top one         │
  │  3  /full auto wt <ISSUE>                                                   │
  │        ├─ /start auto ........... branch · plan → Linear · implement        │
  │        ├─ /quality-review auto .. adversarial review + fix loop             │
  │        └─ /finish auto .......... commit · push · merge · Ready For Release  │
  │  4  record outcome → tmp/auto-state.json,  emit one lifecycle tag           │
  │                                                                             │
  └──────────────────────────────────────┬──────────────────────────────────────┘
                                          │
              AUTO-CONTINUE  ─────────────┤  shipped / skipped / recorded-failure
                                          ▼   → /loop wakes the next iteration
              ─────────────────────────────────────────────────────────────────
              NO-CANDIDATES  (backlog drained)          ─┐
              AUTO-HALTED    (2 consecutive fails / env) ─┴─►  loop stops, awaits a human
```

`/auto` accepts one optional token, `pr`, which opens a PR per issue instead of merging (use only when the queued issues are independent, since the source branch won't advance until PRs land).

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

**Linear Integration:** ([see CLI](https://github.com/Finesssee/linear-cli))

| Skill | Description |
|-------|-------------|
| [linear](skills/linear/) | `linear-cli` quick-reference — the gotchas (anchored comments, dependency graph, parent-linked create) + helper scripts |
| [start](skills/start/) | Start a Linear issue — check blockers, assign, create branch, plan, execute, auto-review |
| [checkpoint](skills/checkpoint/) | Save progress — commit WIP and post progress update to Linear |
| [quality-review](skills/quality-review/) | Adversarial review + triage/fix loop until convergence (gates `pnpm check`) |
| [finish](skills/finish/) | Finish an issue — read verdict, commit/push, mark Ready For Release |
| [full](skills/full/) | End-to-end macro: `/start` → `/quality-review` → `/finish`, gated on verdict |
| [auto](skills/auto/) | Autonomous backlog iteration — ships one issue per invocation; run continuously as `/loop /auto` (see [Autonomous](#autonomous)) |
| [next](skills/next/) | Suggest best next issue using cycle, dependency, and triage signals |
| [triage](skills/triage/) | Analyze backlog for staleness, blockers, and priority suggestions |
| [prd](skills/prd/) | Create agent-friendly tickets with PRDs and success criteria |
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
| [comments](rules/comments.md) | all files (`**/*`) — default to no comments; size to the reader; no provenance decoration |
| [typescript](rules/typescript.md) | `**/*.ts`, `**/*.tsx` |
| [react](rules/react.md) | `**/*.tsx`, `**/*.jsx` |
| [markdown](rules/markdown.md) | `**/*.md`, `**/*.mdx` |
| [package-manager](rules/package-manager.md) | `**/package.json`, lockfiles |

### Hooks

Automatic quality checks that run without manual invocation.

| Hook | Trigger | What It Does |
|------|---------|-------------|
| [git-permissions](hooks/git-permissions.sh) | Before git commands | Blocks destructive operations (`reset --hard`/`--mixed`, `restore`/`checkout <file>`, `clean -f`, `--force`) |
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

> **Prerequisites:** Homebrew, Node, pnpm, git, and Claude Code must already be installed — the script bootstraps everything else and fails fast if Homebrew is missing.

```sh
~/.claude/update.sh
```

This installs:

- The TypeScript LSP plugin
- `gh` and `jq` via Homebrew (installed or upgraded), then runs `gh auth login` if you aren't already authenticated
- Vercel agent-browser and skill-creator
- Vercel React best practices and composition patterns
- `npm-check-updates` (`ncu`) as a pnpm global — required by the dependency-updater skill
- Linear CLI via cargo (Finesssee — the Linear skills already ship with this repo), authenticating it if needed
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

Scope the `paths:` glob to where the rule's principle actually applies: use `**/*` (plus `**/.*` and `**/.*/**` to also cover dotfiles and dot-directories like `.github/`) when the rule is language-agnostic — e.g. comments — and reserve a curated extension list for genuinely language-specific rules. A curated list silently exempts every file type it omits, and the gap stays invisible until a violation slips through an unlisted type (this is how the comment rule once missed a Dockerfile).

## References

- [Anthropic Cookbook: Patterns](https://github.com/anthropics/anthropic-cookbook/tree/main/patterns/)
- [ClaudeLog: You Are the Main Thread](https://claudelog.com/mechanics/you-are-the-main-thread/)
- [Agent configuration inspiration: solatis/claude-config](https://github.com/solatis/claude-config)
- [Claude Code Best Practices](https://htdocs.dev/posts/claude-code-best-practices-and-pro-tips/)
- [Sub-Agent Task Management](https://htdocs.dev/posts/revolutionizing-ai-development-how-claude-codes-sub-agents-transform-task-management/)
