# Package manager standards

- Use yarn rather than npm
- AVOID adding new packages at the top level `package.json` if it can be added to a specific project package
- AVOID using npx when there are scripts specified in the `package.json` that accomplish the same thing
