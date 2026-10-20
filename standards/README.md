# Standards Index

Universal standards, read on demand when their domain comes up. [CLAUDE.md](../CLAUDE.md) carries the summaries;
file-type conventions live in [`~/.claude/rules/`](../rules/) and are injected by `paths:` glob when you edit a matching
file.

- [Git](git.md) - commit messages and PR descriptions, working-tree protection, multi-session rules, commit and push
  authorization
- [Git in Worktree-Isolated Sessions](git-worktrees.md) - the shell-shape guard, delegation placement, the `/finish
  merge` protocol, worktree fork point, re-pointing, throwaway worktrees, the hourly reaper
- [Git on Windows Git Bash](git-windows.md) - `ref:path` conversion, path comparison, native tools behind the shell
- [Shell](shell.md) - the tool shell is zsh: exit status, reserved names, expansion, redirects, heredocs, searching
- [Problem-Solving](problem-solving.md) - when to ask vs. proceed, how to write the question (as a story), workaround
  anti-patterns, measurement discipline
- [Agent Coordination](agent-coordination.md) - dispatch mechanics, interface contracts, write-target exclusivity,
  prohibitions in prompts, long-running commands, dead delegates
- [Testing](testing.md) - falsifiable tests: fixture construction, and the shapes that stay green against their own
  mutation
- [Project Commands](project-commands.md) - command discovery and usage
- [Semantic Versioning](semver.md) - research depth by classification, security and changed defaults, tools
- [Technical Debt Prevention](technical-debt-prevention.md) - no backups, no duplicates, modify in place, instruction
  files state the ideal
- [Linear Workflow](linear-workflow.md) - stdin plumbing, terminal states, claims, stage priorities, parent linking,
  batch approvals
- [Linear Filing](linear-filing.md) - the recipe for every issue an agent files: search, create through the helper,
  labels and priority, collision edges, certify last
- [Issue Spec](issue-spec.md) - certified-spec template, quality bar, and the label contracts (`specified`,
  `needs decision`, `human`, `solo`, `deploy-gated`, `simple`, `keeper`)
- [Lifecycle Tags](lifecycle-tags.md) - final-line status tags for Linear-lifecycle skills
- [Deprecation Handling](deprecation-handling.md) - proactively update deprecated code; migration patterns and
  anti-patterns
- [Version-Aware Planning](version-aware-planning.md) - research and planning based on actual dependency versions
- [CI](github-actions.md) - Tracing a CI behavior to the builds that run it; SHA-pinning third-party actions
