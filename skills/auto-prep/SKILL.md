---
name: auto-prep
description: Prepare a team's certified backlog for a fleet of parallel /loop /auto sessions — audit `specified` labels for unattended-shippability, consolidate defect families, wire collision edges, validate the ranking, list what the keeper must unblock, and recommend a session count and duration from the forecast, printed as the launch command. Use when the user says 'auto-prep', 'fleet prep', 'prep the backlog for auto', or before launching a fleet.
argument-hint: "[team:KEY | KEY]"
model: opus
effort: xhigh
---

# Auto-Prep — Certified-Pool Review Before a Parallel /auto Fleet

`/next` observes one dependency signal — Linear `blocks` relations — and `/auto` ships whatever carries `specified`.
Before many `/loop /auto` sessions run in parallel, both must be honest: every certified issue unattended-shippable,
every prerequisite or same-method pair serialized, and file-level overlap marked `related`, so two sessions never edit one
method concurrently and never idle on a file git can merge. This skill audits and repairs both, then sizes the fleet.
[`/fleet-retro`](../fleet-retro/SKILL.md) is the bookend after the fleet.

Read [skills/linear/SKILL.md](../linear/SKILL.md) first (relations direction, label helpers, state-update verification).
Interactive by design — every flag is a decision for the user; never run it unattended.

**Writes it may make** (all reversible, all reported): add/remove labels, add `blocks`/`duplicate` relations, post
comments, adjust priority. No unconditional state write — a `duplicate` relation moves the absorbed issue into the
duplicate-type state on its own; the only state writes are Step 3's read-back fallback and Step 4's approved promotion
batch. Never assignees.

## Step 1: Resolve scope and fetch the pool

Team scope: a `team:KEY` (or bare key) argument, else `$LINEAR_TEAM`, else error — never workspace-guessed. Multi-team
fleets: run once per team.

```bash
~/.claude/scripts/auto-prep-pool.sh --team <KEY>      # paginated fetch → tmp/pool.json, prints the pool size
```

