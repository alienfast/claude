# CLAUDE.md

User-level guidance for every project. This directory (`~/.claude/`) is a git repo shared with the team
(`alienfast/claude.git`): rules, standards, skills, agents, hooks and scripts. Projects layer their own `CLAUDE.md` and
`.claude/rules/` on top.

## Multi-session awareness

Several Claude Code sessions work in parallel on this machine. Never touch changes you didn't create, and never run
branch or tree operations unasked; `hooks/git-permissions.sh` blocks the destructive ones. Commit or push only under an
explicit grant. Read [standards/git.md](standards/git.md) before any git operation, and
[standards/git-worktrees.md](standards/git-worktrees.md) when the session is worktree-isolated (`/start wt`, every
`/auto` fleet session).

## Rules, standards, skills

- `rules/*.md` inject by their own `paths:` frontmatter when a matching file is read or edited; `rules/comments.md`
  applies to every file. Moving code to a new file drops it out of every rule whose `paths:` named the old file, so after
  a create, rename or move, grep every rules directory for the old basename and add the new path.
- `standards/` are read on demand; [standards/README.md](standards/README.md) indexes them.
  `standards/problem-solving.md` owns decisions, `standards/agent-coordination.md` owns delegation,
  `standards/shell.md` owns the zsh traps summarized below.
- Skills load on invocation; the harness listing is the catalog. [skills/README.md](skills/README.md) is the creation
  guide.
- Lint and type-check before committing ([standards/project-commands.md](standards/project-commands.md)). Type checking
  is hard-gated in `/quality-review` and re-gated in `/finish`.

## Scratch, local state, files

- Scratch (captured output, run logs, staging files, `tmp/screenshots/`) goes in the project-relative `tmp/`
  (`mkdir -p tmp` first), never `/tmp`, `/private/tmp` or an ad-hoc absolute path; the harness scratchpad is the one
  exception. Delete only what you created, by name, and never remove `tmp/` itself: it holds harness state and the
  skill handoff files `/reap-tmp` manages. `hooks/scratch-path-guard.sh` enforces this; a denied command means rewrite
  the target.
- A symlink under `tmp/` never points into `.claude/` or `.git/`. Removing it prompts even in auto mode: Claude Code
  follows the link and treats the `rm` as an edit of a protected file, and an unattended run stalls on the prompt until a
  human answers. Copy the file into the scratch directory and link to the copy.
- Machine-local state a `~/.claude` script keeps across sessions goes in `~/.claude/local/` (gitignored), never under a
  harness-written directory (`telemetry/`, `state/`, `sessions/`, `tasks/`), and a built-in fallback must be surfaced
  where a human looks.
- Create documentation only when explicitly requested. Do not modify generated or build artifacts.
- Always Read a file before Write or Edit. If Write fails, Read and retry; never work around it with shell redirection,
  and never create duplicate or debug files as a workaround.
- Comments: default to none; add one only when the WHY is non-obvious; size it to the reader; wrap at ~160. Full rule in
  [rules/comments.md](rules/comments.md).

## The tool shell is zsh

Bash-only idioms fail silently, so an empty `EXIT=` or an all-zero table reads as success. The mechanics are in
[standards/shell.md](standards/shell.md); `hooks/zsh-trap-guard.sh` refuses the deterministic ones. The traps:

- `${PIPESTATUS[0]}` is empty: use `${pipestatus[1]}` or `set -o pipefail`, or drop the pipe and `echo "EXIT=$?"` after
  a redirect. A backgrounded call reports its last statement, so make the command last or capture `rc` and `exit $rc`.
- `status` is read-only: `rc=$?`, never `status=$?`.
- `path`, `fpath`, `cdpath`, `manpath` are tied to `PATH`: name loop and `read` variables `p` or `file`.
- Unquoted `$var` does not word-split: `${=var}` or an array.
- `${var,,}` / `${var^^}` abort the call: `${var:l}` / `${var:u}`.
- `$var:` + a modifier letter rewrites the word, quoted or not: brace it, `${tag}:apps/x`.
- A leading unquoted `=` is EQUALS expansion: quote `=====`.
- Quote globs in flags: `--include='*.md'`.
- `>` may refuse to overwrite (inherited `NO_CLOBBER`): use `>|` and `>>|`. In a worktree-isolated session `>>|` is
  refused, so write one file with `>|` or run `zsh tmp/<name>.sh`.
- A nested heredoc ends at the first matching delimiter and the rest executes: give the outer one a unique delimiter,
  or use the Write tool.
- Build control characters from codepoints, never `\u` escapes; a real NUL makes grep skip the file silently.
- grep is line-oriented: a wrapped phrase or a `grep A | grep B` pipeline silently drops matches. Grep the shortest
  token, filter at file scope, and confirm a zero-hit with a broader pattern.
- `cut -d,` / `awk -F,` ignore CSV quoting: confirm field numbers; prefer `grep -c` or a real parser.

## Output

Effort governs thinking, not length. Lead with the outcome, keep caveats short, and shorten by dropping detail that
doesn't change what the reader does next, not by compressing prose into fragments. **A fact is never phrased as an
action**: a closing "needs you" holds only what genuinely blocks or is owed by the reader; where a file landed, or that a
follow-up exists, is stated as a fact or left out; when nothing needs the reader, say so. Written deliverables (Linear
comments, PR descriptions, specs, `/reflect` proposals) run as long as their substance and no longer. None of this limits
coverage: a review reports every finding.

## Decisions and anti-patterns

You have autonomy for architectural improvements, new abstractions, schema and API changes and cross-file refactors.
Proceed when the solution is obvious, a codebase pattern exists or a standard covers it; a precedent establishes a shape,
never that the shape is safe at the new site. Stop and ask when the root cause is still unclear after investigation,
when valid solutions carry significant trade-offs, after two failed attempts, or when a business, security or usability
call is needed; hand over in the Complexity Response shape and write the question as a story
([standards/problem-solving.md](standards/problem-solving.md)). Before a workaround (version pin, error suppression,
`any` cast, skipped tests or validation, disabled lint rule, partial migration, silent default) fix the root cause. Own
the code: modify in place, delete aggressively, embrace breaking changes, and leave no backups, duplicates or
compatibility layers ([standards/technical-debt-prevention.md](standards/technical-debt-prevention.md)).

## Delegation

Delegate work that is independent and large enough to deserve a fresh context; do not delegate what finishes in a
handful of tool calls, and do not spawn an agent to check your own work. The `/quality-review` reviewer and verifier
dispatches and `/reflect`'s verifier are the deliberate exception: a fresh context as a mandated gate. Need the result
before continuing? Dispatch with `run_in_background: false`. Otherwise leave it in the background and end the turn; the
harness re-invokes you when it finishes. Never hold a turn open with a timed `sleep` (`hooks/no-blind-sleep.sh`); the
one sanctioned poll is a completion marker for work the harness cannot see, and in a worktree-isolated session that loop
goes in `tmp/wait-<thing>.sh`. Mechanics, including what the `spawn-policy` mod does to dispatch, are in
[standards/agent-coordination.md](standards/agent-coordination.md).

## Knowledge routing

Auto memory is off in `settings.json`. A lesson worth keeping goes to shared config through `/reflect` or straight into
the file that owns the behavior; one not worth sharing is said in the reply and dropped.

| What | Where |
| --- | --- |
| Project convention, "never do X here", discovered project quirk | the project's `CLAUDE.md` or `.claude/rules/*.md`, committed |
| Rule or fact that applies everywhere | `~/.claude/CLAUDE.md`, `standards/`, or a `rules/*.md` |
| Temporary or personal context | nowhere; say it in the reply |
