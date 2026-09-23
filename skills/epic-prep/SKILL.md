---
name: epic-prep
description: Prepare one epic's graph for an epic-scoped fleet (`/fleet-launch epic:<ID>`) — the /auto-prep audit run with `--root`, plus what a team prep lacks: an inline /spec loop over uncertified members in dependency order, a boundary review of outside dependents and related partners, promotion of the whole graph to Planned, the epic integration branch, a hard gate that every resolved member's code is on that branch, and a scoped recommendation (scope, members, branch, base, and a forecast-sized count with the critical path started first). Interactive-only. Use when the user says 'epic prep', 'prep the epic', 'prep BF-1826 for a fleet', 'fleet this epic', or invokes /epic-prep.
argument-hint: "<EPIC-ID>"
model: opus
effort: xhigh
---

# Epic Prep — One Epic's Graph, Ready for a Scoped Fleet

An epic-scoped fleet works one epic's graph and nothing else: `/fleet-launch epic:<ID>` dispatches `/loop /auto epic:<ID>`, every pick runs `next-candidates.sh --root <ID>`, and the epic ships as **one PR from an integration branch the fleet merges into as it goes** (keeper decisions 2026-09-11). This skill is the prep bookend for that shape — `/epic-prep` → `/fleet-launch` (bare, or with a count and duration) → `/fleet-status` (member burn-down) → `/fleet-retro`.

It is [`/auto-prep`](../auto-prep/SKILL.md) with the pool cut to the graph, plus five things a team prep never needs: certifying members in dependency order, deciding what sits just outside the graph, promoting the whole graph together, the integration branch, and a gate on where the already-resolved members' code actually landed. Read [skills/linear/SKILL.md](../linear/SKILL.md) first. **Interactive by design** — it interviews (`/spec`) and asks for approvals; never run it unattended.

**Membership** (`scripts/epic-graph.sh`): the epic, its transitive descendants, and the transitive blockers of any member, non-terminal only, cross-team included. Dependents are not members — an outside issue a member blocks is enabled by the epic, not required by it — and neither are `related` partners; both are the **boundary**, reviewed in Step 4. Membership is live, recomputed at every pick, so a child filed mid-run joins the fleet's pool and `/fleet-status` reports it as added since prep.

## Arguments

`/epic-prep <EPIC-ID>` — required. Validated fail-closed by the graph script: a missing issue or one without the `epic` label stops the run with the reason. Run from the project's main checkout, **on the branch the epic should fork from** (Step 6 reads it).

## Workflow

### Step 1: Resolve the graph

```bash
mkdir -p tmp
~/.claude/scripts/epic-graph.sh <ID> > tmp/epic-graph.json || exit 1     # fails closed — never continue on a refusal
jq -r '"\(.members | length) members across \(.teams | join(", ")); \(.terminal | length) terminal; \(.edges | map(select(.type == "blocks")) | length) internal blocks edges; boundary: \(.boundary.dependents_outside | length) dependents, \(.boundary.related_outside | length) related"' tmp/epic-graph.json
~/.claude/scripts/next-candidates.sh --root <ID> --include-blocked --limit 50
```

