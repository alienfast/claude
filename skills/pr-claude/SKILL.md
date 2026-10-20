---
name: pr-claude
description: |
  Send uncommitted edits under a project's .claude/ (skills, rules, agents) to GitHub as a pull request from a checkout
  parked on the default branch, no git knowledge needed; also resumes a pending submission and tidies up after a merge.
  Use when the user says 'submit my changes', 'share my skill changes', 'make a PR for my Claude changes', or invokes
  /pr-claude. Not for application code (Linear), a branch with commits (/pr-update), or ~/.claude itself (/keeper).
---

# pr-claude

For someone who improved a skill with Claude's help and wants it shared, without learning git. The model to hold onto, and to explain when asked: **edited files under `.claude/` are unsent changes; submitting sends them and puts the shared version back.** The change returns for good once it is merged and `/update` runs.

**Invoking `/pr-claude` is the explicit grant to push one submission branch and open its PR** — the skill-scoped grant shape of `~/.claude/standards/git.md` § Named exceptions. It never pushes the default branch, never force-pushes, and never touches a file outside `.claude/`.

All git work is done by [scripts/pr-claude.sh](scripts/pr-claude.sh); its header explains why it is plumbing-only and why it restores the working files at the end. Never reproduce its steps by hand — a branch switch or a hand-rolled `git checkout --` is exactly what it exists to avoid.

```bash
~/.claude/skills/pr-claude/scripts/pr-claude.sh survey
~/.claude/skills/pr-claude/scripts/pr-claude.sh submit --slug <kebab> --title "<title>" --body-file tmp/pr-claude/<slug>.md [--onto <branch>]
~/.claude/skills/pr-claude/scripts/pr-claude.sh resume <branch>
~/.claude/skills/pr-claude/scripts/pr-claude.sh settle
```

## Step 1 — Survey

Run `survey` and read its lines:

- `REFUSED: …` (exit 1) — a precondition failed: not on the default branch, unpushed commits, a linked worktree, GitHub unreachable. Say what it means in plain words and stop. None of these is something to work around.
- `landed <path>` — an earlier submission was merged and the same edits are still sitting here. Run `settle` first, tell the user their earlier change is now part of the shared version, then survey again.
- `outside <path>` — files outside `.claude/` are modified. Stop: those are not Claude configuration, and they keep the checkout from updating. Offer to show what changed; application changes are described in Linear, not submitted from here.
- `changed <path>` — what would be submitted. None means there is nothing to send.
- `open-pr` / `open-pr-file` — the user's submissions still waiting for review, and the files each touches.

## Step 2 — Confirm with the user

Describe the changed files in plain language, grouped by skill ("the bond calculator's pricing script and its instructions"), and ask whether that is everything they meant to send. A file they did not expect is a reason to stop and look, not to submit. To send only part, pass the paths after `--`.

## Step 3 — Check the change

**These local checks are the only gate: the pull request skips CI**, since nothing under `.claude/` is built, tested, or deployed by it. A red check stops the submission; offer to help fix it.

1. For each touched skill, read its `SKILL.md`. When it names a regression or verify command (a `verify.py`, a
   `*.test.sh`), run it.
2. The project's lint for config files: its Biome check for JSON under `.claude/`, and its markdown check (plus anchor
   gate, where the project has one) when a changed `.md` is linted there. Read the project's `package.json` scripts for
   the names; `pnpm check` is the house default.
3. For a changed `*.sh`: `/bin/bash -n <script>`, then actually run it; nothing automated covers shell
   ([rules/bash.md](../../rules/bash.md)).

## Step 4 — Describe it

Choose a short kebab-case slug, and a title that names the outcome in plain words ("Bond calculator: support call-date scenarios") — the script appends the CI-skip token itself. Write the body to `tmp/pr-claude/<slug>.md`:

```markdown
## Summary

<Two or three plain sentences: what was wrong or missing, and what changes for the person using it.>

## What changed

- <one bullet per file or behavior, in outcome terms>

## How it was checked

- <each check from Step 3 and its result, with the numbers — "35/35 regression checks pass">
```

Do not title a section `Executive Summary`: that heading feeds the release-notes post, and a `.claude/` change is not a product release. Every claim in the body must be true of the files being sent.

## Step 5 — New submission, or more for a pending one

When an `open-pr` from the survey touches the same files, this is almost certainly a revision: pass `--onto <that branch>` so it lands as a new commit on the same pull request. Ask only when it is genuinely unclear. Otherwise omit `--onto` and a new branch `<github-login>/claude-<slug>` is created.

## Step 6 — Submit and report

| Exit | Meaning | What to tell the user |
|---|---|---|
| 0 | `PR <url>`, then `RESTORED n file(s)` | The link. Their change is waiting for review, this checkout is running the shared version again, and the change comes back for good after it is merged and they run `/update`. To keep working on it meanwhile: "keep working on my submitted change". |
| 0 with `NOT-RESTORED` | Files changed while it ran | The change was sent, and the working files were left alone. Survey again. |
| 0 with `MERGED-WITH-BASE` | The shared version had moved | Nothing to do — the edits merged cleanly onto the newer version. Mention it in one line. |
| 2 | `CONFLICT` | Someone changed the same lines on GitHub. Nothing was sent and nothing here was touched. This needs an engineer; do not try to resolve it here. |
| 4 | `PUSHED-NO-PR` | The edits are safe on GitHub but the pull request did not open. Rerun the identical `submit` — it picks up where it stopped. |
| 1 | `REFUSED: …` | The reason, in plain words. |

The `RESCUE` line names a patch of the edits kept under `tmp/pr-claude/` — a local copy in case anything about the round trip is ever in doubt.

## Keep working on a submitted change

`resume <branch>` puts a pending submission's edits back into the working files so they can be changed further; submit again with `--onto <branch>` when done. Until then the checkout is dirty again and `/update` will skip the project pull — say so, since that is the cost of resuming.

## After a merge

Normally nothing: the checkout is already clean, and `/update` brings the merged change in. `settle` exists for the case where a submission was resumed and then merged — it restores every `.claude/` file whose edits are already on the default branch, which loses nothing, then pulls.
