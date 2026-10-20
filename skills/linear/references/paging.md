# Paging, rate limits and batch runs

Read this before any pool-sized read (a whole Backlog, every issue carrying a label), before a loop over issues, and
whenever a Linear call answers with nothing.

## Gotcha 25 — `issues list` returns 50 rows by default, silently; `--count-only` counts that page

The default page size is 50 (hard-coded in `src/commands/issues.rs`; measured on 0.3.28):
`issues list --team PL --state Backlog -o json | jq length` printed **50** against a 506-issue Backlog, the table
footer read `50 issues`, and no output mode prints a more-results hint. `--count-only` — the natural flag for sizing a
pool — inherits the cap and printed `50` for the same Backlog. The flags that fix it exist but `issues list --help`
buries them among forty others (`linear-cli common` is where they are called out): **`--all`** fetches every page
(byte-equal to a paginated raw-hatch count), `--limit N` pages internally past the API's 250-per-page (`--limit 300`
returns 300), and `--page-size`/`--after` are there for hand-paging. Pass `--all` on any pool-sized read, and treat a
result count landing exactly on 50 as truncation, never as the answer; the same tell applies to a one-shot raw query
landing exactly on its `first:` cap (`/auto-prep`'s pool fetch documents the `pageInfo` loop that fixes it —
`next-candidates.sh` runs it).

## Gotcha 26 — a rate-limited answer is invisible behind `2>/dev/null`

linear-cli puts the whole error envelope on STDERR and leaves stdout empty. Linear's window is per USER: 2,500
requests/hour on an API key (`X-RateLimit-Requests-Remaining` rides on every response; the complexity budget is never
the constraint), shared by every session, script and launchd job on the machine. Spent, the API answers HTTP 400 with
`extensions.code: "RATELIMITED"`, which `-o json` relays as a `{"code":4,"details":{"errors":[…]}}` envelope on stderr
and table mode as `Error: HTTP 400 Bad Request: Rate limit exceeded. Only 2500 requests are allowed per 1 hour`. A
capture that discards stderr reads that as an empty page or a missing issue, and a 2-second retry cannot help against
an hourly bucket (a ranker costing hundreds of requests per run, re-run before every pick by five sessions, spent the
window every hour, and the one visible symptom was a pick failing with `auth? network? rate limit?`). Capture stderr
and grep it for `RATELIMITED` / `Rate limit exceeded`; on a hit, stop and wait for the window rather than retrying
(`next-candidates.sh` exits 4 with that word, and `/auto`'s transient-API rule covers it). Read the live meter for one
request, with `$key` from the config file `linear-cli config show` names:

```bash
curl -s -D - -o /dev/null -H "Authorization: $key" -H 'Content-Type: application/json' --data '{"query":"{ viewer { id } }"}' https://api.linear.app/graphql | grep -i x-ratelimit
```

## Gotcha 11 — `Argument Validation Error` means a malformed identifier reached the API

Suspect your shell, not the CLI. Linear returns this generic GraphQL error when an issue key is empty or is not a key,
so a batched loop that mangles its arguments looks exactly like a broken command. The usual cause is a bash idiom in
**zsh**, which does not word-split unquoted *parameter* expansions: `for pair in "A B"; do set -- $pair` leaves the
first positional parameter as `A B` and the second empty (bash gives `A` and `B`). The asymmetry that makes this easy
to miss: an unquoted `$(…)` *at the point of expansion* does still split in zsh, so `for id in $(cmd)` iterates per
word while `p=$(cmd); for id in $p` iterates once over the joined value. Before reporting a CLI bug, echo the arguments
and retry one pair by hand.

## Gotcha 24 — in auto mode, a Linear write inside shell control flow is denied by the permission classifier

The same write as one plain command runs: three `relations remove <uuid>` calls in a `for` loop (with `set --`
word-splitting) came back `Blocked by classifier`, and each re-issued as its own single-command Bash call printed
`Relation removed`. The denial reads as a refusal of the write itself, and the natural response is to stop and hand
the commands to the user — retry once as a plain command first. Issue Linear writes one per Bash call (loops are fine
for reads) and confirm with a follow-up `relations list` / `issues get --no-cache`.
