# Quick Start Guide

## Installation

1. **Quick Install** (recommended):
   ```bash
   curl -sSL https://raw.githubusercontent.com/alienfast/claude/main/scripts/install.sh | bash
   ```

2. **Manual Install**:
   ```bash
   git clone https://github.com/alienfast/claude.git ~/.claude
   ```

## First Steps

### 1. Explore Available Configurations
```bash
# List available subagents
ls ~/.claude/subagents/

# List available commands  
ls ~/.claude/commands/

# List project templates
ls ~/.claude/templates/
```

### 2. Use a Subagent
```bash
# Start with the coding assistant
claude --subagent ~/.claude/subagents/coding-assistant.json "Help me write a Python function"
```

### 3. Run a Command
```bash
# Generate a README for your project
claude --command ~/.claude/commands/generate-readme.json --project_path ./

# Review your code
claude --command ~/.claude/commands/code-review.json --target ./src/ --focus security
```

### 4. Set Up a New Project
```bash
# Copy a template to your project
cp -r ~/.claude/templates/python-project/* ./my-new-project/
cd my-new-project

# Use the project configuration
claude --config ./claude-config.json "Help me set up this Python project"
```

## Common Usage Patterns

### Code Review Workflow
```bash
# Quick review
claude --command ~/.claude/commands/code-review.json --target ./src/

# Security-focused review
claude --command ~/.claude/commands/code-review.json --target ./src/ --focus security

# Performance review
claude --command ~/.claude/commands/code-review.json --target ./src/ --focus performance
```

### Documentation Workflow
```bash
# Generate README
claude --command ~/.claude/commands/generate-readme.json --project_path ./

# Update documentation
claude --subagent ~/.claude/subagents/documentation-writer.json "Update the API docs"
```

### Development Workflow
```bash
# Code assistance
claude --subagent ~/.claude/subagents/coding-assistant.json "Help me implement this feature"

# Code refactoring
claude --command ~/.claude/commands/refactor-code.json --target ./src/ --refactor_type improve-naming
```

## Tips

- **Alias Creation**: Create shell aliases for frequently used commands
- **Project Integration**: Add claude configurations to your project's setup scripts
- **Custom Templates**: Create project-specific templates based on the provided examples
- **Version Control**: Keep your ~/.claude directory under version control for personal customizations

## Getting Help

- Read the full [Configuration Guide](configuration-guide.md)
- Check the [README.md](../README.md) for latest updates
- Explore example configurations in the repository