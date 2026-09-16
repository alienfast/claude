---
name: sentry
description: |
  Queue-driven Sentry triage for whichever project the session is in — rank unresolved production
  issues by users affected and event volume, deep-dive each, and drive the queue to zero through
  dispositions: file a spec-shaped Linear issue on the project's team ($LINEAR_TEAM), archive noise,
  resolve already-fixed, merge duplicates, or hand off to the project's /investigate skill. Also syncs
  the loop closed: shipped Linear issues get their Sentry issue resolved in-release. Resolves the Sentry
  org/project from the checkout (the CLI's own DSN auto-detection, or the project's
  .claude/rules/sentry.md) and reads that rule for the project's environments, release model, and
  attribution notes. Reads and mutations both run unconfirmed and are reported after the fact. Uses
  the agentic `sentry` CLI (cli.sentry.dev) — never Seer. Use when the user says 'sentry next',
  'sentry triage', 'sentry sweep', 'work the sentry queue', 'sentry PROJECT-123', 'triage sentry
  issues', or invokes /sentry.
---

# sentry

Work the Sentry unresolved queue to zero, most-impactful first, with Linear as the system of record for anything needing a fix. Linear drives the workflow (`/auto`, `/start`, `/finish` pick up from there); Sentry state (archive/resolve/merge) tracks what needs no code. The skill is the judgment filter between Sentry's alert stream and the kanban the business watches — alert-rule auto-filing is deliberately not used.

**Safety stance:** Sentry reads and **mutations** (resolve, archive, merge, posting notes) both run as ordinary skill work — nothing is held for approval, and the disposition table is a report, not a request. What makes that safe is reversibility, measured against this CLI: `resolve` has a first-class inverse (`unresolve`, alias `reopen`), `archive` (alias `ignore`) is reversed the same way, an `--until <cond>` archive un-archives itself on escalation, and notes are additive. `merge` is the one-way door — `sentry issue --help` lists no `unmerge` — so choose the canonical issue deliberately and name the children in the report; it is a caution, not a gate. Linear filing is normal skill work.

The harness gates what this prose cannot: in auto mode every `sentry issue resolve | archive | merge` and `sentry api` call is classified as an external write and refused unless a permission rule allows the command, and in default mode each one prompts. The mutation batch therefore needs `Bash(sentry issue resolve:*)`, `Bash(sentry issue archive:*)`, `Bash(sentry issue merge:*)` and `Bash(sentry api:*)` in `~/.claude/settings.json`, beside the Linear rules — `sentry api` whole, since a rule cannot see the `-X POST` flag, and no rule for reads, which pass the classifier on their own. Measured 2026-09-16 on bfp-control-panel, where a user-authorised `sentry issue resolve` was refused mid-run with `[External System Writes]`.

## Project context — read before anything else

This skill is project-agnostic; the project supplies its facts through **`<repo root>/.claude/rules/sentry.md`**. Read it first when it exists. It declares the `org/project` target and short-id prefix, the environments and which one is triage scope, the release model (what `resolve --in` takes and the post-release `period:` knob), the Linear team and filing conventions, the investigation handoff target, performance-attribution notes, and what the project's scrubbers remove from events. Every step below says "the rule" for these.

Without a rule, the defaults are: the target is whatever the CLI resolves on its own (run from the repo root — it auto-detects from the DSN or config under the cwd, and honors `SENTRY_ORG`/`SENTRY_PROJECT`; a fresh worktree may lack the DSN file, in which case pass `org/project` explicitly), triage scope is `environment:production`, resolution is `--in @next`, the Linear team is `$LINEAR_TEAM`, and a **Needs investigation** disposition records the identifiers in the report and stops, since there is no handoff target.

## Modes

- `/sentry` or `/sentry next` — sync pass, ranked queue, then deep-dive + disposition the **top** unhandled issue.
- `/sentry <issue>` — deep-dive + disposition one issue (short id, numeric id, or Sentry URL).
- `/sentry sweep` — sync pass, then walk the ranked queue dispositioning until the list is drained or the user stops.

Optional argument `period:<spec>` overrides the ranking window (`14d` default; `>=YYYY-MM-DD` after a release — see Ranking). Optional `env:<name>` widens scope to a non-production environment the rule describes.

## Workflow

### 1. Pre-flight

```bash
~/.claude/skills/sentry/scripts/preflight.sh [<org/project>]
```

