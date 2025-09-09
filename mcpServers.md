# Setup for MCP servers

## Github
([doc](https://github.com/github/github-mcp-server/blob/main/docs/installation-guides/install-claude.md))

- [Generate a PAT](https://github.com/settings/personal-access-tokens/new) with the specific permissions you want.

  ![GitHub Permissions](pics/gh-perms.png)
- Add the token (to your lastpass first) then to `~/.claude.env` as `GITHUB_PAT`
- Run `claude mcp add --transport http github https://api.githubcopilot.com/mcp -H "Authorization: Bearer $(grep GITHUB_PAT ~/.claude.env | cut -d '=' -f2)"`