The script pages the fetch (`first:` is a hard API cap and overflow is silent), reads `hasNextPage` through the `data`
envelope (linear gotcha #6), and accumulates pages on disk. State the pool size in the report — a short fetch has no other
tell, and Step 4's ranking paginates on its own so it will not expose one.

Split into the certified set (`specified`) and the rest. Read every certified description in full — the audit and the
collision analysis depend on body content, not titles.

## Step 2: Certification honesty audit

`specified` means "an unattended agent may pick this up and ship it" ([standards/issue-spec.md](../../standards/issue-spec.md),
which owns every label below). Test each certified issue against that sentence, sort failures into the dispositions, then
run item 5 over every certified issue, failures included.

1. **Mark `needs decision`** — the body itself contradicts unattended shipping: a present-tense "must not ship from an
   unattended run" about *this* issue (a past-tense "was deferred because too big" does not count), or capabilities no
   agent has (a vendor rep, credentials or console access, a product decision with no testable criteria). Comment naming
   the decision or access needed, then `~/.claude/scripts/linear-add-label.sh <ID> 'needs decision'`. The issue keeps
   `specified` — gated, not wrong — and is hidden from every ranking until a human clears the label (directly or via
   `/spec`). When the work is *itself* human-performed — outreach, a console only a person can drive, production data
   remediation, sign-offs — apply `human` instead: permanent, and it refuses targeted `/auto <ID>` too. A body bundling an
   agent-shippable slice with human acts takes neither label — flag it for `/spec` to split at the handoff.
2. **Flag: decision-gated** — the first success criterion is a product/design decision but a conservative implementable
   path exists. Keep the label, list it: the user decides now (best) or accepts the conservative option. A decision counts
   only once it is in the description — route it through `/spec <ID>`; a comment does not unblock `/auto`.
3. **Mark `solo`** — implementable unattended but fleet-hostile; the remedy is sequencing. Apply the label
   (`linear-add-label.sh <ID> solo`; exit 2 → `linear-cli labels create "solo" -t issue`, retry once) and recommend a
   targeted `/auto <ID>` or `/fleet-sequence` while the fleet is quiet. The label hides the issue from every ranking;
   targeted runs still ship it. **It over-triggers, and a false positive parks a workable issue on the one serial
   resource** — read `references/solo-qualification.md` before marking one. Exactly two grounds qualify, named in the
   comment: (a) it changes the rules in-flight sessions already play by (merge drivers, the check graph, a shared CI gate,
   a lockfile every worktree's install predates); (b) it collides so broadly that serialization does not scale (more than
   a handful of Step 3 edges — put the count in the comment). A resolved generated artifact, a sweep confined to one file,
   and a serial artifact the repo does not resolve are the false positives the reference walks through.
4. **Pipeline label repair** — `/reflect` filings certify by provenance: ensure `specified` + `reflection`, plus `keeper`
   when the proposal edits `~/.claude`. Duplicate filings of one proposal: keep one canonical,
   `linear-cli relations add <dup> <canonical> -r duplicate`, cross-comment both.
5. **`simple` audit — both directions** (§ The `simple` label: risk-low, no open decision; effort irrelevant below the
   reviewability ceiling). Add it where the body qualifies; **remove** it (`linear-remove-label.sh <ID> simple`) where the
   body no longer qualifies or a `security`, `human`, `needs decision`, or `epic` label has attached. Body-first; open code
   only for issues near the top of the ranking, as one grep of the named file for a policy, lock, or transaction token
   that would move the remedy across a contract. List adds and removes with reasons; apply what the user confirms.

While reading bodies, catch cheap ranking wins: a flake fix or check-stabilizer other sessions' gates depend on deserves a
priority bump; `bug`/`security` labels missing from issues that plainly are one feed the class rank.

## Step 3: Consolidate families, then wire collision edges

**First confirm the team's ship state is one the ranking resolves.** `next-candidates.sh` clears a blocker only when its
state NAME is in `TERMINAL_STATES` (Done, Canceled/Cancelled, Duplicate, Ready For Release, In Review — case-insensitive;
`standards/linear-workflow.md` § Terminal States), so an edge whose blocker ships into a differently named state never
releases and the lane idles. Compare `linear-cli statuses list -t <KEY> --no-cache -o json | jq -r '.statuses[].name'`
against that list and against where `mark-ready-for-release.sh` lands. With no match, still wire the edges but say so and
treat every chain as manual.

Build overlap groups from each certified issue's edit-bearing sections, subjects first and paths second:

```bash
~/.claude/scripts/auto-prep-pool.sh --team <KEY> --collisions     # candidates → tmp/pool-collisions.json
```

Its output is candidates to confirm, never edges to wire blind. Read `references/collision-classification.md` when
confirming them — a named file is not an edited file, a subject takes the same edit-vs-citation test, same file is not
same method; a false edge hides a workable issue from every ranking while a missed edge costs one merge conflict.

**Family consolidation (one decision per group, interactive).** When a group's issues are the same defect *class* with
the same fix *shape* — one root cause across N sites — N point fixes cost N worktrees, ~2N reviews and N serialized merges
for what one class-scoped sweep fixes at once. Propose the merge: absorb into the existing sweep issue, else promote the
most complete point issue to canonical and widen it to the class. On approval: append each absorbed issue's Problem +
Success Criteria as a checklist comment on the canonical (`linear-post.sh`), wire `linear-cli relations add <absorbed>
<canonical> -r duplicate`, and remove `specified` from the absorbed issue — only once the canonical's **description**
names the absorbed subject (the reference explains why a comment is not enough). The `duplicate` relation moves its first
argument into the duplicate-type state with no history entry; read the state back and write it only if it did not land.
An uncertified canonical takes the absorbed work out of the pool until groomed — flag it for `/spec` rather than
certifying here. Same fix shape, never same file: two defects in one method are a serialization case, two in one file a
`related` pair, and merging them builds the blast radius `solo` exists to keep out. Declined groups fall through to
serialization.

Then wire **minimal chains** with `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks`:

- **`blocks` only for the three meanings — prerequisite, same method, deliberate increment** (`standards/issue-spec.md`
  § Certification includes collision edges). Same file, same spec file, or same mechanism is `related`. Adjacent pairs
  only (A→B, B→C, never a redundant A→C — `/next` requires all blockers terminal, so transitivity is free).
- **Order each group against the edges it already carries, then re-check every pair.** The pool arrives pre-wired and
  Step 1's relations carry the edges. Sort by existing reachability first, then the standard's direction rule
  (semantic/work order, else the earlier issue blocks the newer), then higher priority and wider fan-out first — a serial
  group's order is the run's tail. Then check every pair: adjacent-only wiring plus an existing edge can leave a pair
  mutually unreachable, a live collision nothing downstream reports.
- **Semantic order directs the edge:** mechanism before consumers, client display fixes before the server withholds the
  data, code before its docs, small surgical fixes before the sweep that enumerates the area.
- **Disjoint-overlap diamonds stay parallel:** A and C disjoint but both overlapping B → A→B and C→B, A ∥ C.
- **Never chain through a Step 2-flagged issue** — it never ships unattended, so its dependents are stranded. Flagged
  issues sit at chain *tails* only, save the one `human` head the standard allows (a production-readiness act whose
  dependent is wrong without it; `fleet-blockers.sh` reports it as a `human` root).
- **A `solo` blocker is a chain head or nothing.** It ships outside the fleet window, and blocker resolution reads state,
  never labels, so a dependent behind it stays blocked all run. Wire it as a blocker only when you will run it in the
  pre-fleet solo pass; otherwise leave it at a tail.

Rails that need no wiring: Linear is the claim registry (In Progress is invisible to `/next`), worktree creation is
repo-locked, `/finish` merges serialize and re-gate the merged tree whenever source advanced (what lets `related` partners
ship in parallel), and `/quality-review` wires its own same-batch collisions. This step covers *previously filed* siblings.

## Step 4: Validate through the real ranking

```bash
~/.claude/scripts/next-candidates.sh --team <KEY> --label specified --limit 30
```

Confirm: tier-0 reflection filings lead; every Step 3 dependent is absent; de-labeled issues are gone; every `solo` issue
is absent and accounted for by the trailing hidden-count note; `epic`-labeled issues absent with their own note (never
fleet-workable — an epic closes itself when its last child releases); and the `PLANNED-HOLD` note's *need the keeper*
entries read as the fleet's stopping point. Reconcile `solo` with `--label solo --include-blocked --limit 50`.

**Pass `--limit` on every listing you reconcile from — the default is 3**, with the remainder in a trailing `_N more …_`
line a row count discards. **Reconcile against the listing, not the hidden-count note:** the blocker filter hides issues
behind open blockers (`--include-blocked` restores them), and the notes span every state the fetch admits — `started`,
`triage`, `duplicate` included — so a note exceeding the listing means parked, in-flight, or blocked siblings before it
means a wiring fault. A blocker in the ship state still reading unresolved is a name mismatch against `TERMINAL_STATES`.

**Release-scope audit + fleet-drain blockers.** Run the tested implementation — never re-derive the filters inline (a
mistranscribed filter prints nothing at exit 0, which reads as "nothing blocks the fleet") — and branch on the `FOCUS:`
and `FLEET-BLOCKED:` summary lines, never on empty output:

```bash
~/.claude/scripts/fleet-blockers.sh --team <KEY>
```

**Epic auto-close sweep — before reading FOCUS.** `mark-ready-for-release.sh` closes an epic itself once every child is
terminal; the `CLOSE-SET:` line lists epics complete before that walk existed. Run the batch with one approval:
`~/.claude/scripts/linear-set-state.sh 'Ready for Release' <IDs>`. `CLOSE-SET: (none)` is steady state.

**FOCUS is the report's headline** — the keeper's unblock list for the unstarted stage (Planned/Todo, the committed
release scope that stage-first ranking drains first): every unstarted issue classified fleet-workable /
needs-keeper-action / draining, each blocked issue's chain walked to its root causes and grouped by fan-out
(`FOCUS-ROOT: <root> — <remedy> — unblocks <deps>`, widest first). Present the rows grouped by remedy, each with what it
releases and the released issues' priorities as its worth:

- `needs decision` → decide now, through `/spec <ID>` so the answer lands in the description.
- Uncertified scope → `/spec`, **excluding claimed issues**: an assignee other than the viewer is a person's claim
  (`standards/linear-workflow.md`; the script's `claimed by <email>` rows) — one line, never a keeper action.
- `human` work → do or re-scope; `solo` roots → the pre-fleet quiet window; `stalled` in-flight roots → resume or release.
- **Parked roots holding banked work** — a `needs decision`/`human` root whose preserved worktree carries verified
  commits: quantify the drift (`git rev-list --count <branch>..<source>`) and lead its row with a split-and-merge
  recommendation, since the gate usually covers part of the work and the verified remainder ages.
- Triage roots → groom (grooming is triage acceptance; never promote around it with a bare state write).
- **Every Backlog member of a Planned blocking chain** is release scope by implication whatever its labels — an issue is
  scoped by what it gates, not by its column or the gate parked on it. Promote the whole membership as one batch — the
  script's `PROMOTE-SET:` line IS the set (roots and intermediates; a hand re-derivation from the FOCUS-ROOT rows drops
  the intermediates): `~/.claude/scripts/linear-set-state.sh Planned <IDs>`, one approval, each write read-back-verified
  (linear gotcha #8). Promotion is column hygiene, not what makes the fleet reach them (`next-candidates.sh` inherits the
  Planned stage for Backlog issues that transitively block Planned work — `standards/linear-workflow.md` § Stage
  Priorities); it puts them in the keeper's Planned view and grooming filter. Gate labels never hold a member back (they
  already hide it from every ranking in any state), and promotion does not unpark it: its remedy row still leads. A root
  co-gated with siblings frees nothing alone, so the batch is the unit. After promoting, re-run the Planned-tier collision
  pass. This is the **only** promotion this skill suggests: Backlog issues gating only Backlog work stay put.

