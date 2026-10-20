---
name: epic-prep
description: Prepare one epic's graph for an epic-scoped fleet (`/fleet-launch epic:<ID>`) — the /auto-prep audit scoped to the graph, a /spec loop over uncertified members, a boundary review, promotion to Planned, the integration branch, a gate that every resolved member's code is on it, and a forecast-sized count. Use when the user says 'epic prep', 'prep the epic', 'fleet this epic', or invokes /epic-prep.
argument-hint: "<EPIC-ID>"
model: opus
effort: xhigh
---

# Epic Prep — One Epic's Graph, Ready for a Scoped Fleet

An epic-scoped fleet works one epic's graph and nothing else: `/fleet-launch epic:<ID>` dispatches `/loop /auto
epic:<ID>`, every pick runs `next-candidates.sh --root <ID>`, and the epic ships as **one PR from an integration branch
the fleet merges into as it goes**. This skill is the prep bookend — `/epic-prep` → `/fleet-launch` → `/fleet-status`
(member burn-down) → `/fleet-retro` → `~/.claude/scripts/epic-pr.sh`, then `/pr-update <PR#>`.

It is [`/auto-prep`](../auto-prep/SKILL.md) with the pool cut to the graph, plus five things a team prep never needs:
certifying members in dependency order, deciding what sits just outside the graph, promoting the whole graph together,
the integration branch, and a gate on where the already-resolved members' code landed. Read
[skills/linear/SKILL.md](../linear/SKILL.md) first. **Interactive by design** — it interviews (`/spec`) and asks for
approvals; never run it unattended.

**Membership** (`scripts/epic-graph.sh`): the epic, its transitive descendants, and the transitive blockers of any
member, non-terminal only, cross-team included. Dependents are not members — an outside issue a member blocks is enabled
by the epic, not required by it — and neither are `related` partners; both are the **boundary** (Step 4). Membership is
live, recomputed at every pick, so a child filed mid-run joins the pool and `/fleet-status` reports it as added since prep.

## Arguments

`/epic-prep <EPIC-ID>` — required. Validated fail-closed by the graph script: a missing issue or one without the `epic`
label stops the run. Run from the project's main checkout, **on the branch the epic should fork from** (Step 6 reads it).

## Workflow

### Step 1: Resolve the graph

```bash
mkdir -p tmp
~/.claude/scripts/epic-graph.sh <ID> > tmp/epic-graph.json || exit 1     # fails closed — never continue on a refusal
jq -r '"\(.members | length) members across \(.teams | join(", ")); \(.terminal | length) terminal; \(.edges | map(select(.type == "blocks")) | length) internal blocks edges; boundary: \(.boundary.dependents_outside | length) dependents, \(.boundary.related_outside | length) related"' tmp/epic-graph.json
~/.claude/scripts/next-candidates.sh --root <ID> --include-blocked --limit 50
```

