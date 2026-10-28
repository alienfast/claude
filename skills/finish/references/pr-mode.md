# `/finish pr`: labels, title and body, create, close

Step 9 of [`/finish`](../SKILL.md) (`ACTION=pr`) reads this file once `<BASE>` is resolved there. The branch is already
on origin: `pr` implies push, and Step 7 pushed under `PUSH=1`. The flow is the same with or without a worktree; only
the base and the closing message differ.

## 1. Verify requested labels (only when Step 0 collected any)

Exact-equality check per label — a substring like `deploy` must not match an existing `pr-deploy`. The command prints
the name if the label exists and nothing otherwise:

```bash
gh label list --limit 200 --json name -q '.[].name | select(. == "<label>")'
```

A missing label is never dropped silently: surface it and ask — proceed without it, create it (`gh label create
'<label>'`), or abort. Apply only labels that exist or were just created. **Auto mode:** proceed without the missing
label and note the omission in the closing message.

## 2. Generate the title and body from the actual diff

Never `--fill` — it only echoes the commit message. Apply the [`pr-update`](../../pr-update/SKILL.md) skill's
methodology **by reference**: read its Analysis Process (§2–6), PR Title Formats and Description Structure and follow
them here, not as a `Skill`-tool dispatch — `/finish` stays the authority over the base, the labels and the terminal
`SHIPPED-PR` tag, and must not trigger pr-update's own interactive PR-state prompts. Skip pr-update's §2
base-resolution prologue (`if [[ -n "$pr_info" ]]; … BASE=…`) and substitute the `<BASE>` resolved in SKILL.md wherever
its commands reference `$BASE`: in a worktree that base is `SOURCE_BRANCH`, **not** the default branch, and letting
pr-update re-resolve it would diff the worktree PR against the wrong base. (pr-update's empty-`$BASE` guard lives in the
skipped prologue; SKILL.md's base step already stops on an unresolvable base, so `<BASE>` is non-empty here.) No push
here — Step 7 did it.

Before writing the body, apply [`standards/git.md`](../../../standards/git.md) § Linear auto-close keywords: only
`<ISSUE-ID>` may follow a close keyword. Every other issue ID — deferred follow-ups, next-in-sequence references,
siblings mentioned in passing — is written bare or behind a non-closing keyword, or merging this PR silently closes an
issue nobody worked on.

## 3. Write the body

To `<WT_DIR>/tmp/pr-body-<issue-id-lowercased>.md` (worktree mode) or `<REPO_ROOT>/tmp/pr-body-<issue-id-lowercased>.md`
(in-place) with the `Write` tool (it requires an absolute path) — the same pattern as the merge-commit message file in
merge mode.

## 4. Create the PR

Pass `--base` explicitly, the generated title, the body file, and one `--label` per verified label:

```bash
gh pr create --base '<BASE>' --head '<WORKTREE_BRANCH>' --title '<generated title>' --body-file '<path from step 3>' [--label '<label>' ...]
```

**A branch that already has an open PR** — a Renovate branch, a PR opened by hand, a re-run after §5 failed — is
updated, not created: `gh pr list --head '<WORKTREE_BRANCH>' --state open --json number --jq '.[0].number'` prints its
number, so run `gh pr edit <number> --title '<generated title>' --body-file '<path from step 3>' [--add-label '<label>'
...]` and continue to §5 with that PR. `gh pr create` refuses a branch with an open PR, and Step 9 has no handler for
the refusal, so without this branch §5's transition never runs.

## 5. Transition and close

Run `~/.claude/scripts/mark-ready-for-release.sh <ISSUE-ID>`: the open PR is the ship, and Ready For Release is the
state of work waiting for its release — never `In Review`, which is a human-review request, not a ship's landing state.
The PR merging later changes nothing in Linear.

Then emit the `SHIPPED-PR` closing message from SKILL.md § Terminal tags, choosing the variant by `SOURCE_BRANCH`:

- set → the worktree stays in place as the lifecycle boundary, and the tag names the post-merge cleanup once —
  `git worktree remove .claude/worktrees/<issue-id-lowercased>`, run from the main checkout (the parent of
  `.claude/worktrees/`). The leading sentence must not repeat the cleanup hint.
- empty → there is no worktree, so the tag ends on `Review/merge the PR.`

Substitute the resolved `<BASE>`, branch and label list (or the bare word `none` when no labels were applied). The
leading `This agent-view session is done.` sentence is standalone-only — under `/auto` drop it, keep the rest of the
line, and continue with `/auto` Step 4 after the tag.
