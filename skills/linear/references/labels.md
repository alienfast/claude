# Labels

Read this before any label read or write. What each label means and who applies it is
[standards/issue-spec.md](../../../standards/issue-spec.md) (`specified`, `needs decision`, `human`, `solo`,
`deploy-gated`, `simple`, `keeper`, and § An agent filing never lands unrouted). The flag shape on `issues create`
(`-l` once per label, never comma-joined) is [create.md](create.md) gotcha #21.

## Gotcha 7 — labels are typed, can be team-scoped, and `-l` REPLACES

- **Typed.** `labels list` and `labels create` default to `--type project`; pass `-t issue` for issue labels (a project
  label cannot be attached to an issue; probe with `linear-cli labels list -t issue -o json`).
- **`-l` replaces.** `issues update -l` sets the entire label set (there is no add/remove subcommand). To add one label
  without clobbering the rest, use `~/.claude/scripts/linear-add-label.sh <ID> <label>` (read-merge-set + verified
  attach); to remove one, `linear-remove-label.sh <ID> <label>` (read-filter-set, with a raw `issueUpdate labelIds: []`
  for the last-label case). `issues list -l <name>` filters by label name.
- **Team-scoped.** Issue labels can be team-scoped: attaching one to an issue in another team fails with GraphQL
  `labelIds for incorrect team`, and `labels create` has no `--team` flag, so it provisions workspace-level labels only
  (team-scoped ones are created in the Linear UI). The `specified` certification label is deliberately workspace-level
  so it attaches across all teams; `scripts/linear-file-improvement.sh` keeps a best-effort attach (exit 2 + WARN) for
  the day a conflicting team-scoped label appears.
- **Never minted by a helper.** `linear-add-label.sh` and `linear-create-child.sh` heal a near-miss name to the existing
  label after normalization (case, space/`-`/`_`; multi-word names keep their spacing) and refuse a label that does not
  exist (exit 2) rather than creating it — a freehand `needsdecision` once minted a permanent near-miss that leaked its
  issue past the `needs decision` park gate, and a reply token passed as a label once minted one that fourteen filings
  then carried unrouted. An ambiguous near-miss (several labels normalize to the request) also exits 2. New labels are
  a `/linear-setup` decision.

## Gotcha 17 — a label write is verified through the consumer, not through `issues get`

Label reads are eventually consistent and flap in both directions across reads seconds apart (observed: `specified`
alone, then both labels, then `specified` alone, then both, over ~20s, for a write that had landed on the first
attempt). `linear-add-label.sh` verifies with its own re-read, so it inherits this: `ERROR: label set on <ID> may have
been modified concurrently — expected […], found […], missing […]` (exit 2) means **could not confirm**, not
**failed**. A caller that treats exit 2 as a hard failure acts on a write that succeeded.

**Do not retry the write on the strength of it.** `issues update -l` replaces the whole label set (gotcha #7), so a
retry built from a stale read can drop a label another actor just added — the exact loss the helper's `--no-cache`
reads exist to prevent.

**This is not gotcha #8** ([states.md](states.md)), and #8's remedy does not transfer. There the write did not take
and a `--no-cache` re-check plus raw-mutation fallback is right; here the write took and the read is what lies.
`--no-cache` cannot help: `linear-cli`'s cache stores only teams, statuses, projects, users, labels and views
(`linear-cli cache status`; on disk `~/Library/Application Support/linear-cli/cache/`) — there is no issue cache, so
the staleness is server-side and re-reading settles nothing.

**Verify through whatever consumes the label.** For the pickup gates that is `~/.claude/scripts/next-candidates.sh`,
which re-fetches every issue per invocation and answers the question that matters — is the label *effective* — rather
than whether a string is present on one read. It hard-hides `needs decision`, `solo` and `keeper`, each with a trailing
hidden-count note, so a count moving plus the issue leaving the ranking is the proof; `specified` has no hidden count
and is checked by ranking membership under `--label specified`. (It also gates ordering, not visibility, on
`specified`+`reflection` together for tier 0 and on `security`/`bug` for class rank.) Counts are computed client-side
by `jq` from that fresh fetch — the value is the consumer's semantics, not a fresher read path.

**Never run two label writes on the same issue concurrently — not even as parallel tool calls in one message.**
`linear-add-label.sh` and `linear-remove-label.sh` each read the set once, apply one change, and write the whole set
back (gotcha #7), so two in flight start from the same original set and the last write wins. Their verification cannot
see it: each re-checks only the set *it* computed from its own read, never that nothing else changed — so the last
writer always confirms its own clobbering write, an earlier one exits 0 whenever its re-read lands first, and the
exit-2 case is inconclusive as above: no exit code certifies a concurrent batch. Measured: add `specified`, remove
`needs decision`, remove `bug`, and add `simple`, issued in parallel on one issue, all exited 0 and left
`bug, needs decision, simple` — the certification dropped and both removals undone (an add makes one extra
`labels list` call before writing, so adds tend to write last). Issue one label write per message on a given issue,
each after the previous returns, then confirm the end state through the consumer. Writes to *different* issues share
nothing to race on — the helpers never create labels — so parallelizing across issues is safe.
