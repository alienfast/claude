# Available Subagents

## General Purpose

### coding-assistant
- **File**: `coding-assistant.json`
- **Purpose**: General-purpose coding assistant for software development tasks
- **Capabilities**: Code generation, review, debugging, documentation, testing
- **Best for**: Day-to-day development tasks

## Specialized

### documentation-writer
- **File**: `documentation-writer.json`
- **Purpose**: Technical documentation specialist
- **Capabilities**: README generation, API docs, user guides, technical writing
- **Best for**: Creating and maintaining project documentation

### code-reviewer
- **File**: `code-reviewer.json`
- **Purpose**: Comprehensive code review and quality analysis
- **Capabilities**: Security analysis, performance optimization, best practices, bug detection
- **Best for**: Code quality assurance and security reviews

## Usage

Reference any subagent in your Claude commands:

```bash
claude --subagent ~/.claude/subagents/<subagent-file> "Your prompt here"
```

Example:
```bash
claude --subagent ~/.claude/subagents/coding-assistant.json "Help me write a REST API endpoint"
```