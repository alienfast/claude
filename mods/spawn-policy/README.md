# spawn-policy

A hooks-only mod on `agent.spawn` that applies the review tiers mechanically instead of by prose, and logs each decision.

## Rules

| Rule | Condition | Rewrite |
|---|---|---|
| model | The spawn's `subagentType` has a configured model and the call's `model` is unset or does not carry it (`sonnet` is satisfied by `claude-sonnet-5-5`) | `model` set to the configured alias |
| sync | `run_in_background` is true on a main-loop spawn of quality-reviewer, quality-verifier or developer | `background` set to false |

Forks, teammates and Workflow-started agents are left alone: the engine ignores `model` on the first two and every change
on the third. An unset `model` is never compliant, because the agent definition's own pin then decides, and `developer.md`
pins opus.

`enforce` decides whether a rule rewrites or only logs: `auto` rewrites once the `auto` skill has expanded in the session
or when the spawn's permission mode is `auto`, and logs a `would rewrite` line elsewhere; `always` and `never` do what they
say.

## Configuration

`userConfig`: `enforce`, `developer_model` (sonnet), `verifier_model` (sonnet), `reviewer_model` (opus),
`sync_review_dispatch` (true), `ledger` (true).

## Ledger

`<session root>/tmp/spawn-policy-<sessionId>.jsonl`, one row per spawn a rule fired on:

```json
{"ts":"...","session":"...","type":"developer","description":"fix batch 2","modelIn":null,"modelOut":"sonnet","backgroundIn":true,"backgroundOut":false,"rules":["model:developer->sonnet","sync:developer"],"enforced":true,"parentAgentId":null,"resolvedModel":"claude-sonnet-5-5"}
```

## Loading and checks

Installed user-wide by `update.sh` and loaded in place from this folder; `claude --plugin-dir ~/.claude/mods/spawn-policy`
loads it for one session on a machine without the install. The retro reads the ledger as a **Spawn policy** line and
`spawn_policy` in `fleet-metrics.py`'s JSON.

```bash
claude plugin validate mods/spawn-policy && claude plugin test mods/spawn-policy && mods/typecheck.sh mods/spawn-policy
```
