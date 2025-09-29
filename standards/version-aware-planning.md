# Version-Aware Planning

This standard ensures that all planning and research activities are based on the actual versions of dependencies and tools being used in the project, preventing outdated or incorrect information from leading to invalid solutions.

## Pre-Planning Requirements

### Version Detection (MANDATORY FIRST STEP)

Before any planning, research, or definitive statements about capabilities:

1. **Check Project Dependencies**: Always examine `package.json`, `Cargo.toml`, `pyproject.toml`, or equivalent dependency files
2. **Verify Lockfile Versions**: Check `yarn.lock`, `package-lock.json`, `Cargo.lock`, or equivalent for exact versions
3. **Identify Configuration Versions**: Look for version-specific config files (e.g., `biome.json` with `$schema` indicating v2)
4. **Note Framework/Runtime Versions**: Check Node.js, Python, Rust versions from `.nvmrc`, `pyproject.toml`, etc.

### Documentation Strategy

- **NEVER** make definitive statements about what is/isn't possible without version verification
- Use phrases like "checking the latest documentation for your version..." when uncertain
- Explicitly state version numbers when researching: "Looking at Biome v2 documentation..."

## Research Protocol

### Tool Usage Priority

1. **Context7**: Use with exact library IDs and version numbers when available
2. **WebSearch**: Include version numbers in search queries (e.g., "biome v2 config duplication")
3. **Official Documentation**: Prioritize versioned docs over generic guides
4. **GitHub Issues/Releases**: Check recent issues and changelogs for version-specific information

### Search Query Patterns

**Good Examples:**
- "biome v2 configuration inheritance"
- "React 18.3 concurrent features"
- "TypeScript 5.4 new syntax"

**Bad Examples:**
- "biome configuration" (version-agnostic)
- "React hooks" (could apply to any version)
- "latest TypeScript features" (ambiguous)

## Verification Steps

### Before Making Definitive Statements

1. **Cross-Reference Sources**: Check at least 2 authoritative sources
2. **Version Match**: Ensure documentation matches detected project versions
3. **Release Date Validation**: Verify information is current for the identified version
4. **API Existence Check**: When claiming something doesn't exist, verify in version-specific docs

### When Uncertain

- Explicitly state uncertainty: "Let me check the v2 documentation to confirm..."
- Research first, then provide definitive answers
- Acknowledge when information might be outdated: "This may have changed in recent versions"

## Common Version-Sensitive Areas

### Configuration Files
- Biome, ESLint, Prettier config schemas change between major versions
- Build tools (Vite, Webpack, Rollup) have version-specific features
- TypeScript compiler options evolve across versions

### API Capabilities
- Framework features (React hooks, Vue composition API)
- Library methods and their signatures
- CLI commands and flags

### Deprecation Awareness
- Reference [Deprecation Standards](~/.claude/standards/deprecations.md) for handling outdated APIs
- Proactively check for deprecation notices in version-specific docs
- Update deprecated usage even when not directly related to main task

## Integration with Existing Standards

### Package Manager Standards
- Build on existing dependency checking requirements
- Add version-specific API validation to debugging workflows

### Deprecation Standards
- Use version detection to identify deprecated features more accurately
- Apply deprecation fixes based on current version capabilities

## Error Prevention

### Red Flags (Immediate Version Check Required)
- User contradicts previous advice (may indicate outdated information)
- Configuration not working as expected
- API or CLI commands failing unexpectedly
- Documentation seems to conflict with actual behavior

### Recovery Actions
- Acknowledge the outdated information
- Re-research with correct version context
- Provide corrected guidance
- Update approach based on actual capabilities

## Examples

### Good Version-Aware Response
```
Let me check your package.json to see which version of Biome you're using...
I see you're using Biome v2.1.0. Let me look up the v2 configuration documentation to see the latest options for reducing duplication...
```

### Bad Version-Agnostic Response
```
Biome doesn't support configuration inheritance, so you can't reduce duplication.
```

## Compliance

This standard applies to:
- All planning and research activities
- Tool and library capability assessments
- Configuration and setup guidance
- Debugging and troubleshooting
- API usage recommendations

Violations result in potentially incorrect solutions and user frustration when advice doesn't match actual capabilities.