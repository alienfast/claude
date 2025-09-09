# Claude Configuration Repository

A reference repository for reusable Claude code agent and command definitions. This repository is designed to be cloned into your home directory as `~/.claude` for easy access and reuse across all your projects.

## Installation

Clone this repository to your home directory:

```bash
git clone https://github.com/alienfast/claude.git ~/.claude
```

Or use the automated installer:

```bash
curl -sSL https://raw.githubusercontent.com/alienfast/claude/main/scripts/install.sh | bash
```

### Validation

After installation, validate your configuration:

```bash
~/.claude/scripts/validate.sh
```

## Directory Structure

```
~/.claude/
├── agents/              # Reusable Claude agent configurations
├── commands/           # Command definitions and templates
├── templates/          # Project templates and examples
├── scripts/            # Utility scripts for setup and management
└── docs/               # Documentation and guides
```

## Usage

### Using Agents

Agent configurations in `~/.claude/agents/` can be referenced in your projects:

```bash
# Reference an agent from your project
claude --agent ~/.claude/agents/coding-assistant.md
```

### Using Commands

Command definitions in `~/.claude/commands/` provide reusable command templates:

```bash
# Use a predefined command
claude --command ~/.claude/commands/code-review.md
```

### Using Templates

Project templates in `~/.claude/templates/` help you quickly set up new projects with Claude configurations:

```bash
# Copy a template to your new project
cp -r ~/.claude/templates/web-project ./my-new-project
```

## Contributing

Feel free to contribute new agents, commands, or templates that would be useful across projects.

## License

MIT License - see [LICENSE](LICENSE) file for details.