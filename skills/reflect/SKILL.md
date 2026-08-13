---
name: reflect
description: Continuous-improvement reflection on the just-finished session — captures generalizable lessons and reconciles stale config, then auto-applies the small/safe shared-config edits (user-level `~/.claude` targets only on the keeper's machine; project-level edits inside a /start wt worktree are check-gated and committed so they ride the issue merge) and proposes the larger ones — filing the proposals as a certified (`specified`) Linear issue (Planned); keeper batches (any `~/.claude` target) file uncertified with `keeper` instead, since `/auto` cannot ship cross-repo config work. Two modes — session (default; reflect on this session's friction) and sweep (audit a project's CLAUDE.md/rules against the actual codebase and de-duplicate). Use when the user says 'reflect', 'reflect on this session', 'what did we learn', 'reflect sweep', 'audit the config', or invokes /reflect. Auto-invoked at the tail of /quality-review.
---

# Reflect

Turn a session's friction into durable improvements to **shared, team-visible config** (`CLAUDE.md` / `rules/` / `standards/` / skills) — and reconcile config that has drifted from reality. Reuses `/quality-review`'s triage discipline (`apply-now` / `propose` / `drop`), pointed at the config layer instead of the code.

Two directions:

- **Add** — a generalizable friction (thrashing, a missing convention) → a new or updated rule/note that would have shortcut it.
- **Reconcile** — existing config now *contradicts* what actually happened → fix the stale instruction. A contradiction is concrete and verifiable, so reconcile is higher-value and lower-noise than add.

## Arguments

- (none) or `session` → **session mode**: reflect on the conversation in context.
- `sweep [project-path]` → **sweep mode**: broad audit of a project's config vs. its codebase + cross-file dedup. Defaults to the current project.

Examples: `/reflect`, `/reflect sweep`, `/reflect sweep ~/projects/baseFund`.

## Invariant — the noise guard is the whole point

A reflection step that drips low-value "lessons" into `CLAUDE.md`/rules **actively degrades every future session** — more context to read, more noise to weigh. So:

- **The bar is high and self-checking.** A candidate survives only if it is *genuinely generalizable* (will recur), *not already covered* by existing config, and *would actually have shortcut the friction*. Default to dropping.
- **Surfacing zero improvements is a success, not a failure.** Most clean sessions should produce `No improvements identified.` Do not manufacture findings to look productive.
- **Commits are narrow and scoped; pushes never.** Auto-applied edits normally land in the working tree only — the user's explicit-commit step is the review gate. The single exception: project-scoped `apply-now` edits inside a `/start wt` worktree are committed by Step 5 (staged **by name**, as a dedicated commit, check-gated) so they ride the issue merge instead of blocking it — that commit is authorized by this skill's contract. This skill never runs `git push`, never commits user-level `~/.claude` edits, and never commits anything it did not itself just edit.
- **Auto-apply is additive/clarifying only.** Anything that *removes* or *restructures* existing guidance is `propose`, never `apply-now`.

## Routing — where a lesson goes

Per the "Where Knowledge Goes" doctrine in `~/.claude/CLAUDE.md`. Target **shared config** by default; memory is the last resort, reserved for the rare truly-personal/transient note (a generalizable lesson is team-worthy, so it belongs in committed config where the team benefits).

| Lesson shape | Destination |
| --- | --- |
| File-type-scoped rule ("always X in `.ts`") | `~/.claude/rules/<type>.md` (with `paths:` frontmatter) or `<project>/.claude/rules/<topic>.md` |
| Universal cross-project rule or doctrine | `~/.claude/CLAUDE.md` or a `~/.claude/standards/<topic>.md` |
| Project-specific convention / stale project fact | `<project>/CLAUDE.md` or `<project>/.claude/rules/<topic>.md` |
| Broken skill behavior | fix the skill's `SKILL.md` directly; if it needs code/script changes → `propose` (its diff is captured in the auto-filed continuous-improvement issue — see Step 6) |
| Truly personal / transient (rare) | `~/.claude/projects/<project>/memory/` |

When unsure between two destinations, prefer the **most specific** scope that still reaches everyone who needs it (project rule over global rule over CLAUDE.md prose), and route to `propose` so the user picks placement.

## Triage gates (adapted from `/quality-review` Step 6)

Classify each verified candidate as exactly one:

1. **`apply-now`** — *all* of:
   - Targets an **existing** shared file (no new file created automatically).
   - One localized, **additive or clarifying** edit (a bullet, a sentence, a small section, or a reconcile fix that *corrects* a stale line in place — rewrite to current reality, **not** a deletion; removals are always `propose`).
   - Removes or contradicts no other guidance.
   - Clearly generalizable and confirmed not already covered.
   - **User-level `~/.claude` targets: keeper machines only.** The `~/.claude` repo is shared (pushed to `alienfast/claude.git`) and has one keeper who reviews and commits it. On any other machine, an auto-applied edit sits uncommitted in a clone nobody inspects — invisible to the keeper, drifting from origin until it conflicts or is silently lost. Probe with a **literal absolute path, never a bare `git -C ~/.claude …`**: in a `/start wt` worktree — this skill's dominant invocation, as `/quality-review` Step 7 — the isolation guard refuses a `git -C` target it cannot resolve statically, and `~/.claude` needs runtime tilde expansion, so the probe as literally written is refused (`standards/git.md` § Worktree-isolated sessions). That refusal reads exactly like a probe error, which the Error-handling rule below then turns into a **silent non-keeper downgrade on a keeper machine**. Resolve the path first with a plain non-`-C` command (`echo ~/.claude`), then pass the resolved string: `git -C <resolved path> config --get reflect.keeper`. Never hardcode one machine's path — this file is shared across every keeper's checkout. Prints `true` → apply-now permitted (the edit stays uncommitted for the keeper's deliberate review). Anything else — unset, or the probe errors — → downgrade to `propose`; Step 6's auto-filed issue is the durable, keeper-visible route. One-time keeper setup per machine: `git -C ~/.claude config reflect.keeper true` (local git config — machine-scoped, never committed or synced).
   - **Project-scoped targets inside a `/start wt` worktree: apply-now is permitted but MUST go through Step 5's check-then-commit path.** (`WT_ABS != MAIN_CHECKOUT` is the worktree signal — the same derivation `/quality-review`/`/start` Step 8 already use.) Left uncommitted, the edit fails `finish-merge.sh` precondition 5 and blocks the merge, or is discarded to unblock it and lost with the worktree; committed on the issue branch it rides the `/finish … merge` to the source branch — the only path by which a worktree session's project-config improvement actually reaches the team.
   - → apply to the working tree now, no prompt.
