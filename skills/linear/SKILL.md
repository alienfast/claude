---
name: linear
description: Linear via linear-cli — MUST READ before running Linear commands, especially for reading comments or dependencies (the obvious commands silently miss both). Indexes 26 numbered gotchas (detail in references/).
---

# Linear (linear-cli)

Linear is driven by nesszer `linear-cli` (Rust; binary `linear-cli`, installed to `~/.cargo/bin`, which is not on a
non-interactive PATH). This file indexes the non-obvious parts; for everything else use `linear-cli <cmd> --help`,
`linear-cli common`, or `linear-cli agent`. Auth: `linear-cli auth oauth` (browser) or `LINEAR_API_KEY`; check with
`linear-cli auth status`. The issue lifecycle itself is automated by the skills (`/start`, `/spec`, `/finish`, …).

## Start here

```bash
~/.claude/scripts/linear-context.sh PL-13                  # description, parent chain, deps, standalone AND anchored comments
~/.claude/scripts/linear-deps-graph.sh PL-13 | --team PL   # dependency graph as {nodes, edges}
linear-cli issues get PL-13 -o json --no-cache             # the bare issue object (.identifier, .state.name, .labels.nodes[])
```

Body text (a comment, a description) goes through `linear-post.sh` / `linear-stdin.sh` from a `tmp/` file, never
through `<`, `cat |` or a heredoc — [standards/linear-workflow.md](../../standards/linear-workflow.md) § Passing File
Content to Linear CLI owns that. Filing an issue follows [standards/linear-filing.md](../../standards/linear-filing.md);
label meanings are [standards/issue-spec.md](../../standards/issue-spec.md); terminal states and claims are
linear-workflow.md.

## Gotchas

Numbers are stable — other skills cite them. The line is the reminder; the named file is the rule.

1. **Anchored (inline) comments are invisible** to `comments list` and `issues get`; read the digest → `references/comments.md`
2. **No dependency commands or flags** — graph via `linear-deps-graph.sh`, filter with jq → `references/relations.md`
3. **`issues create` has no `--parent`** — `parentId` in `--data`, or `linear-create-child.sh`, which verifies the link → `references/create.md`
4. **Unassign** = `issues assign <ID>` with the user omitted → `references/states.md`
5. **Workflow states** = `statuses list -t <TEAM>`; provisioning is `/linear-setup`, never hand-rolled → `references/states.md`
6. **`api query`/`api mutate` return the raw envelope** — jq paths start `.data.`; a wrong path's `length` is `0` at exit 0 → `references/json.md`
7. **Labels are typed (`-t issue`), can be team-scoped, and `-l` REPLACES** — add with `linear-add-label.sh` → `references/labels.md`
8. **`issues update` can report success without writing** — use `issues assign`, `linear-set-state.sh`, `linear-claim.sh`; read back `--no-cache` → `references/states.md`
9. **`comments list` needs `-o json`** (the table is empty) and the body path is `.comments.nodes[].body` → `references/comments.md`
10. **`-r blocked-by` 400s** — always `relations add <BLOCKER> <BLOCKED> -r blocks` → `references/relations.md`
11. **`Argument Validation Error`** = a mangled identifier reached the API, usually zsh not word-splitting `$var` → `references/paging.md`
12. **`priority`: `0` (none) ranks LAST**, and dedicated commands have no `priorityLabel` — print a label, never `P<n>` → `references/json.md`
13. **Result shape varies by command** — `search issues`/`issues list` are a bare array, `issues get` a bare object, `relations list` has no `.nodes` → `references/json.md`
14. **`search issues` matches a contiguous phrase** — single tokens only, the file basename first; a multi-word miss exits 0 → `references/create.md`
15. **`relations add A B -r duplicate` closes A** (state `Duplicate`); re-adding the right way restores it to Backlog → `references/relations.md`
16. **Checked task boxes read back as `- [X]`** — match case-insensitively → `references/create.md`
17. **A label write is verified through its consumer**, not `issues get` (reads flap); exit 2 = unconfirmed; one write per issue at a time → `references/labels.md`
18. **`comments create -b -` posts a literal `-`** — use `linear-post.sh comment` or `issues comment --body -` → `references/comments.md`
19. **Rows carry `state` as `{name}` only** — filter terminal states by name, never `.state.type` → `references/states.md`
20. **An issue id in a body stays plain text** — emit the issue URL, or better a `related` relation → `references/comments.md`
21. **`issues create`: title is positional, `-l` once per label, ALWAYS `--state`** (the default lands in Triage) → `references/create.md`
22. **`grep blocks` on `relations list` drops `blocked by` rows** — read the table whole → `references/relations.md`
23. **`statuses list` is cached** — pass `--no-cache` in every state resolution → `references/states.md`
24. **In auto mode a write inside shell control flow is classifier-denied** — one Linear write per Bash call → `references/paging.md`
25. **`issues list` returns 50 rows by default**, `--count-only` included — pass `--all` on pool-sized reads → `references/paging.md`
26. **A rate-limited answer is on STDERR with empty stdout** — never `2>/dev/null`; grep for `RATELIMITED` and wait → `references/paging.md`

