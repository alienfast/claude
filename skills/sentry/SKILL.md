---
name: sentry
description: Queue-driven Sentry triage for the current project — rank unresolved production issues by users and events, deep-dive each, and dispose (file a spec-shaped Linear issue, archive, resolve, merge, or hand off to /investigate), then reconcile shipped fixes and placement. Modes `next` (default), `<issue>`, `sweep`. Uses the `sentry` CLI, never Seer. Use when the user says 'sentry next', 'sentry sweep', 'sentry PROJECT-123', or invokes /sentry.
---

# sentry

Work the Sentry unresolved queue to zero, most-impactful first, with Linear as the system of record for anything needing
a fix. Linear drives the workflow (`/auto`, `/start`, `/finish` pick up from there); Sentry state (archive/resolve/merge)
tracks what needs no code. The skill is the judgment filter between Sentry's alert stream and the kanban the business
watches — alert-rule auto-filing is deliberately not used.

**Safety stance:** Sentry reads and **mutations** (resolve, archive, merge, linking a Linear issue) both run as ordinary
skill work — nothing is held for approval, and the disposition table is a report, not a request. What makes that safe is
reversibility: `resolve` has a first-class inverse (`unresolve`, alias `reopen`), `archive` (alias `ignore`) is reversed
the same way, an `--until <cond>` archive un-archives itself on escalation, and an external-issue link is idempotent for
the same Sentry/Linear pair and has a documented `DELETE`; the one non-idempotent case, a second Linear owner for the
same Sentry issue, is refused by the link script (Step 7). `merge` is the one-way door — there is no `unmerge` — so
choose the canonical issue deliberately and name the children in the report; a caution, not a gate. Linear filing is
normal skill work, as are the Linear state moves and `related` edges Step 6 applies — a state move is one
`issues update --state` away from undone, and an edge is `relations remove`.

The harness gates what this prose cannot: in auto mode every `sentry issue resolve | archive | merge` and `sentry api`
call is classified as an external write and refused unless a permission rule allows the command, and in default mode each
one prompts. The mutation batch therefore needs `Bash(sentry issue resolve:*)`, `Bash(sentry issue archive:*)`,
`Bash(sentry issue merge:*)` and `Bash(sentry api:*)` in `~/.claude/settings.json`, beside the Linear rules — `sentry
api` whole, since a rule cannot see the `-X POST` flag, and no rule for reads, which pass the classifier on their own.

## Project context — read before anything else

This skill is project-agnostic; the project supplies its facts through **`<repo root>/.claude/rules/sentry.md`**. Read it
first when it exists. It declares the `org/project` target and short-id prefix, the environments and which one is triage
scope, the release model (what `resolve --in` takes and the post-release `period:` knob), the Linear team and filing
conventions, the investigation handoff target, performance-attribution notes, and what the project's scrubbers remove
from events. Every step below says "the rule" for these.

Without a rule, the defaults are: the target is whatever the CLI resolves on its own (run from the repo root — it
auto-detects from the DSN or config under the cwd, and honors `SENTRY_ORG`/`SENTRY_PROJECT`; a fresh worktree may lack
the DSN file, in which case pass `org/project` explicitly), triage scope is `environment:production`, resolution is
`--in @next`, the Linear team is `$LINEAR_TEAM`, and a **Needs investigation** disposition records the identifiers in
the report and stops.

## Modes

- `/sentry` or `/sentry next` — sync pass, ranked queue, then deep-dive + disposition the **top** unhandled issue.
- `/sentry <issue>` — deep-dive + disposition one issue (short id, numeric id, or Sentry URL).
- `/sentry sweep` — sync pass, then walk the ranked queue dispositioning until the list is drained or the user stops,
  then reconcile every open `sentry` issue's placement against the ranked queue (Step 6) and end on what needs working
  now.

Optional `period:<spec>` overrides the ranking window (`14d` default; `>=YYYY-MM-DD` after a release — see Ranking).
Optional `env:<name>` widens scope to a non-production environment the rule describes.

## Workflow

### 1. Pre-flight

```bash
~/.claude/skills/sentry/scripts/preflight.sh [<org/project>]
```