Pass the target the rule declares. The script probes a real issue read (never `auth status` — a CI release token passes that and 403s on the first query) and prints the short-id prefix it resolved, which is the check that the right project was detected. Non-zero exit → stop immediately and show the block (the fix is usually the project's `.claude/update.sh` then `sentry auth login`). Linear access follows the `/linear` skill (read it before any Linear command — it owns the CLI usage and gotchas).

### 2. Sync pass (close the loop from prior runs)

The primary resolve happens at fix time — each filed issue's success criteria carry the `sentry issue resolve ... --in @next` command for the implementing session (see [triage.md](./references/triage.md), Resolution lifecycle). This pass is the safety net: reconcile before ranking, so the queue reflects reality:

1. Pull Linear issues on `$LINEAR_TEAM` labeled `sentry` in Done / Ready For Release; extract each one's short-id link from its description.
2. For any whose Sentry issue is still unresolved → queue `sentry issue resolve <short-id> --in <release>` (the release that shipped the fix; `@next` when not yet released) into the mutation batch.
3. Report drift the other way too: a previously-filed Sentry issue that has **regressed** (new events after resolve) reopens the Linear conversation — comment on the Linear issue rather than silently re-filing.

### 3. Rank the queue

Two pulls, merged (recipes and the exact commands: [triage.md](./references/triage.md)):

```bash
sentry issue list [<org/project>] \
  --query "is:unresolved environment:production !issue.type:[performance_n_plus_one_db_queries,performance_slow_db_query,performance_n_plus_one_api_calls]" \
  --sort user --period <window> --limit 50 --json --fields shortId,title,userCount,count,level,priority,firstSeen,lastSeen,culprit,isUnhandled
# and the same with --sort freq
```

Order: `userCount` desc, then `count` desc. Default window `14d`; **after a release, pass `period:>=<release-date>`** so pre-release noise doesn't outrank post-release reality (counts are computed over the queried window). Non-production environments are out of scope unless explicitly asked; the rule says what they carry.

Performance issues are excluded in the **query** rather than dropped from the merged JSON: both pulls are a server-side top-N, so a client-side filter would leave them consuming slots error issues should have had. They carry no users, rank on a different key, and get their own pull — [triage.md § Performance queue](./references/triage.md#performance-queue).

Then dedupe against Linear: search Linear for each short-id; issues already filed are shown in the table with their Linear identifier and skipped by `next`/`sweep`.

Present the ranked table (short-id, title, users, events, first seen, priority, Linear link) before diving, and the performance queue as a **second** table (short-id, repeating spans, events, normalized SQL, Linear link) — the two rank on different keys and cannot be ordered against each other. Lead the performance table with the normalized SQL (`event.occurrence.evidenceData.repeatingSpansCompact`, already fetched by the [triage.md recipe](./references/triage.md#performance-queue)); whether the transaction name discriminates at all is a property of the project's architecture, and the rule says.

### 4. Deep-dive one issue

- `sentry issue view <short-id> --json` — metadata, culprit, assignedTo, substatus.
- `sentry issue events <short-id> --full --json` — full event bodies: `entries[]` (`exception` → `stacktrace.frames` with source context, `request` → URL), `tags`, `user`. **`--full` does nothing without `--json`** — the table output is byte-identical with and without it, and the table's footer suggests `sentry event view <EVENT_ID>` against ids it has truncated to 12 chars, which cannot be followed as printed (see [cli.md](./references/cli.md)). For just the newest event's body, `sentry api "issues/<numeric-id>/events/latest/"`.
- Read the implicated code in this repo. Root-cause by measurement, under the project's planning rules where it has them — a claim about what the code does is measured, not reasoned; the stack frame is a starting point, not a conclusion.
- Read absence correctly: the rule says what the project's scrubbers strip from events (a missing email or a `user` reduced to an id is usually the scrubber, not a bug).
- Correlate when needed through the project's investigation surfaces — the rule names them.
- **A performance issue carries none of the above.** `entries[]` is `["spans"]` — no `exception`, no `request` — and `user` is null, so there is no stacktrace or request URL to read. Deep-dive it via [triage.md § Dispositioning a performance issue](./references/triage.md#dispositioning-a-performance-issue) instead: attribution is by matching the normalized SQL to call sites in this repo, guided by the rule's attribution notes.

### 5. Disposition

Exactly one per issue (definitions and edge cases: [triage.md](./references/triage.md)):

| Disposition | Action |
| --- | --- |
| **Fix** | File a spec-shaped Linear issue (template in triage.md) via `linear-create-child.sh --allow-planned - $LINEAR_TEAM Planned … sentry` — never a raw `issues create`; always labeled `sentry`; bidirectional links. Certify `specified` only when the root cause is measured — then it's `/auto`-eligible. |
| **Noise** | `sentry issue archive <id> --until <escalation>` with a one-line recorded rationale. |
| **Already fixed** | Link the in-flight/shipped Linear issue; `sentry issue resolve <id> --in <release>` (or `--in @next` when unreleased). |
| **Duplicate** | `sentry issue merge <children...> --into <canonical>`. **Not for a performance issue** — the API rejects merging `performance_*` issues; join same-cause fingerprints in one Linear issue instead ([triage.md § Dispositioning a performance issue](./references/triage.md#dispositioning-a-performance-issue)). |
| **Needs investigation** | Hand off to the project's `/investigate` skill with the correlation identifiers the rule names; without one, record the identifiers in the report. The Sentry issue stays unresolved either way. |

In `sweep`, collect dispositions across the walk; in `next`, it's a table of one plus anything the sync pass queued.

### 6. Execute

Execute the dispositions straight through: the Sentry mutations, then the Linear filings, then post each filed issue's Linear identifier back onto its Sentry issue as a note:

```bash
sentry api "issues/<numeric-id>/comments/" -X POST -d '{"text":"Linear: <TEAM>-XXXX — <linear url>"}'
```

(Numeric ID from `sentry issue view <short-id> --json --fields id`.) **A performance issue refuses this endpoint** (403 as a JSON body at exit 0 — see [triage.md § Dispositioning a performance issue](./references/triage.md#dispositioning-a-performance-issue)), so its back-link lives in Linear alone; on an error issue, read `.id` from the response to confirm the note landed.

`-X POST` is required — `sentry api` defaults to GET and `-d` does not imply POST the way `curl -d` does. Without it the call GETs the comment list, folds the payload into the query string (`?text=Linear%3A+…`), creates nothing, and **exits 0** — so the note silently never lands. Confirm with `sentry api … --dry-run`, which prints the resolved method and body without sending.

### 7. Report

Chat summary: queue depth before/after, dispositions taken, Linear issues filed (with links), what remains and why. No findings file — Linear issues and Sentry state *are* the durable record.

**Every narrative finding carries its own Linear key inline — a summary table upstream does not discharge this.** A prose section explaining a root cause is the part a reader acts on, so it must name the issue that finding was filed as, in that paragraph, not one section away. Putting the identifiers in a "Filed" table and then writing the findings as pure mechanism commentary makes the reader join the two by hand, and the join is exactly what a skim drops.

**Label any issue that is referenced but is NOT the finding's own issue.** A related, prior-art, or same-mechanism-different-subject issue must be marked as such (`related — different policy`, `prior art, Done`), never dropped in bare. The failure mode was observed: a findings section named a pre-existing Backlog issue on a *different* policy while the issue actually filed for that finding went unnamed, so the section's only key pointed away from the deliverable and the filed work read as unfiled. One bare key in a paragraph is read as *the* issue for that paragraph.

When a finding has no Linear issue (dispositioned **Noise**, **Duplicate**, or **Needs investigation**), say so explicitly — `not filed: <disposition>, because <reason>` — so an absent key is never ambiguous with an omitted one.

## What this skill is not

- Not `/investigate` — that's symptom-driven, cross-layer, and read-only; this is queue-driven and mutation-bearing. Each hands off to the other, and a project without an investigate skill gets the identifiers in the report instead.
- Not Seer — `sentry issue explain`/`plan` invoke a paid metered add-on and are never used; the repo, the project's rules, and the review pipeline are the analysis engine.
- Not an auto-filer — nothing lands in Linear without a deep-dive behind it, and Sentry alert rules must not be configured to create Linear issues.

## Reference files

- [references/triage.md](./references/triage.md) — ranking recipes, the performance queue, disposition definitions, the Linear issue template, resolve/archive semantics, Linear↔Sentry linking conventions.
- [references/cli.md](./references/cli.md) — CLI prerequisites and auth precedence, target resolution, query syntax, JSON output shapes, the traps.
- `<repo root>/.claude/rules/sentry.md` — the project's own facts; the file this skill reads first.
