# Claude Configuration Documentation

## Overview

This repository contains reusable Claude configurations, agents, commands, and templates that can be shared across multiple projects. By cloning this repository to `~/.claude`, you can access these configurations from any project on your system.

## Directory Structure

### `/agents/`
Contains pre-configured Claude agents for specific tasks:

- **coding-assistant.md**: General-purpose coding assistant
- **documentation-writer.md**: Specialized for technical documentation
- **code-reviewer.md**: Focused on code review and quality analysis

### `/commands/`
Contains reusable command definitions:

- **code-review.md**: Comprehensive code review command
- **generate-readme.md**: Automatic README generation
- **refactor-code.md**: Code refactoring assistant

### `/templates/`
Contains project templates with pre-configured Claude settings:

- **web-project/**: Configuration for web development projects
- **python-project/**: Configuration for Python projects
- **node-project/**: Configuration for Node.js projects

### `/scripts/`
Utility scripts for setup and management:

- **install.sh**: Installation script for setting up ~/.claude

## Configuration Format

### Agent Configuration

Agent configurations are written in markdown format for clarity and readability:

```markdown
# Agent Name

Description of the agent's purpose and capabilities.

## Configuration

**Version:** 1.0.0

## Capabilities

- capability-1
- capability-2
- capability-3

## Prompt Template

Base prompt template for the agent with instructions and context.

## Model Preferences

- **Primary:** claude-3-5-sonnet-20241022
- **Fallback:** claude-3-haiku-20240307

## Context Settings

- **Max Tokens:** 4096
- **Temperature:** 0.1
- **Preserve Conversation:** true

## Tools

- tool-1
- tool-2
- tool-3
```

### Command Configuration

Command configurations are also written in markdown format:

```markdown
# Command Name

Description of what the command does.

## Configuration

**Version:** 1.0.0  
**Type:** analysis|generation|transformation

## Parameters

### parameter_name (required/optional)
- **Type:** string|path|boolean
- **Description:** Parameter description
- **Default:** default_value
- **Options:** option1, option2, option3

## Execution

- **Agent:** agent-to-use
- **Prompt Template:** Template with {parameter} placeholders
- **Tools Required:** tool1, tool2

## Output

- **Type:** file|summary
- **Filename:** output-filename-template
```

## Best Practices

1. **Naming**: Use descriptive names for agents and commands
2. **Versioning**: Always include version numbers for compatibility
3. **Documentation**: Provide clear descriptions and usage examples
4. **Testing**: Test configurations before adding them to the repository
5. **Modularity**: Keep configurations focused and reusable

## Contributing

When adding new configurations:

1. Follow the established directory structure
2. Use consistent naming conventions
3. Include proper documentation
4. Test configurations thoroughly
5. Submit pull requests for review

## Usage Examples

### Using an Agent
```bash
claude --agent ~/.claude/agents/coding-assistant.md "Help me debug this function"
```

### Using a Command
```bash
claude --command ~/.claude/commands/code-review.md --target ./src/
```

### Using a Template
```bash
cp -r ~/.claude/templates/web-project/* ./my-new-project/
cd my-new-project
claude --config ./claude-config.json
```