# Unattended-run prerequisites

Read from `/auto` when launching or recovering an unattended run. The running model can change none of these; whoever
launches the session sets them (`/fleet-launch`, `/fleet-sequence`, or a human typing `claude`).

## Model and effort

- Launch with `--model 'opus[1m]' --effort xhigh` and no `--autocompact`. `[1m]` gives one oversized issue headroom.
- Never `opusplan`: it means "Opus in plan mode, Sonnet otherwise", and `/full auto` dispatches `/start auto`, which
  skips `EnterPlanMode`, so the Opus branch never fires and the whole run executes on Sonnet.
- Fable (`--model fable`) is the alternative for unusually large issues (better long-horizon retention). It runs safety
  classifiers that can return `stop_reason: "refusal"`, which reaches Step 4 as an unrecognized-tag failure and counts
  against the circuit breaker.

## Context across iterations

Cross-iteration accumulation is the dominant cost of a looping session: cache reads scale with context. The
`loop-boundary` mod (`mods/loop-boundary/README.md`, installed by `update.sh`) compacts the conversation to one
boundary message when a looping session's turn ends with one of this skill's outcome lines, so every iteration starts
at the session floor; cross-iteration state lives in `tmp/auto-state-<runKey>.json` and Linear, so nothing is lost.
`fleet-launch.sh` and `fleet-sequence.sh` refuse to dispatch where the mod is not enabled
(`scripts/mod-enabled.sh loop-boundary`).

Growth inside an iteration is handled by the harness's own summarization at its threshold. `/compact` and `/clear` are
user commands — never attempt them. Never stop, summarize, or propose a new session on account of context limits.

## Permissions

- Interactive sessions (a watched terminal or editor): auto-accept edits or `--permission-mode acceptEdits` suffice —
  someone can answer the occasional Bash prompt.
- Background sessions (`claude --bg`, `/fleet-launch`): `--permission-mode auto`. `acceptEdits` only auto-accepts file
  edits, so the first gated Bash command (`/start wt`'s worktree validation) stalls the session at a prompt nobody can
  see, before its first pick.
- `/fewer-permission-prompts` seeds a project allowlist first.
- A permission prompt mid-run breaks nothing: the run pauses until answered and `/loop` resumes normally. Expect them
  on milestones that touch unusual commands.

## Recovering a halted deep session

Never resume a deep fleet session; recover its in-flight issue in a fresh targeted `/auto <ISSUE-ID>` session.

1. Stop the halted session in `claude agents` first. A session the harness halted (an autocompact thrash leaves it
   `blocked`, not dead) still reads `alive`, so the targeted run's create gate would refuse its worktree.
2. Run `~/.claude/scripts/wt-owner.sh <worktree>`. `dead` or `released` needs nothing more — the targeted run adopts
   the worktree, uncommitted work included.
3. `alive` or `unknown` means the probe found no job dir: a stop keeps the dir with a terminal `stopped` state, so this
   is a session that was deleted (`claude rm`, or delete in the `claude agents` view), and the stamp's pid — the
   shared daemon, or blank — is all that is left to read. Release it with
   `~/.claude/scripts/wt-disown.sh --force <worktree>`, which is correct only because you just stopped the owner. The
   targeted run never forces on its own.
