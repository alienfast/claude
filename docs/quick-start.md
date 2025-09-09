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
# List available agents
ls ~/.claude/agents/

# List available commands  
ls ~/.claude/commands/

# List project templates
ls ~/.claude/templates/
```

### 2. Use an Agent
```bash
# Start with the coding assistant
claude --agent ~/.claude/agents/coding-assistant.md "Help me write a Python function"
```

### 3. Run a Command
```bash
# Generate a README for your project
claude --command ~/.claude/commands/generate-readme.md --project_path ./

# Review your code
claude --command ~/.claude/commands/code-review.md --target ./src/ --focus security
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
claude --command ~/.claude/commands/code-review.md --target ./src/

# Security-focused review
claude --command ~/.claude/commands/code-review.md --target ./src/ --focus security

# Performance review
claude --command ~/.claude/commands/code-review.md --target ./src/ --focus performance
```

### Documentation Workflow
```bash
# Generate README
claude --command ~/.claude/commands/generate-readme.md --project_path ./

# Update documentation
claude --agent ~/.claude/agents/documentation-writer.md "Update the API docs"
```

### Development Workflow
```bash
# Code assistance
claude --agent ~/.claude/agents/coding-assistant.md "Help me implement this feature"

# Code refactoring
claude --command ~/.claude/commands/refactor-code.md --target ./src/ --refactor_type improve-naming
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