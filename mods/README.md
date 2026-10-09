# Mods

Plugins of function hooks that run inside Claude Code (mods), one folder each. Every mod here is hooks-only, so it
behaves the same in a terminal, the VS Code panel, and a `claude --bg` fleet session; none draws.

| Mod | What it does | Issue |
|---|---|---|
| `effort-phase` | Main-loop effort per model request by skill phase; per-step usage ledger | BF-2501 |
| `spawn-policy` | Role-to-model tiers and synchronous review dispatch enforced on `agent.spawn` | BF-2502 |
| `effort-probe` | One-shot measurement that an effort rewrite is cache-safe on this build | BF-2501 |
| `loop-boundary` | Near-clear compaction of the main conversation at each `/loop /auto` iteration boundary; per-boundary ledger | BF-2510 |
| `loop-boundary-probe` | One-shot measurement of where a plugin compaction is accepted and what origin a `/loop` wakeup carries | BF-2510 |

## Loading

Every machine that pulls this repo gets the mods through `update.sh`: it registers the repo as the `alienfast-claude`
marketplace (the shared `settings.json` declares it with the home-relative path `~/.claude`, and `update.sh` keeps
that portable form after the CLI rewrites it) and installs `effort-phase`, `spawn-policy` and `loop-boundary` user-wide. An installed
mod loads in place from `mods/<name>`, so a pull is its update, and an edit takes effect at the next session start or
`/reload-plugins`. Each mod ships a kill switch in its `userConfig` (`/plugin configure <name>@alienfast-claude`), and
`claude plugin disable <name>@alienfast-claude` turns one off on a machine without touching the shared settings.

On a machine where a mod is installed, do not also pass `--plugin-dir` for it: two copies would load and both would
write the same ledger. `--plugin-dir ~/.claude/mods/<name>` is for a machine that has not installed it, or for the
probe, which is not installed anywhere.

## Checks

Run all three on a mod before committing it:

```bash
claude plugin validate mods/<name>
claude plugin test mods/<name>
mods/typecheck.sh mods/<name>
```

`typecheck.sh` runs tsc through `pnpm dlx` against the build's `claude-code.d.ts`, which the engine writes beside a mod
only when an interactive session loads it; otherwise it uses the copy the `plugin-authoring` skill extracted this
session. The engine-written `.claude-plugin/types/` folders are gitignored.
