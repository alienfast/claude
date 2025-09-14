# Package manager standards

- Use yarn rather than npm
- AVOID adding new packages at the top level `package.json` if it can be added to a specific project package
- AVOID using npx when there are scripts specified in the `package.json` that accomplish the same thing
- AVOID using `npx tsc --noEmit` to check types, and instead use `yarn build:ide` if it is available.
