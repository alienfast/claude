# Sweep mode (`/reflect sweep [project-path]`)

Read this when `/reflect` is invoked with the `sweep` argument: a broad audit of accumulated drift — not
session-driven. Runnable manually or on a schedule.

## Step 1 — Scope

Resolve the target project (arg, else current). Collect its `<project>/CLAUDE.md` and `<project>/.claude/rules/*.md`,
plus the user-level `~/.claude/CLAUDE.md`, `~/.claude/rules/*.md`, and `~/.claude/standards/*.md` that the project's
stack makes relevant. Sweep requires a project — ask for a path if none resolves.

## Step 2 — Fan out audit agents (parallel)

Split the config into slices (one agent per file or small group). Each agent reads its slice **and inspects the actual
codebase** to test every claim and instruction:

```md
Task for general-purpose: Audit config against reality.
Files: <slice>
Project root: <path>
For each instruction/claim in the file: verify it against the codebase — is it still true? Has a script/command/pattern superseded it (e.g. a manual step now automated)? Do referenced paths, commands, scripts, or flags still exist? Quote the codebase evidence.
Return findings: [{ file, line_or_claim, status: stale|contradicted|duplicate|orphaned-ref|ok, evidence, proposed_fix }].
Only report non-ok items.
```

## Step 3 — Dedup pass

Across all slices, find overlapping or redundant guidance (the same rule stated in two files, a CLAUDE.md bullet
duplicating a rule). Propose consolidation to the most specific correct home.

## Step 4 — Triage, apply, surface

Run findings through the three gates — with the session-mode removal invariant applying here too: **any deletion is
`propose`, never `apply-now`.** In sweep, `apply-now` is limited to **in-place corrections that remove no guidance** —
fixing a stale command, path, or flag to its verified-current value. Any deletion — a now-false line, an orphaned
reference, an exact duplicate — is `propose`, because an audit agent can mistake a correct-but-externally-referenced
rule for dead config (a migration invoked only from a CI yaml or Makefile the agent never read). `propose` also covers
merging rules, restructuring a section, and anything needing judgment. Apply the in-place corrections to the working
tree, never commit; surface the rest as diffs.

**A stale comment or docblock in source code is an `apply-now` in-place correction — fix it, never file it.** A sweep
reads application code to test config claims, so it routinely diagnoses comments asserting behavior the code no longer
has. `rules/comments.md` § Scope puts these in scope and forbids deferring them: the "file the change does not otherwise
touch" exception licenses *leaving* a comment alone, never converting it into an issue. Fix them in the working tree
with the other in-place corrections and list them in the Config Audit report. Escalate to `propose` only when the fix
needs a behavior decision the sweep cannot make (the comment may be right and the *code* wrong).

## Step 5 — Output

```text
Config Audit — <project>:
- Stale/contradicted: <N> — <file:claim — fix, applied|proposed>
- Duplicates: <N> — <consolidation proposed>
- Applied: <N> (always uncommitted — sweep never commits)
- Proposed: <N>
- Clean: <files audited with no findings>
```

**Scheduling (opt-in, not auto-installed):** wire a recurring sweep via the `schedule` skill (cloud cron) or `loop`,
e.g. weekly `/reflect sweep <project-path>`. Document it; never install it silently.
