# Description template

Read this when composing the PR body (`/pr-update` § Description Structure). Per-type variants:
[templates/feature.md](../templates/feature.md), [templates/bugfix.md](../templates/bugfix.md),
[templates/infrastructure.md](../templates/infrastructure.md). The Executive Summary's rules are in SKILL.md; the
shape is below.

```markdown
## Executive Summary

[Single-issue PR:]

**Problem:** [1–2 plain sentences: what users or the business hit, and why it matters
now. Concrete numbers where real. No file paths, no code, minimal jargon.]

**Solution:** [1–2 plain sentences, what changed in outcome terms, verbatim user-visible
strings in backticks where the change IS the copy.]

[Multi-issue PR (hotfix or release bundle) — in place of Problem/Solution:]

[Headline: 1–3 plain sentences — what this release is about, in the business's words.]

### [Theme — what the reader does or gets, e.g. Managing an organization]

[One sentence: the problem this theme solves.]

- [Outcome — what is better now; verbatim user-visible strings in backticks. No issue IDs.]
- [Outcome — a rode-along change with no issue goes here too]

### [Next theme]

[One sentence: its problem.]

- [Outcome]

[Optional one-liners — include only those that genuinely apply, omit the rest:]
- **For users:** [what changes in their experience — single-issue PRs; the themes cover it on a bundle]
- **Business impact:** [revenue, risk, cost, compliance, or operational effect]
- **Security & quality:** [notable hardening, test coverage, or reliability gains]

### Issues in this release

- BF-1716: [short label — enough to recognize the issue, not to explain it]
- BF-1763: [short label]

Also in this release, with no customer-visible change: BF-1698, BF-1703.

🔗 **Pull request:** [#<number> — <title>](<pr-url>)

## Summary

[1-2 sentence overview of what this PR accomplishes and why]

## [Major Category 1 - e.g., Infrastructure Changes]

### [Subcategory - e.g., Cloud SQL Enterprise Plus]

**[Feature Name]:**
- [Implementation detail verified in HEAD]
- [Configuration detail with actual values]
- [Benefit or impact]

**Implementation:**
- File: [link to main file](path/to/file.ts)
- Configuration: [link to config](path/to/config.yaml)

**Stack Commands:**
- `./stack command_name` - Description

**Documentation:**
- [Link to relevant docs](doc/path/to/doc.md)

[Repeat structure for each major category]

## Code Impact

| Category | Added | Removed | Net |
|---|---|---|---|
| App code | X | X | X |
| Unit tests | X | X | X |
| E2E tests | X | X | X |
| Stories | X | X | X |
| Mocks | X | X | X |
| Generated | X | X | X |
| Ops/Infra | X | X | X |
| Config/Assets | X | X | X |
| **Total** | **X** | **X** | **X** |

[1-2 sentence interpretation of what the numbers mean — e.g., "Production code reduced by X lines through Y. Net increase driven by new test coverage."]

## Breaking Changes

### [Area Affected]
- **What changed**: [Specific change]
- **Migration**: [Steps to migrate]
- **Impact**: [Who/what is affected]

## Dependencies

- Updated `package-name` to version X.Y.Z
- Added `new-package` for [specific purpose]
- Removed `old-package` (no longer needed)

## Testing

**[Test Category]:**
- ✅ [Specific test that validates the change]
- ✅ [Another specific test]

## Cost Impact

[If applicable - infrastructure cost changes]

**Production:**
- Current: $X/month
- Planned: $Y/month (with optimization Z)
- Benefit: [SLA/performance/reliability improvements]
```

## Code Impact category patterns

Category patterns live in [scripts/code-impact.awk](../scripts/code-impact.awk) (first-match-wins, most-specific first)
— edit them there to match project structure:

- `\.stories\.` — Storybook story files
- `mock|Mock` — Test mocks
- `generated|packages\/graphql\/` — Generated code (GraphQL codegen, etc.)
- `packages\/e2e\/` — E2E tests (whole Playwright package: specs, page objects, fixtures, support, config)
- `\.test\.[jt]sx?$|_spec\.rb$` — Unit tests (Vitest `*.test.ts[x]` + RSpec `*_spec.rb`)
- `ops\/` — Infrastructure/operations
- `lock\.yaml$|lock\.json$|\.lock$` — Lock files (skipped entirely)
- `\.(yml|yaml|json|css|scss|svg|md)$` — Config, locales, styles, assets

"App code" captures source files (ts, tsx, rb, …); config and assets are separated to keep the signal clean, and test
code is split into **Unit tests** / **E2E tests** so production churn reads true. The categorized breakdown often tells
a different story than raw totals (production code reduced while test coverage increased). If `cloc` is available,
`cloc --diff "$BASE" HEAD --git` gives an alternative per-language breakdown, but lacks categorization and does not
handle renames.
