# loop-boundary

A hooks-only mod that compacts the main conversation to a near-clear at each `/loop /auto` iteration boundary, so every
iteration starts at the session's fixed floor instead of carrying the previous iterations' context. `/auto` keeps its
cross-iteration state in `tmp/auto-state-<runKey>.json` and Linear, which is what makes the near-clear loss-free.

## When it compacts

A **boundary** is a main-loop turn that ended with one of `/auto`'s iteration outcome lines (`SHIPPED-MERGE`,
`SHIPPED-PR`, `DEFERRED-MERGE`, `SKIPPED-*`, `BLOCKED-ON-REVIEW`, `AUTO-CONTINUE`, `NO-CANDIDATES`, `AUTO-HALTED`), in
a session that is **looping** — a `/loop` prompt was typed or dispatched, a scheduled-trigger wakeup arrived, or a
`ScheduleWakeup` call armed the next iteration — on a loop prompt that begins with a configured prefix (`/auto`).

Never compacted: a turn with no outcome line (the fallback heartbeat's status check with delegated work in flight, or a
stalled turn), any turn in a session running no loop, the turn whose `ScheduleWakeup` ends the loop, an aborted or
errored turn, and every subagent conversation. Each passed-through looping turn gets a `pass` ledger row with its reason.

The compaction is called from `turn.complete`, the one site the engine accepts it from (the probe's result is in
`mods/loop-boundary-probe/README.md`); the mod's own `session.compact` hook answers that compaction with one message
naming the outcome line, the run key and the run-state file, so no summarizer request is made.

## Measured, 2026-10-09

Installed mod, `claude --bg` `/loop 1m` on sonnet with the loop prompt configured as a prefix, each reply ending in an
outcome line: the first boundary took the next request from 72,791 to 45,813 tokens, and the second iteration's last
request was 45,813 again — the floor held, nothing accumulated. In a fleet session the floor is the ~108k fixed overhead
`doc/compacting-investigation.md` measured.

## Configuration

`userConfig`: `enabled` (kill switch), `loop_prefixes` (comma-separated, default `/auto`), `min_context_percent` (below
it a boundary is logged, not compacted; default 0), `ledger`.

## Ledger

`<checkout>/tmp/loop-boundary-<sessionId>.jsonl`, where the checkout is the one that owns the session root — a linked worktree
resolves to its main checkout, so a session resumed inside one keeps writing where `fleet-metrics.py` reads (the three
2026-10-10 fleet sessions, resumed at 14:22Z, split their ledgers into the worktrees until this resolution):

```json
{"ts":"...","session":"...","event":"boundary","accepted":true,"outcome":"SHIPPED-MERGE: BF-1","tokensBefore":480210,"tokensAfter":112340,"path":"turn-complete","nearClear":true,"turnId":"...","loopPrompt":"/auto"}
{"ts":"...","session":"...","event":"pass","reason":"no-outcome","turnId":"...","loopPrompt":"/auto"}
```

`tokensBefore` is the context of the last request before the boundary; `tokensAfter` is the context of the next
iteration's first request, filled in when it answers (null until then, and on a session that ends first). The retro
reads it: `fleet-metrics.py` reports a **Boundary compactions** line and `boundary_compactions` in its JSON.

## Loading

Installed user-wide by `update.sh` from the repo's marketplace and loaded in place from this folder; `fleet-launch.sh`
and `fleet-sequence.sh` refuse to dispatch where it is not enabled (`scripts/mod-enabled.sh loop-boundary`), since they
no longer add an `--autocompact` cap. `claude --plugin-dir ~/.claude/mods/loop-boundary` loads it for one session on a
machine without the install.

## Checks

```bash
claude plugin validate mods/loop-boundary && claude plugin test mods/loop-boundary && mods/typecheck.sh mods/loop-boundary
```
