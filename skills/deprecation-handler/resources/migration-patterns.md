# Common Migration Patterns

This document provides practical examples of migrating from deprecated code to modern alternatives.

## React Patterns

### Class Components to Functional Components

**Deprecated Pattern**:

```typescript
import React from 'react';

class UserProfile extends React.Component {
  constructor(props) {
    super(props);
    this.state = { loading: true, user: null };
  }

  componentDidMount() {
    this.fetchUser();
  }

  componentWillUnmount() {
    this.cancelRequest();
  }

  fetchUser() {
    // Fetch logic
  }

  render() {
    return <div>{this.state.user?.name}</div>;
  }
}
```

**Modern Pattern**:

```typescript
import { useState, useEffect } from 'react';

const UserProfile = () => {
  const [loading, setLoading] = useState(true);
  const [user, setUser] = useState(null);

  useEffect(() => {
    let cancelled = false;

    const fetchUser = async () => {
      // Fetch logic
      if (!cancelled) {
        setUser(data);
        setLoading(false);
      }
    };

    fetchUser();

    return () => {
      cancelled = true; // Cleanup
    };
  }, []);

  return <div>{user?.name}</div>;
};
```

### Legacy Lifecycle Methods

**Deprecated**: `componentWillMount`, `componentWillReceiveProps`, `componentWillUpdate`

**Modern Replacements**:

```typescript
// componentWillMount → useEffect or constructor
useEffect(() => {
  // Initialization logic
}, []); // Empty deps = mount only

// componentWillReceiveProps → useEffect with deps
useEffect(() => {
  // React to prop changes
}, [propValue]);

// componentWillUpdate → useEffect
useEffect(() => {
  // Before update logic
  return () => {
    // After update cleanup
  };
});
```

### React.createClass

**Deprecated**:

```javascript
const MyComponent = React.createClass({
  getInitialState() {
    return { count: 0 };
  },
  handleClick() {
    this.setState({ count: this.state.count + 1 });
  },
  render() {
    return <button onClick={this.handleClick}>{this.state.count}</button>;
  }
});
```

**Modern**:

```typescript
const MyComponent = () => {
  const [count, setCount] = useState(0);
  const handleClick = () => setCount(count + 1);

  return <button onClick={handleClick}>{count}</button>;
};
```

## TypeScript Patterns

### Deprecated Compiler Options

**tsconfig.json migrations**:

```json
{
  "compilerOptions": {
    // Deprecated → Modern
    // "charset": "utf8" → (removed, UTF-8 is default)
    // "out": "./output" → "outFile": "./output.js"
    // "suppressImplicitAnyIndexErrors": true → "noImplicitAny": false

    // Use modern strict flags
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true
  }
}
```

### Namespace vs ES Modules

**Deprecated (namespaces)**:

```typescript
namespace Utilities {
  export function log(msg: string) {
    console.log(msg);
  }
}

Utilities.log('Hello');
```

**Modern (ES modules)**:

```typescript
// utils.ts
export function log(msg: string) {
  console.log(msg);
}

// other-file.ts
import { log } from './utils';
log('Hello');
```

## Node.js API Changes

### Buffer Constructor

**Deprecated**:

```javascript
const buf = new Buffer('hello'); // Security risk
const buf2 = new Buffer(10);
```

**Modern**:

```javascript
const buf = Buffer.from('hello'); // Safe
const buf2 = Buffer.alloc(10); // Initialized to zero
const buf3 = Buffer.allocUnsafe(10); // Fast but uninitialized
```

### url.parse

**Deprecated**:

```javascript
const url = require('url');
const parsed = url.parse('http://example.com/path?query=1');
```

**Modern**:

```javascript
const parsed = new URL('http://example.com/path?query=1');
console.log(parsed.pathname); // '/path'
console.log(parsed.searchParams.get('query')); // '1'
```

## Package Migrations

### request → axios/node-fetch

**Deprecated (request)**:

