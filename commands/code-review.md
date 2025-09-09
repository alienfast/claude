# Code Review

Perform a comprehensive code review of files or directories.

## Configuration

**Version:** 1.0.0  
**Type:** analysis

## Parameters

### target (required)
- **Type:** path
- **Description:** File or directory to review

### focus (optional)
- **Type:** string
- **Description:** Specific area to focus on (security, performance, maintainability, etc.)
- **Default:** general

### output_format (optional)
- **Type:** string
- **Description:** Output format for the review
- **Default:** markdown
- **Options:** markdown, json, plain

## Execution

- **Agent:** code-reviewer
- **Prompt Template:** Please review the code at {target} with a focus on {focus}. Provide detailed feedback on code quality, potential issues, and improvement suggestions. Format the output as {output_format}.
- **Tools Required:** file_reader, code_analysis

## Output

- **Type:** file
- **Filename:** code-review-{timestamp}.{output_format}