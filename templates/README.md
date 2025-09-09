# Available Templates

## Web Development

### web-project
- **Directory**: `web-project/`
- **Purpose**: Configuration for general web development projects
- **Includes**: Basic Claude config for HTML, CSS, JavaScript, TypeScript
- **Context**: Frontend source files, public assets, tests
- **Tools**: File editor, bash execution, browser automation, code analysis

## Backend Development

### node-project
- **Directory**: `node-project/`
- **Purpose**: Configuration for Node.js projects
- **Includes**: Claude config for Node.js applications and libraries
- **Context**: JavaScript/TypeScript source files, package.json, tests
- **Tools**: File editor, bash execution, code analysis, npm manager

### python-project
- **Directory**: `python-project/`
- **Purpose**: Configuration for Python projects
- **Includes**: Claude config for Python applications and libraries
- **Context**: Python source files, requirements.txt, setup files, tests
- **Tools**: File editor, bash execution, code analysis, Python execution

## Usage

1. **Copy template to your project**:
   ```bash
   cp -r ~/.claude/templates/<template-name>/* ./your-project/
   ```

2. **Customize the configuration**:
   Edit `claude-config.json` to match your project's specific needs.

3. **Use with Claude**:
   ```bash
   claude --config ./claude-config.json "Your prompt here"
   ```

## Customization

Each template includes:
- **claude-config.json**: Main configuration file
- **README.md**: Template-specific documentation
- Project structure guidelines
- Recommended tools and settings

Feel free to modify these templates or create new ones based on your project requirements.