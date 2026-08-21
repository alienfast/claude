---
name: update
description: Bring this machine current — pull the latest project code and ~/.claude, then run the update script (the project's .claude/update.sh when it has one, ~/.claude/update.sh directly when it doesn't) to update Claude Code, skills, and the CLI tools. A start-of-day habit, and the first thing to try when a tool is missing or a skill behaves like an older version. Use when the user says 'update', 'update my setup', 'pull the latest', 'bring me up to date', or invokes /update.
---

# Update

One command that leaves the machine current: latest project code, latest agent configuration, latest tools.

This is the routine the setup guides hand to non-engineers, so **narrate it in plain language** and never leave the user
guessing whether it worked. It is also safe for engineers mid-work — the branch rules below are what make that true.

Run it at the start of the day, and any time something behaves like it is out of date: a skill that has changed, a command
that is not found, a tool that fails on a version mismatch.

## Step 1 — Pull the project

Establish where you are before touching anything:

```bash
git status --porcelain
git branch --show-current
git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||'
```

The third one is the default branch. It prints `origin/main`, hence the `sed` — comparing the raw output against
`branch --show-current` never matches. It fails when `origin/HEAD` was never set (some clones, and every worktree cut
before it existed); `git remote set-head origin --auto` repairs it.

Then apply these rules in order. **Never** stash, reset, checkout a different branch, or discard anything — another
session may own the working tree (`standards/git.md` § Multi-Session Awareness), and for a non-engineer a dirty tree
usually means something was edited by accident and needs a human's eyes, not a silent cleanup.

- **Clean tree, on the default branch** → `git pull --ff-only`. Report what came in (`N commits`, or "already current").
- **Dirty tree** → skip the pull. Say plainly which files are modified, and that you left them alone. For a business
  user, add: *"these are local edits — if you didn't mean to make them, tell me and I'll show you what changed."*
- **On a branch other than the default** → skip the pull and say so in one line: this is someone's in-progress work, and
  merging the default branch into it is a deliberate act belonging to `/start`, not a routine update.

A skipped project pull is not a failure. Continue to Step 2 regardless — that is the half that matters most.

## Step 2 — Run the update script

From the repo root, prefer the project's own script when it has one:

```bash
bash .claude/update.sh
```

That script pulls `~/.claude`, runs the global `~/.claude/update.sh` — Claude Code itself, the plugin marketplaces, the
skills, `gh` / `jq` / `linear-cli`, the launchd agents — and finishes with any project-specific work (usually a lint
pass).

**A project without `.claude/update.sh` is normal, not a failure — the global script must still run.** But the global
script does not pull `~/.claude` itself; the project script is what does that, and skipping the pull would update the
tools while leaving every skill and rule stale. So do the pull the project script would have done, then run the global
script directly, and say that's the path you took:

```bash
git -C ~/.claude pull --ff-only
bash ~/.claude/update.sh
```

When the project *is* `~/.claude`, Step 1 already handled the pull — go straight to the script.

The script's sign-in steps (`gh auth login`, the Linear browser OAuth) are TTY-gated, and run from this tool there is no
TTY — so it never stops to prompt. It prints a ⚠️ with the exact command and keeps going, which means **a run can end
with `Done!` and still need the user**. Treat `Done!` as the end of the script, not proof of success: collect every ⚠️
from the output, hand the user the exact commands to run in their own terminal, and re-run the script after they
confirm, until the auth checks print `✓`. Platform-gap warnings (a missing prebuilt binary, an unsupported
`claude update`) are report-only — name them and move on rather than looping on them.

Three failure shapes are worth naming rather than retrying blindly. `/update` detects and routes; the recovery itself
belongs to `/keeper`, never to this skill — do not commit, stash, reset, or discard anything here.

- **`~/.claude` is not a git repo, or has the wrong origin** — the script refuses and prints the fix. Set it up as a
  checkout of `https://github.com/alienfast/claude` in place; never delete the directory.
- **Uncommitted changes in `~/.claude`** — the pull will refuse rather than clobber them. What they mean depends on the
  machine (`git -C ~/.claude config --get reflect.keeper`): on the keeper's machine (`true`) they are usually
  `/reflect`'s auto-applied edits awaiting review — point at `/keeper`. On any other machine they are local drift that
  can never be committed from here — point at `/keeper` too: its contributor mode folds what has global value into a
  proposal PR and restores the files, and tells the user what to undo by hand for the rest.
- **Local commits on `~/.claude` main** (the `--ff-only` pull refuses, or `git -C ~/.claude log --oneline
  origin/main..HEAD` is non-empty) — on a non-keeper machine these can never be pushed and only accumulate conflicts.
  Point at `/keeper`: contributor mode carries them onto a proposal branch, opens the PR, and — with the user's
  in-session consent — resets main back to a pure clone, leaving a rescue branch behind.

## Step 3 — Report

Three lines, no more:

1. What the project pull did — commits pulled, already current, or skipped and why.
2. Whether the update script finished (`Done!`) and whether any ⚠️ in its output still needs the user — with the exact
   command if so.
3. **Restart VS Code.** The script says this and it is easy to skip: new skills and configuration are read at startup, so
   until the restart the session is still running the old ones.

If anything needs a person — an auth prompt they have to answer, a dirty tree, a keeper batch — put it at the top of the
report rather than the bottom.
