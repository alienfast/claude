# Package Manager Standards

## Tool Selection

- Follow existing project's package manager (check for `yarn.lock`, `package-lock.json`, `pnpm-lock.yaml`)
- Default to Yarn (modern) for new projects
- Never commit `package-lock.json` if project uses Yarn

## Dependencies

- Check existing dependencies before adding new ones
- In workspaces: add packages to specific workspace projects, not root

## Command Usage

- Use project scripts over direct tool invocation
- Prefer `yarn typecheck` over `npx tsc --noEmit`
- Use `yarn npm audit` instead of `npm audit`
