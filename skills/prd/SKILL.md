---
name: prd
description: Create agent-friendly Linear tickets with PRDs, sub-issues, and clear success criteria. Use when planning features or breaking down work for agentic coding.
---

# PRD Skill - Create Agent-Friendly Tickets

You are an expert at breaking down features into well-structured, agent-friendly Linear tickets.

## When to Use

Use this skill when:

- Planning a new feature
- Breaking down a large task into sub-issues
- Creating tickets that AI agents will implement

## Process

1. **Understand the Request**
   - Ask clarifying questions if the scope is unclear
   - Identify the core problem being solved

2. **Create the Epic/Parent Issue**
   Use `linear-cli issues create` with a clear, action-oriented title and a body following the canonical spec template in [standards/issue-spec.md](../../standards/issue-spec.md) — problem, desired outcome, requirements (must-have vs nice-to-have), testable success criteria, boundaries.

3. **Break Down into Sub-Issues**
   Each sub-issue body is itself a spec (same template) and should:
   - Be completable in one focused session (<150k tokens of context)
   - Have clear success criteria stated as observable outcomes
   - Define boundaries (what's in/out of scope)

4. **Set Up Dependencies**
   Use `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` to create dependency chains (see Example Commands).

5. **Certify**
   Apply the `specified` label to **every** created issue — parent and each sub-issue:

   ```bash
   ~/.claude/scripts/linear-add-label.sh ENG-100 specified
   ```

   `specified` marks a certified spec — the gate `/auto` picks up ([standards/issue-spec.md](../../standards/issue-spec.md)). Label post-create rather than via `issues create -l`, so a label problem can never fail issue creation. On exit 2, surface the helper's create-label pointer and tell the user certification is incomplete.

## Spec Shape

The canonical template and quality bar live in [standards/issue-spec.md](../../standards/issue-spec.md): `Problem` → `Desired Outcome` → `Requirements` (Must/Nice checkboxes) → `Success Criteria` (testable checkboxes) → `Boundaries` (In/Out of Scope).

Specs are problem + outcomes + success criteria only — **no implementation planning** (`/start` Step 6 designs the how, in plan mode, at execution time) and **no verification-command blocks** (project quality gates own that). Checkboxes are load-bearing: `/start` treats them as requirements and `/finish` checks them off.

## Example Commands

```bash
# Create parent issue with description from file
~/.claude/scripts/linear-stdin.sh tmp/prd-description.md issues create "User Authentication System" \
  --team ENG \
  --priority 2 \
  -d -

# Create a sub-issue linked to a parent. `linear-cli issues create` has no --parent
# flag (set the parent's UUID via `--data` parentId instead), but prefer the helper — it
# links via `relations parent` and verifies the link, failing on an orphan. Write the body to a file first.
#   ...write the description to tmp/sub-issue-description.md via the Write tool...
~/.claude/scripts/linear-create-child.sh ENG-100 ENG Planned "Add JWT refresh tokens" tmp/sub-issue-description.md

# Set a blocking dependency: ENG-101 blocks ENG-102 (i.e. ENG-102 is blocked by ENG-101).
# Use `-r blocks` with the blocker FIRST — the `blocked-by` enum value is broken on
# linear-cli 0.3.26 (it sends "blockedBy", which the API rejects).
linear-cli relations add ENG-101 ENG-102 -r blocks

# Certify each created issue (read-merge-set — `issues update -l` alone would replace the label set)
~/.claude/scripts/linear-add-label.sh ENG-100 specified
~/.claude/scripts/linear-add-label.sh ENG-101 specified
```

**Important:** For any description or body content longer than a single line, write it to `tmp/` first and use `~/.claude/scripts/linear-stdin.sh` to pass it via stdin. Do NOT use shell operators (`<`, `|`, `$()`) in Bash commands — they trigger permission prompts regardless of allow-list rules.

## Discovering Related Work

Before creating tickets, search for existing related work:

```bash
# Find existing work on this topic. NOTE: `search issues` has no --team flag — it
# searches the whole workspace. Scope by team with `issues list --team ENG` or the api.
linear-cli search issues "authentication"

# Look for related work / potential blockers, then inspect dependencies via the graph
linear-cli search issues "user database"
~/.claude/scripts/linear-deps-graph.sh --team ENG    # {nodes, edges} — see /triage for jq recipes
```

**Pro tip:** After creating tickets, establish dependencies directly with `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` (blocker first; the `blocked-by` enum is broken on 0.3.26).

## Best Practices

1. **Size tickets appropriately** - Each should be 1-4 hours of focused work
2. **State success criteria as observable outcomes** - Verification commands and technical approach belong to `/start`, not the ticket
3. **Be explicit about scope** - Prevent scope creep with clear boundaries
4. **Certify every ticket** - Process step 5 applies the `specified` label; `/auto` only ships certified issues
5. **Establish dependencies** - Use `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` to show work order
6. **Search first** - Check for existing related issues before creating duplicates
