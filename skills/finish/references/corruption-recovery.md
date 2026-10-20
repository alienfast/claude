# Worktree corruption recovery

Step 0.5 of [`/finish`](../SKILL.md), entered only when `finish-detect-mode.sh` exits 4. The worktree's identity does
not verify: either a parallel `/start wt` session reset it out from under this one, or this session's own deliberate
history rewrite detached the stamp without a restamp. In the hijack case the intended work is usually uncommitted edits
that survived the reset; `finish-recover.sh` salvages them to a patch, re-forks a fresh branch off the **current**
source tip, re-applies, gates on `pnpm check`, commits and merges.

Posture: detect and stop, with one confirmation. Recovery infers which files are this session's heuristically, so it
never runs unattended — auto mode never reaches this file (SKILL.md Step 0.5 stops on `BLOCKED-ON-RECOVERY` first). The
sanctioned restamp belongs at rewrite time, in the session that rewrote; a restamp run at finish time on a mismatch
would self-authorize exactly the signal a live-owner hijack forges.

## 1. Surface the mismatch

From Step 0's output: `CORRUPTION_REASON`, `CORRUPTION_OWNER_IS_ME`, `IDENTITY_SOURCE`, `EXPECTED_BRANCH` against the
current `WORKTREE_BRANCH`, `EXPECTED_BASELINE`, `EXPECTED_SOURCE_BRANCH`. State plainly what recovery will do: salvage →
fresh `.claude/worktrees/<id>-recovered` off `EXPECTED_SOURCE_BRANCH` → re-apply → `pnpm check` → commit → merge →
retire the corrupted worktree.

## 2. Self-rewrite fast path (interactive only)

