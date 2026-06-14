# Lifecycle Status Tags

Standard vocabulary for the **final line** of any session that participates in the Linear issue lifecycle (`/start`, `/finish`, `/checkpoint`, future related skills). The agents-list display surfaces this line — using a consistent tag prefix makes session state scannable at a glance.

## Why

Without a convention, final summaries are prose ("PR merged; worktree cleaned up", "Ready for /finish", "moved back to Planned per request"). A user scanning the agents list cannot tell which sessions need action vs which are done vs which were abandoned. The tags below give every terminal state a one-token signal at the start of the final line.

## Format

```text
<TAG>: <one-line summary, including next action when applicable>
```

- The tag is the **first token** of the final line.
- Tag is `UPPERCASE-WITH-DASHES`, followed by a colon and a single space.
- The summary follows on the same line — no line break between tag and content.
- The whole line is `/start` Step 10's "Next steps" line OR `/finish` Step 8/9's closing message — whichever is the session's last LLM-authored output before the harness's `※ recap:` footer.

## Tag vocabulary

Ten tags cover the lifecycle. Every session ends with exactly one.

| Tag | Issued by | Meaning | Typical next action |
| --- | --- | --- | --- |
| `IN-PROGRESS` | `/start` mid-flight (e.g., `/checkpoint`) | Implementation or review still running | wait, or resume in a new session |
| `READY-FOR-FINISH` | `/start` Step 10 (passing verdict) | Implementation + review passed cleanly; awaiting commit/push/state-transition | run `/finish` |
| `BLOCKED-ON-REVIEW` | `/start` Step 10 OR `/finish` Preflight/Step 8 (non-passing/unavailable/malformed verdict, OR user picked `abort`/`re-run` at the gate, OR user rejected the plan-mode preflight, OR `ExitPlanMode` tool failure at preflight) | `/quality-review` did not reach a clean pass, OR the user explicitly bailed at `/finish`'s gate or preflight, OR `ExitPlanMode` failed (tool/harness error) at preflight. Covers `terminated-with-open-items`, `escalated-to-architect`, verdict-unavailable, malformed, Step 8 `abort`/`re-run` responses, plan-mode preflight rejection, and `ExitPlanMode` tool failure | re-run `/quality-review`, escalate to architect, or investigate failure |
| `BLOCKED-ON-RECOVERY` | `/finish` Step 0/Step 8.7 (`finish-detect-mode.sh` exit 4) | The worktree was **hijacked by a parallel session** (branch swapped, HEAD reset off its baseline, or source-branch config wiped while the immune identity sidecar still proves it's a `/start wt` worktree). `/finish` stopped before merging: either the user declined the offered `finish-recover.sh` recovery, or recovery itself failed (apply conflict, `pnpm check` red, or setup error). State unchanged; the corrupted worktree is preserved | confirm/run `finish-recover.sh`, resolve the recovery conflict in the recovered worktree, or investigate manually. A successful recovery ends with `SHIPPED-MERGE`, not this tag |
| `SHIPPED-MERGE` | `/finish` Step 9 (`ACTION=merge`) | Worktree branch merged into source, worktree removed, issue Ready For Release. Also the terminal tag of a **successful** corruption recovery (recovered work merged) | done |
| `SHIPPED-PR` | `/finish` Step 9 (`ACTION=pr`) | PR opened (base = source branch in `wt` mode, else repo default branch); worktree preserved only in `wt` mode | review/merge the PR (then `git worktree remove` if it was a `wt` PR) |
| `DEFERRED-MERGE` | `/finish` Step 9 (`ACTION=merge`, `finish-merge.sh` exit 3) | Worktree merge couldn't advance source *right now* (transient: main checkout on source with WIP, source checked out elsewhere, main mid-operation, or contention) but was self-enqueued to the local merge queue; a launchd drainer retries until it lands and marks it Ready For Release then. Issue **remains In Progress** until the merge lands (it is not released until merged). Worktree intact | none — self-resolves. Check `/merge-queue`; act only if it later flags a conflict |
| `RELEASED` | `/finish` Step 8 (non-worktree flow) | Plain `/finish` complete, issue Ready For Release | done |
| `CANCELED` | `/start` Step 8.5 (canceled-after-start path) | Implementation discovered the work was already done or no longer needed; issue moved to `Canceled` | manual `git worktree remove` + branch delete |
| `ABANDONED` | `/start` Step 8.5 (abandoned-after-start path) | User halted the session before completion; issue moved back to `Planned`, worktree preserved for resumption | resume later, or clean up manually if dropping permanently |

## Worked examples

```text
READY-FOR-FINISH: PL-317 — resolveApolloErrorMessage suffix dropped, 6 files updated, tests green. Medium deferred to PL-324. Run /finish PL-317 merge.

BLOCKED-ON-REVIEW: PL-323 — 2 High findings unresolved after 5 cycles, user accepted current state. Re-run /quality-review or file follow-up issues before /finish.

SHIPPED-MERGE: PL-313 — merged into nextjs-descope-user, worktree removed, Ready For Release.

BLOCKED-ON-RECOVERY: PL-454 — worktree hijacked by a parallel session (branch-swapped); intended work salvaged to a patch. Confirm finish-recover.sh to re-fork off nextjs-descope-user and merge.

SHIPPED-PR: PL-319 — PR opened, base=main head=pl-319-foo. Review/merge then git worktree remove .claude/worktrees/pl-319.

SHIPPED-PR: PL-340 — PR opened (base=main, head=fix-contact-corruption), labels: pr-deploy. Review/merge the PR.

DEFERRED-MERGE: PL-361 — merge queued (main checkout on source branch with uncommitted changes); will retry automatically. Check with /merge-queue.

RELEASED: PL-201 — committed, pushed, marked Ready For Release.

CANCELED: PL-292 — work already shipped under PL-282/PL-284/PL-293. Run git worktree remove .claude/worktrees/pl-292 && git branch -D rosskevin/pl-292-eliminate-n-1...

ABANDONED: PL-322 — returned to Planned per user request. Worktree preserved for resumption.

IN-PROGRESS: PL-321 — implementation paused at /checkpoint, 3 of 5 requirement checkboxes complete.
```

## Rules

- **Exactly one tag per terminal output.** Never emit two tags on the same line. Never emit a tag mid-session.
- **No tag means the session did not reach a defined terminal state** (crash, manual interrupt before any skill stage emitted, etc.). The agents-list will show whatever raw text was last written; this is the only acceptable case for an untagged final line.
- **Tag choice is mechanical, not interpretive.** Each skill step that emits a final line specifies which tag applies based on terminal state — no LLM judgment required.
- **Skills MAY add a leading sentence (a one-line completion summary) before the tagged line**, but the tagged line must be LAST so the agents-list picks it up. Example pattern: a paragraph of detail followed by `READY-FOR-FINISH: ...`.

## Cross-references

- `~/.claude/skills/start/SKILL.md` — Step 10 (READY-FOR-FINISH, BLOCKED-ON-REVIEW); Step 8.5 (CANCELED, ABANDONED); `/checkpoint` interaction (IN-PROGRESS).
- `~/.claude/skills/finish/SKILL.md` — Step 8 (RELEASED, when non-worktree); Step 9 (SHIPPED-MERGE, SHIPPED-PR, DEFERRED-MERGE); Step 0/8.7 (BLOCKED-ON-RECOVERY on a hijacked worktree; `finish-recover.sh`).
- `~/.claude/skills/checkpoint/SKILL.md` — IN-PROGRESS on save.
- `~/.claude/skills/merge-queue/SKILL.md` — inspect/drain the deferred-merge queue behind DEFERRED-MERGE.
