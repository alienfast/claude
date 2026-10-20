# Step 0 failure paths: the live-owner refusal and the non-`VERIFIED` verdicts

Read from `/start` Step 0 sub-step 1 when `start-wt-setup.sh` exits non-zero, and from sub-step 3 when
`start-wt-verify.sh` returns anything other than `VERIFIED`. Every auto-mode exit below is a bare tagged final line
([standards/lifecycle-tags.md](../../../standards/lifecycle-tags.md)).

## `start-wt-setup.sh` exited non-zero

The worktree is in an indeterminate state and the locked helper has already cleaned up via its EXIT trap: surface the
script's stderr and stop. One failure has its own mapping.

**`owned by another live session`** is the locked create's parallel-session refusal — normally a live sibling actively
working this issue's worktree (a `/next` pick race, or an orphan-resume of work that is not orphaned). The worktree was
NOT touched (the reuse path never arms the cleanup trap) and nothing was claimed. Probe the issue for the `stalled`
label — `linear-cli issues get <ISSUE-ID> -o json | jq -r '.labels.nodes[].name' | grep -qix stalled`; a probe failure
(auth, network) counts as label-absent, never block on it — then:

- **Label absent** (a live sibling really owns it). Auto mode: emit
  `SKIPPED-BLOCKED: <ISSUE-ID> — worktree owned by a live parallel session; nothing claimed. No state change.` and stop —
  `/auto` records a skip, not a failure. Interactive: surface it and suggest waiting for that session or picking
  different work.
- **Label present.** `/auto` releases ownership (`wt-disown.sh`) when it applies `stalled`, so a stamp still reading
  alive under the label is a stale claim or a failed best-effort release; the one live possibility is a resumer
  mid-claim, which removes the label at Step 3 moments after claiming. Interactive: state both facts and ask once —
  force-release and take over, or leave it; on yes run `~/.claude/scripts/wt-disown.sh --force <wt-abs>` and re-run
  sub-step 1's setup script (its reuse path re-stamps ownership to this session; Step 3 removes the label). Auto mode:
  never force — emit `SKIPPED-BLOCKED: <ISSUE-ID> — stamp claims a live owner but the issue is labeled stalled (likely a
  stale claim); run /start <ISSUE-ID> interactively to force-release it. Nothing claimed.` and stop. The label lives in
  Linear and the stamp in git; no lock spans them, so a human confirmation is the right gate for the mid-claim race.

## `start-wt-verify.sh` verdicts other than `VERIFIED`

The verdict is the first (only) line of stdout; the script's header docblock has the full contract. Each `FAILED-*`
line is mirrored to stderr as well, so a merged capture carries it twice — take the last match.

- **`FAILED-CWD`** → the `EnterWorktree` registration did not take (sub-step 2's STOP-and-surface). Never fall back to a
  shell `cd`. Auto: `BLOCKED-ON-REVIEW: <ISSUE-ID> — EnterWorktree registration did not take (cwd mismatch); manual
  investigation required. No state change.`
- **`FAILED-CLAIM`** → the update command itself failed (auth expired, network, unknown state name) — distinct from
  Step 3's availability decisions, which were made before the script ran. STOP and surface; never proceed unclaimed.
  Auto: `BLOCKED-ON-REVIEW: <ISSUE-ID> — claim update failed (linear-cli error). No state change.` **One exception, a
  transient Linear 5xx:** when stderr shows `HTTP 5xx` / `Service Unavailable` / a timeout (not auth expiry, a
  permissions error, or an unknown state name), the claim failed on Linear's infrastructure. Probe once
  (`linear-cli issues get <ISSUE-ID>`); if the probe succeeds, re-run the identical invocation and continue on
  `VERIFIED`. One retry — if it fails again, take the stop above.
- **`FAILED-SOURCE-BRANCH`** → sub-step 1 recorded the value this session, so an empty probe is a possible
  hijack/corruption signal: STOP and surface; do NOT continue to implementation. Auto: `BLOCKED-ON-REVIEW: <ISSUE-ID> —
  start.source-branch missing from worktree config (possible parallel-session interference); manual investigation
  required.` The claim has already run (or the issue was already claimed, on the `--no-claim` path), so this line
  carries no "No state change" clause.
- **`FAILED-CHECK`** → Step 5's baseline-failure path: STOP, delegate the fix (`developer` / `debugger`, carrying Step 8's
  isolation blocks), re-run until clean; auto mode bounds this to two fix delegations, then posts the baseline failure
  as a Linear comment, returns the issue per `early-exit.md` § ABANDONED, and emits Step 5's `BLOCKED-ON-REVIEW` line.
- **Anything else** — `FAILED-USAGE` (a malformed invocation), no verdict line at all, or empty stdout — is a FAILED
  check: fail closed, STOP; never read unrecognized or missing output as success. Auto: `BLOCKED-ON-REVIEW: <ISSUE-ID> —
  start-wt-verify.sh returned no recognizable verdict (<first output line, or 'empty stdout'>); fail closed, manual
  investigation required.` This can fire before or after the claim stage ran, or with the claim skipped on the
  `--no-claim` path, so it carries no "No state change" clause; on the `--claim` path Linear state is indeterminate until
  a human checks.
