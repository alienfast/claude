# loop-boundary-probe

Measures where a plugin may compact the conversation and what origin a `/loop` wakeup's prompt carries, which is what
`loop-boundary` rests on. One row per submitted prompt (origin, whether a turn was running) and one per compaction
attempt (accepted, skipped or rejected; whether this plugin's own `session.compact` hook saw the compaction it
triggered; context before and after). It compacts at the end of every main-loop turn but the first.

```bash
python3 mods/loop-boundary-probe/run.py [model]                      # three prompts over claude -p stream-json
claude --bg --plugin-dir ~/.claude/mods/loop-boundary-probe --model sonnet --effort low --permission-mode auto \
  -n loop-boundary-probe "/loop 1m Reply with exactly the one word: TICK"   # a real loop; stop it with claude stop <id>
```

## Result, 2026-10-09 (Claude Code 2.1.295)

| where the compaction was called | session | result |
|---|---|---|
| `prompt.submit` hook, idle | plugin test harness | refused by the host check: "called from a prompt.submit hook, it would compact under the turn this hook is holding; call it from a later event (turn.complete)" |
| `turn.complete`, main loop | `claude -p --input-format stream-json` | rejected: "not available in a headless (-p / SDK) session yet" |
| `turn.complete`, main loop | `claude --bg` `/loop 1m`, sonnet | accepted: 72,602 → 6,939 tokens, then 55,889 → 6,934; own hook saw its trigger |
| `turn.complete`, main loop | `claude --bg` `/loop 1m`, `opus[1m]` | accepted: 72,313 → 6,776, then a steady 55,1xx → 6,8xx over 21 ticks; own hook saw its trigger |

Every `/loop` wakeup's prompt arrived with origin `scheduled-trigger` and no running turn; the session's first prompt
(`claude --bg "<prompt>"`) arrived as `composer`. The engine's summarizer answered these compactions (two messages
left), which is what `loop-boundary` replaces with its one hand-written message.

## Checks

```bash
claude plugin validate mods/loop-boundary-probe && claude plugin test mods/loop-boundary-probe && mods/typecheck.sh mods/loop-boundary-probe
```