**FLEET-BLOCKED is second-order** — certified Backlog candidates stranded behind blockers the fleet can never pick;
present it briefly and last. A declined remedy → the dependent is stranded for this run; a stale edge → drop the edge,
never promote around it.

## Step 5: Fleet size and launch checklist

Count **lanes** from the Step 4 ranking, which already excludes both label gates and, under the Planned gate
(`standards/linear-workflow.md` § Stage Priorities), is the **Planned stage alone** until that column drains: Backlog
candidates never count as lanes while anything Planned remains, and a session beyond the Planned lanes idles until a
chain releases or the keeper acts. Lanes are the immediately-workable candidates minus the decision-gated flags, grouped
by cluster (chain heads count once; standalones individually). Then read the cap this machine's account pool sustains and
forecast the pool at every count up to it — the lane count is a hand walk at `t=0`, the simulation is the mechanical
check that each session added still ships something once chains release:

```bash
cap=$(~/.claude/scripts/fleet-cap.sh --json | jq -r .cap)     # 3 per account with room: 3 on one account, up to 12 rotating
for n in $(seq 2 "$cap"); do ~/.claude/scripts/fleet-forecast.py --team <KEY> --sessions $n --horizon-h 24 >| tmp/forecast-$n.txt; grep -E '^FORECAST|^STAGE|^POOL-DRAINED|^PLANNED-HOLD|^ROTATION|^THROTTLE' tmp/forecast-$n.txt; grep '^SHIP' tmp/forecast-$n.txt | tail -1; done
```