When `CORRUPTION_OWNER_IS_ME=1`, `CORRUPTION_REASON=baseline-detached` and `EXPECTED_BRANCH` equals `WORKTREE_BRANCH`,
the likely cause is a deliberate rebase or reset by this session or its user. Confirm that with them; on confirmation
run `~/.claude/scripts/wt-restamp.sh '<WT_DIR>'` and re-run Step 0's detection. **Only the re-run reporting
`CORRUPTION=0` licenses continuing** — the restamp's own exit 0 is necessary, not sufficient, so never skip the re-run or
read its verdict off the restamp. On a clean re-run, continue the normal flow from Step 1 with every gate intact
(Step 1.5's verdict read and Step 8 included): the tree was never foreign-touched, so nothing is recovered. A non-zero
restamp exit (2, 3, 4, 5, or an undocumented code) or a re-run still reporting `CORRUPTION=1` falls through to the
recovery question in § 3, with the script's stderr surfaced verbatim.

**Exit 5** means the rewrite dropped commits the branch used to carry (the script lists them). A foreign reset and a
deliberate drop look identical here, so only after the user explicitly confirms the drops were intentional may the fast
path re-run once as `~/.claude/scripts/wt-restamp.sh --acknowledge-lost '<WT_DIR>'`. Never pass that flag unprompted.

**`lineage-clobbered` with `CORRUPTION_OWNER_IS_ME=1`** takes the same `--acknowledge-lost` path, and the audit can fire
on an orphaned merge alone: it checks content and reachability separately, `git cherry` compares patch-ids and never
sees a merge commit, and `git rev-list --merges` is the only check that can — an amended merge leaves `WTID_AUDIT_LOST`
empty and `WTID_AUDIT_LOST_MERGES` populated while the two trees are identical. Read the two stderr headings separately
(`… HEAD no longer contains:` versus `merge commits no longer reachable:`) and tell the user which fired and what it
lists. Only after they explicitly confirm the drops were deliberate, run the `--acknowledge-lost` form and re-run
Step 0's detection; the re-run's `CORRUPTION=0` licenses continuing, exactly as above. Restamp exit 3 means it could not
match a session id (owner attribution falls back to harness-pid equality when an id is missing on either side; the
restamp never does): fall through to § 3, whose question must then carry the flatten warning.

**Never carry `wt-restamp.sh` into a handoff.** Ownership is proven by session-id equality alone, so it refuses every
caller that is not the stamped owning session (exit 3, `cannot prove this is the owning session`); a human at a terminal
presents no session id and can never clear it. A blocked message is by definition read by someone else, so naming the
restamp in one sends its reader to a command that cannot run — route them to the recovery question instead.

## 3. Ask the user (single message, then wait)

> Worktree for `<ISSUE-ID>` does not match its stamped identity (`<CORRUPTION_REASON>`; owner-is-me=`<CORRUPTION_OWNER_IS_ME>`). Recover automatically? Reply `yes` to run `finish-recover.sh`, or `abort` to stop and inspect manually.

**When `CORRUPTION_REASON` is `lineage-clobbered`, the question must say what `yes` costs.** `finish-recover.sh`
salvages by flattening the branch to one `git diff <fork>` patch replayed as a single commit on a fresh fork, so every
merge commit and its message is destroyed — a real loss when the audit's only drops are orphaned merges whose tree HEAD
already carries (history is broken; the tree is not). Add the listed drops to the question, state that `yes` flattens
them away and that `abort` leaves the worktree for a human to repair reachability by hand, and on `abort` carry those
SHAs in the `BLOCKED-ON-RECOVERY` line.

**Never merge with `_WT_SKIP_IDENTITY_CHECK=1` instead.** That variable is recovery-internal — `finish-merge.sh` honours
it only because recovery re-invokes the merge on a freshly stamped worktree. It switches off `wt_identity_verify` and
the audit together, demands no ownership proof, and re-opens the detect→merge window a parallel session can hijack
across, which is why `finish-merge.sh` re-runs both checks at all. A read-only `git merge-tree` prediction that matches
the tree it would land is what makes it look safe, and is not evidence. It is strictly weaker than the
`--acknowledge-lost` path it would stand in for. (`_FM_SKIP_OURS_GUARD` is a different kind of skip: the guard it
bypasses has already printed exactly what the bypass discards; nothing enumerates what this one gives up.)

On `abort`: stop with `BLOCKED-ON-RECOVERY: <ISSUE-ID> — worktree identity mismatch (<CORRUPTION_REASON>); recovery
declined. Worktree preserved at <WT_DIR>.` No state change; run no further step.

## 4. On `yes`

Write the work-commit message (it must contain the issue ID, e.g. `PL-13: <summary>`) to
`<REPO_ROOT>/tmp/finish-commit-<issue-id-lowercased>.md`. In a worktree-isolated session the guard blocks a Write-tool
write to `REPO_ROOT` — write it via the shell (heredoc or `printf` redirect): it is gitignored, run-scoped bookkeeping
this workflow owns, and never a reason to touch `worktree.bgIsolation`. Then run from the main checkout:

```bash
cd '<REPO_ROOT from Step 0>'
~/.claude/scripts/finish-recover.sh '<WT_DIR>' '<EXPECTED_BASELINE>' '<EXPECTED_SOURCE_BRANCH>' '<EXPECTED_BRANCH>' '<REPO_ROOT>/tmp/finish-commit-<issue-id-lowercased>.md'
```

Route on the exit code. The script prints `RECOVER_DIFF_STRATEGY=<strategy>` on stderr — quote it in the closing line.

- **0** — recovered and merged. The merge owns the Ready-For-Release transition (as in Step 9's exit 0): run
  `~/.claude/scripts/mark-ready-for-release.sh <ISSUE-ID>`, then emit `SHIPPED-MERGE: <ISSUE-ID> — worktree identity
  mismatch recovered; work salvaged (<strategy>), re-forked off <EXPECTED_SOURCE_BRANCH>, merged, Ready For Release.`
  Terminal. When the `RECOVERED:` line ends with a `CLEANUP-FAILED` note, the recovered worktree stayed on disk at
  `.claude/worktrees/<id>-recovered`: apply Step 9's `CLEANUP-FAILED:` handling to it — the follow-up Notes comment, and
  `recovered worktree NOT removed (CLEANUP-FAILED: <blocking paths>; see the completion comment)` appended to the tag.
- **2** — conflict applying or merging in `.claude/worktrees/<id>-recovered`. Resolve there (read the conflicted files
  listed on stderr, fix, `git -C '.claude/worktrees/<id>-recovered' add <files>`, `pnpm check`), then re-run the same
  `finish-recover.sh` line — it resumes the recovered worktree. If genuinely unresolvable, emit
  `BLOCKED-ON-RECOVERY: <ISSUE-ID> — recovery conflict in .claude/worktrees/<id>-recovered; resolve and re-run finish-recover.sh.`
- **3** — merge deferred to the queue (transient). Emit `DEFERRED-MERGE: <ISSUE-ID> — recovered work queued (<reason>);
  will retry automatically. Check with /merge-queue.` The drainer marks Ready For Release when it lands.
- **4** — `pnpm check` failed in the recovered worktree. Emit
  `BLOCKED-ON-RECOVERY: <ISSUE-ID> — pnpm check failed in the recovered worktree; fix in .claude/worktrees/<id>-recovered and re-run finish-recover.sh.`
- **1** — setup failure (source branch gone, nothing salvageable, or the identity stamp on the recovered worktree
  failed). Surface the script's stderr and emit `BLOCKED-ON-RECOVERY: <ISSUE-ID> — recovery setup failed: <first stderr
  line>. Inspect <WT_DIR> manually.` If the failure was the identity stamp, the salvage already succeeded: the work is
  committed on the recovery branch in `.claude/worktrees/<id>-recovered` (`<WT_DIR>` is the corrupted original and holds
  nothing new), and the script resumes from that committed state — say so, point at the recovered worktree, and re-run
  the same line once the cause (a concurrent config writer, a read-only `.git`) is cleared.

Recovery is terminal — never continue to Steps 1–9 after it. The recovered code is what `/quality-review` already passed
in `/start`, so no separate verdict gate runs here; the user's `yes` is the gate.
