# States, assignment and claims

Read this before writing a state or an assignee, or filtering on state. Which states count as terminal for dependency
resolution, and what an assignee means, are [standards/linear-workflow.md](../../../standards/linear-workflow.md)
§ Terminal States for Dependency Resolution and § Assignment Is a Claim.

## Gotcha 4 — unassign

`linear-cli issues assign <ID>` with the user omitted. A load-bearing unassign gets a `--no-cache` read-back, as
gotcha #8 prescribes.

## Gotcha 5 — workflow states are `statuses list -t <TEAM>`

There is no `teams states`. Pass `--no-cache` (gotcha #23). Provisioning a team's states, labels and views is
`/linear-setup` ([skills/linear-setup/SKILL.md](../../linear-setup/SKILL.md)), which applies the house model
idempotently — never hand-roll `workflowStateCreate`/`customViewCreate` calls.

## Gotcha 8 — `issues update` can report success without writing the field

Its success line names the issue, never the field, in every output mode: exit 0 and `+ Updated issue: <ID> <title>`
are not confirmation, because the mutation selects `issue { identifier title }` and nothing else, so `-o json`, `-q`
and `--id-only` cannot confirm either — they print less, not more. Measured on both fields it is used to write:
`--state` (a follow-up `issues get --no-cache` still showing the old state, after retries and even when passing the
state's UUID) and `--assignee` (the success line at exit 0 with `assignee` left null, confirmed by a `--no-cache` read
and by the Linear UI, while the identical command re-run afterwards wrote it normally). Intermittent, which is what
makes it dangerous: it survives every retry you run to reproduce it.

**For the assignee, use `issues assign <ID> me`.** `--help` calls it "a shortcut for update --assignee"; the
difference it glosses over is the whole point: its mutation selects `assignee { name }` and prints the server's
resulting value (`+ Assigned <ID> to <name>`, or `+ Unassigned <ID>` when the response carries no assignee), so a write
that did not land usually appears in the output instead of reading as success — usually, not always: a bare
`issues assign <ID>` has printed `+ Unassigned <ID>` at exit 0 while two consecutive `--no-cache` reads still showed
the assignee, and the identical retry landed. A load-bearing assign or unassign therefore gets a `--no-cache` read-back
regardless of what the echo said. It cannot set state; pair it with a separate state write. **Do not reach for
`issues start`**: it selects both fields but renders them as the *intended* values when the response is null (the
assignee defaulted to `"me"`, the state name computed locally), manufacturing a confirmation, and it picks whichever
`started`-type state the API returns first — which on a team whose In Review is also type `started` need not be In
Progress.

**For the state**, re-check with `--no-cache` and then fall back to the raw mutation ([json.md](json.md) gotcha #6),
trusting its own response over the wrapped command:

```bash
linear-cli api mutate 'mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { id identifier state { id name } } } }' --variable id=<issue-uuid> --variable stateId=<state-uuid>
```

Its response includes the resulting `issue.state`, so you confirm without a separate `get`.
`scripts/linear-set-state.sh` and `scripts/mark-ready-for-release.sh` automate exactly this; `scripts/linear-claim.sh`
does the assignee-and-state pair a claim needs, with the three outcomes below kept distinct.

**Where this bites hardest is a claim**, and a read-back is the only confirmation available. Verify `.assignee` on a
fresh `issues get --no-cache` — the payload exposes an assignee as `{name}` alone, no id and no email, so that is the
field to compare, and on a viewer whose display name is not their email a naive email comparison never matches. Never
verify through `next-candidates.sh`'s `hidden as claimed by a person` note: its count excludes self-assignments, so
your own claim never moves it (linear-workflow.md § A self-claim does not hide an issue — it promotes it). Keep three
outcomes apart, because they route differently: **confirmed landed**; **confirmed not landed** (a good read showing the
old value — retryable, the write is idempotent); and **could not confirm** (the read command itself failed — network,
auth), which is not a failed claim and must not be reported as one.

## Gotcha 19 — rows carry `state` as `{name}` only; a type-based terminal filter passes every row

The Linear API exposes `WorkflowState.type` (`completed`, `canceled`, …), which makes
`select(.state.type? != "completed")` the natural jq for dropping shipped work from a dedup or collision probe — but a
`search issues` row is exactly `{id, identifier, priority, state: {name}, title}` (`issues list` rows add
`assignee`/`project` but their `state` is `{name}`-only too, as is `issues get`'s), and jq yields `null` for a missing
key at exit 0, `?`-guarded or not, so the comparison is vacuously true for every row: Done and Canceled issues sail
through and closed work reads as open — the silent mode of [json.md](json.md) gotcha #13 striking on the very field the
open-vs-terminal judgment rests on. Filter by **name**: `select(.state.name | IN("Done","Canceled","Duplicate") | not)`,
checking the team's actual state names with `statuses list -t <KEY> --no-cache` when unsure — or ask the raw hatch
(gotcha #6), which does return `state { type }`. The same reduction omits `description`, while the substring match of
[create.md](create.md) gotcha #14 runs over title *and* body — a hit can match on text the row does not show, so judge
relevance with `issues get <ID>` on the surviving hits, never from the row alone.

## Gotcha 23 — `statuses list` reads through the Statuses cache; pass `--no-cache`

A workflow state added minutes ago is invisible to a cached read, and the error blames the team:
`mark-ready-for-release.sh` exits 1 with `ERROR: no Ready-For-Release state found for team '<KEY>'. Set it manually.`
while the state exists and every matcher handles it (measured against a 24-minute-old cache: the cached path returned
nothing, `--no-cache` returned `Ready for Release`, and `linear-cli cache clear` fixed the cached path). It self-heals
on expiry, which makes it intermittent and easy to dismiss, and it appears only in the window right after someone
changes a workflow state — exactly when these scripts matter most. Every state resolution in `~/.claude/scripts`
passes `--no-cache` (`grep -rn 'statuses list' ~/.claude/scripts` is the roster); keep it that way in any new one, at
the cost of one API round-trip on a path that already makes several.