2. **`propose`** — *any* of: a new rule/standard/skill **file**; a structural `CLAUDE.md` change; a skill bug needing code/script work; cross-cutting; or the wording/placement needs a judgment call. → surface a ready-to-paste diff, and capture it in the auto-filed continuous-improvement issue (Step 6).
3. **`drop`** — one-off, already covered, or not generalizable. → record a one-line reason; do not surface loudly.

When genuinely torn between `apply-now` and `drop` for a small, safe, generalizable edit, prefer `apply-now` (the standing preference is to improve the config, not just note it). When torn between `apply-now` and `propose`, prefer `propose` (let the user place a borderline edit).

---

## Session mode

### Step 1 — Detect friction signals

Scan the session **in context** (you participated in it — no transcript-file lookup, which also avoids matching the wrong JSONL across concurrent sessions). Look for:

- **Thrashing** — repeated failed attempts at one problem; multiple `pnpm check` fail→fix cycles; circling on the same file; a long detour to discover a fact a doc would have handed over ("how does this project run tests", "where is X configured").
- **Silent skill/tool workaround** — a skill or tool errored or behaved wrong and was routed around **without being surfaced**. *Highest value:* a broken skill stays broken for the whole team until someone flags it.
- **Repeated user correction** — the user corrected the same class of thing more than once → a *candidate* missing convention. Frequency within one session is only a trigger to look, never proof: the lesson qualifies only if it states a standing principle that will recur across sessions, not "X happened twice today." Step 3 tests this.
- **Workaround anti-pattern** — one of the seven in `~/.claude/standards/problem-solving.md` was used (version pin/downgrade, error suppression, `any` cast, lint-disable, partial migration, incomplete impl, silent default). Note whether it was justified-and-documented or a smell that points at a missing rule.
- **Stale-config contradiction (targeted reconcile)** — this session did something that contradicts existing config: added a script/pattern that supersedes a documented manual step, or hit a `CLAUDE.md`/rule instruction that proved wrong. Scope the reconcile check to config that plausibly references the files this session touched.

