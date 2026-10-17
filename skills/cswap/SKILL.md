---
name: cswap
description: Multi-account rotation through claude-swap (cswap) on a machine that runs several Claude subscriptions. `quota` (default) shows every account's 5-hour, weekly and Fable usage in one table with the age of each figure, then only the conditions that need action; `log` says what the auto-switch engine did last and why it is holding; `next` shows the move it would make right now, as a dry run; `setup` points at scripts/cswap-setup.sh or re-applies its policy flags. Needs cswap on this machine — on a single-account machine it says so and stops. Use when the user says 'cswap', 'cswap quota', 'usage across my accounts', 'which account am I on', 'why hasn't cswap switched', 'what would cswap do', or invokes /cswap.
---

# cswap

Claude Code shows only the account it is logged in as. On a machine that rotates accounts, `cswap list --json` asks each
managed account for its own figures, and the auto-switch engine's log says what it decided. This skill reads both and
presents them; it never computes a figure itself and never shows one from memory.

Context: [README § Multi-account rotation](../../README.md#multi-account-rotation-optional). The policy the setup script
applies (`consume-first`, threshold 95) and why is in the header of [cswap-setup.sh](../../scripts/cswap-setup.sh).

## Preflight

```bash
command -v cswap >/dev/null 2>&1 || ls "$HOME/.local/bin/cswap" >/dev/null 2>&1
```

Missing → say so in one line — this machine does not rotate accounts; `~/.claude/scripts/cswap-setup.sh` is the opt-in —
and stop. Never substitute a table built from `/usage`, the rate-limits snapshot, or memory. When `cswap` is only under
`~/.local/bin`, prefix every command below with `PATH="$HOME/.local/bin:$PATH"`.

Verbs: `quota` (default when no argument or `/cswap` alone), `log`, `next`, `setup`. Anything else → list the four.

## quota

One read. `// "-"` marks a figure the read did not carry; show it as absent, never as zero. `willLastToReset` is tested
for null explicitly because jq's `//` also swallows `false`, the value that matters.

```bash
cswap list --json | jq -r '
  .accounts[] | [
    .number, .email, (if .active then "active" else "" end), .usageStatus,
    (.usage.fiveHour.pct // "-"), (.usage.fiveHour.countdown // "-"),
    (.usage.sevenDay.pct // "-"), (.usage.sevenDay.clock // "-"),
    (.usage.sevenDay.willLastToReset | if . == null then "-" else . end),
    ((.usage.scoped // []) | map(select(.name == "Fable")) | (.[0].pct // "-")),
    ((.usage.spend.used // "-") | tostring) + " / " + ((.usage.spend.limit // "-") | tostring),
    (.loginExpiresAt // "-"),
    (.usageFetchedAt // "-"),
    (.usageAgeSeconds | if . == null then "-" else (. / 60 | floor) end)
  ] | @tsv'
cswap config get autoswitch.threshold
date -u
```

`usageStatus: ok` does not mean current. After the usage endpoint answers 429, cswap keeps serving an account's last
good figure as `ok` for up to two hours — right for the switcher, wrong for a person reading the table — so the last
two columns (when the figure was read, and its age in minutes) are what say whether a row is current.

Present one table, one row per account: account, active, 5h % and time to reset, weekly % and reset time, Fable weekly
%, extra-usage spend against its cap, login expiry, age in minutes. A row older than 15 minutes shows its usage cells
as OUT OF DATE, never as current values, and no condition below is judged from it (a healthy row refreshes within about
10 minutes). A 5h "time to reset" of `-` on a 0% account means no window is open — the window starts on first use —
and is said that way, not left as a dash. Reset clocks are local time.

Under the table, one line per condition that holds, and "nothing needs action" when none does:

- figures older than 15 minutes: that account's usage is unknown since the time shown. When it is the active account,
  the engine is deciding on the same stale figure and the account can reach its limit without a switch.
- `usageStatus` `unavailable`: cswap stopped trusting the last figure after refused refreshes; no login is needed.
- any other `usageStatus` but `ok`: `claude auth login` as that account, then `cswap add`.
- a weekly or Fable window at or above the threshold that resets within 48 hours: its remaining percent expires unused
  unless the user moves to it by hand (`cswap switch <n>`) — the engine only lands on accounts under the threshold.
- `willLastToReset` false: on pace to run out before its reset.
- extra-usage spend at 80% of its cap or more: billed beyond the plan.
- `loginExpiresAt` within 3 days: `claude auth login` as that account before it lapses.

## log

What the engine did and why it is holding, from the agent's event stream (`cswap auto --json`, one line per event):

```bash
LOG="$HOME/.claude/logs/cswap-auto.log"
launchctl print "gui/$(id -u)/com.alienfast.cswap-auto" 2>/dev/null | grep -E '^\s*(state|pid) ' || echo "agent: not loaded"
grep '"event": "switch"' "$LOG" | tail -n 3
grep -v '"event": "poll"' "$LOG" | tail -n 1
tail -n 1 "$LOG"
```

Present: whether the agent is running; the last switches as `when, from → to, trigger`; the latest non-poll event with
its `reason` and `detail`, translated — `cooldown` is the 5-minute hold after any switch; `below-threshold` under
`best`, and `already-consuming-soonest` under `consume-first`, mean the active account is the right one; `reset-unknown`
means the active account's weekly reset is not reported yet, so `consume-first` is idle; `no-qualifying-candidate` and
`no-viable-target` mean nothing under the threshold beats the active account; `all-exhausted` carries the earliest reset.
A missing log means the agent was never installed here: point at `setup`. A `wrapper-error` line names what is wrong.
With a number (`log 20`), show that many non-poll events instead of the last one.

## next

```bash
cswap auto --once --dry-run --json 2>&1 | tail -n 3; echo "exit=$?"
```

Dry run decides and never switches. Exit 0: it would switch now — name from, to and trigger from the `switch` line.
Exit 2: nothing to do, the active account is the one to drain. Exit 3: blocked — no candidate under the threshold, or
every account at its limit; quote the `reason`. Exit 1: an error; quote it. Nothing else — one tick, no loop.

## setup

Enrollment needs a terminal: each further account is a browser login (`claude auth login`) followed by `cswap add`, and
a session has no TTY for that, so never run the script bare from here. Print the command and what it will do:

```text
~/.claude/scripts/cswap-setup.sh      # in a terminal: installs the pinned cswap, enrolls accounts, applies the policy, loads the agent
```

Re-applying the policy without enrollment is safe from a session, when the user asks for a different threshold or
strategy (the flags are validated; the running engine restarts on the new values):

```bash
~/.claude/scripts/cswap-setup.sh --no-enroll --threshold 95 --strategy consume-first
```

Removal and the agent's manual commands are in the setup script's header (`cswap-setup.sh --help`).

## Rules

- Figures come from the read in the same turn. Quote cswap's own error when a read fails; a table from memory is never
  a substitute.
- Never run `cswap switch` or `cswap auto` (without `--dry-run`) on the user's behalf unless they ask for that move by
  name; the engine owns the login.
- Emails are the user's own accounts: show them in full in the table.