Present the roster in three groups: members by state with their labels (certified / uncertified / gate-labeled), the terminal members (already resolved — Step 7's subjects), and the counts above. A nested `epic`-labeled member is a container like the root: its children are the work.

### Step 2: Certify members — the `/spec` loop, blockers first

The uncertified non-terminal members (no `specified`, not `epic`-labeled), ordered so every issue's internal blockers come before it:

```bash
jq -r '
  ([.members[] | select(any(.labels[]; ascii_downcase == "specified" or ascii_downcase == "epic") | not) | .identifier]) as $todo
  | ([.edges[] | select(.type == "blocks")]) as $e
  | def order($done; $left):
      if ($left | length) == 0 then $done
      else ([ $left[] | . as $x | select(all($e[]; .to != $x or (.from as $f | (($done | index($f)) != null) or (($left | index($f)) == null)))) ] | sort) as $ready
        | if ($ready | length) == 0 then $done + ($left | sort) else order($done + $ready; $left - $ready) end
      end;
  order([]; $todo)[]' tmp/epic-graph.json
```

Run `/spec <ID>` on each, in that order, inline — the full interview and signoff (`/spec` Steps 2–7); the collision pass `/spec` runs at certification uses the same three `blocks` meanings as everywhere else (`standards/issue-spec.md` § Certification includes collision edges), and within one epic the file-level overlap it finds is `related`, never `blocks`. A member the user declines to certify stays a member and will hold the gate as a FOCUS-ACTION row — say so in the report rather than working around it. Members that are decision-shaped take `/spec`'s decision-grade path; the members it files afterwards are new descendants and join the graph on the next resolve.

### Step 3: The team audit, scoped to the graph

Run `/auto-prep`'s [Step 2 (certification honesty)](../auto-prep/SKILL.md#step-2-certification-honesty-audit) and [Step 3 (families and collision edges)](../auto-prep/SKILL.md#step-3-consolidate-families-then-wire-collision-edges) over the **members only** — the pool is `tmp/epic-graph.json`, not the team fetch. For the collision candidates, run the pool tool for the epic's team(s) and keep only pairs whose issues are both members:

```bash
~/.claude/scripts/auto-prep-pool.sh --team <KEY> --collisions
jq --slurpfile g tmp/epic-graph.json '[.[] | select(all(.issues[]; . as $i | ($g[0].members | map(.identifier) | index($i)) != null))]' tmp/pool-collisions.json
```

Then [Step 4 (validate through the real ranking)](../auto-prep/SKILL.md#step-4-validate-through-the-real-ranking) with the scoped forms — both read the graph and refuse on a bad root:

```bash
~/.claude/scripts/next-candidates.sh --root <ID> --label specified --limit 30
~/.claude/scripts/fleet-blockers.sh --root <ID>
```

`FOCUS`, `FOCUS-ROOT`, `PROMOTE-SET`, and `FLEET-BLOCKED` describe the epic alone. Run the **CLOSE-SET sweep** exactly as `/auto-prep` Step 4 does (`linear-set-state.sh 'Ready for Release' <IDs>`, one approval) — a nested epic whose children have all shipped closes here; from now on `mark-ready-for-release.sh` closes epics itself at the last child's release, this one included.

### Step 4: Boundary review — include by re-parenting, default leave out

```bash
jq -r '.boundary | (.dependents_outside[] | "DEPENDENT \(.identifier) [\(.state)] \(.title) — blocked by \(.blocked_by | join(", "))"),
                   (.related_outside[]   | "RELATED   \(.identifier) [\(.state)] \(.title) — related to \(.related_to | join(", "))")' tmp/epic-graph.json
```

Present every row and ask, per issue, one question: does it belong to this epic? **Default is leave out** — a dependent is work the epic enables, a `related` partner is file-level overlap the merge gate reconciles; neither needs to be in the fleet's pool. **Include** only on the user's say-so, by re-parenting: `linear-cli relations parent <ISSUE> <EPIC-ID>`, then confirm with `linear-cli issues get <ISSUE> -o json | jq -r '.parent.identifier'`. Re-resolve the graph (Step 1) after any inclusion — the new member may bring blockers with it, and Steps 2–3 apply to it. Record the decisions in one comment on the epic (`~/.claude/scripts/linear-post.sh comment <EPIC-ID> tmp/epic-boundary.md`: each boundary issue, included or left out, one line) so the next prep starts from them.

### Step 5: Promote the whole graph to Planned

PROMOTE-SET semantics over the **entire membership**: every non-terminal member in Backlog or Todo — gate labels notwithstanding (labels decide who acts, not scope), the root included if it is not Planned — in one batch with one approval:

```bash
~/.claude/scripts/linear-set-state.sh Planned <IDs>      # each write read-back-verified
```

The one state never promoted around is Triage — a Triage member is groomed in Step 2 (grooming is acceptance), never state-written past it. With the graph promoted, the Planned gate is satisfied inside the scope and the board says what the fleet is doing.

### Step 6: The integration branch

The base is the same source `/start wt` would resolve in the main checkout: `git config --get start.wt-source-branch` when set, else `git branch --show-current`. A detached checkout with no config is an error — check out the branch the epic should fork from first (with no other context that is `main`; a long-running feature branch the epic belongs to is equally valid). Then:

```bash
base=$(git config --get start.wt-source-branch 2>/dev/null || git branch --show-current)
branch="epic/<id-lowercased>"
git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || git branch "$branch" "$base"
git merge-base --is-ancestor "$base" "$branch" || echo "WARN: $branch is behind $base — merge $base into it before launch"
```

No checkout happens here or at launch — `fleet-launch.sh` never moves the main checkout; each session's `/auto` steers its picks onto the branch with a per-issue `start.<id>.wt-source-branch` key set from the fleet marker ([`/fleet-launch`](../fleet-launch/SKILL.md) § Epic-scoped launch), so the human keeps the checkout on `base` or any other branch while the fleet runs. After the fleet, the epic's PR is opened from `branch` onto `base` (`~/.claude/scripts/integration-pr.sh <branch> <base> <member IDs...>` pushes the branch and opens the PR with a roster body — the same script `/fleet-sequence` ends with; `/pr-update` from a checkout of the branch then writes the real description).

### Step 7: Hard gate — every resolved member's code is on the branch

The ranking reads a terminal member as resolved, so its siblings look unblocked — while its code may sit in an open PR against some other branch (BF-1826's three renames: Ready for Release, PRs 492/494/497 stacked on `hotfixes`, contained in neither `hotfixes` nor `main`). A fleet forked from a branch without that code builds on a base that lacks its prerequisites. **This gate stops the prep until every such member's code has landed on the integration branch.**

Subjects: every issue in `tmp/epic-graph.json`'s `terminal[]` whose state is completed-type or Ready for Release (a Canceled or Duplicate member carries no code and is skipped), plus any member in `In Review` (resolved for blocker purposes, keeper ruling 2026-08-21). For each subject, in the project checkout:

1. Find its PR: `gh pr list --state all --search "<ID>" --json number,state,headRefName,headRefOid,baseRefName,mergedAt,title --limit 5`. Titles carry the ID by convention, so keep the row whose title starts with the ID followed by a non-digit; `ABC-12` must never take `ABC-123`'s PR.
2. **Landed** when the PR's head commit is contained: `git merge-base --is-ancestor <headRefOid> <branch>`.

   With no PR, search the whole commit message, not just the subject, and anchor the ID so `ABC-12` cannot match `ABC-123`: `git log -E --grep='<ID>([^0-9]|$)' --format='%h %s' "$branch"`.

   - A hit whose printed subject carries the ID counts as landed; `/finish` puts it there (`<ID>: …`, `Merge <ID>`).
   - Work absorbed into a sibling's change is often named only in that commit's body. A body-only hit counts once you have read the commit and confirmed it carries this issue's change ("That is the change <ID> specifies") rather than merely citing it ("leaves X for <ID>"). The issue's own closing comment usually names the absorbing sibling, which corroborates the read.

3. Anything else — a PR open or merged elsewhere, or no trace — is a **FAIL** row naming the ID, the PR, and its head branch.

   The one exception is a **decision record**, which has no code to land: a Done member that `/spec`'s decision-grade path closed as the record of a decision. A decision with no code change rides no release, so it closes Done rather than Ready for Release. Confirm both halves:

   - **Mechanically:** it has no PR of its own, and no commit anywhere carries its ID in the subject (`git log --all --format=%s | grep -E '<ID>([^0-9]|$)'` is empty). Bodies citing it are expected, because commits are where decisions get cited.
   - **By reading:** its closing comment is the recorded decision and names the follow-ups that carry the code. Those follow-ups are gated on their own: a terminal one by this step, an open one by the fleet.

   Mark the row `decision record`. It is a pass with nothing to land, not a waiver. A Done issue with no code and no such record stays a FAIL, since Linear's close-keyword automation can close an issue that way (`standards/git.md` § Linear auto-close keywords).

Print the table (`ID · state · PR · head · verdict`; verdict is `landed`, `landed (body)`, `decision record`, or `FAIL`). **Any FAIL stops the prep**: the remedy is to merge each failing head into the integration branch — for a stack, merging the tip carries the rest (BF-1839's branch carries BF-1832's and BF-1831's) — and the skill performs it only on explicit approval, through a temporary worktree so the main checkout is never switched:

```bash
git worktree add --detach tmp/epic-merge "$branch"
git -C tmp/epic-merge merge --no-ff --no-edit <head-branch>        # once per failing head, tip first for a stack
git update-ref "refs/heads/$branch" "$(git -C tmp/epic-merge rev-parse HEAD)"
git worktree remove tmp/epic-merge
```

Then re-run the gate; it must come back clean before Step 8. The superseded PRs are closed with a comment naming the branch they landed on (`gh pr close <n> --comment "landed on <branch> via /epic-prep <ID>"`) — never merged, since their bases were wrong. No waivers: a member whose code cannot be found is a member the fleet cannot safely build on (a decision record has no code to find — item 3), and the user's alternative is to take it out of the graph (re-parent it away or cancel it), not to launch around it. `gh` missing means the gate cannot run, which means the prep stops.

### Step 8: Critical path, sizing, and the recommendation

**Start the critical path first, then size from the forecast, not the lane count.** An epic's constraint is usually its longest `blocks` chain. When that chain's head ranks behind the standalones it starts late, and each session added beside it only ships a standalone and then idles.

Find the chain from the graph. Do not walk the edges by hand, and do not use the forecast's `(unblocked by …)` notes, which name the first shipped blocker rather than the binding one:

```bash
jq -r '[.members[].identifier] as $m
  | [.edges[] | select(.type == "blocks" and (.from as $f | $m | index($f)) != null and (.to as $t | $m | index($t)) != null)] as $e
  | def chain($x): [$x] + ([$e[] | select(.from == $x) | chain(.to)] | max_by(length) // []);
  [$m[] | select(. as $x | all($e[]; .to != $x)) | chain(.)] | max_by(length) | "\(length): \(join(" → "))"' tmp/epic-graph.json
```

Read the head's rank in Step 3's `next-candidates.sh --root <ID> --label specified` listing, which is what decides picks at run time. If the head is not first, priority is the lever, and within the tier every epic member sits in, only Urgent works. The within-tier order is Urgent > label class (`security` > `bug` > none) > remaining priority (`skills/next/SKILL.md`), so a High head still ranks behind every Normal `security` or `bug` member.

Self-assignment would also work, because fleet sessions share one Linear viewer and an issue assigned to you ranks in tier 1, above Urgent (`standards/linear-workflow.md` § Assignment Is a Claim). But it reads as your personal claim, and `fleet-forecast.py` does not model tiers, so the re-forecast below cannot confirm it.

Propose Urgent on every chain member: the head and each successor, since each competes again when it unblocks. Get the user's yes first. Urgent is the board's "drop everything" signal, and it outranks label classes across the whole team, not only inside the epic. Set each member with `linear-cli issues update <ID> --priority 1`, read `.priority` back (linear skill gotcha #8), and record the change in one comment on the epic, as Step 4 does for the boundary.

Then forecast the prepped graph at a few counts:

```bash
for n in 2 3 4 5; do ~/.claude/scripts/fleet-forecast.py --root <ID> --sessions $n --horizon-h 24 >| tmp/forecast-$n.txt; grep -E '^FORECAST|^UNREACHED' tmp/forecast-$n.txt; grep '^SHIP' tmp/forecast-$n.txt | tail -1; grep -E '^PICK .*: <HEAD> ' tmp/forecast-$n.txt; done
```

Confirm the head's `PICK` is at `t=0.0h`. Recommend the smallest count past which neither the ship count nor the last `SHIP` time improves, capped at 3 (the 5h-burst cap `/auto-prep` fixes; `/fleet-launch` takes any count, and above 3 the headroom gate parks sessions between picks). The simulation does not model file collisions, and one epic's members share files by construction. So when the last session added gains only by running `related` members side by side, take the count below it.

Measured on a 22-member epic: a Normal chain head covering 6 of the 15 shippable members ranked 9th of 9, and 7th at High. With the chain at Urgent, 4 sessions finished all 15 in about 21h instead of 26h, 3 sessions reached all 15 instead of 14, and 5 or more added nothing. `min(lanes, 2)` would have shipped 11.

State the binding term: the chain's serial floor (`floor`), which no count moves; lanes; or the cap. An explicit `/fleet-launch <count>` remains the user's override.

Persist the recommendation with the scope fields `fleet-launch.sh` and `fleet-status.sh` read — `scope`, `members` (the prep-time membership: the burn-down baseline), `branch`, `base` — alongside the sizing block `/auto-prep` writes:

```bash
jq -n --argjson sessions <N> --arg team <KEY> --argjson e "$(date +%s)" \
      --arg scope <ID> --argjson members "$(jq -c '[.members[].identifier]' tmp/epic-graph.json)" \
      --arg branch "$branch" --arg base "$base" \
      --arg bound_by '<floor|lanes|cap>' --argjson duration_h <D> \
      --argjson rate <TOK_PER_SESSION_HOUR> --argjson peak5h <PEAK_5H_OBSERVED> \
  '{sessions: $sessions, team: $team, generated_epoch: $e, generated: (now | todate),
    scope: $scope, members: $members, branch: $branch, base: $base,
    bound_by: $bound_by, duration_h: $duration_h,
    sizing: {rate_tok_per_session_hour: $rate, peak_5h_observed: $peak5h}}' \
  > tmp/fleet-recommendation.json
```

Written in the project's main checkout. A bare `/fleet-launch` now launches the scoped fleet on the integration branch; `/fleet-status` reports the member burn-down against `members`.

## Report

Lead with the Step 7 gate verdict — clean, or what was merged to make it clean — naming each row that passed on a read body match or as a decision record, since both are judgment passes in a no-waiver gate. Then the roster: certified this run, declined (holding the gate), terminal, nested epics closed by the sweep. Then the boundary decisions, the promotion batch, the critical path and any priority changes made to start it first, and the audit's remaining `FOCUS` rows. Then the launch line: `/fleet-launch` (bare) with the recommended count and duration, which term bound it (the chain's serial floor, lanes, or the cap), the integration branch and its base, and the post-fleet steps (`~/.claude/scripts/integration-pr.sh <branch> <base> <member IDs...>` then `/pr-update` for the PR). Every Linear write is reversible — say so once.

## What this skill must NOT do

- Never launch — that is `/fleet-launch`, a separate human-triggered act.
- Never certify without the interview — every certification goes through `/spec`.
- Never switch the main checkout's branch — the branch is created by ref, merges land through a temporary worktree, and the launch does not move the checkout either (per-issue fork keys steer the fleet).
- Never skip or waive the Step 7 gate.

## Error Handling

- Not an epic / missing issue → the graph script's refusal on stderr; stop.
- Detached HEAD with no `start.wt-source-branch` → say which branch to check out; stop.
- `gh` unavailable → Step 7 cannot run; stop before Step 8.
- A Linear write failing mid-run leaves prior writes in place — report what landed; everything is idempotent to re-run.
