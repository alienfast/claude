---
name: linear
description: Linear via linear-cli — MUST READ before running Linear commands, especially for reading comments or dependencies (the obvious commands silently miss both)
---

# Linear (linear-cli) — Quick Reference

Linear is driven by **nesszer `linear-cli`** (Rust; binary `linear-cli`, installed to `~/.cargo/bin`). This is a short reference for the **non-obvious** parts — for everything else use `linear-cli <cmd> --help`, `linear-cli common`, or `linear-cli agent`.

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
   ~/.claude/scripts/linear-create-child.sh [--allow-planned] <parent|-> <team> <state|-> <title> <body-file>
   ```

4. **Unassign** = `linear-cli issues assign <ID>` with the user omitted.

5. **Workflow states** = `linear-cli statuses list -t <TEAM>` (there is no `teams states`).

6. **Escape hatch — and its responses carry the `data` envelope.** Anything the dedicated commands can't do: `linear-cli api query`/`api mutate` run raw GraphQL against the Linear API (this is why we use linear-cli — the previous CLI had no such hatch). Unlike every dedicated command, these return the **raw GraphQL envelope**, so jq filters need a `.data.` prefix — `jq '.data.issues.nodes[]'`, not `.issues.nodes[]` (`linear-context.sh`, `linear-deps-graph.sh` and `next-candidates.sh` all do this). Copying the path straight out of your own query text is the trap, and it fails two ways: iterating the missing path errors loudly (`Cannot iterate over null`), but `length`, `//` defaults and most aggregations **succeed on `null`** — `jq '.issues.nodes | length'` prints `0` and exits **0**, no default required, so a summary line reads `TOTAL: 0` and a full pool is indistinguishable from an empty team.

