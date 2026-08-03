# Linear for stakeholders

How anyone on the team — engineer or not — can influence what the agents work on next.

> Linear is used for context just as much as the codebase.
> Linear is aspirational, code is ground-truth.

Linear is not a status report the agents write to — it is the **control plane** they read from. The board, its labels, its states, and the links between issues decide what an autonomous session picks up next. Change the board and you change the work.

## Executive summary

- **Agents pick up only certified issues** — those carrying the `specified` label. Everything else is invisible to autonomous runs, though humans can work it by hand.
- **Certification is a human gate.** `/spec` interviews a person, rewrites the issue into a standard shape (problem → outcome → testable success criteria), and applies the label. No interview, no label, no unattended pickup.
- **Ranking is mechanical**, computed fresh on every pick from labels, workflow state, priority, and issue relations. Prose in a description or a comment never affects *when* something is worked — only *what* gets built once it is picked.
- **Your levers, strongest first:** `Urgent` priority → `Planned` vs `Backlog` → `security`/`bug` labels → `High` priority. Planned work is drained before Backlog work, so stage is the main thing deciding when something happens (see [the tiebreaks](#the-tiebreaks--this-is-the-real-ranking)).
- **To see a human-readable board**, filter the label `specified` and invert the filter to *does not include*. The technical work the agents generate for themselves disappears and your product backlog is left.
- **Do not rename or delete these labels:** `specified`, `needs decision`, `solo`, `reflection`, `keeper`, `security`, `bug`, `stalled`. They are load-bearing — the automation matches on the exact names.

## What the agents actually read

An autonomous session ranks the whole workable backlog before every issue it picks. That ranking reads exactly four things:

| Signal | Where it lives | Effect |
| ------ | -------------- | ------ |
| Labels | Issue labels | Gate pickup (`specified`), hide from pickup (`needs decision`, `solo`), boost (`reflection`, `security`, `bug`) |
| Workflow state | Issue status | Planned and Backlog are both workable — but Planned is drained first. Triage and all terminal states are excluded |
| Priority | Issue priority | `Urgent` jumps the queue outright; the rest order work within a stage |
| Relations | Blocks / blocked by / parent | A blocked issue is hidden until its blocker reaches Ready for Release or Done |

Nothing else counts. In particular:

- **Descriptions and comments** are read at *implementation* time — they are the requirements — but they are never a scheduling control. Writing "do this first" or "don't start this yet" in a description has no effect; a `blocks` relation does.
- **Dragging a card up or down inside a column does nothing.** It is the most natural thing to try and it fails silently — the card visibly moves and the queue is unchanged. Use priority instead.
- **Cycle membership does nothing.** See [What the cycle view is good for](#what-the-cycle-view-is-good-for).

## The certification gate — `specified`

`specified` means: *this issue's description is a certified spec, and an unattended agent may pick it up and ship it.* Certification requires a problem statement, an observable desired outcome, and testable success criteria — plus explicit scope boundaries.

It is applied by:

- **`/spec`** — grooms an existing or Triage issue: research, an interview with a human, then certification.
- **`/prd`** — creates net-new epics and sub-issues already in spec shape.
- **`/quality-review`** — files follow-up issues discovered during review, certifying only the ones carrying a real severity. A judgement call, made by the reviewing agent.
- **`/reflect`** — files improvements to the toolkit's own rules and skills.
- **A human**, directly in Linear, when they judge a spec complete.

An issue with no testable criteria is not certifiable. In particular, a success criterion that says "decide whether X" can never ship unattended — the run just re-derives the same open question and stops. Decisions have to be made *before* certification and written into the description as the chosen behavior.

## Filtering the board back to human scale

The fleet generates a lot of technical issues for itself. To get the product view back:

1. Open the team view.
2. Add a filter: **Label → specified**.
3. Click the filter chip and switch it from *includes* to *does not include*.
4. Save it as a view if you want it to stick.

Two other filters worth keeping around:

- **Label → needs decision** — issues waiting on a human. This is where your input is most valuable; [When an agent parks an issue](#when-an-agent-parks-an-issue) covers how to clear one.
- **Label → stalled** — issues an agent abandoned after a pipeline failure. Developer territory rather than stakeholder, but worth watching as a health signal.

## How the queue is ranked

Every pick sorts the entire workable backlog into tiers, then breaks ties within a tier. Three tiers jump the queue:

1. **Certified toolkit improvements** (`specified` + `reflection`) — fixes to the rules and skills themselves. They change how every later issue runs, so they ship ahead of the work they improve.
2. **Already assigned to the session** — finish what you started.
3. **Newly unblocked, or a sibling** of the issue just completed — transient, and only in the moment after an agent finishes something.

Everything else — nearly the whole backlog — sits in one bottom tier, which makes the tiebreaks the thing that actually decides order.

### The tiebreaks — this is the real ranking

Each rule below is applied in turn, and the first one that separates two issues decides which goes first.

1. **`Urgent` priority** — pierces everything below it. The deliberate "drop everything."
2. **Stage: Planned before Backlog** — and it outranks the defect labels below, so a `Planned` improvement is picked ahead of a `Backlog` security fix. Deliberate: moving work to Backlog is how you defer a whole area, and a deferral that quietly exempted every defect would not be a deferral.
3. **`security` label** — within a stage, security defects lead.
4. **`bug` label** — then other defects, ahead of improvements.
5. **Remaining priority** — High, then Normal, then Low, then None.
6. **Sibling already in flight** — a soft de-rank, so parallel agents don't collide in the same files.
7. **Parent epic's state** — In Progress, then Planned, then Backlog, then Triage.
8. **Smallest estimate first.**

The first two are the ones you control directly, and they decide most picks: **Planned versus Backlog is your lever, `Urgent` is your override.**

Two rules work by removal rather than ordering. A **`blocks` relation** hides the blocked issue until its blocker is done — the only hard sequencing control available. The **`needs decision` label** hides an issue until a human resolves it. Also hidden: `solo` issues, anything in Triage, and everything in a terminal state. An epic whose children carry all the work is de-ranked below real work.

If an issue matters and you are not sure which lever to pull: move it to `Planned`, set the priority, and say why in a comment. Stage plus a clear reason is enough for a human to place it correctly.

Please don't inflate priorities. `Urgent` works precisely because it is rare; a board where everything is urgent ranks identically to a board where nothing is.

## Label glossary

| Label | Meaning |
| ----- | ------- |
| `specified` | Certified spec. The gate for autonomous pickup — no label, no unattended work |
| `needs decision` | A human must decide something before this can ship. Keeps `specified` (the spec is gated, not wrong) and is hidden from every ranking. Always paired with a comment naming the decision |
| `solo` | Certified and shippable unattended, but not *concurrently* — a broad sweep that would collide with everything else in flight. Run alone, when no fleet is active |
| `reflection` | A meta-issue about the toolkit's own rules or skills, filed from session friction. Ranked top tier because it prevents repeated friction and wasted tokens in every future session |
| `keeper` | Only valid alongside `reflection`. Marks an improvement to the *shared, cross-project* configuration, which only its keeper can ship. Filed uncertified on purpose and hidden on every other machine — it waits for the keeper to pick up by hand |
| `security` / `bug` | Defect class. Ranked ahead of improvements — within a stage, so a Backlog defect still waits behind Planned work |
| `stalled` | An agent abandoned this mid-flight after a pipeline failure. The work is preserved; a human needs to look |

Anyone's session can file a `reflection` issue against the shared toolkit. That is the intended path for "the agents keep doing X wrong."

## States

| State | Meaning |
| ----- | ------- |
| Triage | Unreviewed inbox. Never picked up automatically — it has not been accepted for work yet |
| Backlog | Accepted, sometime soon. Workable, but only drained once Planned is empty |
| Planned | Accepted, this release. Workable, and worked first |
| In Progress / In Review | An agent or human is on it |
| Ready for Release | Implementation complete and reviewed. Treated as **done** for dependency purposes — issues blocked by it are released immediately |
| Done | Merged and released |

## When an agent parks an issue

Autonomous runs are built to fail loudly and safely. The worst acceptable outcome is "nothing happened, and Linear says why" — never "something wrong shipped." Two shapes:

**A decision it cannot make.** The run posts a comment naming the exact decision or access needed, adds `needs decision`, returns the issue to Planned, and unassigns it. The `specified` label stays — the spec is not wrong, it is gated. The issue disappears from ranking until a human resolves it.

To unblock it: run `/spec BF-123`. That re-reads the issue, every comment added since, and interviews you about what to do. It rewrites the description with the answer baked in, re-certifies, and clears `needs decision` — putting the issue back in the queue.

Answering in a comment alone is *not* enough. The next run re-reads the description, finds the same open question, and stops the same way. The decision has to land in the description, which is what `/spec` does.

**A pipeline failure.** The run posts a comment, applies `stalled`, and moves on, preserving the branch and its commits. This one needs a developer: read the failure comment, work out whether the problem is the issue or the workflow, and decide whether to resume, respec, or drop it. Resuming clears the label.

## The operating rhythm

The fleet runs on three commands:

- **`/auto-prep`** — daily grooming pass before any fleet launch. Audits certified issues for unattended-shippability (flagging `needs decision` and `solo`), consolidates duplicate and same-family issues into one canonical issue, and wires `blocks` relations between issues that would touch the same files. This is what keeps parallel sessions from colliding.
- **`/fleet-launch 4 10 hours`** — starts four autonomous sessions with a ten-hour budget. At the deadline each finishes its in-flight issue and stops cleanly; nothing is killed mid-work.
- **`/fleet-retro`** — post-mortem on the run: what shipped, what it cost, whether the token burn was productive, and what to fix before the next one.

Sessions work in isolated git worktrees and merge through a lock, so several can drain the same backlog at once without stepping on each other.

## What the cycle view is good for

Linear adds an issue to the active cycle automatically the moment work starts or finishes on it. Nobody puts anything there by hand, and nothing reads it when deciding what to work on next — which makes it useless as a lever and genuinely useful as a report.

Each cycle is a self-maintaining two-week record of what the fleet delivered, typically a couple of hundred issues. If you want a throughput number for a given fortnight — what shipped, how much, in what areas — this is where to get it. Read it as history, never as a plan: adding an issue to the cycle yourself does not move it up the queue.

## The short version

The board is the agents' memory. If you want to change **what** gets built, edit the issue and get it re-specified. If you want to change **when**, use stage, priority, labels, and `blocks` relations — those are the only things the ranker reads.

For the full engineering detail behind any of this, see [standards/issue-spec.md](standards/issue-spec.md) (label contracts and the spec template), [skills/next/](skills/next/) (the ranking algorithm), and [the autonomous section of the README](README.md#autonomous-auto).
