# effort-phase

A hooks-only mod that sets the main loop's effort per model request from the phase of the skill flow, and writes one
ledger row per request. Subagent requests are never touched.

## Lanes

| Lane | When | Default effort |
|---|---|---|
| judgment | The turn's default, and again after any skill not listed as mechanical expands (start, spec, quality-review, auto, full, do, ...) | the session's own (`session`) |
| mechanical | After a mechanical skill expands in the turn (finish, checkpoint, pr-update, exec-summary, merge-queue, reap-worktrees, reap-tmp, update, fleet-status, fleet-stop), and for the one request that follows a Bash command naming `finish-*.sh`, `linear-post.sh`, `linear-set-state.sh`, `mark-ready-for-release.sh`, or `git push` | high |
| polling | The request that follows a step made only of wait-shaped tool calls (`Monitor`, `ScheduleWakeup`, `TaskStop`, or a Bash command with `sleep`, `until [`, `tail -f`, `wait`) | low |

The phase resets to judgment when a main-loop turn completes, not when one starts: a typed `/finish` expands before
`turn.start` fires, so a reset there would undo the phase the skill had just set (the first live run showed every step
left in judgment for that reason). The signal is the `skill.prompt` event, which fires whether the skill was typed as
`/finish` or called through the Skill tool, so no text classifier and no model call is involved.

## Configuration

`userConfig` in `.claude-plugin/plugin.json`: `enabled`, `judgment_effort` (`session` or a level), `mechanical_effort`,
`polling_effort`, `max_switches_per_turn` (0 = unlimited), `ledger`. The `effort-probe` mod measured an effort switch as
cache-safe on Opus 5.5 with Claude Code 2.1.295, which is why the cap ships at 0.

## Ledger

`<session root>/tmp/effort-ledger-<sessionId>.jsonl`, one row per main-loop request:

```json
{"ts":"...","session":"...","event":"step","turnId":"...","index":3,"lane":"mechanical","effortIn":"xhigh","effortOut":"high","model":"claude-opus-5-5[1m]","answeredBy":"claude-opus-5-5","usage":{"input_tokens":2,"output_tokens":74,"cache_read_input_tokens":59638,"cache_creation_input_tokens":3644,"model":"claude-opus-5-5"},"tools":["Bash"],"commands":["git push origin main"]}
```

Each skill expansion adds a `skill` row (`{"event":"skill","skill":"finish","lane":"mechanical"}`), which the retro
skips when counting requests. The root is resolved once at session start, so a later worktree move does not split the file. The reaper ages it out
with ordinary scratch.

## Loading

Installed user-wide by `update.sh` on every machine that pulls the repo, and loaded in place from this folder, so an
edit takes effect at the next session start or `/reload-plugins`. On a machine without the install,
`claude --plugin-dir ~/.claude/mods/effort-phase` loads it for one session. The retro reads the ledger:
`fleet-metrics.py` reports an **Effort lanes** line, `effort_lanes` in its JSON, and a `rewr%` column in the cross-run
trend.

## Checks

```bash
claude plugin validate mods/effort-phase
claude plugin test mods/effort-phase
mods/typecheck.sh mods/effort-phase
```