Pass the target the rule declares. The script probes a real issue read (never `auth status` — a CI release token passes
that and 403s on the first query) and prints the short-id prefix it resolved, which is the check that the right project
was detected. Non-zero exit → stop immediately and show the block (the fix is usually the project's `.claude/update.sh`
then `sentry auth login`). Linear access follows the `/linear` skill (read it before any Linear command).

### 2. Sync pass (close the loop from prior runs)

The primary resolve happens at fix time — each filed issue's success criteria carry the `sentry issue resolve ... --in
@next` command for the implementing session ([triage.md](./references/triage.md), Resolution lifecycle). This pass is
the safety net, run before ranking so the queue reflects reality:

1. Pull Linear issues on `$LINEAR_TEAM` labeled `sentry` in Done / Ready For Release; extract each one's short-id link
   from its description.
2. For any whose Sentry issue is still unresolved → queue `sentry issue resolve <short-id> --in <release>` (the release
   that shipped the fix; `@next` when not yet released) into the mutation batch.
3. Report drift the other way too: a previously-filed Sentry issue that has **regressed** (new events from a release
   carrying the fix; item 4 screens out false ones) reopens the Linear conversation. Comment on the Linear issue rather
   than silently re-filing.
4. **Catch the integration's regression bounces, which item 1 cannot see.** When a linked Sentry issue regresses,
   Linear's Sentry integration moves the Linear issue to Triage within seconds, which takes it out of item 1's states
   whether or not it is labelled. Pull by attachment instead: `linear-cli api query 'query { issues(first: 50, filter: {
   team: { key: { eq: "<TEAM>" } }, state: { type: { eq: "triage" } }, attachments: { sourceType: { eq: "sentry" } } }) {
   nodes { identifier attachments { nodes { url sourceType } } } } }'`. For each hit, take the numeric id from the
   `sentry` attachment URL, read `sentry api "issues/<numeric-id>/activities/"` (the list is under `.activity`), and
   compare the newest `set_regression` entry's `version` with the first release carrying the fix:
   - **Predates the fix:** a false regression. The resolve named an earlier release (a plain resolve names none), and a
     release shipped between them without the fix. Re-resolve `--in <fix release>`. The integration then moves the
     Linear issue out of Triage by itself, into the completed state any resolve drives a linked issue to — not
     necessarily the one it bounced from; restore that by hand when they differ.
   - **No release carries the fix yet:** the events are genuine. Leave both issues as they are and name the pair under
     *Needs work now*; a later run re-checks.
   - **Carries the fix:** a real regression, handled by item 3.

### 3. Rank the queue

Two pulls, merged (recipes and the exact commands: [triage.md](./references/triage.md)):

```bash
sentry issue list [<org/project>] \
  --query "is:unresolved environment:production !issue.type:[performance_n_plus_one_db_queries,performance_slow_db_query,performance_n_plus_one_api_calls]" \
  --sort user --period <window> --limit 50 --json --fields shortId,title,userCount,count,level,priority,firstSeen,lastSeen,culprit,isUnhandled
# and the same with --sort freq
```

Order: `userCount` desc, then `count` desc. Default window `14d`; **after a release, pass `period:>=<release-date>`** so
pre-release noise doesn't outrank post-release reality (counts are computed over the queried window). Non-production
environments are out of scope unless explicitly asked; the rule says what they carry.

