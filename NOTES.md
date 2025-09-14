# Notes

- `*` means definitely do
- `-` means probably not
- `x` means done and documented

## todo

https://github.com/anthropics/anthropic-cookbook/tree/main/patterns/agents/prompts

Using the research-agent, parallelize 3-5 of as needed to complete the research. Start with short, broad queries, evaluate what’s available, then progressively narrow focus.

After gaining an understanding, you might also parallelize agents for the following:

- gain a comprehensive understanding of any related documentation
- gain a comprehensive understanding of any related APIs
- search for best practices to obtain the objective

## Overall:

- https://claudelog.com/mechanics/you-are-the-main-thread/

## Gateway:

- MetaMCP https://docs.metamcp.com/en
- MCP Gateway https://theogn1s.substack.com/p/bb4fb319-2de4-4f1e-8405-1fc95c7f063c?postPreview=paid&updated=2025-09-04T13%3A28%3A09.791Z&audience=everyone&free_preview=false&freemail=true
- -ToolHive? missing some, but can add custom registry
- -Docker MCP Toolkit? many missing, sentry archived, not enough

## Dev MCPs:

- x \*github - interactions with github instead of gh
- x \*context7
- x \*playwright-mcp https://github.com/microsoft/playwright-mcp or firecrawl
- x \*claude-context - make the entire codebase available https://github.com/zilliztech/claude-context
- x \*mui https://mui.com/material-ui/getting-started/mcp/
- x \*gcloud https://github.com/googleapis/gcloud-mcp
- x \*pulumi https://www.pulumi.com/docs/iac/using-pulumi/mcp-server/

Later:

- kubernetes
- sentry https://docs.sentry.io/product/sentry-mcp/
- mcp-toolbox (db access)
- memory-mcp?
- sequential thinking vs code reasoning https://github.com/mettamatt/code-reasoning - break big problems into small https://github.com/modelcontextprotocol/servers/tree/main/src/sequentialthinking
- figma
- -cloudflare https://github.com/cloudflare/mcp-server-cloudflare multiple available based on the need. Doesn't seem like we need any at this time.

## Admin MCPs:

- slack
- notion
- intercom
- hubspot

## Command examples

- \*Sample claude repo with commands and workflows https://github.com/anthropics/claude-code
- \*Commands examples https://claudecodecommands.directory/ (some but may not be great great. pr fix etc might be nice)

## Agent examples

- https://github.com/solatis/claude-config/blob/main/commands/plan-execution.md good cc basics, includes great doc on prompt-engineering
- https://docs.agentinterviews.com/blog/parallel-ai-coding-with-gitworktrees/ parallel worktrees
- https://github.com/wshobson/agents - ok for some inspiration
- https://github.com/vijaythecoder/awesome-claude-agents - interesting approach. Rediscovers agents/specialists and updates the project CLAUDE.md

Perhaps not good examples?

- https://github.com/0xfurai/claude-code-subagents - numerous agents for inspiration including react, pulumi, gh actions, cci, ruby, k8
- https://github.com/lst97/claude-code-sub-agents pretty extensive/detailed listing

## Prompt examples

Not sure if these are workable or not, but ran into them

- "use the appropriate subagent to Analyse the issue, have it document it in a md file, spawn a new instance to draft a comprehensive fix plan in MD format, spawn a new instance that implements the fix plan and documents it, then update the appropriate documentation and compile a clean distribution package "
- Checkout a new branch named 'feature-xyz' and commit these changes.
- Create a pull request for the current branch.
- Plan the refactor of game.js in SCRATCHPAD.md before making changes.
- Please read the latest documentation for Next.js 14 App Router (you can search for it). Then, explain how to set up a basic page with server-side rendering.

## Command examples

- git commit -m "$(claude -p "Look at the staged git changes and create a summarizing git commit title. Only respond with the title and no affirmation.")"
- cat error.log | claude -p "Explain the root cause of the errors in this log file in a single sentence."
