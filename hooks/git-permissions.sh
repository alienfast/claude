#!/bin/bash
# Git Destructive Command Permissions Hook
# Prevents Claude from running destructive git commands without explicit user approval
#
# This hook protects against:
# - Accidental data loss from git reset/restore/clean/checkout
# - Conflicts between multiple Claude sessions working simultaneously
# - Claude making assumptions about which files to discard
#
# Triggered: Pre-Tool hook for Bash commands
# Blocks: Destructive git commands that can permanently delete work
#
# Scope: this hook sees only the Bash tool's command string. A destructive git command run from
# inside a script file, or with git displaced from command position (`bash -c`, `env git`), is
# invisible to it. It is a backstop for direct top-level invocation, not a guarantee —
# standards/git.md "The hook only sees the Bash tool's command string".

# Read the tool input from stdin (current Claude Code hook format).
INPUT=$(cat)

# Fail CLOSED on a payload we cannot parse. Previously a missing/broken jq (or any non-JSON stdin)
# produced an empty COMMAND, which then failed the ^git test and allowed EVERY git command through
# silently — the one failure mode a safety hook must not have.
if ! command -v jq >/dev/null 2>&1; then
  echo "🛑 BLOCKED: git-permissions hook cannot run — 'jq' not found on PATH. Refusing to allow git commands unchecked." >&2
  exit 2
fi
if ! COMMAND=$(printf '%s' "$INPUT" | jq -er '.tool_input.command // ""' 2>/dev/null); then
  echo "🛑 BLOCKED: git-permissions hook could not parse the tool payload. Refusing to allow git commands unchecked." >&2
  exit 2
fi

deny() {
  printf '%s\n' "$1" >&2
  exit 2
}

