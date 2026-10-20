# gh mechanics — identify, validate, create, update

Read this at `/pr-update` §1 (identifying the PR and validating its state) and at "After Generating Description"
(creating or updating it). The rules live in SKILL.md; this file carries the shell blocks and prompt text.

## §1 — Identify the PR

```bash
git branch --show-current

pr_info=$(gh pr view --json number,title,state,mergedAt,headRefName,baseRefName 2>/dev/null)

if [[ -n "$pr_info" ]]; then
  pr_state=$(echo "$pr_info" | jq -r '.state // "UNKNOWN"')
  pr_merged_at=$(echo "$pr_info" | jq -r '.mergedAt // "null"')
  pr_number=$(echo "$pr_info" | jq -r '.number')
  pr_title=$(echo "$pr_info" | jq -r '.title')
  pr_head=$(echo "$pr_info" | jq -r '.headRefName')
  pr_base=$(echo "$pr_info" | jq -r '.baseRefName')

  case "$pr_state" in
    OPEN|CLOSED|MERGED|UNKNOWN) ;;
    *)
      echo "WARNING: Unexpected PR state from GitHub API: $pr_state" >&2
      pr_state="UNKNOWN"
      ;;
  esac

  if [[ "$pr_merged_at" != "null" ]] && [[ ! "$pr_merged_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
    echo "WARNING: Unexpected mergedAt format from GitHub API: $pr_merged_at" >&2
    pr_merged_at="null"
  fi

  if [[ -z "$pr_number" ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
    echo "ERROR: PR data incomplete (missing or invalid PR number)" >&2
    pr_info=""
  fi
fi
```

### Targeting a PR by number or URL

`/pr-update 545`, or another skill passing one from a checkout on an unrelated branch: the PR is the subject, not the
checkout. Resolve it with `gh pr view <arg> --json
number,title,state,mergedAt,headRefName,headRefOid,baseRefName,mergeCommit` in place of the bare `gh pr view` above. It
must belong to this checkout's `origin` repository — `git fetch origin` and Case B's `gh pr edit <number>` both target
it, so stop otherwise. A lookup that fails stops the skill; it is never "no PR exists". Never check out, switch, or push:
the update is Case B, title and body only, and the §1.1 prompt for a non-open PR offers update or cancel, never "create
new PR". Fetch with `git fetch origin <base> "pull/<number>/head"` (GitHub keeps that ref after a merge), then run the
rest of the skill against an explicit pair instead of the checkout:

- **Head:** every `HEAD` in the skill is `<headRefOid>` — §2–§4, §6, the checklist, and the census's `$BASE...HEAD`
  test. `scripts/verify-feature.sh` reads only the local `HEAD`; use `git show <headRefOid>:<path>` instead.
- **Base:** every `"$BASE"`, `origin/$BASE`, and §4 `$BASE_REF` is `origin/<base>` — unless the PR is MERGED, when it is
  `<mergeCommit>^1` (from `.mergeCommit.oid`), the base tip just before the merge. Once merged, `origin/<base>` carries
  the PR's change, so §4's baseline read shows it as already shipped — whatever the merge method. After a merge-commit
  merge it also contains the PR's head, so a three-dot diff against it comes back empty (`code-impact.sh` prints an
  all-zero table and exits 0); a squash or rebase merge leaves that diff intact, and the baseline is wrong all the same.
  Against `<mergeCommit>^1`, the three-dot diff to `<headRefOid>` is the PR's own change set — what GitHub's Files
  changed tab shows: `code-impact.sh <mergeCommit>^1 <headRefOid>`. A rebase merge is the exception: its `mergeCommit`
  has one parent and carries the PR's last commit, so `^1` already holds the PR's earlier commits; the three-dot diffs
  still resolve through ancestry, but find §4's baseline by hand before writing any "fixes" claim.

## §1.1 — PR state validation

OPEN → proceed. Otherwise stop and present this prompt (substitute the values):

```text
⚠️ **PR State Warning**

The detected pull request is **{pr_status_type}**:

- **PR**: #{pr_number} - {pr_title}
- **Branch**: {pr_head} → {pr_base}
- **State**: {pr_status_detail}

**Options:**
1. **Create new PR** - Open a fresh pull request for these changes (recommended for most cases; not offered when the PR was named by number or URL — "these changes" would be whatever branch is checked out)
2. **Update {pr_status_type} PR anyway** - Modify the PR's title/description (rarely needed)
3. **Cancel** - Stop without making changes

{pr_status_note}

**What would you like to do?**
```

Where `MERGED` (state `MERGED`, or `mergedAt` not null): detail "merged", note "Updating a merged PR only changes its
historical record, not the code." `CLOSED`: detail "closed without merging", note "Updating a closed PR is unusual. Most
cases should create a new PR instead." Anything else: `UNKNOWN`, detail `in an unclear state (<state>)`, note "Cannot
verify PR state safely. Manual investigation recommended."

