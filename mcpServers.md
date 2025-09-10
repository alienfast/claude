# Setup for MCP servers

## User scoped

Generally applicable MCP servers for any kind of coding project.

### Github

View, edit, create github content (this is used in place of command line `gh`)

([doc](https://github.com/github/github-mcp-server/blob/main/docs/installation-guides/install-claude.md))

- [Generate a PAT](https://github.com/settings/personal-access-tokens/new) with the specific permissions you want.

  ![GitHub Permissions](pics/gh-perms.png)
- Add the token (to your lastpass first) then to `~/.zshrc` as `GITHUB_PAT` and `source ~/.zshrc`
- Add the code block to your  `~/.claude.json` (user level config):

```json
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp",
      "headers": {
        "Authorization": "Bearer ${GITHUB_PAT}"
      }
    }
  },
```
### Context7

MCP for most up to date libraries (not delayed based on LLM training date) as well as documentation.  Reduces hallucinations.

Create an api key at context7.com and save it in your lastpass.  Then add the following to your `~/.claude.json`

```json
  "mcpServers": {
    "context7": {
      "type": "http",
      "url": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "${CONTEXT7_API_KEY}"
      }
    }
  },
```

### Playwright

Navigate web pages, take screenshots, generally control a browser.

Easiest to install with `claude mcp add playwright -s user -- npx @playwright/mcp@latest`

### claude-context 
Make the entire codebase available ([docs](https://github.com/zilliztech/claude-context))

- See the docs and sign up for Zilliz Cloud to get an API key for a vector database.  Add to your `~/.zshrc` as `MILVUS_TOKEN`
- Create an [OpenAI API key](https://platform.openai.com/api-keys) dedicated for `claude-context`.  Add to your `~/.zshrc` as `OPENAI_API_KEY`
- `source ~/.zshrc`
- Run
  ```sh
  claude mcp add claude-context -s user \
    -e OPENAI_API_KEY=\${OPENAI_API_KEY} \
    -e MILVUS_TOKEN=\${MILVUS_TOKEN} \
    -- npx @zilliz/claude-context-mcp@latest
  ```
- In your codebase, run prompt `Index this codebase`
- You can check on the status by runing `Check the indexing status`
- Example prompt `Find functions that handle user authentication`



## Project scoped

Project scoped MCP servers can be shared by a `.mcp.json` file in the root of the project.