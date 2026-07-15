---
name: triage
description: Triage and prioritize Linear backlog. Analyzes issues for staleness, blockers, and suggests priorities based on dependencies and capacity.
---

# Triage Skill - Backlog Analysis

You are an expert at analyzing and prioritizing software backlogs.

## When to Use

Use this skill when:

- The backlog needs cleanup
- Prioritization decisions need to be made
- Looking for stale or blocked issues

## Process

1. **Fetch the Backlog**

   ```bash
   linear-cli issues list --team ENG
   ```

2. **Analyze Dependencies**

   ```bash
   ~/.claude/scripts/linear-deps-graph.sh --team ENG
   ```

3. **Identify Issues**
   Look for:
   - **Stale issues**: No updates in 30+ days
   - **Blocked issues**: Dependencies not resolved
   - **Priority mismatches**: High priority but blocked
   - **Orphaned issues**: No assignee, no activity
   - **Uncertified issues**: Workable but lacking the `specified` label — invisible to `/auto`; route through `/spec` to certify (see [standards/issue-spec.md](../../standards/issue-spec.md)). Detect them by comparing `linear-cli issues list --team ENG -o json` label sets, or diffing against `linear-cli issues list --team ENG -l specified` (the default table view doesn't show labels)

4. **Generate Recommendations**

## Analysis Framework

### Staleness Check

- Last updated > 30 days ago = Stale
- Last updated > 60 days ago = Very stale (consider closing)
- No activity + no assignee = Orphaned

### Dependency Health

- Blocked by completed issues = Unblock
- Circular dependencies = Flag for resolution
- Long blocking chains = Risk

### Priority Assessment

- P1/P2 but blocked = Escalate blocker
- P3/P4 with no activity = Consider closing
- No priority set = Needs triage

## Output Format

```text
BACKLOG TRIAGE: Team ENG
════════════════════════════════════════

URGENT ATTENTION (3)
────────────────────────────────────────
ENG-101 [Stale 45d] Login bug - P1 but no activity
ENG-102 [Blocked] Payment flow - blocked by ENG-99
ENG-103 [Orphaned] API refactor - no owner

RECOMMENDED ACTIONS
────────────────────────────────────────
1. Unblock ENG-102: Complete ENG-99 or remove dependency
2. Assign ENG-103: Needs owner or close if abandoned
3. Update ENG-101: Stale P1 needs attention

HEALTH SUMMARY
────────────────────────────────────────
Total issues: 45
Blocked: 8 (17%)
Stale: 12 (26%)
Healthy: 25 (55%)
```

## Commands Used

```bash
# List all issues for a team
linear-cli issues list --team ENG

# Check dependencies (emits {nodes, edges} JSON — see Discovery Commands below)
~/.claude/scripts/linear-deps-graph.sh --team ENG

# Update priority
linear-cli issues update ENG-123 --priority 2

# Add a comment about triage
linear-cli issues comment ENG-123 --body "Triaged: Needs unblocking before sprint"
```

## Discovery Commands

`linear-cli` has no dependency-aware search flags, so derive blocked/blocking/blocked-by from the team dependency graph (`linear-deps-graph.sh` emits `{nodes, edges}`) with `jq`, and use `search issues` for keyword/state. Fetch the graph once and reuse it:

```bash
TERMINAL='["Done","Canceled","Cancelled","Duplicate","Ready For Release"]'
GRAPH=$(~/.claude/scripts/linear-deps-graph.sh --team ENG)

# Find all blocked issues (>=1 unresolved blocker) that need attention
printf '%s' "$GRAPH" | jq -r --argjson term "$TERMINAL" '
  (.nodes | map({(.identifier): .state.name}) | add) as $sm
  | [.edges[] | select(.type=="blocks")] | group_by(.to)
  | map({issue: .[0].to, blockers: [.[].from]})
  | .[] | select(any(.blockers[]; . as $b | ($term | index($sm[$b] // "?")) == null))
  | "\(.issue) ⟵ blocked by \(.blockers | join(", "))"'

# Find work blocked by a specific bottleneck (e.g. ENG-100)
printf '%s' "$GRAPH" | jq -r '[.edges[] | select(.type=="blocks" and .from=="ENG-100") | .to][]'

# Best-effort circular dependencies — mutual A↔B blocks. (Longer cycles are not
# detected; this catches the common two-issue case. Escalate anything it surfaces.)
printf '%s' "$GRAPH" | jq -r '
  [.edges[] | select(.type=="blocks")] as $e
  | [$e[] as $x | $e[] | select(.from==$x.to and .to==$x.from and .from < .to) | "\(.from) ↔ \(.to)"] | unique[]'

# Search for work by keyword, filtered by state. NOTE: `search issues` has NO --team
# flag — it searches the whole workspace; --filter runs on returned fields (state.name),
# not team. To scope by team, use `issues list --team ENG` (above) or the api.
linear-cli search issues "authentication" --filter 'state.name=Backlog'
```

**Pro tip:** Run the blocked-issues recipe weekly to identify and unblock stuck work.

## Best Practices

1. **Regular cadence** - Triage weekly or bi-weekly
2. **Be decisive** - Close issues that won't be done
3. **Document reasoning** - Add comments explaining priority changes
4. **Involve stakeholders** - Flag issues needing product input
