# Relations: dependencies, blocks, parent/child

Read this before reading or writing any relation. When a pair takes `blocks` versus `related` is
[standards/issue-spec.md](../../../standards/issue-spec.md) § Certification includes collision edges; which states
resolve a blocker is [standards/linear-workflow.md](../../../standards/linear-workflow.md) § Terminal States for
Dependency Resolution.

## Gotcha 2 — no dependency commands or flags

There is no `deps` command and no `search --has-blockers/--blocked-by/--has-circular-deps`. Get the graph as
`{nodes, edges}` and filter with `jq`:

```bash
~/.claude/scripts/linear-deps-graph.sh PL-13        # local graph (issue + neighbors)
~/.claude/scripts/linear-deps-graph.sh --team PL    # whole-team graph (active issues + the partners their edges name, in any state)
```

An edge `{from, to, type:"blocks"}` means `from` blocks `to`. Per-issue relations also exist directly:
`linear-cli relations list <ID>` — read its JSON with the shapes in [json.md](json.md) gotcha #13 (`.relations[]` and
`.inverseRelations[]`, both needed, neither carrying `.nodes`).

## Gotcha 10 — `relations add -r blocked-by` 400s; express blocking as `blocks`

`IssueRelationType` has no `blockedBy` member (Linear models blocking as one directed `blocks`), and every published
version through 0.3.27 serializes the flag straight through, so the API answers 400 (upstream
[nesszer/linear-cli#42](https://github.com/nesszer/linear-cli/issues/42)). The help text on 0.3.28 still lists
`blocked-by`, and whether that release carries the fix is unmeasured. Always express blocking as
`relations add <BLOCKER> <BLOCKED> -r blocks`, which is right on every version: "A blocked by B" is
`relations add B A -r blocks`. `blocks`, `related` and `duplicate` all work, but `duplicate` additionally mutates the
first argument's state (gotcha #15).

## Gotcha 15 — `relations add A B -r duplicate` marks A the duplicate and auto-closes it

The direction matches `blocks` — the first argument is the subject, "A is a duplicate of B" as "A blocks B" — which
`relations add --help` confirms only obliquely (`<FROM>` is "Source issue identifier"; `-r duplicate` is "Duplicate of
another issue"). Unlike `blocks` and `related` it has a side effect on issue state that neither the help text nor the
command output mentions: Linear moves A into the `Duplicate` state, its own workflow-state type alongside `canceled`
and `completed`. Get it backwards while working A and you silently close the issue you are working, and nothing
downstream reliably catches it (`/finish`'s terminal-state check enumerates only `Ready For Release` and `Done`).

Re-adding in the correct direction fixes the relation and clears the wrong issue's `Duplicate` state, but restores it
to `Backlog`, not to whatever it was before — re-claim it explicitly (`~/.claude/scripts/linear-claim.sh <ID> --state
"In Progress"`, [states.md](states.md) gotcha #8). Read the argument order as the sentence "A is a duplicate of B"
before running it, and re-check the worked issue's state afterwards (`issues get <ID> --no-cache`).

## Gotcha 22 — filtering `relations list` output on `blocks` drops every `blocked by` row

The two relation types render as distinct strings and `blocks` is not a substring of `blocked by`, so
`linear-cli relations list <ID> | grep -E 'blocks|related'` returns only the outgoing edges, exits 0, and inverts the
answer to the question the command is usually asked: an issue carrying two `blocked by` rows that decided whether it
was pickable printed as one `blocks` and one `related` row under that filter, and a sibling matched only because its
title contained "duplicated". Both tokens are on the line — the term you grepped simply does not subsume the sibling
term it looks like it should. The table is a few rows: read it whole, or grep `blocked` when what you want is blockers.
Gotcha #13 ([json.md](json.md)) covers the complementary jq failure on the same command.

## Parent and child

`issues create` has no `--parent` flag ([create.md](create.md) gotcha #3): file through `linear-create-child.sh`, or
set the parent after create with `linear-cli relations parent <CHILD> <PARENT>`. `relations remove` takes the relation
UUID (from `relations list <ID> -o json`), not the two issue keys. An epic's membership (descendants plus their
blockers, dependents excluded) is what `~/.claude/scripts/epic-graph.sh` assembles; its header has the walk rules.
