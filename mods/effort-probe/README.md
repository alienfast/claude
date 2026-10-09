# effort-probe

Measures whether a `turn.step` effort rewrite preserves the prompt cache. One scripted `claude -p` conversation of four
main-loop requests (three chained Reads, then the answer) runs with this mod loaded; in `switch` mode the hook rewrites
request 1's effort to `low`, in `control` mode it rewrites nothing. Each request's usage lands in a JSONL ledger.

```bash
mods/effort-probe/run.sh control          # baseline
mods/effort-probe/run.sh switch           # request 1 at low effort
mods/effort-probe/run.sh switch sonnet    # another model
```

## Result, 2026-10-09

Claude Code 2.1.295, `opus[1m]` answered by `claude-opus-5-5`, `--effort high`.

| request | effort sent (control / switch) | cache_read control | cache_read switch | cache_creation control | cache_creation switch |
|---|---|---|---|---|---|
| 0 | high / high | 21,977 | 23,760 | 37,656 | 35,878 |
| 1 | high / low | 59,633 | 59,638 | 3,644 | 3,644 |
| 2 | high / high | 63,277 | 63,282 | 148 | 148 |
| 3 | high / high | 63,425 | 63,430 | 143 | 143 |

The switched request and the switch-back request read the whole prefix from cache and wrote only the new turn, the same
as the control, so a `turn.step` effort rewrite is cache-safe on Opus 5.5 on this build. Request 0 differs only because
the two first requests ran concurrently and each wrote its own entry. The debug log records request ids, not bodies, so
the wire shape (per-message effort system message or top-level field) is not observed directly.

Re-run after a Claude Code upgrade before trusting `effort-phase` with per-step switching; its `max_switches_per_turn`
option is the fallback if the numbers change.

## Checks

```bash
claude plugin validate mods/effort-probe
claude plugin test mods/effort-probe
mods/typecheck.sh mods/effort-probe
```
