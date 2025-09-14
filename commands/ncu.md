# NCU - Automated Dependency Updates

Run `npm-check-updates` (ncu) to analyze available package updates, research release notes and changelogs, detect breaking changes, plan code updates, implement changes, run tests, and create a comprehensive PR.

This command will:

1. **Analyze Updates**: Run `ncu --jsonUpgraded` to detect available package updates
2. **Research Changelogs**: Fetch GitHub release notes and changelogs for updated packages
3. **Detect Breaking Changes**: Analyze release notes for breaking change indicators
4. **Plan Code Changes**: Search codebase for usage of updated packages and assess impact
5. **Apply Updates**: Update package.json files and run `yarn install`
6. **Quality Assurance**: Run `yarn build:ide`, `yarn lint:fix`, and `yarn test`
7. **Create PR**: Generate feature branch, commit with detailed message, and create PR

## Usage Options

- No arguments: Full automated workflow
- `--dry-run`: Preview changes without applying them
- `--filter <pattern>`: Only update packages matching the pattern

## Example Usage

```
/ncu
/ncu --dry-run
/ncu --filter react
```

Please run the following comprehensive dependency update workflow:

1. First, run npm-check-updates to analyze available updates:
   ```bash
   ncu --jsonUpgraded
   ```

2. Parse the output to identify packages with available updates

3. For each package with updates, research the changelog and release notes:
   - Use GitHub API via `gh` CLI to fetch release information
   - Look for breaking changes, migration guides, and new features
   - Assess the impact based on semantic versioning

4. Analyze the codebase to understand how updated packages are used:
   - Search for import statements and require calls
   - Identify files that might be affected by breaking changes

5. If this is not a dry run, apply the updates:
   - Run `ncu -u` to update package.json files
   - Run `yarn install` to install updated dependencies

6. Run quality checks to ensure everything works:
   - `yarn build:ide` for TypeScript compilation
   - `yarn lint:fix` for code quality
   - `yarn test` for test validation

7. If all checks pass, create a comprehensive git commit and PR:
   - Create a feature branch with timestamp
   - Generate detailed commit message including package changes and breaking change notes
   - Create PR with comprehensive description including:
     - List of updated packages with version changes
     - Breaking change analysis and impact assessment
     - Links to relevant changelogs and release notes
     - Quality check results

8. Push the branch and create the PR using `gh pr create`

Please provide verbose output throughout the process, including:
- Number of packages updated
- Any breaking changes detected
- Quality check results
- Final PR creation confirmation

If any step fails, provide clear error messages and stop the process.