Handle the user's verbal choice directly: "create new PR" → `pr_info=""` (Case A); "update anyway" →
`user_confirmed_update="true"` (Case B); "cancel" → `user_cancelled="true"`, exit without changes. Any other answer is
re-asked, never guessed.

## Case A — no PR exists (create)

`pr_info` is empty: none was found in §1, or the user chose "create new" in §1.1 — never for a PR named by number or
URL. Push the branch (idempotent), then create the PR against the resolved `$BASE`:

```bash
branch="$(git branch --show-current)"
if [[ -z "$branch" ]]; then
  echo "ERROR: detached HEAD — check out a branch before opening a PR." >&2
  exit 1
fi

if ! git push -u origin HEAD; then
  echo "ERROR: push failed (diverged remote, or no write access). Resolve manually — do NOT force-push — then retry." >&2
  exit 1
fi

gh pr create --base "$BASE" --head "$branch" --title "$title" --body "$(cat <<'EOF'
[Full description. The Executive Summary link line is a placeholder on this first pass — e.g. 🔗 **Pull request:** _(link below)_ — patched to the real URL in the required follow-up edit below.]
EOF
)"
```

`git push -u origin HEAD` sets the upstream on first push and is a no-op when the branch is already current. It is
**not** unconditionally safe — the `if !` gate stops before `gh pr create` whenever the push fails (a diverged remote
rejects it non-fast-forward; never force-push to recover). The `branch` guard rejects a detached HEAD up front (so
`--head` can never collapse to empty) and supplies `--head "$branch"`, which also keeps `gh` out of its interactive
"where should I push this branch?" prompt that would hang a non-interactive session.

**Fill the Executive Summary PR link.** The URL does not exist until the PR is created, so create with a placeholder on
the link line, then resolve the real URL and patch the body in one **required** follow-up edit — skip it and the PR
permanently shows the placeholder in its most-shared line:

```bash
pr_url=$(gh pr view --json url -q .url)
if [[ -z "$pr_url" ]]; then
  echo "ERROR: could not resolve the new PR's URL — leave the placeholder and retry the edit; do not ship it." >&2
  exit 1
fi
gh pr edit "$pr_url" --body "$(cat <<'EOF'
[Full description with the real PR URL written into the Executive Summary link line]
EOF
)"
```

The body heredoc is **quoted** (`<<'EOF'`), so it does **not** expand shell variables — write the *resolved* URL text
into the link line (`[#42 — Title](https://github.com/org/repo/pull/42)`), never the literal token `$pr_url` or the
template's `<pr-url>`, which would ship verbatim. This second edit is create-only.

## Case B — a PR already exists (update)

`pr_info` is non-empty: an OPEN PR, or a non-open PR the user confirmed updating. The URL is already known — resolve it
before composing the body and write its resolved value straight into the link line, so the single `gh pr edit` carries
it:

```bash
pr_url=$(gh pr view "$pr_number" --json url -q .url)
if [[ -z "$pr_url" ]]; then
  echo "ERROR: could not resolve PR #$pr_number URL — resolve before composing the body; do not ship an empty link." >&2
  exit 1
fi
```

**Pre-update state verification** (TOCTOU) — re-check the PR state immediately before the edit, in the same Bash call
that captured §1's variables (they do not survive across calls; if absent, stop and re-run §1's capture with this block
together):

```bash
if [[ -z "$pr_number" || -z "$pr_state" ]]; then
  echo "ERROR: PR identity not present in this shell — re-run §1's capture and this block in a single Bash call." >&2
  exit 1
fi

current_pr_info=$(gh pr view "$pr_number" --json state 2>/dev/null)
if [[ -z "$current_pr_info" ]]; then
  echo "ERROR: PR no longer exists (may have been deleted)" >&2
  exit 1
fi
current_state=$(echo "$current_pr_info" | jq -r '.state // "UNKNOWN"')
if [[ "$current_state" != "$pr_state" ]]; then
  echo "ERROR: PR state changed during processing ($pr_state -> $current_state); aborting update" >&2
  exit 1
fi

if [[ "$user_cancelled" == "true" ]]; then
  echo "ERROR: Attempted to continue after user cancellation" >&2
  exit 1
fi

if [[ "$pr_state" != "OPEN" ]] && [[ "$user_confirmed_update" != "true" ]]; then
  echo "ERROR: Attempted to update non-open PR #$pr_number (state: $pr_state) without user confirmation." >&2
  exit 1
fi

gh pr edit "$pr_number" --title "$title" --body "$(cat <<'EOF'
[Your full description here]
EOF
)"
```

## Confirm

Either path — `gh pr view` for the current branch's PR, `gh pr view <number>` when it was named.
