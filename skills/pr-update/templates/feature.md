# Feature PR Template

Use this template when adding new features or capabilities.

```markdown
## Summary

[1-2 sentence overview: What feature is this adding and why is it valuable?]

## Feature Overview

### [Feature Name]

**What it does**:

- [Primary capability]
- [Secondary capability]
- [Additional capability]

**Why we need it**:

- [Business/technical justification]
- [Problem it solves]
- [Expected impact]

**Implementation**:

- Core logic: [link to main file](path/to/file.ts)
- API endpoints: [link to routes](path/to/routes.ts)
- UI components: [link to components](path/to/components/)
- Configuration: [link to config](path/to/config.yaml)

## User Experience

**Before**:

- [What users had to do previously]

**After**:

- [What users can now do]

**Example Usage**:

```typescript
// Code example showing the new feature in action
import { newFeature } from './module';

const result = await newFeature({
  option: 'value'
});
```

## API Changes

### New Endpoints

- `POST /api/resource` - [Description]
- `GET /api/resource/:id` - [Description]

### Request/Response Examples

```json
// POST /api/resource
{
  "field": "value"
}

// Response
{
  "id": "123",
  "status": "success"
}
```

## Configuration

### New Settings

```yaml
feature:
  enabled: true
  option: value
  timeout: 30s
```

### Environment Variables

- `FEATURE_API_KEY` - [Description, how to obtain]
- `FEATURE_ENDPOINT` - [Description, default value]

## Dependencies

- Added `package-name@x.y.z` - [Why needed]
- Updated `existing-package` to x.y.z - [What changed, compatibility notes]

## Testing

**Unit Tests**:

- ✅ [Feature X] handles valid inputs correctly
- ✅ [Feature X] rejects invalid inputs with proper errors
- ✅ [Edge case Y] works as expected

**Integration Tests**:

- ✅ [Feature X] integrates with [System Y]
- ✅ [End-to-end flow Z] completes successfully

**Manual Testing**:

- ✅ Tested in development environment
- ✅ Tested edge cases: [list specific scenarios]
- ✅ Tested performance with [X] concurrent users

## Documentation

- [User guide](docs/user-guide.md) - How to use the feature
- [API docs](docs/api.md) - API reference
- [Migration guide](docs/migration.md) - For existing users

## Breaking Changes

[If none, write "None"]

### [Area Affected]

- **What changed**: [Specific change]
- **Migration path**: [Steps users need to take]
- **Impact**: [Who is affected and how]

## Performance Impact

- Response time: [measurement]
- Memory usage: [measurement]
- Database queries: [count/impact]

## Security Considerations

- Authentication: [How feature is protected]
- Authorization: [Permission requirements]
- Data validation: [Input sanitization approach]
- Rate limiting: [If applicable]

## Rollout Plan

- [ ] Deploy to staging
- [ ] Run automated tests
- [ ] Manual smoke testing
- [ ] Monitor metrics for 24h
- [ ] Deploy to production
- [ ] Feature flag: [If using gradual rollout]

---

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>

```
