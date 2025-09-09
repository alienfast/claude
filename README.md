# Claude Code reusable agents, commands, and MCP configurations

Assuming you have already used claude, there will already be a `~/.claude` directory.  The goal is to supplement your user directory with reusable agent definitions and commands, not to overwrite (or check in!) your personal user settings or data.  Always double check before committing information to ensure it is not local user data, and adjust the `.gitignore` accordingly.

## Setup

```sh
cd ~/.claude
git init
git remote add origin https://github.com/alienfast/claude.git
git fetch
git checkout -b main origin/main
git pull
```

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

References: 
  - https://htdocs.dev/posts/revolutionizing-ai-development-how-claude-codes-sub-agents-transform-task-management/
  - https://htdocs.dev/posts/claude-code-best-practices-and-pro-tips/