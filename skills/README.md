# Claude Skills Directory

Reusable skills: workflows Claude loads into the current conversation when a trigger phrase or `/name` invokes them.
The harness lists every installed skill with its description at session start, and that listing is the catalog; run
`/skill-doctor` to see what each one costs in context and how often it is used. This file is the guide to writing one.

## Skills, agents, and scripts

- A **skill** is a workflow that runs in the current context: steps, decisions, gates. It can delegate to agents and
  call scripts.
- An **agent** (`agents/*.md`) is a persona with its own context window that the main thread delegates to. Add one only
  when a fresh context or a pinned model/effort adds material value.
- A **script** carries machinery a skill would otherwise make the model re-type. See
  [Policy in markdown, machinery in scripts](#policy-in-markdown-machinery-in-scripts).

### Claude-side tooling is a skill, not a package

A tool whose only consumer is a Claude session belongs in `<project>/.claude/skills/<name>/` with its scripts under
`scripts/`, in whatever language they were written (Python is the conventional choice, as in the bundled pdf/docx/xlsx
skills). Keep it project-level and shared, never one person's; add an agent only where delegation adds material value;
propose a `@repo/*` package, a CLI, or a product surface only when the user has named a product or deployment use. Ask
about the use before proposing a structure.

## Creating a skill

### Directory structure

```text
skills/
  your-skill-name/
    SKILL.md          # required: frontmatter + the workflow
    references/       # optional: rare-path detail, read on demand
    templates/        # optional: output templates
    scripts/          # optional: tested helper scripts
```

### Frontmatter

```yaml
---
name: your-skill-name
description: "Does X for Y. Use when the user says 'x', 'do x', or invokes /your-skill-name."
argument-hint: "[mode] [ISSUE-ID]"  # optional: shown in the slash-command picker
model: sonnet                       # optional: pin the model the skill runs on
effort: high                        # optional: pin the effort
allowed-tools: ["Bash", "Read"]     # optional: restrict the tools available
---
```

- `name` (required): kebab-case, identical to the directory name. The harness registers it as the skill's `/name`
  identity, so a title-case name shows up as `/Fleet Forecast` among `/fleet-*` siblings.
- `description` (required): a trigger statement — see [Description](#description).
- `version` (optional): most workflow skills here omit it.

### Description

The description is always in context and is the only thing the model sees when deciding whether to invoke the skill.

- Write it as a trigger statement of at most about 400 characters, with the key use case first. The harness truncates
  each listing entry at 1,536 characters, so text past that is never read.
- Third person: **what** the skill does, then **when** — the phrases a user would actually say, and `/name`.

```yaml
# Good
description: "Generate or update GitHub PR titles and descriptions from the actual diff. Use when the user says 'open a PR', 'update the PR', or asks for a PR description."

# Too vague, no trigger, wrong voice
description: "Updates dependencies"
description: "Handles package version management"
description: "I help you update your dependencies"
```

## House rules

### Progressive disclosure

A skill pays for itself in three places: its description in every session, its body when invoked, and whatever
supporting files it reads. Keep each tier as small as its job allows.

- **SKILL.md stays under 500 lines and about 20 KB.** After compaction the harness keeps only the first 5,000 tokens of
  each invoked skill (25,000 across all of them), so put the invariants and the step list first. Detail that sits
  below that cut is gone for the rest of a long session.
- **Rare paths go in `references/<topic>.md`**, each named at the step that needs it: "Read `references/rollback.md`
  when the merge fails." A pointer at the top of the file ("see references/ for details") loads nothing useful and
  gets ignored.
- **`@path` imports do not expand inside SKILL.md** — the literal `@references/x.md` text reaches the model. Point at
  supporting files with an explicit Read instruction instead.
- **The description is a trigger, not a manual.** Everything about how to run the skill belongs in the body.

Example from [standardize-tooling](standardize-tooling/SKILL.md): the body declares the target end state and the
convergence steps; the apply step points at `references/converge.md` for the source-of-truth map and per-attribute
apply steps, and at `references/publishing.md` only when detection reports the package as published.

### Policy in markdown, machinery in scripts

A skill's markdown carries decisions, routing, and prompts. Multi-line procedural bash belongs in a tested script —
skill-local (`skills/pr-update/scripts/verify-feature.sh`, `skills/standardize-tooling/scripts/detect-state.sh`) or the
shared `~/.claude/scripts/` — with a verdict-line stdout contract: the first line is the verdict and the skill branches
on it (see `~/.claude/scripts/start-wt-verify.sh` — `VERIFIED`/`FAILED-*` — and `finish-merge.sh`). Inline bash the
model must re-emit verbatim is a transcription-drift surface: more than a few lines, or any duplication across skills,
means extract to a script. Scripts are not just length management.

### Never write a literal positional token in SKILL.md

The Skill tool substitutes the invocation arguments into every dollar-digit token of a SKILL.md body at load time —
prose and fenced code alike; named variables such as `$BASE` are untouched. The file on disk stays correct, so the
corruption is invisible to every grep and lint and exists only in what the model reads, and an argument-free invocation
leaves the token literal and hides it. Anything that needs awk fields or shell positional parameters goes in
`scripts/` and is called by path; prose about positional parameters says "the first positional parameter", never the
token.

### Quality gates and models

- Define success criteria and the validation that proves them, plus what to do on failure.
- Test on the model the skill will run on: an unpinned skill inherits the session's model, a `model: sonnet` pin has to
  hold up on Sonnet, and Haiku suits only narrow classification (it does not support the `effort` parameter).

## Scopes and precedence

| Scope | Location | Use |
| ----- | -------- | --- |
| Managed | set by an organization's managed settings | policy-enforced skills |
| User | `~/.claude/skills/` (this directory) | cross-project workflows |
| Project | `<project>/.claude/skills/` | project-specific workflows, shared with the team |
| Plugin | a plugin's `skills/` | invoked namespaced as `plugin:skill` |

When two skills share a name, managed wins over user, and user wins over project. Plugin skills are namespaced, so they
never collide with the others.

## Resources

- [Claude Code skills documentation](https://docs.anthropic.com/en/docs/claude-code/skills)
- The `skill-creator` skill, installed by `update.sh`, for scaffolding a new skill
- Local examples: [dependency-updater](dependency-updater/SKILL.md) (agent delegation),
  [pr-update](pr-update/SKILL.md) (scripts and templates), [standardize-tooling](standardize-tooling/SKILL.md)
  (references read on demand)
- Standards skills lean on: [semver](../standards/semver.md), [git](../standards/git.md),
  [agent-coordination](../standards/agent-coordination.md)
