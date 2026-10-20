# Parks and declines — routing a stop that needs a human

Read from `/auto` Step 4 before recording a `SKIPPED-BLOCKED`, or any terminal tag whose reason names something a
person must supply. `standards/issue-spec.md` defines the labels; this file is how `/auto` applies them.

## Two park shapes, two labels — routed by WHAT the human must do

`stalled` is reserved for genuine pipeline failures; a human wait is a park, and the label routes by shape:

- A **decision** the pipeline may not make — a product, design, or business call surfaced mid-implementation,
  mid-review, or at merge time — parks under `needs decision`. The decision lands, the label clears, an agent ships it.
  The keeper sweeps this label with `/spec` looking for a question to answer.
- A **human-performed step** — credentials, console or vendor-UI work, outreach, production data remediation, a
  product sign-off — parks under `human`. No recorded answer hands it back; a person must act.

A capability park mislabeled `needs decision` wastes the keeper's sweep while the real to-do stays invisible; route by
the park comment's own words.

### Park mechanics

In the failure marking's ordering slots (comment → label → release → state file):

1. Post the comment naming the specific decision or the specific human step.
2. Apply the routed label: `~/.claude/scripts/linear-add-label.sh <ISSUE-ID> <label>`; exit 2 → the label may not
   exist: `linear-cli labels create "<label>" -t issue`, then retry once.
3. Move the issue back to `Planned` and unassign it — `linear-cli issues update <ISSUE-ID> -s Planned`, then
   `issues assign <ISSUE-ID>` with no user. The board must not show a dead session as active work.
4. Release the worktree stamp (`wt-disown.sh`), preserving the worktree and its commits for resumption.
5. Write the state file. The tag's normal row still governs the counters and lists — only the outward marking changes.

End state, shared with the durable decline below: `Planned` + `specified` + the routed label, unassigned, worktree
preserved when one exists. `next-candidates.sh` hides both labels from every ranking, so no session re-picks it —
`needs decision` until a human decides and clears the label (directly, or via `/spec <ISSUE-ID>`), `human` until the
person acts (or `/spec` re-scopes the agent-shippable slice out). The comment plus worktree carry the partial-work
signal.

## A refusal of the pipeline's own step is a stall, never a park

When the stop's cause is that the run was denied a mechanical action on its own deliverable — the auto-mode permission
classifier refusing an edit to a shared repo file, a pre-commit hook rejecting the commit, a guard refusing the merge —
nothing product-shaped waits on anyone: the work is finished or in progress in the worktree, and a human re-runs the
same step with the permission the run lacked. That is the failure row — `stalled`, In Progress, worktree preserved —
not `human`. `human` promises that no mode of any skill ships the issue and that it clears only by re-scoping through
`/spec`, both false here, and it tells the operator there is a to-do where there is a recovery: `fleet-status.sh` and
`/auto-prep`'s unblock list read `stalled` as abandoned mid-flight (resume or release), while a Planned `human` issue
reads as a person's pending task with nothing in flight. "A sign-off" in the human-step list means a product sign-off —
a customer's, a compliance owner's — never approval of the run's own edit.

## A durable decline marks the routed gate label; a transient one stays run-scoped

`SKIPPED-BLOCKED` covers two different things, and only one should survive this run.

**Transient** — a live sibling owns the worktree, the issue is In Progress under someone else, a blocker `/next` missed
is still open — is NOT written to `skipped` at all. Step 2 excludes every `skipped` entry for the rest of the run, so a
run-scoped entry would make a transient decline permanent for the session that recorded it, and the session would
refuse the issue after shipping its blocker itself. The condition clears on its own and the issue must stay eligible:
say so in the iteration's tag line, write nothing to the ledger.

**Durable** — the issue as written is not unattended-shippable: a product or design decision with no testable success
criteria, work needing credentials, console or vendor access, or a human note on the issue saying it must not ship
unattended. This is `/auto-prep`'s gated disposition, routed by the same shape test as the park above: decision-shaped
(a do-not-ship-unattended note included) → `needs decision`; a human-performed step (credentials, console or vendor
access is this, not a decision) → `human`. Record it where `/next` can see it — skip lists are per-session,
`next-candidates.sh` ranks on labels, states and relations only, and a comment is invisible to it, so an unmarked
decline is ranked first again and a fresh session re-pays `/start`'s worktree create and install to re-decline it,
leaving an empty worktree behind:

1. Post a comment naming the specific decision or access needed and what would clear it.
2. Apply the routed label (`linear-add-label.sh <ISSUE-ID> 'needs decision'` or `… human`; exit 2 → create the label,
   retry once). Comment before label, per the failure rows' outward-markers-first ordering.
3. Remove the worktree if `/start` created one before declining:
   `git worktree remove .claude/worktrees/<issue-id-lowercased> && git branch -D <branch>`.

The issue keeps `specified` — the spec is gated, not wrong. Never mark a transient skip, and never mark on a reason you
cannot state in one sentence: when unsure whether a decline is durable, append the run-scoped `skipped` entry without
a label — this session moves on, and the next session re-judges it.
