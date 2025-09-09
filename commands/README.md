# Available Commands

## Code Quality

### code-review
- **File**: `code-review.json`
- **Purpose**: Perform comprehensive code review of files or directories
- **Parameters**: 
  - `target` (required): File or directory path
  - `focus` (optional): security, performance, maintainability, etc.
  - `output_format` (optional): markdown, json, plain
- **Example**: `claude --command ~/.claude/commands/code-review.json --target ./src/ --focus security`

### refactor-code
- **File**: `refactor-code.json`
- **Purpose**: Refactor code to improve quality, performance, or maintainability
- **Parameters**:
  - `target` (required): File or directory path
  - `refactor_type` (required): extract-functions, improve-naming, optimize-performance, etc.
  - `backup` (optional): Create backup files
- **Example**: `claude --command ~/.claude/commands/refactor-code.json --target ./app.py --refactor_type improve-naming`

## Documentation

### generate-readme
- **File**: `generate-readme.json`
- **Purpose**: Generate comprehensive README.md file for a project
- **Parameters**:
  - `project_path` (required): Path to project directory
  - `project_type` (optional): web, mobile, cli, library, auto-detect
  - `include_badges` (optional): Include status badges
- **Example**: `claude --command ~/.claude/commands/generate-readme.json --project_path ./`

## Usage

Run any command with:

```bash
claude --command ~/.claude/commands/<command-file> [parameters]
```

Parameters can be passed as command-line arguments using `--parameter_name value` format.