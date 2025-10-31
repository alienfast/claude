#!/bin/bash
# Git Destructive Command Permissions Hook
# Prevents Claude from running destructive git commands without explicit user approval
#
# This hook protects against:
# - Accidental data loss from git reset/restore/clean
# - Conflicts between multiple Claude sessions working simultaneously
# - Claude making assumptions about which files to discard
#
# Triggered: Pre-Tool hook for Bash commands
# Blocks: Destructive git commands that can permanently delete work

# Get the command that Claude is about to execute
COMMAND="$1"

# Skip if not a git command
if [[ ! "$COMMAND" =~ ^git[[:space:]] ]]; then
  exit 0
fi

# Allow safe read-only and staging commands
if [[ "$COMMAND" =~ ^git[[:space:]]+(status|log|diff|show|branch|add|commit|stash|reflog) ]]; then
  exit 0
fi

# Allow git restore --staged (only unstaging, not discarding changes)
if [[ "$COMMAND" =~ ^git[[:space:]]+restore[[:space:]]+--staged ]]; then
  exit 0
fi

# BLOCK: git reset --hard (destroys all working tree and staged changes)
if [[ "$COMMAND" =~ ^git[[:space:]]+reset[[:space:]]+--hard ]]; then
  cat <<EOF
🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $COMMAND

This command will PERMANENTLY DELETE all uncommitted changes in your working
tree and staging area. This cannot be undone.

⚠️  CRITICAL: Multiple Claude sessions may be working simultaneously.
    This command could destroy work from other sessions or your own uncommitted changes.

To proceed: Explicitly tell Claude "yes, run git reset --hard"
            (Only do this if you are absolutely certain!)
EOF
  exit 1
fi

# BLOCK: git reset --mixed (destroys staged changes, keeps working tree)
if [[ "$COMMAND" =~ ^git[[:space:]]+reset[[:space:]]+--mixed ]]; then
  cat <<EOF
🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $COMMAND

This command will unstage all changes. While it preserves your working tree,
it may interfere with other Claude sessions' staged changes.

To proceed: Explicitly tell Claude "yes, run git reset --mixed"
EOF
  exit 1
fi

# BLOCK: git restore <files> (destroys working tree changes for specific files)
# Allow ONLY: git restore --staged
if [[ "$COMMAND" =~ ^git[[:space:]]+restore[[:space:]] ]] && [[ ! "$COMMAND" =~ --staged ]]; then
  cat <<EOF
🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $COMMAND

This command will PERMANENTLY DELETE uncommitted changes to the specified files.
This cannot be undone - the changes will be lost forever.

⚠️  CRITICAL: Another Claude session or you may be working on these files.
    Running this command will destroy that work.

To proceed: Explicitly tell Claude "yes, run this git restore command"
            (Only do this if you are absolutely certain these changes should be discarded!)
EOF
  exit 1
fi

# BLOCK: git checkout <files> (old way to restore files)
if [[ "$COMMAND" =~ ^git[[:space:]]+checkout[[:space:]] ]] && [[ "$COMMAND" =~ [[:space:]]--[[:space:]] ]]; then
  cat <<EOF
🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $COMMAND

This command will PERMANENTLY DELETE uncommitted changes to the specified files.

⚠️  Use 'git restore <file>' instead (also requires approval).

To proceed: Explicitly tell Claude "yes, run this git checkout command"
EOF
  exit 1
fi

# BLOCK: git clean -f or -fd (deletes untracked files)
if [[ "$COMMAND" =~ ^git[[:space:]]+clean[[:space:]].*-[fd] ]]; then
  cat <<EOF
🛑 BLOCKED: Destructive git command requires explicit user approval

Command: $COMMAND

This command will PERMANENTLY DELETE untracked files from your working tree.
This cannot be undone.

⚠️  CRITICAL: This may delete files created by other Claude sessions or by you.

To proceed: Explicitly tell Claude "yes, run git clean"
EOF
  exit 1
fi

# BLOCK: Any git command with --force flag
if [[ "$COMMAND" =~ --force ]]; then
  cat <<EOF
🛑 BLOCKED: Git command with --force flag requires explicit user approval

Command: $COMMAND

The --force flag overrides safety checks and can cause data loss or
destructive changes to your repository.

To proceed: Explicitly tell Claude "yes, use --force"
EOF
  exit 1
fi

# Allow other git commands (push, pull, fetch, etc.)
# Note: git push --force is already blocked above
exit 0
