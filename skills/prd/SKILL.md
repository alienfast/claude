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
   Use `linear-cli issues create` with:
   - Clear, action-oriented title
   - Problem/Context section
   - Requirements (must-have vs nice-to-have)
   - Success criteria (testable, specific)

3. **Break Down into Sub-Issues**
   Each sub-issue should:
   - Be completable in one focused session (<150k tokens of context)
   - Have clear, verifiable success criteria
   - Include verification commands (tests to run)
   - Define boundaries (what's in/out of scope)

4. **Set Up Dependencies**
   Use `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` to create dependency chains (see Example Commands).

## Ticket Structure

```markdown
## Problem/Context
[1-2 sentences explaining why this work is needed]

## Requirements
### Must Have
- [ ] Requirement 1
- [ ] Requirement 2

### Nice to Have
- [ ] Optional feature

## Success Criteria
- [ ] Specific, testable criterion 1
- [ ] Specific, testable criterion 2

## Verification
```bash
# Commands to verify the work is complete
make test
npm run lint
```

## Boundaries
### In Scope
- What this ticket covers

### Out of Scope
- What should be separate tickets
```

## Example Commands

```bash
# Create parent issue with description from file
~/.claude/scripts/linear-stdin.sh tmp/prd-description.md issues create "User Authentication System" \
  --team ENG \
  --priority 2 \
  -d -

# Create a sub-issue linked to a parent. `linear-cli issues create` has no --parent
# flag (and its --data silently drops parentId), so use the helper — it creates the
# issue, links the parent via `relations parent`, and verifies. Write the body to a file first.
#   ...write the description to tmp/sub-issue-description.md via the Write tool...
~/.claude/scripts/linear-create-child.sh ENG-100 ENG Planned "Add JWT refresh tokens" tmp/sub-issue-description.md

# Set a blocking dependency: ENG-101 blocks ENG-102 (i.e. ENG-102 is blocked by ENG-101).
# Use `-r blocks` with the blocker FIRST — the `blocked-by` enum value is broken on
# linear-cli 0.3.26 (it sends "blockedBy", which the API rejects).
linear-cli relations add ENG-101 ENG-102 -r blocks
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
2. **Include test commands** - Always specify how to verify completion
3. **Be explicit about scope** - Prevent scope creep with clear boundaries
4. **Use Labels** - Add `agent-ready` label for tickets ready for AI implementation
5. **Establish dependencies** - Use `linear-cli relations add <BLOCKER> <BLOCKED> -r blocks` to show work order
6. **Search first** - Check for existing related issues before creating duplicates
