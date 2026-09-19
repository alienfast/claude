#!/usr/bin/env bash
# auto-push-main.sh — push the main checkout's default branch to origin when the project has opted in, fast-forward only.
#
# WHY: /finish's worktree-merge mode never pushes the source branch (its Step 7 — keeper ruling 2026-08-16), so origin
# lags Linear until a human pushes, and an unattended fleet cannot wait for one. On the 2026-09-18 BFP fleet the only
# pickable candidate was the contract half of an expand/contract migration, gated on its expand reaching PRODUCTION —
# which deploys from origin/main. Local main sat 16 commits ahead for the run's whole 12 hours and was pushed 21 minutes
# after the deadline. All three sessions named the push correctly and none could make it; the fleet shipped nothing in
# its last 24.8 of 36 session-hours, this gate and a stage gate withholding the rest of the pool between them.
#
# The ruling that replaced the deadlock (keeper, 2026-09-19): a project may grant the push, and /auto exercises it
# LAZILY. main still batches — every push is a CI build, and that cost is why merges batch — and a session pushes at
# exactly two moments: a deploy-gated pick (the top candidate cannot proceed until origin carries a merge local main
# already holds) and its own deadline wind-down (so origin never lags Linear overnight). Never per merge. The grant
# itself is the /auto invocation (standards/git.md § Named exceptions); this script is the mechanism, and it refuses
# without the project's opt-in.
#
# Opt-in: AUTO_PUSH_MAIN=lazy in the project's committed .claude/settings.json `env` block — project-scoped by
# construction, since the harness exports it only inside that project's sessions. Any other value is refused loudly:
# a typo must not read as "batching as usual".
#
# Usage: auto-push-main.sh        (from the MAIN checkout, on its default branch; no arguments)
#
# One line on stdout, and an exit code the caller branches on:
#   0  PUSHED: <n> commit(s) <old>..<new> to origin/<branch>
#   0  NOTHING-TO-PUSH: <branch> is at origin/<branch> (<sha>)
#   1  FETCH-FAILED: / PUSH-FAILED: <git's first error line>   — transient infrastructure; retry later
#   2  usage error (stderr): a linked worktree, a non-default branch, or an unknown AUTO_PUSH_MAIN value
#   3  DISABLED: AUTO_PUSH_MAIN is not set — origin lags until a human pushes
#   4  DIVERGED: origin/<branch> has <n> commit(s) this checkout lacks — not pushing; a human reconciles
#
# Never a force push, and never a rebase, merge, pull or reset of the local branch: a fleet's siblings merge into local
# main throughout the run, and this script must not move it under them. On a rejected push it re-fetches ONCE — origin
# may have moved between our fetch and our push — and answers DIVERGED when origin now holds commits we lack, otherwise
# PUSH-FAILED. Two siblings pushing the same commits concurrently both succeed: the second push finds origin already
# there, which git reports as success.
set -uo pipefail

mode="${AUTO_PUSH_MAIN:-}"
if [ -z "$mode" ]; then
  echo "DISABLED: AUTO_PUSH_MAIN is not set — origin lags until a human pushes (skills/finish/SKILL.md Step 7)"
  exit 3
fi
if [ "$mode" != "lazy" ]; then
  echo "usage: AUTO_PUSH_MAIN=$mode is not a mode this script knows — the one value is 'lazy' (a deploy-gated pick and the deadline wind-down); unset it to keep batching" >&2
  exit 2
fi

git rev-parse --git-dir >/dev/null 2>&1 || { echo "usage: not inside a git checkout ($(pwd))" >&2; exit 2; }
# The main checkout only. A linked worktree sits on an issue branch, and pushing from one pushes the wrong thing or
# nothing — `git worktree list` prints the main worktree first, whatever directory the command runs in.
main_wt=$(git worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
top=$(git rev-parse --show-toplevel 2>/dev/null)
if [ -n "$main_wt" ] && [ -n "$top" ] && [ "$(cd "$main_wt" && pwd -P)" != "$(cd "$top" && pwd -P)" ]; then
  echo "usage: run from the main checkout ($main_wt), not a linked worktree ($top)" >&2
  exit 2
fi

branch=$(git branch --show-current 2>/dev/null)
default=$(git symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
[ -n "$default" ] || default=main
if [ "$branch" != "$default" ]; then
  echo "usage: checkout is on '${branch:-a detached HEAD}', not the default branch '$default' — nothing to push" >&2
  exit 2
fi

first_err() { printf '%s\n' "$1" | grep -m1 -E '^(error|fatal|remote:|\s*!)' || printf '%s\n' "$1" | grep -m1 -v '^$' || true; }

if ! err=$(git fetch -q origin "$branch" 2>&1); then
  echo "FETCH-FAILED: $(first_err "$err")"
  exit 1
fi
if ! counts=$(git rev-list --left-right --count "origin/$branch...$branch" 2>/dev/null); then
  echo "FETCH-FAILED: origin/$branch is not a known ref after the fetch"
  exit 1
fi
behind=${counts%%[[:space:]]*}
ahead=${counts##*[[:space:]]}
old=$(git rev-parse --short "origin/$branch")

if [ "$behind" -gt 0 ]; then
  echo "DIVERGED: origin/$branch has $behind commit(s) this checkout lacks (origin at $old, local $ahead ahead) — not pushing; a human reconciles"
  exit 4
fi
if [ "$ahead" -eq 0 ]; then
  echo "NOTHING-TO-PUSH: $branch is at origin/$branch ($old)"
  exit 0
fi

new=$(git rev-parse --short "$branch")
if err=$(git push -q origin "$branch:$branch" 2>&1); then
  echo "PUSHED: $ahead commit(s) $old..$new to origin/$branch"
  exit 0
fi

# Rejected. Re-fetch once: origin may have moved between our fetch and our push.
if git fetch -q origin "$branch" 2>/dev/null \
   && counts=$(git rev-list --left-right --count "origin/$branch...$branch" 2>/dev/null); then
  behind=${counts%%[[:space:]]*}
  now=$(git rev-parse --short "origin/$branch")
  if [ "$behind" -gt 0 ]; then
    echo "DIVERGED: origin/$branch moved to $now during the push — $behind commit(s) this checkout lacks; not pushing; a human reconciles"
    exit 4
  fi
fi
echo "PUSH-FAILED: $(first_err "$err")"
exit 1