## Command map

```bash
linear-cli issues get <ID> [-o json] [--no-cache]                        # --comments adds STANDALONE comments only (#1)
linear-cli issues list --team <KEY> [--all | --limit N] [--state X] [--assignee me] [-l <label>] [-o json]   # 50 rows by default (#25)
linear-cli issues create "<title>" --team <KEY> --state X [-l <label>]... [-d -]   # title positional, -l repeated, -d - reads stdin (#21)
linear-cli issues update <ID> [--state X] [--priority N] [-l <label>]... [--data -]   # -l SETS the whole set (#7); verify writes (#8)
linear-cli issues assign <ID> [me|<user>]                                 # omit the user to unassign (#4)
linear-cli issues comment <ID> --body -                                   # comment body via stdin (#18)
linear-cli comments list <ID> -o json                                     # standalone only (#1); -o json required (#9)
linear-cli relations list <ID> [-o json]                                  # .relations[] AND .inverseRelations[] (#13, #22)
linear-cli relations add <BLOCKER> <BLOCKED> -r blocks|related|duplicate  # the first argument is the subject (#10, #15)
linear-cli relations remove <RELATION-UUID>                               # the relation id from relations list -o json, not issue keys
linear-cli relations parent <CHILD> <PARENT>                              # set a parent after create (#3)
linear-cli search issues "<token>" [-o json]                              # workspace-wide, no --team; contiguous match (#14)
linear-cli statuses list -t <KEY> --no-cache                              # (#5, #23)
linear-cli labels list -t issue [-o json]                                 # -t is the label TYPE (#7)
linear-cli labels create "<name>" -t issue [-c <hex>]                     # workspace-level only (#7)
linear-cli labels delete <LABEL-UUID> -t issue -f                         # takes the label id, not the name
linear-cli api query '<graphql>' | jq '.data…'                            # escape hatch (#6)
linear-cli uploads fetch "<uploads.linear.app URL>" -f <file>             # authenticated download
```

Output flags: `-o json|ndjson`, `-q`, `--id-only`, `--compact`, `--fields <a,b>` (an unknown field is dropped silently).

## Helper scripts

All under `~/.claude/scripts/`. Each header carries the usage line, exit codes and contract; read it before calling.

| Script | Does |
|---|---|
| `linear-context.sh` | Markdown digest of an issue including anchored comments (#1). |
| `linear-deps-graph.sh` | Dependency graph as `{nodes, edges}` for one issue or a whole team (#2). |
| `linear-create-child.sh` | Create, link the parent, verify the link; refuses `Planned` and an unrouted label slot without the leading flags (#3, #21). |
| `linear-post.sh` | Post a comment or replace a description from a file (#18). |
| `linear-stdin.sh` | Pipe a file to any `linear-cli` command's stdin flag. |
| `linear-add-label.sh` | Add one label without clobbering the rest; heals near-miss names, never mints (#7, #17). |
| `linear-remove-label.sh` | Remove one label, preserving the rest (#7, #17). |
| `linear-set-state.sh` | Verified state transition for one or many issues: update → `--no-cache` read-back → raw-mutation fallback (#8). |
| `linear-claim.sh` | Assignee-and-state claim with a verdict on the first stdout line (`CLAIMED` / `NOT-CLAIMED` / `UNCONFIRMED`) (#8). |
| `linear-file-improvement.sh` | File a `/reflect` improvement issue (`specified`+`reflection`, or `reflection`+`keeper` uncertified). |
| `mark-ready-for-release.sh` | Move to Ready For Release and unassign, verified; then closes an `epic` parent whose every child is terminal (#8). |
| `epic-graph.sh` | An epic's working set as JSON — members, blockers, terminal nodes, edges, and the boundary report. |

## References

- [references/comments.md](references/comments.md) — read before reading or writing comments or any body text (#1, #9, #18, #20)
- [references/relations.md](references/relations.md) — read before reading or writing dependencies, duplicates or parents (#2, #10, #15, #22)
- [references/labels.md](references/labels.md) — read before any label read or write (#7, #17)
- [references/states.md](references/states.md) — read before writing a state or assignee, or filtering on state (#4, #5, #8, #19, #23)
- [references/create.md](references/create.md) — read before `issues create`, a dedup search, or a description rewrite (#3, #14, #16, #21)
- [references/paging.md](references/paging.md) — read before a pool-sized read or a loop, and when a call returns nothing (#11, #24, #25, #26)
- [references/json.md](references/json.md) — read before writing a `jq` filter over any linear-cli output (#6, #12, #13)
