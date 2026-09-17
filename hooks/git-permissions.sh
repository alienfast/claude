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
# No globbing: switch_verdict word-splits an argument list, and a `*` operand must not expand against the hook's cwd.
set -f

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
  # A placeholder, not a blank: `git -C "$REPO" reset --hard` must keep its -C argument slot, or the
  # global-option peel below eats `reset` as the path and the subcommand anchors see nothing.
  scan=$(printf '%s' "$scan" | sed -E "s/'[^']*'/ Q /g; s/\"[^\"]*\"/ Q /g")
fi

# Evaluate EVERY command in the string, not just the leading one. All rules below anchor on ^git,
# so a compound like `git status && git reset --hard`, a leading space, or a second line used to
# bypass the hook entirely — the first word of the whole string was all it ever inspected.
normalized=${scan//&&/$'\n'}
normalized=${normalized//||/$'\n'}
normalized=${normalized//;/$'\n'}
normalized=${normalized//|/$'\n'}

# ---- Context for the two conditional rules below (a plain branch switch; a stash on a single-checkout repo). The git
# ---- probes inside these helpers run only when such a rule reaches them, so every other Bash call pays nothing.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
# A cd/pushd anywhere in the command could have moved git off the payload cwd — then the directory is unknowable here.
if [[ "$normalized" =~ (^|[[:space:]])(cd|pushd)([[:space:]]|$) ]]; then CWD_MOVED=1; else CWD_MOVED=0; fi

# The directory the current segment's git runs in; rc 1 when it cannot be known — an unresolvable -C (quoted, so already
# the Q placeholder, or carrying a $VAR), --git-dir/--work-tree, a cd in the command, or a payload with no cwd. Unknown
# fails closed: the conditional rules deny and say so.
repo_dir() {
  case "$seg_dir" in
    "?") return 1 ;;
    "")  [ -n "$CWD" ] && [ "$CWD_MOVED" = 0 ] && printf '%s' "$CWD" && return 0; return 1 ;;
    /*|[A-Za-z]:*) printf '%s' "$seg_dir"; return 0 ;;
    *)   [ -n "$CWD" ] && [ "$CWD_MOVED" = 0 ] && printf '%s/%s' "$CWD" "$seg_dir" && return 0; return 1 ;;
  esac
}
tree_clean() { # <dir> — no uncommitted change to a TRACKED file (untracked files survive a switch untouched)
  local out; out=$(git -C "$1" status --porcelain --untracked-files=no 2>&1) || return 1; [ -z "$out" ]
}
branch_exists() { # <dir> <name> — a local branch, or origin/<name> (git then creates the tracking branch: a creation, not a move)
  git -C "$1" rev-parse --verify -q "refs/heads/$2" >/dev/null 2>&1 || git -C "$1" rev-parse --verify -q "refs/remotes/origin/$2" >/dev/null 2>&1
}
main_checkout_of() { # <dir> — the main checkout: the fleet markers live in ITS tmp/, whichever worktree the cwd is in
  local c; c=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  dirname "$c"
}
# rc 0 and a reason when a fleet is running out of this checkout; rc 1 when none is. Only the explicit fleet-deadline
# marker counts: an /auto ledger's mtime says nothing about liveness (the heartbeat never touches it, and a killed
# loop leaves it "active"), and a lone loop — or a /fleet-sequence, whose runner steers each session with a per-issue
# start.<id>.wt-source-branch key and never parks the checkout — keeps its work in worktrees and merges by ref, so a
# main-checkout switch does not move its tree. The clean-tree condition is what protects a same-checkout session's edits.
automation_live() { # <dir>
  local main m dl now
  main=$(main_checkout_of "$1") || { echo "the main checkout of $1 cannot be resolved"; return 0; }
  m="$main/tmp/fleet-deadline.json"
  if [ -s "$m" ] && [ "$(jq -r '.stopped // false' "$m" 2>/dev/null)" != "true" ]; then
    dl=$(jq -r '.deadline_epoch // empty' "$m" 2>/dev/null); now=$(date +%s)
    if ! [[ "$dl" =~ ^[0-9]+$ ]] || [ "$dl" -gt "$now" ]; then
      echo "a fleet is running out of $main (tmp/fleet-deadline.json; /fleet-stop ends it)"; return 0
    fi
  fi
  return 1
}
linked_worktrees() { # <dir> — how many worktrees besides the main checkout
  local n; n=$(git -C "$1" worktree list --porcelain 2>/dev/null | grep -c '^worktree ') || true
  echo $(( ${n:-0} > 0 ? n - 1 : 0 ))
}
# A plain branch switch is allowed only when every condition holds; the first that fails is echoed as the reason.
switch_verdict() { # <args after checkout/switch>
  local w target="" dir why
  for w in $1; do
    case "$w" in
      -q|--quiet|--progress|--no-progress|--guess|--no-guess|-t|--track|--no-track) ;;
      --) echo "the '--' path form"; return 1 ;;
      -)  echo "the previous-branch shorthand '-' (spell the branch name)"; return 1 ;;
      -*) echo "flag '$w' is outside the plain-switch set (-q, --progress, --guess, --track)"; return 1 ;;
      *)  if [ -z "$target" ]; then target=$w; else echo "more than one operand"; return 1; fi ;;
    esac
  done
  [ -n "$target" ] || { echo "no branch operand"; return 1; }
  [[ "$target" =~ ^[A-Za-z0-9_][A-Za-z0-9_./-]*$ ]] || { echo "'$target' is not a plain branch name"; return 1; }
  dir=$(repo_dir) || { echo "the directory git would run in cannot be determined (a quoted or \$VAR -C path, a cd in the command, or no cwd in the payload)"; return 1; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$dir is not inside a git checkout"; return 1; }
  branch_exists "$dir" "$target" || { echo "'$target' is not an existing branch (local or origin/)"; return 1; }
  tree_clean "$dir" || { echo "the working tree has uncommitted changes to tracked files"; return 1; }
  why=$(automation_live "$dir") && { echo "$why"; return 1; }
  return 0
}
# A stash mutation is a hazard only with a second party on the shared stack: a linked worktree, or a running fleet.
stash_verdict() {
  local dir why n
  dir=$(repo_dir) || { echo "the directory git would run in cannot be determined (a quoted or \$VAR -C path, a cd in the command, or no cwd in the payload)"; return 1; }
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "$dir is not inside a git checkout"; return 1; }
  n=$(linked_worktrees "$dir"); [ "$n" = 0 ] || { echo "this repo has $n linked worktree(s) sharing the stash stack"; return 1; }
  why=$(automation_live "$dir") && { echo "$why"; return 1; }
  return 0
}

while IFS= read -r segment; do
  # Trim leading/trailing whitespace — ` git reset --hard` bypassed the ^git anchor.
  segment="${segment#"${segment%%[![:space:]]*}"}"
  segment="${segment%"${segment##*[![:space:]]}"}"

  [[ "$segment" =~ ^git[[:space:]] ]] || continue

  # Peel git's global options: every rule below anchors on `^git <subcommand>`, so `-C <path>` (the
  # form standards/git.md prescribes in worktree sessions), `-c k=v`, `--git-dir`, `--work-tree` and
  # the flag-only globals hid the subcommand from all of them. Measured 2026-09-09: a runaway heredoc
  # ran `git -C "$REPO" reset -q --hard; git -C "$REPO" clean -qfd; git -C "$REPO" branch -q -D ...`
  # against ~/.claude itself, and none of the three was blocked.
  # -C is also RECORDED (seg_dir) for the conditional rules: a literal path resolves; a quoted one is the Q placeholder by
  # now and a $VAR cannot be resolved here, so either marks the directory unknowable ("?"), as do --git-dir/--work-tree.
  seg_dir=""
  while [[ "$segment" =~ ^git[[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace|--exec-path|--super-prefix)(=[^[:space:]]*|[[:space:]]+[^[:space:]]+)[[:space:]]+(.*)$ ]]; do
    opt="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]#=}"; val="${val#"${val%%[![:space:]]*}"}"
    case "$opt" in
      -C) if [ "$val" = Q ] || [[ "$val" == *'$'* ]] || [ -n "$seg_dir" ]; then seg_dir="?"; else seg_dir="$val"; fi ;;
      --git-dir|--work-tree) seg_dir="?" ;;
    esac
    segment="git ${BASH_REMATCH[3]}"
  done
  while [[ "$segment" =~ ^git[[:space:]]+(--no-pager|-p|--paginate|-P|--bare|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks)[[:space:]]+(.*)$ ]]; do
    segment="git ${BASH_REMATCH[2]}"
  done

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

  # git stash: list/show are read-only. drop, clear and branch are denied always (entries destroyed, or the tree moved).
  # push/pop/apply and the bare form mutate a stack every worktree of the repo shares, so they are allowed only when
  # nobody else can be on it: no linked worktrees and no fleet running out of this checkout (stash_verdict).
  if [[ "$segment" =~ ^git[[:space:]]+stash([[:space:]]|$) ]]; then
    sargs="${segment#*stash}"
    if [[ "$sargs" =~ ^[[:space:]]+(list|show)([[:space:]]|$) ]]; then
      continue
    fi
    if [[ "$sargs" =~ ^[[:space:]]+(drop|clear|branch)([[:space:]]|$) ]]; then
      sub="${BASH_REMATCH[1]}"
      deny "🛑 BLOCKED: 'git stash $sub' requires explicit user approval

Command: $segment

drop and clear delete stash entries permanently; branch applies one onto a
new branch and moves the working tree.

To proceed: Explicitly tell Claude \"yes, run this git stash command\""
    fi
    why=$(stash_verdict) && continue
    deny "🛑 BLOCKED: git stash mutates a stack shared across every worktree of this repo

Command: $segment
Why:     $why

The stash stack lives in the common git dir — every worktree pushes onto and
pops off ONE shared stack. A concurrent session's push between your push and
your pop makes 'pop' apply THEIR diff into your tree and delete their entry.

push/pop/apply ARE allowed when the repo has no linked worktrees and no fleet
is running out of it. Otherwise, to undo a temporary edit, copy the file aside
and copy it back (standards/git.md \"Working Tree Protection\"). 'git stash
list' and 'git stash show' are always allowed.

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

  # git checkout: a PATH operand destroys that file's uncommitted changes and a BRANCH operand moves the shared working
  # tree, so any non-flag operand is denied — unless it is a plain branch switch on a checkout with nothing to lose: an
  # existing branch, a clean tracked tree, a resolvable directory, no fleet running out of it (switch_verdict). Blocking
  # every branch operand outright left a one-person machine with no in-session way to `git checkout main` at all.
  # -b creates and stays allowed; --detach is flag-only and stays allowed (/full, /auto-prep and /start recommend it).
  # -B is denied outright: it resets an EXISTING branch to the start point and moves the tree onto it — `branch -f` plus
  # a switch in one word — and it was the one branch-moving form the old flag-only allowance let through.
  if [[ "$segment" =~ ^git[[:space:]]+checkout([[:space:]]|$) ]]; then
    args="${segment#*checkout}"
    if [[ "$args" =~ (^|[[:space:]])-B([[:space:]]|$) ]]; then
      deny "🛑 BLOCKED: 'git checkout -B' resets an existing branch and moves the working tree onto it

Command: $segment

-B is 'git branch -f' plus a switch: whatever the branch pointed at is dropped
from it, and the SHARED working tree moves. Use -b for a new branch, or a plain
'git checkout <branch>' on a clean tree to switch.

To proceed: Explicitly tell Claude \"yes, run this git checkout -B command\""
    fi
    if [[ "$args" =~ (^|[[:space:]])-b([[:space:]]|$) ]] && [[ ! "$args" =~ [[:space:]]--([[:space:]]|$) ]]; then
      continue
    fi
    # A lone `-` is the previous-branch shorthand — an operand that moves the tree, not a flag, though it reads as one.
    if [[ "$args" =~ (^|[[:space:]])[^-[:space:]] ]] || [[ "$args" =~ [[:space:]]--?([[:space:]]|$) ]]; then
      why=$(switch_verdict "$args") && continue
      deny "🛑 BLOCKED: git checkout with an operand requires explicit user approval

Command: $segment
Why:     $why

'git checkout <file>' PERMANENTLY DELETES uncommitted changes to that file.
'git checkout <branch>' moves the SHARED working tree and can carry another
session's WIP onto the target branch.

A plain switch IS allowed when the operand is an existing branch (local or
origin/), the tracked tree is clean, the directory is resolvable (no quoted or
\$VAR -C path, no cd in the command), and no fleet is running out of it.
To restore a file, copy it aside and back, or 'git show HEAD:<path> >| <path>'.
Flag-only forms (--detach, -b) stay allowed.

To proceed: Explicitly tell Claude \"yes, run this git checkout command\""
    fi
  fi

  # git switch mirrors checkout — without it, `git switch main` is a one-word detour around the same protection. -c
  # creates and stays allowed, --detach is flag-only and stays allowed, -C is denied like checkout -B, and a plain
  # branch operand goes through switch_verdict.
  if [[ "$segment" =~ ^git[[:space:]]+switch([[:space:]]|$) ]]; then
    sargs="${segment#*switch}"
    if [[ "$sargs" =~ (^|[[:space:]])-C([[:space:]]|$) ]]; then
      deny "🛑 BLOCKED: 'git switch -C' resets an existing branch and moves the working tree onto it

Command: $segment

-C is 'git branch -f' plus a switch. Use -c for a new branch, or a plain
'git switch <branch>' on a clean tree to switch.

To proceed: Explicitly tell Claude \"yes, run this git switch -C command\""
    fi
    if [[ "$sargs" =~ (^|[[:space:]])-c([[:space:]]|$) ]]; then
      continue
    fi
    if [[ "$sargs" =~ (^|[[:space:]])[^-[:space:]] ]] || [[ "$sargs" =~ [[:space:]]-([[:space:]]|$) ]]; then
      why=$(switch_verdict "$sargs") && continue
      deny "🛑 BLOCKED: git switch with an operand requires explicit user approval

Command: $segment
Why:     $why

'git switch <branch>' moves the SHARED working tree and can carry another
session's uncommitted work onto the target branch — the same hazard as
'git checkout <branch>'.

A plain switch IS allowed when the operand is an existing branch (local or
origin/), the tracked tree is clean, the directory is resolvable (no quoted or
\$VAR -C path, no cd in the command), and no fleet is running out of it.
Flag-only forms (--detach, -c) stay allowed.

To proceed: Explicitly tell Claude \"yes, run this git switch command\""
    fi
  fi

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
