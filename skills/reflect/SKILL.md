---
name: reflect
description: Continuous-improvement reflection on the just-finished session — captures generalizable lessons and reconciles stale config, then auto-applies the small/safe shared-config edits (user-level `~/.claude` targets only on the keeper's machine; project-level edits inside a /start wt worktree are check-gated and committed so they ride the issue merge) and proposes the larger ones — filing the proposals as a certified (`specified`) Linear issue (Planned). Two modes — session (default; reflect on this session's friction) and sweep (audit a project's CLAUDE.md/rules against the actual codebase and de-duplicate). Use when the user says 'reflect', 'reflect on this session', 'what did we learn', 'reflect sweep', 'audit the config', or invokes /reflect. Auto-invoked at the tail of /quality-review.
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
   - **User-level `~/.claude` targets: keeper machines only.** The `~/.claude` repo is shared (pushed to `alienfast/claude.git`) and has one keeper who reviews and commits it. On any other machine, an auto-applied edit sits uncommitted in a clone nobody inspects — invisible to the keeper, drifting from origin until it conflicts or is silently lost. Probe `git -C ~/.claude config --get reflect.keeper`: prints `true` → apply-now permitted (the edit stays uncommitted for the keeper's deliberate review). Anything else — unset, or the probe errors — → downgrade to `propose`; Step 6's auto-filed issue is the durable, keeper-visible route. One-time keeper setup per machine: `git -C ~/.claude config reflect.keeper true` (local git config — machine-scoped, never committed or synced).
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
Return: { verdict: keep|drop, reason: <one line>, corrected_target?: <path>, corrected_draft?: <text> }.
Default to drop when uncertain.
```

Run verifiers in parallel when there are several, as one-shot **unnamed** `Agent` calls — never pass `name`, or the verdict is discarded with the teammate's turn-final text and only a bare idle notification arrives (see `standards/agent-coordination.md` § "Background-agent completion reports"). Drop everything that comes back `drop`. This is the primary noise guard — be glad when it rejects.

### Step 4 — Triage

Apply the three gates above to each kept candidate. **`apply-now` requires that Step 3 verification ran and returned `keep` for that candidate** — the independent verify is the gate that licenses an unattended edit to shared config. If verification could not run at all (verifier unavailable — see Error handling), **no candidate may be `apply-now`**; every survivor downgrades to `propose`. Auto-applying shared config without an independent verify defeats the primary noise guard.

### Step 5 — Apply `apply-now` items

Edit the target files directly in the working tree (these are small markdown edits; the orchestrator applies them — delegate to `developer` only if several independent files are involved). Re-read each target file **immediately before editing** — a prior step, an auto-fixer, *or a concurrent session* may have touched it (see `~/.claude/CLAUDE.md` multi-session safety: never clobber changes you did not make). **Do not commit** — except the one scoped case below.

**Project-scoped edits inside a `/start wt` worktree — check, then commit (the Invariant's single exception).** After applying them (user-level `~/.claude` edits are never committed by this skill, in any mode):

1. Run `pnpm check`. On failure, reverse each just-applied project edit with the Edit tool (swap the edit's new/old strings back — this skill knows exactly what it changed; never `git restore`, which is hook-blocked and could clobber others' work), reclassify the candidate as `propose` with the check failure as the reason, and move on — a config edit that reddens the check must not ride the issue merge, and left uncommitted it would block that merge (`finish-merge.sh` precondition 5).
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

   Reference the originating issue as a bare `<ISSUE-ID>` (Linear auto-links it). Do **not** parent-link — a config/process improvement is standalone, not a child of the feature that surfaced it. This body certifies via the trusted-pipeline carve-out documented in [standards/issue-spec.md](../../standards/issue-spec.md) — observation = problem, diff = outcome, checkboxes = criteria — so filing self-certifies without an interview.
3. **File it,** capturing the exit code:

   ```bash
   new_id=$(~/.claude/scripts/linear-file-improvement.sh <team> "<title>" "$body_file"); rc=$?
   ```

   The helper creates one standalone issue — status `Planned`, unassigned, label `specified` (created if missing — the certification that makes it eligible for `/auto` pickup) — and echoes the identifier. Title e.g. `Continuous improvement from <ISSUE-ID>: <N> proposal(s)`.
4. Branch on `rc` for the Output `Filed:` line, then move on — never block the reflection or the enclosing `/full` on filing:
   - `0` → `Filed: <new_id>` (filed and certified).
   - `2` → `Filed: <new_id> (label not attached)` — filed, but the `specified` label could not attach, so the issue is invisible to `/auto` until labeled; surface the helper's WARN so the user can fix the label.
   - `1` (or empty `new_id`) → degrade per Error handling (`Filed: none — <reason>`).

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
- Filed: <PL-XX (Planned, specified) — append `(label not attached — not eligible for /auto)` on exit 2; or none — reason if skipped>
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
- **Keeper probe unavailable** (`git -C ~/.claude config` errors — e.g. `~/.claude` is not a git clone on this machine) → treat as non-keeper: user-level candidates downgrade to `propose`. Fail toward filing, never toward editing a shared repo blind.
- **wt commit fails** (Step 5 — `git commit` rejected by a hook or precondition) → reverse the edits with the Edit tool exactly as in the red-check path, reclassify as `propose`, and surface the git error. Never leave a tracked project edit uncommitted in a merge-mode worktree.
- **Auto-fixer/lint touched a config file you were about to edit** → re-read before editing (the on-disk copy is post-fix); see `~/.claude/rules/markdown.md` and `~/.claude/rules/biome.md`.
- **A proposed edit would remove or restructure existing guidance** → never `apply-now`; always `propose`, even if you are confident. Removal is the user's call. (A reconcile fix that *corrects a stale line's value in place* removes and restructures nothing — that stays `apply-now` per the gates above.)
- **No issue / no project context** (standalone in a non-project dir) → session mode still works (it reflects on the conversation); sweep mode requires a project — ask for a path if none resolves. When `<project>` is unresolvable, any candidate whose correct home is a project-scoped file (`<project>/CLAUDE.md`, `<project>/.claude/rules/`) downgrades to `propose` (surface the suggested path for the user to place) — never `apply-now` to a guessed or user-level fallback path.
- **Issue filing failed or no team resolved** (Step 6) → if `linear-file-improvement.sh` exits **1** (`linear-cli` unavailable, the create call failed, no `Planned`-like state) or no team could be derived from a worked issue, **surface the `propose` diffs as before and record `Filed: none — <reason>`**. Exit **2** is *not* a failure — the issue was filed (id on stdout) but the `specified` label could not attach, leaving it invisible to `/auto` until labeled; record `Filed: <PL-XX> (label not attached)` and surface the WARN. Filing is best-effort: never block the reflection or the enclosing `/full` flow on it, and never guess a team to force a file.
