# CLAUDE.md

Global user-level guidance for Claude Code. This directory (`~/.claude/`) contains rules, skills, commands, and standards that apply to all projects unless overridden by project-specific configurations.

## Multi-Session Awareness

Multiple Claude Code sessions can work simultaneously. Never touch changes you didn't create. The git-permissions.sh hook blocks destructive commands automatically.

See [Git Standards](standards/git.md) for detailed rules and examples.

## Path-Specific Rules

Rules in `~/.claude/rules/` are automatically applied based on file type:

- `comments.md` - Applied to all files (`**/*`, language-agnostic) — default to no comments; size to the reader; no provenance decoration
- `typescript.md` - Applied to `**/*.ts`, `**/*.tsx` files
- `react.md` - Applied to `**/*.tsx`, `**/*.jsx` files
- `markdown.md` - Applied to `**/*.md`, `**/*.mdx` files
- `package-manager.md` - Applied to `**/package.json` and lockfiles
- `env-vars.md` - Applied to `**/*.ts`, `**/*.tsx`, `**/*.mts` files (required-env-var handling; `assertEnvVariable`, no silent defaults)
- `biome.md` - Applied to `**/*.ts`, `**/*.tsx`, `**/*.js`, `**/*.jsx`, `**/*.mjs`, `**/*.cjs`, `**/*.json`, `**/*.jsonc` files (Biome projects only — self-nullifies elsewhere; auto-fix output is post-fix, not a TODO, so re-read before editing)