7. **Labels are typed, can be team-scoped, and `-l` REPLACES.** `labels list` and `labels create` default to `--type project` — pass `-t issue` for issue labels (a project label can't be attached to an issue; probe with `linear-cli labels list -t issue -o json`). `issues update -l` **sets the entire label set** (no add/remove subcommand) — to add one label without clobbering the rest, use `~/.claude/scripts/linear-add-label.sh <ID> <label>` (read-merge-set + verified attach); `issues list -l <name>` filters by label name. Issue labels can be **team-scoped**: attaching one to an issue in another team fails with GraphQL `labelIds for incorrect team`, and `labels create` has **no `--team` flag**, so it provisions workspace-level labels only (team-scoped ones must be created in the Linear UI). The `specified` certification label is deliberately workspace-level so it attaches across all teams (`standards/issue-spec.md`); `scripts/linear-file-improvement.sh` keeps a best-effort attach (exit 2 + WARN) for the day a conflicting team-scoped label appears.

8. **`issues update --state` can report success without the state actually changing.** Exit code 0 and the printed `+ Updated issue` message are not confirmation — a follow-up `issues get --no-cache` may still show the old state, even after retries and even when passing the state's UUID directly instead of its name. If a state update doesn't seem to have taken effect after a `--no-cache` re-check, fall back to the raw mutation (gotcha #6) and trust its own response over the wrapped command: `linear-cli api mutate 'mutation($id: String!, $stateId: String!) { issueUpdate(id: $id, input: { stateId: $stateId }) { success issue { id identifier state { id name } } } }' --variable id=<issue-uuid> --variable stateId=<state-uuid>` — its response includes the resulting `issue.state`, so you can confirm the change immediately without a separate `get`.

9. **`comments list` needs `-o json` — its table output is empty, and the JSON is a nested envelope.** The default table prints a header row and ZERO data rows for every issue (`| Author | Created | Body | ID |`, then `N comments`), so the bare command reads as "no comments" on an issue that has several — and `/start` Step 4 sends you here precisely for full standalone bodies, which the digest truncates to 140 chars. Always pass `-o json`; the payload is `{"comments":{"nodes":[{"body":…}]},"id","identifier","title"}`:

   ```bash
   linear-cli comments list <ID> -o json | jq -r '.comments.nodes[].body'
   ```

   Not `.[].body` — iterating the top level hits the `id`/`title` strings and errors with `Cannot index string with string`. Passing **multiple** IDs returns an ARRAY of those objects; use `-o ndjson` and keep the same per-line filter.

10. **`relations add -r blocked-by` 400s in every published version through 0.3.27** — `IssueRelationType` has no `blockedBy` member (Linear models blocking as one *directed* `blocks`), and the CLI serializes the flag straight through. Fixed upstream on `master` (PR #37, 2026-07-18) but **unreleased**: crates.io `0.3.27` was published 2026-06-26, three weeks earlier ([#42](https://github.com/nesszer/linear-cli/issues/42)). Until a `0.3.28` ships, always express blocking as `relations add <BLOCKER> <BLOCKED> -r blocks`. `blocks`, `related` and `duplicate` all work — but `duplicate` additionally mutates the first argument's state, see gotcha #15.

11. **`Argument Validation Error` means a malformed identifier reached the API — suspect your shell, not the CLI.** Linear returns this generic GraphQL error when an issue key is empty or isn't a key, so a batched loop that mangles its arguments looks exactly like a broken command. The usual cause is a bash idiom in **zsh**, which does not word-split unquoted *parameter* expansions: `for pair in "A B"; do set -- $pair` leaves `$1="A B"` and `$2=""` (bash gives `$1=A`, `$2=B`). The asymmetry that makes this easy to miss: an unquoted `$(…)` *at the point of expansion* does still split in zsh, so `for id in $(cmd)` iterates per word while `p=$(cmd); for id in $p` iterates once over the joined value. Before reporting a CLI bug, echo the arguments and retry one pair by hand.

12. **`priority` is an integer whose lowest value ranks LAST.** Linear encodes `1` Urgent, `2` High, `3` Medium, `4` Low — and **`0` = No priority**, so a raw `.priority` read inverts if you treat it positionally ("P0 is top"). `scripts/next-candidates.sh` maps it explicitly (`priority_rank`: `Urgent(1)→1 … None(0)→5`), i.e. an unprioritized issue sorts *behind* every prioritized one; the full within-tier ordering is in [next/SKILL.md](../next/SKILL.md). When printing priorities for a human decision, print a **label**, never `P<n>`: that form reads like a severity scale running the other way, and a ranking judgment built on it is inverted. **The dedicated commands do not give you one** — `issues get`, `search issues` and `issues list` all carry the bare integer `priority` and no `priorityLabel` field (measured on 0.3.27), so `jq -r '.priorityLabel'` prints `null` for **every** issue, which reads as *No priority* and inverts the very judgment this gotcha exists to protect. `--fields priorityLabel` does not rescue it — an unknown field is dropped silently, returning `{}` at exit 0. **That null is structural, not a flap:** it is identical across repeated `--no-cache` reads, so do not misroute it to gotcha #8 (the write didn't take) or #17 (an eventually-consistent read) — the re-check and raw-mutation fallback those prescribe will only re-confirm a write that already landed. Three ways to get a label: map the integer yourself (`1` Urgent, `2` High, `3` Medium, `4` Low, `0`/absent No priority); read `scripts/next-candidates.sh`'s `priority_label`, which computes it client-side (rendering `3` as `Normal` and `0` as `None`); or ask the raw hatch, which **does** return it — `linear-cli api query 'query { issue(id: "BF-670") { priority priorityLabel } }' | jq -r '.data.issue.priorityLabel'` (note the `.data.` prefix, gotcha #6).

13. **Result shape varies by command — `search issues` and `issues list` return a BARE ARRAY (`.[]`).** There is no single envelope; take the filter from the command you ran, never from a sibling:

    | Command | Top level | Filter |
    |---|---|---|
    | `search issues`, `issues list` | bare array | `.[]` |
    | `issues get <ID>` | bare object (the issue itself) | `.identifier`, `.state.name`, `.labels.nodes[]` … |
    | `comments list <ID>` | object wrapping a sub-collection | `.comments.nodes[]` (gotcha #9) |
    | `relations list <ID>` | object wrapping several sub-collections | `.relations[]`, `.inverseRelations[]`, `.parent`, `.children[]` (no `.nodes`) |
    | `api query`/`api mutate` | raw GraphQL envelope | `.data.<field>.nodes[]` (gotcha #6) |
    | `statuses list -t <KEY>` | object wrapping a sub-collection | `.statuses[]` (no `.nodes`) |

    Only a **sub-collection nested under a parent** carries `.nodes` — top-level results are unwrapped. (`statuses list` wraps without `.nodes` — `.statuses[]` — and its failure is the loud kind: `.[]` reaches the inner array so `select(.name==…)` dies with `Cannot index array with string ("name")`, exit 5.) Copying `.issues.nodes[]` from an `api query` onto `search issues` does **not** quietly return nothing: jq exits **5** with `Cannot index array with string ("issues")` on stderr, and a `// []` guard chain does not rescue it (`//` catches `null`, not a type error). That exit code is the check that matters for the dedup search `/quality-review` requires before filing — a genuinely empty search exits **0** with no output, so treat empty stdout as "no existing issue covers this" only once the command itself succeeded. **That loudness is specific to the bare-ARRAY rows.** On the bare-object `issues get` row a wrong filter is as silent as gotcha #6's: `.issue.description` — the natural guess, since no envelope is visible in the command — yields the string `null` at exit **0**, and so does a two-level `.issue.foo.bar`. Nothing distinguishes that from an issue whose description is genuinely empty, which is how a wrong path survives as a "defensive" fallback chain instead of being recognized and fixed. The issue object is unwrapped: read `.description`, `.identifier`, `.state.name` directly. That split runs *inside* the `issues get` object too: its scalars and single objects are bare (`.identifier`, `.description`, `.state.name`), while its collections are not (`.labels.nodes[]`, `.children.nodes[]`) — so `.labels[].name` fails with jq's `Cannot index array with string ("name")` at exit **5**, the same loud signature as the bare-array rows above. Do not carry that to those rows, though: `search issues` and `issues list` return *reduced* rows that omit `labels` entirely, so `.labels` there is `null` at exit **0** — the silent mode — and label filtering is `issues list -l <name>` (gotcha #7).

    `relations list <ID>` is a second instance of the `statuses list` shape — an object whose sub-collections are bare arrays (`.relations[]`, never `.relations.nodes[]`) — but its failure is the SILENT kind rather than `statuses list`'s loud one. Because the top level is an **object**, a `type=="array"` guard — the natural shape for "did this return anything", and primed by `comments list`, which really does return an array when passed several IDs (gotcha #9) — falls through to the else branch for **every** issue at exit **0**, byte-identical to the answer a genuinely edge-less issue gives. There is no array variant to guard for: `relations list` takes exactly one ID, and a second is rejected outright (`error: unexpected argument`). Measured 2026-08-18 at a fleet retro: an edge audit over 10 filed issues reported 0 with edges and was believed, where a GraphQL cross-check found 6; re-measured on BF-871 (4 `relations` + 4 `inverseRelations` + a parent) and BF-1202 (2 + 3), both printing `(none)` under that guard, `cmp`-identical to edge-less BF-1225. Read `.relations[]` and `.inverseRelations[]` explicitly — and read **both**, since one `blocks` edge appears on the blocker as `.relations[]` and on the blocked issue as `.inverseRelations[]` — or ask the raw hatch (gotcha #6), which DOES carry `.nodes` because it is raw GraphQL: `relations { nodes { type relatedIssue { identifier } } } inverseRelations { nodes { type issue { identifier } } }`.

    ```bash
    linear-cli search issues "<terms>" -o json | jq -r '.[] | "\(.identifier) [\(.state.name)] \(.title)"'
    ```

14. **`search issues` matches a CONTIGUOUS PHRASE, not a set of words — so a multi-word query is almost always
    zero hits, and it exits 0.** The query is matched as a substring of the title/description, in order. Words
    that all appear but are not adjacent do **not** match. Verified against one issue whose title reads
    `Security: client-supplied GraphQL scopes (rewhere) bypass row-level authorization on any list_field`:

    | query | hits | why |
    |---|---|---|
    | `rewhere` | 2 | single token |
    | `row-level authorization` | 1 | adjacent, in order |
    | `client-supplied GraphQL scopes` | 1 | adjacent, in order |
    | `scopes authorization` | **0** | both words present, not adjacent |
    | `resolve_list scopes injection` | **0** | a description, not a substring |

    This is the **dedup search `/quality-review` requires before filing**, and it fails in the worst possible
    direction: an invented descriptive phrase returns empty with **exit 0** and no error, which is exactly the
    signature of "no existing issue covers this." Gotcha #13's exit-code check does not catch it — the command
    genuinely succeeded. It found nothing because nothing could have matched.

    **So search single tokens only** — code identifiers, symbol/method/field names, `snake_case`, `camelCase`,
    error strings — one per query, several queries. Never a phrase you composed to describe the defect. If a
    multi-word query is unavoidable, it must be text you have *seen verbatim* in an existing title.

    **Search the target FILE's basename too, and search it first when the defect is a flake, a fixture, or
    anything else whose identifiers are descriptions rather than symbols.** Near-duplicates routinely share zero
    identifier tokens — each filer names the mechanism their own way — while every one of them names the same
    file, so the basename is the only invariant token available. Measured: `rack_logger_spec.rb:208`'s one
    assertion was filed FOUR times across three fleets (BF-1014/1222/1252/1283) under four different mechanism
    descriptions; the single token `rack_logger_spec` returns all four. Apply the same distinctive-vs-generic
    split `/reflect`'s Step 6 dedup search uses: a distinctive basename (`rack_logger_spec`,
    `next-candidates.sh`) is searchable as-is; a generic one (`prepopulate` → ~50 hits, `user.rb`, `index.ts`)
    discriminates nothing — fall back to the symbol there.

    Real cost of getting this wrong: BF-777 was filed Urgent against `ListHelper#resolve_list` after three
    dedup searches — `resolve_list scopes injection`, `list_helper scopes`, `SQL injection anonymous` — all
    multi-word, all structurally guaranteed to return nothing. BF-490 had described the same defect in the same
    file for weeks and is returned by the single token `rewhere`.

15. **`relations add A B -r duplicate` marks **A** as the duplicate, and Linear auto-transitions A into the `Duplicate` state.** The direction matches `blocks` — first argument is the subject, "A is a duplicate of B" as "A blocks B" — which `relations add --help` confirms only obliquely (`<FROM>` is "Source issue identifier"; `-r duplicate` is "Duplicate of another issue"). But unlike `blocks` and `related` it has a **side effect on issue state**, which the help text does not mention and the command output does not report. Get it backwards while working A and you silently move the issue you are working into a closed state — `Duplicate` is its own workflow-state *type*, alongside `canceled` and `completed`. **Nothing downstream reliably catches this:** `/finish`'s terminal-state check (Error Handling section) enumerates only `Ready For Release` and `Done`, so a `Duplicate` issue surfaces incidentally at best. Re-adding in the correct direction fixes the relation and clears the wrong issue's `Duplicate` state, but restores it to **`Backlog`**, not to whatever it was before — re-claim it explicitly (`issues update <ID> --assignee me --state "In Progress"`). Read the argument order as the sentence "A is a duplicate of B" before running it, and re-check the worked issue's state afterwards (`issues get <ID> --no-cache`). Observed on BF-662 (being worked, In Progress) against its duplicate BF-713.

16. **Linear stores task-list marks as uppercase `- [X]`, whatever case you posted — so matching a CHECKED box case-sensitively silently does nothing.** Verified by round-trip: a description posted with ten lowercase `- [x]` reads back from `issues get -o json` as ten `- [X]`, zero lowercase. Writing either case is therefore harmless (Linear normalizes), and the check-off direction the skills prescribe is safe too — `/start` Step 8, `/checkpoint`, and `/finish` Step 4 all match the *unchecked* `- [ ]`, which has no case. The bite is the other direction: unchecking, counting, or verifying an already-checked box. `grep -c '^- \[x\]'` returns **0**, `sed 's/^- \[x\]/- [ ]/'` matches no line, and the resulting no-op update still prints the ordinary `+ Updated issue:` line at exit 0. A pre/post `diff` does not catch it either — both files are the byte-identical original, so "identical apart from the one mark" is vacuous. Match case-insensitively (`grep -ci`, `sed 's/^- \[[xX]\]/…/'`), and treat a checked-count of **zero** on a description you know has checked boxes as the tell that your pattern's case is wrong, not as "nothing to update". This comes up whenever a description must be byte-preserved while one box changes — the divergence workflow in `.claude/rules/planning.md`.

17. **A label write is verified through the consumer, not through `issues get` — and its read-back ERROR is inconclusive.** Label reads are eventually consistent and flap in *both* directions across reads seconds apart. Observed on BF-856: `specified` alone, then both labels, then `specified` alone, then both, over ~20s — for a write that had landed on the first attempt. `~/.claude/scripts/linear-add-label.sh` verifies with its own re-read, so it inherits this: `ERROR: label set on <ID> may have been modified concurrently — expected […], found […], missing […]` (exit 2) means **could not confirm**, not **failed**. Callers that treat exit 2 as a hard failure will act on a write that succeeded — `/spec`'s error row reads it as "the spec landed but the issue is NOT certified" and stops the run.

    **Do not retry the write on the strength of it.** `issues update -l` REPLACES the whole label set (gotcha #7), so a retry built from a stale read can drop a label another actor just added — the exact loss the helper's `--no-cache` reads were meant to prevent.

    **This is not gotcha #8, and #8's remedy does not transfer.** There the *write* did not take and a `--no-cache` re-check plus raw-mutation fallback is right; here the write took and the *read* is what lies. `--no-cache` cannot help: `linear-cli`'s cache stores only teams, statuses, projects, users, labels and views (`linear-cli cache status`; on disk `~/Library/Application Support/linear-cli/cache/`) — there is **no issue cache**, so the staleness is server-side and re-reading settles nothing.

    **Verify through whatever consumes the label.** For the pickup gates that is `~/.claude/scripts/next-candidates.sh`, which re-fetches every issue per invocation and answers the question that actually matters — is the label *effective* — rather than whether a string is present on one read. It hard-hides `needs decision`, `solo` and `keeper`, each with a trailing hidden-count note, so a count moving (BF-856: 12 → 13) plus the issue leaving the ranking is the proof; `specified` has no hidden count and is checked by ranking membership under `--label specified`. (It also gates ordering, not visibility, on `specified`+`reflection` together for tier 0 and on `security`/`bug` for class rank.) Counts are computed client-side by `jq` from that fresh fetch — the value is the consumer's semantics, not a fresher read path.

18. **`comments create -b -` posts a literal `-` as the comment body — `issues comment --body -` is the form that reads stdin.** Only the help text distinguishes them: `issues comment`'s `-b` documents `Use "-" to read from stdin`; `comments create`'s `-b` does not, and 0.3.27's `create_comment` passes `--body` straight into the GraphQL `CommentCreateInput`. Passing `-` is therefore not an error — it posts a one-character comment and reports success (`+ Comment added to <ID>` … `Body: -`) at exit 0, so the corruption surfaces only if you read the body back. The `comments` family primes the mistake from both sides: gotcha #9 sends you there for reads, and `comments list`'s own *issue-ID* argument really does take `-` for stdin. Eventual consistency compounds it — a `comments list <ID>` taken immediately after can return an empty `nodes` array, which reads as "the create did nothing" and invites a retry that posts a second stray. Use `~/.claude/scripts/linear-post.sh comment <ID> <body-file>` (the helper `standards/linear-workflow.md` prescribes, which picks the right flag per kind), or the Command-map form `issues comment <ID> --body -`. Remove a stray with `comments delete <comment-uuid> --force` — without the flag it bails with `Delete requires --force flag` rather than prompting; the uuid comes from `comments list <ID> -o json`.

19. **`search issues` rows carry `state` as `{name}` ONLY — there is no `state.type` — so a type-based terminal filter silently passes every row.** The Linear API does expose `WorkflowState.type` (`completed`, `canceled`, …), which makes `select(.state.type? != "completed")` the natural jq for dropping shipped work from a dedup or collision probe — but the search row is exactly `{id, identifier, priority, state: {name}, title}` (measured on 0.3.27; `issues list` rows add `assignee`/`project` but their `state` is `{name}`-only too, as is `issues get`'s), and jq yields `null` for a missing key at exit **0**, `?`-guarded or not, so the comparison is vacuously true for **every** row: Done and Canceled issues sail through and closed work reads as open — #13's silent mode (`labels` there) striking on the very field the open-vs-terminal judgment rests on. Filter by **name** — `select(.state.name | IN("Done","Canceled","Duplicate") | not)`, checking the team's actual state names with `statuses list -t <KEY>` (gotcha #5) when unsure — or ask the raw hatch (gotcha #6), which does return `state { type }`. The same reduction omits `description`, while #14's substring match runs over title *and* body — a hit can match on text the row does not show, so judge relevance with `issues get <ID>` on the surviving hits, never from the row alone.

20. **An issue identifier written through the API stays literal text — auto-linking is a client-side editor input rule, and the API-side equivalent is a plain URL, not the identifier.** Linear stores rich text as a ProseMirror document in which a mention is its own `issueMention` node (`id`/`label`/`href`/`title`); typing `BF-932` in Linear's editor converts it via an input rule, but nothing converts it on the way in through `issues create -d`, `issues update --data`, `issues comment --body`, or `linear-post.sh`. **The fix is to emit the plain issue URL**, which Linear's markdown ingest does convert into a real mention chip (docs: "mentions can be created in Markdown by using the plain URL of the resource", e.g. `https://linear.app/yourworkspaceurl/issue/LIN-123/some-issue` → `@LIN-123`). Read the canonical slug-carrying URL rather than hand-building it: `linear-cli issues get <ID> -o json | jq -r '.url'`. A `[BF-932](<url>)`-wrapped link is what a mention serializes back **out** to, but only the bare URL is documented as converting on the way **in**. **For a durable reference prefer a relation** — `linear-cli relations add <A> <B> -r related` (see gotchas #10 and #15 for direction and the `duplicate` state side effect) — which renders with live status and survives renames; a stored mention `href` goes stale on retitle (BF-931's mention still carries BF-932's superseded slug).

21. **`issues create` rejects `--title` and `--label` — and clap's "tip" for the first is actively wrong.** The command map below already shows the two flags that DO exist (title is POSITIONAL, description is `-d`/`--description`, `-` for stdin) but not the trap: guessing `--title` gets `tip: a similar argument exists: '--filter'` plus a `Usage:` line reading as though `--filter` were required for `create` — it is not, and `--filter` has nothing to do with `create`. The label flag is `--labels` (plural, short `-l`); `--label` errors the same way. There is no `--description-file` at all — pass the body inline or via stdin.

    **Always pass `--state` — an omitted state lands the issue in the team's DEFAULT state, which on a triage-enabled team is Triage, invisible to `/next` and `/auto` permanently with no warning anywhere** (measured 2026-08-15: three fleet follow-up filings stranded this way in one run). Unattended filings use `--state Backlog` (keeper ruling 2026-08-15: the human curates Planned) — or better, file through `~/.claude/scripts/linear-create-child.sh` (parent `-` for a standalone issue), which resolves a Backlog-preferring state itself and verifies everything it writes.

    ```bash
    linear-cli issues create --team BF "<TITLE>" --description - --state Backlog --labels specified < body.md
    ```

23. **Every `statuses list` call reads through `linear-cli`'s Statuses cache, so a workflow state added minutes ago is invisible — and the error blames the
    team.** The cache covers statuses (gotcha #17), and no state-resolution call site opted out until this was measured. Symptom:
    `mark-ready-for-release.sh` exits 1 with `ERROR: no Ready-For-Release state found for team '<KEY>'. Set it manually.` while the state exists and every
    matcher handles it. Measured 2026-08-21 against a live team with a 24-minute-old cache: the cached path returned no output and the script exited 1,
    `--no-cache` returned `Ready for Release`, and `linear-cli cache clear` fixed the cached path. It self-heals on expiry, which makes it intermittent and
    easy to dismiss, and it appears only in the window right after someone changes a workflow state — exactly when these scripts matter most. Every state
    resolution in `~/.claude/scripts` now passes `--no-cache` (`grep -rn 'statuses list' ~/.claude/scripts` is the current roster); keep it that way in any
    new one, at the cost of one API round-trip on a path that already makes several.

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
linear-cli comments list <ID> -o json         # STANDALONE only (gotcha #1); -o json is REQUIRED — see gotcha #9
linear-cli relations add <BLOCKER> <BLOCKED> -r blocks   # "A blocked by B" = relations add B A -r blocks (-r blocked-by 400s in every PUBLISHED version through 0.3.27 — see gotcha #10); also -r related|duplicate
linear-cli relations remove <RELATION-UUID>              # takes the relation id (from relations list -o json), NOT the two issue keys
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
| `linear-create-child.sh [--allow-planned] <parent\|-> <team> <state\|-> <title> <body-file> [label\|-]` | Parent-linked issue create — create → `relations parent` → verify (gotcha #3). A caller-passed `Planned` is refused without the leading `--allow-planned` (the human curates Planned; the flag marks a deliberate placement). Labels get the same normalized-identity healing as `linear-add-label.sh` (multi-word names keep their spacing; a near-miss heals to the canonical label rather than minting a twin — a `tr -d '[:space:]'` here once corrupted `needs decision` into a minted `needsdecision` that leaked BF-1243 past its park gate; ambiguous matches skip with exit 2). |
| `linear-post.sh <comment\|description> <ID> <body-file>` | Post a comment or replace a description from a file. |
| `linear-add-label.sh <ID> <label>` | Add one issue label without clobbering the rest (read-merge-set + verified attach; gotcha #7). A requested name that matches an existing label after normalization (case + space/`-`/`_`) heals to that label with a NOTE instead of minting a twin — a freehand `needsdecision` once minted a permanent near-miss that leaked its issue past `next-candidates.sh`'s `needs decision` park gate. Exit 2 + create-label pointer when genuinely missing/unattachable, or when several labels normalize to the request. |
| `linear-remove-label.sh <ID> <label>` | Remove one issue label, preserving the rest (read-filter-set + verified; raw `issueUpdate labelIds: []` for the last-label case). Exit 0 on already-absent. |
| `mark-ready-for-release.sh <ID>` | Move to Ready-For-Release **and unassign** — read-back-verified, with gotcha #8's raw-mutation fallback automated (exit 1 if the state provably never changed). |
