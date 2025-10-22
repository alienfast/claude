# Testing Strategies for Deprecation Migration

Approaches to ensure safe migration from deprecated code with comprehensive test coverage.

## Pre-Migration Testing

### Establish Baseline

Before changing any deprecated code:

```bash
# 1. Ensure all tests pass
npm test

# 2. Record current test coverage
npm test -- --coverage

# 3. Save coverage report for comparison
cp coverage/coverage-summary.json coverage/baseline-coverage.json

# 4. Document current behavior
# Create snapshot tests or golden files
```

### Add Missing Tests

If deprecated code lacks tests:

```typescript
// 1. Test current (deprecated) behavior first
describe('UserProfile (baseline)', () => {
  it('loads user data on mount', async () => {
    const { getByText } = render(<UserProfile userId="123" />);

    await waitFor(() => {
      expect(getByText('John Doe')).toBeInTheDocument();
    });
  });

  it('handles errors', async () => {
    // Mock error scenario
    server.use(
      rest.get('/api/user', (req, res, ctx) => {
        return res(ctx.status(500));
      })
    );

    const { getByText } = render(<UserProfile userId="123" />);

    await waitFor(() => {
      expect(getByText(/error/i)).toBeInTheDocument();
    });
  });
});
```

## Migration Testing Pattern

### Dual Implementation Testing

Run both old and new implementations side-by-side:

```typescript
describe('Date formatting migration', () => {
  const testCases = [
    { input: '2025-01-15', expected: '01/15/2025' },
    { input: '2025-12-31', expected: '12/31/2025' },
    { input: 'invalid', expected: 'Invalid Date' },
  ];

  describe('deprecated moment implementation', () => {
    testCases.forEach(({ input, expected }) => {
      it(`formats ${input} as ${expected}`, () => {
        const result = formatDateMoment(input); // Old implementation
        expect(result).toBe(expected);
      });
    });
  });

  describe('modern date-fns implementation', () => {
    testCases.forEach(({ input, expected }) => {
      it(`formats ${input} as ${expected}`, () => {
        const result = formatDateModern(input); // New implementation
        expect(result).toBe(expected);
      });
    });
  });

  describe('equivalence', () => {
    testCases.forEach(({ input }) => {
      it(`produces same output for ${input}`, () => {
        const oldResult = formatDateMoment(input);
        const newResult = formatDateModern(input);
        expect(newResult).toBe(oldResult);
      });
    });
  });
});
```

### Snapshot Testing

Capture behavior before and after migration:

```typescript
describe('Component migration snapshots', () => {
  it('renders identically after hooks migration', () => {
    const { container } = render(<UserProfile userId="123" />);

    // Snapshot should match before and after migration
    expect(container).toMatchSnapshot();
  });
});
```

## Regression Prevention

### Visual Regression Testing

For UI component migrations:

```typescript
// Storybook + Chromatic/Percy
export const Default = () => <Button>Click Me</Button>;

// Take screenshot before and after migration
// Visual diff will catch unexpected changes
```

### Integration Testing

Test deprecated code in real scenarios:

```typescript
describe('End-to-end user flow', () => {
  it('completes checkout flow', async () => {
    // Test entire flow that uses deprecated API
    await userEvent.type(screen.getByLabelText('Email'), 'test@example.com');
    await userEvent.click(screen.getByRole('button', { name: /checkout/i }));

    // Verify final state
    expect(await screen.findByText(/order confirmed/i)).toBeInTheDocument();
  });
});

// This test should pass before AND after migration
```

## Testing React Migrations

### Class to Hooks Migration

```typescript
describe('UserProfile migration', () => {
  const setup = () => {
    const user = { id: '123', name: 'John Doe' };
    server.use(
      rest.get('/api/user/123', (req, res, ctx) => {
        return res(ctx.json(user));
      })
    );
    return { user };
  };

  // Test both implementations
  describe.each([
    ['class component', UserProfileClass],
    ['hooks component', UserProfileHooks],
  ])('%s', (name, Component) => {
    it('loads and displays user', async () => {
      const { user } = setup();
      render(<Component userId="123" />);

      expect(await screen.findByText(user.name)).toBeInTheDocument();
    });

    it('handles loading state', () => {
      render(<Component userId="123" />);
      expect(screen.getByText(/loading/i)).toBeInTheDocument();
    });

    it('cleans up on unmount', async () => {
      const { unmount } = render(<Component userId="123" />);

      // Trigger async operation
      await waitFor(() => screen.getByText(/john doe/i));

      // Unmount before completion
      unmount();

      // Should not cause warnings/errors
      expect(console.error).not.toHaveBeenCalled();
    });
  });
});
```

### Lifecycle Method Migration

```typescript
describe('componentWillReceiveProps → useEffect', () => {
  it('updates when props change', async () => {
    const { rerender } = render(<DataFetcher id="1" />);

    expect(await screen.findByText('Data for ID: 1')).toBeInTheDocument();

    // Change props
    rerender(<DataFetcher id="2" />);

    // Should fetch new data
    expect(await screen.findByText('Data for ID: 2')).toBeInTheDocument();
  });
});
```

## Testing API Changes

### Deprecated Function Migration

