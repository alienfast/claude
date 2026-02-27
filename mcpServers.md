# Setup for MCP servers

Note: at any time, you can check the status of your MCP servers with `claude mcp list`.

**NOTE** I have since **removed** most of these and am trying more skills because they are more context efficient.  I do stil have `mui` as it has proven useful. I'll leave these instructions in case I want to try and add them back.

## User scoped

**_MAYBE_** you want to use these.  I have mui configured.

### Material UI ([docs](https://mui.com/material-ui/getting-started/mcp/))

Note: verified that that this is deeper/more useful information that adds to the use of `context7` and can be used in addition.

`claude mcp add mui -s user -- npx @mui/mcp@latest`

## Project scoped

Project scoped MCP servers can be shared by a `.mcp.json` file in the root of the project.
