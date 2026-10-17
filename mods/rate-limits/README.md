# rate-limits

A hooks-only mod that writes the account's rate-limit windows, and which account they belong to, to
`~/.claude/local/rate-limits.json` on every measurement, so `scripts/fleet-launch.sh` can print the active account's burst
(`five_hour`) and weekly (`seven_day`) readings before it dispatches, and `scripts/fleet-headroom.sh` can park a fleet session
on the same meter. Nothing at launch reported weekly use before it: the 2026-10-10 fleet (3 sessions, 12h) was launched on an
account 5.75h from its weekly limit and lost 18.75 of its 36 session-hours. On a machine that rotates accounts it also pins the
active account and its windows under the prompt.

## What it writes

`session.measure` fires after each main-thread turn and whenever a window moves a whole point. When its `rateLimits`
carries a reading the whole file is rewritten — last writer wins, so the file names whichever account the latest session
on this machine ran on, and `measured_at` dates it. A measurement with no windows (off a subscription, or before the first
response) writes nothing, so an empty reading never overwrites a dated one.

`account` is the live login's email as Claude Code records it in `~/.claude.json` (`$CLAUDE_CONFIG_DIR/.claude.json` in a
`cswap run` profile), the file cswap rewrites on every switch. It is read at session start and again whenever the reading's
weekly reset moves — a switch, or the week rolling over — since that reset is stable within one account's week and differs
between accounts; a steady-state turn costs no file read. Absent when the file is missing or carries no login.

```json
{
  "measured_at": "2026-10-10T20:15:03.000Z",
  "session": "8c16860d-d02b-4364-af52-2d5a27d9dd9c",
  "account": "claude-bfp@drinkto.me",
  "windows": [
    { "kind": "five_hour", "percentUsed": 12.5, "resetsAt": "2026-10-11T00:00:00.000Z" },
    { "kind": "seven_day", "percentUsed": 71, "resetsAt": "2026-10-13T22:00:00.000Z" }
  ]
}
```

`~/.claude/local/` is the directory `~/.claude/CLAUDE.md` reserves for machine-local state kept across sessions; the write
creates it. The home directory comes from `HOME`, or `USERPROFILE` where only that is set.

Each session also keeps a history, `~/.claude/local/rate-limits/<session-id>.jsonl`, one line per measurement in which a
window moved (`{"measured_at", "account", "windows"}`, the same windows as above) and one for every login that moved under
the session, carrying the account left as `switched_from` — the moment cswap's auto-switch landed on a running session, dated
from the session's own traffic. The snapshot cannot say how full the 5-hour window got while a fleet ran — the 2026-10-12
retro had only a reading from two days earlier to estimate headroom from — and one file per session means concurrent sessions
never race a shared file. `scripts/fleet-metrics.py` reads a fleet's files for each session's peak `five_hour` reading, and
`scripts/fleet-headroom.sh --session <id>` reads a session's last line as its account's current 5h reading at pick time (the
account it is on, switch or no switch), falling back to the snapshot. Both read `windows` and ignore the other keys. A reload
resumes the session's file rather than starting it over. Nothing prunes these files (the mod API has no delete); each holds at
most a few hundred short lines.

## Status line on a rotating machine

Where cswap's backup directory exists (`~/.claude-swap-backup`, or `$XDG_DATA_HOME/claude-swap` on Linux) the mod pins
`⇄ <account> · 5h <pct>% · 7d <pct>%` under the prompt through `$.ui.status`, updated on every measurement, so the account a
session is on is visible while the engine moves the login underneath it. Everywhere else it pins nothing. This is deliberately
not a `statusLine` command in the shared settings: configuring one removes the footer's keyboard hints for every user of this
repo, rotating or not, and a command that prints nothing still does that.

## Measured, 2026-10-10

A headless `claude -p --plugin-dir ~/.claude/mods/rate-limits --model haiku` run on a subscription account wrote the file
on its one turn, carrying both windows: `five_hour` at 28% resetting in 3.5h and `seven_day` at 7% resetting Oct 13
22:00Z, the same reset the morning's weekly-limit message had named. The file did not exist before the run. Not yet
measured: a cswap switch landing on a running interactive session — the `switched_from` line is what records it when it does.

## Configuration

`userConfig`: `enabled` (kill switch: writes nothing, pins nothing), `status` (the pin alone; off still records the account).

## Loading

Installed user-wide by `update.sh` from the repo's marketplace and loaded in place from this folder. `fleet-launch.sh` never
requires it: without a reading it prints `Weekly: no reading (<why>)` and launches.

## Checks

```bash
claude plugin validate mods/rate-limits && claude plugin test mods/rate-limits && mods/typecheck.sh mods/rate-limits
```
