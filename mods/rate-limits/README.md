# rate-limits

A hooks-only mod that writes the account's rate-limit windows to `~/.claude/local/rate-limits.json` on every
measurement, so `scripts/fleet-launch.sh` can print the active account's weekly (`seven_day`) reading beside the headroom
ceiling before it dispatches. Nothing at launch reported weekly use before it: the 2026-10-10 fleet (3 sessions, 12h) was
launched on an account 5.75h from its weekly limit and lost 18.75 of its 36 session-hours.

## What it writes

`session.measure` fires after each main-thread turn and whenever a window moves a whole point. When its `rateLimits`
carries a reading the whole file is rewritten — last writer wins, so the file names whichever account the latest session
on this machine ran on, and `measured_at` dates it. A measurement with no windows (off a subscription, or before the first
response) writes nothing, so an empty reading never overwrites a dated one.

```json
{
  "measured_at": "2026-10-10T20:15:03.000Z",
  "session": "8c16860d-d02b-4364-af52-2d5a27d9dd9c",
  "windows": [
    { "kind": "five_hour", "percentUsed": 12.5, "resetsAt": "2026-10-11T00:00:00.000Z" },
    { "kind": "seven_day", "percentUsed": 71, "resetsAt": "2026-10-13T22:00:00.000Z" }
  ]
}
```

`~/.claude/local/` is the directory `~/.claude/CLAUDE.md` reserves for machine-local state kept across sessions; the write
creates it. The home directory comes from `HOME`, or `USERPROFILE` where only that is set.

## Measured, 2026-10-10

A headless `claude -p --plugin-dir ~/.claude/mods/rate-limits --model haiku` run on a subscription account wrote the file
on its one turn, carrying both windows: `five_hour` at 28% resetting in 3.5h and `seven_day` at 7% resetting Oct 13
22:00Z, the same reset the morning's weekly-limit message had named. The file did not exist before the run. Not yet
measured: that the reading follows an account switch — the next session on the other account rewrites the file, and
`measured_at` should move with it.

## Configuration

`userConfig`: `enabled` (kill switch).

## Loading

Installed user-wide by `update.sh` from the repo's marketplace and loaded in place from this folder. `fleet-launch.sh` never
requires it: without a reading it prints `Weekly: no reading (<why>)` and launches.

## Checks

```bash
claude plugin validate mods/rate-limits && claude plugin test mods/rate-limits && mods/typecheck.sh mods/rate-limits
```
