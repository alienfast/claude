# Creating issues and writing bodies

Read this before `issues create`, before a dedup search, and before rewriting a description. The filing procedure an
agent follows (search, body, create through the helper, edges, routing label last) is
[standards/linear-filing.md](../../../standards/linear-filing.md); the stdin plumbing for any body is
[standards/linear-workflow.md](../../../standards/linear-workflow.md) § Passing File Content to Linear CLI.

## Gotcha 3 — `issues create` has no `--parent` flag

To set the parent at create time, pass its UUID as `parentId` in `--data` JSON (`--data` carries `description` too).
For follow-ups use the helper anyway: it links via `relations parent` and **verifies** the link (a bare `--data` create
does not), failing hard on an orphan:

```bash
~/.claude/scripts/linear-create-child.sh [--allow-planned] [--allow-unrouted] <parent|-> <team> <state|-> <title> <body-file> [label|-] [priority|-]
```

The label slot must carry a routing label — `specified`, `needs decision`, `human` or `keeper` (`sentry` /
`dependencies` from those two producers). A call without one is refused before anything is created unless it passes
the leading `--allow-unrouted`, which only a caller that certifies in a later step of the same run does. A
caller-passed `Planned` is refused without the leading `--allow-planned` (the human curates Planned; the flag marks a
deliberate placement). The script header carries the full contract and exit codes.

## Gotcha 14 — `search issues` matches a CONTIGUOUS PHRASE, not a set of words

The query is matched as a substring of the title/description, in order. Words that all appear but are not adjacent do
not match, and a miss exits 0. Verified against one issue whose title reads
`Security: client-supplied GraphQL scopes (rewhere) bypass row-level authorization on any list_field`:

| query | hits | why |
|---|---|---|
| `rewhere` | 2 | single token |
| `row-level authorization` | 1 | adjacent, in order |
| `client-supplied GraphQL scopes` | 1 | adjacent, in order |
| `scopes authorization` | **0** | both words present, not adjacent |
| `resolve_list scopes injection` | **0** | a description, not a substring |

This is the dedup search `/quality-review` requires before filing, and it fails in the worst direction: an invented
descriptive phrase returns empty with exit 0 and no error, exactly the signature of "no existing issue covers this".
The exit-code check of [json.md](json.md) gotcha #13 does not catch it — the command genuinely succeeded; nothing
could have matched.

**Search single tokens only** — code identifiers, symbol/method/field names, `snake_case`, `camelCase`, error strings
— one per query, several queries. Never a phrase you composed to describe the defect. If a multi-word query is
unavoidable, it must be text you have *seen verbatim* in an existing title.

**Search the target FILE's basename too, and search it first when the defect is a flake, a fixture, or anything else
whose identifiers are descriptions rather than symbols.** Near-duplicates routinely share zero identifier tokens —
each filer names the mechanism their own way — while every one of them names the same file, so the basename is the
only invariant token (one spec file's single assertion was filed four times under four mechanism descriptions; its
basename returns all four). A distinctive basename (`rack_logger_spec`, `next-candidates.sh`) is searchable as-is; a
generic one (`prepopulate`, `user.rb`, `index.ts`) discriminates nothing — fall back to the symbol there. The cost of
getting this wrong is a duplicate filed Urgent after three multi-word searches that were structurally guaranteed to
return nothing, while the single token found the weeks-old original.

`search issues` is workspace-wide with no `--team` flag (scope with `issues list --team`); its rows omit `description`
and carry `state` as `{name}` only ([states.md](states.md) gotcha #19).

## Gotcha 16 — Linear stores task-list marks as uppercase `- [X]`, whatever case you posted

Verified by round-trip: a description posted with ten lowercase `- [x]` reads back from `issues get -o json` as ten
`- [X]`, zero lowercase. Writing either case is harmless (Linear normalizes), and the check-off direction the skills
prescribe is safe too — `/start`, `/checkpoint` and `/finish` all match the *unchecked* `- [ ]`, which has no case.
The bite is the other direction: unchecking, counting, or verifying an already-checked box. `grep -c '^- \[x\]'`
returns **0**, `sed 's/^- \[x\]/- [ ]/'` matches no line, and the resulting no-op update still prints
`+ Updated issue:` at exit 0. A pre/post `diff` does not catch it either — both files are the byte-identical original.
Match case-insensitively (`grep -ci`, `sed 's/^- \[[xX]\]/…/'`), and treat a checked-count of zero on a description
you know has checked boxes as the tell that your pattern's case is wrong, not as "nothing to update". This comes up
whenever a description must be byte-preserved while one box changes.

## Gotcha 21 — `issues create` rejects `--title` and `--label`, and clap's tip for the first is wrong

Title is POSITIONAL, description is `-d`/`--description` (`-` for stdin). Guessing `--title` gets
`tip: a similar argument exists: '--filter'` plus a `Usage:` line reading as though `--filter` were required for
`create` — it is not, and `--filter` has nothing to do with `create`. The label flag is `--labels` (plural, short
`-l`); `--label` errors the same way. There is no `--description-file`: pass the body inline or via stdin.

**On `issues create`/`update`, `-l/--labels` takes ONE label per occurrence — repeat the flag, never comma-join.**
`--labels a,b,c` is parsed as a single label named `a,b,c` and dies with `Error: Label not found: a,b,c`, which names
the joined string and so reads as *these labels do not exist* — sending you to `labels list` to check labels that are
all present. Write `-l a -l b -l c`. Both take `labels: Vec<String>` with no clap `value_delimiter`
(`src/commands/issues.rs`), and the error interpolates the unsplit string (`src/api.rs`). The comma is a natural guess
because sibling subcommands in the same binary *do* split — `templates create -l`, `bulk` and `webhooks` set
`value_delimiter = ','`, and `templates create --help` even reads "Repeat or comma-separate for multiple labels" — so
`--help` on one command is no guide to another. **`issues list` is different in both directions**: its flag is
singular `-l, --label <LABEL>` (a filter, one value), and repeating it is a hard error —
`error: the argument '--label <LABEL>' cannot be used multiple times`. On `update`, `-l` REPLACES the whole set
([labels.md](labels.md) gotcha #7); a comma-join fails at label resolution rather than clobbering, but the repeat form
is what you want either way.

**Always pass `--state`** — an omitted state lands the issue in the team's DEFAULT state, which on a triage-enabled
team is Triage, invisible to `/next` and `/auto` permanently with no warning anywhere. Unattended filings use
`--state Backlog` (the human curates Planned) — or better, file through `~/.claude/scripts/linear-create-child.sh`
(parent `-` for a standalone issue), which resolves a Backlog-preferring state itself and verifies everything it
writes.

```bash
~/.claude/scripts/linear-stdin.sh tmp/linear-body.md issues create --team PL "<TITLE>" --description - --state Backlog --labels specified
```
