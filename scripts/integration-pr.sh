#!/bin/bash
# integration-pr.sh — push an integration branch and open (or find) the one PR that ships it onto its base.
#
# Usage: integration-pr.sh <branch> <base> [<ISSUE-ID>...]
#
# The release shape /fleet-sequence and an epic-scoped fleet share (keeper decision 2026-09-11): work lands on
# one integration branch as it ships, and a single PR from that branch onto its base carries the lot. This is
# the mechanical half of opening that PR — push, find an open PR from <branch> onto <base>, create one with a
# roster body when there is none — so a detached runner can do it without an LLM and a human can do it from a
# terminal after a fleet. /pr-update rewrites the title and body from the diff afterwards; until then the body
# is the roster and says so.
#
# The body lists every issue ID bare — `<ID>: <title>` — never behind a close verb, because Linear scans PR
# bodies and would move an issue on merge (standards/git.md § Linear auto-close keywords). The issues are
# already Ready For Release from their merges; the PR merging changes nothing in Linear. A title that itself
# names another issue behind a close verb is the one hole this cannot close; /pr-update's checklist catches it.
#
# Output (stdout, key=value): PR_URL, PR_NUMBER, CREATED (1 when this run created it), BEHIND (commits on
# origin/<base> the branch lacks — one catch-up merge — or "?" when the fetch failed). Exit 1 when the branch
# cannot be pushed or the PR cannot be opened; nothing is retried. Read-write: pushes <branch>, creates the PR,
# writes tmp/integration-pr-body.md in the repo.

set -eo pipefail

[ $# -ge 2 ] || { echo "usage: integration-pr.sh <branch> <base> [<ISSUE-ID>...]" >&2; exit 1; }
branch="$1"; base="$2"; shift 2
for cmd in git gh jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found on PATH" >&2; exit 1; }
done
root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERROR: not inside a git repository" >&2; exit 1; }
git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || { echo "ERROR: no local branch '$branch'" >&2; exit 1; }
git remote get-url origin >/dev/null 2>&1 || { echo "ERROR: no 'origin' remote — a PR needs the branch on GitHub" >&2; exit 1; }
git ls-remote --exit-code --heads origin "$base" >/dev/null 2>&1 || { echo "ERROR: '$base' is not on origin — push it first (git push -u origin $base)" >&2; exit 1; }
git push -q -u origin "$branch" || { echo "ERROR: could not push '$branch' to origin" >&2; exit 1; }

find_pr() { # → "<url>\t<number>" of the open PR from the branch onto the base, or nothing
  gh pr list --head "$branch" --base "$base" --state open --json url,number 2>/dev/null \
    | jq -r 'if type == "array" and length > 0 then "\(.[0].url)\t\(.[0].number)" else empty end' 2>/dev/null || true
}

created=0
line=$(find_pr)
if [ -z "$line" ]; then
  mkdir -p "$root/tmp"
  body="$root/tmp/integration-pr-body.md"
  roster=""; single_title=""
  for id in "$@"; do
    title=""
    if command -v linear-cli >/dev/null 2>&1; then
      title=$(linear-cli issues get "$id" -o json 2>/dev/null | jq -r '.title // empty' 2>/dev/null || true)
    fi
    single_title="$title"
    roster="$roster
- $id${title:+: $title}"
  done
  {
    printf 'Integration branch `%s` onto `%s`' "$branch" "$base"
    if [ $# -gt 0 ]; then printf ', carrying these issues in the order they shipped:\n%s\n' "$roster"; else printf '.\n'; fi
    printf '\nEach issue was merged into the branch by its own session after its quality review; this PR carries them together.\n'
    printf 'Title and description are rewritten by `/pr-update`.\n'
  } > "$body"
  if [ $# -eq 1 ]; then title_line="$1${single_title:+: $single_title}"
  else title_line="$branch: $(printf '%s\n' "$@" | paste -sd, - | sed 's/,/, /g')"; fi
  gh pr create --head "$branch" --base "$base" --title "$title_line" --body-file "$body" >/dev/null \
    || { echo "ERROR: gh pr create failed for $branch → $base" >&2; exit 1; }
  created=1
  line=$(find_pr)
  [ -n "$line" ] || { echo "ERROR: PR created but gh pr list does not show it — check GitHub" >&2; exit 1; }
fi
url=${line%%$'\t'*}; number=${line##*$'\t'}
behind="?"
if git fetch -q origin "$base" 2>/dev/null; then
  behind=$(git rev-list --count "$branch..origin/$base" 2>/dev/null || echo "?")
fi
printf 'PR_URL=%s\nPR_NUMBER=%s\nCREATED=%s\nBEHIND=%s\n' "$url" "$number" "$created" "$behind"
