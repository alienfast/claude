# PR Title Formats

Choose the most appropriate format based on the primary type of change in your PR.

## Infrastructure Changes

**Format**: "Enterprise [resource] with [key feature] and [secondary feature]"

**Examples**:

- ✅ "Enterprise Cloud SQL infrastructure with Advanced DR and staging environment"
- ✅ "Production Kubernetes cluster with autoscaling and monitoring"
- ✅ "CDN deployment with edge caching and SSL termination"

**When to use**: Major infrastructure deployments, cloud resource provisioning, architecture changes.

## Feature Additions

**Format**: "Add [feature] with [benefit]"

**Examples**:

- ✅ "Add GraphQL subscription support with real-time updates"
- ✅ "Add OAuth authentication with Google and GitHub providers"
- ✅ "Add PDF export with custom templates"

**When to use**: New capabilities, features, or functionality that didn't exist before.

## Bug Fixes

**Format**: "Fix [specific issue] in [area]"

**Examples**:

- ✅ "Fix memory leak in WebSocket connection handling"
- ✅ "Fix race condition in authentication middleware"
- ✅ "Fix incorrect timezone handling in date picker"

**When to use**: Corrections to existing functionality, bug resolutions.

## Refactoring

**Format**: "Refactor [area] to [improvement]"

**Examples**:

- ✅ "Refactor authentication layer to support OAuth providers"
- ✅ "Refactor database queries to use connection pooling"
- ✅ "Refactor component structure to improve reusability"

**When to use**: Code improvements without changing external behavior.

## Multiple Areas

**Format**: "[Primary change] and [secondary change]"

**Examples**:

- ✅ "Update database schema and add migration tooling"
- ✅ "Add CI/CD pipeline and deployment documentation"
- ✅ "Upgrade dependencies and fix compatibility issues"

**When to use**: PRs that touch multiple distinct areas with roughly equal importance.

## Performance Improvements

**Format**: "Optimize [area] for [benefit/metric]"

**Examples**:

- ✅ "Optimize image loading for 50% faster page render"
- ✅ "Optimize database queries reducing response time by 3x"
- ✅ "Optimize bundle size cutting load time by 2 seconds"

**When to use**: Changes focused on improving speed, efficiency, or resource usage.

## Documentation

**Format**: "Document [area/feature] with [type of content]"

**Examples**:

- ✅ "Document API endpoints with OpenAPI specification"
- ✅ "Document deployment process with runbooks"
- ✅ "Document architecture with diagrams and decision records"

**When to use**: Documentation-only changes.

## Anti-patterns

**DON'T use these formats**:

- ❌ "PR deployment" (too vague)
- ❌ "Various fixes and improvements" (not specific)
- ❌ "Update code" (meaningless)
- ❌ "WIP" or "Work in progress" (not descriptive)
- ❌ "Misc changes" (lazy)
- ❌ "Small fixes" (unhelpful)
- ❌ "Updates" (what kind of updates?)

## Title Quality Checklist

- [ ] Specific enough that reviewers know what to expect
- [ ] Under 72 characters (GitHub UI limit)
- [ ] Uses imperative mood ("Add X", not "Added X" or "Adding X")
- [ ] Describes the outcome, not the process
- [ ] No jargon that non-technical stakeholders wouldn't understand (when possible)
- [ ] Accurate to what's actually in the final code state
