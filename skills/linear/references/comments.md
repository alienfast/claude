# Comments and bodies

Read this before reading or writing comments, or writing any body text through the API. The stdin plumbing for a body
(`linear-post.sh`, `linear-stdin.sh`, the `tmp/` file workflow) is owned by
[standards/linear-workflow.md](../../../standards/linear-workflow.md) § Passing File Content to Linear CLI.

## Gotcha 1 — anchored (inline) comments are invisible to the obvious commands

A comment made by highlighting text in the issue description is stored on the description's `documentContent`, not on
`issue.comments`. `linear-cli comments list <ID>` and `issues get` return only standalone comments and report "no
comments" while reviewer corrections sit on the description. Read an issue with its full thread through the digest:

```bash
~/.claude/scripts/linear-context.sh PL-13   # description + parent chain + deps + standalone AND anchored comments
```

Raw form (what the digest does): resolve the issue's `documentContent.id`, then
`comments(filter:{documentContent:{id:{eq:<that id>}}})` via `linear-cli api query`.

## Gotcha 9 — `comments list` needs `-o json`, and the JSON is a nested envelope

The default table prints a header row and zero data rows for every issue (`| Author | Created | Body | ID |`, then
`N comments`), so the bare command reads as "no comments" on an issue that has several. The digest truncates standalone
bodies to 140 chars, so full bodies come from here. Always pass `-o json`; the payload is
`{"comments":{"nodes":[{"body":…}]},"id","identifier","title"}`:

```bash
linear-cli comments list PL-13 -o json | jq -r '.comments.nodes[].body'
```

Not `.[].body` — iterating the top level hits the `id`/`title` strings and errors with `Cannot index string with
string`. Passing several IDs returns an array of those objects; use `-o ndjson` and keep the same per-line filter.

## Gotcha 18 — `comments create -b -` posts a literal `-`; `issues comment --body -` reads stdin

Only the help text distinguishes them: `issues comment`'s `-b` documents `Use "-" to read from stdin`; `comments
create`'s `-b` does not, and its `create_comment` passes `--body` straight into the GraphQL `CommentCreateInput`.
Passing `-` is therefore not an error — it posts a one-character comment and reports success (`+ Comment added to
<ID>` … `Body: -`) at exit 0, so the corruption surfaces only if you read the body back. The `comments` family primes
the mistake from both sides: gotcha #9 sends you there for reads, and `comments list`'s own issue-ID argument really
does take `-` for stdin. Eventual consistency compounds it: a `comments list <ID>` taken immediately after can return
an empty `nodes` array, which reads as "the create did nothing" and invites a retry that posts a second stray.

Use `~/.claude/scripts/linear-post.sh comment <ID> <body-file>`, which picks the right flag per kind, or the Command-map
form `issues comment <ID> --body -`. Remove a stray with `comments delete <comment-uuid> --force` — without the flag it
bails with `Delete requires --force flag` rather than prompting; the uuid comes from `comments list <ID> -o json`.

## Gotcha 20 — an issue identifier written through the API stays literal text

Auto-linking is a client-side editor input rule. Linear stores rich text as a ProseMirror document in which a mention
is its own `issueMention` node (`id`/`label`/`href`/`title`); typing `PL-932` in Linear's editor converts it, but
nothing converts it on the way in through `issues create -d`, `issues update --data`, `issues comment --body`, or
`linear-post.sh`.

The API-side equivalent is the plain issue URL, which Linear's markdown ingest does convert into a real mention chip
(Linear's docs: "mentions can be created in Markdown by using the plain URL of the resource", e.g.
`https://linear.app/yourworkspaceurl/issue/LIN-123/some-issue` → `@LIN-123`). Read the canonical slug-carrying URL
rather than hand-building it: `linear-cli issues get <ID> -o json | jq -r '.url'`. A `[PL-932](<url>)`-wrapped link is
what a mention serializes back out to, but only the bare URL is documented as converting on the way in.

For a durable reference prefer a relation — `linear-cli relations add <A> <B> -r related` (direction and the
`duplicate` state side effect: [relations.md](relations.md) gotchas #10 and #15) — which renders with live status and
survives renames; a stored mention `href` goes stale on retitle.