These are generic, file-type-scoped, and shared across all projects via `alienfast/claude.git`. Projects layer their own domain rules in `<project>/.claude/rules/` — committed to the project repo and shared with the team (e.g. basefund's `descope.md`, `nextjs.md`, `apollo.md`, `mui-*.md`, `storybook.md`).

## Available Skills

Skills activate automatically based on context, and the harness lists the full available set each session — so this file does not enumerate them (the list drifts otherwise). See [Skills README](skills/README.md) for the catalog, grouping (Linear workflow vs development workflow), and creation guide. External skills are installed via `update.sh`.

## Standards

Universal standards in `~/.claude/standards/` apply across all contexts and are indexed in [Standards README](standards/README.md) — read the relevant file when its domain comes up. `git.md` (multi-session safety, commit/PR conventions) is the broadest and most safety-critical; read it before any git operation.

## Quality Checks

Lint and type-check before committing — see [Project Commands](standards/project-commands.md) for the commands.

Type checking is hard-gated in `/quality-review` and re-gated in `/finish`; run it directly otherwise.

## Guidelines

- Write scratch / intermediate files — captured command output, run logs, script staging files, screenshots (`tmp/screenshots/`) — to a project-relative `tmp/` directory (`mkdir -p tmp` first), and add files there freely — but delete only what you created, naming your own files and subdirectories. Never `rm -rf tmp/` or otherwise remove the directory itself: it also holds harness-owned session state and cross-skill handoff artifacts — the `/start wt` contamination baseline (`main-dirty-baseline-<issue>.txt`), the `/quality-review` → `/finish` verdict (`quality-review-verdict-<issue>.md`), and `/auto`'s run state (`auto-state-<runKey>.json`). Wiping it silently disables a safety check or breaks a skill handoff, and the loss stays invisible until the next check fails closed. Never write scratch to bare system roots (`/tmp`, `/private/tmp`) or ad-hoc absolute paths like `/check_output.log`: these pollute the host and trip the harness's dangerous-path confirmation when you clean them up. A harness-assigned session scratchpad is the only exception. This applies to sub-agents too. Enforced by the `scratch-path-guard.sh` PreToolUse hook — a denied command means rewrite the target to `tmp/`, not retry.
- Create documentation only when explicitly requested.
- Do not modify generated or build artifact files (e.g., `src/generated/`, `dist/`).
- Do not create git commits unless explicitly requested — see [Git Standards](standards/git.md) for commit/push authorization.
- Always Read a file before using Write or Edit on it. Write rejects writes to existing files that haven't been Read first. If Write fails, do NOT work around it with Bash (`cat`, `tee`, `echo >`, `sed`, `awk`) — Read the file first, then retry. Never create duplicate/debug files as workarounds.
- When writing or editing comments: default to none; add one only when the WHY is non-obvious; size to what the reader needs, not the effort it took to discover; wrap at ~160 chars, never 80. Full guidance auto-injects on every file edit (all file types) — see [rules/comments.md](rules/comments.md).
- The shell is **zsh**, not bash — every `Bash` tool call runs it. Bash-only idioms fail *silently* rather than erroring: `${PIPESTATUS[0]}` expands to the empty string because zsh has no `PIPESTATUS` parameter at all (its array is lowercase `pipestatus` and 1-indexed, so `${PIPESTATUS[1]}` is empty too). An empty `EXIT=` reads like success, so a red gate gets skimmed as green. To get a command's status through a pipe, use `${pipestatus[1]}` or `set -o pipefail`; for long output, drop the pipe entirely — `cmd > tmp/out.log 2>&1; echo "EXIT=$?"`, then inspect the file. That last idiom is **foreground-only**. A `;`-separated list exits with its *last* statement's status, so the `echo` — not the command — is what a **backgrounded** Bash call reports: a job whose command died at 127 still notifies as "completed (exit code 0)", and a regression suite that never ran reads as a clean pass. `||` is no escape (`cmd > log 2>&1 || echo "FAILED=$?"` still exits 0). When backgrounding, either make the command the final statement and read the log for detail, or capture and re-raise its status — `rc=0; cmd > tmp/out.log 2>&1 || rc=$?; echo "EXIT=$rc" >> tmp/out.log; exit $rc` (initialize `rc`, or success prints the same empty `EXIT=` as above). Also reserved: `status` is a **read-only** built-in synonym for `$?`, so the natural exit-code idiom `out=$(cmd); status=$?` dies with `read-only variable: status` — every assignment does, `local status=$?` included; use `rc=$?`. (`pipestatus` is special but *not* read-only.) This bites hardest in capture-then-check helpers: the abort fires on the *assignment* line, **after** the captured command already ran, and it aborts the whole script — so the captured output is never printed, the shell may still exit 0, and a call that looks like it failed may have already committed its side effect (created the record, pushed the tag). Re-check external state before retrying. Likewise, zsh does **not** word-split unquoted *parameter* expansions: `p="a b"; set -- $p` leaves `$1="a b"` and `$2` empty (bash gives `a`/`b`), so a loop that builds arguments out of a variable silently passes one joined argument where two were meant, and the command fails complaining about the joined value. Unquoted command substitution `$(…)` *does* still split, which is what makes the asymmetry easy to miss. Force it with `${=p}`, use a real array (`p=(a b); cmd "$p[1]" "$p[2]"`), or just write the calls out.
- **Quote glob patterns in command flags** — `--include='*.md'`, `-name '*.rb'`. Unquoted, zsh expands them against the *cwd* before the command runs, and both outcomes are bad: no match aborts with `no matches found` and the command never executes; a match silently substitutes filenames (`-name *.rb` → `-name b.rb c.rb`), so the command runs on the wrong argument and exits 0. The abort is subshell-contained, so when the glob-bearing command sits in a **pipeline** a downstream `|| echo "none"` still fires and a search that never ran reads as a verified empty result; outside a pipeline it aborts the rest of the Bash call. A `||` fallback alone does not rescue it — the pipe is what masks it.
- **Build control and invisible characters from codepoints, never from backslash-u escapes.** A backslash-u escape in an `Edit`/`Write` payload lands as the *character*, not as the six source characters — verified: the escape for U+0000 wrote a real NUL byte, the one for U+200B a real ZWSP. Doubling the backslash writes two literal backslashes instead, and a repair `Edit` cannot fix the line because `old_string` round-trips the same way. (`\t`, `\n`, and `\xNN` are unaffected — the failure is specific to the backslash-u form.) A real **NUL** additionally makes the file binary, and the bundled `grep` (ugrep, run with `-I`) then skips it *silently*: a single-file search prints nothing and exits 1, while a `grep -r` over a tree exits **0** and prints matches from every other file, so a partial result reads as a complete one. `grep -a` / `--text` still matches, and `/usr/bin/grep` and `rg` announce `Binary file … matches` rather than going quiet. Write `0.chr` / `0xFF0C.chr('UTF-8')` (Ruby) or `String.fromCharCode(0)` (TS) instead — which also makes an otherwise-invisible fixture legible to a reviewer.

Own the code and move forward: modify in place, delete aggressively, embrace breaking changes, and never leave backups, duplicates, or compatibility layers behind. See [Technical Debt Prevention](standards/technical-debt-prevention.md) for the full rules.

## Output length

Effort governs how much thinking happens, not how much gets said. Length has to be asked for.

**In conversation.** Lead with the outcome — the first sentence after finishing answers "what happened" or "what did you find"; supporting detail comes after. Keep caveats short. When asked to explain something, give the high-level answer unless depth was requested. Shorten by dropping detail that doesn't change what the reader does next, not by compressing prose into fragments, arrow chains, or invented shorthand. Readable beats terse.

**In written deliverables.** Linear plan and completion comments, PR descriptions, spec bodies, and `/reflect` proposals are documents, and they run long by default. Match length to substance and stop: no filler sections, no restating the section above, no template headings kept because the template had them.

**This is about prose, never about coverage.** It does not govern how many findings a review reports, how many requirements a spec lists, or how many candidates a triage surfaces. Reporting less to look concise is the one failure this rule must not cause.

## Decision-Making & Anti-Patterns

You have autonomy to make good engineering decisions — architectural improvements, new abstractions, schema changes, API updates, cross-file refactors — without asking permission. Proceed directly when the solution is obvious, a codebase pattern exists, or a standard covers the scenario.

Stop and ask when genuine uncertainty remains: root cause still unclear after investigation, multiple valid solutions with significant trade-offs, 2+ attempts failed, or a business / security / usability call is needed. When you stop, give what you tried, the trade-offs, your recommendation, and a clear question.

Before reaching for a workaround — version pin/downgrade, error suppression, `any` cast, disabling a lint rule, partial migration, silent default for required config — stop and fix the root cause. These are signals to dig deeper, not shortcuts.

See [Problem-Solving Standards](standards/problem-solving.md) for the full decision framework, the seven workaround anti-patterns with their narrow exceptions, and the complexity-response template.

## Delegation

For complex multi-step tasks (>5 steps, multiple domains, high context usage), use the `/do` command pattern with TodoWrite and agent delegation.

Delegate work that is genuinely independent and big enough to deserve a fresh context — a wide multi-file investigation, parallel implementation across unrelated files, a scoped review. Do not delegate what finishes in a handful of tool calls, and do not spawn a subagent to check your own work: re-reading, re-running, and self-correction happen without being asked, so instructing them again only multiplies cost. When one agent can do it, use one, and keep spawn counts low overall.

The named review gates are the deliberate exception. `/quality-review`'s reviewer dispatches (`quality-reviewer` discovery; `quality-verifier` re-reviews and fix confirmations — including confirming fixes the orchestrator applied directly) and `/reflect`'s verifier bring a fresh context to the session's output as a mandated independent gate — that is not self-critique, and it stays.

### Waiting on delegated work

**Need the result before you can continue? Dispatch with `run_in_background: false`.** The call blocks and hands back the result, so there is nothing to wait for and nothing to write. This is the right default for a review, a fix batch, or an implementation whose output the next step consumes — which is nearly every in-flight dispatch.

**Don't need it yet? Leave it in the background and end the turn.** The harness re-invokes you when it finishes. Ending the turn is not abandoning the work.

**Never hold a turn open with a timed `sleep` to wait for something the harness already tracks.** A `for i in $(seq 1 22); do sleep 25; done` window cannot end early: it burns its full duration whether the agent finished in ten seconds or never started. Measured on one fleet run, two of four sessions lost **7.7 hours** to exactly this shape — 54% and 81% of their wall-clock — while the two sessions that dispatched synchronously lost none. This applies just as much when a human is watching: a session that sleeps through a nine-minute window it cannot exit is wasting the operator's time, not just the machine's. The `no-blind-sleep.sh` PreToolUse hook enforces it; a denied command means pick one of the three routes above, not retry with a different loop shape.

The one sanctioned poll is for work the harness genuinely cannot see — a detached test run, CI, a remote queue. Poll a completion **marker** so the wait ends when the work does: `n=0; until [ -f tmp/run.done ] || [ $n -ge 60 ]; do sleep 10; n=$((n+1)); done`.

## Memory

Auto memory persists learned context across sessions in `~/.claude/projects/<project>/memory/`. It is **gitignored and machine-local — never shared with the team.** Treat it as private scratch space, not a knowledge base.

- **MEMORY.md** — index of private notes; first 200 lines auto-loaded each session.
- **Topic files** — detailed private notes for specific domains.

### Where Knowledge Goes

The first question is **shared or private**, not *rule or fact*. Both rules *and* discovered facts usually belong in shared config — only transient, personal context belongs in memory.

**Shared** — committed to git, the whole team gets it:

- `~/.claude/` config (`CLAUDE.md`, `rules/`, `standards/`, `skills/`) → pushed to `alienfast/claude.git`. Cross-project, generic.
- Project config (`<project>/CLAUDE.md`, `<project>/.claude/rules/`) → committed to the project repo. Project-specific.

**Private** — gitignored, only on this machine:

- `~/.claude/projects/<project>/memory/` and `<project>/.claude/agent-memory/`.

Route by what the information is:

- Durable convention or "never do X here," project-specific → that project's `CLAUDE.md` or a `<project>/.claude/rules/*.md`.
- Durable rule that applies everywhere → `~/.claude/CLAUDE.md`, `standards/`, or a file-type `~/.claude/rules/*.md`.
- Durable discovered fact, pattern, or quirk the team should know → the shared layer too. Most of `<project>/CLAUDE.md` is exactly this. A useful discovery is **not** automatically "memory."
- Temporary, personal, or session-spanning context not worth committing → `memory/`.

Memory is the destination of last resort: if it's worth keeping and the team would benefit, promote it to shared config instead.

The `/reflect` skill automates this routing: at the `/quality-review` tail it turns session friction (thrashing, silently-worked-around skills, repeated corrections) into shared-config edits — auto-applying the small/safe ones (user-level `~/.claude` edits only on the keeper's machine, left uncommitted for their review; project-level edits inside a `/start wt` worktree check-gated and committed on the issue branch so they ride the merge), proposing the rest, and filing those proposals as a certified (`specified`) Linear issue (`Planned`) so they survive autonomous `/full` runs and are eligible for `/auto` pickup — except keeper batches (any `~/.claude` target), which file uncertified with the `keeper` label instead: `/auto` cannot ship cross-repo config work, so those wait for the keeper's interactive pickup. `/reflect sweep` audits a project's config against the actual codebase and de-duplicates accumulated drift.

### Multi-Session Safety

Memory files follow the same principles as git working tree protection:

- Only write memory entries relevant to your current work
- Do not overwrite or delete entries another session is actively writing
- Correct outdated or inaccurate entries when discovered