Performance issues are excluded in the **query** rather than dropped from the merged JSON: both pulls are a server-side
top-N, so a client-side filter would leave them consuming slots error issues should have had. They carry no users, rank
on a different key, and get their own pull — [triage.md § Performance queue](./references/triage.md#performance-queue).

Then dedupe against Linear: search Linear for each short-id; issues already filed are shown in the table with their
Linear identifier and skipped by `next`/`sweep`.

Present the ranked table (short-id, title, users, events, first seen, priority, Linear link) before diving, and the
performance queue as a **second** table (short-id, repeating spans, events, normalized SQL, Linear link) — the two rank
on different keys and cannot be ordered against each other. Lead the performance table with the normalized SQL
(`event.occurrence.evidenceData.repeatingSpansCompact`, fetched by the triage.md recipe); whether the transaction name
discriminates at all is a property of the project's architecture, and the rule says.

### 4. Deep-dive one issue

- `sentry issue view <short-id> --json` — metadata, culprit, assignedTo, substatus.
- `sentry issue events <short-id> --full --json` — full event bodies: `entries[]` (`exception` → `stacktrace.frames`
  with source context, `request` → URL), `tags`, `user`. **`--full` does nothing without `--json`** — the table output
  is identical with and without it, and its footer suggests `sentry event view <EVENT_ID>` against ids truncated to 12
  chars, which cannot be followed as printed ([cli.md](./references/cli.md)). For just the newest event's body,
  `sentry api "issues/<numeric-id>/events/latest/"`.
- Read the implicated code in this repo. Root-cause by measurement, under the project's planning rules where it has
  them — a claim about what the code does is measured, not reasoned; the stack frame is a starting point, not a
  conclusion.
- Read absence correctly: the rule says what the project's scrubbers strip from events (a missing email or a `user`
  reduced to an id is usually the scrubber, not a bug).
- Correlate when needed through the project's investigation surfaces — the rule names them.
- **A performance issue carries none of the above.** `entries[]` is `["spans"]` — no `exception`, no `request` — and
  `user` is null. Deep-dive it via [triage.md § Dispositioning a performance issue](./references/triage.md#dispositioning-a-performance-issue):
  attribution is by matching the normalized SQL to call sites in this repo, guided by the rule's attribution notes.

### 5. Disposition

Exactly one per issue (definitions and edge cases: [triage.md](./references/triage.md)):

| Disposition | Action |
| --- | --- |
| **Fix** | File a spec-shaped Linear issue (template in triage.md) via `linear-create-child.sh --allow-planned - $LINEAR_TEAM Planned … sentry` — never a raw `issues create`; always labeled `sentry`; bidirectional links. Certify `specified` only when the root cause is measured — then it's `/auto`-eligible. |
| **Noise** | `sentry issue archive <id> --until <escalation>` with a one-line recorded rationale. |
| **Already fixed** | Link the in-flight/shipped Linear issue; `sentry issue resolve <id> --in <release>` (or `--in @next` when unreleased). |
| **Duplicate** | `sentry issue merge <children...> --into <canonical>`. **Not for a performance issue** — the API rejects merging `performance_*` issues; join same-cause fingerprints in one Linear issue instead. |
| **Needs investigation** | Hand off to the project's `/investigate` skill with the correlation identifiers the rule names; without one, record the identifiers in the report. The Sentry issue stays unresolved either way. |

In `sweep`, collect dispositions across the walk; in `next`, it's a table of one plus anything the sync pass queued.

### 6. Reconcile priority

Step 5 decides *whether* an issue exists in Linear; this step decides *where it sits* — across every open
`sentry`-labeled issue the ranked queues resolve to, not only the ones this run filed. A prior run's filing is the usual
candidate: it was placed on the evidence of its day, and the queue has moved since. Apply the moves. Do not ask, and do
not report an issue that stays put.

Walk both ranked tables from Step 3 top-down, resolve each row to its owning Linear issue (the Step 3 dedup already did
this), and compare the issue's state to the row's rank:

- **Up — Backlog → Planned** when the issue owns the top row of either queue on that queue's ranking key (the error
  queue's top user count; the performance queue's top span count), or an **outlier** on that key — a count ≥ 3× the next
  row's. Also up when the issue is the standing fix for a class that has now cost three or more manual archives (a
  `source:runner` family, a recurring transient). Certification is Step 5's bar and is not lowered here — an uncertified
  move-up is normal, and it is what *Needs work now* exists to name.
- **Down — Planned → Backlog** when a Planned issue is uncertified AND its evidence sits at the floor (one user or none,
  single-digit events, no auth / data-integrity / security class) AND the fix is not in flight. An open `blocks` edge
  into it is a second reason down on its own: it cannot be picked regardless, so it only holds the Planned gate.
- **Bundle** when two open issues share a fix mechanism and a file — two per-row policy predicates served by the same
  request cache, two fingerprints under one resolver: wire `related` and name the pair in *Needs work now* as one pick.
  Merging them is content work, `/spec`'s and not this step's.