Recommend the smallest count past which neither the `FORECAST` ship count nor the `STAGE` drain time (`Planned/Todo …
drains ≈t=`) improves, capped at `cap`; below the cap, say when chains release more work. Cross-check wave 1 against the
Step 4 ranking as `/fleet-forecast` Step 3 does — the ranking decides pick order, the forecast decides the count. The
duration is that count's `STAGE` drain time rounded up to the next whole hour: under the Planned gate the fleet holds once
the column drains, so hours past it buy nothing without `backlog`, and a `STAGE … NOT drained` at the horizon makes the
horizon the duration with the report saying the column outlasts the run. When the checklist names the `backlog` opt-in,
re-run the recommended count with `--backlog` and take its `POOL-DRAINED` time (else the horizon) as the opt-in line's
duration.

**The cap is read, never asked about** — [`/fleet-launch`](../fleet-launch/SKILL.md) § The count — 3 per account with
room owns the per-account figure, the rotation arithmetic (3 on a single-account machine; 3 × the accounts with room on a
cswap-rotating one, at most 12), the weekly-window rule and the headroom-probe rule. Never size from a `/cswap quota`
table or a usage reading; the script's line is the whole input. Say which other window consumers are expected (the
operator's own session, an earlier fleet whose window has not rolled off) so the count is read against the whole pool; a
user-driven extra consumer never reduces the recommended count.

State the binding term: "7 lanes available, capped to 6 (2 accounts with room)" says the backlog is not the constraint;
"4 — the forecast gains nothing at 5" names the chain structure (`floor`); a lane-bound "2 sessions" names the real lever
(certify more work, or say when chains release it).

**Persist the recommendation** in the project's main checkout — a count-less `/fleet-launch` reads exactly this file and
warns when it is older than 24h. Read `references/sizing-block.md` to fill `rate`, `peak5h` and `fits` (the block
`/fleet-retro` audits the projection against):

