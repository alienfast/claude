# JSON envelopes and jq shapes

Read this before writing any `jq` filter over linear-cli output. There is no single envelope: take the filter from the
command you ran, never from a sibling.

## Gotcha 6 — the escape hatch, and its `data` envelope

Anything the dedicated commands cannot do: `linear-cli api query` / `api mutate` run raw GraphQL against the Linear
API. Unlike every dedicated command, these return the **raw GraphQL envelope**, so jq filters need a `.data.` prefix —
`jq '.data.issues.nodes[]'`, not `.issues.nodes[]` (`linear-context.sh`, `linear-deps-graph.sh` and
`next-candidates.sh` all do this). Copying the path straight out of your own query text is the trap, and it fails two
ways: iterating the missing path errors loudly (`Cannot iterate over null`), but `length`, `//` defaults and most
aggregations **succeed on `null`** — `jq '.issues.nodes | length'` prints `0` and exits **0**, no default required, so
a summary line reads `TOTAL: 0` and a full pool is indistinguishable from an empty team.

## Gotcha 13 — result shape varies by command; `search issues` and `issues list` return a BARE ARRAY

| Command | Top level | Filter |
|---|---|---|
| `search issues`, `issues list` | bare array | `.[]` |
| `issues get <ID>` | bare object (the issue itself) | `.identifier`, `.state.name`, `.labels.nodes[]` … |
| `comments list <ID>` | object wrapping a sub-collection | `.comments.nodes[]` ([comments.md](comments.md) gotcha #9) |
| `relations list <ID>` | object wrapping several sub-collections | `.relations[]`, `.inverseRelations[]`, `.parent`, `.children[]` (no `.nodes`) |
| `api query`/`api mutate` | raw GraphQL envelope | `.data.<field>.nodes[]` (gotcha #6) |
| `statuses list -t <KEY>` | object wrapping a sub-collection | `.statuses[]` (no `.nodes`) |

```bash
linear-cli search issues "<token>" -o json | jq -r '.[] | "\(.identifier) [\(.state.name)] \(.title)"'
```

Only a **sub-collection nested under a parent** carries `.nodes` — top-level results are unwrapped.

**The bare-array rows fail loudly.** Copying `.issues.nodes[]` from an `api query` onto `search issues` does not
quietly return nothing: jq exits **5** with `Cannot index array with string ("issues")` on stderr, and a `// []` guard
chain does not rescue it (`//` catches `null`, not a type error). That exit code is the check that matters for the
dedup search `/quality-review` requires before filing — a genuinely empty search exits **0** with no output, so treat
empty stdout as "no existing issue covers this" only once the command itself succeeded. `statuses list` is loud the
same way: `.[]` reaches the inner array so `select(.name==…)` dies with `Cannot index array with string ("name")`,
exit 5.

**The bare-object `issues get` row fails silently.** `.issue.description` — the natural guess, since no envelope is
visible in the command — yields the string `null` at exit **0**, and so does a two-level `.issue.foo.bar`. Nothing
distinguishes that from an issue whose description is genuinely empty, which is how a wrong path survives as a
"defensive" fallback chain instead of being recognized and fixed. The issue object is unwrapped: read `.description`,
`.identifier`, `.state.name` directly. The split runs *inside* the object too: scalars and single objects are bare
(`.identifier`, `.description`, `.state.name`), collections are not (`.labels.nodes[]`, `.children.nodes[]`) — so
`.labels[].name` fails loudly with `Cannot index array with string ("name")`, exit 5. Do not carry that to the
bare-array rows: `search issues` and `issues list` return *reduced* rows that omit `labels` entirely, so `.labels`
there is `null` at exit **0** — the silent mode — and label filtering is `issues list -l <name>`
([labels.md](labels.md) gotcha #7). The same reduction leaves `state` as `{name}` only ([states.md](states.md)
gotcha #19).

**`relations list <ID>` is a second instance of the `statuses list` shape, but its failure is the SILENT kind.** It is
an object whose sub-collections are bare arrays (`.relations[]`, never `.relations.nodes[]`); because the top level is
an **object**, a `type=="array"` guard — the natural shape for "did this return anything", and primed by
`comments list`, which really does return an array when passed several IDs (gotcha #9) — falls through to the else
branch for **every** issue at exit **0**, byte-identical to the answer a genuinely edge-less issue gives. There is no
array variant to guard for: `relations list` takes exactly one ID, and a second is rejected outright
(`error: unexpected argument`). Measured: an edge audit over ten filed issues reported 0 with edges under that guard
where a GraphQL cross-check found 6, and an issue with 4 `relations` + 4 `inverseRelations` + a parent printed `(none)`,
`cmp`-identical to an edge-less one. Read `.relations[]` and `.inverseRelations[]` explicitly — and read **both**,
since one `blocks` edge appears on the blocker as `.relations[]` and on the blocked issue as `.inverseRelations[]` — or
ask the raw hatch (gotcha #6), which DOES carry `.nodes` because it is raw GraphQL:
`relations { nodes { type relatedIssue { identifier } } } inverseRelations { nodes { type issue { identifier } } }`.

## Gotcha 12 — `priority` is an integer whose lowest value ranks LAST

Linear encodes `1` Urgent, `2` High, `3` Medium, `4` Low — and **`0` = No priority**, so a raw `.priority` read
inverts if you treat it positionally ("P0 is top"). `scripts/next-candidates.sh` maps it explicitly (`priority_rank`:
`Urgent(1)→1 … None(0)→5`), i.e. an unprioritized issue sorts *behind* every prioritized one; the full within-tier
ordering is in [next/SKILL.md](../../next/SKILL.md). When printing priorities for a human decision, print a **label**,
never `P<n>`: that form reads like a severity scale running the other way, and a ranking judgment built on it is
inverted.

**The dedicated commands do not give you one.** `issues get`, `search issues` and `issues list` all carry the bare
integer `priority` and no `priorityLabel` field, so `jq -r '.priorityLabel'` prints `null` for **every** issue, which
reads as *No priority* and inverts the very judgment this gotcha exists to protect. `--fields priorityLabel` does not
rescue it — an unknown field is dropped silently, returning `{}` at exit 0. **That null is structural, not a flap:** it
is identical across repeated `--no-cache` reads, so do not misroute it to gotcha #8 (the write did not take,
[states.md](states.md)) or #17 (an eventually-consistent read, [labels.md](labels.md)) — the re-check and
raw-mutation fallback those prescribe will only re-confirm a write that already landed. Three ways to get a label: map
the integer yourself; read `scripts/next-candidates.sh`'s `priority_label`, which computes it client-side (rendering
`3` as `Normal` and `0` as `None`); or ask the raw hatch, which **does** return it — note the `.data.` prefix of
gotcha #6:

```bash
linear-cli api query 'query { issue(id: "PL-13") { priority priorityLabel } }' | jq -r '.data.issue.priorityLabel'
```

**Do not add a `priorityLabel` read-back guard to `linear-create-child.sh`** (the only script that sets priority):
unlike `--state`, `-p/--priority` takes on both `issues create` and `issues update`, so such a guard would fire on
every run and retry a write that already succeeded.
