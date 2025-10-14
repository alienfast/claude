# Claude Code reusable agents, commands, and MCP configurations

Assuming you have already used claude, there will already be a `~/.claude` directory. The goal is to supplement your user directory with reusable agent definitions and commands, not to overwrite (or check in!) your personal user settings or data. Always double check before committing information to ensure it is not local user data, and adjust the `.gitignore` accordingly.

## Rationale

I’ve selected several MCP servers targeting development context and tooling to provide to the LLM. I have created a team of agents including an `architect`, `debugger`, `developer`, `quality reviewer`, and a `technical-writer`. The top level orchestration and the `architect` run on the more expensive Opus 4.1, while the other agents are pinned to a cheaper model Sonnet that works fine for focused tasks. The top level orchestration may run each of the agents many times to accomplish an objective.

A lot of the agent architecture is aimed at limitations in current LLMs: context rot and context poisoning. Too much information in the context can send the LLM way off track. With the agent model, agents get their own context, while the architect orchestrates from above, creating a plan and handing down assignments. Each agent reports back after success, so both the the top level context and the agent contexts stay smaller and smarter.

For a great overview, read the [ClaudeLog](https://claudelog.com/mechanics/you-are-the-main-thread/) site.

## Usage

Initially, using is triggered through `/plan-execution`, with something like the following:

```sh
/plan-execution I want to update Traefik.  Search traefik documents, compare the version we are currently on, and what we might need to change to be up to date.  Implement the changes.
```

or

```sh
/plan-execution this code was originally written for react 16.  While some files have been updated for react 19, I want you
 to take a look at a comprehensive review of all react code, and implement the best practices for react 19.
```

## Setup

### Add this repo to your user directory

```sh
cd ~/.claude
git init
git remote add origin https://github.com/alienfast/claude.git
git fetch
git checkout -b main origin/main
git pull
```

### Run MCP resources

Due to caps on collections for cloud services such as Zilliz (Milvus), we are running some services locally via `docker compose`. See `start.sh` and `stop.sh` commands, and be sure these are running.

### Configure MCP servers

WARNING: limit your MCP selections to what is useful - they consume initial context. For this reason, and since e.g. github is easily used with `gh` command line, we omit it. Starting claude and running `/context` can show you your initial context.

**For detailed MCP server setup instructions, see [mcpServers.md](mcpServers.md)**

## Background

Claude Code is Anthropic's official CLI tool for software development that integrates Claude's AI capabilities directly into the terminal. It provides intelligent code assistance through a sophisticated agent architecture designed to maximize efficiency and minimize context pollution.

### Key Architecture Concepts

- **Subagents**: Specialized task-focused agents that operate with clean contexts, preventing information bleed between tasks and maintaining optimal performance. Each subagent starts fresh, avoiding context rot that can degrade response quality.
- **Context Management**: The main agent delegates complex multi-step tasks to subagents, keeping the primary context lean and focused. This architecture prevents token exhaustion during iterative development workflows.
- **MCP (Model Context Protocol) Servers**: Enable efficient codebase interaction by indexing and returning only relevant code portions, dramatically reducing token usage compared to full codebase traversal.
- **Tool Specialization**: Subagents can be configured with specific toolsets appropriate to their tasks, while resource-intensive planning remains with the primary Opus model.
- **Shared Resources**: Configuration and custom agents can be stored in ~/.claude for reuse across projects, enabling consistent development patterns.

### Best Practices

- Use subagents for complex, multi-step operations to maintain context clarity
- Leverage MCP servers for large codebase navigation and real-time information retrieval
- Reserve iterative workflows (edit, test, debug cycles) for subagent execution to prevent main context bloat
- Create reusable agent configurations for common development patterns
- `CLAUDE.md`
  - Can be in root and child directories (in addition to the user dir)
  - Are loaded as a prompt with every request
  - More specific yields better results
  - Use the [prompt improver](https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/prompt-improver) periodically to refine these files

References:

- <https://github.com/anthropics/anthropic-cookbook/tree/main/patterns/>
- Primary inspiration for our agents: <https://github.com/solatis/claude-config>
- <https://htdocs.dev/posts/revolutionizing-ai-development-how-claude-codes-sub-agents-transform-task-management/>
- <https://htdocs.dev/posts/claude-code-best-practices-and-pro-tips/>
