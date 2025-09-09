# Generate README

Generate a comprehensive README.md file for a project.

## Configuration

**Version:** 1.0.0  
**Type:** generation

## Parameters

### project_path (required)
- **Type:** path
- **Description:** Path to the project directory

### project_type (optional)
- **Type:** string
- **Description:** Type of project (web, mobile, cli, library, etc.)
- **Default:** auto-detect

### include_badges (optional)
- **Type:** boolean
- **Description:** Include status badges in the README
- **Default:** true

## Execution

- **Agent:** documentation-writer
- **Prompt Template:** Analyze the project at {project_path} and generate a comprehensive README.md file. The project type is {project_type}. Include badges: {include_badges}. Include installation instructions, usage examples, and contribution guidelines.
- **Tools Required:** file_reader, directory_scanner

## Output

- **Type:** file
- **Filename:** README.md
- **Location:** {project_path}