---
name: linear
description: Linear via linear-cli — MUST READ before running Linear commands, especially for reading comments or dependencies (the obvious commands silently miss both)
---

# Linear (linear-cli) — Quick Reference

Linear is driven by **Finesssee `linear-cli`** (Rust; binary `linear-cli`, installed to `~/.cargo/bin`). This is a short reference for the **non-obvious** parts — for everything else use `linear-cli <cmd> --help`, `linear-cli common`, or `linear-cli agent`.

Auth: `linear-cli auth oauth` (browser) or `LINEAR_API_KEY`; check with `linear-cli auth status`. The full issue lifecycle is automated by the in-repo skills (`/start`, `/finish`, `/full`, `/checkpoint`, `/next`, `/quality-review`, `/prd`, `/spec`, `/triage`) — no install step.

## ⚠️ Gotchas that bite (read these)

1. **Anchored (inline) comments are invisible to the obvious commands.** A comment made by *highlighting text in the issue description* is stored on the description's `documentContent`, NOT on `issue.comments`. `linear-cli comments list <ID>` and `issues get` return only standalone comments and will report "no comments" while reviewer corrections sit on the description. **To read an issue with its full comment thread, use the digest:**

   ```bash
   ~/.claude/scripts/linear-context.sh PL-13          # markdown digest: desc + deps + standalone AND anchored comments
   ```

   Raw form (what the digest does): resolve the issue's `documentContent.id`, then
   `comments(filter:{documentContent:{id:{eq:<that id>}}})` via `linear-cli api query`.

2. **No dependency commands or flags.** There is no `deps` command and no `search --has-blockers/--blocked-by/--has-circular-deps`. Get the graph as `{nodes, edges}` and filter with `jq`:

   ```bash
   ~/.claude/scripts/linear-deps-graph.sh PL-13        # local graph (issue + neighbors)
   ~/.claude/scripts/linear-deps-graph.sh --team PL    # whole-team graph (active issues)
   ```

   Per-issue relations also exist directly: `linear-cli relations list <ID>`.

3. **`issues create` has no `--parent` flag** — to set the parent at create time, pass its UUID as `parentId` in `--data` JSON (verified on 0.3.26; `--data` carries `description` too). For follow-ups use the helper anyway: it links via `relations parent` and **verifies** the link (a bare `--data` create doesn't), failing hard on an orphan:

   ```bash
   ~/.claude/scripts/linear-create-child.sh <parent|-> <team> <state|-> <title> <body-file>
   ```

4. **Unassign** = `linear-cli issues assign <ID>` with the user omitted.

5. **Workflow states** = `linear-cli statuses list -t <TEAM>` (there is no `teams states`).

6. **Escape hatch.** Anything the dedicated commands can't do: `linear-cli api query`/`api mutate` run raw GraphQL against the Linear API (this is why we use linear-cli — the previous CLI had no such hatch).

7. **Labels are typed, can be team-scoped, and `-l` REPLACES.** `labels list` and `labels create` default to `--type project` — pass `-t issue` for issue labels (a project label can't be attached to an issue; probe with `linear-cli labels list -t issue -o json`). `issues update -l` **sets the entire label set** (no add/remove subcommand) — to add one label without clobbering the rest, use `~/.claude/scripts/linear-add-label.sh <ID> <label>` (read-merge-set + verified attach); `issues list -l <name>` filters by label name. Issue labels can be **team-scoped**: attaching one to an issue in another team fails with GraphQL `labelIds for incorrect team`, and `labels create` has **no `--team` flag**, so it provisions workspace-level labels only (team-scoped ones must be created in the Linear UI). The `specified` certification label is deliberately workspace-level so it attaches across all teams (`standards/issue-spec.md`); `scripts/linear-file-improvement.sh` keeps a best-effort attach (exit 2 + WARN) for the day a conflicting team-scoped label appears.

## Command map

```bash
# Issues (alias: i)
linear-cli issues get <ID> [-o json]          # single issue (state is {name}; --comments adds STANDALONE comments only)
linear-cli issues list --team <KEY> [--limit N] [--state X] [--assignee me] [-l <label>] [-o json]
linear-cli issues create "<title>" --team <KEY> [--state X] [-d -]   # description via stdin with -d -
linear-cli issues update <ID> [--state X] [--assignee me|<user>] [--priority N] [-l <label>]... [--data -]   # -l SETS the whole label set — to add, use linear-add-label.sh (gotcha #7)
linear-cli issues assign <ID> [<user>]        # omit <user> to UNASSIGN
linear-cli issues comment <ID> --body -       # add a comment (body via stdin)

# Comments / relations / search / statuses
linear-cli comments list <ID>                 # STANDALONE only — see gotcha #1 for anchored
linear-cli relations add <BLOCKER> <BLOCKED> -r blocks   # "A blocked by B" = relations add B A -r blocks (the blocked-by enum is broken on 0.3.26); also -r related|duplicate
linear-cli relations parent <CHILD> <PARENT>             # set parent after create (issues create has no --parent flag; or set parentId via --data)
linear-cli search issues "<query>" [--filter 'state.name=Backlog']   # workspace-wide; NO --team flag (use `issues list --team` to scope)
linear-cli statuses list -t <KEY>
linear-cli labels list -t issue|project [-o json]        # -t is label TYPE, not team; defaults to project (gotcha #7)
linear-cli labels create "<name>" -t issue [-c <hex>]    # create an ISSUE label; no --team flag (gotcha #7)
linear-cli labels delete <LABEL-UUID> -t issue -f        # takes the label id (from labels list -o json), not the name; -f skips the confirm prompt

# Projects / users / uploads
linear-cli projects get|list|create ...
linear-cli users list ; linear-cli whoami
linear-cli uploads fetch "<uploads.linear.app URL>" -f <file>   # authenticated download
```

Output flags (agent-friendly): `-o json|ndjson`, `-q` (quiet), `--id-only`, `--compact`, `--fields <a,b>`.

## In-repo helper scripts

| Script | Purpose |
|---|---|
| `linear-context.sh <ID>` | Full issue digest **including anchored comments** (gotcha #1). |
| `linear-deps-graph.sh <ID> \| --team <KEY>` | Dependency graph as `{nodes, edges}` (gotcha #2). |
| `linear-create-child.sh <parent\|-> <team> <state\|-> <title> <body-file>` | Parent-linked issue create — create → `relations parent` → verify (gotcha #3). |
| `linear-post.sh <comment\|description> <ID> <body-file>` | Post a comment or replace a description from a file. |
| `linear-add-label.sh <ID> <label>` | Add one issue label without clobbering the rest (read-merge-set + verified attach; gotcha #7). Exit 2 + create-label pointer when missing/unattachable. |
| `mark-ready-for-release.sh <ID>` | Move to Ready-For-Release **and unassign**. |