Everything else stays where it is, silently. Verify each state move with a `--no-cache` re-read — linear gotcha #8:
`issues update --state` can report success without the state changing.

### 7. Execute

Execute the dispositions straight through: the Sentry mutations, then the Linear filings, then link each filed or matched
Linear issue onto its Sentry issue as an **External Link** — the sidebar's "+ Link issue", which also gives the Linear
issue a `sentry` attachment:

```bash
~/.claude/skills/sentry/scripts/link-linear.sh <org/project> <SHORT-ID> <TEAM>-XXXX
```

The script resolves the org's installed `linear` Sentry app, asks its search hook for the Linear issue's uuid, POSTs the
same `external-issue-actions` link the UI form submits, and confirms it on the issue's `external-issues` listing; it
prints `linked: … (external issue <id>, shown as BF#1939)` and exits non-zero with the reason otherwise. Re-running it
for the same pair prints `already linked` without posting. It refuses with exit 8 when the Sentry issue already links a
*different* Linear issue: Sentry keeps one Linear link per issue, and a second link re-points the existing record in
place with no Activity entry, displacing the first owner's sidebar link and leaving its Linear attachment behind; the
second owner's mapping then lives in its Linear description, as a performance issue's does. **Never post the mapping as
a comment instead**: a note lands in Activity, leaves External Links empty, and reaches nothing on the Linear side. **A
performance issue cannot be linked** — the script refuses it with exit 3, because the action endpoint cannot find the
group and its `external-issues` listing 403s — so its mapping lives in the Linear description alone.

### 8. Report

Chat summary, in this order: queue depth before and after, the dispositions taken, the Linear issues filed (with links),
the priority moves applied. **Only what changed.** An issue the ranked table already showed as filed and that this run
left where it was is not reported again. No findings file — Linear issues and Sentry state *are* the durable record.

**Every narrative finding carries its own Linear key inline — a summary table upstream does not discharge this.** A
prose section explaining a root cause is the part a reader acts on, so it names the issue that finding was filed as, in
that paragraph. **Label any issue that is referenced but is NOT the finding's own issue** (`related — different policy`,
`prior art, Done`), never dropped in bare: one bare key in a paragraph is read as *the* issue for that paragraph, and a
section whose only key points away from the deliverable makes the filed work read as unfiled. When a finding has no
Linear issue (**Noise**, **Duplicate**, **Needs investigation**), say so explicitly — `not filed: <disposition>, because
<reason>` — so an absent key is never ambiguous with an omitted one.

**End with `## Needs work now` — always the last section, and always present.** It is the run's answer to "what do I
need to be on top of." One line per item: the Linear key, the single action, and why the queue will not bring it back on
its own. What belongs there, and nothing else:

- an uncertified Planned filing — this run's or a prior run's, including anything Step 6 moved up — holding the `/auto`
  gate; the action is `/spec`
- a bundle Step 6 wired `related`; the action is the merge
- an issue that needs a human decision rather than code and is generating the queue's loudest daily alert (a sweep
  adjudication, a `needs decision` label)
- a fingerprint with users affected whose owning issue is blocked, stranded (Triage, an orphaned state), or unassigned
- a **Needs investigation** disposition's correlation identifiers, so they are not lost with the transcript

Write `## Needs work now — nothing` when the set is empty.

## What this skill is not

- Not `/investigate` — that's symptom-driven, cross-layer, and read-only; this is queue-driven and mutation-bearing. Each
  hands off to the other, and a project without an investigate skill gets the identifiers in the report instead.
- Not Seer — `sentry issue explain`/`plan` invoke a paid metered add-on and are never used; the repo, the project's
  rules, and the review pipeline are the analysis engine.
- Not an auto-filer — nothing lands in Linear without a deep-dive behind it, and Sentry alert rules must not be
  configured to create Linear issues.

## Reference files

- [references/triage.md](./references/triage.md) — ranking recipes, the performance queue, disposition definitions, the
  Linear issue template, resolve/archive semantics, Linear↔Sentry linking conventions.
- [references/cli.md](./references/cli.md) — CLI prerequisites and auth precedence, target resolution, query syntax,
  JSON output shapes, the traps.
- `<repo root>/.claude/rules/sentry.md` — the project's own facts; the file this skill reads first.
