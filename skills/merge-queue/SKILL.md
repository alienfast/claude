---
name: merge-queue
description: Inspect and drain the local deferred-merge queue. Shows worktree merges that /finish deferred (transient block — e.g. the main checkout was on the source branch with WIP) and that a local launchd drainer retries until they land. Use when the user says 'merge queue', 'what merges are pending', 'drain the merge queue', or invokes /merge-queue.
---

# Merge Queue

A `/finish … merge` (or `/full … wt`) that can't advance the source branch *right now* but
could later — the transcript case where the main checkout sat on the source branch with another
session's uncommitted WIP — is **deferred**, not failed. [scripts/finish-merge.sh](../../scripts/finish-merge.sh)
exits `3`, self-enqueues a marker under `<repo>/.claude/merge-queue/<issue>.json`, and emits the
`DEFERRED-MERGE` lifecycle tag. A local launchd drainer
([scripts/drain-merge-queue.sh](../../scripts/drain-merge-queue.sh) → `merge-queue.sh drain`)
retries every ~15 min until each merge lands. This skill is the manual window into that queue.

All logic lives in [scripts/merge-queue.sh](../../scripts/merge-queue.sh); this skill only
dispatches to it and narrates the result.

## Arguments

`/merge-queue [list | drain | <ISSUE-ID>]`

- **(none)** or `list` — show the queue.
- `drain` — run a drain pass now across all registered repos (don't wait for launchd).
- `<ISSUE-ID>` (e.g. `PL-361`) — drain **just that one issue** now (its repo is resolved automatically from the registry), then report its status. Other queued issues in the same repo are not touched.

## Behavior

### `list` (default)

Run and show the output verbatim:

```bash
~/.claude/scripts/merge-queue.sh list
```

Each row is `ISSUE | REPO | AGE(min) | TRIES | STATUS / REASON`. Interpret the status for the user:

- **queued** — transient block; the drainer will keep retrying. No action needed.
- **NEEDS-RESOLUTION** — the deferred merge hit a real conflict. It needs a human: resolve it
  (see below), the drainer cannot.
- **HARD-FAIL** — a hard precondition failed (worktree removed, source branch gone, etc.). Inspect;
  the marker won't clear on its own.

If the queue is empty, say so and stop. (`list` reads the repos in
`~/.claude/merge-queue-repos.txt`, which a repo self-registers on its first deferral — so an
"empty" result for a repo that never deferred is expected, not a lost marker.)

### `drain` / `<ISSUE-ID>`

Run a drain pass (the script serializes against the launchd drainer via a per-repo lock, so this
is always safe to run):

```bash
~/.claude/scripts/merge-queue.sh drain               # all registered repos
~/.claude/scripts/merge-queue.sh drain '<ISSUE-ID>'  # just that one issue (repo auto-resolved from the registry)
~/.claude/scripts/merge-queue.sh drain '<repo-root>' # one whole repo's queue
```

The drainer prints one line per marker: `DRAINED` (merged, marker removed), `STILL-BLOCKED`
(transient, will retry), `NEEDS-RESOLUTION` (conflict — needs you), or `HARD-FAIL`. Surface those
lines and summarize.

### Resolving a `NEEDS-RESOLUTION` entry (conflict)

The drainer deliberately never resolves conflicts unattended — that would land code on a shared
branch without review. Resolve it in a normal session, exactly like
[/finish](../finish/SKILL.md) Step 9's exit-2 path:

1. Read the marker for the worktree path: `jq . '<repo>/.claude/merge-queue/<issue-lower>.json'`.
   The worktree is mid-merge of the source branch.
2. For each conflicted file under `<wt_dir>`, resolve both sides.
3. `git -C '<wt_dir>' add <resolved-files>`
4. Run `pnpm check` from `<wt_dir>` — must be green before committing.
5. `git -C '<wt_dir>' commit -F '<wt_dir>/tmp/git-merge-msg-<issue-lower>.md'`
6. Re-drain that issue: `~/.claude/scripts/merge-queue.sh drain '<ISSUE-ID>'`. On success the marker
   is removed and the worktree torn down.

## Installing the drainer

The queue is inert without the launchd agent loaded. **`~/.claude/update.sh` installs and
refreshes it automatically** (it renders the plist template for the current `$HOME` and bootstraps
it idempotently — macOS only), so a normal `update.sh` run is all that's needed. To (re)install by
hand without a full update (see the plist header for the exact commands):

```bash
sed "s|__HOME__|$HOME|g" ~/.claude/launchd/com.alienfast.merge-queue-drain.plist \
  > ~/Library/LaunchAgents/com.alienfast.merge-queue-drain.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.alienfast.merge-queue-drain.plist
```

To remove: `launchctl bootout gui/$(id -u)/com.alienfast.merge-queue-drain`.

Drainer activity is logged to `~/.claude/logs/merge-queue-drain.log`. Notifications fire (macOS
desktop) only for `NEEDS-RESOLUTION` / `HARD-FAIL` / long-stuck entries — never for routine retries.
