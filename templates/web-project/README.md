# Web Project Template

This template provides a basic Claude configuration for web development projects.

## Setup

1. Copy this template to your project directory:
   ```bash
   cp -r ~/.claude/templates/web-project/* ./
   ```

2. Customize the `claude-config.json` file based on your specific project needs.

3. Start using Claude with your project:
   ```bash
   claude --config ./claude-config.json
   ```

## Configuration

The template includes:
- Default coding assistant subagent
- Common web development commands
- Context files for typical web project structure
- Ignore patterns for build artifacts and dependencies

## Customization

Edit `claude-config.json` to:
- Change the default subagent
- Add project-specific commands
- Modify context files and ignore patterns
- Add custom tools or configurations