# Filing a Linear Issue as an Agent

Every issue an agent files on its own initiative takes this recipe, whatever skill prompted it: a deferred review item,
a `/finish` promise, a record a project convention asks for ("file the flake you re-ran past"), a boundary route-out,
an ad-hoc follow-up noticed on the way out. A one-line convention that says *file it* names the trigger, never the
procedure. Five obligations travel together, and a filing made outside the recipe routinely drops all five: search
before filing; create through `linear-create-child.sh` under the originating issue; class labels and a priority at
create; collision edges; a routing label last. The body shape and the label semantics are
[issue-spec.md](issue-spec.md)'s. File items one at a time, in order, so a failure splits the set cleanly into filed,
failed and never-attempted.

## 1. Search before filing

Probe for an open issue already covering the defect: `linear-cli search issues "<token>"` with the finding's most
distinctive identifiers, the file's basename when it is distinctive and the predicate or operation, **one token per
call**, two or three calls, never several words in one. `search issues` matches a contiguous phrase, so two identifiers
that are not adjacent in the target match nothing and exit 0, indistinguishable from a clean result, and a query worded
as a description of the defect is a guaranteed empty one (linear skill gotcha #14). Also check the current run's
already-filed list. On a hit:

- **Same root cause** → do not create. Append the evidence as a comment (`~/.claude/scripts/linear-post.sh comment`),
  raise its priority or labels if the new evidence warrants it, and record `<ID> (existing — evidence appended)`; a
  dedup counts as filed, not dropped.
- **Adjacent but distinct** → file, then `linear-cli relations add <new> <existing> -r related`. When the hit is open
  against the same file, the new item will be `specified`, and the hit is itself `specified` (not uncertified, not
  `needs decision`, not `solo`), wire `linear-cli relations add <existing> <new> -r blocks` instead: existing blocks new,
  the no-discernible-order default. Behind a blocker that never ships unattended, keep `related`. If the hit already
  sits in a chain, read `linear-cli relations list <hit>` (both `.relations[]` and `.inverseRelations[]`) and attach at
  the tail ([issue-spec.md](issue-spec.md) § Certification includes collision edges).
- **Superseded** (same gap, but the hit's premise has dissolved) → file the successor with the fresh evidence, then
  `linear-cli relations add <OLD> <NEW> -r duplicate` (the first argument becomes the Duplicate and auto-closes) with a
  one-line comment naming what dissolved; or, when the hit is certified and its spec still fits, refresh it instead of
  filing. Never leave two open owners of one gap.
- **Terminal** (Done or Canceled, judged by state *name*) → never blocks the filing, but the body names it:
  `Prior art: <ID> (Done): <its fix's scope>; filing because <what still fails>`, so the groomer can ask whether the fix
  regressed or never covered this path.
- **`In Progress`, or `specified` and fleet-pickable** → its fix may absorb this finding even when its body describes a
  different defect. Add `Verify against <ID> once it ships: its fix may absorb this.` to the body and record the item as
  `<new> (may be absorbed by <ID>)`; do not hold the filing and do not fetch the sibling's plan.

A dedup inherits the hit's premise. Grep the file for the code its Problem quotes; if that code is gone,
`git log -S '<quoted string>' -- <file>` names the sibling that removed it. Re-ask the root-cause question against
current code before appending or citing the issue from a code comment, and name the claim that no longer holds.

## 2. Write the body

`mkdir -p tmp` once, then `Write` the description to a fixed per-item path under the worktree's `tmp/`:
`tmp/linear-filing-<slug>.md`, where `<slug>` is the finding's own distinctive token, so concurrent sessions in different
worktrees never share a path. a `mktemp -u` command substitution is refused in worktree-isolated sessions
([git-worktrees.md](git-worktrees.md)), and a pre-created empty file makes the Write tool refuse the write. Pass the
helper the same **absolute** path the Write used: Bash cwd drifts across tool calls, and a relative path then fails the
helper's `body file not found` pre-flight. Confirm the Write landed content; an empty body file files a zero-byte
description without error.

The body is the compact certifiable shape of [issue-spec.md](issue-spec.md): `## Problem` as a story with the
measurements and `file:line` under `## Evidence`, `## Desired Outcome`, `## Success Criteria` as checkboxes, and an
optional `## Boundaries` that excludes deliverables, never mechanisms, when the root cause is undiagnosed (`(decided:
<who/why>)` only when relaying a human's recorded call; never author `(assumed)`). The title carries no severity prefix
and no routing word: the priority field carries the grade and the label carries the route. When a criterion cites a
measurement this run produced (a repro rate, a baseline count, a remedy matrix), paste the runnable apparatus into the
body or a comment, or commit it where the repo keeps such scripts; a prose summary makes the next session re-pay the
whole setup before it can confirm the problem exists.

**A genuine human pick** (a product or design call, two defensible behaviors nothing pins) files without `specified`,
with `needs decision` in the create's label arg beside any class label, and the body saying what must be decided. An
empirical question the session could not settle is not a pick: write it as a directed measurement with the response to
each outcome prescribed, and certify. Before filing a decision, read the decisions on the worked issue and on every
ancestor in its parent chain (`linear-cli issues get <ID> -o json | jq -r .description` per ancestor; the digest lists
them by title only). One that already answers the question is filed as a request to reopen it: quote the decision and
the issue that records it, state the evidence it did not weigh, and close with the two outcomes (it stands, cancel this
issue citing it; it is reversed, record the reversal there and keep this issue as the work). Skip every `blocks` edge for
a decision filing and wire `related` instead. **Human-performed work** files with `human` in the label arg the same way,
keeping `specified` when the body meets the bar.

## 3. Create through the helper

```bash
~/.claude/scripts/linear-create-child.sh --allow-unrouted [--allow-planned] <PARENT|-> <TEAM> <Backlog|Planned> "<title>" /abs/path/tmp/linear-filing-<slug>.md <class-labels|-> <1|2|3> >| tmp/linear-filing-<slug>.id; echo "EXIT=$?"
```

Read the id back with `cat tmp/linear-filing-<slug>.id`; empty means no issue exists. The `EXIT=` line, printed in the
same call before anything else runs, is what the exit-status rules below branch on.

- **Parent**: the originating issue, or `-` for a top-level issue when the context has none; never invent one. The helper
  creates the issue, links the parent with `relations parent`, and verifies the link, failing hard on an orphan.
  `linear-cli issues create` has no `--parent` flag, and a hand-rolled create-then-link is skipped or silently fails
  when filing several in a row, so never hand-roll it. Parent linkage does not make the parent an epic.
- **State**: `Backlog` by default; the human curates Planned. `Planned`, behind the leading `--allow-planned`, only for
  a Critical/High item (priority 1–2) or one taking the `security` class label; the flag is the audit record that the
  placement was asserted at file time. Never Triage: an omitted state lands in the team default, which on a
  triage-enabled team is Triage, invisible to `/next` and `/auto`. If the team rejects both names,
  `linear-cli statuses list -t <TEAM>` and take the first state matching `/^(planned|backlog|to.?do)$/i` exactly (never
  a `ready` prefix, which latches onto release and review states); with no match, ask which state is "ready to work, not
  yet prioritized" rather than falling through to the default (an unattended run files into the default and records
  the deviation).
- **Class labels**, comma-separated in one slot, each applied independently: `security` (unauthorized access or
  disclosure, a viewer-scoping leak, PII exposure, a cross-boundary write, including latent ones a code change would
  make reachable); `bug` (a behavioral defect of shipped code; a live security defect is `security,bug`); neither for
  coverage gaps, hardening and docs, which must not jump the queue disguised as defects. A parent carrying `security`
  whose child's Problem is the same failure class passes it on: labels do not propagate through the create, and the
  child's own label sets its rank and its Planned-at-birth state. `simple` when the item is Medium, takes no `security`,
  is not a decision or `human` filing, and the concrete remedy passes [issue-spec.md](issue-spec.md) § The `simple`
  label's risk test under the mechanical-lane bound (no choice between valid alternatives, a single file or subject plus
  spec, no public contract or schema change, roughly under 15 lines, checkable by the project check plus a targeted run);
  doubt means no label. `deploy-gated` (§ The `deploy-gated` label) when the body's own criteria wait on a release rather
  than a merge; it goes in the create, like `needs decision`, so the gate exists before the item is pickable, and it reads
  the parent→child `blocks` edge below or a `blocks` edge from the release issue when the parent is not it. `needs
  decision` and `human` go here too (step 2). `specified` never goes in the create (step 5). A reply token such as
  `suggested` is never a label; the helper refuses an unknown label (exit 2) rather than minting it.
- **Priority** is required: Critical → 1, High → 2, Medium → 3. A severity in the title or body is invisible to
  `/next`'s ranking, which reads the field.

### Exit status

The helper prints the id on every path where the issue was created; empty stdout means no issue exists.

- **0**: filed and parent-linked.
- **2**: filed and linked, a class label did not attach. Keep it, annotate
  `(<label> not attached — add manually: ~/.claude/scripts/linear-add-label.sh <ID> <label>)`, continue.
- **3** (or **4**, which is 3 plus 2): the parent is at Linear's sub-issue nesting cap (10 ancestors), so the helper
  wired a `related` peer edge instead. The issue is filed and usable: skip the parent re-query for it, annotate
  `(related, not sub-issue — parent at Linear's nesting cap)`, continue.
- **1 with an id on stdout**: the issue exists but its state or linkage could not be established; stderr says which.
  Record it with stderr's first line and continue.
- **1 with no id, stderr naming a local precondition** (`body file not found`, the `usage:` line, `priority must be 0-4`,
  `refusing to file UNROUTED`, `refusing caller-passed state 'Planned'`): a pre-flight refusal. Nothing was created;
  correct the invocation, re-run the same create, continue. `linear-file-improvement.sh` and `linear-post.sh` carry the
  same pre-flight and the same `body file not found` string.
- **1 with no id and `failed to create issue`, `issue created but no identifier returned`, or `'<cmd>' not found on
  PATH`**: the create itself failed and the issue may or may not exist. **Stop filing**: the remaining creates would run
  against the same failing API, widening the set whose existence is uncertain. Record the item as unfiled with
  stderr's first line (`the issue may exist unlinked; check Linear, then re-file or link manually`) and every later item
  as not attempted. An unreadable body file surfaces here too (the pre-flight tests existence only), which is the
  correct conservative branch.

After each create, re-verify the link from outside the helper: `linear-cli issues get <ID> -o json | jq -r
'.parent.identifier'` prints the parent. If that read errors or prints `null` after an exit-0 create, the issue exists
and is tracked: annotate `(parent link unverified — confirm or re-link: linear-cli relations parent <ID> <PARENT>)` and
continue; each later create verifies itself independently.

## 4. Wire collision edges

- **Parent → child**: `linear-cli relations add <PARENT> <ID> -r blocks` for every item that will be `specified`, hence
  fleet-pickable, while the parent is still in flight. The parent's work has not reached the source branch, and
  `next-candidates.sh` otherwise ranks a child of an In Progress parent best. The edge self-clears when `/finish` moves
  the parent to Ready For Release. Skip it for a `-` parent, a nesting-cap peer, a decision filing, and when the caller's
  run is already failing (the parent then stalls and the edge would strand the child). A `human` route-out whose act is
  performed on what the parent ships (a deploy of its stack, a verification on an environment running its code) takes
  this edge whether or not it is `specified`, since the person's act waits on the code; one whose act needs none of the
  parent's code (a vendor template, a secret, a DNS record) takes `-r related`.
- **Across a batch of two or more**: group the new issues by the files and the enclosing methods their findings name.
  One method body, or one item's fix a prerequisite of another's → chain in filed order with `blocks`, adjacent pairs
  only. Same file only → `related` between adjacent pairs; `next-candidates.sh` soft-de-ranks a candidate whose
  `related` partner is in flight and `/finish` gates the merged tree, so same-file siblings may ship concurrently.

Edges are best-effort: a failed `relations add` annotates the item (`collision edge to <ID> not wired — add manually`)
and never stops filing or changes a verdict.

## 5. Certify last

`specified` is what makes an item pickable, and under `/auto`'s hot-handoff rule a session's own filing is its very next
pick, so it goes on after every edge above is wired: `~/.claude/scripts/linear-add-label.sh <ID> specified` per item. The
state was set at create; the column is not the race, the label is. `specified` is workspace-level and always exists, so
the helper's exit 2 here means "could not confirm": annotate and do not retry. Certify on the bar, not on convenience: a
body below [issue-spec.md](issue-spec.md)'s quality bar is rewritten while the evidence is hot (verify the mechanism, or
write the open empirical question as a directed measurement), and only a genuine human pick withholds the label (step 2).

Every filing ends carrying a routing label some consumer reads, `specified`, `needs decision`, `human` or `keeper`,
never a class label alone ([issue-spec.md](issue-spec.md) § An agent filing never lands unrouted). Two gates enforce it:
`quality-review-write-verdict.sh` reads every id on a verdict's `Deferred filed as issues:` line back from Linear and
exits 3 on one with no routing label or priority None (route it with the two commands its stderr names, then re-run the
same call), and `linear-create-child.sh` refuses a label slot with no routing label unless the call passes
`--allow-unrouted`, which is why only a caller that certifies in a later step of the same run passes it. A sibling filed
unrouted is not precedent: route the new filing, and route the sibling while you are there.

## 6. Record

Each item lands in exactly one place in the caller's record (`Deferred filed as issues`, `Deferred dropped`, `Open
items`, or the skill's equivalent) with its annotations. The caller supplies what this recipe does not: the finding's
severity (the priority and the state), its provenance (the parent, the verbatim finding and its evidence), and its
disposition.
