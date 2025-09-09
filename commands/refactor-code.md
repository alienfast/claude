# Refactor Code

Refactor code to improve quality, performance, or maintainability.

## Configuration

**Version:** 1.0.0  
**Type:** transformation

## Parameters

### target (required)
- **Type:** path
- **Description:** File or directory to refactor

### refactor_type (required)
- **Type:** string
- **Description:** Type of refactoring to perform
- **Options:** extract-functions, improve-naming, optimize-performance, enhance-readability, modernize-syntax

### backup (optional)
- **Type:** boolean
- **Description:** Create backup of original files
- **Default:** true

## Execution

- **Agent:** coding-assistant
- **Prompt Template:** Refactor the code at {target} focusing on {refactor_type}. Create backup: {backup}. Preserve functionality while improving code quality. Provide a summary of changes made.
- **Tools Required:** file_editor, code_analysis, backup_creator

## Output

- **Type:** summary
- **Include Changes:** true