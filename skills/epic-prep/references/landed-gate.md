# Step 7 — proving a resolved member's code is on the integration branch

For each subject (`/epic-prep` Step 7), in the project checkout:

1. **Find its PR:** `gh pr list --state all --search "<ID>" --json
   number,state,headRefName,headRefOid,baseRefName,mergedAt,title --limit 5`. Titles carry the ID by convention, so keep
   the row whose title starts with the ID followed by a non-digit; `ABC-12` must never take `ABC-123`'s PR.
2. **Landed** when the PR's head commit is contained: `git merge-base --is-ancestor <headRefOid> <branch>`.

   With no PR, search the whole commit message with the ID anchored:
   `git log -E --grep='<ID>([^0-9]|$)' --format='%h %s' "$branch"`. A hit whose subject carries the ID is landed
   (`/finish` writes `<ID>: …` and `Merge <ID>`). Work absorbed into a sibling's change is often named only in a commit
   body: a body-only hit counts once you have read the commit and confirmed it carries this issue's change rather than
   merely citing it; the issue's closing comment usually names the absorbing sibling, which corroborates the read.
3. **Anything else** — a PR open or merged elsewhere, or no trace — is a **FAIL** row naming the ID, the PR, and its head.

   The one exception is a **decision record**: a Done member that `/spec`'s decision-grade path closed as the record of a
   decision. It has no code to land, so it closes Done rather than Ready for Release. Confirm both halves:

   - **Mechanically:** no PR of its own, and `git log --all --format=%s | grep -E '<ID>([^0-9]|$)'` is empty (body
     citations are expected — commits are where decisions get cited).
   - **By reading:** its closing comment is the recorded decision and names the follow-ups that carry the code. Those are
     gated on their own: a terminal one by this step, an open one by the fleet.

   Mark the row `decision record` — a pass with nothing to land, not a waiver. A Done issue with no code and no such
   record stays a FAIL, since a close keyword can close an issue that way (`standards/git.md` § Linear auto-close
   keywords).

Print the table: `ID · state · PR · head · verdict`, verdict one of `landed`, `landed (body)`, `decision record`, `FAIL`.

## Remedy for a FAIL

Merge each failing head into the integration branch — for a stack, merging the tip carries the rest — only on explicit
approval, through a temporary worktree so the main checkout is never switched:

```bash
git worktree add --detach tmp/epic-merge "$branch"
git -C tmp/epic-merge merge --no-ff --no-edit <head-branch>        # once per failing head, tip first for a stack
git update-ref "refs/heads/$branch" "$(git -C tmp/epic-merge rev-parse HEAD)"
git worktree remove tmp/epic-merge
```

Re-run the gate; it must come back clean before Step 8. Close the superseded PRs with a comment naming the branch they
landed on (`gh pr close <n> --comment "landed on <branch> via /epic-prep <ID>"`) — never merge them, since their bases
were wrong.
