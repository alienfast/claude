# Available Agents

## General Purpose

### coding-assistant
- **File**: `coding-assistant.md`
- **Purpose**: General-purpose coding assistant for software development tasks
- **Capabilities**: Code generation, review, debugging, documentation, testing
- **Best for**: Day-to-day development tasks

## Specialized

### documentation-writer
- **File**: `documentation-writer.md`
- **Purpose**: Technical documentation specialist
- **Capabilities**: README generation, API docs, user guides, technical writing
- **Best for**: Creating and maintaining project documentation

### code-reviewer
- **File**: `code-reviewer.md`
- **Purpose**: Comprehensive code review and quality analysis
- **Capabilities**: Security analysis, performance optimization, best practices, bug detection
- **Best for**: Code quality assurance and security reviews

## Usage

Reference any agent in your Claude commands:

```bash
claude --agent ~/.claude/agents/<agent-file> "Your prompt here"
```

Example:
```bash
claude --agent ~/.claude/agents/coding-assistant.md "Help me write a REST API endpoint"
```