# Heredoc BODIES are data, not commands. `git commit -F - <<'EOF' ... EOF` legitimately carries prose
# describing git commands — a commit message for this very hook did, and the segment scan below read
# its lines as invocations and blocked the commit. Drop each body before scanning; the `<<` line
# itself stays, so the real command is still inspected.
scan=$(printf '%s' "$COMMAND" | awk '
  { if (skip) { if ($0 == term || $0 == "\t" term) skip = 0; next } }
  { line = $0
    if (match(line, /<<-?[[:space:]]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
      t = substr(line, RSTART, RLENGTH)
      gsub(/^<<-?[[:space:]]*|[\047"]/, "", t)
      term = t; skip = 1
    }
    print line }
')

# Quoted text is normally DATA too — a `grep "git reset --hard" skills/` search must not trip this.
# But under an executor the quoted text IS the code, and stripping it would be a trivial bypass.
# Same rule as linear-create-state-guard.sh and no-blind-sleep.sh.
# Leading space so one [[:space:]] branch covers start-of-string: `^` inside an ERE alternation
# group is not an anchor, so `(^|[[:space:]])` silently never matched a command-initial executor.
executor_probe=" $scan"
if ! [[ "$executor_probe" =~ [[:space:]](ba|z|k)?sh[[:space:]]+-[A-Za-z]*c([[:space:]]|$) || "$executor_probe" =~ [[:space:]](eval|xargs)([[:space:]]|$) ]]; then
  scan=$(printf '%s' "$scan" | sed -E "s/'[^']*'/ /g; s/\"[^\"]*\"/ /g")
fi

# Evaluate EVERY command in the string, not just the leading one. All rules below anchor on ^git,
# so a compound like `git status && git reset --hard`, a leading space, or a second line used to
# bypass the hook entirely — the first word of the whole string was all it ever inspected.
normalized=${scan//&&/$'\n'}
normalized=${normalized//||/$'\n'}
normalized=${normalized//;/$'\n'}
normalized=${normalized//|/$'\n'}

while IFS= read -r segment; do
  # Trim leading/trailing whitespace — ` git reset --hard` bypassed the ^git anchor.
  segment="${segment#"${segment%%[![:space:]]*}"}"
  segment="${segment%"${segment##*[![:space:]]}"}"

  [[ "$segment" =~ ^git[[:space:]] ]] || continue

  # ---- Force flags. Checked BEFORE the safe-subcommand allowlist: `git branch --force` and
  # ---- `git add --force` used to short-circuit into the allowlist and skip this test entirely.
  if [[ "$segment" =~ (^|[[:space:]])--force(-with-lease)?([[:space:]]|=|$) ]]; then
    deny "🛑 BLOCKED: Git command with --force flag requires explicit user approval

Command: $segment

The --force flag overrides safety checks and can cause data loss or
destructive changes to your repository.

To proceed: Explicitly tell Claude \"yes, use --force\""
  fi

  # Short-form -f (including bundled forms like -fd) on the subcommands where it is destructive.
  # Scoped deliberately: a blanket -f would catch harmless flags on read-only subcommands.
  if [[ "$segment" =~ ^git[[:space:]]+(push|branch|checkout|switch|clean|worktree|tag|gc)([[:space:]]|$) ]] &&
     [[ "$segment" =~ (^|[[:space:]])-[a-eg-zA-Z]*f[a-zA-Z]*([[:space:]]|$) ]]; then
    deny "🛑 BLOCKED: Git command with a short-form force flag (-f) requires explicit user approval

Command: $segment

-f is the same override as --force. It was previously NOT caught, so
'git push -f' and 'git branch -f' ran unguarded.

To proceed: Explicitly tell Claude \"yes, use -f\""
  fi

  # Force-push by refspec: `git push origin +main` is a force push with no flag at all.
  if [[ "$segment" =~ ^git[[:space:]]+push([[:space:]]|$) ]] &&
     [[ "$segment" =~ [[:space:]]\+[A-Za-z0-9_/.^~-]+ ]]; then
    deny "🛑 BLOCKED: Force-push by refspec requires explicit user approval

Command: $segment

A leading '+' on a refspec forces the update exactly as --force does.

To proceed: Explicitly tell Claude \"yes, force-push this refspec\""
  fi

  # Destructive branch operations. `git branch` is otherwise allowlisted below.
  if [[ "$segment" =~ ^git[[:space:]]+branch[[:space:]] ]] &&
     [[ "$segment" =~ (^|[[:space:]])-[a-zA-Z]*[DM]([a-zA-Z]*)?([[:space:]]|$) ]]; then
    deny "🛑 BLOCKED: Destructive branch operation requires explicit user approval

Command: $segment

-D force-deletes a branch and -M force-renames over an existing one. In a
checkout shared by concurrent sessions this mutates state every session sees.

To proceed: Explicitly tell Claude \"yes, run this git branch command\""
  fi

  # ---- Safe read-only and staging commands.
  if [[ "$segment" =~ ^git[[:space:]]+(status|log|diff|show|branch|add|commit|reflog)([[:space:]]|$) ]]; then
    continue
  fi

  # Allow git restore --staged (only unstaging, not discarding changes)
  if [[ "$segment" =~ ^git[[:space:]]+restore[[:space:]]+--staged ]]; then
    continue
  fi

  # Allow read-only stash inspection
  if [[ "$segment" =~ ^git[[:space:]]+stash[[:space:]]+(list|show) ]]; then
    continue
  fi

  # BLOCK: any other git stash form (bare stash, push, save, pop, apply, drop, clear, branch)
  # The stash stack lives in the COMMON git dir, so every worktree of a repo shares ONE stack.
  if [[ "$segment" =~ ^git[[:space:]]+stash([[:space:]]|$) ]]; then
    deny "🛑 BLOCKED: git stash mutates a stack shared across every worktree of this repo

Command: $segment

The stash stack lives in the common git dir — every worktree pushes onto and
pops off ONE shared stack. A concurrent session's push between your push and
your pop makes 'pop' apply THEIR diff into your tree and delete their entry.

To undo a temporary edit, copy the file aside and copy it back (file copy),
per standards/git.md \"Working Tree Protection\". 'git stash list' and
'git stash show' remain allowed.

To proceed: Explicitly tell Claude \"yes, run this git stash command\""
  fi

  # BLOCK: git reset in any mode except --soft. Matching the spelled-out --hard/--mixed left bare
  # `git reset` and `git reset HEAD~1` allowed — both are --mixed, git's default, with exactly the
  # impact the blocked spelling has.
  if [[ "$segment" =~ ^git[[:space:]]+reset([[:space:]]|$) ]] && [[ ! "$segment" =~ (^|[[:space:]])--soft([[:space:]]|$) ]]; then
    deny "🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $segment

git reset discards staged changes (--mixed, the default) or destroys the
working tree outright (--hard). This cannot be undone.

⚠️  CRITICAL: Multiple Claude sessions may be working simultaneously.
    This command could destroy work from other sessions or your own uncommitted changes.

'git reset --soft' (moves HEAD only, keeps index and tree) remains allowed.

To proceed: Explicitly tell Claude \"yes, run this git reset command\"
            (Only do this if you are absolutely certain!)"
  fi

  # BLOCK: git restore <files> (destroys working tree changes for specific files)
  # Allow ONLY: git restore --staged
  if [[ "$segment" =~ ^git[[:space:]]+restore[[:space:]] ]] && [[ ! "$segment" =~ --staged ]]; then
    deny "🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $segment

This command will PERMANENTLY DELETE uncommitted changes to the specified files.
This cannot be undone - the changes will be lost forever.

⚠️  CRITICAL: Another Claude session or you may be working on these files.
    Running this command will destroy that work.

To proceed: Explicitly tell Claude \"yes, run this git restore command\"
            (Only do this if you are absolutely certain these changes should be discarded!)"
  fi

  # BLOCK: git checkout with any non-flag argument. The old rule required a space-delimited '--',
  # so it caught `git checkout -- foo.ts` and missed the bare `git checkout foo.ts` that people
  # actually type — the form that destroys the file. A bare branch name is caught by the same
  # test, and deliberately: `git checkout` is overloaded, and nothing lexical separates a branch
  # from a path (`main` and `foo.ts` are both bare words). A filesystem probe cannot settle it
  # either — this hook's cwd is not reliably the repo, so an operand that "does not exist" may
  # simply be a path in a directory we are not standing in, and guessing wrong destroys the file.
  # `git switch <branch>` is the un-overloaded spelling and is allowed; it takes no pathspec, so
  # it cannot reach the destructive mode at all. Point the caller there instead of at an approval
  # phrase nothing reads: deny() is exit 2, a hard block with no approve path.
  # Flag-only forms stay allowed: --detach (recommended by /full, /auto-prep, /start), -b, -B.
  if [[ "$segment" =~ ^git[[:space:]]+checkout([[:space:]]|$) ]]; then
    args="${segment#*checkout}"
    # -b/-B create a branch: the operand following it is the new branch name (and an optional
    # start point), never a path, so the non-flag scan below must not see them.
    if [[ "$args" =~ (^|[[:space:]])-[bB]([[:space:]]|$) ]] && [[ ! "$args" =~ [[:space:]]--([[:space:]]|$) ]]; then
      continue
    fi
    if [[ "$args" =~ (^|[[:space:]])[^-[:space:]] ]] || [[ "$args" =~ [[:space:]]--([[:space:]]|$) ]]; then
      deny "🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $segment

'git checkout <file>' PERMANENTLY DELETES uncommitted changes to that file,
and 'git checkout' cannot tell a file from a branch without guessing.

➡️  To CHANGE BRANCH, use 'git switch <branch>' — it takes no pathspec, so it
    cannot reach the destructive mode. That form is allowed.
⚠️  To RESTORE a file, copy it aside and back, or 'git show HEAD:<path> >| <path>'.

Flag-only forms (--detach, -b, -B) remain allowed.

This is a hard block: no phrase you say to Claude will lift it. Run it yourself
if you genuinely mean the file form."
    fi
  fi

  # `git switch` is deliberately NOT blocked. It was, mirroring checkout — but the two are not
  # equivalent: checkout is overloaded (branch OR pathspec) while switch is branch-only and has no
  # pathspec form at all, so it cannot destroy an uncommitted file. What remains is the
  # shared-working-tree concern from standards/git.md, and git already fails that case closed —
  # it refuses to switch when the move would overwrite local changes. Blocking it bought no safety
  # over `git checkout`'s own block and left branch-switching with no allowed spelling, which is
  # how the block message above came to promise an approval phrase that nothing honors.

  # BLOCK: git clean with a real force flag. The old substring match on -[fd] also caught
  # '--dry-run' (the '-d' inside it), blocking the one form that is a safe preview, while
  # '-n' passed. Preview forms are now explicitly allowed.
  if [[ "$segment" =~ ^git[[:space:]]+clean([[:space:]]|$) ]] &&
     [[ ! "$segment" =~ (^|[[:space:]])(-n|--dry-run)([[:space:]]|$) ]] &&
     [[ "$segment" =~ (^|[[:space:]])-[a-eg-zA-Z]*f[a-zA-Z]*([[:space:]]|$) ]]; then
    deny "🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $segment

This command will PERMANENTLY DELETE untracked files from your working tree.
This cannot be undone.

⚠️  CRITICAL: This may delete files created by other Claude sessions or by you.

Preview first with 'git clean -n' / 'git clean --dry-run' (both allowed).

To proceed: Explicitly tell Claude \"yes, run git clean\""
  fi
done <<< "$normalized"

# Allow other git commands (push, pull, fetch, etc.)
exit 0
