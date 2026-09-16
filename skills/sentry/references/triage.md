# Sentry triage reference

Recipes and conventions for the `/sentry` skill. CLI facts (auth, target resolution, query syntax, JSON shapes) live in [cli.md](./cli.md) — read that first. Project facts — the target, environments, release model, attribution notes — come from the project's `.claude/rules/sentry.md`, referred to below as "the rule".

## Ranking

Two sorted pulls, merged client-side. `--sort user` and `--sort freq` each return a server-side top-N; the union, ordered `userCount` desc then `count` desc, is the triage queue. One pull alone misses issues that are extreme on the other axis.

Performance issues are excluded in the **query**, not dropped from the merged JSON, because each pull is a server-side top-N — a client-side filter would leave them consuming slots that error issues should have had. They carry `userCount: 0` by construction, so they sort below every user-bearing error and then fill the zero-user tail, which is what keeps `next` from ever reaching one. They rank on their own axis instead — see [Performance queue](#performance-queue).

```bash
sentry issue list [<org/project>] \
  --query "is:unresolved environment:production !issue.type:[performance_n_plus_one_db_queries,performance_slow_db_query]" \
  --sort user --period "$WINDOW" --limit 50 --json \
  --fields shortId,title,userCount,count,level,priority,firstSeen,lastSeen,culprit,isUnhandled,permalink
```

Merging the two pulls (redirect each to its own file first; `--json` returns an envelope and `count` is a string — see [cli.md](./cli.md#json-output-shape)):

```bash
jq -s '[.[].data[]] | unique_by(.shortId) | sort_by(-(.userCount), -(.count|tonumber))' user.json freq.json
```

- `$WINDOW`: `14d` default. After a release, `>=<release-date>` — user/event counts are computed **over the queried window**, so this single knob makes the ranking ignore pre-release history while still surfacing old issues that regressed post-release. The rule says how the project names releases and where to read the date.
- `--query` refinements that earn their keep: `is:unresolved is:for_review` (new/escalating only), `release:<name>` (one release's regressions), `!level:warning` (errors only). Syntax is implicit AND; no OR — use `key:[a,b]`.
- Tie-breakers beyond the two counts: `isUnhandled` (crashes outrank handled captures), `priority` (Sentry's own triage signal), recency of `lastSeen`.

## Performance queue

Sentry's performance detectors (N+1 DB queries, slow DB query) are their own queue, pulled with the positive form of the alternation that [Ranking](#ranking) negates:

```bash
mkdir -p tmp
sentry issue list [<org/project>] \
  --query "is:unresolved environment:production issue.type:[performance_n_plus_one_db_queries,performance_slow_db_query]" \
  --sort date --period "$WINDOW" --limit 50 --json \
  --fields shortId,title,count,level,priority,firstSeen,lastSeen,culprit,permalink > tmp/perf.json
```

**The subtype list is exhaustive and has to be maintained by hand — there is no wildcard.** `issue.type:performance_*` is rejected outright (`Error parsing search query: Invalid type value of 'performance_*'`), and `issue.category:performance` matches nothing: the `issueCategory` these issues carry is `db_query`. The `key:[a,b]` alternation is the extensible form, but only across the subtypes actually named in it — **when a new `performance_*` subtype appears it must be added here *and* to the negated copy in [Ranking](#ranking), or it silently re-lands in the ERROR queue.** A subtype absent from `!issue.type:[a,b]` still satisfies that negation, so it re-consumes a server-side top-N slot there — exactly the defect this queue split exists to fix. Measured 2026-09-12: negating only `performance_slow_db_query` returned every live N+1 issue in the error pull.

Ranking is on the offending-span count in `event.occurrence.evidenceData`, reachable in **one** extra call per candidate — not two. `issue list --json` never returns `occurrence` (it is not in `--fields`' allow-list, and unknown fields are dropped silently) and `issue events --full --json` returns `"occurrence": null`, but those two dead ends don't extend to `issue view`: it always pulls the latest event as a nested `event` object, and `evidenceData` lives inside `event.occurrence` — one field-selected call away, keyed on the short-id. `--sort` offers no server-side substitute (`recommended|date|new|freq|user` only), so sort client-side after the one-call hop:

```bash
jq -r '.data[].shortId' tmp/perf.json | while read -r sid; do
  sentry issue view "$sid" --json --fields shortId,event.occurrence.evidenceData | jq -c '
    .event.occurrence.evidenceData as $e
    | {shortId: .shortId,
       spans: (($e.numberRepeatingSpans // $e.numRepeatingSpans // ($e.offenderSpanIds | length | tostring)) | tonumber),
       offenders: ($e.offenderSpanIds | length),
       reps: $e.numPatternRepetitions, size: $e.patternSize,
       transaction: $e.transactionName}'
done | jq -s 'sort_by(-.spans)'
```

`issue view` caches by default (`-f`/`--fresh` bypasses it, per `sentry issue view --help`) — refetch a candidate with `--fresh` if it was mutated earlier in the same run (resolved, merged, archived); `sentry api` has no such cache.

`/sentry` normally runs in the main checkout, where the block above pastes as-is. From a worktree-isolated session (`/start wt`, `/auto`) it does not: the isolation guard refuses `while` loops and `$(…)` command substitution outright. Write it to `tmp/rank-perf.sh` and run `zsh tmp/rank-perf.sh` — script bodies are never analyzed.

**The count comes under two spellings, and the fallback in the recipe above is load-bearing.** Live N+1 occurrences carry either `numberRepeatingSpans` *or* `numRepeatingSpans` — same occurrence type (`1006`, "N+1 Query"), different key sets — and **neither name is a substring of the other**, so a filter written for one silently returns a partial set. Measured 2026-09-12 across every unresolved performance issue in one project: fifteen carried `numberRepeatingSpans` alongside its two factors (`numPatternRepetitions` × `patternSize` = the count, both real numbers), and one carried the short spelling with neither factor — the **top** row of the date-sorted pull. A recipe keyed on the long spelling alone does not fail loudly: inside a `while … done | jq -s` shape, one iteration's `jq` error exits that iteration's own subshell — the loop keeps going, the outer `jq -s` still succeeds on whatever did parse, and the **whole pipeline exits 0** with the row silently missing from the ranked table. `performance_slow_db_query` widens this beyond the two known spellings: a slow-query occurrence has no repeating-span concept to carry either key at all. The `// (.offenderSpanIds | length | tostring)` fallback closes both gaps: `offenderSpanIds | length` equals the coalesced count in every case measured, so it's a real answer rather than a placeholder, and jq's `length` returns `0` for a missing or null array instead of erroring — so a candidate can no longer vanish from its own queue.

Both spellings are **strings** (`"46"`) exactly like `count`, hence `tonumber` — jq refuses to negate a string.

## Dispositioning a performance issue

The [Dispositions](#dispositions) below still apply; four things work differently for a performance issue.

**Attribution is by normalized SQL, not by the span tree, and how far the transaction name gets you is project-specific.** The SQL lives in `occurrence.evidenceData.repeatingSpans`, typed per shape like the count above: an **array** of `db.sql.active_record - <SQL>`-style strings on the `numberRepeatingSpans` shape, a single such **string** on the `numRepeatingSpans` one, so index it only after a `type` check (`.repeatingSpans | if type == "array" then .[] else . end`). Match it to call sites in the repo. In a single-controller GraphQL monolith the transaction name and parent span are the same for every row and discriminate nothing; in a route-per-handler app they name the route outright. The rule records which case the project is, and any tag the project adds to make attribution a one-read job.

**The repeating-span count (`numberRepeatingSpans`, above) is the severity signal; event count is not.** The two are near-orthogonal — one measured pair was 2 events / 54 repeating spans against 14 events / 33 — so ranking on events inverts the true per-request cost. And under a traces sample rate below 1, an event is one *sampled request* whose span tree tripped the detector's threshold, never one slow query: event count measures how often the detector sampled that route, not how expensive the route is. That is the whole justification for ranking this queue on a different key — which is also why the pull above sorts `--sort date` rather than `--sort freq`: a `freq`-sorted pull would let the server-side top-N truncation at `--limit 50` apply the very event-count bias this paragraph argues against, before the client-side span-count sort ever runs, silently dropping a high-span/low-event issue the moment the queue passes 50 candidates.

**`merge` is unavailable — same-cause fingerprints are joined in Linear only.** `sentry issue merge --help` states it: "Only error-type issues can be merged (the API rejects performance/info issues)." The API's reported response body is `400 ["Only error issues can be merged."]`; it has not been verified against a live project, because `merge` is this skill's one irreversible mutation and carries no `--dry-run`. So a **Duplicate** disposition on a performance issue means one owning Linear issue naming every Sentry short-id in its description, with each of them resolved individually at fix time — never a Sentry-side merge.

**Going quiet is not evidence a fix worked.** A performance fingerprint *is* the normalized SQL, so a table or column rename kills the fingerprint outright: Sentry does not resolve it, it simply stops adding events to that issue and opens a new one carrying the new spelling — which arrives looking like a brand-new N+1. Verify a performance fix at the call site rather than on the event stream, and after a release that renamed schema, before filing a fresh-looking N+1, check whether it is the twin of one that just went quiet.

## Linear dedup

Before dispositioning, search Linear for each candidate's short-id — the filing convention below guarantees it appears in the Linear issue description. Follow the `/linear` skill for the commands. An issue with a Linear match is **filed**: show the Linear identifier and state in the queue table; only re-open it (comment, never re-file) when Sentry shows a regression after the Linear issue shipped.

## Dispositions

**Fix** — a real defect needing a code change.

- File one Linear issue per root cause (not per Sentry issue — several fragmented Sentry issues sharing a cause get one Linear issue plus a `merge` disposition).
- Spec shape (per the `/prd`–`/spec` conventions), seeded with measured Sentry evidence:

  ```markdown
  ## Problem
  <what is failing, for whom> Sentry: [<SHORT-ID>](<permalink>) — N users / M events since <window start>.
  <stack frame + file:line in this repo; the measured root cause, or the narrower claim actually confirmed>

  ## Desired Outcome
  <user-visible behavior once fixed>

  ## Success Criteria
  - [ ] <the specific failure mode no longer reproduces / spec covering it>
  - [ ] Sentry issue marked resolved: `sentry issue resolve <SHORT-ID> --in @next`
  ```

  The resolve criterion is the literal command so the implementing session — human or `/auto` — runs it at finish time and checks the box. "No new events post-release" is deliberately NOT a criterion: it's a post-deploy observation no finishing session can verify; the sync pass owns it (see Resolution lifecycle).

- Label `sentry` on **every** issue this skill files or links (create the label on first use) — Step 2's sync pass queries exactly that label, so an unlabelled filing is invisible to the next run's close-the-loop pass. Team `$LINEAR_TEAM` (the project's `.claude/settings.json` exports it). Priority maps from impact: multi-user or auth/data-integrity → Urgent/High.
- File into `Planned`, through the helper — never a raw `linear-cli issues create`:

  ```bash
  ~/.claude/scripts/linear-create-child.sh --allow-planned - "$LINEAR_TEAM" Planned "<title>" tmp/sentry-<short-id>.md <sentry|sentry,specified> <1|2|3>
  ```

  `--allow-planned` is mandatory and leading: the helper refuses a caller-passed `Planned` without it and exits 1 before creating anything. This is not an exception to the keeper's Backlog ruling — that ruling is scoped to **unattended** filings ("the human curates Planned"; `standards/linear-workflow.md` § Stage Priorities, and the same wording in the helper's own refusal message, which names "a human-in-the-loop interactive filing" as a sanctioned reason to pass the flag). `/sentry` is interactive — a human invokes it and reads its report — so it is the same class `/spec` and `/prd` already file to Planned, and a live production defect belongs in the release-scoping column the business watches. The `linear-create-state-guard.sh` hook will not catch a raw create here — it only checks that *some* `--state` is present — so the helper is what makes the placement deliberate and auditable.
- Take one consequence knowingly: an **uncertified** Planned filing holds the Planned gate (`standards/linear-workflow.md` § Stage Priorities — Backlog is withheld, not merely outranked, until the column drains), idling `/auto` until someone grooms or moves it. For a live production defect that pressure is the point, but name any uncertified Planned filing in the Step 7 report so the operator can act on it.
- Certification: add `specified` **only** when the root cause is control-confirmed (a measurement, not a plausible reading) and the fix is unambiguous — that makes it `/auto`-eligible, so the bar is "shippable unattended." Otherwise leave uncertified for `/spec` grooming.
- Bidirectional link: the Linear description carries the Sentry permalink + short-id (above); after filing, post the Linear identifier onto the Sentry issue as a note (`sentry api "issues/<numeric-id>/comments/" -X POST -d '{"text":"Linear: <TEAM>-XXXX — <url>"}'` — `-X POST` is not optional; without it the call silently GETs and exits 0). The note is what makes the mapping visible from the Sentry/Slack side.

**Noise** — expected, self-healing, or third-party-transient events with no actionable fix (scanner probes 404ing, a vendor's flaky 5xx already wrapped in retries, user-typo login failures).

- `sentry issue archive <short-id> --until <cond>` — prefer an escalation condition over silence: `--until "10x/1h"` (unarchive on 10 events in an hour), `--until "3u/24h"` (3 users/day), `--until auto` (Sentry's escalation detection), `--until 14d` (time-boxed). An archive with an escape hatch is a tripwire, not a mute.
- Record the rationale in the disposition table; it goes into the run report. Truly-never-actionable classes are better killed at the SDK (`beforeSend`/`ignoreErrors`/`excluded_exceptions`) — that's a **Fix** disposition on the instrumentation, not a permanent archive.

**Already fixed** — the defect is gone on the source branch or in a shipped release.

- Shipped in release R: `sentry issue resolve <short-id> --in R` (R in the project's release naming — the rule says).
- Merged but unreleased: `sentry issue resolve <short-id> --in @next` — auto-resolves when the next release is finalized.
- Prove it first: "the code moved" is not "the defect is gone" (the premise may have moved: relocate the code by subject, not by line number).

**Duplicate** — same root cause fragmented across issues (common when messages interpolate variable content).

- `sentry issue merge <child> <child> --into <canonical>` — pick the oldest/highest-volume as canonical. Merge **before** filing Linear, so counts aggregate and the Linear link lands once.

**Needs investigation** — root cause not determinable from Sentry + code reading alone (needs a log or edge correlation, an env-specific repro, or auth-side evidence).

- Hand off to the project's `/investigate` skill with the concrete identifiers the rule names (request ids, user, time window). Without one, write the identifiers into the report so the next session can pick them up.
- The Sentry issue stays unresolved and keeps its queue position; the investigation's verdict feeds the next `/sentry` run.

## Resolution lifecycle

Resolution is eager at fix time, reconciled at triage time:

1. **Fix time (the implementing session).** The filed issue's resolve criterion carries the literal command; `--in @next` marks the issue resolved-pending, binds it to the next finalized release, and auto-regresses if events arrive after that release — so resolving a merged-but-undeployed fix is correct, and a wrong resolve heals itself. This mutation is bookkeeping mandated by certified criteria, not a triage judgment, and is safe unattended. The global `/finish` skill knows nothing about Sentry — the criterion is what carries the instruction, which is the house mechanism for issue-specific steps. What "the next release" means — a semver tag CI finalizes, or a deploy-created release named by commit — is the rule's business.
2. **Triage time (the sync pass).** Catches fixes that shipped without the criterion — organic fixes landed outside `/sentry` filings — and runs the regression check: a resolved issue with post-release events gets a comment on its Linear issue, never a silent re-file.
3. **Never via commit-message tokens.** Sentry can auto-resolve on `Fixes <SHORT-ID>` in commit prose when commit tracking is wired, but commit messages already carry two magic-token grammars (`[skip ci]`, Linear close keywords — `standards/git.md`); a third scanner is collision surface with no gain over the explicit command.

## Mutation etiquette

- Nothing is confirmed — reads and writes alike. The writes are `resolve`, `unresolve`, `archive`, `merge`, and `api` POSTs (notes).
- Execute serially and report each result. A failed mutation (e.g. a short-id resolved by someone else mid-run) is reported, not retried blind.
- `merge` is the only irreversible one (no `unmerge` in this CLI), so name the canonical issue and its children in the report — a wrong merge is then at least traceable.
- No Sentry assignment (`assignedTo`) — ownership lives in Linear, and split ownership drifts.

## Environments

`environment:production` is the triage scope. What the other environments carry — PR canaries, preview builds, nothing at all — is the rule's to say; they are triaged only on explicit request (`/sentry … env:<name>`), and never filed to Linear without a production sighting or a deliberate decision.