```typescript
describe('API migration', () => {
  const mockData = { users: [{ id: '1', name: 'Alice' }] };

  beforeEach(() => {
    // Mock both old and new APIs
    vi.spyOn(legacyApi, 'fetchUsers').mockResolvedValue(mockData);
    vi.spyOn(modernApi, 'getUsers').mockResolvedValue(mockData);
  });

  it('deprecated API returns expected data', async () => {
    const result = await legacyApi.fetchUsers();
    expect(result).toEqual(mockData);
  });

  it('modern API returns equivalent data', async () => {
    const result = await modernApi.getUsers();
    expect(result).toEqual(mockData);
  });

  it('both APIs handle errors identically', async () => {
    const error = new Error('Network error');
    vi.spyOn(legacyApi, 'fetchUsers').mockRejectedValue(error);
    vi.spyOn(modernApi, 'getUsers').mockRejectedValue(error);

    await expect(legacyApi.fetchUsers()).rejects.toThrow('Network error');
    await expect(modernApi.getUsers()).rejects.toThrow('Network error');
  });
});
```

## Performance Testing

### Before/After Benchmarks

```typescript
import { performance } from 'perf_hooks';

describe('Performance comparison', () => {
  const iterations = 1000;

  it('deprecated moment.js performance', () => {
    const start = performance.now();

    for (let i = 0; i < iterations; i++) {
      formatDateMoment('2025-01-15');
    }

    const duration = performance.now() - start;
    console.log(`Moment.js: ${duration}ms`);
  });

  it('modern date-fns performance', () => {
    const start = performance.now();

    for (let i = 0; i < iterations; i++) {
      formatDateModern('2025-01-15');
    }

    const duration = performance.now() - start;
    console.log(`date-fns: ${duration}ms`);

    // Optional: Assert performance improvement
    // expect(duration).toBeLessThan(baselineDuration);
  });
});
```

## Bundle Size Testing

### Before/After Comparison

```bash
# Before migration
npm run build
du -sh dist/ # or webpack-bundle-analyzer

# After migration
npm run build
du -sh dist/

# Compare bundle sizes
# Expect smaller bundle after removing large deps like moment
```

## Migration Test Checklist

Use this checklist for each deprecation migration:

- [ ] Baseline tests pass before changes
- [ ] Added tests for current (deprecated) behavior if missing
- [ ] Implemented new modern equivalent
- [ ] Added equivalence tests comparing old vs new
- [ ] All existing tests pass with new implementation
- [ ] No new TypeScript errors
- [ ] No new ESLint warnings
- [ ] Integration tests pass
- [ ] Visual regression tests pass (if UI changes)
- [ ] Performance is equal or better
- [ ] Bundle size is equal or smaller
- [ ] Documentation updated
- [ ] Deprecated code removed (or marked for removal)

## Continuous Testing Strategy

### Gradual Rollout

For large migrations, test incrementally:

```typescript
// Feature flag to test both implementations
const USE_MODERN_API = process.env.FEATURE_FLAG_MODERN_API === 'true';

export function fetchData() {
  if (USE_MODERN_API) {
    return modernApi.getData();
  }
  return legacyApi.getDataDeprecated();
}

// Test both paths
describe('fetchData', () => {
  describe('with legacy API', () => {
    beforeAll(() => {
      process.env.FEATURE_FLAG_MODERN_API = 'false';
    });

    it('works', async () => {
      const data = await fetchData();
      expect(data).toBeDefined();
    });
  });

  describe('with modern API', () => {
    beforeAll(() => {
      process.env.FEATURE_FLAG_MODERN_API = 'true';
    });

    it('works', async () => {
      const data = await fetchData();
      expect(data).toBeDefined();
    });
  });
});
```

### Canary Testing

Deploy to subset of users first:

```typescript
// A/B test old vs new in production
const useModernImplementation = userInCanaryGroup(userId);

if (useModernImplementation) {
  return modernApi.getData();
}
return legacyApi.getDataDeprecated();
```

## Test Automation

### Automated Deprecation Detection

```typescript
// Custom lint rule or test
describe('deprecation checks', () => {
  it('has no deprecated imports', () => {
    const sourceCode = fs.readFileSync('src/index.ts', 'utf-8');

    // Fail if deprecated packages still imported
    expect(sourceCode).not.toContain("from 'moment'");
    expect(sourceCode).not.toContain("from 'request'");
  });
});
```

### CI Integration

```yaml
# .github/workflows/test.yml
name: Test Migrations
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - run: npm ci
      - run: npm test -- --coverage
      - run: npm run lint

      # Check for deprecation warnings
      - name: Check for deprecations
        run: |
          npm test 2>&1 | tee test-output.log
          if grep -i "deprecat" test-output.log; then
            echo "Deprecation warnings found"
            exit 1
          fi
```

## Documentation Testing

### Test Documentation Examples

Ensure migration guide examples work:

```typescript
// Test code examples from migration docs
describe('Migration guide examples', () => {
  it('example 1: basic usage', () => {
    // Copy-paste example from docs
    const result = modernApi.getData();
    expect(result).toBeDefined();
  });

  it('example 2: error handling', async () => {
    // Verify documented error handling works
    try {
      await modernApi.getData();
    } catch (error) {
      expect(error).toBeInstanceOf(ApiError);
    }
  });
});
```
