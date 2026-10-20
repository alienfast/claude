---
name: epic-pr
description: Open the one PR for an epic's integration branch after an epic-scoped fleet or sequence has landed its members — resolves the epic, branch, base and landed roster from what /epic-prep and /fleet-launch recorded, pushes the branch, opens the PR, then runs /pr-update on it. Invoking it is the grant to push that branch. Use when the user says 'epic pr', 'open the epic PR', or invokes /epic-pr.
argument-hint: "[EPIC-ID]"
---

# Epic PR

The closing step of the epic fleet workflow: `/epic-prep` → `/fleet-launch` → `/fleet-status` → **`/epic-pr`** → merge
(the project's `/pr-merge` where it has one). Everything `integration-pr.sh` needs — the branch, its base, the member
roster — was recorded by the prep and the launch or is readable from Linear and git, so nothing is typed by hand. The
resolver is [scripts/epic-pr.sh](../../scripts/epic-pr.sh); this skill dispatches to it, asks the one or two questions it
cannot answer, and narrates.

**Invoking `/epic-pr` is the grant to push the epic's integration branch and open its PR** (`standards/git.md` § Named
exceptions). It never merges the PR, never moves the checkout, and never writes to Linear.

## Arguments

`/epic-pr [EPIC-ID]` — the id is optional. Without it the resolver reads, in order: the checkout's branch when it is
`epic/<id>`, the fleet marker's `scope` ([`/fleet-launch`](../fleet-launch/SKILL.md) § The deadline contract), the
recommendation's `scope` (`tmp/fleet-recommendation.json`), then the one local `epic/*` branch. Several such branches, or
none, is the one case it asks.

## Workflow

### Step 1: Resolve, without pushing

```bash
~/.claude/scripts/epic-pr.sh --dry-run [EPIC-ID]
```

Read the key=value output. On **exit 3** the resolver needs a choice:

- `ASK=epic` — AskUserQuestion naming the `CANDIDATES=` branches (each as `epic/<id>`), or asking for the epic id when
  there are none; re-run with the answer as the argument.
- `ASK=base` — the branch has no recorded base and the checkout sits on the integration branch itself. AskUserQuestion
  with the likely bases (the repo's default branch, any long-running branch the epic belongs to); re-run with
  `--base <branch>`.

On exit 1 relay the error and stop — a missing local branch means the epic was never prepped (`/epic-prep <ID>` creates
it).

### Step 2: Confirm what the PR will carry

Show the plan from the dry run: the epic and where its id came from (`EPIC_SOURCE`), the branch, the base and where it
came from (`BASE_SOURCE`), the roster in landing order (`LANDED`), and anything left out. Then decide whether to ask:

- `NOT_LANDED` non-empty — members whose code is not on the branch. The PR carries only what landed; say which members
  stay open and confirm with one AskUserQuestion that a partial PR is wanted. A fleet that ended on its deadline
  routinely leaves some.
- `LANDED` empty — nothing to ship; stop with that finding rather than opening an empty PR.
- `BASE_SOURCE` is `checkout` or `config` rather than a recorded value — the base is derived from where the checkout
  happens to sit; confirm it in the same question.
- `SKIPPED` — Canceled or Duplicate members and nested epic containers, listed for the record; nothing to confirm.

When the base and the roster are both recorded or complete, no question: proceed.

### Step 3: Push and open

```bash
~/.claude/scripts/epic-pr.sh [--base <branch>] [EPIC-ID]
```

The resolver hands its answers to `integration-pr.sh`, which pushes the branch, finds or creates the open PR onto the
base with a roster body (every ID bare, never behind a close keyword), and prints `PR_URL`, `PR_NUMBER`, `CREATED`, and
`BEHIND` — the commits the base gained that the branch lacks, which is one catch-up merge before it can merge.

### Step 4: Write the real description

Invoke `/pr-update <PR_NUMBER>` — by number, so it edits the PR without touching the checkout — to replace the roster
body with a title and description read from the diff.

### Step 5: Report

The PR URL; whether it was created or already existed; the roster it carries; the members left open; the catch-up merge
if `BEHIND` is non-zero; and the next step once CI is green: the project's `/pr-merge <PR_NUMBER>` where it has one,
otherwise the merge on GitHub.

## What this skill must NOT do

- Never merge the PR — that is the project's `/pr-merge`, or a human on GitHub.
- Never switch, reset or detach the main checkout; the branch is pushed by ref.
- Never move an issue in Linear; the members are already Ready For Release from their own merges, and the PR body
  deliberately carries no close keywords.
- Never open a PR for a branch with no landed member.

## Error Handling

- Not in a git repo, `gh` or `jq` missing → the script errors before writing anything; relay it.
- `ERROR: no local branch` → the epic was not prepped on this checkout: `/epic-prep <ID>` first.
- A push or PR-create failure → `integration-pr.sh` exits 1 with the reason; nothing is retried. Re-running is safe: an
  existing open PR is found rather than duplicated.
- `/pr-update` failing after the PR exists → the PR stands with its roster body; re-run `/pr-update <number>` alone.
