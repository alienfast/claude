# The `sentry` CLI

Facts about the agentic **`sentry`** CLI ([cli.sentry.dev](https://cli.sentry.dev)) that every Sentry-touching skill relies on. It is NOT the legacy `sentry-cli` v2 (build pipelines use the npm `@sentry/cli` package for sourcemaps and releases; unrelated). Measured on CLI 0.44.x; re-derive a shape with `sentry <cmd> --json | jq -r type` after an upgrade.

## Prerequisites and auth

- Install: the project's `.claude/update.sh` normally does it with `--no-agent-skills` (Sentry's bundled agent skills would compete with the house ones in the session listing); by hand, `curl -fsS https://cli.sentry.dev/install | bash -s -- --no-agent-skills`. Upgrade with `sentry cli upgrade --no-agent-skills`.
- Authenticate with `sentry auth login` (browser device flow, personal identity). **The stored login outranks any `SENTRY_AUTH_TOKEN` in the environment** (`SENTRY_FORCE_ENV_TOKEN=1` inverts that).
- A `SENTRY_AUTH_TOKEN` of the `sntrys_*` shape is an **organization** token — the kind CI uses for sourcemap upload and release finalization. It has no issue scopes: it satisfies `sentry auth status` and 403s on the first real read. That is why pre-flight probes an issue list, never `auth status`, and why the fix for a failing probe is `sentry auth login`, not re-exporting the token.
- Hard-fail policy: a skill that needs Sentry stops when the CLI is missing or unauthed, with the install/auth fix in one block. No partial run, no working around it.

## Target resolution (org/project)

The positional `<org>/<project>` is optional on `issue list`, `explore`, and most reads. Resolution order, all measured:

1. An explicit `<org>/<project>` argument.
2. `SENTRY_ORG` / `SENTRY_PROJECT` in the environment.
3. Auto-detection from the DSN or config under the cwd (a `SENTRY_DSN` in a dotenv file, an SDK config file). Run from the repo root; a fresh worktree may lack the gitignored dotenv, in which case nothing resolves and the CLI errors with `Organization and project are required`.

`sentry cli defaults org|project` sets a **per-user global** default — do not set it on a machine that works several Sentry projects, since it silently wins over auto-detection in every checkout. `sentry info` shows the active auth and defaults.

Forms: `<org>/<project>`, `<org>/` (every project in the org — the trailing slash matters; without it the argument is a project-name search), `<project>` (searched across orgs). Issue arguments accept short ids (`PROJ-ABC`), numeric ids, `@latest`, and `@most_frequent`.

## Common queries

```bash
sentry issue list [<org/project>] --query "is:unresolved <focus>" --limit 25
sentry issue list [<org/project>] --query "user.email:foo@bar.com"              # one user's issues (if the project keeps emails on events)
sentry issue list [<org/project>] --query "is:unresolved environment:production" \
  --sort user --period ">=2026-09-01" --json --fields shortId,title,userCount,count,priority
sentry issue view <short-id> --json                                             # bare object; latest event nested under .event
sentry issue events <short-id> --full --json --limit 1                          # ~90KB per event with --full
sentry api organizations/<org>/issues/<numeric-id>/                             # gh-style passthrough, relative to /api/0/
sentry explore [<org/project>] --dataset logs -F message -F "count()" --period 24h   # aggregate queries over errors|spans|metrics|logs|replays
```

- Query syntax: implicit AND, no OR; `key:[a,b]` for alternatives; `!key:value` negates; `key:>N`; quoted phrases; wildcards `*term*`. Built-ins: `is:unresolved`, `is:for_review`, `has:user`, `age:-24h`, `firstSeen:+7d`.
- `--sort`: `recommended` (the sentry.io default), `date`, `new`, `freq` (events), `user` (users affected). `--period` accepts `7d`, ranges (`2026-09-01..2026-09-08`), and open bounds (`>=2026-09-01`). By default only issues active in the last 90 days are shown.
- `--full` only takes effect under `--json`; without it the table output is byte-identical to a plain `issue events`, and the table's footer suggests `sentry event view <EVENT_ID>` against ids it has truncated to 12 chars — which cannot be followed as printed, because `event view` does no prefix matching (every prefix from 8 to 31 chars fails with `Error: Event '<id>' not found`, exit 23). Take full ids from `sentry issue events <short-id> --json --fields id` and pass one to `sentry event view <org>/<project>/<32-char-id>`. For just the newest event's body, `sentry api "issues/<numeric-id>/events/latest/"`.
- `issue view` caches by default; `-f`/`--fresh` bypasses it. `sentry api` has no cache.
- `sentry api` defaults to **GET** (`-X`/`--method`), and `-d` does not imply POST the way `curl -d` does, despite the flag's own help saying "like curl -d". A write without `-X POST`/`PUT` silently reads instead — the JSON body is folded into the query string and the call exits 0, so a note or status change appears to succeed and never lands. Verify with `--dry-run`, which prints the resolved method and body without sending. Exit status is **not** an HTTP status either: a `403` comes back as a JSON body (`{"detail": "You do not have permission to perform this action."}`) at exit 0 — pipe through `jq` and check the field you expect (`.id` on a created note) rather than the exit code.
- A flag value beginning with `-` (`--sort -timestamp`) is parsed as a run of short flags (`No alias registered for -i`); write `--sort=-timestamp`.

## JSON output shape

`--json` shape is per-subcommand, not uniform — check before writing a `jq` filter. Collection commands wrap rows in an envelope; single-object views and `sentry api` do not.

- Enveloped as `{"data": [...], "hasMore": …, "hasPrev": …}` — `issue list`, `issue events` (which adds `nextCursor`), `explore` (adds `meta` and `dataset`), `project list`, `team list`. The filter is `.data[]`.
- Bare — `issue view` returns a single object (`--fields` included), `org list` and `release list` return arrays, and `sentry api` returns the API's own response untouched.

A bare `.[]` against an envelope iterates its *values*, so it dies on the row field — `jq: error: Cannot index array with string ("shortId")`; `.[0]` dies with `Cannot index object with number (0)`. Neither message names `data`, which is what makes it read as a field-name typo.

Field types are not uniform either: `count` is a **string** while `userCount` is a number, in `issue list` and `issue view` alike — so ranking on events needs `.count|tonumber` (jq refuses to negate a string: `string ("6") cannot be negated`). Unknown `--fields` names are dropped silently rather than erroring.

`explore --dataset logs` cannot be sorted (`--sort` is spans-only and ignored with a warning), and numeric log attributes are addressed as `tags[<name>,number]`.

## Never Seer

Do not use `sentry issue explain` / `plan` — they invoke Seer, a paid metered add-on; the analysis is ours to do with the repo in hand.
