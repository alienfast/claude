# Setup for MCP servers

## User scoped

Generally applicable MCP servers for any kind of coding project.

### Github
([doc](https://github.com/github/github-mcp-server/blob/main/docs/installation-guides/install-claude.md))

- [Generate a PAT](https://github.com/settings/personal-access-tokens/new) with the specific permissions you want.

  ![GitHub Permissions](pics/gh-perms.png)
- Add the token (to your lastpass first) then to `~/.zshrc` as `GITHUB_PAT`
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

## Project scoped

Project scoped MCP servers can be shared by a `.mcp.json` file in the root of the project.