```bash
jq -n --argjson sessions <N> --arg team <KEY> --argjson e "$(date +%s)" \
      --arg bound_by '<floor|lanes|cap>' --argjson cap "$cap" --argjson duration_h <D> \
      --argjson rate <TOK_PER_SESSION_HOUR> --argjson peak5h <PEAK_5H_OBSERVED> \
      --argjson fits <FIVE_HOUR_FITS_SESSIONS or null> \
  '{sessions: $sessions, team: $team, generated_epoch: $e, generated: (now | todate),
    bound_by: $bound_by, cap: $cap, duration_h: $duration_h,
    sizing: {rate_tok_per_session_hour: $rate, peak_5h_observed: $peak5h, five_hour_fits_sessions: $fits}}' \
  > tmp/fleet-recommendation.json
```

Launch checklist for the report:

- `export LINEAR_TEAM=<KEY>` in every fleet session (else `/next` roams the workspace).
- Project main checkout clean and parked off the integration branch (`git checkout --detach`) — every merge then takes
  the ref-only path.
- Run the `solo` issues via targeted `/auto <ID>` or `/fleet-sequence` before or after the fleet, not during. Bare
  `--label solo` is the **workable-now** set; the `--include-blocked` diff is the **blocked** set, which waits on its
  blockers regardless of the quiet window.
- The decisions (Step 2 flags, `needs decision` issues) that would refill the pool once made.
- **What will hold the Planned gate once the pickable Planned work ships** — the `PLANNED-HOLD` note's *need the keeper*
  entries. Each one left in the column idles the whole fleet at that point (without `backlog` it will not spend on
  Backlog around it). Decide, `/spec`, or move it out of Planned before launch — or state that the fleet is expected to
  idle after N issues (an epic fleet ends itself on `EPIC-DRAINED`, so `/epic-prep` says "expected to end after N").
- **A fleet mints its own gate holders, so that projection is an upper bound.** The filing recipe
  (`standards/linear-filing.md`) routes a priority 1–2 or `security` deferred filing into Planned at birth, and `/auto`'s
  park writes `-s Planned` when it declines or abandons a pick, so a column drained at launch can re-close hours in.
  Report "idles after N issues *or sooner*"; a security sweep or hardening batch erodes its own runway. It mints Backlog
  candidates too: every other certified filing lands in Backlog, where a fleet launched without `backlog` reaches it
  only through its filer's hot handoff, an ancestor still in Planned lending it the stage, or the column draining, so
  "Backlog is empty" at launch does not mean a held fleet has nothing to work. When the report expects the fleet to idle
  well before its deadline, name the opt-in without recommending it: `/fleet-launch … backlog` would let held sessions
  work those filings, the human's call for a day with spare usage (`standards/linear-workflow.md` § Stage Priorities;
  `/fleet-forecast --backlog` projects it). The 2026-10-27 fleet: two certified `bug` filings made about an hour in
  waited behind a column nine keeper-only issues held until the deadline, while its three sessions sat idle 7.8–10h
  each after their last ship.
- Remaining `FLEET-BLOCKED` rows — each a candidate the fleet will NOT reach this run.

## Report

**Lead with the keeper's unblock list for the release scope** — Step 4's FOCUS rows grouped by remedy and ranked by
fan-out, each action paired with what it releases and its worth; the first line is the single highest-value action.
Everything unstarted-scoped that needs the keeper — decisions, certifications, human tasks, stalled resumes, the promotion
batch (required for the stage to drain, never an optional pull-forward) — belongs here. Then the launch command, **printed
literally on every run with this prep's count and duration filled in — never a bare `/fleet-launch`, never a
placeholder**:

```text
/fleet-launch 6 10h
```

followed by which term bound the count (`floor` — the forecast gains nothing past it; lanes; or the cap with its
accounts-with-room reading), the `STAGE` drain time the duration rounds up, and the projected burn per 5h window beside
the observed peak; when the checklist named the `backlog` opt-in, the same command with ` backlog` appended and its own
duration from the `--backlog` forecast on a second line, labelled as the opt-in. Then the `solo` quiet-window plan in
running order: **workable now**,
then **blocked** (each with its blocker). **Everything Backlog-scoped comes last and stays brief**: changes made
(consolidations as absorbed→canonical
with the class named, edges as blocker→blocked with one-line rationale, label ops, priority bumps), decision-gated issues
gating only Backlog work, remaining FLEET-BLOCKED edges, and the validated top of the ranked pool. Every write is
reversible — say so once.

## Error Handling

- No team resolvable → ask for one; never scan the workspace.
- Zero certified candidates → report it and point at `/spec` rather than inventing prep work.
- A write failing mid-run leaves prior writes in place — report what landed and what didn't; every operation is
  idempotent to re-run.
