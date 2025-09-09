# Claude Configuration Documentation

## Overview

This repository contains reusable Claude configurations, subagents, commands, and templates that can be shared across multiple projects. By cloning this repository to `~/.claude`, you can access these configurations from any project on your system.

## Directory Structure

### `/subagents/`
Contains pre-configured Claude subagents for specific tasks:

- **coding-assistant.json**: General-purpose coding assistant
- **documentation-writer.json**: Specialized for technical documentation
- **code-reviewer.json**: Focused on code review and quality analysis

### `/commands/`
Contains reusable command definitions:

- **code-review.json**: Comprehensive code review command
- **generate-readme.json**: Automatic README generation
- **refactor-code.json**: Code refactoring assistant

### `/templates/`
Contains project templates with pre-configured Claude settings:

- **web-project/**: Configuration for web development projects
- **python-project/**: Configuration for Python projects
- **node-project/**: Configuration for Node.js projects

### `/scripts/`
Utility scripts for setup and management:

- **install.sh**: Installation script for setting up ~/.claude

## Configuration Format

### Subagent Configuration

```json
{
  "name": "subagent-name",
  "description": "Description of the subagent's purpose",
  "version": "1.0.0",
  "capabilities": ["list", "of", "capabilities"],
  "prompt_template": "Base prompt for the subagent",
  "model_preferences": {
    "primary": "claude-3-5-sonnet-20241022",
    "fallback": "claude-3-haiku-20240307"
  },
  "context_settings": {
    "max_tokens": 4096,
    "temperature": 0.1,
    "preserve_conversation": true
  },
  "tools": ["list", "of", "tools"]
}
```

### Command Configuration

```json
{
  "name": "command-name",
  "description": "Description of what the command does",
  "version": "1.0.0",
  "type": "analysis|generation|transformation",
  "parameters": {
    "param_name": {
      "type": "string|path|boolean",
      "description": "Parameter description",
      "required": true,
      "default": "default_value",
      "options": ["list", "of", "valid", "options"]
    }
  },
  "execution": {
    "subagent": "subagent-to-use",
    "prompt_template": "Template with {parameter} placeholders",
    "tools_required": ["required", "tools"]
  },
  "output": {
    "type": "file|summary",
    "filename": "output-filename-template"
  }
}
```

## Best Practices

1. **Naming**: Use descriptive names for subagents and commands
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

### Using a Subagent
```bash
claude --subagent ~/.claude/subagents/coding-assistant.json "Help me debug this function"
```

### Using a Command
```bash
claude --command ~/.claude/commands/code-review.json --target ./src/
```

### Using a Template
```bash
cp -r ~/.claude/templates/web-project/* ./my-new-project/
cd my-new-project
claude --config ./claude-config.json
```