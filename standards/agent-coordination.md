# Agent Coordination Patterns

This document defines coordination patterns for parallel and sequential agent execution in Claude Code.

## Parallel vs Sequential Execution Decision Matrix

### Use Parallel Execution When:

- Tasks are **independent** - results don't depend on each other
- Tasks can be **validated separately**
- No **shared resources** or potential conflicts
- **Time-sensitive** - parallel execution provides significant speed benefits

### Use Sequential Execution When:

- Tasks are **dependent** - later tasks need earlier results
- Tasks **share resources** that could cause conflicts
- **Quality gates** - each step must be validated before proceeding
- **Complex integration** - results need careful coordination

## Parallel Execution Patterns

### Research Tasks

```md
# Independent research queries - High Parallelism Pattern

[Single message with multiple Task calls - aim for 5-15 parallel subagents]
Task 1 for research-subagent: Market analysis for Product A
Task 2 for research-subagent: Competitive landscape for Product B
Task 3 for research-subagent: Technical feasibility for Feature C
Task 4 for research-subagent: Regulatory requirements for Feature C
Task 5 for research-subagent: Cost analysis for Product A production
Task 6 for research-subagent: Consumer demand trends for Product B
...
# Continue up to 15-20 parallel research tasks for maximum efficiency
```

### Development Tasks

```md
# Independent component development

[Single message with multiple Task calls]
Task 1 for developer: Implement UserProfile component
Task 2 for developer: Implement ProductCatalog component
Task 3 for developer: Implement ShoppingCart component
```

### Mixed Agent Types

```md
# Different agents working on related but independent tasks

[Single message with multiple Task calls]
Task 1 for architect: Design authentication system architecture
Task 2 for technical-writer: Document API endpoints for payments
Task 3 for quality-reviewer: Security audit of existing auth code
```

## Sequential Execution Patterns

### Dependent Development Flow

```md
# Task 1: Architecture first

Task for architect: Design user authentication system

# Task 2: Implementation after architecture

Task for developer: Implement authentication based on architecture

# Task 3: Review after implementation

Task for quality-reviewer: Security review of authentication implementation
```

### Research → Development Flow

```md
# Task 1: Research existing patterns

Task for research-lead: Research best practices for user onboarding flows

# Task 2: Design based on research

Task for architect: Design onboarding system based on research findings

# Task 3: Implement the design

Task for developer: Build onboarding flow per architecture specifications
```

## Coordination Checkpoints

### For Parallel Tasks

- **Launch**: All agents start simultaneously
- **Monitor**: Track progress independently
- **Sync Points**: Define where results need to be integrated
- **Validation**: Test integration points after completion

### For Sequential Tasks

- **Handoff**: Clear completion criteria before next task starts
- **Validation**: Quality gates between phases
- **Context**: Pass relevant context from previous task
- **Rollback**: Plan for backing out if later stages fail

## Error Handling in Parallel Execution

### Partial Failures

- Continue with successful tasks
- Identify which parallel tasks failed
- Re-run failed tasks or adjust scope
- Integrate successful results

### Cascading Failures

- Stop dependent tasks if critical parallel task fails
- Provide clear error context to remaining agents
- Consider fallback strategies
- Document impact on overall plan

## Performance Optimization

### Batching Guidelines

- **Small research tasks** (< 5 min): Batch 10-15 together for maximum parallelism
- **Medium research tasks** (5-15 min): Batch 5-10 together
- **Large research tasks** (> 15 min): Batch 3-5 together with progress monitoring
- **Development tasks** (< 5 min): Batch 3-5 together
- **Medium dev tasks** (5-15 min): Batch 2-3 together
- **Large dev tasks** (> 15 min): Execute individually with progress monitoring
- **Resource-intensive**: Consider system load and agent limits (max 20 parallel agents)

### Tool Call Efficiency

- Use single message for multiple independent Task calls
- Avoid sequential Task calls when parallel execution is possible
- Monitor agent capacity and adjust batch size accordingly
- Balance parallelism with quality control needs

## Quality Assurance

### Parallel Validation

- Define clear acceptance criteria for each parallel task
- Test integration points thoroughly
- Validate that parallel results work together
- Document any conflicts or integration issues

### Sequential Validation

- Quality gates between each phase
- Comprehensive testing before proceeding
- Clear rollback procedures if validation fails
- Maintain audit trail of decisions and changes

This coordination framework ensures optimal performance while maintaining code quality and system reliability.