**If no signal clears the bar → emit `No improvements identified.` and stop.** This is the common, good outcome; keep it cheap.

### Step 2 — Draft candidates

For each surviving signal, draft:

```text
{ type: add | reconcile,
  observation: <what happened, with concrete evidence — file/command/quote from the session>,
  proposed change: <the rule/note/fix>,
  target file: <per the routing table>,
  draft: <exact text or diff to add/change> }
```

### Step 3 — Verify (adversarial bar-check + dedup)

Delegate each candidate to a verifier agent (mirrors quality-review's find→verify). The agent has none of the session context, so pass the full candidate; it reads the target config file(s) and relevant code **from disk** and tries to **reject** it:

```md
Task for general-purpose (or quality-reviewer): Adversarially verify a config-improvement candidate.
Candidate:
- type: <add|reconcile>
- observation + evidence: <...>
- proposed change: <...>
- target file: <path>
- draft text/diff: <...>
Your job is to REJECT unless it clearly survives all of:
1. Generalizable — this states a standing principle that will recur across sessions/people. Single-session frequency ("it happened 2–3 times today") is NOT evidence of recurrence on its own — reject unless the lesson holds as a durable convention beyond this session. (You cannot see other sessions — judge the *plausibility* that the stated principle is durable; do not reject a sound general principle merely for lack of cross-session proof you cannot access.)
2. Not already covered — read <target file> and the related rules/standards/CLAUDE.md; quote anything that already says this. If covered, reject.
3. Would actually have helped — the change, present beforehand, would have shortcut the friction (for reconcile: the contradiction is real and the proposed fix matches CURRENT reality — read the code/scripts to confirm).
4. Correct destination — per ~/.claude/CLAUDE.md "Where Knowledge Goes".
5. Claims about other skills hold — when the draft asserts how another skill, standard, or rule behaves, or prescribes an action another skill owns, READ those files (skills included — gate 2's read set stops at rules/standards/CLAUDE.md) and confirm every assertion. Reject, or return a `corrected_draft`, when a claim misstates the referenced behavior or the proposed rule would conflict with what that skill actually does. A rule stating a false fact about the workflow is worse than no rule.
6. Quantified or enumerative claims about the codebase hold — a count ("six call sites share this shape"), a universal ("each of them derives `update?`"), or any characterization of a family. Verify these **by enumerating every member and checking each**, never by sampling one or trusting the draft's own survey, and state the enumeration in your reason line so the check is auditable. This gate and gate 7 are the only ones whose read set reaches application code — gate 2's stops at rules/standards/CLAUDE.md, gate 5's at skills, and gate 3's read-the-code clause is scoped to `reconcile` — so for a type `add` candidate no other gate will catch a false claim about the codebase. A draft can be right about the hazard and wrong about the family; the rule still ships a false statement, and rules are followed rather than re-derived. When the lesson survives but the claim does not, return a `corrected_draft` with the accurate enumeration rather than a `drop` — this preference overrides the default-to-drop below, which governs doubt about the *lesson*, not about a fixable claim.
7. Impossibility and universal-negative claims hold — "no hook can be written", "nothing can reach X", "the only answers are A or B", "there is no way to Y". The specific failure this gate exists for: a draft measured ONE mechanism's absence *correctly* and generalized to the capability's absence, so re-reading the measurement never surfaces the error and the draft's evidence looks sound. Name the capability, list the mechanisms that could satisfy it, and check each — like gate 6, this gate's read set reaches library and application code. When the enumeration cannot be closed, do not accept the claim on the strength of the one measurement: return a `corrected_draft` scoped to what was actually measured ("`beforeSend` cannot see a replay event") in place of the unscoped claim ("no hook can"). That narrowing is the default action here, not a fallback. A rule that misdescribes a mechanism is merely inaccurate; one that forecloses a mechanism talks the next reader out of the correct solution.
Return: { verdict: keep|drop, reason: <one line>, corrected_target?: <path>, corrected_draft?: <text> }.
Default to drop when uncertain.
```

Run verifiers in parallel when there are several, as one-shot **unnamed** `Agent` calls — never pass `name`, or the verdict is discarded with the teammate's turn-final text and only a bare idle notification arrives (see `standards/agent-coordination.md` § "Background-agent completion reports"). Drop everything that comes back `drop`. This is the primary noise guard — be glad when it rejects.

### Step 4 — Triage

Apply the three gates above to each kept candidate. **`apply-now` requires that Step 3 verification ran and returned `keep` for that candidate** — the independent verify is the gate that licenses an unattended edit to shared config. If verification could not run at all (verifier unavailable — see Error handling), **no candidate may be `apply-now`**; every survivor downgrades to `propose`. Auto-applying shared config without an independent verify defeats the primary noise guard.

### Step 5 — Apply `apply-now` items

Edit the target files directly in the working tree (these are small markdown edits; the orchestrator applies them — delegate to `developer` only if several independent files are involved). Re-read each target file **immediately before editing** — a prior step, an auto-fixer, *or a concurrent session* may have touched it (see `~/.claude/CLAUDE.md` multi-session safety: never clobber changes you did not make). **Do not commit** — except the one scoped case below.

**Project-scoped edits inside a `/start wt` worktree — check, then commit (the Invariant's single exception).** After applying them (user-level `~/.claude` edits are never committed by this skill, in any mode):

1. Run `pnpm check`. On failure, reverse each just-applied project edit with the Edit tool (swap the edit's new/old strings back — this skill knows exactly what it changed; never `git restore`, which is hook-blocked and could clobber others' work, and never `git stash` — the stash stack is shared across every worktree of the repo: `standards/git.md` § Safe Commands), reclassify the candidate as `propose` with the check failure as the reason, and move on — a config edit that reddens the check must not ride the issue merge, and left uncommitted it would block that merge (`finish-merge.sh` precondition 5).
2. On a green check, stage ONLY those files by name and commit them as a dedicated commit — never amended into, or mixed with, issue commits:

   ```bash
   git add <target-file ...> && git commit -m "docs(config): <one-line summary> (via /reflect)"
   ```

   This is the scoped commit the Invariant authorizes: it exists so the edit rides `/finish … merge` into the source branch and reaches the team. No push — `/finish` owns push.

Emit one visibility line, e.g.:

```text
Applied 2 config improvements: rules/typescript.md — prefer X over Y (uncommitted, keeper review); baseFund/CLAUDE.md — test setup is now scripts/setup-tests.sh, not manual (committed on issue branch).
```

### Step 6 — Surface and file `propose` items

First, for each `propose` item, show its destination and a ready-to-paste diff — an interactive run can paste straight away. Then, whenever there is **≥1 `propose` item**, capture them all in **one** auto-filed Linear issue, with **no prompt**, so the work survives autonomous runs (`/full` has no human to act on a surfaced diff — that is the gap this closes):

1. **Resolve the team.** Derive it from the worked issue's ID prefix (e.g. `PL-13` → `PL`) — use the issue ID already in context, or `~/.claude/scripts/detect-issue-id.sh` to recover it from the branch. If no issue/team resolves (a standalone reflection in a non-issue context), **skip filing** — surface the diffs only and note it (see Error handling); never guess a team.
2. **Build the body** into a unique tmp file — `mkdir -p tmp`, then `body_file=$(mktemp -u tmp/reflect-improvement-XXXXXX)` (`-u` — name only, no file created: the Write tool refuses a pre-existing file it has not Read, so plain `mktemp` breaks the next step. No suffix — BSD `mktemp` only substitutes a template that ends in the `X`s). Shape:

   ```text
   Auto-filed by /reflect after working <ISSUE-ID>. These config/process improvements were
   proposed (not auto-applied — apply-now edits already landed in the working tree).

   ## Proposals
   - [ ] **<target file>** — <one-line observation>
         <ready-to-paste diff in a fenced diff block>
   - [ ] ...
   ```

   **Make the title, observations, and any acceptance line enumerate the same scope the diff changes.** A count in the title and an acceptance line naming a subset both read as the filing's scope, so anything the diff additionally changes ships unannounced — and an implementer who trusts the prose carries the omission into their plan and their delegations. BF-1046 was titled "correct **two** mis-generated redaction rates" with an acceptance line naming only the two sentry ids, while its diff also moved a third figure 40.8% → 42.0%, a value ~5.8 standard errors from truth at the filing's own stated n — the error class the filing existed to fix, reintroduced by its own fix. Count what the diff changes and make the prose match before filing.

   Reference the originating issue by its plain Linear URL (`linear-cli issues get <ID> -o json | jq -r '.url'`) so it renders as a mention — a bare `<ISSUE-ID>` written through the API stays dead text (linear skill gotcha #20). Do **not** parent-link — a config/process improvement is standalone, not a child of the feature that surfaced it. This body certifies via the trusted-pipeline carve-out documented in [standards/issue-spec.md](../../standards/issue-spec.md) — observation = problem, diff = outcome, checkboxes = criteria — so filing self-certifies without an interview.

   **When a proposal's text describes code that landed under an issue — usually the originating one — record it as a checkable precondition, not just a link.** This skill runs as `/quality-review` Step 7, i.e. `/start` Step 9 — *before* `/finish` commits (its Step 7) and merges (its Step 9) — so the code the proposal describes is not on the source branch yet and **there is no merge SHA to cite**. Name the issue instead, as its own line in the body:

   ```text
   Precondition: this text describes code landed under <ORIGIN-ID>. Before editing, confirm it is in this tree —
   `git log --oneline | grep -q '<ORIGIN-ID>'` — and if absent, `git merge <source-branch>` first (merge, never
   rebase: a rebase detaches the stamped baseline and /finish refuses, exit 4).
   ```

   Grep the issue ID, not a `Merge <ID>` subject: `finish-merge.sh` creates a merge commit only when the source branch moved during the worktree's life, so the landed work often appears solely as its own `<ORIGIN-ID>: <summary>` line. A worktree cut for this proposal forks from the main checkout's HEAD at pick time (`start-wt-create.sh`, `mode=fresh`), which in a parallel `/auto` fleet routinely predates that merge — BF-790's forked one minute before its originating BF-744 landed, and `start-wt-create.sh` runs its behind/ahead drift warning only on the reuse path, so nothing flags it. Without this line every present-tense claim in the proposal is false against the very tree the implementer is editing, and the doc ships describing code absent from its own commit.
3. **Dedup, then file.** Run item 5's per-target-file token searches BEFORE creating (they are needed for edge wiring anyway — reuse the results there). An OPEN hit whose body describes the same defect against the same target absorbs the batch item: do NOT create a twin — append the proposal (evidence and diff) as a comment on the existing issue (`~/.claude/scripts/linear-post.sh comment`) and record it as `Filed: <ID> (existing — evidence appended)`. Two `/reflect` sessions in one fleet window hit the same friction routinely, and item 5's post-create edge wiring cannot un-file a twin (fleet-retro 2026-08-13: BF-1099 and BF-1103, same defect measured in the same window, no edge between them, found only at retro). Then **file it,** capturing the exit code — pass `--keeper` iff **≥1 proposal targets the user-level `~/.claude` repo** (any target outside the project — `~/.claude/CLAUDE.md`, `~/.claude/rules/`, `standards/`, `skills/`, `scripts/`):

   ```bash
   new_id=$(~/.claude/scripts/linear-file-improvement.sh [--keeper] <team> "<title>" "$body_file"); rc=$?
   ```

   The helper creates one standalone issue — status `Planned`, unassigned, labels `specified` + `reflection` (created if missing; `specified` is the certification that makes it eligible for `/auto` pickup, `reflection` is what makes `/next` rank it ahead of product work — improvements change how all future work runs) — and echoes the identifier. With `--keeper` it attaches `keeper` **instead of** `specified`, filing the issue uncertified: `/auto` ships project repos only, so a certified `~/.claude` issue produces a zero-commit false ship (BF-591) or a re-declined pick in every fresh session. Uncertified, `/auto` ignores it on every machine, while `keeper` hides it from every machine whose `git -C ~/.claude config reflect.keeper` is not `true` and boosts it on the keeper's for interactive pickup. Title e.g. `Continuous improvement from <ISSUE-ID>: <N> proposal(s)`. A `reflection`-only attach failure is a WARN within exit 0 (the load-bearing label intact), not an error.
4. Branch on `rc` for the Output `Filed:` line, then continue to item 5 — never block the reflection or the enclosing `/full` on filing:
   - `0` → `Filed: <new_id>` (filed and certified; for a `--keeper` batch: filed uncertified and keeper-gated).
   - `2` → `Filed: <new_id> (label not attached)` — filed, but the load-bearing label (`specified`; `keeper` for a `--keeper` batch) could not attach; surface the helper's WARN so the user can fix the label.
   - `1` (or empty `new_id`) → degrade per Error handling (`Filed: none — <reason>`).
5. **Wire the filed issue's collision edges** — [standards/issue-spec.md](../../standards/issue-spec.md) § Certification includes collision edges: filing hands the pool a pickable issue, so sequencing against open siblings must already be mechanical. `<new-ID>` below stands for the identifier item 3 captured as `new_id` — that capture ran in item 3's own Bash call, and shell state does not survive across separate Bash invocations, so a literal `"$new_id"` here sends an empty identifier to the API; substitute the resolved identifier.

   For each **distinct target file** in the batch (cap at ~5 searches on a large batch — the first five distinct targets in body order), search on a distinctive token: a distinctive basename (`issue-spec.md`, `next-candidates.sh`) is distinctive enough to search directly; a generic basename every skill or project shares (`SKILL.md`, `CLAUDE.md`, `README.md` — `search issues "SKILL.md"` alone returns dozens of unrelated hits) needs a substitute instead — the skill's directory name (`spec` for `skills/spec/SKILL.md`), the full repo-relative path for a nested `README.md` (e.g. `skills/README.md` — colliding issues name the file verbatim, and the path is one contiguous string), or the project name for a project `CLAUDE.md` or a repo-root `README.md` (whose path is just the bare basename `README.md`, so the path form discriminates nothing there). Either way, one token per call, never a composed phrase — `search issues` matches a contiguous token, and the JSON payload (`linear-cli search issues "<token>" -o json`) carries only `{id, identifier, priority, state, title}`, no description, while matches are frequently on body text. So: split hits by `state`. For each OPEN hit, `linear-cli issues get <ID> -o json` to read its body and judge overlap against the **full repo-relative path** of the target file, never the basename alone — two skills can each have a `SKILL.md` with no overlap at all. A TERMINAL hit (Done/Canceled) is prior art, not noise: when its title names the same file or mechanism, fetch it too and cite it in the filed body — `Prior art: <ID> (Done) — <what its fix covered>; filing anyway because <what still fails>` — because an unattributed re-file of shipped work hides the one question that matters about it: did the old fix regress, or never cover this path? (fleet-retro 2026-08-13: BF-1099 and BF-1103 both re-measured Done BF-510's exact repro and neither named it). Cap the total `issues get` fetches at ~10 per batch and keep this best-effort. Per OPEN hit that overlaps:
   - same file, the hit is itself `specified`, and this filing is a non-keeper (`specified`) filing → `linear-cli relations add <existing-open-ID> <new-ID> -r blocks` (existing blocks new — the no-discernible-order default of standards/issue-spec.md's direction rule — because `next-candidates.sh` hides blocked issues, which is what actually prevents concurrent pickup);
   - same file, but the hit is uncertified, `needs decision`, or `solo` (a blocker that will never ship unattended), or this filing is a `--keeper` batch → `-r related` plus a comment naming the file — wiring `blocks` behind a blocker that never ships unattended would strand this issue invisibly;
   - shares only a mechanism → `-r related` plus a comment naming the mechanism;
   - no overlap → nothing.

   Runs on the `--keeper` path too — the step still searches, wires edges, and comments — and on `rc=2` (filed but the load-bearing label unattached: a human fixing the label later must not inherit a certified-but-unwired issue). Skipped only on `rc=1`, where there is no `<new-ID>` to wire. **On the `--keeper` path the same-file edge is always `related`, never `blocks`**: a keeper batch certifies nothing (it files with `keeper`, not `specified`), so neither side is fleet-pickable and there is nothing to serialize — `next-candidates.sh` drops blocked issues *before* its keeper boost, so a `blocks` edge there would hide the batch from the keeper's own `/next` instead of protecting anything. Best-effort like item 4: a failed search, fetch, or `relations add` never blocks the reflection or the enclosing `/full` — note the miss in the `Filed:` line instead (`<new-ID> (collision edge to <ID> not wired — add manually)`).

### Step 7 — Output

Emit the compact Reflection block (see Output). When session mode was invoked from `/quality-review` Step 7, keep this terse so it never buries the verdict, and **emit no lifecycle tag** (this skill never owns one).

---

## Sweep mode (`/reflect sweep [project-path]`)

A broad audit of accumulated drift — not session-driven. Runnable manually or on a schedule.

### Step 1 — Scope

Resolve the target project (arg, else current). Collect its `<project>/CLAUDE.md` and `<project>/.claude/rules/*.md`, plus the user-level `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md`, and `~/.claude/standards/*.md` that the project's stack makes relevant.

### Step 2 — Fan out audit agents (parallel)

Split the config into slices (one agent per file or small group). Each agent reads its slice **and inspects the actual codebase** to test every claim/instruction:

```md
Task for general-purpose: Audit config against reality.
Files: <slice>
Project root: <path>
For each instruction/claim in the file: verify it against the codebase — is it still true? Has a script/command/pattern superseded it (e.g. a manual step now automated)? Do referenced paths, commands, scripts, or flags still exist? Quote the codebase evidence.
Return findings: [{ file, line_or_claim, status: stale|contradicted|duplicate|orphaned-ref|ok, evidence, proposed_fix }].
Only report non-ok items.
```

### Step 3 — Dedup pass

Across all slices, find overlapping or redundant guidance (the same rule stated in two files, a CLAUDE.md bullet duplicating a rule). Propose consolidation to the most specific correct home.

### Step 4 — Triage, apply, surface

Run findings through the three gates — with the **session-mode removal invariant applying here too: any deletion is `propose`, never `apply-now`.** So in sweep, `apply-now` is limited to **in-place corrections that remove no guidance** — fixing a stale command, path, or flag to its verified-current value. **Any deletion** — a now-false line, an orphaned reference, or an exact duplicate — is `propose`, because an audit agent can mistake a correct-but-externally-referenced rule for dead config (e.g. a migration invoked only from a CI yaml or Makefile the agent never read). `propose` also covers merging rules, restructuring a section, and anything needing judgment. Apply the in-place corrections to the working tree, never commit; surface the rest as diffs.

### Step 5 — Output

Emit the Config Audit report (see Output).

**Scheduling (opt-in, not auto-installed):** wire a recurring sweep via the `schedule` skill (cloud cron) or `loop`, e.g. weekly `/reflect sweep ~/projects/baseFund`. Document it; never install it silently.

---

## Output

**Session mode:**

```text
Reflection:
- Applied: <N> — <file — one-line each, marked committed|uncommitted, or none>
- Proposed: <N> — <destination — one-line each, or none>
- Filed: <PL-XX (Planned, specified — or "Planned, keeper — uncertified" for a --keeper batch) — append `(label not attached)` on exit 2, and/or `(collision edge to BF-YY not wired — add manually)` on an item 5 miss; or none — reason if skipped>
- Dropped: <N> (already-covered / one-off / not-generalizable)
```

**Sweep mode:**

```text
Config Audit — <project>:
- Stale/contradicted: <N> — <file:claim — fix, applied|proposed>
- Duplicates: <N> — <consolidation proposed>
- Applied: <N> (committed|uncommitted per Step 5's rules)
- Proposed: <N>
- Clean: <files audited with no findings>
```

## Error handling

- **Invoked from `/quality-review` with nothing to reflect on** → `No improvements identified.` and return. Add no latency-heavy work to clean runs.
- **Verifier agent unavailable** → do not auto-apply on faith. Downgrade every unverified candidate to `propose` and note that verification could not run.
- **Keeper probe unavailable** (`git -C <resolved literal path> config` errors — e.g. `~/.claude` is not a git clone on this machine) → treat as non-keeper: user-level candidates downgrade to `propose`. Fail toward filing, never toward editing a shared repo blind. **A worktree-isolation guard refusal on the tilde form is NOT this case** — re-resolve `~/.claude` to a literal path (`echo ~/.claude`) and retry with `-C <literal>` before concluding the probe is unavailable.
- **wt commit fails** (Step 5 — `git commit` rejected by a hook or precondition) → reverse the edits with the Edit tool exactly as in the red-check path, reclassify as `propose`, and surface the git error. Never leave a tracked project edit uncommitted in a merge-mode worktree.
- **Auto-fixer/lint touched a config file you were about to edit** → re-read before editing (the on-disk copy is post-fix); see `~/.claude/rules/markdown.md` and `~/.claude/rules/biome.md`.
- **A proposed edit would remove or restructure existing guidance** → never `apply-now`; always `propose`, even if you are confident. Removal is the user's call. (A reconcile fix that *corrects a stale line's value in place* removes and restructures nothing — that stays `apply-now` per the gates above.)
- **No issue / no project context** (standalone in a non-project dir) → session mode still works (it reflects on the conversation); sweep mode requires a project — ask for a path if none resolves. When `<project>` is unresolvable, any candidate whose correct home is a project-scoped file (`<project>/CLAUDE.md`, `<project>/.claude/rules/`) downgrades to `propose` (surface the suggested path for the user to place) — never `apply-now` to a guessed or user-level fallback path.
- **Issue filing failed or no team resolved** (Step 6) → if `linear-file-improvement.sh` exits **1** (`linear-cli` unavailable, the create call failed, no `Planned`-like state) or no team could be derived from a worked issue, **surface the `propose` diffs as before and record `Filed: none — <reason>`**. Exit **2** is *not* a failure — the issue was filed (id on stdout) but the load-bearing label (`specified`; `keeper` for a `--keeper` batch) could not attach; record `Filed: <PL-XX> (label not attached)` and surface the WARN. Filing is best-effort: never block the reflection or the enclosing `/full` flow on it, and never guess a team to force a file.
