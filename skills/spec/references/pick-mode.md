# Pick mode — presenting the uncertified roster

Read this for the no-arg form (`/spec` Step 1) and for every subsequent pick in the same session.

## The roster

Team scope resolves mechanically, exactly like `/next` Step 2: `$LINEAR_TEAM` if exported (single key or comma list),
else omit `--team` and the script searches every team — never ask which team. A user who explicitly names a team is the
one exception (`--team <KEY>`).

```bash
~/.claude/scripts/next-candidates.sh --exclude-label specified --include-triage --include-blocked --limit 10
~/.claude/scripts/next-candidates.sh --label 'needs decision' --include-blocked --limit 10   # parked issues the first filter hides
```

Same ranking as `/next`, so its hard gates hold: an issue **assigned to anyone else is never offered** (assignment is a
claim — `standards/linear-workflow.md`; the script hides them and appends a hidden-count note, surfaced verbatim). The
ranking is a **strict stage order**: every Planned/Todo issue outranks every Backlog issue, which outranks the entire
**Triage inbox**, priority and class notwithstanding. Triage is included at all (unlike `/next`) because grooming is what
drains it — but only ever last. Blocked issues are included deliberately: certifying before the blocker resolves builds
runway `/auto` picks up the moment it unblocks. The **Planned/Todo queue is exhaustive by construction**: every below-cut
Planned/Todo issue is appended in a trailing **"Planned/Todo below the cut"** section — full roster members. The limit
trims only the Backlog/Triage tail; raise it for a large inbox. Issues parked behind a human decision keep `specified`
plus `needs decision`, so the exclude filter hides them — the second invocation lists them.

## Three buckets, fixed order

**Present the roster as three stage buckets — Planned, Backlog, Triage — never one mixed list.** Certify ALL of Planned
first, then all of Backlog, and look at the inbox only once both are empty; the buckets exist so the user can SEE that a
stage is drained. Membership comes from each entry's `State:` line.

- Each bucket renders as its own numbered list — `ID — title` plus a clause on why it ranks (tier, priority,
  blocked-but-certifiable), never a prose paragraph — with that bucket's parked (`needs decision`) issues directly
  beneath it in the SAME rendering. A parked issue compressed into a sentence gets missed and re-asked; grooming one
  means recording the decision in the interview, after which certification clears the label (Step 6 item 5).
- An empty bucket still renders, as its one-line proof — `Planned: fully certified, nothing parked.`
- Then AskUserQuestion with options drawn from the **first non-empty bucket only**, top-ranked first, the recommendation
  its top item — parked issues included as options when they outrank the uncertified ones. Never offer or recommend a
  Backlog issue while the Planned bucket holds any candidate (uncertified or parked), nor a Triage issue while either
  earlier bucket does; `Other` covers a deliberate out-of-order pick.
- **One exception, rendered inside the Planned bucket:** a Backlog issue that BLOCKS a Planned candidate is Planned work
  in waiting — when a Planned candidate shows unresolved blockers, resolve them
  (`~/.claude/scripts/linear-deps-graph.sh <ID>`) and list any Backlog blocker in the Planned bucket annotated
  `Backlog — blocks <Planned-ID>`, fully eligible; certifying it includes promoting it to Planned (Step 6 item 4).
- The dialog must be legible on its own — a bare-ID option list sends the user to Linear to find out what they are
  choosing.
- All three buckets empty → `Everything workable is already certified.` and stop.

## After each certification

Re-run the roster and re-render the full three-bucket presentation for every subsequent pick, so the state of every
stage stays visible. When a certification just DRAINED a bucket (nothing uncertified, nothing parked left in it),
announce the milestone as its own line before offering anything further — `Planned is fully certified — moving to
Backlog.` / `Backlog is fully certified — the Triage inbox is next.` The milestone is the point of the bucket order, not
a footnote.
