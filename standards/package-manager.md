# Package Manager Standards

## Tool Preference

- **Use Yarn** (modern, not classic) over npm
- Follow existing project's package manager choice

## Dependencies

- Add packages to specific workspace projects, not root `package.json`
- Check existing dependencies before adding new ones

## Command Usage

- Use project scripts over direct tool invocation
- Prefer `yarn build:ide` over `npx tsc --noEmit`
- Use `yarn npm audit` instead of `npm audit`
- Avoid `npx` when equivalent `yarn` scripts exist
- Avoid `npx vitest` and run `yarn vitest` instead

## Examples

```bash
# ✅ Good
yarn build
yarn test
yarn lint

# ❌ Avoid
npx tsc --noEmit
npm run build
```