Present the roster in three groups: members by state with their labels (certified / uncertified / gate-labeled), the
terminal members (Step 7's subjects), and the counts above. A nested `epic`-labeled member is a container like the root:
its children are the work.

### Step 2: Certify members — the `/spec` loop, blockers first

The uncertified non-terminal members (no `specified`, not `epic`-labeled), ordered so every issue's internal blockers
come before it:

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

Run `/spec <ID>` on each, in that order, inline — the full interview and signoff. Its collision pass uses the same three
`blocks` meanings as everywhere else (`standards/issue-spec.md` § Certification includes collision edges); within one epic
file-level overlap is `related`, never `blocks`. A member the user declines to certify stays a member and holds the gate as
a FOCUS-ACTION row — say so in the report rather than working around it. Decision-shaped members take `/spec`'s
decision-grade path; the issues it files afterwards join the graph on the next resolve.

### Step 3: The team audit, scoped to the graph

Run `/auto-prep`'s [Step 2 (certification honesty)](../auto-prep/SKILL.md#step-2-certification-honesty-audit) and
[Step 3 (families and collision edges)](../auto-prep/SKILL.md#step-3-consolidate-families-then-wire-collision-edges) over
the **members only** — the pool is `tmp/epic-graph.json`, not the team fetch. For collision candidates, run the pool tool
for the epic's team(s) and keep only pairs whose issues are both members:

```bash
~/.claude/scripts/auto-prep-pool.sh --team <KEY> --collisions
jq --slurpfile g tmp/epic-graph.json '[.[] | select(all(.issues[]; . as $i | ($g[0].members | map(.identifier) | index($i)) != null))]' tmp/pool-collisions.json
```

Then [Step 4 (validate through the real ranking)](../auto-prep/SKILL.md#step-4-validate-through-the-real-ranking) with
the scoped forms — both read the graph and refuse on a bad root:

```bash
~/.claude/scripts/next-candidates.sh --root <ID> --label specified --limit 30
~/.claude/scripts/fleet-blockers.sh --root <ID>
```

`FOCUS`, `FOCUS-ROOT`, `PROMOTE-SET`, and `FLEET-BLOCKED` describe the epic alone. Run the **CLOSE-SET sweep** as
`/auto-prep` Step 4 does (`linear-set-state.sh 'Ready for Release' <IDs>`, one approval) — a nested epic whose children
have all shipped closes here.

### Step 4: Boundary review — include by re-parenting, default leave out

```bash
jq -r '.boundary | (.dependents_outside[] | "DEPENDENT \(.identifier) [\(.state)] \(.title) — blocked by \(.blocked_by | join(", "))"),
                   (.related_outside[]   | "RELATED   \(.identifier) [\(.state)] \(.title) — related to \(.related_to | join(", "))")' tmp/epic-graph.json
```

Present every row and ask, per issue, one question: does it belong to this epic? **Default is leave out** — a dependent
is work the epic enables, a `related` partner is overlap the merge gate reconciles. **Include** only on the user's say-so,
by re-parenting: `linear-cli relations parent <ISSUE> <EPIC-ID>`, confirmed with `linear-cli issues get <ISSUE> -o json |
jq -r '.parent.identifier'`. Re-resolve the graph (Step 1) after any inclusion — the new member may bring blockers, and
Steps 2–3 apply to it. Record the decisions in one comment on the epic (`~/.claude/scripts/linear-post.sh comment
<EPIC-ID> tmp/epic-boundary.md`, one line per boundary issue) so the next prep starts from them.

### Step 5: Promote the whole graph to Planned

PROMOTE-SET semantics over the **entire membership**: every non-terminal member in Backlog or Todo — gate labels
notwithstanding (labels decide who acts, not scope), the root included if it is not Planned — in one batch with one
approval:

```bash
~/.claude/scripts/linear-set-state.sh Planned <IDs>      # each write read-back-verified
```

The one state never promoted around is Triage — a Triage member is groomed in Step 2 (grooming is acceptance), never
state-written past it. With the graph promoted, the Planned gate is satisfied inside the scope and the board says what the
fleet is doing.

### Step 6: The integration branch

The base is the same source `/start wt` would resolve in the main checkout: `git config --get start.wt-source-branch`
when set, else `git branch --show-current`. A detached checkout with no config is an error — check out the branch the
epic should fork from first (`main` with no other context; a long-running feature branch is equally valid). Then:

```bash
base=$(git config --get start.wt-source-branch 2>/dev/null || git branch --show-current)
branch="epic/<id-lowercased>"
git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || git branch "$branch" "$base"
git merge-base --is-ancestor "$base" "$branch" || echo "WARN: $branch is behind $base — merge $base into it before launch"
```

No checkout happens here or at launch — `fleet-launch.sh` never moves the main checkout; each session's `/auto` steers
its picks onto the branch with a per-issue fork key ([`/fleet-launch`](../fleet-launch/SKILL.md) § Epic-scoped launch;
`scripts/auto-fork-key.sh`'s header documents the key), so the human keeps the checkout on `base` or any other branch.
After the fleet, `~/.claude/scripts/epic-pr.sh <EPIC-ID>` pushes `branch` by ref and opens the PR onto `base` from what
this prep and the launch recorded (read its header; `--dry-run` previews), then `/pr-update <PR#>` writes the description.

### Step 7: Hard gate — every resolved member's code is on the branch

The ranking reads a terminal member as resolved, so its siblings look unblocked — while its code may sit in an open PR
against some other branch, and a fleet forked without it builds on a base that lacks its prerequisites. **This gate stops
the prep until every such member's code has landed on the integration branch.**

Subjects: every issue in `tmp/epic-graph.json`'s `terminal[]` whose state is completed-type or Ready for Release (a
Canceled or Duplicate member carries no code and is skipped), plus any member in `In Review` (resolved for blocker
purposes). Read `references/landed-gate.md` for the procedure: find each subject's PR (ID-anchored, so `ABC-12` never takes
`ABC-123`'s), test `git merge-base --is-ancestor <head> <branch>`, fall back to an ID-anchored `git log --grep` on the
branch (a body-only hit counts once you have read the commit and confirmed it carries the change), and treat a Done
member that `/spec`'s decision-grade path closed as a **decision record** — a pass with nothing to land, confirmed
mechanically and by reading its closing comment. Print the table (`ID · state · PR · head · verdict`: `landed`,
`landed (body)`, `decision record`, `FAIL`).

**Any FAIL stops the prep.** The remedy — merging each failing head into the integration branch through a temporary
worktree, tip first for a stack, then closing the superseded PRs with a comment — runs only on explicit approval
(procedure in the reference), and the gate is re-run until clean. No waivers: a member whose code cannot be found is one
the fleet cannot safely build on, and the alternative is to take it out of the graph (re-parent it away or cancel it), not
to launch around it. `gh` missing means the gate cannot run, so the prep stops.

### Step 8: Critical path, sizing, and the recommendation

**Start the critical path first, then size from the forecast, not the lane count.** An epic's constraint is usually its
longest `blocks` chain; when that chain's head ranks behind the standalones it starts late, and each session added beside
it ships a standalone and then idles. Find the chain from the graph — never by hand, and never from the forecast's
`(unblocked by …)` notes, which name the first shipped blocker rather than the binding one:

```bash
jq -r '[.members[].identifier] as $m
  | [.edges[] | select(.type == "blocks" and (.from as $f | $m | index($f)) != null and (.to as $t | $m | index($t)) != null)] as $e
  | def chain($x): [$x] + ([$e[] | select(.from == $x) | chain(.to)] | max_by(length) // []);
  [$m[] | select(. as $x | all($e[]; .to != $x)) | chain(.)] | max_by(length) | "\(length): \(join(" → "))"' tmp/epic-graph.json
```

Read the head's rank in Step 3's `--label specified` listing, which decides picks at run time. If the head is not first,
priority is the lever, and within one tier only Urgent works: the within-tier order is Urgent > label class (`security` >
`bug` > none) > remaining priority (`skills/next/SKILL.md`), so a High head still ranks behind every Normal `security` or
`bug` member. Self-assignment would also rank it first (`standards/linear-workflow.md` § Assignment Is a Claim) but reads
as a personal claim, and `fleet-forecast.py` does not model tiers, so the re-forecast could not confirm it. Propose Urgent
on every chain member — the head and each successor, since each competes again when it unblocks — and get the user's yes
first: Urgent outranks label classes across the whole team. Set each with `linear-cli issues update <ID> --priority 1`,
read `.priority` back (linear gotcha #8), and record the change in one comment on the epic, as Step 4 does.

Then forecast the prepped graph at a few counts:

```bash
for n in 2 3 4 5; do ~/.claude/scripts/fleet-forecast.py --root <ID> --sessions $n --horizon-h 24 >| tmp/forecast-$n.txt; grep -E '^FORECAST|^UNREACHED' tmp/forecast-$n.txt; grep '^SHIP' tmp/forecast-$n.txt | tail -1; grep -E '^PICK .*: <HEAD> ' tmp/forecast-$n.txt; done
```

Confirm the head's `PICK` is at `t=0.0h`. Recommend the smallest count past which neither the ship count nor the last
`SHIP` time improves, capped at 3 ([`/fleet-launch`](../fleet-launch/SKILL.md) § The count is settled at 3). The
simulation does not model file collisions, and one epic's members share files by construction: when the last session
added gains only by running `related` members side by side, take the count below it. State the binding term — the chain's
serial floor (`floor`), which no count moves; lanes; or the cap. An explicit `/fleet-launch <count>` remains the user's
override.

**One PR or more.** List every `human` member that holds a non-`human`, non-`epic` member — directly or through other
members, on the graph's `blocks` edges — and read its body for a step that needs the epic's code running outside a
worktree: production, a preview deployment, a live device or floor test. Each hit is a gate this fleet cannot pass: a merge
into the integration branch deploys nothing, and nothing pushes the branch (`/auto`'s lazy push reaches only the default
branch). The fleet ships the agent work in front of the gate and idles there, and the epic needs a second PR whatever the
operator does. Report each gate with what it needs (a preview needs a push; production needs the branch merged onto
`base`) and the agent members it holds, and put the release shape to the operator: prep the nested phase epic that ends at
the first gate instead (`/epic-prep <PHASE-ID>`), which ships as its own PR, then prep the next phase once its human steps
are done; a mid-epic PR of this branch is the operator's call. A `human` member that holds only the epic itself — a
post-deploy step at the tail — is not a gate.

Persist the recommendation with the scope fields `fleet-launch.sh` and `fleet-status.sh` read — `scope`, `members` (the
prep-time membership: the burn-down baseline), `branch`, `base` — alongside the sizing block `/auto-prep` writes
(`skills/auto-prep/references/sizing-block.md`):

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

Written in the project's main checkout. A bare `/fleet-launch` stops on the recorded scope (`SCOPE-CONFIRM`) and asks
whether to launch it or go team-wide; `/fleet-launch epic:<ID>` launches directly, and `/fleet-status` reports the burn-down
against `members`. An epic fleet ends itself once only keeper-gated members remain, so the report says "expected to end
after N", not "idles after N".

## Report

Lead with the Step 7 gate verdict — clean, or what was merged to make it clean — naming each row that passed on a read
body match or as a decision record, since both are judgment passes in a no-waiver gate. Then the roster: certified this
run, declined (holding the gate), terminal, nested epics closed by the sweep. Then the boundary decisions, the promotion
batch, the critical path and any priority changes, and the audit's remaining `FOCUS` rows. When Step 8 found a deploy
gate, say before the launch line that this epic will not ship as one PR, name the gates, and carry the operator's
release-shape choice into the launch line. Then the launch line: `/fleet-launch` (bare) with the recommended count and
duration, which term bound it, the integration branch and its base, and the post-fleet step (`scripts/epic-pr.sh`, then `/pr-update`). Every Linear
write is reversible — say so once.

## What this skill must NOT do

- Never launch — that is `/fleet-launch`, a separate human-triggered act.
- Never certify without the interview — every certification goes through `/spec`.
- Never switch the main checkout's branch — the branch is created by ref, merges land through a temporary worktree, and
  the launch steers with per-issue fork keys.
- Never skip or waive the Step 7 gate.

## Error Handling

- Not an epic / missing issue → the graph script's refusal on stderr; stop.
- Detached HEAD with no `start.wt-source-branch` → say which branch to check out; stop.
- `gh` unavailable → Step 7 cannot run; stop before Step 8.
- A Linear write failing mid-run leaves prior writes in place — report what landed; everything is idempotent to re-run.