```javascript
const request = require('request');

request('http://api.example.com', (error, response, body) => {
  if (error) console.error(error);
  console.log(body);
});
```

**Modern (axios)**:

```javascript
import axios from 'axios';

try {
  const response = await axios.get('http://api.example.com');
  console.log(response.data);
} catch (error) {
  console.error(error);
}
```

**Modern (node-fetch)**:

```javascript
import fetch from 'node-fetch';

try {
  const response = await fetch('http://api.example.com');
  const data = await response.json();
  console.log(data);
} catch (error) {
  console.error(error);
}
```

### moment → date-fns/dayjs

**Deprecated (moment)**:

```javascript
import moment from 'moment';

const formatted = moment().format('YYYY-MM-DD');
const future = moment().add(7, 'days');
const isPast = moment(date).isBefore(moment());
```

**Modern (date-fns)**:

```javascript
import { format, addDays, isBefore } from 'date-fns';

const formatted = format(new Date(), 'yyyy-MM-dd');
const future = addDays(new Date(), 7);
const isPast = isBefore(date, new Date());
```

### lodash → Native JS

Many lodash utilities now have native equivalents:

**Deprecated (lodash)**:

```javascript
import _ from 'lodash';

const unique = _.uniq([1, 2, 2, 3]);
const mapped = _.map(array, item => item.value);
const filtered = _.filter(array, item => item.active);
```

**Modern (native)**:

```javascript
const unique = [...new Set([1, 2, 2, 3])];
const mapped = array.map(item => item.value);
const filtered = array.filter(item => item.active);
```

**Keep lodash for**:

```javascript
import { debounce, throttle, cloneDeep } from 'lodash';

// These don't have good native equivalents
const debouncedFn = debounce(handler, 300);
const deepCopy = cloneDeep(complexObject);
```

## Framework-Specific Migrations

### Vue 2 → Vue 3

**Deprecated (Vue 2 Options API)**:

```javascript
export default {
  data() {
    return { count: 0 };
  },
  methods: {
    increment() {
      this.count++;
    }
  }
}
```

**Modern (Vue 3 Composition API)**:

```javascript
import { ref } from 'vue';

export default {
  setup() {
    const count = ref(0);
    const increment = () => count.value++;

    return { count, increment };
  }
}
```

### Angular Deprecated Features

**Deprecated (ngModel with reactive forms)**:

```typescript
// Don't mix template-driven and reactive forms
<input [(ngModel)]="name" [formControl]="nameControl">
```

**Modern (reactive forms only)**:

```typescript
<input [formControl]="nameControl">
```

## Testing Library Migrations

### Enzyme → React Testing Library

**Deprecated (Enzyme)**:

```javascript
import { shallow } from 'enzyme';

const wrapper = shallow(<MyComponent />);
expect(wrapper.find('button').text()).toBe('Click me');
wrapper.find('button').simulate('click');
```

**Modern (React Testing Library)**:

```javascript
import { render, screen } from '@testing-library/react';
import userEvent from '@testing-library/user-event';

render(<MyComponent />);
const button = screen.getByRole('button', { name: /click me/i });
await userEvent.click(button);
```

## Migration Strategy

### Step-by-Step Process

1. **Identify Pattern**: Find deprecated usage in codebase
2. **Find Replacement**: Consult migration guide or deprecation message
3. **Create Test**: Ensure current behavior is tested
4. **Apply Change**: Replace deprecated code with modern equivalent
5. **Verify**: Run tests and check for regressions
6. **Commit**: Commit working migration incrementally

### Batch vs Individual

**Batch** (same pattern across files):

```bash
# Good for mechanical replacements
git grep "deprecatedFunc" | # Find all usages
  # Replace pattern across all files
  # Commit as single change: "Migrate from deprecatedFunc to newFunc"
```

**Individual** (complex changes):

```bash
# Migrate one component at a time
git commit -m "Migrate UserProfile component to hooks"
git commit -m "Migrate Dashboard component to hooks"
# Easier to review and rollback if needed
```
